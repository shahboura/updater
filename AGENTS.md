# updater — Agent Context

One-command system update for Windows and Linux. Updates package managers,
developer tools, containers, and firmware in a single pass.

## Tech stack

- **Windows:** `Update-Windows.ps1` — PowerShell 5.1+, `[CmdletBinding()]`, splatting.
- **Linux:** `update-linux.sh` — bash 4+ (Ubuntu/Debian), `set -o pipefail`.
- **Docs:** `README.md` (usage, provider flags, prerequisites, exit codes).

## Architecture / conventions

- **Provider model:** each updater (winget, choco, npm, apt, snap, …) is a
  provider block guarded by a skip flag. Windows flags are `-SkipX` switch
  params; Linux flags are `--skip-x`.
- **`Invoke-Step` (Windows) / `run_step` (Linux):** shared step runner.
  Pre-flight checks required tools, handles dry-run, logs status, records a
  result row (`Provider|Status|Message|Duration|Error`).
- **Results:** stored in `$Script:Results` (PowerShell `List[PSCustomObject]`) /
  `RESULTS` (bash array, `|`-delimited). The summary report reads from it.
- **Exit codes:** `0` all ok, `1` partial failure, `2` all failed, `3` halted
  (`--stop-on-error` / `-StopOnFirstError`).

## Gotchas

- **PowerShell output-stream pollution:** functions emit everything on the
  success output stream (log lines via `Write-Output`, native command output,
  and any `return $value`). Assigning a step result to a variable therefore
  captured an array, not a boolean. `Invoke-Step` now returns *no* value —
  callers read `$Script:Results[...].Status` instead.
- **npm global prefix permissions:** `npm upgrade -g` needs write access to
  `npm root -g`. Windows: `C:\Program Files\nodejs` requires elevation. Linux:
  apt-installed npm (`/usr/lib/node_modules`) requires `sudo` or a user-local
  prefix. Both scripts detect an unwritable prefix and skip with a hint.

## Milestones

- [x] Phase 0–2: Windows script, Linux script, providers, config file, README.
- [x] npm EPERM handling + cache-gating bug fix (see recent activity).

## Recent activity

### 2026-08-22 14:27 - Fix npm EPERM + cache-gating bug (Windows & Linux)
**Agent:** orchestrator
**Summary:** Diagnosed `✗ npm : Failed` (EPERM, non-elevated) and a real bug
where the npm cache step ran even after npm failed.
- Root cause: `Invoke-Step` returned a boolean on the same output stream as its
  progress output, so `$npmOk = Invoke-Step @params` captured a truthy array.
- Fix: `Invoke-Step` returns nothing; result read from `$Script:Results`.
- Added graceful skip when npm global prefix needs elevation (Windows) / is
  root-owned (Linux); documented in README.
- Workflow that worked: confirm root cause with a minimal repro before editing;
  reject the `Write-Host`/`Out-Host` workaround in favor of removing the
  redundant return value.
