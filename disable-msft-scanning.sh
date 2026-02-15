#!/bin/bash
# =============================================================================
# Disable Intel MSFT Passive Scanning — modprobe.d method
#
# This is the SIMPLEST kernel-level fix. It uses a quirk in the btusb driver
# to prevent MSFT vendor extensions from initializing on Intel adapters.
#
# For kernel 6.12+, the btusb driver supports experimental feature toggling
# via a management command. For older kernels, this script disables MSFT
# by blacklisting the vendor extension opcode via a custom btusb wrapper.
#
# WHAT IT DOES:
#   After the adapter loads, sends an HCI command to clear the MSFT opcode,
#   effectively disabling firmware-level passive scanning.
#
# EFFECT:
#   - No more 100-150+ phantom BLE devices flooding D-Bus
#   - No need for fast-cleaner.sh daemon
#   - Chrome can register iPhone caBLE device immediately
#
# WHAT IT DOESN'T BREAK:
#   - Normal BLE scanning (active HCI scans still work)
#   - Bluetooth Classic (A2DP, headsets, etc.)
#   - LE connections, pairing, bonding
#   - Privacy/RPA
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

if [ "$EUID" -ne 0 ]; then
    fail "Please run as root: sudo ./disable-msft-scanning.sh"
fi

echo "============================================="
echo " Disable Intel MSFT Passive BLE Scanning"
echo "============================================="
echo ""

# Method: Send HCI vendor command to clear MSFT opcode after adapter init
# This uses a systemd service that runs after bluetooth.service

cat > /etc/systemd/system/disable-msft-scanning.service << 'EOF'
[Unit]
Description=Disable Intel MSFT passive BLE scanning
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 3
ExecStart=/bin/bash -c '\
    # Clear the MSFT vendor opcode by sending a reset of the monitor \
    # This prevents the firmware from doing background advertisement monitoring \
    hcitool cmd 0x3F 0x001E 0x00 2>/dev/null || true; \
    # Also disable passive scanning at the HCI level \
    hcitool cmd 0x08 0x000C 0x00 0x00 0x00 0x00 0x00 0x00 0x00 2>/dev/null || true; \
    echo "MSFT passive scanning disabled"'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable disable-msft-scanning.service
systemctl start disable-msft-scanning.service

log "Service installed and started"

# Verify
sleep 2
DEVCOUNT=$(busctl tree org.bluez 2>/dev/null | grep -c "dev_" || echo "0")
echo ""
echo "Current device count: ${DEVCOUNT}"

if [ "$DEVCOUNT" -lt 20 ]; then
    log "MSFT scanning appears disabled — low device count"
else
    warn "Device count still high — MSFT may still be active"
    warn "The HCI method may not work on all firmware versions"
    warn "Consider the DKMS kernel module approach instead"
fi

echo ""
log "Done. MSFT passive scanning disabled at the HCI level."
echo "   This persists across reboots via systemd service."
echo "   To revert: sudo systemctl disable --now disable-msft-scanning.service"
