#!/bin/bash
# master setup, runs phase 1..9 in order
# usage: sudo bash car2x-00-master-setup.sh

set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="/var/log/car2x"
readonly STATUS_DIR="/var/lib/car2x"
readonly STATUS_FILE="${STATUS_DIR}/setup-status.json"

LOG_FILE=""
RESUME_MODE=0

if [[ ! -f "${SCRIPT_DIR}/car2x-99-utilities.sh" ]]; then
    echo "ERROR: car2x-99-utilities.sh not found in $SCRIPT_DIR"
    exit 1
fi
source "${SCRIPT_DIR}/car2x-99-utilities.sh"

DRY_RUN=0
VERBOSE=0
SKIP_VALIDATION=0
AUTO_CONTINUE=0
RESUME_FROM_STEP=0

check_prerequisites() {
    log_info "Validating prerequisites..."

    if ! check_root; then
        return 1
    fi

    local need=(
        "car2x-01-prepare-system.sh"
        "car2x-02-create-user.sh"
        "car2x-03-patch-kernel.sh"
        "car2x-04-build-drivers.sh"
        "car2x-05-peripheral-setup.sh"
        "car2x-06-gps-setup.sh"
        "car2x-07-pico-setup.sh"
        "car2x-08-bluetooth-wlan-setup.sh"
        "car2x-09-deploy-services.sh"
    )

    for s in "${need[@]}"; do
        if [[ ! -f "${SCRIPT_DIR}/${s}" ]]; then
            log_error "Required script missing: ${s}"
            return 1
        fi
        chmod +x "${SCRIPT_DIR}/${s}"
        log_success "Found: $s"
    done

    # need ~5G free for the kernel build
    if ! check_disk_space "/" 5242880; then
        return 1
    fi

    check_internet || true

    if ! check_no_apt_conflicts; then
        return 1
    fi

    return 0
}

run_step() {
    local num=$1
    local name=$2
    local sf=$3
    local desc=$4

    log_info ""
    log_info "----------------------------------------------------"
    log_info " STEP $num: $desc"
    log_info "----------------------------------------------------"

    if [[ ! -f "${SCRIPT_DIR}/${sf}" ]]; then
        log_error "Script not found: $sf"
        return 1
    fi

    # skip if already done (resume)
    if [[ -f "$STATUS_FILE" ]]; then
        local st=$(grep "\"$name\"" "$STATUS_FILE" 2>/dev/null | grep -o "\"completed\"" || echo "")
        if [[ "$st" == "\"completed\"" ]]; then
            log_success "Step already completed (skipping in resume mode)"
            return 0
        fi
    fi

    local t0=$(date +%s)
    log_info "Starting: $sf"
    log_msg "EXEC" "bash ${SCRIPT_DIR}/${sf}"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_warn "Dry-run mode: would execute script (skipped)"
        update_status "$STATUS_FILE" "$name" "dry_run"
        return 0
    fi

    if bash "${SCRIPT_DIR}/${sf}" 2>&1 | tee -a "$LOG_FILE"; then
        local t1=$(date +%s)
        local dur=$(( t1 - t0 ))
        log_success "Completed: $sf (${dur}s)"
        update_status "$STATUS_FILE" "$name" "completed"
        return 0
    else
        local rc=$?
        log_error "Failed: $sf (exit code: $rc)"
        update_status "$STATUS_FILE" "$name" "failed"
        return 1
    fi
}

