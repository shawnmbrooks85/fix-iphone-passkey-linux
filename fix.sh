#!/bin/bash
# =============================================================================
# Fix iPhone Passkey (caBLE) on Ubuntu 24.04 / Linux
# Upgrades BlueZ 5.72 → 5.77, applies discovery filter patch, and configures
# all required services for reliable iPhone passkey connections.
#
# Usage: sudo ./fix.sh
# Rollback: sudo ./rollback.sh
# =============================================================================
set -e

BLUEZ_VERSION="5.77"
BLUEZ_URL="https://www.kernel.org/pub/linux/bluetooth/bluez-${BLUEZ_VERSION}.tar.xz"
MAIN_CONF="/etc/bluetooth/main.conf"
BACKUP_SUFFIX=".bak.pre-passkey-fix"
BUILD_DIR="/tmp/bluez-${BLUEZ_VERSION}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_DIR=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# --- Pre-flight checks -------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    fail "Please run as root: sudo ./fix.sh"
fi

echo "============================================="
echo " iPhone Passkey (caBLE) Fix for Linux"
echo " BlueZ 5.72 → ${BLUEZ_VERSION} + Runtime Services"
echo "============================================="
echo ""

CURRENT_VERSION=$(bluetoothd --version 2>/dev/null || echo "unknown")
echo "Current BlueZ version: ${CURRENT_VERSION}"
echo "Target BlueZ version:  ${BLUEZ_VERSION}"
echo ""

# Detect adapter
ADAPTER_MAC=$(hciconfig hci0 2>/dev/null | grep -oP 'BD Address: \K[A-F0-9:]+' || true)
if [ -n "$ADAPTER_MAC" ]; then
    ADAPTER_DIR="/var/lib/bluetooth/${ADAPTER_MAC}"
    log "Detected adapter: ${ADAPTER_MAC}"
else
    warn "Could not detect adapter MAC — skipping cache purge"
fi

# --- Step 1: Backup ----------------------------------------------------------

echo ""
echo "--- Step 1: Backup current configuration ---"

if [ -f "${MAIN_CONF}" ] && [ ! -f "${MAIN_CONF}${BACKUP_SUFFIX}" ]; then
    cp "${MAIN_CONF}" "${MAIN_CONF}${BACKUP_SUFFIX}"
    log "Backed up ${MAIN_CONF}"
else
    warn "Backup already exists or config not found"
fi

# --- Step 2: Install build dependencies --------------------------------------

echo ""
echo "--- Step 2: Install build dependencies ---"

apt-get update -qq
apt-get install -y -qq \
    build-essential \
    libreadline-dev \
    libical-dev \
    libdbus-1-dev \
    libudev-dev \
    libglib2.0-dev \
    python3-docutils \
    flex bison \
    libdw-dev \
    libell-dev \
    libjson-c-dev \
    wget \
    > /dev/null 2>&1
log "Build dependencies installed"

# --- Step 3: Download, patch, and build BlueZ --------------------------------

echo ""
echo "--- Step 3: Build BlueZ ${BLUEZ_VERSION} with discovery filter patch ---"

cd /tmp

if [ ! -f "bluez-${BLUEZ_VERSION}.tar.xz" ]; then
    echo "Downloading BlueZ ${BLUEZ_VERSION}..."
    wget -q "${BLUEZ_URL}"
    log "Downloaded"
fi

if [ -d "${BUILD_DIR}" ]; then
    rm -rf "${BUILD_DIR}"
fi
tar -xf "bluez-${BLUEZ_VERSION}.tar.xz"
log "Extracted"

# Apply discovery filter patch
cd "${BUILD_DIR}"
if [ -f "${SCRIPT_DIR}/patches/bluez-5.77-discovery-filter.patch" ]; then
    echo "Applying discovery filter patch..."
    patch -p1 < "${SCRIPT_DIR}/patches/bluez-5.77-discovery-filter.patch"
    log "Patch applied"
