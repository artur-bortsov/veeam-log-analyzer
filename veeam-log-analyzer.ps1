<#
.SYNOPSIS
    Veeam Replication Log Analyzer

.DESCRIPTION
    Parses Veeam Backup & Replication task log files and extracts replication
    session metrics (timestamps, storage names, host names, proxy info,
    bottleneck classification) into a semicolon-delimited CSV database.

    The script is designed to be run by the Windows Task Scheduler, typically
    once per day after the nightly replication window completes. It keeps track
    of already-processed session IDs so each run is incremental – only new
    sessions are appended to the CSV.

.NOTES
    Version : 1.2
    Created : 2021-10-13
    Updated : 2024-01-30
    Author  : Bortsov A.S.

.LINK
    https://github.com/artur-bortsov/veeam-log-analyzer
#>

# ---------------------------------------------------------------------------
# Load configuration from config.psd1 located next to this script file.
# Edit config.psd1 to change paths without touching the script logic.
# ---------------------------------------------------------------------------
$configPath = Join-Path $PSScriptRoot "config.psd1"
$Config     = Import-PowerShellDataFile -Path $configPath

# Resolve paths; fall back to defaults relative to $PSScriptRoot when empty.
$path      = $Config.OutputCsvPath
$veeamLogs = $Config.VeeamLogPath
$logDir    = if ($Config.ScriptLogDir) { $Config.ScriptLogDir } else { Join-Path $PSScriptRoot "Log" }
$errorLog  = if ($Config.ErrorLogPath) { $Config.ErrorLogPath } else { Join-Path $PSScriptRoot "Error.txt" }

