#!/usr/bin/env bash
# car2x-07-pico-setup.sh
# phase 7: pico serial protocol + python deps (placeholder)

set -euo pipefail

# minimal helper load so the banner uses log_*
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/car2x-99-utilities.sh" ]]; then
    source "${SCRIPT_DIR}/car2x-99-utilities.sh"
fi

log_info "----------------------------------------------------"
log_info " Phase 7: Raspberry Pi Pico setup (coming soon)"
log_info "----------------------------------------------------"
log_warn "Pico setup not yet implemented, skipping this phase"
log_success "Phase 7 skipped (coming soon)"
exit 0

# helpers + env (only reached when the early exit is removed)
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

# config with defaults
PICO_DEV="${CAR2X_USB_PICO:-/dev/car2x-pico}"
PICO_BAUDRATE="${CAR2X_PICO_BAUDRATE:-115200}"
ENABLE_PICO="${CAR2X_ENABLE_PICO:-1}"
PICO_PYTHON_SCRIPT="${CAR2X_PICO_PYTHON_SCRIPT:-/usr/local/bin/car2x-pico-protocol.py}"

# entry banner
log_info "----------------------------------------------------"
log_info " Phase 7: Raspberry Pi Pico setup (serial protocol)"
log_info "----------------------------------------------------"
log_info ""

# pico flag toggle
if [[ "$ENABLE_PICO" != "1" ]]; then
    log_warn "Pico service disabled (CAR2X_ENABLE_PICO=$ENABLE_PICO)"
    log_warn "Skipping Pico setup phase"
    exit 0
fi

# root check
if ! check_root; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# step 1: python deps
log_info "Step 1: installing python dependencies"

