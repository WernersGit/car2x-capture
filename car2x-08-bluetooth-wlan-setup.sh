#!/usr/bin/env bash
# car2x-08-bluetooth-wlan-setup.sh
# phase 8: bluetooth + internal wlan beacon capture
# safe to re-run

set -euo pipefail

# shared helpers + env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/car2x-99-utilities.sh" ]]; then
    echo "ERROR: car2x-99-utilities.sh not found in $SCRIPT_DIR"
    exit 1
fi
source "${SCRIPT_DIR}/car2x-99-utilities.sh"

# env config
if [[ -f /etc/car2x/environment ]]; then
    source /etc/car2x/environment
elif [[ -f "${SCRIPT_DIR}/environment" ]]; then
    source "${SCRIPT_DIR}/environment"
fi

# config (with sane defaults)
ENABLE_BLUETOOTH="${CAR2X_ENABLE_BLUETOOTH:-1}"
ENABLE_WLAN_BEACON="${CAR2X_ENABLE_WLAN_BEACON:-1}"
BT_INTERFACE="${CAR2X_BT_INTERFACE:-hci0}"
WLAN_BEACON_INTERFACE="${CAR2X_WLAN_BEACON_INTERFACE:-wlan1}"
WLAN_BEACON_CHANNELS="${CAR2X_WLAN_BEACON_CHANNELS:-1,6,11}"

# entry banner
log_info "----------------------------------------------------"
log_info " Phase 8: Bluetooth + WLAN beacon capture setup"
log_info "----------------------------------------------------"
log_info ""

# bail out if neither side is wanted
if [[ "$ENABLE_BLUETOOTH" != "1" ]] && [[ "$ENABLE_WLAN_BEACON" != "1" ]]; then
    log_warn "Both Bluetooth and WLAN beacon services disabled"
    log_warn "Skipping phase 8 setup"
    exit 0
fi

# need root
if ! check_root; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

