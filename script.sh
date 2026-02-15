#!/bin/bash
VERSION="0.2.2"

# Self-update configuration
SCRIPT_URL="https://raw.githubusercontent.com/TeamGloomy/Fly-FastOS-DSF-Update/main/script.sh"
SCRIPT_LOCATION="${BASH_SOURCE[@]}"
SELF_UPDATER_SCRIPT="/tmp/fly_fastos_selfupdater.sh"

self_update() {
    # Delete previous self-updater script if any
    rm -f "$SELF_UPDATER_SCRIPT"

    TMP_FILE=$(mktemp -p "" "XXXXX.sh")
    
    # Download new script
    if wget -q "$SCRIPT_URL" -O "$TMP_FILE"; then
        # VALIDATION: Check if it's a valid bash script
        if ! head -n 1 "$TMP_FILE" | grep -q "^#!/bin/bash"; then
             echo "⚠️  Downloaded update is not a valid script (likely HTML or network error). Skipping update."
             rm -f "$TMP_FILE"
             return
        fi

        # Extract new version
        # Use tr -d '\r' to remove carriage returns and trim whitespace
        # grep "^VERSION=" to avoid matching VERSIONS array later in the script
        # cut -d'"' -f2 extracts the value inside quotes
        NEW_VER=$(grep "^VERSION=" "$TMP_FILE" | head -n 1 | cut -d'"' -f2 | tr -d '\r')
        
        # Check if version was found
        if [ -z "$NEW_VER" ]; then
            echo "⚠️  Could not detect version in remote script. Skipping update."
            rm -f "$TMP_FILE"
            return
        fi

        ABS_SCRIPT_PATH=$(readlink -f "$SCRIPT_LOCATION")
        
        # STRICT CHECK using string equality first
        if [ "$VERSION" == "$NEW_VER" ]; then
             echo "Script is up-to-date ($VERSION). Continuing..."
             rm -f "$TMP_FILE"
             return
        fi

        # Compare versions (Remote > Local)
        if [[ "$VERSION" < "$NEW_VER" ]]; then
            printf "Updating script \e[31;1m%s\e[0m -> \e[32;1m%s\e[0m\n" "$VERSION" "$NEW_VER"

            # Create transient updater script
            echo "#!/bin/bash" > "$SELF_UPDATER_SCRIPT"
            echo "cp \"$TMP_FILE\" \"$ABS_SCRIPT_PATH\"" >> "$SELF_UPDATER_SCRIPT"
            echo "rm -f \"$TMP_FILE\"" >> "$SELF_UPDATER_SCRIPT"
            echo "echo 'Running updated script...'" >> "$SELF_UPDATER_SCRIPT"
            echo "exec \"$ABS_SCRIPT_PATH\" \"\$@\"" >> "$SELF_UPDATER_SCRIPT"

            chmod +x "$SELF_UPDATER_SCRIPT"
            chmod +x "$TMP_FILE"
            
            # Execute updater and exit current process
            exec "$SELF_UPDATER_SCRIPT"
        else
             echo "Remote version ($NEW_VER) is not newer than current ($VERSION). Skipping."
             rm -f "$TMP_FILE"
        fi
    else
        echo "⚠️  Failed to check for updates (network issue?). Continuing..."
        rm -f "$TMP_FILE"
    fi
}

self_update "$@"


# ==============================================================================
# FORCE OVERWRITE: CUSTOM URL
# ==============================================================================
# 1. Stops Services & Reloads Daemon.
# 2. Remounts Filesystem RW.
# 3. Downloads Package List from YOUR URL.
# 4. Downloads & Overwrites files.
# ==============================================================================

echo ""
echo "=============================================================================="
echo "   Fly-FastOS DSF Update Script v$VERSION"
echo "=============================================================================="
echo ""

# --- CONFIGURATION ---
PS3="Select Release Channel (Enter number): "
select CHANNEL in "Stable" "Unstable"; do
    case $CHANNEL in
        "Stable")
            TARGET_URL="https://pkg.duet3d.com/dists/stable/armv7/binary-arm64/"
            break
            ;;
        "Unstable")
            TARGET_URL="https://pkg.duet3d.com/dists/unstable/armv7/binary-arm64/"
            break
            ;;
        *) echo "Invalid selection. Please try again.";;
    esac
done

echo "Selected Channel: $CHANNEL"
echo "Target URL: $TARGET_URL"

PACKAGES_FILE="Packages"
WORK_DIR="/tmp/dsf_overwrite"

# --- UTILS ---
die() { echo -e "❌ \033[1;31m$1\033[0m"; exit 1; }
status() { echo -e "🔹 \033[1;34m$1\033[0m"; }

if [ "$EUID" -ne 0 ]; then die "Please run as root (sudo)."; fi

# --- 1. SYSTEM PREP ---
status "Stopping services..."
systemctl stop duetcontrolserver duetwebserver duetpluginservice duetruntime 2>/dev/null

status "Reloading Daemon..."
systemctl daemon-reload

status "Remounting Filesystem as Read/Write..."
mount -o remount,rw / || die "Failed to remount / as RW. Cannot proceed."

# --- 2. FETCH PACKAGE INDEX ---
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" && cd "$WORK_DIR" || die "Could not create temp dir."

status "Fetching package index from: $TARGET_URL"

