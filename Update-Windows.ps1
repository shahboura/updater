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
        $configData = Get-Content $configPath -Raw | ConvertFrom-Json
        foreach ($prop in $configData.PSObject.Properties) {
            if ($PSBoundParameters.ContainsKey($prop.Name)) { continue }
            Set-Variable -Name $prop.Name -Value $prop.Value
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
            return $false
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
        return $false
    }

    Write-LogMessage "$Provider : $Description"
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $err  = $null
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

    return ($stat -eq "Success")
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

# ── winget ─────────────────────────────────────────────

if (-not $SkipWinget) {
    $params = @{
        Provider      = "winget"
        Description   = "Upgrading winget packages"
        RequiredTools = @("winget")
        Command       = { winget upgrade --all --silent --include-unknown --accept-source-agreements }
    }
    Invoke-Step @params
}

# ── Microsoft Store ────────────────────────────────────

if (-not $SkipStore) {
    $params = @{
        Provider      = "Microsoft Store"
        Description   = "Upgrading Microsoft Store apps via winget (msstore)"
        RequiredTools = @("winget")
        Command       = { winget upgrade --source msstore --all --silent --include-unknown --accept-source-agreements }
    }
    Invoke-Step @params
}

# ── Chocolatey ─────────────────────────────────────────

if (-not $SkipChoco) {
    $params = @{
        Provider      = "Chocolatey"
        Description   = "Upgrading Chocolatey packages"
        RequiredTools = @("choco")
        Command       = { choco upgrade all -y --limit-output }
    }
    Invoke-Step @params
}

# ── Scoop ──────────────────────────────────────────────

if (-not $SkipScoop) {
    $params = @{
        Provider      = "Scoop"
        Description   = "Updating Scoop buckets and packages"
        RequiredTools = @("scoop")
        Command       = { scoop update; scoop update * }
    }
    Invoke-Step @params
}

# ── Git ────────────────────────────────────────────────

if (-not $SkipGit) {
    $params = @{
        Provider      = "Git"
        Description   = "Updating Git for Windows"
        RequiredTools = @("git")
        Command       = { git update-git-for-windows }
    }
    Invoke-Step @params
}

# ── WSL ────────────────────────────────────────────────

if (-not $SkipWsl) {
    $params = @{
        Provider      = "WSL (kernel)"
        Description   = "Updating WSL kernel"
        RequiredTools = @("wsl")
        Command       = { wsl --update }
    }
    Invoke-Step @params

    if (Test-Command "wsl") {
        $params = @{
            Provider      = "WSL (apt update)"
            Description   = "Updating WSL apt package lists"
            RequiredTools = @("wsl")
            Command       = { wsl sudo apt-get update }
        }
        Invoke-Step @params

        $params = @{
            Provider      = "WSL (apt upgrade)"
            Description   = "Upgrading WSL apt packages"
            RequiredTools = @("wsl")
            Command       = { wsl sudo apt-get upgrade -y }
        }
        Invoke-Step @params

        $params = @{
            Provider      = "WSL (apt autoremove)"
            Description   = "Removing unused WSL apt packages"
            RequiredTools = @("wsl")
            Command       = { wsl sudo apt-get autoremove -y }
        }
        Invoke-Step @params
    }
}

# ── Docker ─────────────────────────────────────────────

if (-not $SkipDocker) {
    $params = @{
        Provider      = "Docker (Watchtower)"
        Description   = "Updating Docker containers"
        RequiredTools = @("docker")
        Command       = {
            docker run --rm --name watchtower `
                -v /var/run/docker.sock:/var/run/docker.sock `
                nickfedor/watchtower --run-once
        }
    }
    Invoke-Step @params
}

# ── npm ────────────────────────────────────────────────

if (-not $SkipNpm) {
    $params = @{
        Provider      = "npm"
        Description   = "Upgrading npm global packages"
        RequiredTools = @("npm")
        Command       = { npm upgrade -g }
    }
    $npmOk = Invoke-Step @params

    if ($npmOk -and -not $SkipNpmCache) {
        $params = @{
            Provider      = "npm (cache)"
            Description   = "Cleaning npm cache"
            RequiredTools = @("npm")
            Command       = { npm cache clean --force }
        }
        Invoke-Step @params
    }
}

# ── pip / pipx ─────────────────────────────────────────

if (-not $SkipPip) {
    $params = @{
        Provider      = "pip"
        Description   = "Upgrading pip"
        RequiredTools = @("python")
        Command       = { python -m pip install --upgrade pip }
    }
    Invoke-Step @params

    if (Test-Command "pip-review") {
        $params = @{
            Provider      = "pip (user packages)"
            Description   = "Upgrading pip user packages"
            RequiredTools = @("pip-review")
            Command       = { pip-review --auto }
        }
        Invoke-Step @params
    } else {
        Write-LogMessage "⊘ pip (user packages) : pip-review not found; skipped (install with: pip install pip-review)"
        $null = $Script:Results.Add([PSCustomObject]@{
            Provider  = "pip (user packages)"
            Status    = "Skipped"
            Message   = "pip-review not found"
            Duration  = [TimeSpan]::Zero
            Error     = $null
        })
    }

    if (Test-Command "pipx") {
        $params = @{
            Provider      = "pipx"
            Description   = "Upgrading pipx packages"
            RequiredTools = @("pipx")
            Command       = { pipx upgrade-all }
        }
        Invoke-Step @params
    }
}

# ── PowerShell modules ─────────────────────────────────

if (-not $SkipPSModule) {
    $params = @{
        Provider      = "PowerShell modules"
        Description   = "Updating PowerShell modules"
        RequiredTools = @()
        Command       = { Update-Module -Force -ErrorAction SilentlyContinue }
    }
    Invoke-Step @params
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
