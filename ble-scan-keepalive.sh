#!/bin/bash
# =============================================================================
# BLE Scan Keepalive Daemon — Pulse Mode
#
# Monitors for Chrome stopping discovery and responds with a brief 3-second
# scan burst to re-seed the adapter, then immediately stops. Between pulses,
# it cleans non-paired devices to prevent D-Bus slot exhaustion.
# =============================================================================

echo "[BLE Keepalive] Starting — pulse scan mode"

while true; do
    # Check current discovering state
    DISCOVERING=$(dbus-send --system --print-reply --dest=org.bluez /org/bluez/hci0 \
        org.freedesktop.DBus.Properties.Get \
        string:"org.bluez.Adapter1" string:"Discovering" 2>/dev/null \
        | grep -o "true\|false")

    if [ "$DISCOVERING" = "false" ]; then
        # Chrome stopped scanning. Clean house first, then pulse scan.

        # 1. Remove ALL non-paired devices to free D-Bus slots
        while IFS= read -r line; do
            MAC=$(echo "$line" | awk '{print $2}')
            [ -z "$MAC" ] && continue
            PAIRED=$(bluetoothctl info "$MAC" 2>/dev/null | grep "Paired: yes")
            if [ -z "$PAIRED" ]; then
                bluetoothctl remove "$MAC" >/dev/null 2>&1
            fi
        done <<< "$(bluetoothctl devices 2>/dev/null)"

        # 2. Brief scan pulse (3 seconds)
        echo "[BLE Keepalive] $(date +%H:%M:%S) Pulse scan — cleaning + 3s burst"
        timeout 3 bluetoothctl scan on >/dev/null 2>&1

        # 3. Stop scan to prevent flooding
        bluetoothctl scan off >/dev/null 2>&1
    fi

    # Periodic cleanup even when discovering is true
    DEVCOUNT=$(bluetoothctl devices 2>/dev/null | wc -l)
    if [ "$DEVCOUNT" -gt 20 ]; then
        while IFS= read -r line; do
            MAC=$(echo "$line" | awk '{print $2}')
            [ -z "$MAC" ] && continue
            PAIRED=$(bluetoothctl info "$MAC" 2>/dev/null | grep "Paired: yes")
            if [ -z "$PAIRED" ]; then
                bluetoothctl remove "$MAC" >/dev/null 2>&1
            fi
        done <<< "$(bluetoothctl devices 2>/dev/null)"
    fi

    sleep 2
done
