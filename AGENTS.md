# updater — Agent Context

One-command system update for Windows and Linux. Updates package managers,
developer tools, containers, and firmware in a single pass.

## Tech stack

- **Windows:** `Update-Windows.ps1` — PowerShell 5.1+, `[CmdletBinding()]`,
  named `Invoke-Step` parameters.
- **Linux:** `update-linux.sh` — bash 4+ (Ubuntu/Debian), `set -o pipefail`.
- **Docs:** `README.md` (usage, provider flags, prerequisites, exit codes).

## Architecture / conventions

- **Provider model:** each updater (winget, choco, npm, apt, snap, …) is a
  provider block guarded by a skip flag. Windows flags are `-SkipX` switch
  params; Linux flags are `--skip-x`.
- **`Invoke-Step` (Windows) / `run_step` (Linux):** shared step runner.
  Pre-flight checks required tools, handles dry-run, logs status, records a
  result row. Windows takes `-Hint` to append an install hint to the
  "tool not found" message; Linux prints the hint at the call site.
- **Results:** stored in `$Script:Results` (PowerShell `List[PSCustomObject]`
  with Provider/Status/Message/Duration) / `RESULTS` (bash array,
  `Provider|Status|Message|Duration`, `|` in text replaced by `¦`). The summary
  report reads from it and repeats failures at the end.
- **Exit codes:** `0` all ok, `1` partial failure, `2` all failed, `3` halted
  (`--stop-on-error` / `-StopOnFirstError`). Linux also exits `2` on invalid
  arguments; PowerShell rejects unknown parameters at binding time.

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
- **`run_step` return codes (Linux):** returns `0` only when the command
  succeeded; skipped and dry-run steps return `1`. Gate a follow-up step on
  `$LAST_STATUS` (last recorded status), never on `$?` alone — see the npm
  cache step.
- **Log files are status-only:** `Write-LogMessage` / `log_message` write the
  formatted status lines; raw command output stays on the console.

## Milestones

- [x] Phase 0–2: Windows script, Linux script, providers, config file, README.
- [x] npm EPERM handling + cache-gating bug fix (see recent activity).
- [x] Cleanup pass: boilerplate trimmed, dry-run npm cache bug fixed, summary
  repeats failures (see recent activity).

## Recent activity

### 2026-10-30 - Cleanup pass: trim boilerplate, fix dry-run npm cache, better summary
**Agent:** orchestrator
**Summary:** Removed duplicated result plumbing, fixed a Linux dry-run gate,
made the summary report usable in CI logs.
- Windows: dropped the `$params` hashtable per provider (14 call sites) in favor
  of named `Invoke-Step` parameters; added `Add-StepResult` so the result record
  is built in one place; `-Hint` folds the "install with …" skip messages into
  the runner; removed the redundant `Test-Command` guards for WSL/pipx/pip-review
  (pre-flight already handles it); dropped the unused `Error` field.
- Linux: same `Error` field removed (`Provider|Status|Message|Duration`);
  `LAST_STATUS` added so a follow-up step can gate on the previous result
  without parsing `RESULTS`; `run_step` still returns 0 only on success.
- Bug: `npm (cache)` never ran in `--dry-run` (Linux gated on `$?`, which is 1
  for a dry-run step; Windows gated on `Status -eq "Success"`). Both now gate on
  the recorded status being `Success` or `DryRun`.
- Bug: `update-linux.sh --skip-ap` printed usage and exited 0 (silent no-op).
  Unknown options and a bad `--log-path` now exit 2.
- Logging: run banner with host/kernel, and the summary repeats every failure
  with its message so the reason is visible without scrolling.
- Note: no PowerShell runtime in this environment — the Windows script was
  reviewed statically (brace balance, backtick EOL, call arity) but not executed.

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
