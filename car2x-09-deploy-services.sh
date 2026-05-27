#!/bin/bash
# phase 9: deploy scripts + systemd units, enable them. run as root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${SCRIPT_DIR}/car2x-99-utilities.sh" ]]; then
    echo "ERROR: car2x-99-utilities.sh not found in $SCRIPT_DIR"
    exit 1
fi
source "${SCRIPT_DIR}/car2x-99-utilities.sh"


log_info "STEP 1: deploying core data collection scripts"

scripts=(
    "car2x-10-startup.sh"
    "car2x-10_1-ocb-setup.sh"
    "car2x-11-dumpcap.sh"
    "car2x-12-gps.sh"
    "car2x-13-sysmon.sh"
    "car2x-14-storage-monitor.sh"
    "car2x-16-bt-beacon.py"
    "car2x-17-wlan-beacon.sh"
    "car2x-20-usb-archive.sh"
    "quick-start.sh"
)

for s in "${scripts[@]}"; do
    if [[ -f "${SCRIPT_DIR}/${s}" ]]; then
        cp "${SCRIPT_DIR}/${s}" /usr/local/bin/
        chmod 755 "/usr/local/bin/${s}"
        log_success "Deployed: $s"
    else
        log_warn "Script not found: $s"
    fi
done


log_info "STEP 4: deploying systemd service units"

units=(
    "car2x-startup.service"
    "car2x-ocb-setup.service"
    "car2x-dumpcap.service"
    "car2x-gps.service"
    "car2x-bt-beacon.service"
    "car2x-wlan-beacon.service"
    "car2x-sysmon.service"
    "car2x-usb-archive.service"
    "car2x-storage-monitor.service"
    "car2x-storage-monitor.timer"
)

for u in "${units[@]}"; do
    if [[ -f "${SCRIPT_DIR}/${u}" ]]; then
        cp "${SCRIPT_DIR}/${u}" /usr/lib/systemd/system/
        chmod 644 "/usr/lib/systemd/system/${u}"
        log_success "Deployed: $u"
    else
        log_warn "Service file not found: $u"
    fi
done


log_info "STEP 3
log_info " STEP 4: Deploying systemd Service Units"

declare -a service_files=(
    "car2x-startup.service"
    "car2x-ocb-se

for config in "${config_files[@]}"; do
    if [[ -f "${SCRIPT_DIR}/${config}" ]]; then
        cp "${SCRIPT_DIR}/${config}" /etc/car2x/
        chmod 644 "/etc/car2x/${config}"
        log_success "Deployed config: $config"
    else
        log_warn "Config file not found: $config"
    fi
done


log_info "STEP 4: reloading systemd daemon"

systemctl daemon-reload
log_success "systemd daemon reloaded"


log_info "STEP 5: enabling services for auto-start"

if [[ -f /etc/car2x/environment ]]; then
    source /etc/car2x/environment
fi

ENABLE_GPS="${CAR2X_ENABLE_GPS:-1}"
ENABLE_PICO="${CAR2X_ENABLE_PICO:-1}"
ENABLE_BLUETOOTH="${CAR2X_ENABLE_BLUETOOTH:-1}"
ENABLE_WLAN_BEACON="${CAR2X_ENABLE_WLAN_BEACON:-1}"

core_units=(
    "car2x-startup.service"
    "car2x-ocb-setup.service"
    "car2x-dumpcap.service"
    "car2x-sysmon.service"
    "car2x-storage-monitor.timer"
)

for u in "${core_units[@]}"; do
    if systemctl enable "$u" &>/dev/null; then
        log_success "Enabled: $u"
    else
        log_warn "Could not enable: $u"
    fi
done

if [[ "$ENABLE_GPS" == "1" ]]; then
    systemctl enable car2x-gps.service &>/dev/null && log_success "Enabled: car2x-gps.service (optional)" || log_warn "Could not enable car2x-gps.service"
else
    log_warn "GPS service disabled (CAR2X_ENABLE_GPS=$ENABLE_GPS)"
fi

if [[ "$ENABLE_PICO" == "1" ]]; then
    systemctl enable car2x-pico.service &>/dev/null && log_success "Enabled: car2x-pico.service (optional)" || log_warn "Could not enable car2x-pico.service"
else
    log_warn "Pico service disabled (CAR2X_ENABLE_PICO=$ENABLE_PICO)"
fi

if [[ "$ENABLE_BLUETOOTH" == "1" ]]; then
    systemctl enable car2x-bt-beacon.service &>/dev/null && log_success "Enabled: car2x-bt-beacon.service (optional)" || log_warn "Could not enable car2x-bt-beacon.service"
else
    log_warn "Bluetooth beacon service disabled (CAR2X_ENABLE_BLUETOOTH=$ENABLE_BLUETOOTH)"
fi

if [[ "$ENABLE_WLAN_BEACON" == "1" ]]; then
    systemctl enable car2x-wlan-beacon.service &>/dev/null && log_success "Enabled: car2x-wlan-beacon.service (optional)" || log_warn "Could not enable car2x-wlan-beacon.service"
else
    log_warn "WLAN beacon service disabled (CAR2X_ENABLE_WLAN_BEACON=$ENABLE_WLAN_BEACON)"
fi

if [[ "${CAR2X_ENABLE_USB_ARCHIVE:-1}" == "1" ]]; then
    systemctl enable car2x-usb-archive.service &>/dev/null && log_success "Enabled: car2x-usb-archive.service (optional)" || log_warn "Could not enable car2x-usb-archive.service"
else
    log_warn "USB archive service disabled (CAR2X_ENABLE_USB_ARCHIVE=0)"
fi


log_info "Verifying deployment"

nscripts=$(ls /usr/local/bin/car2x-*.sh 2>/dev/null | wc -l)
log_success "Deployed $nscripts scripts to /usr/local/bin/"

nunits=$(ls /usr/lib/systemd/system/car2x-*.service /usr/lib/systemd/system/car2x-*.timer 2>/dev/null | wc -l)
log_success "Deployed $nunits systemd units"

if [[ -f /etc/car2x/config.yaml ]]; then
    log_success "Configuration deployed to /etc/car2x/"
fi

log_info ""
log_info "Enabled services:"
systemctl list-unit-files car2x-*.service car2x-*.timer 2>/dev/null | grep enabled | sed 's/^/  /'


log_success ""
log_success "----------------------------------------------------"
log_success "Phase 9 done: service deployment"
log_success "----------------------------------------------------"
log_success ""
log_success "Deployed to:"
log_success "  Scripts:        /usr/local/bin/car2x-*.sh"
log_success "  Services:       /usr/lib/systemd/system/car2x-*.service"
log_success "  Configuration:  /etc/car2x/"
log_success "  OCB setup:      /usr/local/bin/car2x-10_1-ocb-setup.sh"
log_success ""
log_info "Next steps:"
log_info "  1. Verify deployment: systemctl status car2x-*"
log_info "  2. Reboot system: sudo reboot"
log_info "  3. Monitor after boot: journalctl -u car2x-* -f"
log_warn ""
log_warn "IMPORTANT: system requires reboot to activate all services!"
log_success ""

exit 0
