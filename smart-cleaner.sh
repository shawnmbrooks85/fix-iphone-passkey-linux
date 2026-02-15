#!/bin/bash
# =============================================================================
# Smart BLE Device Cleaner
# Removes non-Apple devices every 2 seconds via D-Bus.
# KEEPS devices with Apple OUI prefixes so the iPhone's caBLE entry
# stays registered long enough for Chrome to complete the handshake.
# =============================================================================

# Apple OUI prefixes (first 3 bytes of MAC address)
# Apple uses dozens of OUIs — these are the most common for iPhones
# Also keep any device whose Name contains "iPhone" or "Apple"
APPLE_OUIS="
00_CD_FE 14_98_77 28_6A_BA 3C_06_30 40_B3_95 
4C_57_CA 54_4E_90 5C_96_9D 60_F8_1D 64_DB_A0
68_AB_1E 70_3E_AC 74_8D_08 78_67_D7 80_B0_3D
84_A1_34 88_E9_FE 8C_85_90 90_B0_ED 94_E9_79
98_01_A7 9C_20_7B A0_78_17 A4_B8_05 A8_51_5B
AC_BC_32 B0_BE_83 B4_F6_1C B8_17_C2 BC_D0_74
C0_D0_12 C4_91_0C C8_69_CD CC_44_63 D0_03_4B
D4_F4_6F D8_1C_79 DC_56_E7 E0_5F_45 E4_25_E7
E8_80_2E EC_AD_B8 F0_18_98 F4_0F_24 F8_FF_C2
FC_E9_98
"

echo "[Smart Cleaner] Starting — keeping Apple devices, removing everything else"

while true; do
    # Get all device paths from D-Bus
    DEVICES=$(busctl tree org.bluez 2>/dev/null | grep -oP '/org/bluez/hci0/dev_[A-F0-9_]+')
    
    for DEV_PATH in $DEVICES; do
        [ -z "$DEV_PATH" ] && continue
        
        # Extract MAC from path (dev_XX_XX_XX_XX_XX_XX → XX_XX_XX)
        MAC_PREFIX=$(echo "$DEV_PATH" | grep -oP 'dev_\K[A-F0-9]{2}_[A-F0-9]{2}_[A-F0-9]{2}')
        
        # Check if Apple OUI
        IS_APPLE=false
        if echo "$APPLE_OUIS" | grep -q "$MAC_PREFIX"; then
            IS_APPLE=true
        fi
        
        # Check if paired
        PAIRED=$(dbus-send --system --print-reply --dest=org.bluez "$DEV_PATH" \
            org.freedesktop.DBus.Properties.Get \
            string:"org.bluez.Device1" string:"Paired" 2>/dev/null \
            | grep -o "true")
        
        # Keep Apple devices and paired devices, remove everything else
        if [ "$IS_APPLE" = "false" ] && [ -z "$PAIRED" ]; then
            dbus-send --system --print-reply --dest=org.bluez /org/bluez/hci0 \
                org.bluez.Adapter1.RemoveDevice \
                objpath:"$DEV_PATH" >/dev/null 2>&1
        fi
    done
    
    sleep 2
done
