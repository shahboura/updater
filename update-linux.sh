#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────
#  update-linux.sh  –  System updater for Ubuntu / Debian
# ──────────────────────────────────────────────────────────
#  Updates apt, snap, flatpak, npm, pip, pipx, Docker
#  containers, and firmware in one pass.  Each provider
#  can be skipped individually.
#
#  Exit codes: 0 = all ok  1 = partial failure
#              2 = all failed  3 = halted early
# ──────────────────────────────────────────────────────────
set -o pipefail

# ── defaults ─────────────────────────────────────────────

SKIP_APT=false
SKIP_SNAP=false
SKIP_FLATPAK=false
SKIP_NPM=false
SKIP_PIP=false
SKIP_PIPX=false
SKIP_DOCKER=false
SKIP_FIRMWARE=false
DRY_RUN=false
STOP_ON_ERROR=false
LOG_PATH=""
RESULTS=()

# ── helpers ──────────────────────────────────────────────

log_message() {
    local line
    line="[$(date +%H:%M:%S)] $*"
    echo "$line"
    [[ -n "$LOG_PATH" ]] && echo "$line" >> "$LOG_PATH"
}

command_exists() {
    command -v "$1" &>/dev/null
}

# ── core step runner ─────────────────────────────────────
#  Usage:
#    run_step <provider> <description> <req-tools> <cmd> [arg ...]
#
#  <req-tools> is a space-separated string of executables that
#  must be on PATH.  Pass an empty string ("") for no checks.
#  The step is skipped if any required tool is missing.

run_step() {
    local provider="$1"
    local description="$2"
    local req_tools="$3"
    shift 3
    local -a cmd=("$@")

    # pre-flight: every required tool must exist
    for tool in $req_tools; do
        [[ -n "$tool" ]] || continue
        if ! command_exists "$tool"; then
            local msg="$tool not found; skipped"
            log_message "⊘ $provider : $msg"
            RESULTS+=("$provider|Skipped|$msg|0|")
            return 0
        fi
    done

    # dry-run
    if [[ "$DRY_RUN" == "true" ]]; then
        log_message "[DRY RUN] $provider : $description"
        RESULTS+=("$provider|DryRun|Would: $description|0|")
        return 0
    fi

    log_message "$provider : $description"
    local start=$SECONDS
    local status="Success"
    local message=""
    local error=""

    # execute — output flows to terminal so the user sees progress
    local rc=0
    "${cmd[@]}" 2>&1 || rc=$?

    if [[ $rc -ne 0 ]]; then
        status="Failed"
        error="exited with code $rc"
        message="$error"
        log_message "✗ $provider : $message"
    else
        message="Done"
        log_message "✓ $provider : $message"
    fi

    local duration=$((SECONDS - start))
    # encode pipe characters so they don't break the delimiter
    local safe_msg="${message//|/¦}"
    local safe_err="${error//|/¦}"
    RESULTS+=("$provider|$status|$safe_msg|$duration|$safe_err")

    if [[ "$status" == "Failed" && "$STOP_ON_ERROR" == "true" ]]; then
        log_message "Halting: stop-on-error is enabled."
        print_summary
        exit 3
    fi
}

# ── summary report ───────────────────────────────────────

print_summary() {
    echo ""
    echo "══════ Update Summary ══════"

    [[ "$DRY_RUN" == "true" ]] && echo "[DRY RUN] No changes were made."

    local -A icon=(
        [Success]="✓"
        [Failed]="✗"
        [Skipped]="⊘"
        [DryRun]="○"
    )

    local passed=0 failed=0 skipped=0 dry=0 total=0

    for entry in "${RESULTS[@]}"; do
        IFS='|' read -r provider status msg duration err <<< "$entry"
        local dur_str=""
        [[ "$duration" =~ ^[0-9]+$ && "$duration" -gt 0 ]] && dur_str=" [${duration}s]"
        echo "  ${icon[$status]:-?} $provider : $status$dur_str"
        ((total++))
        case "$status" in
            Success) ((passed++)) ;;
            Failed)  ((failed++)) ;;
            Skipped) ((skipped++)) ;;
            DryRun)  ((dry++)) ;;
        esac
    done

    echo "───"
    echo "Total: $total  |  ✓ Passed: $passed  |  ✗ Failed: $failed  |  ⊘ Skipped: $skipped  |  ○ DryRun: $dry"
    echo "═════════════════════════════"
}

# ── usage ────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: update-linux.sh [OPTIONS]

