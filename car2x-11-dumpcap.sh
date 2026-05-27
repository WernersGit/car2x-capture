#!/bin/bash
# runtime: dumpcap with size-based file rotation, unbounded ring

set -euo pipefail

CAP_DIR="${CAR2X_CAPTURES_DIR:-/home/car2x/captures}"
RT_DIR="${CAR2X_RUNTIME_DIR:-/run/car2x}"
LOG_FILE="${CAP_DIR}/last_run.log"

log_msg() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DUMPCAP: $*" | tee -a "${LOG_FILE}"
}

error_exit() {
    log_msg "ERROR: $*"
    exit 1
}

cleanup() {
    if [[ -n "${PID:-}" ]] && kill -0 "${PID}" 2>/dev/null; then
        log_msg "Stopping dumpcap (PID ${PID})..."
        kill -TERM "${PID}" 2>/dev/null || true
        sleep 2
        kill -KILL "${PID}" 2>/dev/null || true
    fi
    [[ -f "${LOCK}" ]] && rm -f "${LOCK}"
    log_msg "DUMPCAP stopped"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

# trip path comes from the startup unit
source "${RT_DIR}/car2x.env" 2>/dev/null || error_exit "Cannot read trip path"

LOCK="${CAP_DIR}/dumpcap.lock"
IFACE="${CAR2X_CAPTURE_INTERFACE:-mon0}"
SNAPLEN=${CAR2X_DUMPCAP_SNAPLEN:-0}
FSIZE_MB=${CAR2X_DUMPCAP_FILESIZE_MB:-100}
FSIZE=$((FSIZE_MB * 1024 * 1024))

log_msg "Starting dumpcap on interface: ${IFACE}"

if ! ip link show "${IFACE}" >/dev/null 2>&1 ; then
    error_exit "Interface ${IFACE} not found"
fi

# old approach: pick the next unused numeric suffix, left in case we ever want it back
#find_next_pcap_number() {
#    local max_num=0
#    for file in "${CAR2X_DRIVE_PATH}"/car2x_*.pcapng; do
#        if [[ -f "$file" ]]; then
#            local num=$(basename "$file" | sed 's/car2x_\([0-9]*\).pcapng/\1/')
#            if [[ "$num" =~ ^[0-9]+$ ]] && (( num > max_num )); then
#                max_num=$num
#            fi
#        fi
#    done
#    echo $((max_num + 1))
#}

#PCAP_NUM=$(find_next_pcap_number)
#PCAP_FILE="${CAR2X_DRIVE_PATH}/car2x_${PCAP_NUM}.pcapng"
#log_msg "Starting capture to: ${PCAP_FILE} (file #${PCAP_NUM})"

OUT="${CAR2X_DRIVE_PATH}/car2x.pcapng"
log_msg "Starting capture to: ${OUT}"



echo "${CAR2X_DRIVE_PATH}" > "${LOCK}"

# no -b files:N here, so the ring buffer is unbounded (nothing deleted)
dumpcap -i "${IFACE}" \
        -w "${OUT}" \
        -b "filesize:${FSIZE}" \
        -s "${SNAPLEN}" --log-level=info &

PID=$!
log_msg "DUMPCAP started with PID ${PID}"

wait ${PID} || true