# Wrap everything in Measure-Command so total wall-clock time is available for the run log.
$Global:ALLTimeWorkScript = Measure-Command -Expression {

    # Ensure the script log directory exists; create it if necessary.
    if (-not (Test-Path $logDir)) {
        New-Item $logDir -ItemType Directory | Out-Null
    }

    # Reset the in-memory ID list used to skip already-processed sessions.
    $Global:IDCSV = $null

    # Check whether the output CSV already exists before the run begins.
    $TestPathSCV = Test-Path $path

    # Capture the run start timestamp.
    $Global:currentDate = Get-Date

    # Counter: sessions successfully written to the CSV during this run.
    [int]$Global:NewRecords = 0

    # Counter: sessions skipped because their ID was already in the CSV.
    [int]$Global:existedRecords = 0

    # Counter: blocks that had a session-start marker but lacked enough data to export.
    [int]$Global:incompleteRecords = 0

    # Counter: blocks where str1 and str4 are present but str2 or str3 are missing.
    [int]$Global:Atypicalrecords = 0

    # Counter: blocks where one or more of the 9 expected marker strings are absent.
    [int]$Global:insufficientRecords = 0

    # ---------------------------------------------------------------------------
    # IDCSV – loads all session IDs that are already stored in the output CSV so
    # that duplicate entries are never written.
    # ---------------------------------------------------------------------------
    Function IDCSV {
        $Global:IDCSV = @()
        if ($TestPathSCV) {
            $TMPCSV = Import-Csv $path -Delimiter ";"
            $Global:IDCSV += $TMPCSV.ID
            Clear-Variable TMPCSV
        }
    }

    $Global:TimeReadCSV = Measure-Command -Expression {
        IDCSV
    }

    # ---------------------------------------------------------------------------
    # ExportCSV – appends one parsed replication session record to the output CSV.
    # ---------------------------------------------------------------------------
    Function ExportCSV {
        [PSCustomObject]@{
            "ID"                       = $Global:ID
            "Server"                   = $Global:Servername
            "StorageOfSource"          = $Global:StorageOfSource
            "StorageOfTarget"          = $Global:StorageOfTarget
            "Bottleneck"               = $Global:Bottleneck
            "HostOfSource"             = $Global:HostOfSource
            "HostOfTarget"             = $global:HostOfTarget
            "Proxy"                    = $Global:proxy.Trim()
            "StartReplication"         = $Global:StartReplication
            "EndReplication"           = $Global:EndReplication
            "StartSnapshotRemoval"     = $Global:StartSnapshotRemoval
            "EndSnapshotRemoval"       = $Global:EndSnapshotRemoval
            "DurationReplication"      = $Global:DurationReplication
            "WaitForSemaphore"         = $Global:WaitForSemaphore
            "DurationSnapshotRemoval"  = $Global:DurationSnapshotRemoval
        } | Export-Csv -Path $path -Delimiter ";" -NoClobber -Append -NoTypeInformation -Encoding UTF8
    }

    # ---------------------------------------------------------------------------
    # LogCSV – appends a run-summary row to the internal script run log.
    # ---------------------------------------------------------------------------
    Function LogCSV {
        [PSCustomObject]@{
            "Date start"           = $Global:currentDate
            "Date end"             = $Global:currentEndDate
            "Time read CSV"        = $Global:TimeReadCSV
            "New records"          = [int]$Global:NewRecords
            "Existed records"      = [int]$Global:existedRecords
            "Incomplete records"   = [int]$Global:incompleteRecords
            "Atypical records"     = [int]$Global:Atypicalrecords
            "Insufficient records" = [int]$Global:insufficientRecords
            "Time script"          = $Global:ALLTimeWorkScript.ToString()
        } | Export-Csv -Path (Join-Path $logDir "ParsingLog.csv") -Delimiter ";" -NoClobber -Append -NoTypeInformation -Encoding UTF8
    }

    # ---------------------------------------------------------------------------
    # Marker strings used to locate relevant events inside Veeam task log files.
    # Each log file contains one or more replication sessions; these patterns
    # delimit session boundaries and carry the data fields we need to extract.
    # ---------------------------------------------------------------------------

    # str1  – Session start: marks the beginning of a task session block.
    $Global:str1   = "Set status 'InProgress' for task session"
    # str2  – Snapshot deallocator: marks the end of the data-transfer phase.
    $Global:str2   = "DeleteSnapshotResourceAllocator]"
    # str3  – Snapshot tracker close: marks the start of snapshot removal.
    $Global:str3   = "VmSnapshotTracker] closing snapshots. Session id:"
    # str4  – Bottleneck report: marks the end of snapshot removal; carries bottleneck type.
    $Global:str4   = "Primary bottleneck:"
    # str5  – VMX file path of the source VM (used to extract source datastore name).
    $Global:str5   = "VMX file: `"\["
    # str5_1 – VMX upload line for the target replica (used to extract target datastore name).
    $Global:str5_1 = "\[SnapReplicaVmTarget\] Uploading vmx file"
    # str6  – Disk processing preparation: carries source and target proxy names.
    $Global:str6   = "Preparing for processing of disk"
    # str7  – Source proxy check: carries source and target ESXi host names.
    $global:str7   = "Checking source proxy \["
    # str8  – VM information line: fallback source host name when str7 is absent.
    $global:str8   = "VM information: name"
    # str9  – Proxy agent connection: fallback proxy name extraction when str6 yields nothing.
    $global:str9   = "ProxyAgent] Connecting client from"

    # ---------------------------------------------------------------------------
    # Collect all Veeam task log files from the configured directory.
    # ---------------------------------------------------------------------------
    $Global:files = (Get-ChildItem $veeamLogs -Recurse |
                     Where-Object { $_.Name -match "Task.*.log" }).FullName

    foreach ($Global:file in $files) {

        # Clear all per-file working variables before processing the next file.
        $allBlock      = $null
        $filecont      = $null
        $Global:str1n  = $null
        $ListString1   = $null
        $ListString1ID = $null
        $Global:ID     = $null
        $str1n         = $null
        $string1       = $null
        $string2       = $null
        $string3       = $null
        $string4       = $null
        $string5       = $null
        $string5_1     = $null
        $string6       = $null
        $string7       = $null
        $string8       = $null
        $string9       = $null

        # Read the file and pre-filter to only the lines that match any marker string.
        $filecont  = [System.IO.File]::ReadAllLines($file) |
                     Select-String $Global:str1,   $Global:str2, $Global:str3,   $Global:str4,
                                   $Global:str5,   $Global:str5_1, $Global:str6, $global:str7,
                                   $global:str8,   $global:str9 |
                     Select-Object LineNumber, Line

        $string1   = $filecont | Select-String $str1   | Select-Object LineNumber, Line
        $string2   = $filecont | Select-String $str2   | Select-Object LineNumber, Line
        $string3   = $filecont | Select-String $str3   | Select-Object LineNumber, Line
        $string4   = $filecont | Select-String $str4   | Select-Object LineNumber, Line
        $string5   = $filecont | Select-String $str5   | Select-Object LineNumber, Line
        $string5_1 = $filecont | Select-String $str5_1 | Select-Object LineNumber, Line
        $string6   = $filecont | Select-String $str6   | Select-Object LineNumber, Line
        $string7   = $filecont | Select-String $str7   | Select-Object LineNumber, Line
        $string8   = $filecont | Select-String $str8   | Select-Object LineNumber, Line
        $string9   = $filecont | Select-String $str9   | Select-Object LineNumber, Line

        # Build the list of all str1 occurrences and extract their session IDs.
        $ListString1   = $filecont | Where-Object { $_.Line -like "*$str1*" }
        $ListString1ID = $ListString1.Line | ForEach-Object {
            ([regex]::Matches($_, "(\w*-){4}\w*")).Value
        }

        # Array of line numbers for each session-start (str1) occurrence.
        $str1n = $string1.LineNumber

        # If this file contains at least one session-start marker, iterate over blocks.
        if ($str1n) {
            [int]$it = 0   # index into the $str1n array

            # Each iteration covers one session block delimited by consecutive str1 lines.
            while ($it -ne $str1n.Count) {
                [int]$startline   = $null
                [int]$endline     = $null
                $str1idChedtoskip = $null
                $checkstrID       = $null

                # The current block starts at the line number of the current str1.
                [int]$startline = $str1n[$it]

                # The current block ends just before the next str1 (or at end of filtered content).
                if (($it + 1) -ge $str1n.Count) {
                    [int]$endline = $filecont.Count + 1
                } else {
                    [int]$endline = $str1n[$it + 1]
                }

                # Extract the session ID from the current str1 line.
                $checkstrID       = ($string1 | Where-Object { $_.LineNumber -eq $startline }).Line
                $str1idChedtoskip = ([regex]::Matches($checkstrID, "(\w*-){4}\w*")).Value

                # Skip this block if the session ID is already stored in the CSV.
                if ($IDCSV -notcontains "$str1idChedtoskip") {

                    # Clear per-block string holders.
                    $str1toAB   = $null
                    $str2toAB   = $null
                    $str3toAB   = $null
                    $str4toAB   = $null
                    $str5toAB   = $null
                    $str5_1toAB = $null
                    $str6toAB   = $null
                    $str7toAB   = $null
                    $str8toAB   = $null
                    $str9toAB   = $null

                    # Find each marker string within the block's line range;
                    # trim the Select-String wrapper characters "@{" / "}" from the value.
                    $str1toAB1 = ($string1 | Where-Object { $_.LineNumber -eq $startline }).Line
                    if ($str1toAB1) {
                        $str1toAB = $str1toAB1.TrimStart("@{").TrimEnd("}")
                    }

                    $str2toAB1 = ($string2 | Where-Object { $_.LineNumber -gt $startline -and $_.LineNumber -lt $endline }).Line
                    if ($str2toAB1) {
                        $str2toAB = $str2toAB1.TrimStart("@{").TrimEnd("}")
                    }

                    $str3toAB1 = ($string3 | Where-Object { $_.LineNumber -gt $startline -and $_.LineNumber -lt $endline }).Line
                    if ($str3toAB1) {
                        $str3toAB = $str3toAB1.TrimStart("@{").TrimEnd("}")
                    }

                    $str4toAB1 = ($string4 | Where-Object { $_.LineNumber -gt $startline -and $_.LineNumber -lt $endline }).Line
                    if ($str4toAB1) {
                        $str4toAB = $str4toAB1.TrimStart("@{").TrimEnd("}")
                    }

                    # str5: take only the first match (a session may process multiple disks).
                    $str5toAB1 = ($string5 | Where-Object { $_.LineNumber -gt $startline -and $_.LineNumber -lt $endline }).Line | Select-Object -First 1
                    if ($str5toAB1) {
                        $str5toAB = $str5toAB1.TrimStart("@{").TrimEnd("}")
                    }

                    $str5_1toAB1 = ($string5_1 | Where-Object { $_.LineNumber -gt $startline -and $_.LineNumber -lt $endline }).Line
                    if ($str5_1toAB1) {
                        $str5_1toAB = $str5_1toAB1.TrimStart("@{").TrimEnd("}")
                    }

                    $str6toAB1 = ($string6 | Where-Object { $_.LineNumber -gt $startline -and $_.LineNumber -lt $endline }).Line
                    if ($str6toAB1) {
                        $str6toAB = $str6toAB1.TrimStart("@{").TrimEnd("}")
                    }

                    # str7: take only the first match.
                    $str7toAB1 = ($string7 | Where-Object { $_.LineNumber -gt $startline -and $_.LineNumber -lt $endline }).Line | Select-Object -First 1
                    if ($str7toAB1) {
                        $str7toAB = $str7toAB1.TrimStart("@{").TrimEnd("}")
                    }

                    # str8: take only the first match (fallback host name source).
                    $str8toAB1 = ($string8 | Where-Object { $_.LineNumber -gt $startline -and $_.LineNumber -lt $endline }).Line | Select-Object -First 1
                    if ($str8toAB1) {
                        $str8toAB = $str8toAB1.TrimStart("@{").TrimEnd("}")
                    }

                    $str9toAB1 = ($string9 | Where-Object { $_.LineNumber -gt $startline -and $_.LineNumber -lt $endline }).Line
                    if ($str9toAB1) {
                        $str9toAB = $str9toAB1.TrimStart("@{").TrimEnd("}")
                    }

                    # Count atypical blocks: session start (str1) and bottleneck (str4) found,
                    # but the snapshot-phase markers (str2 or str3) are missing.
                    if ($str1toAB -and $str4toAB -and (!$str2toAB -or !$str3toAB)) {
                        [int]$Global:Atypicalrecords++
                    }

                    # Count blocks where at least one of the 9 expected strings is absent.
                    if (!$str1toAB -or !$str2toAB -or !$str3toAB -or !$str4toAB -or
                        !$str5toAB -or !$str5_1toAB -or !$str6toAB -or !$str7toAB -or
                        !$str8toAB -or !$str9toAB) {
                        [int]$Global:insufficientRecords++
                    }

                    # If the four mandatory timing strings are all present, queue the block.
                    if ($str1toAB -and $str2toAB -and $str3toAB -and $str4toAB) {
                        $allBlock += @(
                            [PSCustomObject]@{
                                "str1"   = $str1toAB
                                "str2"   = $str2toAB
                                "str3"   = $str3toAB
                                "str4"   = $str4toAB
                                "str5"   = $str5toAB
                                "str5_1" = $str5_1toAB
                                "str6"   = $str6toAB
                                "str7"   = $str7toAB
                                "str8"   = $str8toAB
                                "str9"   = $str9toAB
                            }
                        )
                        $Global:NewRecords++
                    } else {
                        # Session started but did not produce a complete parseable record.
                        [int]$Global:incompleteRecords++
                    }

                    # Register the ID in-memory so it is not re-processed in the same run.
                    $Global:IDCSV += "$str1idChedtoskip"

                } else {
                    # Session is already present in the CSV – increment the skip counter.
                    [int]$Global:existedRecords++
                }

                $it++
            }
        }

        # ------------------------------------------------------------------
        # Extract field values from each collected block and write to CSV.
        # Note: proxy name parsing (str6/str9) may emit errors to the console
        # for log files that do not match the expected format (e.g. backup jobs
        # vs. replication jobs). This is expected and intentional behaviour.
        # ------------------------------------------------------------------
        foreach ($block in $allBlock) {

            [string]$ProxiesOfSource_and_Target = ""
            $Global:ID                      = $null
            $Global:StartReplication        = $null
            $Global:Servername              = $null
            $Global:EndReplication          = $null
            $Global:StartSnapshotRemoval    = $null
            $Global:EndSnapshotRemoval      = $null
            $Global:Bottleneck              = $null
            $Global:StorageOfSource         = $null
            $Global:StorageOfTarget         = $null
            $Global:DurationReplication     = $null
            $Global:WaitForSemaphore        = $null
            $Global:DurationSnapshotRemoval = $null
            $ProxyOfSource                  = $null
            $ProxyOfTarget                  = $null
            $ProxyOfSourceout               = $null
            $ProxyOfTargetout               = $null
            $Global:HostOfSource            = $null
            $global:HostOfTarget            = $null
            $ProxyOfSourceout1              = $null
            $ProxyOfTargetout1              = $null
            [string]$Global:proxy           = $null

            # ---------------------------------------------------------------
            # Primary proxy extraction – from str6 "Preparing for processing of disk".
            # Each disk line may carry a different proxy pair; all are collected
            # and concatenated as a multi-line value in the Proxy column.
            # ---------------------------------------------------------------
            foreach ($proxyinstr in $block.str6) {
                [string]$ProxiesOfSource_and_Target = ""
                $ProxyOfSource    = $null
                $ProxyOfTarget    = $null
                $ProxyOfSourceout = $null
                $ProxyOfTargetout = $null

                if ($proxyinstr -cmatch "proxy '(.*?)'") {
                    $ProxyOfSource = ([regex]::Matches($proxyinstr, "proxy '(.*?)'")).Groups[1].Value
                    $ProxyOfTarget = ([regex]::Matches($proxyinstr, "proxy '(.*?)'")).Groups[3].Value
                }

                if ($ProxyOfSource) {
                    $ProxyOfSourceout = "Source=" + "$ProxyOfSource"
                    [string]$ProxiesOfSource_and_Target += $ProxyOfSourceout + "`n"
                }
                if ($ProxyOfTarget) {
                    $ProxyOfTargetout = "Target=" + "$ProxyOfTarget"
                    [string]$ProxiesOfSource_and_Target += $ProxyOfTargetout + "`n"
                }

                # Accumulate proxy pairs into a single multi-line CSV cell.
                if ($ProxiesOfSource_and_Target.Length -gt 0) {
                    [string]$Global:proxy += $ProxiesOfSource_and_Target
                }
            }

            # ---------------------------------------------------------------
            # Fallback proxy extraction – from str9 "ProxyAgent] Connecting client from".
            # Used only when str6 did not yield any proxy names.
            # Deduplicates entries before appending.
            # ---------------------------------------------------------------
            if (!$Global:proxy) {
                [string]$Global:proxy = $null

                foreach ($strpr9 in $block.str9) {
                    [string]$ProxiesOfSource_and_Target1 = ""
                    $ProxyOfSource     = $null
                    $ProxyOfTarget     = $null
                    $ProxyOfSourceout1 = $null
                    $ProxyOfTargetout1 = $null

                    $ProxyOfSource = [regex]::Matches([string]$strpr9, "'(.*?)'").Groups[1].Value
                    $ProxyOfTarget = [regex]::Matches($strpr9,          "'(.*?)'").Groups[3].Value

                    if ($ProxyOfSource) {
                        $ProxyOfSourceout1 = "Source=" + "$ProxyOfSource"
                    }
                    if ($ProxyOfTarget) {
                        $ProxyOfTargetout1 = "Target=" + "$ProxyOfTarget"
                    }

                    if ($Global:proxy -notmatch $ProxyOfSourceout1) {
                        [string]$ProxiesOfSource_and_Target1 += $ProxyOfSourceout1 + "`n"
                    }
                    if ($Global:proxy -notmatch $ProxyOfTargetout1) {
                        [string]$ProxiesOfSource_and_Target1 += $ProxyOfTargetout1 + "`n"
                    }

                    if ($ProxiesOfSource_and_Target1.Length -gt 0) {
                        [string]$Global:proxy += $ProxiesOfSource_and_Target1
                    }
                }
            }

            # Extract session start datetime and ID from str1.
            $Global:StartReplication = (([regex]::Matches($block.str1, "\[(.*?)\]")).Value).TrimEnd(']').TrimStart('[')
            $Global:ID               = ([regex]::Matches($block.str1, "(\w*-){4}\w*")).Value
            $Global:Servername       = (([regex]::Matches($block.str1, "'\S+'$")).Value).TrimEnd("'").TrimStart("'")

            # Extract end-of-replication datetime from str2.
            $Global:EndReplication = (([regex]::Matches($block.str2, "\[(.*?)\]")).Item(0).Value).TrimEnd(']').TrimStart('[')

            # Extract snapshot removal start datetime from str3.
            $Global:StartSnapshotRemoval = (([regex]::Matches($block.str3, "\[(.*?)\]")).Item(0).Value).TrimEnd(']').TrimStart('[')

            # Extract snapshot removal end datetime and bottleneck type from str4.
            $Global:EndSnapshotRemoval = (([regex]::Matches($block.str4, "\[(.*?)\]")).Item(0).Value).TrimEnd(']').TrimStart('[')
            $Global:Bottleneck         = ([regex]::Matches($block.str4, "(\w)\S+$")).Groups[1].Value

            # Extract source and target datastore/storage pool names.
            $Global:StorageOfSource = ([regex]::Matches($block.str5,   '\[(.*?)\]')).Item(1).Groups[1].Value
            $Global:StorageOfTarget = ([regex]::Matches($block.str5_1, '\[(.*?)\]')).Item(2).Groups[1].Value

            # Extract source and target ESXi host names.
            if (!$block.str7) {
                # str7 absent: fall back to the VM information line (str8) for the source host.
                # Target host is left empty in this case.
                $Global:HostOfSource = ([regex]::Matches($block.str8, 'host "(.*?)"')).Groups[1].Value
                $global:HostOfTarget = $null
            } else {
                $Global:HostOfSource = (([regex]::Matches($block.str7, "\[(.*?)\]")).Groups[3].Value).TrimEnd(']').TrimStart('[')
                $global:HostOfTarget = (([regex]::Matches($block.str7, "\[(.*?)\]")).Groups[4].Value).TrimEnd(']').TrimStart('[')
            }

            # Calculate derived duration fields (rounded to whole minutes).
            [int]$DurationReplicationTime     = (New-TimeSpan -Start $StartReplication -End $EndReplication).TotalMinutes
            $Global:DurationReplication       = $DurationReplicationTime

            [int]$WaitForSemaphoreTime        = (New-TimeSpan -Start $EndReplication -End $StartSnapshotRemoval).TotalMinutes
            $Global:WaitForSemaphore          = $WaitForSemaphoreTime

            [int]$DurationSnapshotRemovalTime = (New-TimeSpan -Start $StartSnapshotRemoval -End $EndSnapshotRemoval).TotalMinutes
            $Global:DurationSnapshotRemoval   = $DurationSnapshotRemovalTime

            # If any mandatory field is missing, write the raw block to the error log
            # for later manual inspection.
            if ((!$Global:StartReplication) -or (!$Global:ID) -or (!$Global:Servername) -or
                (!$Global:EndReplication)   -or (!$Global:StartSnapshotRemoval) -or (!$Global:EndSnapshotRemoval)) {
                $Global:currentDate.DateTime, $block | Format-List | Out-File $errorLog -Append
            }

            # Append the fully parsed record to the output CSV database.
            ExportCSV
        }
    }
}

$Global:currentEndDate = Get-Date

# Write the run summary (counters + elapsed time) to the internal run log.
LogCSV
