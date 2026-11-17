"""Just enough of org.freedesktop.login1 for GNOME Shell to start in a
container without systemd: the name is owned, the Manager object answers,
and every session query returns a fixed seat-less session."""
from gi.repository import Gio, GLib

XML = """
<node>
 <interface name="org.freedesktop.login1.Manager">
  <method name="GetSession"><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
  <method name="GetSessionByPID"><arg type="u" direction="in"/><arg type="o" direction="out"/></method>
  <method name="ListSessions"><arg type="a(susso)" direction="out"/></method>
  <method name="Inhibit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="h" direction="out"/></method>
  <method name="CanSuspend"><arg type="s" direction="out"/></method>
  <method name="CanRebootToBootLoaderMenu"><arg type="s" direction="out"/></method>
  <signal name="PrepareForSleep"><arg type="b"/></signal>
 </interface>
 <interface name="org.freedesktop.login1.Session">
  <property name="Id" type="s" access="read"/>
  <property name="Active" type="b" access="read"/>
  <property name="Remote" type="b" access="read"/>
  <property name="Class" type="s" access="read"/>
  <property name="Type" type="s" access="read"/>
  <property name="State" type="s" access="read"/>
  <property name="LockedHint" type="b" access="read"/>
  <signal name="Lock"/><signal name="Unlock"/>
 </interface>
</node>"""
node = Gio.DBusNodeInfo.new_for_xml(XML)
SESSION = "/org/freedesktop/login1/session/c1"


def call(conn, sender, path, iface, method, params, inv):
    if method in ("GetSession", "GetSessionByPID"):
        inv.return_value(GLib.Variant("(o)", (SESSION,)))
    elif method == "ListSessions":
        inv.return_value(GLib.Variant("(a(susso))", ([("c1", 1000, "tester", "seat0", SESSION)],)))
    elif method in ("CanSuspend", "CanRebootToBootLoaderMenu"):
        inv.return_value(GLib.Variant("(s)", ("na",)))
    else:
        inv.return_dbus_error("org.freedesktop.DBus.Error.NotSupported", "fake logind")


def prop(conn, sender, path, iface, name):
    return {"Id": GLib.Variant("s", "c1"), "Active": GLib.Variant("b", True), "Remote": GLib.Variant("b", False),
            "Class": GLib.Variant("s", "user"), "Type": GLib.Variant("s", "wayland"),
            "State": GLib.Variant("s", "active"), "LockedHint": GLib.Variant("b", False)}.get(name)


def acquired(conn, name):
    conn.register_object("/org/freedesktop/login1", node.interfaces[0], call, None, None)
    conn.register_object(SESSION, node.interfaces[1], call, prop, None)


Gio.bus_own_name(Gio.BusType.SYSTEM, "org.freedesktop.login1", Gio.BusNameOwnerFlags.NONE, acquired, None, None)
GLib.MainLoop().run()
