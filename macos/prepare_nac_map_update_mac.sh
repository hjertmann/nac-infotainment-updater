#!/usr/bin/env bash
#
# ============================================================================
#  PSA/Stellantis NAC Wave 4 Map Update — USB Preparation Script (macOS)
# ============================================================================
#
#  Vehicle:   Any PSA/Stellantis with NAC Wave 4 infotainment
#  Target:    map-eur 17.0.0-r0 (latest European cartography for NAC Wave 4)
#
#  NOTE: Map updates do NOT require a license file or UIN.
#  NOTE: Install the firmware update (44.07.33.32) BEFORE this map update.
#
#  Prerequisites (install via Homebrew):
#    brew install coreutils gnu-tar
#
#  Usage:
#    1. Insert a USB drive (min 32 GB recommended, will be formatted FAT32)
#    2. Run: bash prepare_nac_map_update_mac.sh
#    3. Follow the prompts
#
#  If you already downloaded the .tar file:
#    bash prepare_nac_map_update_mac.sh --tar /path/to/map.tar
#
# ============================================================================

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
MAP_VERSION="17.0.0-r0"
UPDATE_ID="002315011725520285"

# Download URL (TomTom CDN — this is the official source)
MAP_URL="https://download-cde.tomtom.com/OEM/PSA/MAP/PSA_map-eur_17.0.0-r0-NAC_EUR_WAVE4.tar"
MAP_FILENAME="PSA_map-eur_17.0.0-r0-NAC_EUR_WAVE4.tar"

# Expected size
EXPECTED_SIZE=20403312640

# Fallback URL (older TomTom domain)
FALLBACK_URLS=(
    "http://download.tomtom.com/OEM/PSA/MAP/PSA_map-eur_17.0.0-r0-NAC_EUR_WAVE4.tar"
)

# ── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ────────────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR ]${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}── $* ──${NC}\n"; }

# ── Dependency check ───────────────────────────────────────────────────────
check_dependencies() {
    header "Checking Dependencies"

    if ! command -v diskutil &>/dev/null; then
        error "diskutil not found — this script requires macOS."
        exit 1
    fi

    if command -v gstat &>/dev/null; then
        STAT_CMD="gstat"
    elif stat --version &>/dev/null 2>&1; then
        STAT_CMD="stat"
    else
        STAT_CMD="bsd_stat"
    fi

    if command -v gtar &>/dev/null; then
        TAR_CMD="gtar"
    else
        TAR_CMD="tar"
        warn "GNU tar (gtar) not found. Using macOS tar."
        warn "For a ~19 GB archive, gnu-tar is recommended: brew install gnu-tar"
    fi

    success "Dependencies OK. Using: ${TAR_CMD}, ${STAT_CMD}"
}

# ── Prerequisite check ─────────────────────────────────────────────────────
check_firmware_prerequisite() {
    header "Firmware Prerequisite Check"

    echo "  This map update (17.0.0-r0) requires NAC Wave 4 firmware."
    echo "  Compatible firmware versions: 42.x or 44.x (Wave 4)"
    echo ""
    echo "  If you're not sure, check on the NAC screen:"
    echo "    Settings > System info > System version"
    echo ""

    echo "  What firmware version is currently installed?"
    echo "    1) 44.07.33.32 or newer  (latest Wave 4 — ideal)"
    echo "    2) 44.xx.xx.xx           (older Wave 4 — should work)"
    echo "    3) 42.xx.xx.xx           (early Wave 4 — should work)"
    echo "    4) 31.xx.xx.xx or older  (Wave 3 or older — won't work!)"
    echo "    5) I'm not sure / skip this check"
    echo ""
    read -rp "Select [1-5]: " fw_choice

    case "$fw_choice" in
        1|2|3|5)
            if [[ "$fw_choice" == "5" ]]; then
                warn "Skipping check. If the map install fails, update firmware first."
            else
                success "Firmware is compatible."
            fi
            ;;
        4)
            error "Your firmware is too old for this map update."
            echo ""
            echo "  You need to install the NAC Wave 4 firmware first."
            echo "  Use the firmware update script: prepare_nac_update_mac.sh"
            exit 1
            ;;
        *)
            warn "Invalid choice. Proceeding anyway."
            ;;
    esac
}

