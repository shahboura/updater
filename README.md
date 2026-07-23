# updater

One-command system update for Windows and Linux. Updates package managers,
developer tools, containers, and firmware — all in a single pass.

> **Linux users**: The script uses `sudo` for apt, snap, and firmware updates.
> Run with `sudo ./update-linux.sh` or ensure your user has passwordless `sudo`
> for those commands. Docker also requires `sudo` or `docker` group membership.

## Install (copy & paste)

**Windows** (PowerShell 5.1+):
```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/YOUR_USERNAME/updater/main/Update-Windows.ps1" -OutFile "$env:USERPROFILE\Update-Windows.ps1"
```
Or just download `Update-Windows.ps1` and place it anywhere on `PATH`.

**Linux** (Ubuntu/Debian, bash 4+):
```bash
curl -fsSL "https://raw.githubusercontent.com/YOUR_USERNAME/updater/main/update-linux.sh" -o ~/update-linux.sh && chmod +x ~/update-linux.sh
```
Or copy `update-linux.sh` anywhere and `chmod +x` it.

> Replace `YOUR_USERNAME` with the GitHub username hosting the repo.

## Usage

| What | Windows | Linux |
|------|---------|-------|
| Update everything | `.\Update-Windows.ps1` | `./update-linux.sh` |
| Preview only | `-DryRun` | `--dry-run` |
| Skip a provider | `-SkipWsl -SkipDocker` | `--skip-snap --skip-docker` |
| Log to file | `-LogPath update.log` | `--log-path update.log` |
| Stop on first error | `-StopOnFirstError` | `--stop-on-error` |

### Windows providers

| Flag | What it updates |
|------|----------------|
| *(default)* | winget, Microsoft Store, Git, WSL + apt, Docker, npm |
| `-SkipWinget` | Skip winget packages |
| `-SkipStore` | Skip Microsoft Store apps |
| `-SkipGit` | Skip Git for Windows |
| `-SkipWsl` | Skip WSL kernel & apt |
| `-SkipDocker` | Skip Docker (Watchtower) |
| `-SkipNpm` | Skip npm global packages |

### Linux providers

| Flag | What it updates |
|------|----------------|
| *(default)* | apt, snap, flatpak, npm, pip, pipx, Docker, firmware |
| `--skip-apt` | Skip apt |
| `--skip-snap` | Skip snap |
| `--skip-flatpak` | Skip flatpak |
| `--skip-npm` | Skip npm global |
| `--skip-pip` | Skip pip user packages |
| `--skip-pipx` | Skip pipx |
| `--skip-docker` | Skip Docker (Watchtower) |
| `--skip-firmware` | Skip firmware (fwupd) |

## Prerequisites

| Tool | Windows | Linux |
|------|---------|-------|
| winget | Built-in (Win 10 22H2+ / Win 11) | — |
| Git | [git-scm.com](https://git-scm.com) | `sudo apt install git` |
| WSL | `wsl --install` | — |
| Docker | [Docker Desktop](https://docker.com) | [Install Docker Engine](https://docs.docker.com/engine/install/ubuntu/) |
| npm | [Node.js](https://nodejs.org) | `sudo apt install npm` (Node 18+ recommended) |
| pip-review | `pip install pip-review` | `sudo apt install python3-pip && pip3 install pip-review` |
| pipx | `python -m pip install pipx` | `sudo apt install pipx` |
| snap | — | Built-in (Ubuntu) |
| flatpak | — | `sudo apt install flatpak` |
| fwupd | — | Built-in (Ubuntu) |

> Missing tools are detected at runtime and skipped gracefully. No tool is mandatory.
>
> **Snap auto-refresh**: If the snap daemon is already running a background
> refresh, the snap step may report a non-fatal failure — snaps are still
> being updated by the system.

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | All providers succeeded |
| `1` | Partial failure (some failed, some succeeded) |
| `2` | All providers failed |
| `3` | Halted early (`--stop-on-error`) |

> After running, check the exit code with `echo $?` (Linux) or `$LASTEXITCODE` (PowerShell). |
