#!/bin/bash
# car2x-21-usb-archive.sh
# shutdown: zip the active trip onto the usb archive disk
# uses the /dev/car2x-archive symlink from phase 5

set -euo pipefail

if [[ -f /etc/car2x/environment ]]; then
    source /etc/car2x/environment
fi

CAP_DIR="${CAR2X_CAPTURES_DIR:-/home/car2x/captures}"
LOG_FILE="${CAP_DIR}/last_run.log"
MNT="${CAR2X_ARCHIVE_MOUNT:-/mnt/car2x_archive}"
DEV="${CAR2X_USB_ARCHIVE:-/dev/car2x-archive}"
TO=600  # 10 min cap on the zip step

log_msg() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ARCHIVE: $*" | tee -a "${LOG_FILE}"
}

error_msg() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ARCHIVE_ERROR: $*" | tee -a "${LOG_FILE}"
}

cleanup_archive() {
    # umount the archive disk if its still mounted
    if mountpoint -q "${MNT}" 2>/dev/null; then
        log_msg "Unmounting archive: ${MNT}"
        umount "${MNT}" 2>/dev/null || true
        sleep 1
    fi
}

trap cleanup_archive EXIT

log_msg "Starting trip archive to USB..."

# 1. is the archive device actually there
if [[ ! -b "${DEV}" ]]; then
    error_msg "Archive device not found: ${DEV}"
    error_msg "Make sure USB stick is connected and /dev/car2x-archive symlink exists"
    exit 1
fi

log_msg "Using archive device: ${DEV}"

# 2. mount it (skip if already mounted)
mkdir -p "${MNT}"

if mountpoint -q "${MNT}"; then
    log_msg "Archive already mounted at ${MNT}"
else
    log_msg "Mounting archive device: ${DEV}"

    if ! timeout 30 mount "${DEV}" "${MNT}" 2>/dev/null; then
        error_msg "Cannot mount ${DEV}"
        exit 1
    fi

    log_msg "Archive mounted at: ${MNT}"
fi

# 3. pick the most recent trip
ACTIVE_TRIP=""
for trip_dir in "${CAP_DIR}"/[0-9]*_[0-9]*; do
    if [[ -d "$trip_dir" ]]; then
        if [[ -z "$ACTIVE_TRIP" ]] || [[ "$trip_dir" > "$ACTIVE_TRIP" ]]; then
            ACTIVE_TRIP="$trip_dir"
        fi
    fi
done

if [[ -z "$ACTIVE_TRIP" ]]; then
    error_msg "No trip directory found"
    exit 1
fi

TRIP_ID=$(basename "${ACTIVE_TRIP}")
log_msg "Archiving trip: ${TRIP_ID}"

# 4. count the files we will zip (anything but old .zips)
file_count=$(find "${ACTIVE_TRIP}" -type f ! -name "*.zip" | wc -l)
log_msg "Files to archive: ${file_count}"

if (( file_count == 0 )); then
    error_msg "No files to archive in ${ACTIVE_TRIP}"
    exit 1
fi

# list them for the log
log_msg "Files found:"
find "${ACTIVE_TRIP}" -type f ! -name "*.zip" | while read -r file; do
    log_msg "  - $(basename "$file") ($(stat -f%z "$file" 2>/dev/null || stat -c%s "$file") bytes)"
done

# 5. compare free space vs trip size
archive_free_bytes=$(df "${MNT}" | tail -1 | awk '{print $4 * 1024}')
trip_size_bytes=$(du -sb "${ACTIVE_TRIP}" | awk '{print $1}')

if (( trip_size_bytes > archive_free_bytes )); then
    archive_free_gb=$(( archive_free_bytes / 1024**3 ))
    trip_gb=$(( trip_size_bytes / 1024**3 ))
    error_msg "Archive has ${archive_free_gb}GB free but trip is ${trip_gb}GB, proceeding anyway"
fi

# 6. write the zip straight onto the usb (no temp file)
ZIP_NAME="${TRIP_ID}_$(date -u +%Y%m%d_%H%M%S).zip"
ZIP_PATH="${MNT}/${ZIP_NAME}"

log_msg "Creating ZIP archive: ${ZIP_PATH}"
log_msg "Source directory: ${ACTIVE_TRIP}"

# quiet zip but keep errors visible
if ! timeout "${TO}" zip -r -q "${ZIP_PATH}" "${ACTIVE_TRIP}" --exclude "*.zip" 2>&1 | tee -a "${LOG_FILE}"; then
    error_msg "ZIP creation failed"
    rm -f "${ZIP_PATH}" 2>/dev/null  # drop the partial file
    exit 1
fi

ZIP_SIZE_BYTES=$(stat -f%z "${ZIP_PATH}" 2>/dev/null || stat -c%s "${ZIP_PATH}")
ZIP_SIZE_MB=$(( ZIP_SIZE_BYTES / 1024**2 ))
ZIP_SIZE_KB=$(( ZIP_SIZE_BYTES / 1024 ))

if (( ZIP_SIZE_KB < 1 )); then
    log_msg "ZIP archive created: ${ZIP_NAME} (${ZIP_SIZE_BYTES} bytes)"
else
    log_msg "ZIP archive created: ${ZIP_NAME} (${ZIP_SIZE_KB} KB / ${ZIP_SIZE_MB} MB)"
fi

# zips below ~1KB are basically empty, treat as failure
if (( ZIP_SIZE_BYTES < 1024 )); then
    error_msg "ZIP file is only ${ZIP_SIZE_BYTES} bytes, likely empty or creation failed"
    rm -f "${ZIP_PATH}" 2>/dev/null
    exit 1
fi

# 7. integrity check
log_msg "Verifying ZIP integrity..."

if ! timeout 60 zip -T "${ZIP_PATH}" 2>&1 | tee -a "${LOG_FILE}"; then
    error_msg "ZIP integrity check failed"
    rm -f "${ZIP_PATH}" 2>/dev/null
    exit 1
fi

log_msg "ZIP integrity verified successfully"

# 8. drop a manifest next to the zip
log_msg "Creating manifest on archive..."

cat > "${MNT}/${TRIP_ID}_manifest.txt" <<EOF
Trip Archive Manifest
=====================
Trip ID: ${TRIP_ID}
Archive Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Zip File: ${ZIP_NAME}
Zip Size: ${ZIP_SIZE_MB} MB
Source Size: $(du -sh "${ACTIVE_TRIP}" | awk '{print $1}')
Original Location: ${ACTIVE_TRIP}
Status: Success

IMPORTANT: Original trip data remains on SD-card at ${ACTIVE_TRIP}
This ZIP is a backup copy only.

Files archived:
EOF

find "${ACTIVE_TRIP}" -type f ! -name "*.zip" -exec basename {} \; | sort >> "${MNT}/${TRIP_ID}_manifest.txt"

log_msg "Manifest created: ${TRIP_ID}_manifest.txt"

# 9. sync + unmount happens via the trap
log_msg "Syncing archive..."
sync
sleep 1

log_msg "Trip archive complete"
log_msg "ZIP archive: ${MNT}/${ZIP_NAME}"
log_msg "Original trip remains at: ${ACTIVE_TRIP}"

exit 0
