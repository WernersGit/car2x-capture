#!/bin/bash
# runtime: scan wifi beacons + probe requests via iwlist, append jsonl

set -euo pipefail

if [[ -f /etc/car2x/environment ]]; then
    source /etc/car2x/environment
fi

RT_DIR="${CAR2X_RUNTIME_DIR:-/run/car2x}"
source "${RT_DIR}/car2x.env" 2>/dev/null || { echo "ERROR: cannot read CAR2X_DRIVE_PATH"; exit 1; }

TRIP="${CAR2X_DRIVE_PATH}"
IFACE="${CAR2X_WLAN_BEACON_INTERFACE:-wlan1}"
INTERVAL="${CAR2X_WLAN_SCAN_INTERVAL:-2}"  # 2s = 0.5 Hz
OUT="${TRIP}/wlan_beacons_$(date +%s).jsonl"

mkdir -p "$TRIP"

log_msg() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WLAN: $*" >&2
}

error_exit() {
    log_msg "ERROR: $*"
    exit 1
}

cleanup() {
    log_msg "WLAN scanner stopped"
}
trap cleanup SIGTERM SIGINT EXIT

if ! ip link show "$IFACE" &>/dev/null; then
    error_exit "Interface $IFACE not found"
fi

ip link set "$IFACE" up 2>/dev/null || true
sleep 1

log_msg "Starting WLAN beacon scanner on $IFACE"
log_msg "Output: $OUT"

while true; do
    TS=$(date +%s)

    # iwlist needs CAP_NET_ADMIN, granted by the systemd unit
    if ! SCAN=$(iwlist "$IFACE" scanning 2>&1); then
        log_msg "ERROR: iwlist scan failed: $SCAN"
        sleep "$INTERVAL"
        continue
    fi

    echo "$SCAN" | \
    egrep "Cell|Quality|Last beacon|ESSID|Address|Signal level|Frequency|Channel" | \
    awk -v ts="$TS" '
    BEGIN {
        ORS = ""
        print "{\"ts\":" ts ",\"nets\":["
        first = 1
    }

    /Cell [0-9]/ {
        if (!first) print "},"
        first = 0
        print "{"
        sep = ""
    }

    /Address: / {
        gsub(/.*Address: /, "")
        gsub(/:/, "")  # strip colons: AA:BB:CC -> AABBCC
        print sep "\"mac\":\"" $0 "\""
        sep = ","
    }

    /ESSID:/ {
        gsub(/.*ESSID:/, "")
        gsub(/"/, "")
        gsub(/\\/, "\\\\")  # escape backslashes
        gsub(/"/, "\\\"")   # escape quotes
        print sep "\"ssid\":\"" $0 "\""
        sep = ","
    }

    /Channel:/ {
        gsub(/.*Channel:/, "")
        print sep "\"ch\":" $0
        sep = ","
    }

    /Frequency:/ {
        gsub(/.*Frequency:/, "")
        gsub(/ GHz.*/, "")
        freq_mhz = int($0 * 1000)  # GHz -> MHz integer
        print sep "\"freq\":" freq_mhz
        sep = ","
    }

    /Signal level=/ {
        gsub(/.*Signal level=/, "")
        gsub(/ dBm.*/, "")
        print sep "\"rssi\":" $0
        sep = ","
    }

    /Quality=/ {
        gsub(/.*Quality=/, "")
        gsub(/\/.*/, "")
        print sep "\"qual\":" $0
        sep = ","
    }

    /Last beacon:/ {
        gsub(/.*Last beacon: /, "")
        gsub(/ms.*/, "")
        print sep "\"beacon\":" $0
        sep = ","
    }

    END {
        if (!first) print "}"
        print "]}\n"
    }' >> "$OUT"

    sleep "$INTERVAL"
done
