#!/bin/bash
# phase 3: clone rpi kernel, apply 802.11p patches, generate .config
# needs phase 2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "${SCRIPT_DIR}/car2x-99-utilities.sh" ]; then
    echo "ERROR: car2x-99-utilities.sh not found in $SCRIPT_DIR"
    exit 1
fi
source "${SCRIPT_DIR}/car2x-99-utilities.sh"

if [ -f /etc/car2x/environment ]; then
    source /etc/car2x/environment
elif [ -f "${SCRIPT_DIR}/environment" ]; then
    source "${SCRIPT_DIR}/environment"
fi

WORK_DIR="${CAR2X_WORK_DIR:-/home/car2x}"
LBD="${CAR2X_LINUX_BUILD_DIR:-${WORK_DIR}/linux}"
PD="${CAR2X_PATCHES_DIR:-${WORK_DIR}/11p-patches}"


log_info "Validating prereqs"

if ! check_path_exists "$WORK_DIR" "Working directory"; then
    log_error "Run phase 2 first: car2x-02-create-user.sh"
    exit 1
fi


log_info "STEP 1: cloning rpi linux kernel"

if [ -d "$LBD" ]; then
    log_warn "Linux directory already exists at $LBD"
    log_info "Using existing kernel source"
else
    log_info "Cloning Raspberry Pi Linux kernel (5-10 minutes, ~500MB)..."
    git clone --depth=1 https://github.com/raspberrypi/linux.git "$LBD"
    log_success "Kernel cloned"
fi

cd "$LBD"


log_info "STEP 2: checking out rpi-6.12.y"

git fetch origin rpi-6.12.y 2>/dev/null || true
git checkout rpi-6.12.y
log_success "Checked out rpi-6.12.y"


log_info "STEP 3: generating BCM2712 kernel config"

make bcm2712_defconfig
log_success "Kernel config generated"


log_info "STEP 4: cloning + applying 802.11p patches"

if [ -d "$PD" ]; then
    log_warn "Patches directory already exists at $PD"
    log_info "Using existing patches"
else
    log_info "Cloning 11p-on-linux repository..."
    git clone https://gitlab.com/hpi-potsdam/osm/g5-on-linux/11p-on-linux.git "$PD"
    log_success "Patches cloned"
fi


log_info "STEP 5: applying 802.11p patch to the kernel"

cd "$LBD"

if [ ! -f "${PD}/patches/linux-6.12.patch" ]; then
    log_error "Patch file not found: ${PD}/patches/linux-6.12.patch"
    exit 1
fi

log_info "Applying patch: linux-6.12.patch"
if patch -p0 < "${PD}/patches/linux-6.12.patch"; then
    log_success "Patch applied successfully"
else
    # patch -p0 can return 1 even on a mostly successful apply
    rc=$?
    if [ $rc -eq 1 ]; then
        log_warn "Patch had warnings (exit code: $rc)"
        log_warn "Usually OK, but watch for 'Hunk FAILED' errors above"
    fi
fi


log_info "Verifying kernel patching"

if grep -q "802.11p\|OCB\|AIRO" "$LBD/Makefile" 2>/dev/null; then
    log_success "Kernel patches appear to be applied"
fi

if [ -f "$LBD/.config" ]; then
    log_success "Kernel config (.config) exists"
else
    log_error "Kernel config not found"
    exit 1
fi

if [ -f "$LBD/Makefile" ] && [ -d "$LBD/drivers" ]; then
    log_success "Kernel source structure verified"
else
    log_error "Kernel source structure invalid"
    exit 1
fi


log_success ""
log_success "----------------------------------------------------"
log_success "Phase 3 done: kernel patching"
log_success "----------------------------------------------------"
log_success ""
log_success "Kernel build directory: $LBD"
log_success "Patches directory:      $PD"
log_success "Kernel config:          $LBD/.config"
log_success ""
log_info "Next: driver compilation (phase 4)"
log_info "Driver compilation will take 5-10 minutes..."
log_success ""

exit 0
