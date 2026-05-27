#!/bin/bash
# shared helpers, source me from the other scripts

set -o pipefail

# kept for backwards compat with old scripts that might still reference them
readonly RED=''
readonly GREEN=''
readonly YELLOW=''
readonly BLUE=''
readonly CYAN=''
readonly NC=''

setup_logging() {
    local log_dir="$1"
    local log_file="$2"

    mkdir -p "$log_dir"
    touch "$log_file"
    echo "setup started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$log_file"
}

log_msg() {
    local level=$1
    shift
    local msg="$*"
    local ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "[$ts] [$level] $msg" >> "$LOG_FILE"
    fi
}

log_info() {
    echo "[INFO] $*"
    log_msg "[INFO]" "$*"
}

log_success() {
    echo "[SUCCESS] $*"
    log_msg "[SUCCESS]" "$*"
}

log_warn() {
    echo "[WARN] $*"
    log_msg "[WARN]" "$*"
}

log_error() {
    echo "[ERROR] $*"
    log_msg "[ERROR]" "$*"
}

log_debug() {
    if [[ ${VERBOSE:-0} -eq 1 ]]; then
        echo "[DEBUG] $*"
    fi
    log_msg "[DEBUG]" "$*"
}

log_simple() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
    echo "$msg"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

log_dated() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

error_exit() {
    log_error "$*"
    exit 1
}

die() {
    log_error "$*"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use: sudo)"
        return 1
    fi
    log_success "Running as root"
    return 0
}

check_command() {
    local c=$1
    if command -v "$c" &>/dev/null; then
        log_success "$c available"
        return 0
    else
        log_error "$c not found"
        return 1
    fi
}

check_commands() {
    local missing=0
    for c in "$@"; do
        if ! check_command "$c"; then
            missing=1
        fi
    done
    return $missing
}

# file or dir present?
check_path_exists() {
    local p=$1
    local kind=${2:-"path"}

    if [[ ! -e "$p" ]]; then
        log_error "$kind not found: $p"
        return 1
    fi
    log_success "Found: $p"
    return 0
}

# disk space in kB
check_disk_space() {
    local mnt=${1:-"/"}
    local min_kb=${2:-5242880}

    local free=$(df "$mnt" | awk 'NR==2 {print $4}')
    if [[ $free -lt $min_kb ]]; then
        log_error "Not enough disk space: $(( free / 1048576 )) MB available (need $(( min_kb / 1048576 )) MB)"
        return 1
    fi
    log_success "Disk space: $(( free / 1048576 )) MB available"
    return 0
}

check_internet() {
    if ping -c 1 8.8.8.8 &>/dev/null; then
        log_success "Internet connectivity verified"
        return 0
    else
        log_warn "No internet connectivity detected"
        return 1
    fi
}

check_no_apt_conflicts() {
    if pgrep -f "apt-get|dpkg" >/dev/null; then
        log_error "Another apt/dpkg process is running"
        return 1
    fi
    log_success "No conflicting processes detected"
    return 0
}

detect_gps_device() {
    log_simple "Auto-detecting GPS device..."

    local tmo=${1:-10}
    local i=0

    while (( i < tmo )); do
        for d in /dev/ttyUSB* /dev/ttyACM* /dev/ttyAMA*; do
            if [[ ! -c "$d" ]]; then continue; fi

            if timeout 2 stdbuf -oL cat "$d" 2>/dev/null | grep -q '^\$GP' | head -1; then
                log_simple "Found GPS device: $d"
                echo "$d"
                return 0
            fi
        done

        ((i++))
        if (( i < tmo )); then
            sleep 1
        fi
    done

    log_simple "WARNING: GPS auto-detection failed"
    return 1
}

# same idea but for the pico (sends json)
detect_pico_device() {
    log_simple "Auto-detecting Pico USV device..."

    local tmo=${1:-5}
    local i=0

    while (( i < tmo )); do
        for d in /dev/ttyUSB* /dev/ttyACM*; do
            if [[ ! -c "$d" ]]; then continue; fi

            if timeout 1 stdbuf -oL cat "$d" 2>/dev/null | grep -q '{"event"' | head -1; then
                log_simple "Found Pico device: $d"
                echo "$d"
                return 0
            fi
        done

        ((i++))
        if (( i < tmo )); then
            sleep 1
        fi
    done

    log_simple "WARNING: Pico device not found"
    return 1
}

