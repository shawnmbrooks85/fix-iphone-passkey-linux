#!/bin/bash
# =============================================================================
# Passkey Reset — Quick adapter reset for when passkeys stop working
# Usage: sudo ./passkey-reset.sh
#
# Run this after sleep/resume, or whenever "Connecting..." stalls.
# =============================================================================
echo "Resetting Bluetooth for passkeys..."

# 1. Full service restart
systemctl restart bluetooth
sleep 3

# 2. Configure adapter (ORDER MATTERS: power off → settings → power on)
# NOTE: btmgmt can hang indefinitely (especially power off after boot).
# Wrap all calls with timeout to prevent blocking the auto-reset daemon.
timeout 5 btmgmt power off 2>/dev/null || echo "⚠ btmgmt power off timed out (continuing)"
sleep 1
timeout 5 btmgmt bondable on 2>/dev/null
timeout 5 btmgmt privacy on 2>/dev/null
sleep 1
timeout 5 btmgmt power on 2>/dev/null || echo "⚠ btmgmt power on timed out"
sleep 2

# 3. Enable discoverable + pairable
REAL_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-$(whoami)}")
su - "$REAL_USER" -c '
    bluetoothctl discoverable on >/dev/null 2>&1
    bluetoothctl pairable on >/dev/null 2>&1
    bluetoothctl discoverable-timeout 0 >/dev/null 2>&1
' 2>/dev/null

# 4. Ensure runtime services are active
systemctl start ble-device-cleaner.service 2>/dev/null || true

# 5. Start dbus-monitor in background (keeps D-Bus event loop responsive)
pkill -f "dbus-monitor.*org.bluez" 2>/dev/null
dbus-monitor --system "sender='org.bluez'" > /dev/null 2>&1 &

# 6. Verify
sleep 1
SETTINGS=$(
    timeout 5 btmgmt info 2>/dev/null | grep "current settings" | head -1 || true
)
echo ""
echo "✅ Ready — $SETTINGS"
echo ""

# If btmgmt hangs, we don't want to block the whole reset script.
if [ -z "$SETTINGS" ]; then
    echo "⚠ btmgmt info timed out or returned no settings (continuing)"
    echo ""
fi

# Check key flags
if echo "$SETTINGS" | grep -q "privacy"; then
    echo "   Privacy: ON ✓"
else
    echo "   Privacy: MISSING ✗ (try rebooting)"
fi

if echo "$SETTINGS" | grep -q "bondable"; then
    echo "   Bondable: ON ✓"
else
    echo "   Bondable: MISSING ✗"
fi

if echo "$SETTINGS" | grep -q "discoverable"; then
    echo "   Discoverable: ON ✓"
else
    echo "   Discoverable: MISSING ✗"
fi

CLEANER=$(systemctl is-active ble-device-cleaner.service 2>/dev/null)
if [ "$CLEANER" = "active" ]; then
    echo "   Device Cleaner: RUNNING ✓"
else
    echo "   Device Cleaner: NOT RUNNING ✗ (starting...)"
    bash "$(dirname "$0")/fast-cleaner.sh" &
fi

echo ""
echo "Next: open chrome://bluetooth-internals in your browser (Chrome, Brave, Edge), close it, then try passkey"