if [[ "$ENABLE_BLUETOOTH" == "1" ]]; then
    log_info "Step 1a: installing bluetooth dependencies"
    
    install_bluetooth_packages() {
        local packages_to_install=()

        # check for the bluetooth tools
        if ! command -v hcitool &>/dev/null; then
            packages_to_install+=("bluez" "bluetooth")
        fi

        if ! command -v bluetoothctl &>/dev/null && [[ ${#packages_to_install[@]} -eq 0 ]]; then
            packages_to_install+=("bluez")
        fi

        if [[ ${#packages_to_install[@]} -eq 0 ]]; then
            log_success "Bluetooth packages already installed"
            return 0
        fi

        log_info "Installing packages: ${packages_to_install[*]}"

        if command -v apt &>/dev/null; then
            apt update -qq || log_warn "apt update had warnings"
            apt install -y "${packages_to_install[@]}" || {
                log_error "Failed to install Bluetooth packages"
                return 1
            }
        elif command -v dnf &>/dev/null; then
            dnf install -y "${packages_to_install[@]}" || {
                log_error "Failed to install Bluetooth packages via dnf"
                return 1
            }
        else
            log_error "Unsupported package manager"
            return 1
        fi

        log_success "Bluetooth packages installed succesfully"
    }

    if ! install_bluetooth_packages; then
        exit 1
    fi

    # enable the system bluetooth service
    log_info "Enabling Bluetooth service..."
    systemctl enable bluetooth.service || log_warn "Failed to enable bluetooth.service"
    systemctl start bluetooth.service || log_warn "Failed to start bluetooth.service"

    # is the controller actually there
    if hciconfig "$BT_INTERFACE" &>/dev/null; then
        log_success "Bluetooth controller detected: $BT_INTERFACE"
    else
        log_warn "Bluetooth controller not found: $BT_INTERFACE"
        log_warn "Bluetooth scanning will be disabled if controller is missing"
        log_warn "Check available controllers: hciconfig -a"
    fi
else
    log_warn "Bluetooth service disabled (CAR2X_ENABLE_BLUETOOTH=$ENABLE_BLUETOOTH)"
    log_warn "Skipping Bluetooth setup"
fi

if [[ "$ENABLE_WLAN_BEACON" == "1" ]]; then
    log_info ""
    log_info "Step 1b: installing wlan beacon capture dependencies"
    
    install_wlan_packages() {
        local packages_to_install=()

        # wireless tooling
        if ! command -v iw &>/dev/null; then
            packages_to_install+=("iw")
        fi

        if ! command -v tcpdump &>/dev/null; then
            packages_to_install+=("tcpdump")
        fi

        if ! command -v airmon-ng &>/dev/null; then
            packages_to_install+=("aircrack-ng")
        fi
        
        if [[ ${#packages_to_install[@]} -eq 0 ]]; then
            log_success "WLAN packages already installed"
            return 0
        fi
        
        log_info "Installing packages: ${packages_to_install[*]}"
        
        if command -v apt &>/dev/null; then
            apt update -qq || log_warn "apt update had warnings"
            apt install -y "${packages_to_install[@]}" || {
                log_error "Failed to install WLAN packages"
                return 1
            }
        elif command -v dnf &>/dev/null; then
            dnf install -y "${packages_to_install[@]}" || {
                log_error "Failed to install WLAN packages via dnf"
                return 1
            }
        else
            log_error "Unsupported package manager"
            return 1
        fi
        
        log_success "WLAN packages installed successfully"
    }
    
    if ! install_wlan_packages; then
        exit 1
    fi
    
    # is the chosen wlan iface present
    log_info "Detecting WLAN beacon capture interface..."

    # wlan1 is the internal radio on the rpi5
    if iw dev | grep -q "Interface $WLAN_BEACON_INTERFACE"; then
        log_success "WLAN beacon interface detected: $WLAN_BEACON_INTERFACE"
    else
        log_warn "WLAN beacon interface not found: $WLAN_BEACON_INTERFACE"
        log_warn "Available WLAN interfaces:"
        iw dev | grep "Interface" | sed 's/^/  /'

        log_warn "Possible causes:"
        log_warn "  1. dtoverlay=disable-wifi is set in /boot/firmware/config.txt"
        log_warn "  2. WLAN regulatory domain not configured"
        log_warn "  3. System needs reboot after phase 1 configuration"
        log_warn ""
        log_warn "Resolution:"
        log_warn "  1. Check CAR2X_ENABLE_INTERNAL_WLAN=1 in /etc/car2x/environment"
        log_warn "  2. Re-run phase 1: sudo bash car2x-01-prepare-system.sh"
        log_warn "  3. Reboot and retry phase 8"
        log_warn ""
        log_warn "Continuing without wlan1, beacon capture will not work"
    fi
else
    log_warn "WLAN beacon service disabled (CAR2X_ENABLE_WLAN_BEACON=$ENABLE_WLAN_BEACON)"
    log_warn "Skipping WLAN beacon setup"
fi

if [[ "$ENABLE_BLUETOOTH" == "1" ]]; then
    log_info ""
    log_info "Step 2a: configuring bluetooth permissions"

    # car2x user needs access to bluetooth
    if id car2x &>/dev/null; then
        # add to bluetooth group if its there
        if getent group bluetooth &>/dev/null; then
            if groups car2x | grep -q bluetooth; then
                log_success "car2x user already in bluetooth group"
            else
                log_info "Adding car2x user to bluetooth group..."
                usermod -a -G bluetooth car2x || log_warn "Failed to add car2x to bluetooth group"
                log_success "car2x user added to bluetooth group"
            fi
        else
            log_debug "bluetooth group does not exist"
        fi

        # also netdev for general net-iface access
        if getent group netdev &>/dev/null; then
            if groups car2x | grep -q netdev; then
                log_success "car2x user already in netdev group"
            else
                log_info "Adding car2x user to netdev group..."
                usermod -a -G netdev car2x || log_warn "Failed to add car2x to netdev group"
                log_success "car2x user added to netdev group"
            fi
        fi
    else
        log_warn "car2x user not found (will be created in phase 2)"
    fi
fi

if [[ "$ENABLE_WLAN_BEACON" == "1" ]]; then
    log_info ""
    log_info "Step 2b: configuring wlan monitor mode permissions"

    # monitor mode needs root or CAP_NET_ADMIN. we set the cap
    # on the systemd unit instead, no need to do it here.
    log_success "WLAN monitor mode will be configured at runtime"
    log_info "Service will run with CAP_NET_ADMIN capability"
fi

if [[ "$ENABLE_WLAN_BEACON" == "1" ]]; then
    log_info ""
    log_info "Step 3: preventing NetworkManager interference"

    NM_CONF_DIR="/etc/NetworkManager/conf.d"
    NM_CAR2X_CONF="$NM_CONF_DIR/car2x-unmanaged.conf"

    mkdir -p "$NM_CONF_DIR"

    # already configured?
    if [[ -f "$NM_CAR2X_CONF" ]] && grep -q "$WLAN_BEACON_INTERFACE" "$NM_CAR2X_CONF" 2>/dev/null; then
        log_success "NetworkManager already configured to ignore beacon interface"
    else
        log_info "Configuring NetworkManager to ignore $WLAN_BEACON_INTERFACE..."

        cat > "$NM_CAR2X_CONF" <<EOF
# Car2X Network Interface Management - Generated by car2x-08-bluetooth-wlan-setup.sh
# Modified: $(date -u +%Y-%m-%dT%H:%M:%SZ)

[keyfile]
# Prevent NetworkManager from managing Car2X interfaces
unmanaged-devices=interface-name:wlan0;interface-name:$WLAN_BEACON_INTERFACE

[device]
wifi.scan-rand-mac-address=no
EOF

        log_success "NetworkManager configuration written"

        # reload if its already running
        if systemctl is-active NetworkManager &>/dev/null; then
            log_info "Reloading NetworkManager..."
            systemctl reload NetworkManager || log_warn "Failed to reload NetworkManager"
        fi
    fi
fi

log_info ""
log_info "Step 4: final validation"

# bluetooth check
if [[ "$ENABLE_BLUETOOTH" == "1" ]]; then
    if command -v hcitool &>/dev/null && hciconfig "$BT_INTERFACE" &>/dev/null; then
        log_success "Bluetooth controller validated: $BT_INTERFACE"

        # quick controller info
        log_info "Bluetooth controller info:"
        hciconfig "$BT_INTERFACE" | head -2 | sed 's/^/  /' || true
    else
        log_warn "Bluetooth controller validation failed"
        log_warn "Bluetooth scanning may not work if controller is missing"
    fi
fi

# wlan check
if [[ "$ENABLE_WLAN_BEACON" == "1" ]]; then
    if iw dev | grep -q "Interface $WLAN_BEACON_INTERFACE"; then
        log_success "WLAN beacon interface validated: $WLAN_BEACON_INTERFACE"

        # iface info
        log_info "WLAN interface info:"
        iw dev "$WLAN_BEACON_INTERFACE" info | sed 's/^/  /' || true
    else
        log_warn "WLAN beacon interface validation failed"
        log_warn "Beacon capture may not work if interface is missing"
    fi
fi

# done
log_info ""
log_success "----------------------------------------------------"
log_success " Phase 8: bluetooth + wlan beacon setup done"
log_success "----------------------------------------------------"
log_success ""

if [[ "$ENABLE_BLUETOOTH" == "1" ]]; then
    log_success "Bluetooth configuration:"
    log_success "  Interface:      $BT_INTERFACE"
    log_success "  Tools:          hcitool, bluetoothctl"
    log_success "  Permissions:    bluetooth, netdev groups"
    log_success ""
fi

if [[ "$ENABLE_WLAN_BEACON" == "1" ]]; then
    log_success "WLAN beacon configuration:"
    log_success "  Interface:      $WLAN_BEACON_INTERFACE"
    log_success "  Channels:       $WLAN_BEACON_CHANNELS"
    log_success "  Monitor mode:   enabled at runtime"
    log_success ""
fi

log_success "Verification commands:"
if [[ "$ENABLE_BLUETOOTH" == "1" ]]; then
    log_success "  Bluetooth:      hciconfig $BT_INTERFACE"
    log_success "  BT scan test:   timeout 5 hcitool lescan"
fi
if [[ "$ENABLE_WLAN_BEACON" == "1" ]]; then
    log_success "  WLAN info:      iw dev $WLAN_BEACON_INTERFACE info"
    log_success "  WLAN monitor:   iw dev $WLAN_BEACON_INTERFACE set monitor control"
fi
log_success ""

exit 0
