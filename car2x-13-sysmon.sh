#!/bin/bash
# runtime: sample cpu temp / load / mem every 10s into csv

set -euo pipefail

CAP_DIR="${CAR2X_CAPTURES_DIR:-/home/car2x/captures}"
RT_DIR="${CAR2X_RUNTIME_DIR:-/run/car2x}"
LOG_FILE="${CAP_DIR}/last_run.log"

log_msg() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] SYSMON: $*" | tee -a "${LOG_FILE}"
}

error_exit() {
    log_msg "ERROR: $*"
    exit 1
}

cleanup() {
    [[ -f "${LOCK}" ]] && rm -f "${LOCK}"
    log_msg "System monitor stopped"
    exit 0
}

trap cleanup SIGTERM SIGINT

source "${RT_DIR}/car2x.env" 2>/dev/null || error_exit "Cannot read trip path"

OUT="${CAR2X_DRIVE_PATH}/sysMon.csv"
LOCK="${CAP_DIR}/sysMon.lock"
INTERVAL=10

log_msg "Starting system monitor (interval: ${INTERVAL}s)"

if [[ ! -f "${OUT}" ]]; then
    echo "timestamp_utc,cpu_temp_C,load_1m,load_5m,mem_total_kB,mem_free_kB,mem_available_kB" > "${OUT}"
    log_msg "Created sysMon file: ${OUT}"
fi

echo "${OUT}" > "${LOCK}"

# helper: cpu temp via /sys/class/thermal
get_cpu_temperature() {
    for z in /sys/class/thermal/thermal_zone*/temp; do
        if [[ -f "$z" ]]; then
            local mc=$(cat "$z" 2>/dev/null || echo "0")
            echo "scale=1; $mc / 1000" | bc 2>/dev/null || echo "-1"
            return 0
        fi
    done
    echo "-1"
}

get_load_averages() {
    local la=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2}')
    echo "$la"
}

get_memory_info() {
    awk '/MemTotal|MemFree|MemAvailable/ {print $2}' /proc/meminfo | tr '\n' ' '
}

log_msg "Strating monitoring loop..."

n=0

while true; do
    ts=$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)
    temp=$(get_cpu_temperature)
    la=$(get_load_averages)
    mem=$(get_memory_info)

    read m_total m_free m_avail <<< "$mem"

    read la1 la5 <<< "$la"

    printf "%s,%s,%s,%s,%s,%s,%s\n" \
        "$ts" \
        "$temp" \
        "${la1:-0}" \
        "${la5:-0}" \
        "${m_total:-0}" \
        "${m_free:-0}" \
        "${m_avail:-0}" >> "${OUT}"

    # fsync every 6 records (~60s)
    ((n++))
    if (( n % 6 == 0 )); then
        sync "$OUT" 2>/dev/null || true
    fi

    sleep "${INTERVAL}"
done
