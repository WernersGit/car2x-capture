#!/usr/bin/env bash
# phase 5: peripheral setup
# - discover ttyACM* / ttyUSB* (gps, pico)
# - propose auto-assignment, fall back to manual
# - write stable udev rules
# - pin wlan iface names: atheros -> wlan0, broadcom -> wlan1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${SCRIPT_DIR}/car2x-99-utilities.sh" ]]; then
    echo "log_error: car2x-99-utilities.sh not found in $SCRIPT_DIR"
    exit 1
fi
source "${SCRIPT_DIR}/car2x-99-utilities.sh"

if [[ -f /etc/car2x/environment ]]; then
    source /etc/car2x/environment
elif [[ -f "${SCRIPT_DIR}/environment" ]]; then
    source "${SCRIPT_DIR}/environment"
fi

if [[ $EUID -ne 0 ]]; then
    log_error "You must run this script as root!"
    exit 1
fi

get_udev_env() {
    local d="$1"
    local key="$2"
    udevadm info "$d" 2>/dev/null | grep -m1 "^E: $key=" | cut -d= -f2- || true
}

get_display_name() {
    local d="$1"
    local n
    n=$(get_udev_env "$d" "ID_SERIAL")
    echo "${n:-<unknown>}"
}

# usb attrs the udev rule needs
get_usb_vendor() { get_udev_env "$1" "ID_USB_VENDOR_ID"; }
get_usb_product() { get_udev_env "$1" "ID_USB_MODEL_ID"; }
get_usb_serial_short() { get_udev_env "$1" "ID_USB_SERIAL_SHORT"; }

is_pico() { [[ "$(get_usb_vendor "$1")" == "$CAR2X_USB_PICO_VENDOR_ID" && "$(get_usb_product "$1")" == "$CAR2X_USB_PICO_MODEL_ID" ]]; }
is_gps() { [[ "$(get_usb_vendor "$1")" == "$CAR2X_USB_GPS_VENDOR_ID" && "$(get_usb_product "$1")" == "$CAR2X_USB_GPS_MODEL_ID" ]]; }

log_info "Discovering serial USB devices (ttyACM*, ttyUSB*) ..."

DEVICE_LIST=()
for dev in /dev/ttyACM* /dev/ttyUSB*; do
    [[ -c "$dev" ]] || continue
    DEVICE_LIST+=("$dev")
done

if [[ ${#DEVICE_LIST[@]} -eq 0 ]]; then
    log_warn "No serial USB devices found."
    exit 0
fi

echo
echo "Found devices:"
echo "------------------------------------------------------------"
for i in "${!DEVICE_LIST[@]}"; do
    dev="${DEVICE_LIST[$i]}"
    display=$(get_display_name "$dev")
    vendor=$(get_usb_vendor "$dev")
    product=$(get_usb_product "$dev")
    serial=$(get_usb_serial_short "$dev")
    [[ $(is_gps "$dev") == true ]] && serial="<none>"

    printf "[%d] %-12s\n" "$((i+1))" "$dev"
    echo "     Name   : $display"
    echo "     Vendor : ${vendor:-?}"
    echo "     Product: ${product:-?}"
    echo "     Serial : ${serial:-<none>}"
done

# existing udev file?

if [[ -f "${CAR2X_UDEV_RULE_FILE}" ]]; then
    echo
    log_warn "A udev rule file already exists:"
    echo "  ${CAR2X_UDEV_RULE_FILE}"
    echo
    read -rp "Do you want to modify the existing configuration? [y/N] " ans
    case "$ans" in
        y|Y) log_info "Configuration will be updated." ;;
        *)
            log_info "Keeping existing USB device configuration."
            # skip the usb assign steps, go straight to wlan
            GPS_DEV=""
            PICO_DEV=""
            SKIP_USB_SETUP=1
            ;;
    esac
fi

# auto-assign suggestion

if [[ -z "${SKIP_USB_SETUP:-}" ]]; then
    AUTO_GPS=""
    AUTO_PICO=""

    for dev in "${DEVICE_LIST[@]}"; do
        if is_gps "$dev"; then AUTO_GPS="$dev"; fi
        if is_pico "$dev"; then AUTO_PICO="$dev"; fi
    done

    echo
    if [[ -n "$AUTO_GPS" || -n "$AUTO_PICO" ]]; then
        echo "Suggested automatic assignment:"
        [[ -n "$AUTO_GPS" ]] && echo "  GPS  -> $AUTO_GPS ($(get_display_name "$AUTO_GPS"))"
        [[ -n "$AUTO_PICO" ]] && echo "  Pico -> $AUTO_PICO ($(get_display_name "$AUTO_PICO"))"
        read -rp "Accept automatic assignment? [Y/n] " ans
        case "$ans" in
            n|N) log_info "Manual assignment will follow." ;;
            *)  GPS_DEV="$AUTO_GPS"; PICO_DEV="$AUTO_PICO"; log_info "Automatic assignment accepted." ;;
        esac
    fi
