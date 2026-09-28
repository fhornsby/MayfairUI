#!/usr/bin/env python3
"""
A stand-in for xdg-desktop-portal's FileChooser, for tests/source/tests/files.d.

It sits on a private session bus the test starts, so no real dialog comes up on the desktop.
Each call is printed as a line of JSON -- what the test checks the dialog was asked for -- and
answered at once, as if the user had chosen:

    OpenFile            file:///tmp/mayfair/a.png, and with "multiple", file:///tmp/mayfair/b c.png too
    SaveFile            the suggested file, or the suggested name in the suggested folder
    title "Cancel me"   cancelled, whichever it is

    python3 fake_portal.py BUS_ADDRESS
"""
import json
import sys

from gi.repository import Gio, GLib

XML = """
<node>
  <interface name="org.freedesktop.portal.FileChooser">
    <method name="OpenFile">
      <arg type="s" name="parent_window" direction="in"/>
      <arg type="s" name="title" direction="in"/>
      <arg type="a{sv}" name="options" direction="in"/>
      <arg type="o" name="handle" direction="out"/>
    </method>
    <method name="SaveFile">
      <arg type="s" name="parent_window" direction="in"/>
      <arg type="s" name="title" direction="in"/>
      <arg type="a{sv}" name="options" direction="in"/>
      <arg type="o" name="handle" direction="out"/>
    </method>
    <property name="version" type="u" access="read"/>
  </interface>
</node>
"""


def plain(value):
    """Options as JSON can hold them: byte strings (paths, as "ay") as text."""
    if isinstance(value, (bytes, bytearray)):
        return bytes(value).rstrip(b"\0").decode()
    if isinstance(value, list) and value and all(isinstance(v, int) for v in value):
        return bytes(value).rstrip(b"\0").decode()
    if isinstance(value, (list, tuple)):
        return [plain(v) for v in value]
    if isinstance(value, dict):
        return {k: plain(v) for k, v in value.items()}
    return value


def answer(method, title, options):
    if title == "Cancel me":
        return 1, {}
    if method == "OpenFile":
        uris = ["file:///tmp/mayfair/a.png"]
        if options.get("multiple"):
            uris.append("file:///tmp/mayfair/b%20c.png")
    else:
        if "current_file" in options:
            uris = ["file://" + options["current_file"]]
        else:
            uris = ["file://" + options.get("current_folder", "/tmp") + "/" + options.get("current_name", "untitled")]
    return 0, {"uris": GLib.Variant("as", uris)}


def on_call(connection, sender, path, interface, method, parameters, invocation):
    parent, title, raw = parameters.unpack()
    options = plain(raw)
    print(json.dumps({"method": method, "parent_window": parent, "title": title, "options": options}), flush=True)

    # The request's object path is the caller's unique name and its token, as the portal spec says
    token = options.get("handle_token", "t")
    handle = "/org/freedesktop/portal/desktop/request/%s/%s" % (sender[1:].replace(".", "_"), token)
    invocation.return_value(GLib.Variant("(o)", (handle,)))

    response, results = answer(method, title, options)
    # After the reply, as the real portal does: the caller subscribes to the signal first
    GLib.idle_add(lambda: connection.emit_signal(
        sender, handle, "org.freedesktop.portal.Request", "Response",
        GLib.Variant("(ua{sv})", (response, results))) and False)


def on_property(connection, sender, path, interface, name):
    return GLib.Variant("u", 4)


def main():
    connection = Gio.DBusConnection.new_for_address_sync(
        sys.argv[1], Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION)
    info = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0]
    # register_object is deprecated where the closures2 form exists
    register = getattr(connection, "register_object_with_closures2", connection.register_object)
    register("/org/freedesktop/portal/desktop", info, on_call, on_property, None)
    loop = GLib.MainLoop()

    def owned(*_):
        print(json.dumps({"ready": True}), flush=True)

    Gio.bus_own_name_on_connection(connection, "org.freedesktop.portal.Desktop",
                                   Gio.BusNameOwnerFlags.NONE, owned, lambda *_: loop.quit())
    loop.run()


if __name__ == "__main__":
    main()
