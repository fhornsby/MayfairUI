#!/usr/bin/env python3
"""
Checks the running accessibility test app the way a screen reader sees it: over AT-SPI, on the
accessibility bus, with nothing but busctl. Run it through run.sh, which starts the app and
switches the session's accessibility on around it.
"""
import json, subprocess, sys, time

failures = []

def check(ok, what):
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok:
        failures.append(what)

def bus(*args):
    out = subprocess.run(["busctl", "--json=short", "--timeout=3"] + list(args), capture_output=True, text=True)
    if out.returncode:
        raise RuntimeError(out.stderr.strip())
    return json.loads(out.stdout)["data"] if out.stdout.strip() else None

address = bus("--user", "call", "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress")[0]
A = lambda *a: bus("--address=" + address, "--", *a)
ACCESSIBLE, TEXT = "org.a11y.atspi.Accessible", "org.a11y.atspi.Text"
FRAME, LABEL, BUTTON, ENTRY = 23, 29, 43, 79          # AT-SPI roles
FOCUSABLE, SENSITIVE = 11, 24                          # AT-SPI state bits

# The app: the newest registration called mayfair-tests
apps = A("call", "org.a11y.atspi.Registry", "/org/a11y/atspi/accessible/root", ACCESSIBLE, "GetChildren")[0]
app = next((n, p) for n, p in reversed(apps) if A("get-property", n, p, ACCESSIBLE, "Name") == "mayfair-tests")

nodes = []
def walk(name, path):
    role = A("call", name, path, ACCESSIBLE, "GetRole")[0]
    nodes.append({"role": role, "name": A("get-property", name, path, ACCESSIBLE, "Name"), "at": (name, path),
                  "state": A("call", name, path, ACCESSIBLE, "GetState")[0][0]})
    for child in A("call", name, path, ACCESSIBLE, "GetChildren")[0]:
        walk(*child)
walk(*app)

def find(role, name=None):
    return next((n for n in nodes if n["role"] == role and (name is None or n["name"] == name)), None)

check(find(FRAME, "accessibility check") is not None, "the window is a frame named after it")
check(find(LABEL, "Not pressed") is not None, "the label is there, with its text")
button = find(BUTTON, "Press me")
check(button is not None and button["state"] >> FOCUSABLE & 1, "the button is there, focusable")
disabled = find(BUTTON, "Disabled")
check(disabled is not None and not disabled["state"] >> FOCUSABLE & 1, "the disabled button isn't focusable")

# Pressing the button through its Action interface
at = button["at"]
names = [A("call", *at, "org.a11y.atspi.Action", "GetName", "i", str(i))[0]
         for i in range(A("get-property", *at, "org.a11y.atspi.Action", "NActions"))]
check("click" in names, "the button offers click")
A("call", *at, "org.a11y.atspi.Action", "DoAction", "i", str(names.index("click")))
time.sleep(0.5)
nodes.clear(); walk(*app)
check(find(LABEL, "Pressed") is not None, "clicking it through AT-SPI ran its action")

# The text field: its text, its characters where they're drawn, and its selection
field = find(ENTRY)["at"]
T = lambda method, sig="", *a: A("call", *field, TEXT, method, *([sig] + [str(x) for x in a] if sig else []))
text = T("GetText", "ii", 0, -1)[0]
check(text == "abc שלום def", f"the field's text is read in order: {text!r}")
extents = {i: T("GetCharacterExtents", "iu", i, 1) for i in (0, 4, 7, 9)}
check(extents[0][0] < extents[7][0] < extents[4][0] < extents[9][0],
      f"characters are where they're drawn, the Hebrew right to left: {extents}")
check(T("SetSelection", "iii", 0, 4, 8)[0], "selecting the Hebrew through AT-SPI")
time.sleep(0.4)
check(T("GetSelection", "i", 0) == [4, 8], "the selection is the Hebrew word")
A("call", *field, "org.a11y.atspi.EditableText", "SetTextContents", "s", "set by a screen reader")
time.sleep(0.4)
check(T("GetText", "ii", 0, -1)[0] == "set by a screen reader", "the text can be set through AT-SPI")

print(f"{len(failures)} failed")
sys.exit(1 if failures else 0)
