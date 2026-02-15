# Fix iPhone Passkey (caBLE) on Linux

**Reliable iPhone passkey (WebAuthn/FIDO2 caBLE) connections on Ubuntu 24.04+ with Intel AX211 Bluetooth. Works with all Chromium-based browsers (Chrome, Brave, Edge, etc.).**

## The Problem

iPhone passkeys via Chromium-based browsers (Chrome, Brave, Edge, etc.) on Linux are extremely unreliable. The connection stalls at "Connecting..." and never completes. This affects any site using WebAuthn with cross-device authentication (AWS, iCloud, Microsoft, etc.).

## Root Cause

It's a **3-layer cascade** — not a single bug:

| Layer | Issue | Impact |
|-------|-------|--------|
| **BlueZ** | Discovery filter cache not cleared on `StopDiscovery` | Subsequent scans are silently skipped |
| **Intel AX211** | MSFT firmware passive scanning floods 100-150+ BLE devices | D-Bus slots exhaust → browser can't register iPhone |
| **Config** | Missing `Experimental=true`, `Cache=no` in BlueZ config | Chromium's caBLE code silently fails |

## Quick Start

### Option 1: Full Fix (Recommended)

```bash
# Patches BlueZ, configures adapter, installs runtime services (~3 min)
sudo ./fix.sh

# After reboot, or to manually reset:
sudo ./passkey-reset.sh
```

### Option 2: Disable Intel MSFT Scanning (Kernel-Level)

```bash
# Disables firmware-level passive scanning via HCI command
# No BlueZ recompilation needed — installs a lightweight systemd service
sudo ./disable-msft-scanning.sh

# If your browser gets stuck at "Connecting...", run a quick reset:
sudo ./passkey-reset.sh
```

This targets the root cause directly: the Intel AX211's MSFT vendor extensions flood D-Bus with 100-150+ phantom BLE devices. Disabling MSFT scanning eliminates the flooding without needing the cleaner daemon.

> **Note:** Even after disabling MSFT scanning, your browser may occasionally stall on "Connecting…". Run `sudo ./passkey-reset.sh` to recover.

## What It Does

**Option 1** (full fix):
1. **Upgrades BlueZ** 5.72 → 5.77 with a discovery filter patch
2. **Configures BlueZ** for caBLE (`Experimental`, `FastConnectable`, GATT cache off)
3. **Enables BLE Privacy** (LE Privacy/RPA via systemd service)
4. **Installs runtime services:**
   - `ble-device-cleaner.service` — prevents D-Bus slot exhaustion
   - `bluetooth-privacy.service` — ensures privacy flag survives reboots
   - `passkey-ready.service` — keeps adapter discoverable/pairable and starts a BlueZ D-Bus monitor

**Option 2** (kernel-level):
1. **Sends HCI vendor command** to clear the MSFT opcode (`0xFC1E`) after adapter init
2. **Stops firmware-level passive scanning** — no more device flooding
3. **No BlueZ recompilation** — works with stock BlueZ

## Usage

After installation:

1. Open your Chromium-based browser (Chrome, Brave, Edge, etc.)
2. Visit `chrome://bluetooth-internals` briefly (initializes the browser's BLE proxy)
3. Close that tab
4. Navigate to any passkey-enabled site and use "iPhone" as your authenticator

### Manual Reset

If passkey stops working (e.g., after sleep/resume):

```bash
sudo ./passkey-reset.sh
```

### Troubleshooting: Stuck on "Connecting..."

1. Kill any stuck `btmgmt` or reset scripts (a hung `btmgmt info` can leave a root process running):
```bash
sudo pkill btmgmt || true
sudo pkill -f passkey-reset.sh || true
```

2. Ensure privacy is actually enabled (needed for reliable caBLE discovery):
```bash
sudo systemctl enable --now bluetooth-privacy.service
```

3. If you ran the full fix, ensure the runtime services are present and active:
```bash
systemctl is-active bluetooth-privacy.service ble-device-cleaner.service passkey-ready.service
```

4. Browser workaround: open `chrome://bluetooth-internals` (works in any Chromium-based browser) for 1-2 seconds, close the tab, then retry the passkey flow.

## Requirements

- Ubuntu 24.04+ (or any systemd-based Linux with BlueZ)
- Intel AX211 Bluetooth adapter (or similar with MSFT HCI extensions)
- Chromium-based browser — Chrome, Brave, Edge, etc. (Flatpak or native)
- iPhone with passkeys configured

## File Overview

| File | Purpose |
|------|---------|
| `fix.sh` | Main installer — builds BlueZ 5.77, applies patch, configures everything |
| `passkey-reset.sh` | Quick reset script for when passkey stops working |
| `fast-cleaner.sh` | D-Bus device cleaner daemon (prevents slot exhaustion) |
| `ble-scan-keepalive.sh` | Scan pulse daemon (ensures discovery stays active) |
| `patches/bluez-5.77-discovery-filter.patch` | BlueZ source patch |
| `rollback.sh` | Reverts everything to stock BlueZ |
| `systemd/bluetooth-privacy.service` | Auto-enables BLE privacy on boot |
| `systemd/ble-device-cleaner.service` | Auto-starts device cleaner on boot |
| `systemd/passkey-ready.service` | Auto-sets discoverable/pairable on boot |
| `systemd/bluetooth-override.conf` | Systemd drop-in for `--experimental` flag |

## Auto-Start on Boot

After running `fix.sh`, three systemd services are installed and enabled:

```
bluetooth.service
  └── bluetooth-privacy.service     (power cycle + privacy + bondable)
       └── ble-device-cleaner.service  (removes non-paired BLE devices)
       └── passkey-ready.service       (discoverable + pairable + dbus-monitor)
```

Everything starts automatically — no manual scripts needed. The only manual step is visiting `chrome://bluetooth-internals` once per browser session.

## How It Works

### The Discovery Filter Bug

In BlueZ's `adapter.c`, the function `update_discovery_filter()` skips restarting the scan if:
1. `adapter->discovering` is already `true` (set by Intel's firmware scanning), AND
2. The discovery filter matches the cached `current_discovery_filter`

But `stop_discovery_complete()` never clears that cache. So after the first successful passkey, subsequent attempts are silently skipped.

**Fix:** Two lines added to `stop_discovery_complete()`:
```c
g_free(adapter->current_discovery_filter);
adapter->current_discovery_filter = NULL;
```

### D-Bus Slot Exhaustion

The Intel AX211's MSFT HCI extensions cause continuous firmware-level BLE scanning, discovering 100-150+ devices in a typical environment. Each device is registered as a D-Bus object. BlueZ's `TemporaryTimeout` can't evict them because the continuous scanning keeps refreshing each device's timer.

**Fix:** `fast-cleaner.sh` runs every 2 seconds and forcibly removes non-paired devices via `RemoveDevice`, keeping D-Bus slot usage manageable.

## Rollback

```bash
sudo ./rollback.sh
```

This restores stock BlueZ from apt, reverts config, and removes all systemd services.

## License

MIT
