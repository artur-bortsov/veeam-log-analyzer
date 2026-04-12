# Changelog

All notable changes to this project will be documented in this file.

---

## [1.2.0] – 2026-04-12

Initial public release on GitHub.
Version 1.2.0 corresponds to the internal version noted in the script header.

### Features
- Incremental parsing of Veeam Backup & Replication task log files —
  only new sessions are appended on each run; already-processed session
  IDs are tracked to prevent duplicates.
- Extracts per-session metrics into a semicolon-delimited CSV:
  timestamps, storage names, host names, proxy info, and bottleneck
  classification.
- Designed for Windows Task Scheduler (typically run once per day after
  the nightly replication window).
- Configurable paths via `config.psd1` — no script edits needed for
  different environments.
- Run-summary log (`ParsingLog.csv`) with new / existing / incomplete /
  atypical / insufficient record counts and wall-clock timing.
- Handles atypical log structures gracefully: falls back to alternative
  marker strings when primary markers are absent.
