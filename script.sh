#!/bin/bash
VERSION="0.3.1"

# --- COLORS & STYLING ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# --- LOGGING HELPERS ---
header()  { echo -e "\n${BOLD}${CYAN}=== $1 ===${RESET}"; }
info()    { echo -e "${BLUE}[INFO]${RESET} $1"; }
success() { echo -e "${GREEN}[OK]${RESET} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $1"; }
error()   { echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }  # Replaces 'die'

# --- SELF-UPDATE ---
SCRIPT_URL="https://raw.githubusercontent.com/TeamGloomy/Fly-FastOS-DSF-Update/main/script.sh"
SCRIPT_LOCATION="${BASH_SOURCE[@]}"
SELF_UPDATER_SCRIPT="/tmp/fly_fastos_selfupdater.sh"

self_update() {
    rm -f "$SELF_UPDATER_SCRIPT"
    TMP_FILE=$(mktemp -p "" "XXXXX.sh")
    
    # Download new script
    if wget -q "$SCRIPT_URL" -O "$TMP_FILE"; then
        # Check integrity
        if ! head -n 1 "$TMP_FILE" | grep -q "^#!/bin/bash"; then
             warn "Downloaded update is not a valid script. Skipping update."
             rm -f "$TMP_FILE"
             return
        fi

        # Extract new version
        NEW_VER=$(grep "^VERSION=" "$TMP_FILE" | head -n 1 | cut -d'"' -f2 | tr -d '\r')
        
        if [ -z "$NEW_VER" ]; then
            warn "Could not detect version in remote script. Skipping update."
            rm -f "$TMP_FILE"
            return
        fi

        ABS_SCRIPT_PATH=$(readlink -f "$SCRIPT_LOCATION")
        
        # Check if up-to-date
        if [ "$VERSION" == "$NEW_VER" ]; then
             # info "Script is up-to-date ($VERSION)."
             rm -f "$TMP_FILE"
             return
        fi

        # Compare versions
        if [[ "$VERSION" < "$NEW_VER" ]]; then
            echo -e "${BOLD}${YELLOW}Update Available:${RESET} ${RED}$VERSION${RESET} -> ${GREEN}$NEW_VER${RESET}"
            info "Updating script..."

            echo "#!/bin/bash" > "$SELF_UPDATER_SCRIPT"
            echo "cp \"$TMP_FILE\" \"$ABS_SCRIPT_PATH\"" >> "$SELF_UPDATER_SCRIPT"
            echo "rm -f \"$TMP_FILE\"" >> "$SELF_UPDATER_SCRIPT"
            echo "echo -e '${GREEN}[OK] Script updated. Restarting...${RESET}'" >> "$SELF_UPDATER_SCRIPT"
            echo "exec \"$ABS_SCRIPT_PATH\" \"\$@\"" >> "$SELF_UPDATER_SCRIPT"

            chmod +x "$SELF_UPDATER_SCRIPT"
            chmod +x "$TMP_FILE"
            exec "$SELF_UPDATER_SCRIPT"
        else
             rm -f "$TMP_FILE"
        fi
    else
        warn "Failed to check for updates (network issue?). Continuing..."
        rm -f "$TMP_FILE"
    fi
}

self_update "$@"

# --- BANNER ---
clear
echo -e "${CYAN}"
echo "  ______ _                  ______        _    ____   _____ "
echo " |  ____| |                |  ____|      | |  / __ \ / ____|"
echo " | |__  | |_   _           | |__ __ _ ___| |_| |  | | (___  "
echo " |  __| | | | | |  ______  |  __/ _\` / __| __| |  | |\___ \ "
echo " | |    | | |_| | |______| | | | (_| \__ \ |_| |__| |____) |"
echo " |_|    |_|\__, |          |_|  \__,_|___/\__|\____/|_____/ "
echo "            __/ |                                           "
echo "           |___/          DSF Update Utility v${VERSION}"
echo -e "${RESET}"
echo ""

# --- CONFIGURATION IMPORTS ---
PACKAGES_FILE="Packages"
WORK_DIR="/tmp/dsf_overwrite"

if [ "$EUID" -ne 0 ]; then error "Please run as root (sudo)."; fi

# --- USER SELECTION ---
header "Configuration"
echo -e "Select Release Channel:"
echo -e "  1) ${GREEN}Stable${RESET}   (Recommended)"
echo -e "  2) ${YELLOW}Unstable${RESET} (Bleeding Edge)"
echo ""

while true; do
    read -p "Enter choice [1-2]: " choice
    case $choice in
        1)
            CHANNEL="Stable"
            TARGET_URL="https://pkg.duet3d.com/dists/stable/armv7/binary-arm64/"
            break;;
        2)
            CHANNEL="Unstable"
            TARGET_URL="https://pkg.duet3d.com/dists/unstable/armv7/binary-arm64/"
            break;;
        *) echo -e "${RED}Invalid selection.${RESET}";;
    esac
done

info "Channel: ${BOLD}$CHANNEL${RESET}"
info "URL:     $TARGET_URL"

# --- 1. SYSTEM PREP ---
header "System Preparation"
info "Stopping services..."
systemctl stop duetcontrolserver duetwebserver duetpluginservice duetruntime 2>/dev/null

info "Reloading Daemon..."
systemctl daemon-reload

info "Remounting Filesystem as Read/Write..."
mount -o remount,rw / || error "Failed to remount / as RW. Cannot proceed."