get_file_size() {
    local filepath="$1"
    if [[ "$STAT_CMD" == "bsd_stat" ]]; then
        stat -f%z "$filepath"
    else
        $STAT_CMD -c%s "$filepath"
    fi
}

# ── USB Drive Selection ────────────────────────────────────────────────────
select_usb_drive() {
    header "USB Drive Selection"

    echo "Scanning for external drives..."
    echo ""

    local disk_list
    disk_list=$(diskutil list external physical 2>/dev/null || true)

    if [[ -z "$disk_list" ]]; then
        error "No external USB drives detected."
        echo "  Make sure your USB drive is plugged in."
        exit 1
    fi

    echo "$disk_list"
    echo ""

    local disks=()
    while IFS= read -r d; do
        disks+=("$d")
    done < <(echo "$disk_list" | grep -oE '/dev/disk[0-9]+' | sort -u)

    if [[ ${#disks[@]} -eq 0 ]]; then
        error "Could not parse any external disks."
        exit 1
    fi

    if [[ ${#disks[@]} -eq 1 ]]; then
        DISK_ID="${disks[0]}"
        info "Only one external drive found: ${DISK_ID}"
    else
        echo "Multiple external drives found:"
        local i=1
        for d in "${disks[@]}"; do
            local dname dsize
            dname=$(diskutil info "$d" 2>/dev/null | grep "Media Name" | sed 's/.*: *//' || echo "unknown")
            dsize=$(diskutil info "$d" 2>/dev/null | grep "Disk Size" | sed 's/.*: *//' || echo "unknown")
            echo "  $i) $d  —  $dname  ($dsize)"
            ((i++))
        done
        echo ""
        read -rp "Select drive number: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#disks[@]} )); then
            DISK_ID="${disks[$((choice-1))]}"
        else
            error "Invalid selection."
            exit 1
        fi
    fi

    # Check drive size — map is ~19 GB, need at least 22 GB free after format
    local disk_size_bytes
    disk_size_bytes=$(diskutil info "$DISK_ID" 2>/dev/null | grep "Disk Size" | grep -oE '[0-9]+ Bytes' | awk '{print $1}' || echo "0")
    if [[ -n "$disk_size_bytes" ]] && (( disk_size_bytes > 0 && disk_size_bytes < 21474836480 )); then
        local disk_size_gb=$(( disk_size_bytes / 1073741824 ))
        error "Drive is only ${disk_size_gb} GB. The map update is ~19 GB."
        error "You need at least a 32 GB USB drive."
        exit 1
    fi

    echo ""
    diskutil info "$DISK_ID" | grep -E "Device Identifier|Media Name|Disk Size|Removable Media"
    echo ""

    warn "${BOLD}ALL DATA ON ${DISK_ID} WILL BE ERASED!${NC}"
    echo ""
    read -rp "Type 'YES' to confirm: " confirm
    if [[ "$confirm" != "YES" ]]; then
        info "Aborted."
        exit 0
    fi
}

# ── Format USB as FAT32 ───────────────────────────────────────────────────
format_usb() {
    header "Formatting USB Drive as FAT32"

    info "Unmounting ${DISK_ID}..."
    diskutil unmountDisk "$DISK_ID" 2>/dev/null || true

    info "Formatting ${DISK_ID} as FAT32 with MBR partition table..."
    diskutil eraseDisk FAT32 NAC_MAP MBRFormat "$DISK_ID"

    success "Drive formatted as FAT32 (MBR)."

    sleep 2
    USB_MOUNT="/Volumes/NAC_MAP"

    if [[ ! -d "$USB_MOUNT" ]]; then
        USB_MOUNT=$(diskutil info "${DISK_ID}s1" 2>/dev/null | grep "Mount Point" | sed 's/.*: *//' || echo "")
        if [[ -z "$USB_MOUNT" || ! -d "$USB_MOUNT" ]]; then
            error "Drive formatted but mount point not found."
            error "Try: diskutil mount ${DISK_ID}s1"
            exit 1
        fi
    fi

    success "Mounted at: ${USB_MOUNT}"
}

# ── Download with auto-resume ─────────────────────────────────────────────
MAX_RETRIES=50
RETRY_DELAY_BASE=5
CURL_TIMEOUT=30
CURL_SPEED_LIMIT=1024
CURL_SPEED_TIME=60

download_with_resume() {
    local url="$1"
    local dest="$2"

    local attempt=0
    local delay=$RETRY_DELAY_BASE

    while (( attempt < MAX_RETRIES )); do
        (( attempt++ )) || true

        local curl_flags=(
            -L
            --fail
            --progress-bar
            --connect-timeout "$CURL_TIMEOUT"
            --speed-limit "$CURL_SPEED_LIMIT"
            --speed-time "$CURL_SPEED_TIME"
            -o "$dest"
        )

        if [[ -f "$dest" ]]; then
            local current_size
            current_size=$(get_file_size "$dest" 2>/dev/null || echo 0)
            if (( current_size > 0 )); then
                curl_flags+=( -C - )
                if (( attempt > 1 )); then
                    local current_mb=$(( current_size / 1048576 ))
                    local expected_mb=$(( EXPECTED_SIZE / 1048576 ))
                    info "Resuming from ${current_mb} / ${expected_mb} MB  (attempt ${attempt}/${MAX_RETRIES})..."
                fi
            fi
        else
            if (( attempt > 1 )); then
                info "Retrying from scratch  (attempt ${attempt}/${MAX_RETRIES})..."
            fi
        fi

        # Capture curl's exit code directly: reading $? after the if-block
        # would always give 0, so the exit-33 check below never fired.
        local curl_exit=0
        curl "${curl_flags[@]}" "$url" 2>&1 || curl_exit=$?

        if (( curl_exit == 0 )); then
            local final_size
            final_size=$(get_file_size "$dest" 2>/dev/null || echo 0)
            if (( final_size > 5000000000 )); then
                return 0
            else
                warn "File looks too small (${final_size} bytes). Retrying..."
            fi
        fi

        # curl -C - exits 33 when the server ignores the Range header.
        if (( curl_exit == 33 )); then
            warn "Server rejected resume. Starting from the beginning..."
            rm -f "$dest"
            delay=$RETRY_DELAY_BASE
            continue
        fi

        warn "Download interrupted (curl exit ${curl_exit}). Waiting ${delay}s before retry..."
        sleep "$delay"

        delay=$(( delay * 2 ))
        (( delay > 120 )) && delay=120
    done

    return 1
}

download_map() {
    local tar_path="$1"

    header "Downloading European Map"
    info "Version:  map-eur ${MAP_VERSION}"
    info "Size:     ~19 GB (${EXPECTED_SIZE} bytes)"
    info "Source:   TomTom CDN"
    info "Download will auto-resume if the connection drops."
    echo ""

    if [[ -f "$tar_path" ]]; then
        local existing
        existing=$(get_file_size "$tar_path" 2>/dev/null || echo 0)
        if (( existing == EXPECTED_SIZE )); then
            success "File already fully downloaded (${EXPECTED_SIZE} bytes)."
            return 0
        elif (( existing > 0 )); then
            local existing_mb=$(( existing / 1048576 ))
            info "Found partial download: ${existing_mb} MB of ~19,460 MB"
            info "Will resume automatically."
        fi
    fi

    info "Downloading from TomTom CDN..."
    echo "  ${MAP_URL}"
    echo ""

    if download_with_resume "$MAP_URL" "$tar_path"; then
        success "Download complete."
        return 0
    fi

    warn "Primary URL exhausted retries. Trying fallback..."
    for url in "${FALLBACK_URLS[@]}"; do
        rm -f "$tar_path"
        info "Trying: $url"
        if download_with_resume "$url" "$tar_path"; then
            success "Download complete."
            return 0
        fi
    done

    error "All download URLs failed after ${MAX_RETRIES} retries each."
    echo ""
    echo "  Your partial download is kept at: ${tar_path}"
    echo "  You can resume manually with:"
    echo "    curl -L -C - -o '${tar_path}' '${MAP_URL}'"
    echo ""
    echo "  Or download from rui.saraiva's site:"
    echo "    https://sites.google.com/view/nac-rcc/system/nac/wave-4"
    echo ""
    echo "  Then re-run:  bash $0 --tar /path/to/downloaded.tar"
    exit 1
}

# ── Validate map file ─────────────────────────────────────────────────────
validate_map() {
    local tar_path="$1"

    header "Validating Map File"

    local actual_size
    actual_size=$(get_file_size "$tar_path")

    info "File size: ${actual_size} bytes"

    if [[ "$actual_size" -eq "$EXPECTED_SIZE" ]]; then
        success "Size matches expected (${EXPECTED_SIZE} bytes)."
    else
        warn "Size ${actual_size} doesn't match expected ${EXPECTED_SIZE}."
        warn "Could be a re-upload. Proceeding — check forums if install fails."
    fi

    info "Checking archive integrity (this may take a moment for 19 GB)..."
    if $TAR_CMD tf "$tar_path" &>/dev/null; then
        success "Archive is valid."
    else
        error "Archive appears corrupted. Re-download it."
        exit 1
    fi

    # No grep -q: it exits on the first match, tar then dies of SIGPIPE (141)
    # and with pipefail the whole check fails even though SWL/ is there.
    if $TAR_CMD tf "$tar_path" 2>/dev/null | grep "SWL/" >/dev/null; then
        success "Contains SWL/ directory structure."
    else
        error "No SWL/ directory found. Wrong file?"
        exit 1
    fi
}

# ── Extract map to USB ─────────────────────────────────────────────────────
extract_to_usb() {
    local tar_path="$1"
    local dest="$2"

    header "Extracting Map to USB"

    info "Extracting ~19 GB archive. This will take quite a while..."
    info "(USB 2.0 write speeds can make this 15-30 min)"
    echo ""

    $TAR_CMD xf "$tar_path" -C "$dest" 2>&1 | grep -v "unknown extended header" || true

    if [[ -d "${dest}/SWL" ]]; then
        success "Extraction complete. SWL/ directory present."
        local update_dir
        update_dir=$(find "${dest}/SWL" -maxdepth 1 -type d -name "002*" | head -1)
        if [[ -n "$update_dir" ]]; then
            success "Map update directory: $(basename "$update_dir")"
        fi
    else
        error "SWL/ directory missing after extraction!"
        error "Try using GNU tar: brew install gnu-tar  then re-run."
        exit 1
    fi
}

# ── Clean macOS artifacts ──────────────────────────────────────────────────
clean_artifacts() {
    local dest="$1"

    header "Cleaning macOS Artifacts"

    find "$dest" -name ".DS_Store" -delete 2>/dev/null || true
    find "$dest" -name "._*" -delete 2>/dev/null || true
    find "$dest" -name ".Spotlight-V100" -exec rm -rf {} + 2>/dev/null || true
    find "$dest" -name ".Trashes" -exec rm -rf {} + 2>/dev/null || true
    find "$dest" -name ".fseventsd" -exec rm -rf {} + 2>/dev/null || true
    find "$dest" -name "__MACOSX" -exec rm -rf {} + 2>/dev/null || true
    touch "${dest}/.metadata_never_index" 2>/dev/null || true

    success "Cleaned macOS system files."
}

# ── Summary ────────────────────────────────────────────────────────────────
print_summary() {
    local dest="$1"

    header "USB Drive Ready — Map Update!"

    echo -e "${BOLD}USB contents:${NC}"
    find "$dest" -maxdepth 3 -type d \
        ! -name ".*" \
        ! -path "*/.Spotlight*" \
        ! -path "*/.Trashes*" \
        | head -20 \
        | sed "s|${dest}|USB:|"
    echo ""

    echo -e "  ${GREEN}✓${NC} No license file needed for map updates"
    echo ""

    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║              MAP INSTALLATION INSTRUCTIONS                   ║${NC}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${YELLOW}PREREQUISITE: Firmware must be 44.07.33.32 or newer!${NC}        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  (Run the firmware update script first if not done yet)       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  1. Start the car (engine on or READY mode for hybrid)        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  2. Insert USB drive                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  3. System detects the map update automatically               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     You can choose which countries to install                 ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  4. Installation takes 45-90 minutes (19 GB via USB 2.0)      ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     ${RED}Keep the engine running the entire time!${NC}                  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     A long drive is ideal — install while driving.             ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  5. System reboots when done — navigation is then available   ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}Before ejecting:${NC}"
    echo "  Right-click NAC_MAP in Finder > Eject"
    echo "  (or run: diskutil eject ${DISK_ID})"
    echo ""
    echo -e "${YELLOW}Important notes:${NC}"
    echo "  • All existing maps are deleted before new ones install."
    echo "    If you want to keep specific countries, re-select them during install."
    echo "  • No progress bar is shown — this is normal. Just let it run."
    echo "  • If it fails, try a different USB drive (USB 3.0 stick recommended)."
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN}  NAC Wave 4 Map Update — USB Prep (macOS)${NC}"
    echo -e "${BOLD}${CYAN}  Target: map-eur ${MAP_VERSION}${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo ""

    local tar_file=""
    local skip_format=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tar)
                tar_file="$2"
                shift 2
                ;;
            --skip-format)
                skip_format=true
                shift
                ;;
            --help|-h)
                echo "Usage: bash $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --tar FILE       Use a pre-downloaded .tar map file"
                echo "  --skip-format    Don't format USB (must already be FAT32 MBR)"
                echo "  --help           Show this help"
                echo ""
                echo "Homebrew prerequisites:"
                echo "  brew install coreutils gnu-tar"
                echo ""
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    check_dependencies
    check_firmware_prerequisite
    select_usb_drive

    if [[ "$skip_format" == false ]]; then
        format_usb
    else
        USB_MOUNT=$(diskutil info "${DISK_ID}s1" 2>/dev/null | grep "Mount Point" | sed 's/.*: *//' || echo "")
        if [[ -z "$USB_MOUNT" || ! -d "$USB_MOUNT" ]]; then
            USB_MOUNT=$(diskutil info "${DISK_ID}" 2>/dev/null | grep "Mount Point" | sed 's/.*: *//' || echo "")
        fi
        if [[ -z "$USB_MOUNT" || ! -d "$USB_MOUNT" ]]; then
            error "Could not find mount point for ${DISK_ID}."
            exit 1
        fi
        info "Using existing mount: ${USB_MOUNT}"
    fi

    # Download or use provided map file
    if [[ -z "$tar_file" ]]; then
        tar_file="/tmp/${MAP_FILENAME}"
        download_map "$tar_file"
    else
        if [[ ! -f "$tar_file" ]]; then
            error "File not found: ${tar_file}"
            exit 1
        fi
        info "Using provided file: ${tar_file}"
    fi

    validate_map "$tar_file"
    extract_to_usb "$tar_file" "$USB_MOUNT"
    clean_artifacts "$USB_MOUNT"

    # Flush writes
    info "Flushing writes to disk..."
    sync
    diskutil unmountDisk "$DISK_ID" 2>/dev/null || true
    sleep 1
    diskutil mountDisk "$DISK_ID" 2>/dev/null || true
    sleep 2

    USB_MOUNT=$(diskutil info "${DISK_ID}s1" 2>/dev/null | grep "Mount Point" | sed 's/.*: *//' || echo "")
    if [[ -z "$USB_MOUNT" ]]; then
        USB_MOUNT="/Volumes/NAC_MAP"
    fi

    # Final artifact clean after remount
    if [[ -d "$USB_MOUNT" ]]; then
        find "$USB_MOUNT" -name ".DS_Store" -delete 2>/dev/null || true
        find "$USB_MOUNT" -name "._*" -delete 2>/dev/null || true
        find "$USB_MOUNT" -name ".Spotlight-V100" -exec rm -rf {} + 2>/dev/null || true
        find "$USB_MOUNT" -name ".Trashes" -exec rm -rf {} + 2>/dev/null || true
        find "$USB_MOUNT" -name ".fseventsd" -exec rm -rf {} + 2>/dev/null || true
        touch "${USB_MOUNT}/.metadata_never_index" 2>/dev/null || true
    fi

    print_summary "$USB_MOUNT"

    success "Done! Eject the drive before removing:"
    echo -e "  ${BOLD}diskutil eject ${DISK_ID}${NC}"
    echo ""
}

main "$@"
