<#
.SYNOPSIS
    Updates Windows system packages and developer tools.
.DESCRIPTION
    Sequentially runs updates across winget, Microsoft Store, Git, WSL, Docker,
    and npm. Each provider can be individually skipped with a switch parameter.
    Returns structured exit codes for CI / scheduled-task integration.
.PARAMETER SkipWsl
    Skip WSL kernel and apt package updates.
.PARAMETER SkipGit
    Skip Git for Windows update.
.PARAMETER SkipDocker
    Skip Docker container updates via Watchtower.
.PARAMETER SkipWinget
    Skip winget package upgrades.
.PARAMETER SkipStore
    Skip Microsoft Store app updates.
.PARAMETER SkipNpm
    Skip npm global package upgrades.
.PARAMETER StopOnFirstError
    Halt execution on the first provider failure (default: continue).
.PARAMETER DryRun
    Show what would be updated without making changes.
.PARAMETER LogPath
    Path to write a log file. Timestamped output is appended.
.EXAMPLE
    .\Update-Windows.ps1
.EXAMPLE
    .\Update-Windows.ps1 -SkipWsl -SkipDocker
.EXAMPLE
    .\Update-Windows.ps1 -LogPath "$env:TEMP\update.log"
.EXAMPLE
    .\Update-Windows.ps1 -DryRun
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipWsl,
    [switch]$SkipGit,
    [switch]$SkipDocker,
    [switch]$SkipWinget,
    [switch]$SkipStore,
    [switch]$SkipNpm,
    [switch]$StopOnFirstError,
    [switch]$DryRun,
    [string]$LogPath
)

$ErrorActionPreference = "Continue"
$Script:LogFilePath      = $LogPath
$Script:Results          = [System.Collections.Generic.List[PSCustomObject]]::new()
$Script:IsDryRun         = $DryRun -or $WhatIfPreference
$Script:StopOnFirstError = $StopOnFirstError

# ── helpers ────────────────────────────────────────────

function Write-LogMessage {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $Message"
    Write-Output $line
    if ($Script:LogFilePath) {
        Add-Content -LiteralPath $Script:LogFilePath -Value $line -ErrorAction SilentlyContinue
    }
}

