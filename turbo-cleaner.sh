#!/bin/bash
# =============================================================================
# Turbo BLE Cleaner - Bulk removes ALL temporary devices every 1 second
# Uses a single bluetoothctl session for speed
# =============================================================================

echo "[Turbo Cleaner] Running bulk device purge every 1 second"

while true; do
    # Get all device MACs in one shot
    MACS=$(bluetoothctl devices 2>/dev/null | awk '{print $2}')
    
    if [ -n "$MACS" ]; then
        for MAC in $MACS; do
            # Quick paired check via bluetoothctl info
            if ! bluetoothctl info "$MAC" 2>/dev/null | grep -q "Paired: yes"; then
                bluetoothctl remove "$MAC" >/dev/null 2>&1
            fi
        done
    fi
    
    sleep 1
done
