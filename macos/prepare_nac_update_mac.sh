#!/usr/bin/env bash
#
# ============================================================================
#  PSA/Stellantis NAC Wave 4 Firmware Update — USB Preparation Script (macOS)
# ============================================================================
#
#  Vehicle:   Any PSA/Stellantis with NAC Wave 4 infotainment
#  Target:    44.07.33.32_NAC-r0 (latest NAC Wave 4 firmware)
#
#  IMPORTANT: The Citroën/Peugeot/DS/Opel Update app downloads from CloudFront
#  which is INVALID since 4 Feb 2026. This script downloads from the working
#  majestic-web.mpsa.com server instead.
#
#  Prerequisites (install via Homebrew):
#    brew install coreutils    # for gstat (GNU stat)
#    brew install gnu-tar      # for gtar  (GNU tar, handles large archives better)
#
#  Usage:
#    1. Insert a USB drive (any size, will be formatted FAT32)
#    2. Run: bash prepare_nac_update_mac.sh
#    3. Follow the prompts (you will need your NAC UIN — see below)
#
#  If you already downloaded the .tar file:
#    bash prepare_nac_update_mac.sh --tar /path/to/firmware.tar
#
#  How to find your UIN:
#    On the NAC screen: Settings > System info > System version
#    Choose "Export to USB" (insert any FAT32 USB first).
#    Two files are created: instkey_<UIN>.xml and packageslist_<UIN>.txt
#    The UIN is the 20 hex-character string in the filename.
#
# ============================================================================

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
FIRMWARE_VERSION="44.07.33.32_NAC-r0"
UPDATE_ID="001315031692686757"

# UIN will be set interactively or via --uin flag
UIN=""

# The WORKING download URL (majestic-web, NOT CloudFront)
FIRMWARE_URL="https://majestic-web.mpsa.com/nas/eu/mjb00/PSA/mjbsu/PSA_ovip-int-firmware-version_44-07-33-32_NAC-r0_NAC_EUR_WAVE4.tar"
FIRMWARE_FILENAME="PSA_ovip-int-firmware-version_44-07-33-32_NAC-r0_NAC_EUR_WAVE4.tar"

# Expected size of the VALID firmware file
EXPECTED_SIZE=6312212480

# Fallback URL
FALLBACK_URLS=(
    "https://majestic-web.mpsa.com/nas/eu/mjb00/NAC_EU/ovip-int-firmware-version/PSA_ovip-int-firmware-version_44-07-33-32_NAC-r0_NAC_EUR_WAVE4.tar"
)

# License URL is constructed dynamically after UIN is provided

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

    local missing=()
    local install_cmds=()

    # curl ships with macOS
    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi

    # diskutil ships with macOS
    if ! command -v diskutil &>/dev/null; then
        error "diskutil not found — this script requires macOS."
        exit 1
    fi

    # We need GNU stat for reliable byte-count file sizes
    if command -v gstat &>/dev/null; then
        STAT_CMD="gstat"
    elif stat --version &>/dev/null 2>&1; then
        STAT_CMD="stat"  # GNU stat already on PATH
    else
        STAT_CMD="bsd_stat"  # will use macOS stat -f%z
    fi

    # We need GNU tar — macOS bsdtar can struggle with very large archives
    if command -v gtar &>/dev/null; then
        TAR_CMD="gtar"
    else
        TAR_CMD="tar"
        warn "GNU tar (gtar) not found. Using macOS tar — should work, but if"
        warn "extraction fails, install it: brew install gnu-tar"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing: ${missing[*]}"
        echo "  Install with: brew install ${missing[*]}"
        exit 1
    fi

    success "All dependencies satisfied."
    info "Using: ${TAR_CMD} for extraction, ${STAT_CMD} for file sizes"
}

