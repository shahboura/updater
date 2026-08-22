# Handoff — 2026-08-22 14:27

## Done
- Diagnosed `✗ npm : Failed` on Windows: `npm upgrade -g` failed with `EPERM`
  because the global prefix `C:\Program Files\nodejs\node_modules` needs an
  elevated shell (the session was non-elevated).
- Fixed a real bug: `Invoke-Step` returned a boolean on the same output stream
  as its progress output, so `$npmOk = Invoke-Step @params` captured a truthy
  array and the npm cache step ran even after npm failed.
  - Fix: `Invoke-Step` now returns nothing; npm gating reads
    `$Script:Results[$Script:Results.Count - 1].Status`.
- Added graceful skip for an unwritable npm global prefix (Windows elevation
  check; Linux `-w` check on `npm root -g`).
- Documented the npm elevation/prefix requirement in `README.md`.

## Files changed
- `Update-Windows.ps1` — `Invoke-Step` return values removed; npm step
  elevation check + result read from `$Script:Results`.
- `update-linux.sh` — npm step writable-prefix check.
- `README.md` — npm prefix note.

## Verified
- Windows PS1 parses clean; dry-run no longer leaks `True`/`False`.
- Non-elevated + `C:\Program Files\nodejs` → npm skipped, no cache, exit `0`.
- `bash -n update-linux.sh` passes.

## Next
- Commit and push (pending user confirmation).
- Not a script bug: to actually update global npm packages on this machine,
  run once from an elevated PowerShell or move the npm prefix to a
  user-writable location.