Options:
  --skip-apt         Skip apt package upgrades
  --skip-snap        Skip snap package refreshes
  --skip-flatpak     Skip flatpak package updates
  --skip-npm         Skip npm global package upgrades
  --skip-pip         Skip pip user package upgrades
  --skip-pipx        Skip pipx package upgrades
  --skip-docker      Skip Docker container updates (Watchtower)
  --skip-firmware    Skip firmware updates (fwupd)
  --dry-run          Preview without making changes
  --log-path PATH    Write log to PATH (appended)
  --stop-on-error    Halt on first failure
  -h, --help         Show this help

Exit codes: 0=all ok  1=partial  2=all failed  3=halted
EOF
    exit 0
}

# ── parse args ───────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-apt)       SKIP_APT=true ;;
        --skip-snap)      SKIP_SNAP=true ;;
        --skip-flatpak)   SKIP_FLATPAK=true ;;
        --skip-npm)       SKIP_NPM=true ;;
        --skip-pip)       SKIP_PIP=true ;;
        --skip-pipx)      SKIP_PIPX=true ;;
        --skip-docker)    SKIP_DOCKER=true ;;
        --skip-firmware)  SKIP_FIRMWARE=true ;;
        --dry-run)        DRY_RUN=true ;;
        --stop-on-error)  STOP_ON_ERROR=true ;;
        --log-path)       LOG_PATH="$2"; shift ;;
        -h|--help)        usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
    shift
done

# ── require bash 4+ (associative arrays) ─────────────────

if ((BASH_VERSINFO[0] < 4)); then
    echo "bash 4.0+ required (found $BASH_VERSION)" >&2
    exit 2
fi

# ══════════════════════════════════════════════════════════
#  Providers
# ══════════════════════════════════════════════════════════

# ── apt ──────────────────────────────────────────────────

if [[ "$SKIP_APT" != "true" ]]; then
    run_step "apt (update)"      "Updating apt package lists"    "sudo apt-get" sudo apt-get update
    run_step "apt (upgrade)"     "Upgrading apt packages"        "sudo apt-get" sudo apt-get upgrade -y
    run_step "apt (autoremove)"  "Removing unused apt packages"   "sudo apt-get" sudo apt-get autoremove -y
fi

# ── snap ─────────────────────────────────────────────────
# Note: may report a non-fatal failure if the snap daemon is
# already running an auto-refresh.  The system is still updating.

if [[ "$SKIP_SNAP" != "true" ]]; then
    run_step "snap" "Refreshing snap packages" "snap sudo" sudo snap refresh
fi

# ── flatpak ──────────────────────────────────────────────

if [[ "$SKIP_FLATPAK" != "true" ]]; then
    run_step "flatpak" "Updating flatpak packages" "flatpak" flatpak update -y
fi

# ── npm ──────────────────────────────────────────────────

if [[ "$SKIP_NPM" != "true" ]]; then
    run_step "npm" "Upgrading npm global packages" "npm" npm upgrade -g
fi

# ── pip ──────────────────────────────────────────────────

if [[ "$SKIP_PIP" != "true" ]]; then
    run_step "pip (self)" "Upgrading pip" "python3" python3 -m pip install --upgrade pip
    if command_exists pip-review; then
        run_step "pip (pkgs)" "Upgrading pip user packages" "pip-review" pip-review --auto
    else
        log_message "⊘ pip (pkgs) : pip-review not found; skipped (install with: pip install pip-review)"
    fi
fi

# ── pipx ─────────────────────────────────────────────────

if [[ "$SKIP_PIPX" != "true" ]]; then
    run_step "pipx" "Upgrading pipx packages" "pipx" pipx upgrade-all
fi

# ── Docker ───────────────────────────────────────────────

if [[ "$SKIP_DOCKER" != "true" ]]; then
    run_step "Docker (Watchtower)" "Updating Docker containers" "docker" \
        docker run --rm --name watchtower \
            -v /var/run/docker.sock:/var/run/docker.sock \
            nickfedor/watchtower --run-once
fi

# ── firmware ─────────────────────────────────────────────

if [[ "$SKIP_FIRMWARE" != "true" ]]; then
    run_step "firmware (refresh)" "Refreshing firmware metadata" "fwupdmgr" fwupdmgr refresh
    run_step "firmware (update)"  "Updating firmware"          "fwupdmgr" fwupdmgr update -y
fi

# ── finalize ─────────────────────────────────────────────

print_summary

failed=0
success=0
for entry in "${RESULTS[@]}"; do
    IFS='|' read -r _ status _ _ _ <<< "$entry"
    [[ "$status" == "Failed" ]]  && ((failed++))
    [[ "$status" == "Success" ]] && ((success++))
done

if ((failed > 0)); then
    if ((success == 0)); then exit 2; fi   # everything failed
    exit 1                                   # partial failure
fi
exit 0                                       # clean
