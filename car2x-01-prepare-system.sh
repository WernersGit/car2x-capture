#!/bin/bash
# phase 1: os updates, hardware config, build deps. run as root.

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

CAR2X_DISABLE_GUI=${CAR2X_DISABLE_GUI:-1}


log_info "STEP 1: OS updates and EEPROM"

log_info "Updating package lists..."
apt-get update

log_info "Full system upgrade..."
apt-get upgrade -y

log_info "Updating EEPROM (non-interactive)..."
if command -v rpi-eeprom-update &>/dev/null; then
    if rpi-eeprom-update -a 2>&1 | grep -q "update available"; then
        log_warn "EEPROM has been updated (takes effect after reboot)"
    else
        log_success "EEPROM is up to date"
    fi
else
    log_warn "EEPROM update utility not found (not critical)"
fi

log_info "STEP 2: Fan and USB power"

log_info "Configuring /boot/firmware/config.txt..."

if [[ ! -f /boot/firmware/config.txt.bak ]]; then
    cp /boot/firmware/config.txt /boot/firmware/config.txt.bak
    log_success "Backed up config.txt to config.txt.bak"
fi

if ! grep -q "dtoverlay=pcie-32bit-dma" /boot/firmware/config.txt; then
    cat >> /boot/firmware/config.txt <<EOF

# Car2X PCIe Configuration (for Atheros AR9300 WiFi card)
dtoverlay=pcie-32bit-dma
dtparam=pciex1
EOF
    log_success "Added PCIe configuration for Atheros AR9300"
else
    log_warn "PCIe configuration already present"
fi

# start the fan earlier so we dont throttle
if ! grep -q "dtparam=fan_temp0" /boot/firmware/config.txt; then
    cat >> /boot/firmware/config.txt <<EOF

# Car2X Fan Configuration (start earlier to prevent thermal throttling)
dtparam=fan_temp0=45000
dtparam=fan_temp1=55000
dtparam=fan_temp2=62500
dtparam=fan_temp3=70000
EOF
    log_success "Added fan configuration"
else
    log_warn "Fan configuration already present"
fi

CAR2X_USB_MAX_CURRENT_ENABLE=${CAR2X_USB_MAX_CURRENT_ENABLE:-1}

if [[ $CAR2X_USB_MAX_CURRENT_ENABLE -eq 1 ]]; then
    if ! grep -q "usb_max_current_enable" /boot/firmware/config.txt; then
        echo "usb_max_current_enable=1" >> /boot/firmware/config.txt
        log_success "Enabled USB max current"
    else
        log_success "USB max current already enabled"
    fi
else
    if grep -q "^usb_max_current_enable" /boot/firmware/config.txt; then
        log_info "Disabling USB max current (CAR2X_USB_MAX_CURRENT_ENABLE=0)"
        sed -i 's/^usb_max_current_enable/#usb_max_current_enable  # Disabled by car2x-01-prepare-system.sh/' /boot/firmware/config.txt
        log_success "USB max current disabled"
    else
        log_info "USB max current already disabled (CAR2X_USB_MAX_CURRENT_ENABLE=0)"
    fi
fi

log_info "Step 2b: internal WLAN config"

CAR2X_ENABLE_INTERNAL_WLAN=${CAR2X_ENABLE_INTERNAL_WLAN:-1}

