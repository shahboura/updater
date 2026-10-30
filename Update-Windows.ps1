<#
.SYNOPSIS
    Updates Windows system packages and developer tools.
.DESCRIPTION
    Sequentially runs updates across winget, Microsoft Store, Chocolatey, Scoop,
    Git, WSL, Docker, npm, pip, pipx, and PowerShell modules.  Each provider can
    be skipped individually with a switch parameter.
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
.PARAMETER SkipChoco
    Skip Chocolatey package upgrades.
.PARAMETER SkipScoop
    Skip Scoop package updates.
.PARAMETER SkipNpm
    Skip npm global package upgrades.
.PARAMETER SkipNpmCache
    Skip npm cache cleanup (runs after npm upgrade by default).
.PARAMETER SkipPip
    Skip pip and pipx package upgrades.
.PARAMETER SkipPSModule
    Skip PowerShell module updates.
.PARAMETER StopOnFirstError
    Halt execution on the first provider failure (default: continue).
.PARAMETER DryRun
    Show what would be updated without making changes.
.PARAMETER LogPath
    Path to write a log file. Timestamped output is appended.
.PARAMETER Config
    Path to a JSON config file with skip preferences.  Auto-loads
    update-config.json from the script directory if present.
    Command-line parameters always take precedence.
.EXAMPLE
    .\Update-Windows.ps1
.EXAMPLE
    .\Update-Windows.ps1 -SkipWsl -SkipDocker -SkipChoco
.EXAMPLE
    .\Update-Windows.ps1 -LogPath "$env:TEMP\update.log"
.EXAMPLE
    .\Update-Windows.ps1 -DryRun
.EXAMPLE
    .\Update-Windows.ps1 -Config "$env:USERPROFILE\.update-config.json"
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipWsl,
    [switch]$SkipGit,
    [switch]$SkipDocker,
    [switch]$SkipWinget,
    [switch]$SkipStore,
    [switch]$SkipChoco,
    [switch]$SkipScoop,
    [switch]$SkipNpm,
    [switch]$SkipNpmCache,
    [switch]$SkipPip,
    [switch]$SkipPSModule,
    [switch]$StopOnFirstError,
    [switch]$DryRun,
    [string]$LogPath,
    [string]$Config
)

$ErrorActionPreference = "Continue"
$Script:LogFilePath      = $LogPath
$Script:Results          = [System.Collections.Generic.List[PSCustomObject]]::new()
$Script:IsDryRun         = $DryRun -or $WhatIfPreference
$Script:StopOnFirstError = $StopOnFirstError

# ── config file ──────────────────────────────────────────

$configPath = if ($Config) {
    $Config
} elseif (Test-Path "$PSScriptRoot\update-config.json") {
    "$PSScriptRoot\update-config.json"
} else {
    $null
}

if ($configPath) {
    try {
        $configData = Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $allowedKeys = @(
            'SkipWsl', 'SkipGit', 'SkipDocker', 'SkipWinget', 'SkipStore',
            'SkipChoco', 'SkipScoop', 'SkipNpm', 'SkipNpmCache', 'SkipPip', 'SkipPSModule'
        )
        foreach ($prop in $configData.PSObject.Properties) {
            if ($prop.Name -notin $allowedKeys) {
                Write-Warning "Ignoring unrecognized config key: $($prop.Name)"
                continue
            }
            if ($PSBoundParameters.ContainsKey($prop.Name)) { continue }
            Set-Variable -Name $prop.Name -Value ($prop.Value -as [bool])
        }
    }
    catch {
        Write-Warning "Could not load config '$configPath': $_"
    }
}

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

function Add-StepResult {
    param(
        [string]$Provider,
        [string]$Status,
        [string]$Message,
        [TimeSpan]$Duration = [TimeSpan]::Zero
    )
    $null = $Script:Results.Add([PSCustomObject]@{
        Provider = $Provider
        Status   = $Status
        Message  = $Message
        Duration = $Duration
    })
}

# ── core execution wrapper ─────────────────────────────

