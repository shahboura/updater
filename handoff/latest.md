# Handoff — 2026-10-30 08:55

## Done
- Trim pass over both scripts (net -61 lines) without dropping any provider.
- **Windows:** every provider now calls `Invoke-Step` with named parameters
  instead of a 6-line `$params` hashtable; `Add-StepResult` builds the result
  row in one place; new `-Hint` parameter folds "install with …" into the
  not-found skip message; removed the redundant `Test-Command` guards for
  WSL / pipx / pip-review (pre-flight already covers them) and the unused
  `Error` field.
- **Linux:** result format is now `Provider|Status|Message|Duration` (the `Error`
  field duplicated `Message`); `run_step` sets `LAST_STATUS` so a follow-up step
  gates on the recorded result instead of `$?` or string parsing.
- **Bug fixed (both):** `npm (cache)` was missing from `--dry-run` output.
  Linux gated on `$?` (1 for a dry-run step) and Windows on
  `Status -eq "Success"`; both now accept `Success` or `DryRun`.
- **Bug fixed (Linux):** `--skip-ap` (typo) printed usage and exited 0 — a
  silent no-op. Unknown options and a bad `--log-path` now exit 2, and a flag
  following `--log-path` is no longer swallowed as the path.
- **Logging:** run banner with host/kernel in the log, and the summary repeats
  every failure with its message so the reason does not need a scroll-back.

## Files changed
- `Update-Windows.ps1`, `update-linux.sh`, `README.md` (log-file + exit-code
  notes), `AGENTS.md` (conventions, gotchas, activity).

## Verified (fresh output)
- `bash -n update-linux.sh` → clean.
- `--dry-run` with providers skipped → npm **and** npm (cache) recorded, exit 0.
- Stub `flatpak` exiting 7 → `Failures:` block shows `exited with code 7`, exit 2.
- Same stub with `--stop-on-error` → summary then exit 3.
- Stub `npm` exiting 3 → cache step not run (earlier regression stays fixed).
- `--help` → exit 0; `--skip-ap` and bare `--log-path` → exit 2 with message.
- `--log-path` writes banner + status lines only.
- Windows script: static review only — no `pwsh`/`dotnet` on this machine.
  Brace/paren balance even, no trailing whitespace after backticks, all 14
  `Invoke-Step` call sites use declared parameters, no leftover `$params`/`Error`.
  A fresh reviewer lens found the Windows dry-run gate gap (fixed) and no other
  defects.

## Cleanup
- Removed every artifact created here: `/tmp/opencode/{bin,fake}` stubs and the
  `d.log` / `d2.log` / `u.log` / `e.txt` test logs. Nothing installed, nothing
  written outside the repo and `/tmp/opencode`.

## Next
- Commit and push (pending user confirmation).
- Run `.\Update-Windows.ps1 -DryRun` once on Windows to confirm the split
  provider calls bind as expected.
