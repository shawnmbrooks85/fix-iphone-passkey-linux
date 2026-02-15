# Manual Fix Steps

If you prefer not to run the automated script, here are the individual steps.

## 1. Install Build Dependencies

```bash
sudo apt update
sudo apt install -y build-essential libreadline-dev libical-dev \
    libdbus-1-dev libudev-dev libglib2.0-dev python3-docutils \
    flex bison libdw-dev libell-dev libjson-c-dev wget
```

## 2. Build BlueZ 5.77

```bash
cd /tmp
wget https://www.kernel.org/pub/linux/bluetooth/bluez-5.77.tar.xz
tar -xf bluez-5.77.tar.xz
cd bluez-5.77

./configure --prefix=/usr --mandir=/usr/share/man \
    --sysconfdir=/etc --localstatedir=/var \
    --enable-experimental --enable-testing

make -j$(nproc)
sudo systemctl stop bluetooth
sudo make install
```

## 3. Edit `/etc/bluetooth/main.conf`

```ini
[General]
Experimental = true
KernelExperimental = 15c0a148-c273-11ea-b3de-0242ac130004
FastConnectable = true

[GATT]
Cache = no
```

## 4. Create Systemd Override

```bash
sudo mkdir -p /etc/systemd/system/bluetooth.service.d
sudo tee /etc/systemd/system/bluetooth.service.d/passkey-fix.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/libexec/bluetooth/bluetoothd --experimental -P battery
EOF
```

## 5. Enable BLE Privacy

```bash
sudo systemctl daemon-reload
sudo systemctl restart bluetooth
sleep 3
sudo btmgmt power off
sudo btmgmt privacy on
sudo btmgmt power on
```

## 6. Make Discoverable (Optional)

```bash
bluetoothctl discoverable on
bluetoothctl pairable on
```

## 7. Verify

```bash
bluetoothd --version          # Should show 5.77
btmgmt info | grep "current"  # Should include "privacy" and "le"
ps aux | grep bluetoothd       # Should show --experimental -P battery
```

## 8. Persist Privacy Across Reboots

Create `/etc/systemd/system/bluetooth-privacy.service`:

```ini
[Unit]
Description=Enable BLE Privacy for passkey support
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 2
ExecStart=/bin/bash -lc 'timeout 5 btmgmt power off 2>/dev/null || true; sleep 1; timeout 5 btmgmt bondable on 2>/dev/null || true; timeout 5 btmgmt privacy on 2>/dev/null || true; sleep 1; timeout 5 btmgmt power on 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now bluetooth-privacy.service
```

## 9. Optional: Persist Discoverable/Pairable + D-Bus Monitor

If caBLE works once and then stalls at "Connecting..." after reboot/sleep, keep the adapter discoverable/pairable and ensure a BlueZ D-Bus consumer exists:

Create `/etc/systemd/system/passkey-ready.service`:

```ini
[Unit]
Description=Set adapter discoverable and pairable for passkey support
After=bluetooth-privacy.service
Requires=bluetooth.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 1
ExecStart=/bin/bash -c 'bluetoothctl discoverable on && bluetoothctl pairable on && bluetoothctl discoverable-timeout 0'
ExecStartPost=/bin/bash -lc "pkill -f 'dbus-monitor.*org.bluez' 2>/dev/null || true; dbus-monitor --system \"sender='org.bluez'\" > /dev/null 2>&1 &"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now passkey-ready.service
```
