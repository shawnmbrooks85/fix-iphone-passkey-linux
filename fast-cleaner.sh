#!/bin/bash
# =============================================================================
# Fast BLE Device Cleaner
# Runs every 2 seconds and removes ALL non-paired devices via D-Bus.
#
# WHY: Intel AX211's MSFT HCI extensions cause continuous firmware-level
# BLE scanning, discovering 100-150+ devices. Each is registered as a D-Bus
# object. BlueZ's TemporaryTimeout can't evict them because the continuous
# scanning keeps refreshing each device's timer. Without this cleaner,
# D-Bus slots exhaust and Chrome can't register the iPhone's caBLE device.
#
# This is a systemd service — see ble-device-cleaner.service
# =============================================================================

echo "[BLE Cleaner] Starting — clearing non-paired devices every 2s"

while true; do
    # Get all device paths from BlueZ D-Bus tree
    DEVICES=$(busctl tree org.bluez 2>/dev/null | grep "/org/bluez/hci0/dev_" | tr -d '[:space:]│├└─')

    for DEV_PATH in $DEVICES; do
        [ -z "$DEV_PATH" ] && continue

        # Check if paired
        PAIRED=$(dbus-send --system --print-reply --dest=org.bluez "$DEV_PATH" \
            org.freedesktop.DBus.Properties.Get \
            string:"org.bluez.Device1" string:"Paired" 2>/dev/null \
            | grep -o "true")

        # Remove if not paired
        if [ -z "$PAIRED" ]; then
            dbus-send --system --print-reply --dest=org.bluez /org/bluez/hci0 \
                org.bluez.Adapter1.RemoveDevice \
                objpath:"$DEV_PATH" >/dev/null 2>&1
        fi
    done

    sleep 2
done