else
    warn "Patch file not found — applying inline patch"
    # Inline patch: clear current_discovery_filter in stop_discovery_complete
    sed -i '/adapter->discovering = false;/a\\tg_free(adapter->current_discovery_filter);\n\tadapter->current_discovery_filter = NULL;' src/adapter.c
    log "Inline patch applied"
fi

echo "Configuring (this takes a moment)..."
./configure \
    --prefix=/usr \
    --mandir=/usr/share/man \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --enable-experimental \
    --enable-testing \
    > /tmp/bluez-configure.log 2>&1
log "Configured"

echo "Compiling (this takes 2-3 minutes)..."
make -j$(nproc) > /tmp/bluez-make.log 2>&1
log "Compiled"

echo "Installing..."
systemctl stop bluetooth 2>/dev/null || true
sleep 1
make install > /tmp/bluez-install.log 2>&1
log "Installed BlueZ ${BLUEZ_VERSION}"

# --- Step 4: Configure BlueZ -------------------------------------------------

echo ""
echo "--- Step 4: Configure BlueZ ---"

# Write a clean, complete config (make install may have overwritten it)
cat > "${MAIN_CONF}" << 'CONF'
[General]
Experimental = true
KernelExperimental = 15c0a148-c273-11ea-b3de-0242ac130004
FastConnectable = true
TemporaryTimeout = 1
JustWorksRepairing = always

[BR]

[LE]

[GATT]
Cache = no

[CSIS]

[AVDTP]

[Policy]

[AdvMon]
CONF

log "BlueZ config written (Experimental, FastConnectable, GATT cache off)"

# --- Step 5: Systemd override ------------------------------------------------

echo ""
echo "--- Step 5: Create systemd override ---"

mkdir -p /etc/systemd/system/bluetooth.service.d
cat > /etc/systemd/system/bluetooth.service.d/passkey-fix.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/libexec/bluetooth/bluetoothd --experimental -P battery
EOF
log "Systemd override created (--experimental -P battery)"

# --- Step 6: Privacy startup service -----------------------------------------

echo ""
echo "--- Step 6: Create BLE privacy startup service ---"

cat > /etc/systemd/system/bluetooth-privacy.service << 'EOF'
[Unit]
Description=Enable BLE Privacy (RPA) for passkey support
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 2
ExecStart=/bin/bash -lc '\
    timeout 5 btmgmt power off 2>/dev/null || true; \
    sleep 1; \
    timeout 5 btmgmt bondable on 2>/dev/null || true; \
    timeout 5 btmgmt privacy on 2>/dev/null || true; \
    sleep 1; \
    timeout 5 btmgmt power on 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

log "BLE privacy service created"

# --- Step 7: BLE device cleaner service --------------------------------------

echo ""
echo "--- Step 7: Create BLE device cleaner service ---"

# Copy cleaner script to system location
cp "${SCRIPT_DIR}/fast-cleaner.sh" /usr/local/bin/ble-device-cleaner.sh
chmod +x /usr/local/bin/ble-device-cleaner.sh

cat > /etc/systemd/system/ble-device-cleaner.service << 'EOF'
[Unit]
Description=BLE Device Cleaner — prevents D-Bus slot exhaustion
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=simple
ExecStart=/usr/local/bin/ble-device-cleaner.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

log "BLE device cleaner service created"

# --- Step 8: Passkey-ready service -------------------------------------------

echo ""
echo "--- Step 8: Create passkey-ready service ---"

cat > /etc/systemd/system/passkey-ready.service << 'EOF'
[Unit]
Description=Set adapter discoverable and pairable for passkey support
After=bluetooth-privacy.service
Requires=bluetooth.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 1
ExecStart=/bin/bash -c 'bluetoothctl discoverable on && bluetoothctl pairable on && bluetoothctl discoverable-timeout 0'
ExecStartPost=/bin/bash -lc "pkill -f 'dbus-monitor.*org.bluez' 2>/dev/null || true; dbus-monitor --system \"sender='org.bluez'\" > /dev/null 2>&1 &"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