# --- 2. FETCH PACKAGE INDEX ---
header "Fetching Packages"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" && cd "$WORK_DIR" || error "Could not create temp dir."

info "Downloading package index..."

if wget -q "${TARGET_URL}${PACKAGES_FILE}.gz" -O Packages.gz; then
    info "Downloaded Packages.gz. Decompressing..."
    gunzip Packages.gz
elif wget -q "${TARGET_URL}${PACKAGES_FILE}" -O Packages; then
    info "Downloaded plain Packages file."
else
    error "Failed to download package list. URL might be 404."
fi

if [ ! -s Packages ]; then error "The 'Packages' file is empty."; fi

# --- 3. PARSE VERSIONS ---
# Get all versions associated with duetcontrolserver
VERSIONS=($(grep -A 10 "Package: duetcontrolserver" Packages | grep "Version:" | awk '{print $2}' | sort -V -r))

if [ ${#VERSIONS[@]} -eq 0 ]; then 
    warn "Parser Warning: Could not find 'duetcontrolserver' block."
    warn "Trying to find ANY version strings..."
    VERSIONS=($(grep "Version:" Packages | awk '{print $2}' | sort -V -r | uniq))
fi

if [ ${#VERSIONS[@]} -eq 0 ]; then error "No versions found in file."; fi

header "Select Version"
i=1
for val in "${VERSIONS[@]}"; do
    echo -e "  $i) $val"
    ((i++))
done
echo ""

while true; do
    read -p "Select version to install [1-${#VERSIONS[@]}]: " v_choice
    if [[ "$v_choice" =~ ^[0-9]+$ ]] && [ "$v_choice" -ge 1 ] && [ "$v_choice" -le "${#VERSIONS[@]}" ]; then
         TARGET_VER="${VERSIONS[$((v_choice-1))]}"
         break
    else
         echo -e "${RED}Invalid selection.${RESET}"
    fi
done

info "Selected Version: ${BOLD}$TARGET_VER${RESET}"

# --- 4. IDENTIFY PACKAGES ---
declare -A INSTALL_LIST
while read -r line; do
    if [[ "$line" =~ ^Package:\ (.*) ]]; then CURRENT_PKG="${BASH_REMATCH[1]}"; fi
    if [[ "$line" =~ ^Version:\ (.*) ]]; then CURRENT_VER="${BASH_REMATCH[1]}"; fi
    if [[ "$line" =~ ^Filename:\ (.*) ]]; then CURRENT_FILE="${BASH_REMATCH[1]}"; 
        if [[ "$CURRENT_VER" == "$TARGET_VER" ]]; then
            if [[ "$CURRENT_PKG" != "reprapfirmware" && -n "$CURRENT_PKG" ]]; then
                INSTALL_LIST["$CURRENT_PKG"]="$CURRENT_FILE"
            fi
        fi
    fi
done < Packages

if [ ${#INSTALL_LIST[@]} -eq 0 ]; then error "No packages found for version $TARGET_VER"; fi

info "Found ${#INSTALL_LIST[@]} packages to overwrite."
read -p "Proceed with overwrite? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then error "Aborted."; fi

# --- 5. EXECUTION ---
header "Installing Updates"

for pkg in "${!INSTALL_LIST[@]}"; do
    FILE_PATH="${INSTALL_LIST[$pkg]}"
    if [[ "$FILE_PATH" == pool/* ]] || [[ "$FILE_PATH" == dists/* ]]; then
        FULL_URL="https://pkg.duet3d.com/${FILE_PATH}"
    else
        CLEAN_PATH="${FILE_PATH#./}"
        FULL_URL="${TARGET_URL}${CLEAN_PATH}"
    fi

    DEB_NAME="$(basename "$FILE_PATH")"
    info "Downloading $pkg..."
    wget -q --show-progress "$FULL_URL" -O "$DEB_NAME" || error "Failed download."

    info "Extracting & Overwriting..."
    if command -v ar &> /dev/null; then 
        ar x "$DEB_NAME" data.tar.xz 2>/dev/null || ar x "$DEB_NAME" data.tar.gz 2>/dev/null
    else 
        busybox ar x "$DEB_NAME" data.tar.xz 2>/dev/null || busybox ar x "$DEB_NAME" data.tar.gz 2>/dev/null
    fi
    
    if [ -f "data.tar.xz" ]; then ARCHIVE="data.tar.xz"; 
    elif [ -f "data.tar.gz" ]; then ARCHIVE="data.tar.gz"; 
    else error "Bad .deb format (no data.tar)"; fi

    # OVERWRITE DIRECTLY TO /
    # Suppress permission/ownership errors as requested
    tar -xf "$ARCHIVE" -C / --no-same-owner -m 2>/dev/null
    
    rm -f "$DEB_NAME" "$ARCHIVE" control.tar.* debian-binary
    success "Installed $pkg"
done

# --- 6. FINISH ---
header "Finalizing"
info "Fixing Permissions..."
if id "dsf" &>/dev/null; then chown -R dsf:dsf /opt/dsf; fi
chmod +x /opt/dsf/bin/* 2>/dev/null

info "Syncing filesystem..."
sync

info "Restarting Services..."
systemctl start duetcontrolserver duetwebserver duetpluginservice

header "Complete"
success "Fly-FastOS DSF Update Finished Successfully!"