fi

# manual fallback if nothing was auto-picked

if [[ -z "${SKIP_USB_SETUP:-}" ]]; then
    if [[ -z "${GPS_DEV:-}" || -z "${PICO_DEV:-}" ]]; then
        for dev in "${DEVICE_LIST[@]}"; do
            [[ "$dev" == "$GPS_DEV" || "$dev" == "$PICO_DEV" ]] && continue
            display=$(get_display_name "$dev")
            vendor=$(get_usb_vendor "$dev")
            product=$(get_usb_product "$dev")
            serial=$(get_usb_serial_short "$dev")
            [[ $(is_gps "$dev") == true ]] && serial="<none>"

            echo
            echo "------------------------------------------------------------"
            echo "Device: $dev"
            echo "  Name   : $display"
            echo "  Vendor : ${vendor:-?}"
            echo "  Product: ${product:-?}"
            echo "  Serial : ${serial:-<none>}"
            echo
            echo "Choose type:"
            echo "  1) GPS (GT-U7 / GNSS)"
            echo "  2) Pico / Controller"
            echo "  3) Ignore"
            read -rp "Choice [1-3]: " choice

            case "$choice" in
                1) GPS_DEV="$dev" ;;
                2) PICO_DEV="$dev" ;;
                *) ;;
            esac
        done
    fi
fi

# sanity

if [[ -z "${SKIP_USB_SETUP:-}" ]]; then
    if [[ -n "$GPS_DEV" && -n "$PICO_DEV" && "$GPS_DEV" == "$PICO_DEV" ]]; then
        log_error "GPS and Pico cannot be the same device."
        exit 1
    fi

    [[ -z "$GPS_DEV" ]] && log_warn "No GPS device assigned."
fi

# write or patch the udev rules

if [[ -z "${SKIP_USB_SETUP:-}" ]]; then
    log_info "Updating udev file: ${CAR2X_UDEV_RULE_FILE}"

if [[ -f "$CAR2X_UDEV_RULE_FILE" ]]; then
    log_info "Existing udev file found. Patching rules."

    [[ -n "$GPS_DEV" ]] && sed -i \
        '/^# GT-U7 GPS$/,/^$/{
            s|^SUBSYSTEM=="tty".*car2x-gps.*|SUBSYSTEM=="tty", ATTRS{idVendor}=="1546", ATTRS{idProduct}=="01a7", SYMLINK+="car2x-gps", GROUP="dialout", MODE="0660"|
        }' "$CAR2X_UDEV_RULE_FILE"

    if [[ -n "$PICO_DEV" ]]; then
        vendor=$(get_usb_vendor "$PICO_DEV")
        product=$(get_usb_product "$PICO_DEV")
        serial=$(get_usb_serial_short "$PICO_DEV")
        sed -i \
        "/^# Pico$/,/^$/{
            s|^SUBSYSTEM==\"tty\".*car2x-pico.*|SUBSYSTEM==\"tty\", ATTRS{idVendor}==\"$vendor\", ATTRS{idProduct}==\"$product\", ATTRS{serial}==\"$serial\", SYMLINK+=\"car2x-pico\", GROUP=\"dialout\", MODE=\"0660\"|
        }" "$CAR2X_UDEV_RULE_FILE"
    fi

    log_success "udev rules patched succesfully."

else
    log_info "No existing udev file found. Creating new one from template."

    cat > "$CAR2X_UDEV_RULE_FILE" <<'EOF'
# Car2X Device Permissions
# Allow car2x user to access GPS and Pico devices without root

# GT-U7 GPS
SUBSYSTEM=="tty", ATTRS{idVendor}=="1546", ATTRS{idProduct}=="01a7", SYMLINK+="car2x-gps", GROUP="dialout", MODE="0660"

# Pico
SUBSYSTEM=="tty", ATTRS{idVendor}=="REPLACE_VENDOR", ATTRS{idProduct}=="REPLACE_PRODUCT", ATTRS{serial}=="REPLACE_SERIAL", SYMLINK+="car2x-pico", GROUP="dialout", MODE="0660"

# Regular UART devices
SUBSYSTEM=="tty", KERNEL=="ttyACM*", MODE="0666", GROUP="dialout"
EOF

    if [[ -n "$PICO_DEV" ]]; then
        vendor=$(get_usb_vendor "$PICO_DEV")
        product=$(get_usb_product "$PICO_DEV")
        serial=$(get_usb_serial_short "$PICO_DEV")
        sed -i "s|REPLACE_VENDOR|$vendor|; s|REPLACE_PRODUCT|$product|; s|REPLACE_SERIAL|$serial|" "$CAR2X_UDEV_RULE_FILE"
    fi

    log_success "udev rules created successfully."
