#!/bin/bash
# =============================================================================
# Rollback: Restore stock BlueZ and revert all passkey fix changes
# Usage: sudo ./rollback.sh
# =============================================================================
set -e

MAIN_CONF="/etc/bluetooth/main.conf"
BACKUP_SUFFIX=".bak.pre-passkey-fix"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

if [ "$EUID" -ne 0 ]; then
    fail "Please run as root: sudo ./rollback.sh"
fi

echo "============================================="
echo " Rollback Passkey Fix"
echo "============================================="
echo ""

# Stop all services
systemctl stop bluetooth 2>/dev/null || true
systemctl stop ble-device-cleaner.service 2>/dev/null || true
systemctl stop bluetooth-privacy.service 2>/dev/null || true

# Kill background processes
pkill -f "dbus-monitor.*org.bluez" 2>/dev/null || true
pkill -f fast-cleaner 2>/dev/null || true
pkill -f ble-scan-keepalive 2>/dev/null || true

# Restore stock BlueZ
echo "Reinstalling stock BlueZ..."
apt-get install --reinstall -y bluez > /dev/null 2>&1
log "Stock BlueZ restored"

# Restore original config
if [ -f "${MAIN_CONF}${BACKUP_SUFFIX}" ]; then
    cp "${MAIN_CONF}${BACKUP_SUFFIX}" "${MAIN_CONF}"
    log "Original main.conf restored"
else
    echo "No backup found — config left as-is"
fi

# Remove systemd overrides
rm -f /etc/systemd/system/bluetooth.service.d/passkey-fix.conf
rm -f /etc/systemd/system/bluetooth.service.d/experimental.conf
rmdir /etc/systemd/system/bluetooth.service.d 2>/dev/null || true

# Remove services
systemctl disable bluetooth-privacy.service 2>/dev/null || true
systemctl disable ble-device-cleaner.service 2>/dev/null || true
rm -f /etc/systemd/system/bluetooth-privacy.service
rm -f /etc/systemd/system/ble-device-cleaner.service
rm -f /usr/local/bin/ble-device-cleaner.sh

# Reload and restart
systemctl daemon-reload
systemctl start bluetooth
sleep 2

# Disable privacy
btmgmt privacy off 2>/dev/null || true

NEW_VERSION=$(bluetoothd --version 2>/dev/null || echo "unknown")
echo ""
echo "BlueZ version: ${NEW_VERSION}"
log "Rollback complete — all passkey fix changes reverted"