function Test-Command {
    param([string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# ── core execution wrapper ─────────────────────────────
#   Returns a result object.  Never throws to the caller;
#   failures are recorded and surfaced in the summary.

function Invoke-Step {
    [CmdletBinding()]
    param(
        [string]$Provider,
        [string]$Description,
        [scriptblock]$Command,
        [string[]]$RequiredTools = @()
    )

    # pre-flight: check that every required tool is on PATH
    foreach ($tool in $RequiredTools) {
        if (-not (Test-Command $tool)) {
            $msg = "$tool not found; skipped"
            Write-LogMessage "⊘ $Provider : $msg"
            $null = $Script:Results.Add([PSCustomObject]@{
                Provider  = $Provider
                Status    = "Skipped"
                Message   = $msg
                Duration  = [TimeSpan]::Zero
                Error     = $null
            })
            return
        }
    }

    # dry-run: log intent, skip real work
    if ($Script:IsDryRun) {
        Write-LogMessage "[DRY RUN] $Provider : $Description"
        $null = $Script:Results.Add([PSCustomObject]@{
            Provider  = $Provider
            Status    = "DryRun"
            Message   = "Would: $Description"
            Duration  = [TimeSpan]::Zero
            Error     = $null
        })
        return
    }

    Write-LogMessage "$Provider : $Description"
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $err  = $null
    $stat = "Success"
    $msg  = ""

    try {
        # Reset exit code from any prior native command to
        # prevent cross-step contamination.
        $global:LASTEXITCODE = 0
        & $Command 2>&1

        # Capture both signals immediately — before any other
        # statement resets $?.  $LASTEXITCODE is set by native
        # exes; $? catches PowerShell-native failures.
        $cmdSuccess  = $?
        $cmdExitCode = $LASTEXITCODE

        if ($cmdExitCode -ne 0) {
            throw "exited with code $cmdExitCode"
        } elseif (-not $cmdSuccess) {
            throw "PowerShell command failed"
        }

        $msg = "Done"
        Write-LogMessage "✓ $Provider : $msg"
    }
    catch {
        $stat = "Failed"
        $err  = $_
        $msg  = "$_"
        Write-LogMessage "✗ $Provider : $msg"
    }
    finally {
        $sw.Stop()
    }

    $result = [PSCustomObject]@{
        Provider  = $Provider
        Status    = $stat
        Message   = $msg
        Duration  = $sw.Elapsed
        Error     = $err
    }
    $null = $Script:Results.Add($result)

    if ($stat -eq "Failed" -and $Script:StopOnFirstError) {
        Write-LogMessage "Halting: stop-on-error is enabled."
        Write-SummaryReport
        exit 3
    }
}

# ── summary report ─────────────────────────────────────

function Write-SummaryReport {
    Write-Output ""
    Write-Output "══════ Update Summary ══════"

    if ($Script:IsDryRun) {
        Write-Output "[DRY RUN] No changes were made."
    }

    $icon = @{
        Success = "✓"
        Failed  = "✗"
        Skipped = "⊘"
        DryRun  = "○"
    }

    $outcomes = ($Script:Results | Group-Object Status -AsHashTable)

    foreach ($r in $Script:Results) {
        $dur = if ($r.Duration.TotalSeconds -ge 1) {
            " [$([int]$r.Duration.TotalSeconds)s]"
        } else { "" }
        Write-Output "  $($icon[$r.Status]) $($r.Provider) : $($r.Status)$dur"
    }

    Write-Output "───"
    Write-Output ("Total: {0}  |  ✓ Passed: {1}  |  ✗ Failed: {2}  |  ⊘ Skipped: {3}  |  ○ DryRun: {4}" -f
        $Script:Results.Count,
        ($outcomes["Success"]).Count,
        ($outcomes["Failed"]).Count,
        ($outcomes["Skipped"]).Count,
        ($outcomes["DryRun"]).Count
    )
    Write-Output "═════════════════════════════"
}

# ═══════════════════════════════════════════════════════
#  Providers
# ═══════════════════════════════════════════════════════

if (-not $SkipWinget) {
    Invoke-Step -Provider "winget" `
        -Description "Upgrading winget packages" `
        -RequiredTools @("winget") `
        -Command {
            winget upgrade --all --silent --include-unknown --accept-source-agreements
        }
}

if (-not $SkipStore) {
    Invoke-Step -Provider "Microsoft Store" `
        -Description "Upgrading Microsoft Store apps via winget (msstore)" `
        -RequiredTools @("winget") `
        -Command {
            winget upgrade --source msstore --all --silent --include-unknown --accept-source-agreements
        }
}

if (-not $SkipGit) {
    Invoke-Step -Provider "Git" `
        -Description "Updating Git for Windows" `
        -RequiredTools @("git") `
        -Command {
            git update-git-for-windows
        }
}

if (-not $SkipWsl) {
    Invoke-Step -Provider "WSL (kernel)" `
        -Description "Updating WSL kernel" `
        -RequiredTools @("wsl") `
        -Command {
            wsl --update
        }

    # Only reach apt steps if wsl is present (checked by Invoke-Step above).
    # If WSL kernel step was skipped (tool missing), apt steps skip too.
    if (Test-Command "wsl") {
        Invoke-Step -Provider "WSL (apt update)" `
            -Description "Updating WSL apt package lists" `
            -RequiredTools @("wsl") `
            -Command {
                wsl sudo apt-get update
            }

        Invoke-Step -Provider "WSL (apt upgrade)" `
            -Description "Upgrading WSL apt packages" `
            -RequiredTools @("wsl") `
            -Command {
                wsl sudo apt-get upgrade -y
            }

        Invoke-Step -Provider "WSL (apt autoremove)" `
            -Description "Removing unused WSL apt packages" `
            -RequiredTools @("wsl") `
            -Command {
                wsl sudo apt-get autoremove -y
            }
    }
}

if (-not $SkipDocker) {
    Invoke-Step -Provider "Docker (Watchtower)" `
        -Description "Updating Docker containers" `
        -RequiredTools @("docker") `
        -Command {
            docker run --rm --name watchtower `
                -v /var/run/docker.sock:/var/run/docker.sock `
                nickfedor/watchtower --run-once
        }
}

if (-not $SkipNpm) {
    Invoke-Step -Provider "npm" `
        -Description "Upgrading npm global packages" `
        -RequiredTools @("npm") `
        -Command {
            npm upgrade -g
        }
}

# ── finalize ───────────────────────────────────────────

Write-SummaryReport

$failed  = ($Script:Results | Where-Object Status -eq "Failed").Count
$success = ($Script:Results | Where-Object Status -eq "Success").Count

if ($failed -gt 0) {
    if ($success -eq 0) { exit 2 }   # everything failed
    exit 1                           # partial failure
}
exit 0                               # clean
