# updater — Agent Context

One-command system update for Windows and Linux. Providers run one after
another and each can be skipped with a flag. `README.md` has the flag list,
prerequisites and exit codes.

## Layout

- `Update-Windows.ps1` — PowerShell 5.1+, `[CmdletBinding()]`.
- `update-linux.sh` — bash 4+ (Ubuntu/Debian), `set -o pipefail`.

## Conventions

- **Provider blocks:** one per updater, guarded by a skip flag (Windows
  `-SkipX`, Linux `--skip-x`). Windows calls the runner with named parameters,
  not a splat hashtable.
- **`Invoke-Step` / `run_step`:** the shared runner — checks required tools,
  handles dry-run, logs, appends a result row. A missing tool records `Skipped`,
  so no `Test-Command` guard belongs around a step; pass the tools
  (`-RequiredTools`; Windows `-Hint` appends an install hint).
- **Results:** `$Script:Results` (`List[PSCustomObject]` with
  Provider/Status/Message/Duration) / `RESULTS` (bash array of
  `Provider|Status|Message|Duration`, `|` in text swapped for `¦`). The summary
  reads it and repeats failures with their message.
- **Exit codes:** `0` ok, `1` partial failure, `2` all failed (also bad
  arguments on Linux), `3` halted.

## Gotchas

- **Keep the runner free of return values.** `Invoke-Step` writes log lines to
  the success stream, so a `return $value` makes callers capture an array; read
  `$Script:Results[...].Status` instead. Do not "fix" this with `Write-Host`.
- **`run_step` returns 0 only on success** — skipped and dry-run steps return 1.
  Gate a follow-up step on `$LAST_STATUS`, never on `$?` alone.
- **npm global prefix must be writable** (`npm root -g`): `C:\Program Files`
  needs elevation, `/usr/lib/node_modules` needs sudo. Both scripts skip with a
  hint instead of surfacing EPERM/EACCES.
- **Log files are status-only**; raw command output stays on the console.
- **PowerShell may not be installed** on the Linux box, so a PS edit ships
  reviewed statically (braces, backtick line endings, call-site arity) unless
  someone runs it on Windows.

## History

Phase 0–2 plus two bug-fix passes; `git log` has the details. Lesson kept from
them: reproduce with a minimal case before editing.