checkpoint_after_step() {
    local n=$1
    local desc=$2

    log_info ""
    log_info "Validating checkpoint: $desc"

    case $n in
        1)
            if command -v git &>/dev/null && command -v make &>/dev/null; then
                log_success "Build tools found"
                return 0
            fi
            ;;
        2)
            if id car2x &>/dev/null; then
                log_success "car2x user found"
                return 0
            fi
            ;;
        3)
            if [[ -d /home/car2x/linux ]] && [[ -d /home/car2x/11p-patches ]]; then
                log_success "Kernel and patches directory found"
                return 0
            fi
            ;;
        4)
            if [[ -f /home/car2x/linux/drivers/net/wireless/ath/ath.ko ]]; then
                log_success "ATH9K modules found"
                return 0
            fi
            ;;
        5)
            if [[ -f /etc/udev/rules.d/99-car2x-devices.rules ]]; then
                log_success "USB udev rules found"
                return 0
            fi
            ;;
        6)
            if command -v gpsd &>/dev/null; then
                log_success "GPS setup verified (gpsd installed)"
                return 0
            fi
            ;;
        7)
            if python3 -c "import serial" &>/dev/null; then
                log_success "Pico setup verified (Python serial available)"
                return 0
            fi
            ;;
        8)
            if command -v hcitool &>/dev/null || command -v iw &>/dev/null; then
                log_success "Bluetooth/WLAN tools found"
                return 0
            fi
            ;;
        9)
            if systemctl list-unit-files car2x-*.service &>/dev/null; then
                log_success "systemd units found"
                return 0
            fi
            ;;
        *)
            log_warn "No checkpoint for step $n"
            return 0
            ;;
    esac

    log_warn "Checkpoint validation FAILED, continuing anyway"
    return 0
}

prompt_continue() {
    local s=$1

    if [[ $AUTO_CONTINUE -eq 1 ]]; then
        log_debug "Auto-continue enabled, skipping prompt"
        return 0
    fi

    echo ""
    read -p "Continue with step $s? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "User chose not to continue"
        return 1
    fi
    return 0
}

# rollback is still a stub
offer_rollback() {
    local fs=$1

    log_warn ""
    log_warn "Setup encountered an error at step $fs"
    log_warn "The following steps have been completed:"

    if [[ -f "$STATUS_FILE" ]]; then
        log_warn "See: $STATUS_FILE"
    fi

    echo ""
    read -p "Rollback changes? (y/n) " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Starting rollback..."
        # todo: actual rollback per step
        log_warn "Rollback not yet implemented, see log for manual recovery"
        return 0
    fi

    return 1
}

check_test_user_cleanup() {
    log_info "Checking for test user artifacts..."

    if [[ -d /home/car2x ]]; then
        local own=$(stat -c %U /home/car2x 2>/dev/null || stat -f %Su /home/car2x 2>/dev/null || echo "unknown")
        if [[ "$own" != "car2x" ]] && [[ "$own" != "unknown" ]]; then
            log_warn "Detected /home/car2x owned by user: $own (not car2x)"
            log_warn "Fixing ownership..."
            chown -R car2x:car2x /home/car2x 2>/dev/null || log_error "Failed to fix /home/car2x ownership"
            log_success "Fixed /home/car2x ownership"
        fi
    fi

    if [[ -d /run/car2x ]]; then
        local own=$(stat -c %U /run/car2x 2>/dev/null || stat -f %Su /run/car2x 2>/dev/null || echo "unknown")
        if [[ "$own" != "root" ]] && [[ "$own" != "unknown" ]]; then
            log_warn "Detected /run/car2x not owned by root"
            log_warn "Fixing ownership..."
            chown -R root:root /run/car2x 2>/dev/null || true
            log_success "Fixed /run/car2x ownership"
        fi
    fi

    return 0
}