# Try downloading Packages.gz first (standard), then plain Packages
if wget -q "${TARGET_URL}${PACKAGES_FILE}.gz" -O Packages.gz; then
    status "Downloaded Packages.gz. Decompressing..."
    gunzip Packages.gz
elif wget -q "${TARGET_URL}${PACKAGES_FILE}" -O Packages; then
    status "Downloaded plain Packages file."
else
    die "Failed to download package list. URL might be 404."
fi

if [ ! -s Packages ]; then die "The 'Packages' file is empty."; fi

# DEBUG: Print the first 5 lines so you can see if we got the right file
echo "------------------------------------------------"
echo "DEBUG: First 5 lines of Packages file:"
head -n 5 Packages
echo "------------------------------------------------"

# --- 3. PARSE VERSIONS ---
# Get all versions associated with duetcontrolserver
VERSIONS=($(grep -A 10 "Package: duetcontrolserver" Packages | grep "Version:" | awk '{print $2}' | sort -V -r))

if [ ${#VERSIONS[@]} -eq 0 ]; then 
    echo "⚠️  Parser Warning: Could not find 'duetcontrolserver' block."
    echo "   Trying to find ANY version strings..."
    VERSIONS=($(grep "Version:" Packages | awk '{print $2}' | sort -V -r | uniq))
fi

if [ ${#VERSIONS[@]} -eq 0 ]; then die "No versions found in file."; fi

PS3="Select version to install (Enter number): "
select VER in "${VERSIONS[@]}"; do
    if [[ -n "$VER" ]]; then TARGET_VER="$VER"; break; fi
    echo "Invalid selection."
done
status "Selected Version: $TARGET_VER"

# --- 4. IDENTIFY PACKAGES ---
declare -A INSTALL_LIST

# Simple Block Parser
# Reads the file line by line. When it finds a matching version block, saves the file.
while read -r line; do
    if [[ "$line" =~ ^Package:\ (.*) ]]; then CURRENT_PKG="${BASH_REMATCH[1]}"; fi
    if [[ "$line" =~ ^Version:\ (.*) ]]; then CURRENT_VER="${BASH_REMATCH[1]}"; fi
    if [[ "$line" =~ ^Filename:\ (.*) ]]; then CURRENT_FILE="${BASH_REMATCH[1]}"; 
        # Check if this block matches our selected version
        if [[ "$CURRENT_VER" == "$TARGET_VER" ]]; then
            # Exclude firmware
            if [[ "$CURRENT_PKG" != "reprapfirmware" && -n "$CURRENT_PKG" ]]; then
                INSTALL_LIST["$CURRENT_PKG"]="$CURRENT_FILE"
            fi
        fi
    fi
done < Packages

if [ ${#INSTALL_LIST[@]} -eq 0 ]; then die "No packages found for version $TARGET_VER"; fi

echo "------------------------------------------------"
echo "Found ${#INSTALL_LIST[@]} packages to overwrite."
read -p "Proceed with overwrite? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then die "Aborted."; fi

# --- 5. EXECUTION (OVERWRITE) ---

for pkg in "${!INSTALL_LIST[@]}"; do
    FILE_PATH="${INSTALL_LIST[$pkg]}"
    
    # URL CONSTRUCTION LOGIC
    # If the filename in the file is just "duetcontrolserver.deb", append to TARGET_URL
    # If it is "pool/main/...", prepend https://pkg.duet3d.com
    if [[ "$FILE_PATH" == pool/* ]] || [[ "$FILE_PATH" == dists/* ]]; then
        FULL_URL="https://pkg.duet3d.com/${FILE_PATH}"
    else
        # Remove any leading ./
        CLEAN_PATH="${FILE_PATH#./}"
        FULL_URL="${TARGET_URL}${CLEAN_PATH}"
    fi

    DEB_NAME="$(basename "$FILE_PATH")"
    status "Downloading $pkg..."
    # echo "DEBUG URL: $FULL_URL"
    wget -q --show-progress "$FULL_URL" -O "$DEB_NAME" || die "Failed download."

    status "Extracting & Overwriting..."
    
    # Extract
    if command -v ar &> /dev/null; then 
        ar x "$DEB_NAME" data.tar.xz 2>/dev/null || ar x "$DEB_NAME" data.tar.gz 2>/dev/null
    else 
        busybox ar x "$DEB_NAME" data.tar.xz 2>/dev/null || busybox ar x "$DEB_NAME" data.tar.gz 2>/dev/null
    fi
    
    if [ -f "data.tar.xz" ]; then ARCHIVE="data.tar.xz"; 
    elif [ -f "data.tar.gz" ]; then ARCHIVE="data.tar.gz"; 
    else die "Bad .deb format (no data.tar)"; fi

    # OVERWRITE DIRECTLY TO /
    tar -xf "$ARCHIVE" -C /
    
    rm -f "$DEB_NAME" "$ARCHIVE" control.tar.* debian-binary
done

# --- 6. FINISH ---
status "Fixing Permissions..."
if id "dsf" &>/dev/null; then chown -R dsf:dsf /opt/dsf; fi
chmod +x /opt/dsf/bin/* 2>/dev/null

status "Syncing..."
sync

status "Restarting Services..."
systemctl start duetcontrolserver duetwebserver duetpluginservice

status "Update Complete."