ensure_dir() {
    local d=$1
    local owner=${2:-"root:root"}
    local mode=${3:-"755"}

    if [[ ! -d "$d" ]]; then
        mkdir -p "$d"
        chmod "$mode" "$d"
        chown "$owner" "$d"
        log_success "Created directory: $d"
    else
        log_debug "Directory already exists: $d"
    fi
}

backup_file() {
    local f=$1
    local bak="${f}.bak"

    if [[ -f "$f" ]] && [[ ! -f "$bak" ]]; then
        cp "$f" "$bak"
        log_success "Backed up $f to ${bak##*/}"
        return 0
    elif [[ ! -f "$f" ]]; then
        log_debug "File does not exist: $f"
        return 1
    else
        log_debug "Backup already exists: $bak"
        return 1
    fi
}

find_next_number() {
    local pat=$1
    local d=${2:-.}

    local mx=0
    for f in "$d"/$pat; do
        if [[ -f "$f" ]]; then
            local n=$(basename "$f" | sed 's/[^0-9]*\([0-9]*\).*/\1/')
            if [[ "$n" =~ ^[0-9]+$ ]] && (( n > mx )); then
                mx=$n
            fi
        fi
    done
    echo $((mx + 1))
}

read_env_var() {
    local f=$1
    local k=$2

    if [[ -f "$f" ]]; then
        grep "^${k}=" "$f" | cut -d= -f2 | tr -d '\n'
        return 0
    fi
    return 1
}

write_env_var() {
    local f=$1
    local k=$2
    local v=$3

    # drop existing line first
    if [[ -f "$f" ]]; then
        grep -v "^${k}=" "$f" > "${f}.tmp"
        mv "${f}.tmp" "$f"
    fi

    echo "${k}=${v}" >> "$f"
}

# send TERM then KILL to a pid if its alive
kill_if_running() {
    local pid=$1
    local sig=${2:-TERM}

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        log_info "Stopping process (PID ${pid})..."
        kill -"$sig" "$pid" 2>/dev/null || true
        sleep 1
        kill -KILL "$pid" 2>/dev/null || true
        return 0
    fi
    return 1
}

# status json, used by the master setup
init_status() {
    local status_file=$1
    cat > "$status_file" <<EOF
{
  "start_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "steps": {
    "01_prepare_system": "pending",
    "02_create_user": "pending",
    "03_patch_kernel": "pending",
    "04_build_drivers": "pending",
    "05_peripheral_setup": "pending",
    "06_gps_setup": "pending",
    "07_pico_setup": "pending",
    "08_bluetooth_wlan_setup": "pending",
    "09_deploy_services": "pending"
  },
  "completed_steps": [],
  "failed_step": null,
  "log_file": "${LOG_FILE:-}"
}
EOF
}

update_status() {
    local f=$1
    local step=$2
    local s=$3

    log_debug "Updating status: $step -> $s"
    sed -i "s/\"$step\": \"[^\"]*\"/\"$step\": \"$s\"/" "$f"
}

load_status() {
    local f=$1
    if [[ -f "$f" ]]; then
        log_debug "Loading previous status from $f"
        cat "$f"
    fi
}

print_header() {
    local t=$1
    log_info ""
    log_info "----------------------------------------------------"
    log_info " $t"
    log_info "----------------------------------------------------"
    log_info ""
}

print_footer() {
    local t=$1
    log_success ""
    log_success "----------------------------------------------------"
    log_success "$t"
    log_success "----------------------------------------------------"
    log_success ""
}

export_script_info() {
    local name=$1
    local ver=$2

    export CAR2X_SCRIPT_NAME="$name"
    export CAR2X_SCRIPT_VERSION="$ver"
    export CAR2X_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