# ── UIN Prompt ─────────────────────────────────────────────────────────────
prompt_uin() {
    if [[ -n "$UIN" ]]; then
        # Already set via --uin flag
        info "UIN provided: ${UIN}"
    else
        header "NAC Unit Identification (UIN)"

        echo "  Your UIN is a 20-character hex string that identifies your NAC unit."
        echo ""
        echo "  How to find it:"
        echo "    1. Insert any FAT32-formatted USB into the car"
        echo "    2. On the NAC screen: Settings > System info > System version"
        echo "    3. Choose 'Export to USB' (or 'Export configuration')"
        echo "    4. Two files are created on the USB:"
        echo "       instkey_<UIN>.xml  and  packageslist_<UIN>.txt"
        echo "    5. The UIN is the 20-character hex string in those filenames"
        echo "       Example: 0D01071F79D4D1E3643C"
        echo ""

        read -rp "Enter your UIN (20 hex characters): " UIN
    fi

    # Validate: must be exactly 20 hex characters
    UIN=$(echo "$UIN" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    if [[ ! "$UIN" =~ ^[0-9A-F]{20}$ ]]; then
        error "Invalid UIN: '${UIN}'"
        error "Must be exactly 20 hexadecimal characters (0-9, A-F)."
        exit 1
    fi

    # Now set derived values
    LICENSE_FILENAME="license_${UIN}_${UPDATE_ID}.key"
    LICENSE_URL="https://majestic-web.mpsa.com/mjf00-web/rest/LicenseDownload?mediaVersion=${UPDATE_ID}&uin=${UIN}"

    success "UIN: ${UIN}"
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

    # List external, physical disks
    local disk_list
    disk_list=$(diskutil list external physical 2>/dev/null || true)

    if [[ -z "$disk_list" ]]; then
        error "No external USB drives detected."
        echo "  Make sure your USB drive is plugged in."
        echo "  If using a USB-C adapter, try a different port."
        exit 1
    fi

    echo "$disk_list"
    echo ""

    # Extract disk identifiers (e.g., disk2, disk3)
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
            local dname
            dname=$(diskutil info "$d" 2>/dev/null | grep "Media Name" | sed 's/.*: *//' || echo "unknown")
            local dsize
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

    # Show drive details
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

    # eraseDisk FAT32 with MBR scheme
    # - FAT32 is the filesystem
    # - NAC_UPDATE is the volume label
    # - MBRFormat creates an MBR partition table (required by the NAC)
    info "Formatting ${DISK_ID} as FAT32 with MBR partition table..."
    diskutil eraseDisk FAT32 NAC_UPDATE MBRFormat "$DISK_ID"

    success "Drive formatted as FAT32 (MBR)."

    # The volume should now be mounted at /Volumes/NAC_UPDATE
    sleep 2
    USB_MOUNT="/Volumes/NAC_UPDATE"

    if [[ ! -d "$USB_MOUNT" ]]; then
        # Try to find the mount point
        USB_MOUNT=$(diskutil info "${DISK_ID}s1" 2>/dev/null | grep "Mount Point" | sed 's/.*: *//' || echo "")
        if [[ -z "$USB_MOUNT" || ! -d "$USB_MOUNT" ]]; then
            error "Drive formatted but mount point not found."
            error "Try: diskutil mount ${DISK_ID}s1"
            exit 1
        fi
    fi

    success "Mounted at: ${USB_MOUNT}"
}

# ── Download firmware (with auto-resume) ───────────────────────────────────
MAX_RETRIES=50          # generous — a 5.9 GB file over a flaky link can drop many times
RETRY_DELAY_BASE=5      # seconds; doubles each consecutive failure, caps at 120s
CURL_TIMEOUT=30         # --connect-timeout
CURL_SPEED_LIMIT=1024   # abort if speed drops below this many bytes/sec ...
CURL_SPEED_TIME=60      # ... for this many seconds (stall detection)

download_with_resume() {
    # Download a single URL with automatic resume-on-failure.
    # Returns 0 on success, 1 if all retries exhausted.
    local url="$1"
    local dest="$2"

    local attempt=0
    local delay=$RETRY_DELAY_BASE

    while (( attempt < MAX_RETRIES )); do
        (( attempt++ )) || true

        # Build curl flags
        local curl_flags=(
            -L                              # follow redirects
            --fail                          # fail on HTTP errors
            --progress-bar                  # show progress
            --connect-timeout "$CURL_TIMEOUT"
            --speed-limit "$CURL_SPEED_LIMIT"
            --speed-time "$CURL_SPEED_TIME"
            -o "$dest"
        )

        # If a partial file exists, resume from where it left off
        if [[ -f "$dest" ]]; then
            local current_size
            current_size=$(get_file_size "$dest" 2>/dev/null || echo 0)
            if (( current_size > 0 )); then
                curl_flags+=( -C - )        # auto-resume
                if (( attempt > 1 )); then
                    info "Resuming from $(( current_size / 1048576 )) MB  (attempt ${attempt}/${MAX_RETRIES})..."
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
            # curl exited 0 — but double-check we got a plausible file
            local final_size
            final_size=$(get_file_size "$dest" 2>/dev/null || echo 0)
            if (( final_size > 1000000000 )); then  # at least ~1 GB
                return 0
            else
                warn "File looks too small (${final_size} bytes). Retrying..."
            fi
        fi

        # If the server doesn't support range requests, curl -C - exits 33.
        # majestic-web.mpsa.com advertises "Accept-Ranges: bytes" but answers
        # Range requests with a full 200 response, so this happens after any
        # stall. Delete the partial file and start over.
        if (( curl_exit == 33 )); then
            warn "Server rejected resume. Starting from the beginning..."
            rm -f "$dest"
            delay=$RETRY_DELAY_BASE
            continue
        fi

        warn "Download interrupted (curl exit ${curl_exit}). Waiting ${delay}s before retry..."
        sleep "$delay"

        # Exponential backoff, capped at 120 s
        delay=$(( delay * 2 ))
        (( delay > 120 )) && delay=120
    done

    return 1
}

download_firmware() {
    local tar_path="$1"

    header "Downloading Firmware"
    info "Version:  ${FIRMWARE_VERSION}"
    info "Size:     ~5.9 GB (${EXPECTED_SIZE} bytes)"
    info "Download will auto-resume if the connection drops."
    echo ""

    # Check for an existing partial download
    if [[ -f "$tar_path" ]]; then
        local existing
        existing=$(get_file_size "$tar_path" 2>/dev/null || echo 0)
        if (( existing == EXPECTED_SIZE )); then
            success "File already fully downloaded (${EXPECTED_SIZE} bytes)."
            return 0
        elif (( existing > 0 )); then
            info "Found partial download: $(( existing / 1048576 )) MB of ~5880 MB"
            info "Will resume automatically."
        fi
    fi

    # Try primary URL
    info "Downloading from majestic-web.mpsa.com..."
    echo "  ${FIRMWARE_URL}"
    echo ""

    if download_with_resume "$FIRMWARE_URL" "$tar_path"; then
        success "Download complete."
        return 0
    fi

    warn "Primary URL exhausted retries. Trying fallback URL..."
    for url in "${FALLBACK_URLS[@]}"; do
        # Start fresh for a different URL (byte ranges might differ)
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
    echo "    curl -L -C - -o '${tar_path}' '${FIRMWARE_URL}'"
    echo ""
    echo "  Or download from rui.saraiva's site:"
    echo "    https://sites.google.com/view/nac-rcc/system/nac/wave-4"
    echo ""
    echo "  Then re-run:  bash $0 --tar /path/to/downloaded.tar"
    exit 1
}

# ── Validate firmware ──────────────────────────────────────────────────────
validate_firmware() {
    local tar_path="$1"

    header "Validating Firmware File"

    local actual_size
    actual_size=$(get_file_size "$tar_path")

    info "File size: ${actual_size} bytes"

    if [[ "$actual_size" -eq "$EXPECTED_SIZE" ]]; then
        success "Size matches the known-good version (${EXPECTED_SIZE} bytes). This is the correct file."
    elif [[ "$actual_size" -eq 6312210432 ]]; then
        echo ""
        error "╔══════════════════════════════════════════════════════════╗"
        error "║  THIS IS THE BROKEN CLOUDFRONT FILE!                    ║"
        error "║  Size: 6,312,210,432 bytes (should be 6,312,212,480)    ║"
        error "║  This WILL fail with 'incompatible hardware'.           ║"
        error "╚══════════════════════════════════════════════════════════╝"
        echo ""
        echo "  You need the correct file from the majestic-web server."
        echo "  Re-run this script without --tar to download automatically,"
        echo "  or get it from: https://sites.google.com/view/nac-rcc/system/nac/wave-4"
        exit 1
    else
        warn "Size ${actual_size} doesn't match expected ${EXPECTED_SIZE}."
        warn "Could be a newer upload. Proceeding — but if it fails in the car,"
        warn "check rui.saraiva's site for the latest known-good file."
    fi

    info "Checking archive integrity..."
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

# ── License file ───────────────────────────────────────────────────────────
prepare_license() {
    local dest_dir="$1"

    header "Preparing License File"

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local license_found=""

    # Search common locations
    for search_path in \
        "${script_dir}/${LICENSE_FILENAME}" \
        "./${LICENSE_FILENAME}" \
        "$HOME/${LICENSE_FILENAME}" \
        "$HOME/Downloads/${LICENSE_FILENAME}" \
        "$HOME/Desktop/${LICENSE_FILENAME}" \
        ; do
        if [[ -f "$search_path" ]]; then
            license_found="$search_path"
            break
        fi
    done

    if [[ -n "$license_found" ]]; then
        info "Found license: ${license_found}"
    else
        info "License not found locally. Downloading from Stellantis server..."
        local tmp_license="/tmp/${LICENSE_FILENAME}"
        if curl -L --fail -s -o "$tmp_license" "$LICENSE_URL" 2>/dev/null; then
            # Check for error response
            if head -c 50 "$tmp_license" | grep -q '"errorCode"\|"file":null'; then
                warn "Server returned an error. License not available for download."
                warn "Proceeding WITHOUT license — the car must have internet access!"
                rm -f "$tmp_license"
                return 1
            fi
            # The server sometimes answers 200 with an empty body. A valid
            # license is an S/MIME signed message (~7 KB).
            if ! head -c 20 "$tmp_license" | grep "MIME-Version" >/dev/null; then
                warn "Downloaded license is empty or invalid ($(get_file_size "$tmp_license") bytes)."
                warn "Re-run the script to try again, or the car must have internet access!"
                rm -f "$tmp_license"
                return 1
            fi
            license_found="$tmp_license"
            success "License downloaded."
        else
            warn "Download failed."
            warn "Proceeding WITHOUT license — the car must have internet access!"
            return 1
        fi
    fi

    mkdir -p "${dest_dir}/license"
    cp "$license_found" "${dest_dir}/license/${LICENSE_FILENAME}"
    success "License placed at: USB:/license/${LICENSE_FILENAME}"
    return 0
}

# ── Extract firmware ───────────────────────────────────────────────────────
extract_to_usb() {
    local tar_path="$1"
    local dest="$2"

    header "Extracting Firmware to USB"

    info "Extracting ~5.9 GB archive. This takes several minutes..."
    info "(Ignore any 'Ignoring unknown extended header' warnings)"
    echo ""

    $TAR_CMD xf "$tar_path" -C "$dest" 2>&1 | grep -v "unknown extended header" || true

    # Verify
    if [[ -d "${dest}/SWL" ]]; then
        success "Extraction complete. SWL/ directory present."
        local update_dir
        update_dir=$(find "${dest}/SWL" -maxdepth 1 -type d -name "001*" | head -1)
        if [[ -n "$update_dir" ]]; then
            success "Update directory: $(basename "$update_dir")"
        fi
    else
        error "SWL/ directory missing after extraction!"
        error "Try using GNU tar:  brew install gnu-tar  then re-run."
        exit 1
    fi
}

# ── Clean macOS artifacts ──────────────────────────────────────────────────
clean_artifacts() {
    local dest="$1"

    header "Cleaning macOS Artifacts"

    info "Removing .DS_Store, .Spotlight, .Trashes, .fseventsd, ._* files..."

    # These macOS metadata files are known to break NAC firmware installs
    find "$dest" -name ".DS_Store" -delete 2>/dev/null || true
    find "$dest" -name "._*" -delete 2>/dev/null || true
    find "$dest" -name ".Spotlight-V100" -exec rm -rf {} + 2>/dev/null || true
    find "$dest" -name ".Trashes" -exec rm -rf {} + 2>/dev/null || true
    find "$dest" -name ".fseventsd" -exec rm -rf {} + 2>/dev/null || true
    find "$dest" -name "__MACOSX" -exec rm -rf {} + 2>/dev/null || true

    # Prevent Spotlight from re-indexing the USB
    touch "${dest}/.metadata_never_index" 2>/dev/null || true

    success "Cleaned. Also placed .metadata_never_index to prevent Spotlight."
}

# ── Summary ────────────────────────────────────────────────────────────────
print_summary() {
    local dest="$1"
    local has_license="$2"

    header "USB Drive Ready!"

    echo -e "${BOLD}USB contents:${NC}"
    find "$dest" -maxdepth 3 -type d \
        ! -name ".*" \
        ! -path "*/.Spotlight*" \
        ! -path "*/.Trashes*" \
        | head -20 \
        | sed "s|${dest}|USB:|"
    echo ""

    if [[ -f "${dest}/license/${LICENSE_FILENAME}" ]]; then
        echo -e "  ${GREEN}✓${NC} License file present"
    else
        echo -e "  ${YELLOW}⚠${NC} No license file — car MUST have internet!"
    fi
    echo ""

    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║              INSTALLATION INSTRUCTIONS                       ║${NC}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  1. Start the car (engine on or READY mode for hybrid)        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    if [[ "$has_license" != "true" ]]; then
    echo -e "${CYAN}║${NC}  2. ${YELLOW}Connect car to WiFi or phone hotspot FIRST${NC}               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     Settings > Connectivity > WiFi                            ${CYAN}║${NC}"
    else
    echo -e "${CYAN}║${NC}  2. Optionally connect to WiFi (recommended as backup)        ${CYAN}║${NC}"
    fi
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  3. Insert USB drive                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  4. System should detect the update automatically             ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     If not: Settings > System info > System update             ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  5. Installation takes 30-45 minutes                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     ${RED}DO NOT turn off the engine during install!${NC}                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  6. System reboots automatically when done                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}Before ejecting:${NC}"
    echo "  Right-click the NAC_UPDATE drive in Finder and choose 'Eject'"
    echo "  (or run: diskutil eject ${DISK_ID})"
    echo ""
    echo -e "${YELLOW}If it still says 'incompatible hardware':${NC}"
    echo "  • Hold the NAC power/volume button 10+ seconds to reset it"
    echo "  • Connect car to WiFi/hotspot before inserting USB"
    echo "  • Try a different USB drive (some units are picky)"
    echo "  • Try a BSI reset: disconnect 12V battery 15 min, reconnect"
    echo ""
    echo "  Community help:"
    echo "    https://www.mittns.de/"
    echo "    https://www.peugeotforums.com/"
    echo "    https://frenchcarforum.co.uk/"
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN}  NAC Wave 4 Firmware Update — USB Prep (macOS)${NC}"
    echo -e "${BOLD}${CYAN}  Target: ${FIRMWARE_VERSION}${NC}"
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
            --uin)
                UIN="$2"
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
                echo "  --uin UIN        Your NAC unit's 20-char hex ID (prompted if omitted)"
                echo "  --tar FILE       Use a pre-downloaded .tar firmware file"
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
    prompt_uin
    select_usb_drive

    if [[ "$skip_format" == false ]]; then
        format_usb
    else
        USB_MOUNT=$(diskutil info "${DISK_ID}s1" 2>/dev/null | grep "Mount Point" | sed 's/.*: *//' || echo "")
        if [[ -z "$USB_MOUNT" || ! -d "$USB_MOUNT" ]]; then
            # Try without partition number
            USB_MOUNT=$(diskutil info "${DISK_ID}" 2>/dev/null | grep "Mount Point" | sed 's/.*: *//' || echo "")
        fi
        if [[ -z "$USB_MOUNT" || ! -d "$USB_MOUNT" ]]; then
            error "Could not find mount point for ${DISK_ID}. Mount it first or remove --skip-format."
            exit 1
        fi
        info "Using existing mount: ${USB_MOUNT}"

        local fstype
        fstype=$(diskutil info "${DISK_ID}s1" 2>/dev/null | grep "Type (Bundle)" | sed 's/.*: *//' || echo "")
        if [[ "$fstype" != *"msdos"* && "$fstype" != *"FAT"* && "$fstype" != *"fat"* ]]; then
            fstype=$(diskutil info "${DISK_ID}s1" 2>/dev/null | grep "File System Personality" | sed 's/.*: *//' || echo "")
            if [[ "$fstype" != *"FAT32"* && "$fstype" != *"MS-DOS"* ]]; then
                warn "Drive may not be FAT32. Detected: ${fstype}"
                warn "The NAC requires FAT32. Consider removing --skip-format."
            fi
        fi
    fi

    # Download or use provided firmware
    if [[ -z "$tar_file" ]]; then
        tar_file="/tmp/${FIRMWARE_FILENAME}"
        # download_firmware handles resume / partial detection internally
        download_firmware "$tar_file"
    else
        if [[ ! -f "$tar_file" ]]; then
            error "File not found: ${tar_file}"
            exit 1
        fi
        info "Using provided file: ${tar_file}"
    fi

    validate_firmware "$tar_file"
    extract_to_usb "$tar_file" "$USB_MOUNT"

    local has_license="false"
    if prepare_license "$USB_MOUNT"; then
        has_license="true"
    fi

    clean_artifacts "$USB_MOUNT"

    # Flush writes
    info "Flushing writes to disk..."
    sync
    # Extra: flush the specific disk's write cache
    diskutil unmountDisk "$DISK_ID" 2>/dev/null || true
    sleep 1
    diskutil mountDisk "$DISK_ID" 2>/dev/null || true
    sleep 2

    # Re-find mount point after remount
    USB_MOUNT=$(diskutil info "${DISK_ID}s1" 2>/dev/null | grep "Mount Point" | sed 's/.*: *//' || echo "")
    if [[ -z "$USB_MOUNT" ]]; then
        USB_MOUNT="/Volumes/NAC_UPDATE"
    fi

    # One final clean of any macOS files created during remount
    if [[ -d "$USB_MOUNT" ]]; then
        find "$USB_MOUNT" -name ".DS_Store" -delete 2>/dev/null || true
        find "$USB_MOUNT" -name "._*" -delete 2>/dev/null || true
        find "$USB_MOUNT" -name ".Spotlight-V100" -exec rm -rf {} + 2>/dev/null || true
        find "$USB_MOUNT" -name ".Trashes" -exec rm -rf {} + 2>/dev/null || true
        find "$USB_MOUNT" -name ".fseventsd" -exec rm -rf {} + 2>/dev/null || true
        touch "${USB_MOUNT}/.metadata_never_index" 2>/dev/null || true
    fi

    print_summary "$USB_MOUNT" "$has_license"

    success "Done! Eject the drive before removing:"
    echo -e "  ${BOLD}diskutil eject ${DISK_ID}${NC}"
    echo ""
}

main "$@"