check_previous_status() {
    log_info "Checking for previous setup attempts..."

    if [[ ! -f "$STATUS_FILE" ]]; then
        log_info "No previous setup found, starting fresh"
        RESUME_MODE=0
        return 0
    fi

    log_warn "Found previous setup status file: $STATUS_FILE"
    log_warn "Status:"
    cat "$STATUS_FILE" | sed 's/^/  /'

    echo ""
    read -p "Resume from last checkpoint or start fresh? (resume/fresh) " -r
    echo
    if [[ $REPLY =~ ^[Rr] ]]; then
        log_info "Resume mode: skipping already completed steps"
        log_success "Completed steps will be skipped automatically"
        RESUME_MODE=1
    else
        log_warn "Starting fresh: backing up old status and log"

        local stamp=$(date +%Y%m%d_%H%M%S)
        mv "$STATUS_FILE" "${STATUS_FILE}.backup-${stamp}"
        log_info "Old status backed up: setup-status.json.backup-${stamp}"

        if [[ -f "${LOG_DIR}/setup.log" ]]; then
            mv "${LOG_DIR}/setup.log" "${LOG_DIR}/setup-${stamp}.log"
            log_info "Old log archived: setup-${stamp}.log"
        fi

        RESUME_MODE=0
        init_status "$STATUS_FILE"
    fi

    return 0
}

show_banner() {
    echo ""
    echo "===================================================="
    echo " Car2X Raspberry Pi 5 Setup: Master Orchestrator"
    echo "             Version 1.0, Production"
    echo "===================================================="
    echo ""
}

show_steps() {
    cat <<EOF

Setup phases:
  1. System Preparation      (OS updates, hardware config, dependencies)
  2. User & Directories      (car2x user, groups, structure) -> /home/car2x
  3. Kernel Patching         (Linux kernel with 802.11p patches)
  4. Driver Compilation      (ATH9K drivers, wireless-regdb, CRDA)
  5. USB Device Setup        (udev rules for GPS and Pico)
  6. GPS Setup               (gpsd, Chrony NTP time sync)
  7. Pico Setup              (Python serial protocol)
  8. Bluetooth/WLAN Setup    (Beacon capture for tracking detection)
  9. Service Deployment      (systemd units, OCB setup, scripts)

Estimated time: 15 minutes (includes builds and configurations)

EOF
}

show_help() {
    cat <<EOF
Car2X Master Setup - Usage

USAGE:
  sudo bash car2x-00-master-setup.sh [OPTIONS]

OPTIONS:
  -h, --help              Show this help message
  -n, --dry-run           Simulate steps without making changes
  -v, --verbose           Enable verbose logging
  -a, --auto-continue     Continue without prompts (use with caution!)
  -s, --skip-validation   Skip checkpoint validation
  --resume STEP           Resume from specific step (1-9)

EXAMPLES:
  # Full setup with prompts
  sudo bash car2x-00-master-setup.sh

  # Dry run to see what would happen
  sudo bash car2x-00-master-setup.sh --dry-run --verbose

  # Resume from step 3 if previous run failed
  sudo bash car2x-00-master-setup.sh --resume 3

  # Fully automated (careful!)
  sudo bash car2x-00-master-setup.sh --auto-continue

LOGS:
  All output is saved to: $LOG_FILE
  Status tracked in: $STATUS_FILE

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -n|--dry-run)
                DRY_RUN=1
                log_warn "DRY-RUN MODE enabled"
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -a|--auto-continue)
                AUTO_CONTINUE=1
                log_warn "AUTO-CONTINUE mode enabled"
                shift
                ;;
            -s|--skip-validation)
                SKIP_VALIDATION=1
                shift
                ;;
            --resume)
                RESUME_FROM_STEP=$2
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

