#!/usr/bin/env python3
"""
BLE Advertisement Monitor for iPhone Passkeys
Registers a hardware-level BLE filter that only allows devices advertising
the FIDO caBLE service UUID (0xFFF9) to be registered on D-Bus.
All other BLE noise is silently dropped at the kernel/firmware level.

This leverages the Intel AX211's MSFT HCI extension for zero-overhead filtering.
"""

import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib
import signal
import sys

MONITOR_IFACE = 'org.bluez.AdvertisementMonitor1'
MONITOR_MGR_IFACE = 'org.bluez.AdvertisementMonitorManager1'
BLUEZ_BUS = 'org.bluez'
ADAPTER_PATH = '/org/bluez/hci0'

# FIDO caBLE service UUID bytes (0xFFF9 = FD:F9 in BLE advertisement)
# The advertisement contains the UUID in the "Service Data" AD type (0x16)
# For 16-bit UUIDs: AD Type 0x16, then UUID in little-endian
CABLE_SERVICE_DATA_TYPE = 0x16  # Service Data - 16-bit UUID
CABLE_UUID_BYTES = [0xF9, 0xFF]  # 0xFFF9 in little-endian


class AdvMonitor(dbus.service.Object):
    """D-Bus object implementing the AdvertisementMonitor1 interface."""
    
    def __init__(self, bus, path):
        super().__init__(bus, path)
        self._released = False
    
    @dbus.service.method(MONITOR_IFACE, in_signature='', out_signature='')
    def Release(self):
        print("[Monitor] Released by BlueZ")
        self._released = True

    @dbus.service.method(MONITOR_IFACE, in_signature='o', out_signature='')
    def DeviceFound(self, device):
        print(f"[Monitor] caBLE device found: {device}")

    @dbus.service.method(MONITOR_IFACE, in_signature='o', out_signature='')
    def DeviceLost(self, device):
        print(f"[Monitor] caBLE device lost: {device}")

    @dbus.service.method(dbus.PROPERTIES_IFACE,
                         in_signature='ss', out_signature='v')
    def Get(self, interface, prop):
        if interface != MONITOR_IFACE:
            raise dbus.exceptions.DBusException('Unknown interface')
        
        if prop == 'Type':
            return dbus.String('or_patterns')
        elif prop == 'Patterns':
            # Pattern: match Service Data AD type containing FIDO UUID 0xFFF9
            # Each pattern is a struct: (start_pos, ad_type, content)
            # start_pos: byte offset within the AD data (0 = first byte after type+length)
            # ad_type: AD Type to match (0x16 = Service Data 16-bit UUID)
            # content: bytes to match at start_pos
            pattern = dbus.Struct(
                (
                    dbus.Byte(0),        # start position
                    dbus.Byte(0x16),     # AD Type: Service Data - 16-bit UUID
                    dbus.Array([dbus.Byte(0xF9), dbus.Byte(0xFF)], signature='y')  # 0xFFF9 LE
                ),
                signature='yyay'
            )
            return dbus.Array([pattern], signature='(yyay)')
        elif prop == 'RSSILowThreshold':
            return dbus.Int16(-127)  # Accept any signal strength
        elif prop == 'RSSIHighThreshold':
            return dbus.Int16(0)
        elif prop == 'RSSILowTimeout':
            return dbus.UInt16(0)
        elif prop == 'RSSIHighTimeout':
            return dbus.UInt16(0)
        
        raise dbus.exceptions.DBusException('Unknown property')

    @dbus.service.method(dbus.PROPERTIES_IFACE,
                         in_signature='s', out_signature='a{sv}')
    def GetAll(self, interface):
        if interface != MONITOR_IFACE:
            return {}
        return {
            'Type': self.Get(interface, 'Type'),
            'Patterns': self.Get(interface, 'Patterns'),
        }


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    
    monitor_path = '/com/passkey/monitor0'
    monitor = AdvMonitor(bus, monitor_path)
    
    # Register the monitor with BlueZ
    mgr = dbus.Interface(
        bus.get_object(BLUEZ_BUS, ADAPTER_PATH),
        MONITOR_MGR_IFACE
    )
    
    # Create an application path and register
    app_path = '/com/passkey'
    
    print("[Monitor] Registering caBLE advertisement filter (UUID 0xFFF9)...")
    print("[Monitor] Only iPhone passkey advertisements will reach D-Bus")
    
    try:
        mgr.RegisterMonitor(dbus.ObjectPath(monitor_path))
        print("[Monitor] ✅ Hardware-level filter ACTIVE")
    except dbus.exceptions.DBusException as e:
        print(f"[Monitor] Registration failed: {e}")
        print("[Monitor] Trying alternative registration...")
        # Some BlueZ versions need RegisterMonitorApplication instead
        try:
            # Create a minimal application manager
            class MonitorApp(dbus.service.Object):
                @dbus.service.method('org.freedesktop.DBus.ObjectManager',
                                     out_signature='a{oa{sa{sv}}}')
                def GetManagedObjects(self_inner):
                    return {
                        monitor_path: {
                            MONITOR_IFACE: {
                                'Type': dbus.String('or_patterns'),
                                'Patterns': monitor.Get(MONITOR_IFACE, 'Patterns'),
                            }
                        }
                    }
            
            app = MonitorApp(bus, app_path)
            mgr_alt = dbus.Interface(
                bus.get_object(BLUEZ_BUS, ADAPTER_PATH),
                MONITOR_MGR_IFACE
            )
            # Try the Application-based registration
            if hasattr(mgr_alt, 'RegisterMonitorApplication'):
                mgr_alt.RegisterMonitorApplication(dbus.ObjectPath(app_path))
            else:
                mgr_alt.RegisterMonitor(dbus.ObjectPath(app_path))
            print("[Monitor] ✅ Hardware-level filter ACTIVE (via application)")
        except dbus.exceptions.DBusException as e2:
            print(f"[Monitor] Alternative registration also failed: {e2}")
            sys.exit(1)
    
    # Run the main loop to keep the filter active
    loop = GLib.MainLoop()
    
    def sigterm_handler(sig, frame):
        print("\n[Monitor] Shutting down...")
        loop.quit()
    
    signal.signal(signal.SIGTERM, sigterm_handler)
    signal.signal(signal.SIGINT, sigterm_handler)
    
    print("[Monitor] Running... (Ctrl+C to stop)")
    loop.run()


if __name__ == '__main__':
    main()