install_python_packages() {
    local packages_to_install=()
    
    # Check Python 3
    if ! command -v python3 &>/dev/null; then
        packages_to_install+=("python3" "python3-pip")
    fi
    
    # Check for serial library (python3-serial / pyserial)
    if ! python3 -c "import serial" &>/dev/null; then
        packages_to_install+=("python3-serial")
    fi
    
    if [[ ${#packages_to_install[@]} -eq 0 ]]; then
        log_success "All Python packages already installed"
        return 0
    fi
    
    log_info "Installing packages: ${packages_to_install[*]}"
    
    if command -v apt &>/dev/null; then
        apt update -qq || log_warn "apt update had warnings"
        apt install -y "${packages_to_install[@]}" || {
            log_error "Failed to install Python packages"
            return 1
        }
    elif command -v dnf &>/dev/null; then
        dnf install -y "${packages_to_install[@]}" || {
            log_error "Failed to install Python packages via dnf"
            return 1
        }
    else
        log_error "Unsupported package manager"
        return 1
    fi
    
    log_success "Python packages installed successfully"
}

if ! install_python_packages; then
    exit 1
fi

# Verify pyserial is available
if ! python3 -c "import serial" &>/dev/null; then
    log_error "Python serial library not available after installation"
    log_error "Try manual install: pip3 install pyserial"
    exit 1
fi

log_success "Python serial library verified"

# step 2: pico symlink check
log_info ""
log_info "Step 2: validating pico device symlink"

# udev needs a moment after phase 5
MAX_WAIT=10
WAIT_COUNT=0

while [[ ! -e "$PICO_DEV" ]] && [[ $WAIT_COUNT -lt $MAX_WAIT ]]; do
    log_warn "Pico device symlink not found: $PICO_DEV (waiting...)"
    sleep 1
    ((WAIT_COUNT++))
    udevadm trigger --subsystem-match=tty || true
done

if [[ ! -e "$PICO_DEV" ]]; then
    log_warn "Pico device symlink not found: $PICO_DEV"
    log_warn "Pico is optional, the system continues without it"
    log_warn "If a Pico should be present, check phase 5 (USB setup) udev rules"
    log_warn "Check: ls -la /dev/car2x-*"
    # not fatal: pico is optional
else
    # must be a character device
    if [[ ! -c "$PICO_DEV" ]]; then
        log_error "Pico device exists but is not a character device: $PICO_DEV"
        exit 1
    fi

    log_success "Pico device validated: $PICO_DEV"
fi

# step 3: deploy the pico protocol script (placeholder)
log_info ""
log_info "Step 3: deploying pico protocol script"

# Check if user has provided a custom Pico protocol script
CUSTOM_PICO_SCRIPT="${SCRIPT_DIR}/car2x-pico-protocol.py"

if [[ -f "$CUSTOM_PICO_SCRIPT" ]]; then
    log_info "Found custom Pico protocol script: $CUSTOM_PICO_SCRIPT"
    log_info "Installing to: $PICO_PYTHON_SCRIPT"
    
    cp "$CUSTOM_PICO_SCRIPT" "$PICO_PYTHON_SCRIPT" || {
        log_error "Failed to install custom Pico protocol script"
        exit 1
    }
    
    chmod +x "$PICO_PYTHON_SCRIPT"
    log_success "Custom Pico protocol script installed"
else
    # Create placeholder script if none exists
    if [[ ! -f "$PICO_PYTHON_SCRIPT" ]]; then
        log_warn "No custom Pico protocol script found"
        log_info "Creating placeholder script: $PICO_PYTHON_SCRIPT"
        
        cat > "$PICO_PYTHON_SCRIPT" <<'EOF'
#!/usr/bin/env python3
# car2x-pico-protocol.py
# Placeholder for Raspberry Pi Pico serial protocol
# Replace this with your actual serial protocol implementation

import sys
import time
import serial
import json
import os

PICO_DEVICE = os.environ.get('PICO_DEVICE', '/dev/car2x-pico')
PICO_BAUDRATE = int(os.environ.get('PICO_BAUDRATE', '115200'))
CAPTURE_DIR = os.environ.get('CAR2X_DRIVE_PATH', '/home/car2x/captures/runtime')

def log_message(level, message):
    """Log message with timestamp"""
    timestamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    print(f"[{timestamp}] [{level}] {message}", file=sys.stderr, flush=True)

def main():
    log_message("INFO", f"Starting Pico protocol handler")
    log_message("INFO", f"Device: {PICO_DEVICE}")
    log_message("INFO", f"Baudrate: {PICO_BAUDRATE}")
    log_message("INFO", f"Capture path: {CAPTURE_DIR}")
    
    # Ensure capture directory exists
    os.makedirs(CAPTURE_DIR, exist_ok=True)
    
    # Open output file
    output_file = os.path.join(CAPTURE_DIR, f"pico_{int(time.time())}.jsonl")
    log_message("INFO", f"Output file: {output_file}")
    
    try:
        # Open serial connection
        with serial.Serial(PICO_DEVICE, PICO_BAUDRATE, timeout=1) as ser:
            log_message("INFO", "Serial connection opened")
            
            with open(output_file, 'w') as out:
                while True:
                    try:
                        # Read line from Pico
                        line = ser.readline().decode('utf-8', errors='ignore').strip()
                        
                        if not line:
                            continue
                        
                        # Parse JSON event (adjust to your protocol)
                        try:
                            event = json.loads(line)
                            event['timestamp'] = time.time()
                            
                            # Write to output file
                            json.dump(event, out)
                            out.write('\n')
                            out.flush()
                            
                            log_message("DEBUG", f"Received event: {event.get('type', 'unknown')}")
                        except json.JSONDecodeError:
                            # Not JSON - log raw line
                            raw_event = {
                                'timestamp': time.time(),
                                'type': 'raw',
                                'data': line
                            }
                            json.dump(raw_event, out)
                            out.write('\n')
                            out.flush()
                    
                    except KeyboardInterrupt:
                        log_message("INFO", "Shutdown requested")
                        break
                    except Exception as e:
                        log_message("ERROR", f"Read error: {e}")
                        time.sleep(1)
    
    except serial.SerialException as e:
        log_message("ERROR", f"Serial connection failed: {e}")
        log_message("ERROR", f"Check device: {PICO_DEVICE}")
        return 1
    except Exception as e:
        log_message("ERROR", f"Unexpected error: {e}")
        return 1
    
    log_message("INFO", "Pico protocol handler stopped")
    return 0

if __name__ == '__main__':
    sys.exit(main())
EOF
        
        chmod +x "$PICO_PYTHON_SCRIPT"
        log_success "Placeholder Pico protocol script created"
        log_warn "IMPORTANT: Replace $PICO_PYTHON_SCRIPT with your actual protocol implementation"
    else
        log_success "Pico protocol script already exists: $PICO_PYTHON_SCRIPT"
    fi
fi

# step 4: serial port permissions
log_info ""
log_info "Step 4: serial port permissions"

# Ensure car2x user is in dialout group
if id car2x &>/dev/null; then
    if groups car2x | grep -q dialout; then
        log_success "car2x user already in dialout group"
    else
        log_info "Adding car2x user to dialout group..."
        usermod -a -G dialout car2x || {
            log_error "Failed to add car2x to dialout group"
            exit 1
        }
        log_success "car2x user added to dialout group"
    fi
else
    log_warn "car2x user not found (will be created in Phase 2)"
fi

# step 5: final smoke test
log_info ""
log_info "Step 5: final pico setup validation"

# Test Pico device if present
if [[ -c "$PICO_DEV" ]]; then
    log_info "Testing Pico device communication (2 second timeout)..."
    
    if timeout 2 python3 -c "
import serial
try:
    ser = serial.Serial('$PICO_DEV', $PICO_BAUDRATE, timeout=1)
    ser.close()
    print('OK')
except Exception as e:
    print(f'ERROR: {e}')
    exit(1)
" 2>/dev/null | grep -q "OK"; then
        log_success "Pico device communication test passed"
    else
        log_warn "Pico device communication test failed (device may need initialization)"
        log_warn "This is normal if Pico is not sending data yet"
    fi
else
    log_warn "Pico device not present - skipping communication test"
fi

# Verify Python script is executable
if [[ -x "$PICO_PYTHON_SCRIPT" ]]; then
    log_success "Pico Python script is executable: $PICO_PYTHON_SCRIPT"
else
    log_error "Pico Python script is not executable: $PICO_PYTHON_SCRIPT"
    exit 1
fi

# done
log_info ""
log_success "----------------------------------------------------"
log_success " Phase 7: pico setup done"
log_success "----------------------------------------------------"
log_success ""
log_success "Pico configuration summary:"
log_success "  Device:         $PICO_DEV"
log_success "  Baudrate:       $PICO_BAUDRATE"
log_success "  Python script:  $PICO_PYTHON_SCRIPT"
log_success "  Permissions:    dialout group configured"
log_success ""
log_success "Verification commands:"
log_success "  Test device:    python3 -m serial.tools.miniterm $PICO_DEV $PICO_BAUDRATE"
log_success "  Test script:    $PICO_PYTHON_SCRIPT"
log_success "  Check udev:     ls -la /dev/car2x-pico"
log_success ""

exit 0
