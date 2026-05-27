#!/bin/bash
# ocb sub-step of startup: load custom ath9k modules, put wlan0 into ocb mode.
# runs before the other car2x services. needs root + phase 4 built drivers.

set -euo pipefail

LOG_FILE="/var/log/car2x/ocb-setup.log"

mkdir -p "$(dirname "$LOG_FILE")"

log_msg() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] OCB-SETUP: $*" | tee -a "${LOG_FILE}"
}

error_exit() {
    log_msg "ERROR: $*"
    exit 1
}

log_msg "Starting 802.11p OCB mode setup for wlan0..."

if [[ -f /etc/car2x/environment ]]; then
    source /etc/car2x/environment
fi

ENABLE_DUMPCAP="${CAR2X_ENABLE_DUMPCAP:-1}"
LBD="${CAR2X_LINUX_BUILD_DIR:-/home/car2x/linux}"
ATH="${LBD}/drivers/net/wireless/ath"

if [[ "$ENABLE_DUMPCAP" != "1" ]]; then
    log_msg "Dumpcap disabled (CAR2X_ENABLE_DUMPCAP=0), skipping OCB setup"
    exit 0
fi

if [[ ! -d "$ATH" ]]; then
    log_msg "WARNING: Custom ATH drivers not found at ${ATH}"
    log_msg "WARNING: Run phase 4 (car2x-04-build-drivers.sh) to build drivers with OCB support"
    exit 1
fi

if [[ ! -f "${ATH}/ath.ko" ]] || [[ ! -f "${ATH}/ath9k/ath9k.ko" ]]; then
    error_exit "Custom ath9k module files not found, run phase 4 first"
fi

# drop the stock modules first, errors are fine since they may not be loaded
log_msg "Unloading stock ath9k modules..."
rmmod ath9k 2>/dev/null || true
#rmmod ath9k_htc 2>/dev/null || true # not used on the onboard chipset
rmmod ath9k_common 2>/dev/null || true
rmmod ath9k_hw 2>/dev/null || true
rmmod ath 2>/dev/null || true

log_msg "Stock modules unloaded"

log_msg "Loading custom ath9k modules from ${ATH}..."

cd "$ATH"
if ! insmod ath.ko; then
    error_exit "Failed to load ath.ko"
fi
log_msg "Loaded ath.ko"

cd ath9k
if ! insmod ath9k_hw.ko; then
    error_exit "Failed to load ath9k_hw.ko"
fi
log_msg "Loaded ath9k_hw.ko"

if ! insmod ath9k_common.ko; then
    error_exit "Failed to load ath9k_common.ko"
fi
log_msg "Loaded ath9k_common.ko"

#if ! insmod ath9k_htc.ko; then
#    error_exit "Failed to load ath9k_htc.ko"
#fi
log_msg "Loaded ath9k_htc.ko"

if ! insmod ath9k.ko; then
    error_exit "Failed to load ath9k.ko"
fi
log_msg "Loaded ath9k.ko"

log_msg "Waiting for wlan0 interface..."
TO=10
for i in $(seq 1 $TO); do
    if ip link show wlan0 &>/dev/null; then
        log_msg "wlan0 interface detected"
        break
    fi
    if [[ $i -eq $TO ]]; then
        error_exit "wlan0 interface did not appear after ${TO} seconds"
    fi
    sleep 1
done

log_msg "Configuring wlan0 to OCB mode..."

if ! ip link set wlan0 down; then
    error_exit "Failed to bring wlan0 down"
fi

if ! iw dev wlan0 set type ocb; then
    error_exit "Failed to set wlan0 to OCB type"
fi
log_msg "wlan0 set to OCB type"

# extra monitor iface so we can capture the radiotap headers
if iw dev wlan0 interface add mon0 type monitor; then
    ip link set mon0 up
    log_msg "Created monitor interface 'mon0' for Radiotap captures"
else
    log_msg "WARNING: Failed to create monitor interface 'mon0'"
fi

if ! ip link set wlan0 up; then
    error_exit "Failed to bring wlan0 up"
fi
log_msg "wlan0 interface up"

# ITS-G5 ch 180 (5900 MHz, 10 MHz bw)
log_msg "Joining OCB channel 5900 MHz (10 MHz bandwidth)..."
if ! iw dev wlan0 ocb join 5900 10MHZ; then
    error_exit "Failed to join OCB channel"
fi

log_msg "wlan0 succesfully configured for 802.11p OCB mode"
log_msg "Channel: 180 (5900 MHz), bandwidth: 10 MHz"

iw dev wlan0 info | tee -a "${LOG_FILE}"

log_msg "OCB setup complete"
exit 0
