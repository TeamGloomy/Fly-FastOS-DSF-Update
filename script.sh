#!/bin/bash

# ==============================================================================
# FORCE OVERWRITE DSF UPDATE
# ==============================================================================
# 1. Stops services.
# 2. Reloads daemon (as requested).
# 3. Remounts root filesystem as Read/Write.
# 4. Downloads .deb packages.
# 5. Extracts data.tar directly to root /, overwriting existing files.
# ==============================================================================

# --- CONFIGURATION ---
TARGET_URL="https://pkg.duet3d.com/dists/unstable/armv7/binary-arm64/"
SITE_ROOT="https://pkg.duet3d.com"
PACKAGES_FILE="Packages"
WORK_DIR="/tmp/dsf_overwrite"

# --- UTILS ---
die() { echo -e "❌ \033[1;31m$1\033[0m"; exit 1; }
status() { echo -e "🔹 \033[1;34m$1\033[0m"; }

if [ "$EUID" -ne 0 ]; then die "Please run as root (sudo)."; fi

# --- 1. STOP SERVICES & PREPARE ---
status "Stopping services..."
systemctl stop duetcontrolserver duetwebserver duetpluginservice duetruntime 2>/dev/null

status "Reloading Daemon (as requested)..."
systemctl daemon-reload

status "Remounting Filesystem as Read/Write..."
mount -o remount,rw / || die "Failed to remount filesystem as RW. Update cannot proceed."

# --- 2. FETCH PACKAGE INDEX ---
mkdir -p "$WORK_DIR" && cd "$WORK_DIR" || die "Could not create temp dir."

status "Fetching package index..."
if ! wget -q "${TARGET_URL}${PACKAGES_FILE}" -O Packages; then
    wget -q "${TARGET_URL}${PACKAGES_FILE}.gz" -O Packages.gz && gzip -d Packages.gz
fi
if [ ! -f Packages ]; then die "Could not download package list."; fi

# --- 3. SELECT VERSION ---
VERSIONS=($(awk '/^Package: duetcontrolserver$/ {flag=1; next} /^Package:/ {flag=0} flag && /^Version:/ {print $2}' Packages | sort -V -r))
if [ ${#VERSIONS[@]} -eq 0 ]; then die "No versions found."; fi

PS3="Select version to install (Enter number): "
select VER in "${VERSIONS[@]}"; do
    if [[ -n "$VER" ]]; then TARGET_VER="$VER"; break; fi
done
status "Selected Version: $TARGET_VER"

# --- 4. IDENTIFY PACKAGES ---
declare -A INSTALL_LIST
while read -r pkg_name file_path; do
    if [[ "$pkg_name" != "reprapfirmware" && -n "$pkg_name" ]]; then
        INSTALL_LIST["$pkg_name"]="$file_path"
    fi
done < <(awk -v v="$TARGET_VER" '/^Package:/ {p=$2} /^Version:/ {ver=$2} /^Filename:/ {f=$2} /^$/ {if(ver==v && p!="") print p,f; p="";v="";f=""}' Packages)

if [ ${#INSTALL_LIST[@]} -eq 0 ]; then die "No packages found for version $TARGET_VER"; fi

echo "------------------------------------------------"
echo "Packages to be overwritten: ${!INSTALL_LIST[@]}"
read -p "Proceed with overwrite? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then die "Aborted."; fi

# --- 5. EXECUTION (OVERWRITE) ---

for pkg in "${!INSTALL_LIST[@]}"; do
    FILE_PATH="${INSTALL_LIST[$pkg]}"
    
    # Resolve URL
    if [[ "$FILE_PATH" == pool/* ]] || [[ "$FILE_PATH" == dists/* ]]; then
        FULL_URL="${SITE_ROOT}/${FILE_PATH}"
    else
        FULL_URL="${TARGET_URL}${FILE_PATH#./}"
    fi

    DEB_NAME="$(basename "$FILE_PATH")"
    status "Downloading $pkg..."
    wget -q --show-progress "$FULL_URL" -O "$DEB_NAME" || die "Failed download."

    status "Extracting & Overwriting..."
    
    # Extract
    if command -v ar &> /dev/null; then ar x "$DEB_NAME" data.tar.xz 2>/dev/null || ar x "$DEB_NAME" data.tar.gz; 
    else busybox ar x "$DEB_NAME" data.tar.xz 2>/dev/null || busybox ar x "$DEB_NAME" data.tar.gz; fi
    
    if [ -f "data.tar.xz" ]; then ARCHIVE="data.tar.xz"; else ARCHIVE="data.tar.gz"; fi

    # INSTALL TO ROOT /
    # This unpacks ./opt/dsf/... directly into /opt/dsf/..., overwriting files.
    tar -xf "$ARCHIVE" -C /
    
    # Cleanup
    rm -f "$DEB_NAME" "$ARCHIVE" control.tar.* debian-binary
done

# --- 6. FINISH ---
status "Fixing Permissions..."
if id "dsf" &>/dev/null; then chown -R dsf:dsf /opt/dsf; fi
chmod +x /opt/dsf/bin/* 2>/dev/null

status "Syncing Filesystem..."
sync

status "Restarting Services..."
systemctl start duetcontrolserver duetwebserver duetpluginservice

status "Update Complete."