#!/bin/bash
# phase 2: car2x user, groups, base dirs. has to run before kernel patching (creates /home/car2x).
# run as root

set -euo pipefail

ME="$(whoami)"
HOMEDIR="$(eval echo ~$ME)"

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


log_info "STEP 1: creating car2x system user"

if id car2x &>/dev/null; then
    log_warn "User 'car2x' already exists"
else
    useradd -r -s /bin/bash -m -d /home/car2x -c "Car2X Data Acquisition" car2x
    log_success "User 'car2x' created"
fi


log_info "STEP 2: group memberships"

groups_to_add=(
    "dialout"      # serial: /dev/ttyUSB*, /dev/ttyAMA*
    "wireshark"    # dumpcap
    "video"        # /dev/vchiq, optional
)

for g in "${groups_to_add[@]}"; do
    if ! getent group "$g" > /dev/null; then
        groupadd "$g"
        log_success "Created group: $g"
    fi

    if ! groups car2x | grep -q "$g"; then
        usermod -aG "$g" car2x
        log_success "Added car2x to group: $g"
    else
        log_warn "car2x already in group: $g"
    fi
done

log_info "STEP 3: directory layout"

declare -a dirs=(
    "$CAR2X_HOME"
    "$CAR2X_CAPTURES_DIR"
    "$CAR2X_HOME/.config"
    "$CAR2X_HOME/.local"
    "$CAR2X_HOME/.local/bin"
)

for d in "${dirs[@]}"; do
    if [[ ! -d "$d" ]]; then
        mkdir -p "$d"
        chown car2x:car2x "$d"
        chmod 755 "$d"
        log_success "Created: $d"
    else
        log_warn "Directory already exists: $d"
        chown car2x:car2x "$d"
    fi
done


log_info "STEP 4: file permissions"

# captures: 750 (rwxr-x---)
chmod 750 /home/car2x/captures
log_success "Set captures directory permissions: 750"

sudo setfacl -m u:${ME}:rx "$CAR2X_HOME"
sudo setfacl -m u:${ME}:rwX "$CAR2X_CAPTURES_DIR"
# only put a Desktop symlink if a gui is installed
if dpkg -l | grep -Eiq "lxde|xfce4|raspberrypi-ui-mods|gnome-shell|kde-plasma-desktop";
then
    log_info "GUI found. Creating symlink on your Desktop."
    ln -sf "$CAR2X_CAPTURES_DIR" "${HOMEDIR}/Desktop/"
else
    log_info "No GUI found. Creating symlink in your home directory."
    ln -sf "$CAR2X_CAPTURES_DIR" "${HOMEDIR}/"
fi

log_info "STEP 5: dumpcap linux capabilities"

if ! command -v dumpcap &>/dev/null; then
    log_warn "dumpcap not found, installing wireshark-common..."

    # opt-out of setuid, we use file capabilities instead
    echo "wireshark-common wireshark-common/install-setuid boolean false" | debconf-set-selections

    DEBIAN_FRONTEND=noninteractive apt-get install -y wireshark-common

    if command -v dumpcap &>/dev/null; then
        log_success "dumpcap installed (without setuid)"
    else
        log_error "Failed to install dumpcap"
        exit 1
    fi
fi

DC_BIN=$(which dumpcap)
log_info "Found dumpcap at: $DC_BIN"

setcap cap_net_raw,cap_net_admin=ep "$DC_BIN"
log_success "Set dumpcap capabilities: cap_net_raw,cap_net_admin=ep"

# getcap output order is not stable, so check each cap on its own
if getcap "$DC_BIN" | grep -q "cap_net_raw" && getcap "$DC_BIN" | grep -q "cap_net_admin"; then
    log_success "dumpcap capabilities verified"
else
    log_error "dumpcap capabilities not set correctly"
    exit 1
fi

log_info "STEP 6: serial device permissions"

UDEV_RULE_FILE="/etc/udev/rules.d/99-car2x-devices.rules"

if [[ ! -f "$UDEV_RULE_FILE" ]]; then
    cat > "$UDEV_RULE_FILE" <<EOF
# Car2X Device Permissions
# Allow car2x user to access GPS and Pico devices without root

# GT-U7 GPS
SUBSYSTEM=="tty", ATTRS{idVendor}=="1546", ATTRS{idProduct}=="01a7", SYMLINK+="car2x-gps", GROUP="dialout", MODE="0660"

# Pico
SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", ATTRS{idProduct}=="0009", ATTRS{serial}=="F9B663F899667DA9", SYMLINK+="car2x-pico", GROUP="dialout", MODE="0660"


# Regular UART devices
SUBSYSTEM=="tty", KERNEL=="ttyACM*", MODE="0666", GROUP="dialout"

EOF
    log_success "Created udev rule: $UDEV_RULE_FILE"
    udevadm control --reload-rules
    log_success "Reloaded udev rules"
else
    log_warn "udev rule already exists: $UDEV_RULE_FILE"
fi

log_info "STEP 7: runtime directories"

if [[ ! -d /run/car2x ]]; then
    mkdir -p /run/car2x
    chmod 755 /run/car2x
    log_success "Created /run/car2x"
else
    log_warn "Directory already exists: /run/car2x"
fi


log_info "STEP 8: configruation directory"

if [[ ! -d /etc/car2x ]]; then
    mkdir -p /etc/car2x
    chmod 755 /etc/car2x
    log_success "Created /etc/car2x"
else
    log_warn "Directory already exists: /etc/car2x"
fi

if [[ -f "${SCRIPT_DIR}/environment" ]]; then
    log_info "Deploying environment configuration..."
    cp "${SCRIPT_DIR}/environment" /etc/car2x/environment
    chmod 644 /etc/car2x/environment
    log_success "Deployed environment file to /etc/car2x/environment"
else
    log_error "Environment file not found: ${SCRIPT_DIR}/environment"
    exit 1
fi

log_info "STEP 9: USB archive mount point"

if [[ ! -d /mnt/car2x_archive ]]; then
    mkdir -p /mnt/car2x_archive
    chmod 755 /mnt/car2x_archive
    log_success "Created /mnt/car2x_archive"
else
    log_warn "Directory already exists: /mnt/car2x_archive"
fi

log_info "Verifying setup"

if id car2x &>/dev/null; then
    log_success "User 'car2x' exists"
else
    log_error "User 'car2x' not found"
    exit 1
fi

if groups car2x | grep -q dialout; then
    log_success "car2x in dialout group"
fi

if groups car2x | grep -q wireshark; then
    log_success "car2x in wireshark group"
fi

for d in /home/car2x/captures /etc/car2x /run/car2x /mnt/car2x_archive; do
    if [[ -d "$d" ]]; then
        log_success "Directory exists: $d"
    else
        log_error "Directory not found: $d"
        exit 1
    fi
done

if getcap $(which dumpcap) | grep -q "cap_net_raw" && getcap $(which dumpcap) | grep -q "cap_net_admin"; then
    log_success "dumpcap capabilities verified"
fi

log_success ""
log_success "----------------------------------------------------"
log_success "Phase 2 done: user and directory setup"
log_success "----------------------------------------------------"
log_success ""
log_success "User:                car2x"
log_success "Home directory:      /home/car2x"
log_success "Captures directory:  /home/car2x/captures"
log_success "Config directory:    /etc/car2x"
log_success "Runtime directory:   /run/car2x"
log_success "Archive mount:       /mnt/car2x_archive"
log_success ""
log_success "Groups:"
groups car2x | sed 's/^/  /'
log_success ""
log_info "Next: kernel patching (phase 3)"
log_success ""

exit 0