log "Passkey-ready service created"

# --- Step 9: Enable and reload -----------------------------------------------

echo ""
echo "--- Step 9: Enable services ---"

systemctl daemon-reload
systemctl enable --now bluetooth-privacy.service 2>/dev/null
systemctl enable --now ble-device-cleaner.service 2>/dev/null
systemctl enable --now passkey-ready.service 2>/dev/null
log "Services enabled"

# --- Step 10: Clear device cache ---------------------------------------------

echo ""
echo "--- Step 10: Clear stale device cache ---"

if [ -n "$ADAPTER_DIR" ] && [ -d "$ADAPTER_DIR" ]; then
    rm -rf "${ADAPTER_DIR}/cache"/* 2>/dev/null
    log "Device cache cleared"
else
    warn "Skipped cache clear (adapter dir not found)"
fi

# --- Step 11: Restart and verify ---------------------------------------------

echo ""
echo "--- Step 11: Restart and verify ---"

systemctl start bluetooth
sleep 3

# Enable privacy
systemctl start bluetooth-privacy.service 2>/dev/null
sleep 3

# Start cleaner
systemctl start ble-device-cleaner.service 2>/dev/null

# Make discoverable
REAL_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-$(whoami)}")
su - "$REAL_USER" -c 'bluetoothctl discoverable on >/dev/null 2>&1; bluetoothctl pairable on >/dev/null 2>&1; bluetoothctl discoverable-timeout 0 >/dev/null 2>&1' 2>/dev/null

NEW_VERSION=$(bluetoothd --version 2>/dev/null || echo "unknown")
SETTINGS=$(timeout 5 btmgmt info 2>/dev/null | grep "current settings" | head -1 || echo "unknown")

echo ""
echo "============================================="
echo " Verification"
echo "============================================="
echo ""
echo "BlueZ version: ${NEW_VERSION}"
echo "Settings: ${SETTINGS}"
echo ""

# Check key requirements
PASS=true

if [ "$NEW_VERSION" != "$BLUEZ_VERSION" ]; then
    warn "BlueZ version mismatch: expected ${BLUEZ_VERSION}, got ${NEW_VERSION}"
    PASS=false
else
    log "BlueZ ${BLUEZ_VERSION}: OK"
fi

if echo "$SETTINGS" | grep -q "privacy"; then
    log "BLE Privacy: ON"
else
    warn "BLE Privacy: OFF (will apply on next reboot)"
    PASS=false
fi

if echo "$SETTINGS" | grep -q "le"; then
    log "BLE (LE): ON"
else
    warn "BLE (LE): OFF"
    PASS=false
fi

if echo "$SETTINGS" | grep -q "discoverable"; then
    log "Discoverable: ON"
else
    warn "Discoverable: OFF"
fi

PROC=$(ps aux | grep bluetoothd | grep -v grep | head -1)
if echo "$PROC" | grep -q "\-\-experimental"; then
    log "Experimental mode: ON"
else
    warn "Experimental mode: OFF"
    PASS=false
fi

if systemctl is-active ble-device-cleaner.service >/dev/null 2>&1; then
    log "Device cleaner: RUNNING"
else
    warn "Device cleaner: NOT RUNNING"
fi

echo ""
if [ "$PASS" = true ]; then
    echo -e "${GREEN}============================================="
    echo " ✅ ALL CHECKS PASSED"
    echo ""
    echo " Next steps:"
    echo "   1. Open your Chromium-based browser (Chrome, Brave, Edge, etc.)"
    echo "   2. Visit chrome://bluetooth-internals (then close it)"
    echo "   3. Try the passkey QR flow!"
    echo -e "=============================================${NC}"
else
    echo -e "${YELLOW}============================================="
    echo " ⚠️  SOME CHECKS NEED ATTENTION"
    echo " Review the warnings above"
    echo " Try rebooting — privacy service will auto-apply"
    echo -e "=============================================${NC}"
fi
echo ""