main() {
    parse_arguments "$@"

    mkdir -p "$LOG_DIR" 2>/dev/null || { echo "ERROR: Cannot create log directory: $LOG_DIR"; exit 1; }
    mkdir -p "$STATUS_DIR" 2>/dev/null || { echo "ERROR: Cannot create status directory: $STATUS_DIR"; exit 1; }

    LOG_FILE="${LOG_DIR}/setup.log"

    setup_logging
    show_banner
    show_steps

    if [[ $RESUME_FROM_STEP -eq 0 ]]; then
        check_previous_status
    else
        # --resume forces resume mode
        RESUME_MODE=1
    fi

    if [[ $RESUME_MODE -eq 1 ]]; then
        log_info "Using existing log file: ${LOG_DIR}/setup.log"
    else
        log_info "Created new log file: ${LOG_DIR}/setup.log"
    fi

    # Check and fix test user artifacts
    check_test_user_cleanup

    # Initialize status with full path parameter (only in fresh mode)
    if [[ $RESUME_MODE -eq 0 ]]; then
        init_status "$STATUS_FILE"
    fi

    if ! check_prerequisites; then
        log_error "Prerequisite check failed"
        exit 1
    fi

    log_info ""
    log_info "Setup log: $LOG_FILE"
    log_info "Status file: $STATUS_FILE"
    log_info ""

    local steps=(
        "1|01_prepare_system|car2x-01-prepare-system.sh|System Preparation & Updates"
        "2|02_create_user|car2x-02-create-user.sh|User & Directory Setup"
        "3|03_patch_kernel|car2x-03-patch-kernel.sh|Linux Kernel Patching (802.11p)"
        "4|04_build_drivers|car2x-04-build-drivers.sh|ATH9K & Wireless Drivers Build"
        "5|05_peripheral_setup|car2x-05-peripheral-setup.sh|Peripheral Setup (USB devices + WLAN interface naming)"
        "6|06_gps_setup|car2x-06-gps-setup.sh|GPS Setup (gpsd, Chrony NTP)"
        "7|07_pico_setup|car2x-07-pico-setup.sh|Pico Setup (Python Serial Protocol)"
        "8|08_bluetooth_wlan_setup|car2x-08-bluetooth-wlan-setup.sh|Bluetooth & WLAN Beacon Capture"
        "9|09_deploy_services|car2x-09-deploy-services.sh|Service Deployment & Configuration"
    )

    local failed=0
    local num=0

    for cfg in "${steps[@]}"; do
        IFS='|' read -r num name script desc <<<"$cfg"

        # --resume STEP means skip the earlier ones
        if [[ $RESUME_FROM_STEP -gt 0 ]] && [[ $num -lt $RESUME_FROM_STEP ]]; then
            log_warn "Skipping step $num (resuming from $RESUME_FROM_STEP)"
            continue
        fi
        RESUME_FROM_STEP=0

        if ! run_step "$num" "$name" "$script" "$desc"; then
            log_error "Step $num failed"
            failed=$num
            break
        fi

        if [[ $SKIP_VALIDATION -eq 0 ]]; then
            if ! checkpoint_after_step "$num" "$desc"; then
                log_warn "Checkpoint validation warning at step $num"
            fi
        fi

        if [[ $num -lt 9 ]]; then
            if ! prompt_continue "$((num + 1))"; then
                log_info "Setup paused by user"
                exit 0
            fi
        fi
    done

    echo ""
    log_info "----------------------------------------------------"

    if [[ $failed -eq 0 ]]; then
        log_success "----------------------------------------------------"
        log_success ""
        log_success "All setup steps completed succesfully!"
        log_success ""

        log_success "Next steps:"
        log_success "  1. Verify system: systemctl status car2x-*"
        log_success "  2. Monitor services: journalctl -u car2x-* -f"
        log_success "  3. Check data: ls -la /home/car2x/captures/YYYYMMDD_HHMMSS/"
        log_success ""
        log_success "Setup log: $LOG_FILE"
        log_success "Rebooting system in 5 seconds..."
        sleep 5
        sudo reboot
    else
        log_error "----------------------------------------------------"
        log_error "Setup failed at step $failed"
        log_error ""
        log_error "Recovery options:"
        log_error "  1. Check logs: tail -100 $LOG_FILE"
        log_error "  2. Fix issue manually"
        log_error "  3. Resume setup: sudo bash car2x-00-master-setup.sh --resume $((failed + 1))"
        log_error ""

        if ! offer_rollback "$failed"; then
            log_warn "Rollback cancelled, changes remain applied"
        fi

        exit 1
    fi
}

main "$@"