fi  # end of: if [[ -f "$CAR2X_UDEV_RULE_FILE" ]]

fi  # end of: if [[ -z "${SKIP_USB_SETUP:-}" ]]

# pin stable wlan iface names

log_info "Configuring stable WLAN interface naming..."

WLAN_UDEV_RULE="/etc/udev/rules.d/70-car2x-network-names.rules"

cat > "$WLAN_UDEV_RULE" <<'EOF'
# udev rules for stable WLAN interface naming
# Car2X Project: Ensure Atheros PCIe card = wlan0, Broadcom internal = wlan1

# Atheros AR9300 (PCIe, 802.11p OCB capable) -> wlan0
# Match by driver (ath9k) and subsystem (pci)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="ath9k", SUBSYSTEMS=="pci", NAME="wlan0"

# Broadcom BCM4345 (internal SDIO, beacon capture) -> wlan1  
# Match by driver (brcmfmac) and subsystem (sdio)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="brcmfmac", SUBSYSTEMS=="sdio", NAME="wlan1"
EOF

chmod 644 "$WLAN_UDEV_RULE"
log_success "Created WLAN interface naming rule: $WLAN_UDEV_RULE"
log_info "After next boot: Atheros PCIe = wlan0, Broadcom internal = wlan1"

# usb archive disk selection
log_info ""
log_info "STEP 8: USB archive storage configuration"
log_info "Select USB storage device (stick/HDD) for trip data archiving"
log_info ""

# list usb block devs, skip the boot disk and system partitions
BOOT_DEVICE=$(lsblk -ndo PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || echo "mmcblk0")
mapfile -t USB_DEVICES < <(lsblk -ndo NAME,SIZE,TYPE,TRAN,MODEL | grep -E "usb|uas" | grep -v "$BOOT_DEVICE" | awk '{print $1}' || true)

