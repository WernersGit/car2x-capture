#!/bin/bash
# phase 4: build ath9k + wireless-regdb + crda. needs phase 3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${SCRIPT_DIR}/car2x-99-utilities.sh" ]]; then
    echo "ERROR: car2x-99-utilities.sh not found in $SCRIPT_DIR"
    exit 1
fi
source "${SCRIPT_DIR}/car2x-99-utilities.sh"

if [[ -f /etc/car2x/environment ]]; then
    source /etc/car2x/environment
elif [[ -f "${SCRIPT_DIR}/environment" ]]; then
    source "${SCRIPT_DIR}/environment"
fi

WORK_DIR="${CAR2X_WORK_DIR:-/home/car2x}"
LBD="${CAR2X_LINUX_BUILD_DIR:-${WORK_DIR}/linux}"
PD="${CAR2X_PATCHES_DIR:-${WORK_DIR}/11p-patches}"
REGDB="${CAR2X_REGDB_DIR:-${WORK_DIR}/wireless-regdb}"
CRDA="${CAR2X_CRDA_DIR:-${WORK_DIR}/crda}"


log_info "Validating prereqs"

if ! check_path_exists "$LBD" "Linux source"; then
    log_error "Run phase 3 first: car2x-03-patch-kernel.sh"
    exit 1
fi

if ! check_path_exists "$PD" "Patches"; then
    log_error "Run phase 3 first: car2x-03-patch-kernel.sh"
    exit 1
fi

log_success "Prerequisites verified"


log_info "STEP 0: build dependencies"

# what crda needs to build
DEPS=(
    "libnl-3-dev"
    "libnl-genl-3-dev"
    "pkg-config"
    "libgcrypt20-dev"
    "python3"
)

log_info "Checking + installing required packages..."
for p in "${DEPS[@]}"; do
    if ! dpkg -l | grep -q "^ii  ${p}"; then
        log_info "Installing ${p}..."
        apt-get install -y "${p}"
    else
        log_success "${p} already installed"
    fi
done

log_success "All build dependencies installed"

log_info "STEP 1: building ATH9K wireless drivers"
log_warn "This will take 5-10 minutes..."

cd "$LBD/drivers/net/wireless/ath"

log_info "Cleaning previous builds..."
make clean 2>/dev/null || true

log_info "Building ATH drivers..."
if ! make all 2>&1 | tee ath_build.log; then
    log_error "ATH driver build FAILED!"
    log_error "Check build log: $LBD/drivers/net/wireless/ath/ath_build.log"
    exit 1
fi

log_success "ATH drivers built succesfully"

if [[ ! -f "$LBD/drivers/net/wireless/ath/ath.ko" ]]; then
    log_error "ath.ko not generated!"
    exit 1
fi

log_success "ath.ko generated"
log_success "ath9k module files generated"


log_info "STEP 2: wireless regulatory database"

if [[ -d "$REGDB" ]]; then
    log_warn "wireless-regdb directory already exists"
    log_info "Using existing source"
else
    log_info "Cloning wireless-regdb..."
    git clone https://git.kernel.org/pub/scm/linux/kernel/git/sforshee/wireless-regdb.git "$REGDB"
    log_success "wireless-regdb cloned"
fi

cd "$REGDB"

if [[ -f "${PD}/patches/wireless-regdb.patch" ]]; then
    log_info "Applying wireless-regdb patch..."
    patch -p0 < "${PD}/patches/wireless-regdb.patch" || log_warn "Patch had warnings"
fi

log_info "Preparing Makefile for Python 3..."
# guard against double-prefixing if we ran the script before
sed -i 's|python3 python3|python3|g' Makefile
sed -i 's|^\s*./db2bin.py|python3 ./db2bin.py|g' Makefile
sed -i 's|^\s*./db2fw.py|python3 ./db2fw.py|g' Makefile

log_info "Building wireless-regdb..."
if ! make 2>&1 | tee regdb_build.log; then
    log_error "wireless-regdb build FAILED!"
    log_error "Check build log: $REGDB/regdb_build.log"
    exit 1
fi

log_info "Installing wireless-regdb..."
make PREFIX=/ install

log_success "wireless-regdb installed"

if [[ -f /lib/crda/regulatory.bin ]]; then
    log_success "/lib/crda/regulatory.bin verified"
else
    log_error "Regulatory database not installed"
    exit 1
fi


log_info "STEP 3: building + installing CRDA"

if [[ -d "$CRDA" ]]; then
    log_warn "CRDA directory already exists"
    log_info "Using existing source"
else
    log_info "Cloning CRDA..."
    git clone https://git.kernel.org/pub/scm/linux/kernel/git/mcgrof/crda.git "$CRDA"
    log_success "CRDA cloned"
fi

cd "$CRDA"

if [[ -f "${PD}/patches/crda.patch" ]]; then
    log_info "Applying CRDA patch..."
    patch -p0 < "${PD}/patches/crda.patch" || log_warn "Patch had warnings"
fi

# crda needs the root pubkey so it can verify the signed regulatory.bin
log_info "Adding root public key to CRDA for signature verification..."
if [[ -f /lib/crda/pubkeys/root.key.pub.pem ]]; then
    cp /lib/crda/pubkeys/root.key.pub.pem ./pubkeys/root.key.pub.pem
    log_success "Added root public key to CRDA"
else
    log_warn "Root public key not found in /lib/crda/pubkeys/ (will use existing keys)"
fi

log_info "Building CRDA..."
make REG_BIN=/lib/crda/regulatory.bin

log_info "Installing CRDA..."
make install PREFIX=/ REG_BIN=/lib/crda/regulatory.bin

log_success "CRDA installed"


log_info "Verifying driver installation"

if [[ -f "$LBD/drivers/net/wireless/ath/ath.ko" ]]; then
    log_success "ath.ko exists"
fi

if [[ -f "$LBD/drivers/net/wireless/ath/ath9k/ath9k.ko" ]]; then
    log_success "ath9k.ko exists"
fi

if [[ -f /lib/crda/regulatory.bin ]]; then
    log_success "Regulatory database installed"
fi

if command -v crda &>/dev/null; then
    log_success "CRDA binary available"
fi


log_success ""
log_success "----------------------------------------------------"
log_success "Phase 4 done: driver compilation"
log_success "----------------------------------------------------"
log_success ""
log_success "ATH9K modules:   $LBD/drivers/net/wireless/ath"
log_success "Wireless-regdb:  $REGDB"
log_success "CRDA:            $CRDA"
log_success ""
log_info "Next: service deployment (phase 5)"
log_success ""

exit 0
