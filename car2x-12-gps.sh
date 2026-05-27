#!/bin/bash
# runtime: gpspipe -> jq -> csv in the trip folder

set -euo pipefail

if [[ -f /etc/car2x/environment ]]; then
    source /etc/car2x/environment
fi

RT_DIR="${CAR2X_RUNTIME_DIR:-/run/car2x}"

# trip path + gps device come from the startup unit
source "${RT_DIR}/car2x.env" 2>/dev/null || { echo "ERROR: cannot read CAR2X_DRIVE_PATH"; exit 1; }
source "${RT_DIR}/gps_device.env" 2>/dev/null || { echo "ERROR: cannot read GPS_DEVICE"; exit 1; }

TRIP="${CAR2X_DRIVE_PATH}"
CSV="${TRIP}/gps.csv"

mkdir -p "$TRIP"

log_msg() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] GPS: $*" >&2
}

error_exit() {
    log_msg "ERROR: $*"
    exit 1
}

cleanup() {
    log_msg "GPS logger stopped"
}
trap cleanup SIGTERM SIGINT EXIT

GPS_DEVICE="${GPS_DEVICE:-${CAR2X_USB_GPS:-/dev/car2x-gps}}"

if [[ ! -c "$GPS_DEVICE" ]]; then error_exit "GPS device not found: $GPS_DEVICE"; fi

log_msg "GPS device: $GPS_DEVICE"
log_msg "Output file:  $CSV"

if [[ ! -f "$CSV" ]]; then
    echo "timestamp_utc,lat,lon,alt_m,speed_mps,track_deg,fix_mode,sats" > "$CSV"
    log_msg "Created GPS CSV file with header"
fi


log_msg "Starting gpspipe JSON stream (waiting for GPS fix...)"

# keep only TPV messages with mode>=2 (2D/3D fix), flatten into csv.
# gpspipe + jq stderr is funneled into log_msg so the csv stays clean.
gpspipe -w 2> >(while read -r line; do log_msg "gpspipe: $line"; done) | \
    jq -r --unbuffered '
        select(.class=="TPV" and .mode >= 2) |
        [
            (.time // ""),
            (.lat // ""),
            (.lon // ""),
            (.alt // ""),
            (.speed // ""),
            (.track // ""),
            (.mode // ""),
            (if .satellites then .satellites | length else "" end)
        ] | @csv
    ' >> "${CSV}" 2> >(while read -r line; do log_msg "jq: $line"; done) || {
        log_msg "ERROR: gpspipe/jq pipeline failed (exit code: $?)"
        exit 1
    }