function Invoke-Step {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Provider,
        [Parameter(Mandatory)]
        [string]$Description,
        [Parameter(Mandatory)]
        [scriptblock]$Command,
        [string[]]$RequiredTools = @(),
        [string]$Hint = ""
    )

    # pre-flight: check that every required tool is on PATH
    foreach ($tool in $RequiredTools) {
        if (-not (Test-Command $tool)) {
            $msg = if ($Hint) { "$tool not found; skipped ($Hint)" } else { "$tool not found; skipped" }
            Write-LogMessage "⊘ $Provider : $msg"
            Add-StepResult $Provider "Skipped" $msg
            return
        }
    }

    # dry-run: log intent, skip real work
    if ($Script:IsDryRun) {
        Write-LogMessage "[DRY RUN] $Provider : $Description"
        Add-StepResult $Provider "DryRun" "Would: $Description"
        return
    }

    Write-LogMessage "$Provider : $Description"
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $stat = "Success"
    $msg  = ""

    try {
        $global:LASTEXITCODE = 0
        & $Command 2>&1

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
        $msg  = "$_"
        Write-LogMessage "✗ $Provider : $msg"
    }
    finally {
        $sw.Stop()
    }

    Add-StepResult $Provider $stat $msg $sw.Elapsed

    if ($stat -eq "Failed" -and $Script:StopOnFirstError) {
        Write-LogMessage "Halting: stop-on-error is enabled."
        Write-SummaryReport
        exit 3
    }

    # Success/failure is recorded in $Script:Results above; no return value.
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

    # repeat the failures here so the user does not have to scroll back
    $failedSteps = @($Script:Results | Where-Object Status -eq "Failed")
    if ($failedSteps) {
        Write-Output "───"
        Write-Output "Failures:"
        foreach ($r in $failedSteps) {
            Write-Output "  ✗ $($r.Provider) : $($r.Message)"
        }
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

Write-LogMessage "Update started on $env:COMPUTERNAME (dry run: $Script:IsDryRun)"

# ── winget ─────────────────────────────────────────────

if (-not $SkipWinget) {
    Invoke-Step -Provider "winget" -Description "Upgrading winget packages" -RequiredTools "winget" `
        -Command { winget upgrade --all --silent --include-unknown --accept-source-agreements }
}

# ── Microsoft Store ────────────────────────────────────

if (-not $SkipStore) {
    Invoke-Step -Provider "Microsoft Store" -Description "Upgrading Microsoft Store apps via winget (msstore)" -RequiredTools "winget" `
        -Command { winget upgrade --source msstore --all --silent --include-unknown --accept-source-agreements }
}

# ── Chocolatey ─────────────────────────────────────────

if (-not $SkipChoco) {
    Invoke-Step -Provider "Chocolatey" -Description "Upgrading Chocolatey packages" -RequiredTools "choco" `
        -Command { choco upgrade all -y --limit-output }
}

# ── Scoop ──────────────────────────────────────────────

if (-not $SkipScoop) {
    Invoke-Step -Provider "Scoop" -Description "Updating Scoop buckets and packages" -RequiredTools "scoop" `
        -Command { scoop update; scoop update * }
}

# ── Git ────────────────────────────────────────────────

if (-not $SkipGit) {
    Invoke-Step -Provider "Git" -Description "Updating Git for Windows" -RequiredTools "git" `
        -Command { git update-git-for-windows }
}

# ── WSL ────────────────────────────────────────────────
#  Each step skips itself when wsl.exe is missing, so no outer guard is needed.

if (-not $SkipWsl) {
    Invoke-Step -Provider "WSL (kernel)" -Description "Updating WSL kernel" -RequiredTools "wsl" `
        -Command { wsl --update }
    Invoke-Step -Provider "WSL (apt update)" -Description "Updating WSL apt package lists" -RequiredTools "wsl" `
        -Command { wsl sudo apt-get update }
    Invoke-Step -Provider "WSL (apt upgrade)" -Description "Upgrading WSL apt packages" -RequiredTools "wsl" `
        -Command { wsl sudo apt-get upgrade -y }
    Invoke-Step -Provider "WSL (apt autoremove)" -Description "Removing unused WSL apt packages" -RequiredTools "wsl" `
        -Command { wsl sudo apt-get autoremove -y }
}

# ── Docker ─────────────────────────────────────────────

if (-not $SkipDocker) {
    # WARNING: Mounting the Docker socket grants the container
    # root-equivalent host access.  Verify the image digest if
    # running in a trusted environment.
    # Pin a specific digest for production use:
    #   nickfedor/watchtower@sha256:<digest>
    Invoke-Step -Provider "Docker (Watchtower)" -Description "Updating Docker containers" -RequiredTools "docker" `
        -Command {
            docker run --rm --name watchtower `
                -v /var/run/docker.sock:/var/run/docker.sock `
                nickfedor/watchtower:1 --run-once
        }
}

# ── npm ────────────────────────────────────────────────

if (-not $SkipNpm) {
    $npmOk = $false

    # Global npm packages often live in a system-owned location (e.g.
    # C:\Program Files\nodejs) that requires an elevated shell to write to.
    # Detect that case up front and skip gracefully instead of surfacing a raw
    # EPERM error from npm.
    $npmPrefix       = (npm root -g 2>$null | Select-Object -First 1)
    $isElevated      = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $prefixProtected = $npmPrefix -and ($npmPrefix -like "$env:ProgramFiles*")

    if (-not $isElevated -and $prefixProtected) {
        $msg = "global prefix '$npmPrefix' requires an elevated (Administrator) shell; skipped"
        Write-LogMessage "⊘ npm : $msg"
        Add-StepResult "npm" "Skipped" $msg
    } else {
        Invoke-Step -Provider "npm" -Description "Upgrading npm global packages" -RequiredTools "npm" `
            -Command { npm upgrade -g }
        $npmOk = $Script:Results[$Script:Results.Count - 1].Status -in @("Success", "DryRun")
    }

    # clean the cache unless npm failed or was skipped
    if ($npmOk -and -not $SkipNpmCache) {
        Invoke-Step -Provider "npm (cache)" -Description "Cleaning npm cache" -RequiredTools "npm" `
            -Command { npm cache clean --force }
    }
}

# ── pip / pipx ─────────────────────────────────────────

if (-not $SkipPip) {
    Invoke-Step -Provider "pip" -Description "Upgrading pip" -RequiredTools "python" `
        -Command { python -m pip install --upgrade pip }
    Invoke-Step -Provider "pip (user packages)" -Description "Upgrading pip user packages" -RequiredTools "pip-review" `
        -Hint "install with: pip install pip-review" -Command { pip-review --auto }
    Invoke-Step -Provider "pipx" -Description "Upgrading pipx packages" -RequiredTools "pipx" `
        -Hint "install with: python -m pip install pipx" -Command { pipx upgrade-all }
}

# ── PowerShell modules ─────────────────────────────────

if (-not $SkipPSModule) {
    Invoke-Step -Provider "PowerShell modules" -Description "Updating PowerShell modules" `
        -Command { Update-Module -Force -ErrorAction SilentlyContinue }
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
