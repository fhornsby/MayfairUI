#!/usr/bin/env python3
"""
A stand-in for a desktop's notifications, for tests/source/tests/notifications.d: the freedesktop
notification service (org.freedesktop.Notifications) and the desktop portal's
(org.freedesktop.portal.Notification), on a private session bus the test starts, so nothing shows
on the desktop.

Each call is printed as a line of JSON -- what the test checks the desktop was asked -- and the
user's response acted out, by the notification's title:

    "Press the first button"   its first button pressed
    "Click me"                 the notification itself clicked
    "Dismiss me"               dismissed (the service only: the portal doesn't say)

The service, as most do, takes a clicked notification away once it's been clicked.

    python3 fake_notifications.py BUS_ADDRESS
"""
import json
import sys

from gi.repository import Gio, GLib

XML = """
<node>
  <interface name="org.freedesktop.Notifications">
    <method name="Notify">
      <arg type="s" name="app_name" direction="in"/>
      <arg type="u" name="replaces_id" direction="in"/>
      <arg type="s" name="app_icon" direction="in"/>
      <arg type="s" name="summary" direction="in"/>
      <arg type="s" name="body" direction="in"/>
      <arg type="as" name="actions" direction="in"/>
      <arg type="a{sv}" name="hints" direction="in"/>
      <arg type="i" name="expire_timeout" direction="in"/>
      <arg type="u" name="id" direction="out"/>
    </method>
    <method name="CloseNotification">
      <arg type="u" name="id" direction="in"/>
    </method>
    <method name="GetCapabilities">
      <arg type="as" name="capabilities" direction="out"/>
    </method>
  </interface>
  <interface name="org.freedesktop.portal.Notification">
    <method name="AddNotification">
      <arg type="s" name="id" direction="in"/>
      <arg type="a{sv}" name="notification" direction="in"/>
    </method>
    <method name="RemoveNotification">
      <arg type="s" name="id" direction="in"/>
    </method>
    <property name="version" type="u" access="read"/>
  </interface>
</node>
"""

SERVICE = "org.freedesktop.Notifications"
PORTAL = "org.freedesktop.portal.Notification"
next_id = [1]


def plain(value):
    """Values as JSON can hold them: an icon's bytes as how many there are."""
    if isinstance(value, (bytes, bytearray)):
        return {"bytes": len(value)}
    if isinstance(value, tuple) and len(value) == 2 and value[0] == "bytes":
        return ["bytes", len(value[1])]
    if isinstance(value, (list, tuple)):
        return [plain(v) for v in value]
    if isinstance(value, dict):
        return {k: plain(v) for k, v in value.items()}
    return value


def later(f):
    """After the reply, as a real desktop would: a user can't click before it's shown."""
    GLib.timeout_add(50, lambda: f() and False)


def on_call(connection, sender, path, interface, method, parameters, invocation):
    args = parameters.unpack()
    if method == "Notify":
        app, replaces, icon, title, body, actions, hints, timeout = args
        nid = replaces or next_id[0]
        if not replaces:
            next_id[0] += 1
        print(json.dumps({"method": method, "app_name": app, "replaces_id": replaces, "app_icon": icon,
                          "summary": title, "body": body, "actions": actions, "hints": plain(hints),
                          "id": nid}), flush=True)
        invocation.return_value(GLib.Variant("(u)", (nid,)))

        def signal(name, signature, values):
            connection.emit_signal(sender, "/org/freedesktop/Notifications", SERVICE, name,
                                   GLib.Variant(signature, values))
        def clicked(action):
            signal("ActionInvoked", "(us)", (nid, action))
            signal("NotificationClosed", "(uu)", (nid, 2))
        if title == "Press the first button":
            later(lambda: clicked("0"))
        elif title == "Click me":
            later(lambda: clicked("default"))
        elif title == "Dismiss me":
            later(lambda: signal("NotificationClosed", "(uu)", (nid, 2)))
    elif method == "CloseNotification":
        print(json.dumps({"method": method, "id": args[0]}), flush=True)
        invocation.return_value(None)
        later(lambda: connection.emit_signal(sender, "/org/freedesktop/Notifications", SERVICE,
                                             "NotificationClosed", GLib.Variant("(uu)", (args[0], 3))))
    elif method == "GetCapabilities":
        invocation.return_value(GLib.Variant("(as)", (["actions", "body", "icon-static"],)))
    elif method == "AddNotification":
        nid, notification = args
        options = plain(notification)
        print(json.dumps({"method": method, "id": nid, "notification": options}), flush=True)
        invocation.return_value(None)

        def invoked(action):
            connection.emit_signal(sender, "/org/freedesktop/portal/desktop", PORTAL, "ActionInvoked",
                                   GLib.Variant("(ssav)", (nid, action, [])))
        if options.get("title") == "Press the first button":
            later(lambda: invoked("0"))
        elif options.get("title") == "Click me":
            later(lambda: invoked("default"))
    elif method == "RemoveNotification":
        print(json.dumps({"method": method, "id": args[0]}), flush=True)
        invocation.return_value(None)


def on_property(connection, sender, path, interface, name):
    return GLib.Variant("u", 2)


def main():
    connection = Gio.DBusConnection.new_for_address_sync(
        sys.argv[1], Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION)
    nodes = Gio.DBusNodeInfo.new_for_xml(XML).interfaces
    register = getattr(connection, "register_object_with_closures2", connection.register_object)
    register("/org/freedesktop/Notifications", nodes[0], on_call, None, None)
    register("/org/freedesktop/portal/desktop", nodes[1], on_call, on_property, None)
    loop = GLib.MainLoop()
    names = [SERVICE, "org.freedesktop.portal.Desktop"]
    owned = []

    def got(_connection, name):
        owned.append(name)
        if len(owned) == len(names):
            print(json.dumps({"ready": True}), flush=True)

    for name in names:
        Gio.bus_own_name_on_connection(connection, name, Gio.BusNameOwnerFlags.NONE, got, lambda *_: loop.quit())
    loop.run()


if __name__ == "__main__":
    main()
