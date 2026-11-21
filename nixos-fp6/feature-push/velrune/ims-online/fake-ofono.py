"""A fake oFono for vm-test.nix: one modem (/qrtrsoc_0) whose Online can be set, with
PropertyChanged, and NetworkRegistration/ConnectionManager that follow it."""
import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SystemBus()
state = {"Online": False}


def props(d):
    return dbus.Dictionary(d, signature="sv")


class Manager(dbus.service.Object):
    @dbus.service.method("org.ofono.Manager", out_signature="a(oa{sv})")
    def GetModems(self):
        p = props({"Powered": dbus.Boolean(True), "Online": dbus.Boolean(state["Online"])})
        return dbus.Array([dbus.Struct((dbus.ObjectPath("/qrtrsoc_0"), p))], signature="(oa{sv})")


class NetReg(dbus.service.Object):
    @dbus.service.method("org.ofono.NetworkRegistration", out_signature="a{sv}")
    def GetProperties(self):
        return props({"Status": "registered" if state["Online"] else "unregistered"})


class ConnMan(dbus.service.Object):
    @dbus.service.method("org.ofono.ConnectionManager", out_signature="a{sv}")
    def GetProperties(self):
        return props({"Attached": dbus.Boolean(state["Online"]), "Powered": dbus.Boolean(True)})


class Modem(NetReg, ConnMan):
    @dbus.service.method("org.ofono.Modem", out_signature="a{sv}")
    def GetProperties(self):
        return props({"Powered": dbus.Boolean(True), "Online": dbus.Boolean(state["Online"])})

    @dbus.service.method("org.ofono.Modem", in_signature="sv")
    def SetProperty(self, key, value):
        if key == "Online" and bool(value) != state["Online"]:
            state["Online"] = bool(value)
            self.PropertyChanged("Online", dbus.Boolean(state["Online"], variant_level=1))

    @dbus.service.signal("org.ofono.Modem", signature="sv")
    def PropertyChanged(self, key, value):
        pass


name = dbus.service.BusName("org.ofono", bus)
Manager(bus, "/")
Modem(bus, "/qrtrsoc_0")
GLib.MainLoop().run()
