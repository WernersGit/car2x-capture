#!/bin/bash
# car2x-15-pico.sh
# runtime: pico serial protocol handler (placeholder, exits early for now)

set -euo pipefail

echo "Pico runtime service: coming soon"
exit 0

# (everything below is reached once the early exit above is removed)

# env config
if [[ -f /etc/car2x/environment ]]; then
    source /etc/car2x/environment
fi

RUNTIME_DIR="${CAR2X_RUNTIME_DIR:-/run/car2x}"

# pico device + trip path come from the startup unit
source "${RUNTIME_DIR}/car2x.env" 2>/dev/null || { echo "ERROR: cannot read CAR2X_DRIVE_PATH"; exit 1; }
source "${RUNTIME_DIR}/pico_device.env" 2>/dev/null || { echo "ERROR: cannot read PICO_DEVICE"; exit 1; }

TRIP_PATH="${CAR2X_DRIVE_PATH}"
PICO_PYTHON_SCRIPT="${CAR2X_PICO_PYTHON_SCRIPT:-/usr/local/bin/car2x-pico-protocol.py}"

mkdir -p "$TRIP_PATH"

log_msg() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] PICO: $*" >&2
}

error_exit() {
    log_msg "ERROR: $*"
    exit 1
}

cleanup() {
    log_msg "Pico handler stopped"
}
trap cleanup SIGTERM SIGINT EXIT

# check the pico device
PICO_DEV="${PICO_DEVICE:-${CAR2X_USB_PICO:-/dev/car2x-pico}}"

if [[ ! -c "$PICO_DEV" ]]; then
    error_exit "Pico device not found: $PICO_DEV"
fi

log_msg "Pico device: $PICO_DEV"
log_msg "Trip path: $TRIP_PATH"

# the python protocol script needs to be there and executable
if [[ ! -x "$PICO_PYTHON_SCRIPT" ]]; then
    error_exit "Pico Python script not found or not executable: $PICO_PYTHON_SCRIPT"
fi

# hand off to the python script
log_msg "Starting Pico protocol handler: $PICO_PYTHON_SCRIPT"

# pass config via env vars
export PICO_DEVICE="$PICO_DEV"
export PICO_BAUDRATE="${CAR2X_PICO_BAUDRATE:-115200}"
export CAR2X_DRIVE_PATH="$TRIP_PATH"

# exec replaces this shell with python
exec "$PICO_PYTHON_SCRIPT"
