#!/bin/sh
# timer-based storage alerter, no deletion
# fires daily at 02:00 UTC

set -eu

CAP_DIR="${CAR2X_CAPTURES_DIR:-/home/car2x/captures}"
SLOG="${CAP_DIR}/storage_monitor.log"

WARN_GB=${CAR2X_STORAGE_WARNING_GB:-40}
CRIT_GB=${CAR2X_STORAGE_CRITICAL_GB:-45}

slog() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "${SLOG}"
}

used_gb=$(du -sb "${CAP_DIR}" 2>/dev/null | awk '{print int($1 / (1024^3))}')
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ "$used_gb" -ge "$CRIT_GB" ]; then
    slog "CRITICAL | Storage: ${used_gb}GB >= ${CRIT_GB}GB"
elif [ "$used_gb" -ge "$WARN_GB" ]; then
    slog "WARNING | Storage: ${used_gb}GB >= ${WARN_GB}GB"
else
    slog "OK | Storage: ${used_gb}GB"
fi

slog ""
slog "Storage report: ${ts}"
slog "Total: ${used_gb}GB"
du -sh "${CAP_DIR}"/* 2>/dev/null | sort -rh >> "${SLOG}"
slog ""

exit 0