if [[ ${#USB_DEVICES[@]} -eq 0 ]]; then
    log_warn "No USB storage devices detected (only GPS/Pico are expected at this point)"
    log_info "You can run this script again after connecting a USB stick/HDD"
    CAR2X_USB_ARCHIVE=""
else
    log_info "Detected USB storage devices:"
    echo

    for i in "${!USB_DEVICES[@]}"; do
        DEV="${USB_DEVICES[$i]}"
        SIZE=$(lsblk -ndo SIZE "/dev/$DEV" 2>/dev/null || echo "?")
        MODEL=$(lsblk -ndo MODEL "/dev/$DEV" 2>/dev/null || echo "Unknown")
        VENDOR=$(lsblk -ndo VENDOR "/dev/$DEV" 2>/dev/null || echo "")
        TRAN=$(lsblk -ndo TRAN "/dev/$DEV" 2>/dev/null || echo "usb")

        # how many partitions on this disk
        PARTITIONS=$(lsblk -nlo NAME "/dev/$DEV" | tail -n +2 | wc -l)
        PART_INFO=""
        if [[ $PARTITIONS -gt 0 ]]; then
            PART_INFO=" (${PARTITIONS} partition(s))"
        fi

        # show free space when its mounted
        FREE_SPACE=""
        FIRST_PART=$(lsblk -nlo NAME "/dev/$DEV" | tail -n +2 | head -1 || echo "")
        if [[ -n "$FIRST_PART" ]]; then
            MOUNT_POINT=$(lsblk -nlo MOUNTPOINT "/dev/$FIRST_PART" 2>/dev/null || echo "")
            if [[ -n "$MOUNT_POINT" ]]; then
                FREE=$(df -h "$MOUNT_POINT" 2>/dev/null | tail -1 | awk '{print $4}')
                FREE_SPACE=" | Free: $FREE"
            fi
        fi

        log_info "  [$((i+1))] /dev/$DEV - $SIZE - $VENDOR $MODEL$PART_INFO$FREE_SPACE"
    done
    
    echo
    read -rp "Select USB backup device [1-${#USB_DEVICES[@]}] or [s]kip: " SELECTION
    
    if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [[ $SELECTION -ge 1 ]] && [[ $SELECTION -le ${#USB_DEVICES[@]} ]]; then
        SELECTED_DEV="${USB_DEVICES[$((SELECTION-1))]}"
        CAR2X_USB_ARCHIVE="/dev/$SELECTED_DEV"

        log_success "Selected: $CAR2X_USB_ARCHIVE"

        # offer to reformat
        echo
        log_warn "WARNING: Formatting will ERASE ALL DATA on $CAR2X_USB_ARCHIVE!"
        SIZE=$(lsblk -ndo SIZE "$CAR2X_USB_ARCHIVE")
        log_info "Device size: $SIZE"
        echo
        read -rp "Format device? [y/N]: " FORMAT_CONFIRM

        if [[ "$FORMAT_CONFIRM" =~ ^[Yy]$ ]]; then
            log_info "Unmounting any existing partitions..."
            for part in $(lsblk -nlo NAME "$CAR2X_USB_ARCHIVE" | tail -n +2); do
                umount "/dev/$part" 2>/dev/null || true
            done

            log_info "Creating new GPT partition table..."
            parted -s "$CAR2X_USB_ARCHIVE" mklabel gpt

            log_info "Creating single ext4 partition..."
            parted -s "$CAR2X_USB_ARCHIVE" mkpart primary ext4 0% 100%

            # let the kernel pick up the new partition
            sleep 2
            partprobe "$CAR2X_USB_ARCHIVE" 2>/dev/null || true
            sleep 1

            # build the partition node name (sda1 / nvme0n1p1 / etc.)
            PARTITION="${CAR2X_USB_ARCHIVE}1"
            if [[ ! -b "$PARTITION" ]]; then
                # nvme uses pN suffix
                PARTITION="${CAR2X_USB_ARCHIVE}p1"
            fi

            log_info "Formatting $PARTITION as ext4 with label 'CAR2X_ARCHIVE'..."
            mkfs.ext4 -F -L "CAR2X_ARCHIVE" "$PARTITION"

            log_success "Formatting complete!"

            # the udev rule should target the partition
            CAR2X_USB_ARCHIVE="$PARTITION"
        else
            log_info "Skipping format, using existing partition layout"

            # pick the first partition if there is one
            FIRST_PART=$(lsblk -nlo NAME "$CAR2X_USB_ARCHIVE" | tail -n +2 | head -1 || echo "")
            if [[ -n "$FIRST_PART" ]]; then
                CAR2X_USB_ARCHIVE="/dev/$FIRST_PART"
                log_info "Using partition: $CAR2X_USB_ARCHIVE"
            fi
        fi

        # uuid is the most reliable match for removable media
        UUID=$(blkid -s UUID -o value "$CAR2X_USB_ARCHIVE" 2>/dev/null || echo "")

        if [[ -z "$UUID" ]]; then
            log_error "Cannot determine UUID of $CAR2X_USB_ARCHIVE"
            log_warn "Skipping udev rule creation"
        else
            log_info "Device UUID: $UUID"

            # archive udev rule
            ARCHIVE_UDEV_RULE="/etc/udev/rules.d/69-car2x-archive.rules"
            cat > "$ARCHIVE_UDEV_RULE" <<EOF
# udev rule for Car2X archive storage device
# UUID-based matching for reliable identification
# Creates symlink: /dev/car2x-archive

ENV{ID_FS_UUID}=="$UUID", SYMLINK+="car2x-archive", MODE="0660", GROUP="car2x"
EOF
            chmod 644 "$ARCHIVE_UDEV_RULE"
            log_success "Created archive device udev rule: $ARCHIVE_UDEV_RULE"
            log_info "Symlink will be: /dev/car2x-archive -> $CAR2X_USB_ARCHIVE"
        fi

    elif [[ "$SELECTION" =~ ^[Ss]$ ]]; then
        log_info "Skipping USB archive storage configuration"
        CAR2X_USB_ARCHIVE=""
    else
        log_warn "Invalid selection, skipping USB archive storage"
        CAR2X_USB_ARCHIVE=""
    fi
fi  # end of: if [[ ${#USB_DEVICES[@]} -eq 0 ]]

# the environment file does not need updating, the udev symlinks are enough
# /dev/car2x-archive will appear after a usb replug or reboot

log_info "Reloading udev rules..."
udevadm control --reload-rules
udevadm trigger

# result check

echo
log_info "Result:"
[[ -n "$CAR2X_USB_GPS"  ]] && ls -l /dev/car2x-gps 2>/dev/null || log_warn "car2x-gps not present"
[[ -n "$CAR2X_USB_PICO" ]] && ls -l /dev/car2x-pico 2>/dev/null || log_warn "car2x-pico not present"

# the archive symlink only shows up after replug/reboot
if [[ -n "${CAR2X_USB_ARCHIVE:-}" ]]; then
    if ls -l /dev/car2x-archive 2>/dev/null; then
        log_success "Archive storage ready"
    else
        log_info "Archive configured: ${CAR2X_USB_ARCHIVE} (symlink will appear after USB replug/reboot)"
    fi
else
    log_info "car2x-archive not configured (optional)"
fi

# done

echo
log_success "Peripheral setup complete (USB devices + WLAN interface naming)"
log_warn "Reboot required for WLAN interface names to take effect!"
echo

exit 0
