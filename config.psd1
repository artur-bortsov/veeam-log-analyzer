@{
    # ---------------------------------------------------------------------------
    # Path to the output CSV database that accumulates all parsed replication
    # sessions. This file is consumed by Excel, Grafana, Access, and similar
    # reporting tools. The account running the script must have write access.
    # ---------------------------------------------------------------------------
    OutputCsvPath = "\\fileserver\share\Logs\VeeamReplicationLog.csv"

    # ---------------------------------------------------------------------------
    # Root directory where Veeam Backup & Replication stores its task log files.
    # On a default Windows installation this is C:\ProgramData\Veeam\Backup.
    # The script searches this directory recursively for files matching Task.*.log
    # ---------------------------------------------------------------------------
    VeeamLogPath  = "C:\ProgramData\Veeam\Backup"

    # ---------------------------------------------------------------------------
    # Directory for the script's own run log (ParsingLog.csv).
    # Leave empty ("") to use a "Log" subdirectory next to the script file.
    # ---------------------------------------------------------------------------
    ScriptLogDir  = ""

    # ---------------------------------------------------------------------------
    # File path for sessions that could not be fully parsed (diagnostic output).
    # Leave empty ("") to place Error.txt next to the script file.
    # ---------------------------------------------------------------------------
    ErrorLogPath  = ""
}