if [[ $CAR2X_ENABLE_INTERNAL_WLAN -eq 1 ]]; then
    log_info "Internal WLAN enabled (CAR2X_ENABLE_INTERNAL_WLAN=1)"

    if grep -q "^dtoverlay=disable-wifi" /boot/firmware/config.txt; then
        log_warn "Internal WiFi is currently DISABLED (dtoverlay=disable-wifi)"
        log_info "Removing dtoverlay=disable-wifi to enable wlan1..."
        sed -i 's/^dtoverlay=disable-wifi/#dtoverlay=disable-wifi  # Disabled by car2x-01-prepare-system.sh/' /boot/firmware/config.txt
        log_success "Internal WiFi enabled (requires reboot)"
    elif grep -q "#.*dtoverlay=disable-wifi" /boot/firmware/config.txt; then
        log_success "Internal WiFi already enabled (dtoverlay=disable-wifi is commented)"
    else
        log_success "Internal WiFi is enabled (no disable-wifi overlay found)"
    fi

    log_info "Checking WLAN regulatory domain..."
    CURRENT_REGION=$(iw reg get 2>/dev/null | grep "^country" | head -1 | awk '{print $2}' | tr -d ':' | tr -d '\n')

    COUNTRY_CODE="${CAR2X_WLAN_COUNTRY:-DE}"

    if [[ -n "$COUNTRY_CODE" ]]; then
        # env wins even if a region is already set
        COUNTRY_CODE=$(echo "$COUNTRY_CODE" | tr '[:lower:]' '[:upper:]' | tr -d '\n' | tr -d ' ')

        if [[ "$CURRENT_REGION" == "$COUNTRY_CODE" ]]; then
            log_success "WLAN regulatory domain already set to: $COUNTRY_CODE"
        else
            log_info "Setting WLAN regulatory domain from environment: $COUNTRY_CODE (current: ${CURRENT_REGION:-none})"

            if [[ ${#COUNTRY_CODE} -eq 2 ]]; then
                if command -v raspi-config &>/dev/null; then
                    raspi-config nonint do_wifi_country "$COUNTRY_CODE" || log_warn "raspi-config failed"
                fi

                iw reg set "$COUNTRY_CODE" 2>/dev/null || log_warn "iw reg set failed (not critical)"

                mkdir -p /etc/default
                echo "REGDOMAIN=$COUNTRY_CODE" > /etc/default/crda

                log_success "WLAN regulatory domain set to $COUNTRY_CODE"
                log_warn "Full effect after reboot"
            else
                log_error "Invalid country code in environment: $COUNTRY_CODE (must be 2 characters)"
            fi
        fi
    elif [[ -z "$CURRENT_REGION" ]] || [[ "$CURRENT_REGION" == "00" ]]; then
        # no env, no region: ask
        log_warn "WLAN regulatory domain not set (current: ${CURRENT_REGION:-00})"
        log_warn "This is required for WLAN interfaces to function properly"
        log_info ""
        log_info "Please enter your country code (e.g., DE, US, GB, FR):"
        log_info "See: https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2"
        read -r -p "Country code: " COUNTRY_CODE

        COUNTRY_CODE=$(echo "$COUNTRY_CODE" | tr '[:lower:]' '[:upper:]' | tr -d '\n' | tr -d ' ')

        if [[ ${#COUNTRY_CODE} -eq 2 ]]; then
            log_info "Setting WLAN regulatory domain to: $COUNTRY_CODE"

            if command -v raspi-config &>/dev/null; then
                raspi-config nonint do_wifi_country "$COUNTRY_CODE" || log_warn "raspi-config failed"
            fi

            iw reg set "$COUNTRY_CODE" 2>/dev/null || log_warn "iw reg set failed (not critical)"

            mkdir -p /etc/default
            echo "REGDOMAIN=$COUNTRY_CODE" > /etc/default/crda

            log_success "WLAN regulatory domain set to $COUNTRY_CODE"
            log_warn "Changes take effect after reboot"
        else
            log_error "Invalid country code: $COUNTRY_CODE (must be 2 characters)"
            log_error "Skipping WLAN region configuration: WLAN will be blocked!"
        fi
    else
        log_success "WLAN regulatory domain already set: $CURRENT_REGION"
    fi
else
    log_info "Internal WLAN disabled (CAR2X_ENABLE_INTERNAL_WLAN=0)"

    if ! grep -q "^dtoverlay=disable-wifi" /boot/firmware/config.txt; then
        log_info "Adding dtoverlay=disable-wifi to config.txt..."

        # nuke any leftover commented variants
        sed -i 's/^#.*dtoverlay=disable-wifi.*$//' /boot/firmware/config.txt

        echo "" >> /boot/firmware/config.txt
        echo "# Disable internal WiFi (car2x-01-prepare-system.sh)" >> /boot/firmware/config.txt
        echo "dtoverlay=disable-wifi" >> /boot/firmware/config.txt

        log_success "Internal WiFi disabled (requires reboot)"
    else
        log_success "Internal WiFi already disabled"
    fi
fi

log_info "STEP 3: GUI config"

if [[ $CAR2X_DISABLE_GUI -eq 1 ]]; then
    log_info "CAR2X_DISABLE_GUI is on, disabling the desktop environment"
    systemctl set-default multi-user.target
    log_success "System set to multi-user.target (CLI only)"
    log_info "Desktop environment will be off after reboot"
else
    log_info "CAR2X_DISABLE_GUI is off, keeping the desktop environment"
    systemctl set-default graphical.target
    log_success "System set to graphical.target (desktop enabled)"
fi


log_info "STEP 4: installing build dependencies"

log_info "Installing: build-essential git bc bison flex libssl-dev make libncurses5-dev libgcrypt20-dev python3-m2crypto wireless-tools iw ethtool python3-bleak"

apt-get install -y \
    build-essential \
    git \
    bc \
    bison \
    flex \
    libssl-dev \
    make \
    libncurses5-dev \
    libgcrypt20-dev \
    python3-m2crypto \
    wireless-tools \
    iw \
    ethtool \
    python3-bleak

log_success "Build dependencies installed"

# eeprom PSU_MAX_CURRENT, read once write once
PSU_MAX_CURRENT=${CAR2X_PSU_MAX_CURRENT:-4000}

#log_info "=== STEP 5: EEPROM PSU_MAX_CURRENT Configuration ==="
#
#if command -v rpi-eeprom-config &>/dev/null; then
#
#    TMP_EEPROM_CFG="$(mktemp)"
#
#    # READ current EEPROM config (no write yet)
#    rpi-eeprom-config > "$TMP_EEPROM_CFG"
#
#    # Check if PSU_MAX_CURRENT is already set
#    if grep -q "^PSU_MAX_CURRENT=" "$TMP_EEPROM_CFG"; then
#        CURRENT_PSU=$(grep "^PSU_MAX_CURRENT=" "$TMP_EEPROM_CFG" | cut -d= -f2)
#        log_success "PSU_MAX_CURRENT already configured: ${CURRENT_PSU}mA"
#        log_info "Skipping EEPROM write to avoid flash wear"
#        rm -f "$TMP_EEPROM_CFG"
#    else
#        # PSU_MAX_CURRENT not set - offer manual configuration
#        log_warn "PSU_MAX_CURRENT is NOT set in EEPROM (default: 3000mA)"
#        log_warn ""
#        log_warn "WARNING: Modifying EEPROM can cause boot failures!"
#        log_warn "Only change this if you have high-power USB devices"
#        log_warn ""
#        log_info "Recommended setting for high-power USB:"
#        log_info "  PSU_MAX_CURRENT=${PSU_MAX_CURRENT}"
#        log_info ""
#        log_info "If you proceed, the EEPROM editor will open."
#        log_info "Add the following line to the configuration:"
#        log_info ""
#        log_success "PSU_MAX_CURRENT=${PSU_MAX_CURRENT}"
#        log_info ""
#        log_info "Then save and close the editor to continue."
#        log_warn ""
#        
#        read -r -p "Open EEPROM editor now? [y/N]: " EEPROM_EDIT
#        
#        if [[ "$EEPROM_EDIT" =~ ^[Yy]$ ]]; then
#            log_info ""
#            log_info "Opening EEPROM editor..."
#            log_info "Add this line: PSU_MAX_CURRENT=${PSU_MAX_CURRENT}"
#            log_info "Then save (Ctrl+O, Enter) and exit (Ctrl+X)"
#            log_info ""
#            sleep 2
#            
#            # Open interactive EEPROM editor with TTY redirect
#            sudo -E rpi-eeprom-config --edit </dev/tty >/dev/tty 2>&1
#            
#            log_success "EEPROM editor closed"
#            log_warn "Changes take effect after REBOOT"
#            log_warn "If system fails to boot, use EEPROM recovery"
#        else
#            log_info "Skipped - keeping default PSU_MAX_CURRENT (3000mA)"
#            log_info "You can change this later with: sudo rpi-eeprom-config --edit"
#        fi
#        
#        rm -f "$TMP_EEPROM_CFG"
#    fi
#
#else
#    log_warn "rpi-eeprom-config not available, skipping PSU_MAX_CURRENT configuration"
#fi


log_info "Configuring EEPROM PSU_MAX_CURRENT"

if command -v rpi-eeprom-config &>/dev/null; then

    TMPCFG="$(mktemp)"

    rpi-eeprom-config > "$TMPCFG"

    if grep -q "^PSU_MAX_CURRENT=" "$TMPCFG"; then
        CUR=$(grep "^PSU_MAX_CURRENT=" "$TMPCFG" | cut -d= -f2)

        if [[ "$CUR" == "$PSU_MAX_CURRENT" ]]; then
            # avoid the flash wear if its already correct
            log_success "PSU_MAX_CURRENT already configured: ${CUR}mA (matches desired value)"
            log_info "Skipping EEPROM write to avoid flash wear"
            rm -f "$TMPCFG"
        else
            log_warn "PSU_MAX_CURRENT is ${CUR}mA, updating to ${PSU_MAX_CURRENT}mA"
            sed -i "s/^PSU_MAX_CURRENT=.*/PSU_MAX_CURRENT=${PSU_MAX_CURRENT}/" "$TMPCFG"

            rpi-eeprom-config --apply "$TMPCFG"
            rm -f "$TMPCFG"

            log_success "EEPROM PSU_MAX_CURRENT updated to ${PSU_MAX_CURRENT}mA (effective after reboot)"
        fi
    else
        log_info "PSU_MAX_CURRENT not found, adding ${PSU_MAX_CURRENT}mA"
        echo "PSU_MAX_CURRENT=${PSU_MAX_CURRENT}" >> "$TMPCFG"

        rpi-eeprom-config --apply "$TMPCFG"
        rm -f "$TMPCFG"

        log_success "EEPROM PSU_MAX_CURRENT set to ${PSU_MAX_CURRENT}mA (effective after reboot)"
    fi

else
    log_warn "rpi-eeprom-config not available, skipping PSU_MAX_CURRENT configuration"
fi


log_info "Verifying installation"

for t in git make gcc bc bison flex iw; do
    check_command "$t" || exit 1
done

log_success ""
log_success "----------------------------------------------------"
log_success "Phase 1 done: system preparation"
log_success "----------------------------------------------------"
log_success ""

exit 0
