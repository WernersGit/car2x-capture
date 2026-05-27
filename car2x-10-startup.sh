#!/bin/bash
# init/startup: create trip folder, detect devices, write runtime env
# runs once at boot

set -euo pipefail

CAP_DIR="${CAR2X_CAPTURES_DIR:-/home/car2x/captures}"
RT_DIR="${CAR2X_RUNTIME_DIR:-/run/car2x}"
LOG_FILE="${CAP_DIR}/last_run.log"

mkdir -p "${CAP_DIR}" "${RT_DIR}"

log_msg() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] STARTUP: $*"
    echo "$msg" | tee -a "${LOG_FILE}"
}

error_exit() {
    log_msg "ERROR: $*"
    exit 1
}

log_msg "Starting Car2X initialization..."

# fresh trip folder, named by utc timestamp
TID=$(date -u +%Y%m%d_%H%M%S)
TRIP="${CAP_DIR}/${TID}"

if ! mkdir -p "${TRIP}"; then
    error_exit "Cannot create trip directory ${TRIP}"
fi
log_msg "Created trip directory: ${TRIP}"

echo "CAR2X_DRIVE_PATH=${TRIP}" > "${RT_DIR}/car2x.env"

GPS_DEVICE="${CAR2X_USB_GPS:-/dev/car2x-gps}"
PICO_DEVICE="${CAR2X_USB_PICO:-/dev/car2x-pico}"

log_msg "Using GPS device: ${GPS_DEVICE}"
log_msg "Using Pico device: ${PICO_DEVICE}"

cat > "${RT_DIR}/gps_device.env" <<EOF
GPS_DEVICE=${GPS_DEVICE}
GPS_BAUDRATE=${CAR2X_GPS_BAUDRATE:-9600}
EOF

cat > "${RT_DIR}/pico_device.env" <<EOF
PICO_DEVICE=${PICO_DEVICE}
PICO_BAUDRATE=115200
EOF

log_msg "Exported device paths: GPS=${GPS_DEVICE}, PICO=${PICO_DEVICE}"

# rfkill removes the wifi soft-block, monitor mode needs that
log_msg "Unblocking WLAN devices (rfkill)"
if command -v rfkill &>/dev/null; then
    rfkill unblock wifi || log_msg "WARNING: rfkill unblock wifi failed"
else
    log_msg "WARNING: rfkill command not found"
fi

WLAN_BEACON_INTERFACE="${CAR2X_WLAN_BEACON_INTERFACE:-wlan1}"
if ip link show "$WLAN_BEACON_INTERFACE" &>/dev/null; then
    log_msg "Bringing up interface: $WLAN_BEACON_INTERFACE"
    ip link set "$WLAN_BEACON_INTERFACE" up || log_msg "WARNING: Failed to bring up $WLAN_BEACON_INTERFACE"
    sleep 1
else
    log_msg "WARNING: WLAN beacon interface not found: $WLAN_BEACON_INTERFACE"
fi

if [[ "${GPS_DEVICE}" == "${PICO_DEVICE}" ]] && [[ "${PICO_DEVICE}" != "NONE" ]]; then
    error_exit "GPS and Pico conflict on same port ${GPS_DEVICE}"
fi

cat > "${TRIP}/manifest.json" <<EOF
{
  "trip_id": "${TID}",
  "start_time_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "end_time_utc": null,
  "status": "in_progress",
  "gps_device": "${GPS_DEVICE}",
  "pico_device": "${PICO_DEVICE}",
  "pcap_files": [],
  "gps_file": "gps.csv",
  "gps_records": 0,
  "sysmon_file": "sysMon.csv",
  "sysmon_records": 0,
  "events_file": "events.log",
  "events": 0,
  "total_size_bytes": 0,
  "retention_policy": "PERMANENT - All data retained"
}
EOF

log_msg "Created manifest: ${TRIP}/manifest.json"

# clean stale locks from a previously crashed run
for lk in dumpcap.lock gps.lock sysMon.lock usv_receiver.lock; do
    if [[ -f "${CAP_DIR}/${lk}" ]]; then
        old=$(cat "${CAP_DIR}/${lk}" 2>/dev/null || echo "")
        if [[ -n "$old" ]] && [[ ! -d "${old%/*}" ]]; then
            log_msg "Cleaning up stale lock: ${lk}"
            rm -f "${CAP_DIR}/${lk}"
        fi
    fi
done

log_msg "Initialization complete: CAR2X_DRIVE_PATH=${TRIP}"
exit 0
