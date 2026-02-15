#!/usr/bin/env bash
# Reset likely-stuck BlueZ/caBLE state between attempts without reinstalling.
# Usage: sudo ./reset-cable.sh [hciX]
set -euo pipefail

HCI_DEV="${1:-hci0}"

log()  { printf '[reset] %s\n' "$*"; }
warn() { printf '[reset][warn] %s\n' "$*" >&2; }

if [[ "${EUID:-0}" -ne 0 ]]; then
  warn "Run as root: sudo $0 ${HCI_DEV}"
  exit 1
fi

if ! command -v busctl >/dev/null 2>&1; then
  warn "busctl not found (systemd). Continuing anyway."
fi

log "Stopping any ongoing discovery on /org/bluez/${HCI_DEV} (ignore errors)..."
busctl --system call org.bluez "/org/bluez/${HCI_DEV}" org.bluez.Adapter1 StopDiscovery >/dev/null 2>&1 || true

log "Power-cycling adapter + enabling privacy (RPA)..."
btmgmt power off >/dev/null 2>&1 || true
sleep 1
btmgmt privacy on >/dev/null 2>&1 || true
sleep 1
btmgmt power on >/dev/null 2>&1 || true
sleep 2

# Cache cleanup: keeps pairings, removes discovered device cache noise.
ADAPTER_MAC="$(
  hciconfig "${HCI_DEV}" 2>/dev/null | awk -F'BD Address: ' 'NF>1{print $2}' | awk '{print $1}' | head -n1
)"
if [[ -n "${ADAPTER_MAC}" ]] && [[ -d "/var/lib/bluetooth/${ADAPTER_MAC}/cache" ]]; then
  log "Clearing discovered device cache: /var/lib/bluetooth/${ADAPTER_MAC}/cache/*"
  rm -rf "/var/lib/bluetooth/${ADAPTER_MAC}/cache/"* 2>/dev/null || true
else
  warn "Could not locate adapter cache directory for ${HCI_DEV} (MAC=${ADAPTER_MAC:-unknown})."
fi

log "Restarting bluetooth service to flush any leaked D-Bus state..."
systemctl restart bluetooth
sleep 2

log "Done. Retry the passkey QR flow."

