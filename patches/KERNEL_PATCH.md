# Kernel-Level Fix: Disable Intel MSFT Passive Scanning

## Overview

The Intel AX211 Bluetooth adapter uses **MSFT HCI vendor extensions** (opcode `0xFC1E`) to enable firmware-level passive BLE scanning. This causes the adapter to continuously discover and report 100-150+ BLE devices in a typical environment, which BlueZ registers as D-Bus objects, eventually exhausting D-Bus slots and preventing Chrome from registering the iPhone's caBLE device for passkey authentication.

## The Problem in Code

In `drivers/bluetooth/btintel.c`, the function `btintel_set_msft_opcode()` enables MSFT extensions for Intel hardware variants 0x11-0x1e (which includes the AX211):

```c
void btintel_set_msft_opcode(struct hci_dev *hdev, u8 hw_variant)
{
    switch (hw_variant) {
    case 0x17:  // ← AX211 falls here
    case 0x18:
    case 0x19:
    case 0x1b:
    case 0x1c:
    case 0x1d:
    case 0x1e:
        hci_set_msft_opcode(hdev, 0xFC1E);  // ← THIS enables MSFT scanning
        break;
    }
}
```

This is called from `btintel_setup_combined()` at three locations:
- Line 3093: Legacy bootloader path
- Line 3172: Legacy TLV path  
- **Line 3197: New TLV path (AX211 — hw variants 0x17-0x1e)**

## Two Patch Approaches

### Approach 1: btusb Module Parameter (Recommended)

Adds a `disable_msft` boolean module parameter to `btusb.c` that conditionally skips MSFT extension setup in `btintel.c`. This is the cleanest approach as it:
- Doesn't modify Intel-specific code
- Can be toggled at module load time
- Is consistent with existing btusb params (`disable_scofix`, `force_scofix`, `reset`)

**Usage:**
```bash
# Load with MSFT disabled
sudo modprobe btusb disable_msft=1

# Or persist via modprobe config
echo "options btusb disable_msft=1" | sudo tee /etc/modprobe.d/btusb-no-msft.conf
sudo update-initramfs -u
```

### Approach 2: DKMS Module (Provided)

Rebuilds `btintel.ko` with the MSFT opcode call removed for AX211 variants. This is a more targeted approach but requires DKMS infrastructure.

## Building

See `build-kernel-module.sh` for automated DKMS build instructions.

## What This Fixes

Without MSFT extensions:
- No firmware-level passive scanning
- No D-Bus device flooding
- No need for the `fast-cleaner.sh` daemon
- Chrome can immediately register the iPhone's caBLE advertisement

## What This Doesn't Break

MSFT extensions are used for:
1. **Advertisement monitoring** — used by Windows for Swift Pair. Not used on Linux.
2. **RSSI monitoring** — used by some Windows apps. Not used on Linux desktop.
3. **Background scanning offload** — useful for IoT. Not needed for passkey auth.

Disabling MSFT has **no effect** on:
- Normal BLE scanning (Active scanning via HCI still works)
- Bluetooth Classic (A2DP, HFP, etc.)
- LE connections, pairing, bonding
- Privacy/RPA functionality
