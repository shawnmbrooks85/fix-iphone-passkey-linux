#!/usr/bin/env bash
# Capture a single caBLE attempt with bluetoothd debug, btmon, and D-Bus traces.
# Usage: sudo ./trace-cable.sh [hciX]
#
# Output goes under /tmp/cable-trace-YYYYmmdd-HHMMSS/
set -euo pipefail

HCI_DEV="${1:-hci0}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="/tmp/cable-trace-${TS}"

if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "Run as root: sudo $0 ${HCI_DEV}" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
echo "[trace] writing logs to ${OUT_DIR}"

BTMON_PID=""
BTD_PID=""
DBUS_PID=""

cleanup() {
  set +e
  echo "[trace] stopping capture..."
  [[ -n "${DBUS_PID}" ]] && kill "${DBUS_PID}" >/dev/null 2>&1 || true
  [[ -n "${BTD_PID}" ]] && kill "${BTD_PID}" >/dev/null 2>&1 || true
  [[ -n "${BTMON_PID}" ]] && kill "${BTMON_PID}" >/dev/null 2>&1 || true
  sleep 1

  echo "[trace] restoring bluetooth service..."
  systemctl start bluetooth >/dev/null 2>&1 || true
  sleep 1
  echo "[trace] done"
}
trap cleanup EXIT INT TERM

echo "[trace] stopping bluetooth.service (we'll run bluetoothd in foreground)..."
systemctl stop bluetooth
sleep 1

echo "[trace] starting btmon..."
btmon -w "${OUT_DIR}/btmon.btsnoop" >"${OUT_DIR}/btmon.txt" 2>&1 &
BTMON_PID="$!"
sleep 1

echo "[trace] starting dbus-monitor (org.bluez only)..."
dbus-monitor --system "sender='org.bluez' or destination='org.bluez'" >"${OUT_DIR}/dbus.txt" 2>&1 &
DBUS_PID="$!"
sleep 1

echo "[trace] starting bluetoothd debug..."
/usr/libexec/bluetooth/bluetoothd -n -d --experimental -P battery >"${OUT_DIR}/bluetoothd.txt" 2>&1 &
BTD_PID="$!"
sleep 2

echo "[trace] adapter snapshot:"
bluetoothd --version >"${OUT_DIR}/snapshot.txt" 2>&1 || true
btmgmt info >>"${OUT_DIR}/snapshot.txt" 2>&1 || true
hciconfig "${HCI_DEV}" -a >>"${OUT_DIR}/snapshot.txt" 2>&1 || true

cat <<EOF
[trace] capture is running.

1) Reproduce the passkey failure (the iPhone stalls at "Connecting...").
2) Come back here and press Ctrl+C.

Files:
  ${OUT_DIR}/bluetoothd.txt
  ${OUT_DIR}/dbus.txt
  ${OUT_DIR}/btmon.btsnoop  (open with Wireshark)
  ${OUT_DIR}/btmon.txt
  ${OUT_DIR}/snapshot.txt
EOF

wait

