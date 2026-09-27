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

# The scroll pane. AccessKit gives AT-SPI a scroll view as a panel, and of what it has scrolled out
# of view shows only the nearest item either side, as browsers do: the one a screen reader moves
# on to next, and asks to have scrolled into view
PANEL = 39
COMPONENT, WINDOW_COORDS = "org.a11y.atspi.Component", "1"
pane = find(PANEL)
check(pane is not None, "the scroll pane is there, as a panel")
extents = lambda at: A("call", *at, COMPONENT, "GetExtents", "u", WINDOW_COORDS)[0]
px, py, pw, ph = extents(pane["at"])
shown = [n["name"] for n in nodes if n["role"] == BUTTON and n["name"].startswith("Row ")]
check(shown and shown[-1] != "Row 14", f"it shows the rows in view and the next one: {shown}")
row = find(BUTTON, shown[-1])["at"]
y = extents(row)[1]
check(y + 1 >= py + ph, f"{shown[-1]} is out of view below the pane: {y} against {py}+{ph}")
A("call", *row, COMPONENT, "ScrollTo", "u", "0")
time.sleep(0.5)
_, y, _, h = extents(row)
check(py <= y and y + h <= py + ph, f"a screen reader scrolled it into view, and sees where it went: {y}+{h} in {py}+{ph}")
nodes.clear(); walk(*app)
following = [n["name"] for n in nodes if n["role"] == BUTTON and n["name"].startswith("Row ")]
check(following[-1] != shown[-1], f"and the next row on is there to move to: {following}")

# Toggles: a check box and a radio button, each saying what it is and whether it's on
CHECKED = 4
def by_name(name):
    return next((n for n in nodes if n["name"] == name), None)
tick, pick = by_name("Tick me"), by_name("Pick me")
CHECK_BOX, RADIO_BUTTON = 7, 44
check(tick and tick["role"] == CHECK_BOX and tick["state"] >> CHECKED & 1, "a ticked check box, checked")
check(pick and pick["role"] == RADIO_BUTTON and not pick["state"] >> CHECKED & 1, "a radio button, not checked")

# The text area, read a line at a time; the slider and progress bar, as values
LINE = 3
def text_of(n):
    try:
        return A("call", *n["at"], TEXT, "GetText", "ii", "0", "-1")[0]
    except RuntimeError:
        return None
area = next((n for n in nodes if text_of(n) == "one\ntwo\nthree"), None)
check(area is not None, "the text area's text, lines and all")
if area:
    line = A("call", *area["at"], TEXT, "GetStringAtOffset", "iu", "5", str(LINE))
    check(line[0].rstrip("\n") == "two", f"read a line at a time: {line}")
VALUE = "org.a11y.atspi.Value"
def value_of(n):
    try:
        return A("get-property", *n["at"], VALUE, "CurrentValue")
    except RuntimeError:
        return None
valued = [(n, value_of(n)) for n in nodes]
slider = next((n for n, v in valued if v == 30), None)
check(slider is not None, f"the slider's value: {[v for n, v in valued if v is not None]}")
check(any(v == 0.5 for n, v in valued), "the progress bar's")
if slider:
    A("set-property", *slider["at"], VALUE, "CurrentValue", "d", "70")
    time.sleep(0.4)
    check(value_of(slider) == 70, f"a screen reader sets the slider: {value_of(slider)}")

# Tabs and a navigation list: their roles, and which one's selected
SELECTED = 23
PAGE_TAB, PAGE_TAB_LIST, LIST_ITEM, LIST_BOX = 37, 38, 32, 98   # AT-SPI roles
def role_name(n):
    return {PAGE_TAB: "page tab", PAGE_TAB_LIST: "page tab list", LIST_ITEM: "list item", LIST_BOX: "list box"}.get(n["role"], n["role"])
alpha, beta = by_name("Alpha"), by_name("Beta")
check(alpha and role_name(alpha) == "page tab" and alpha["state"] >> SELECTED & 1, "the selected tab, a page tab, selected")
check(beta and role_name(beta) == "page tab" and not beta["state"] >> SELECTED & 1, "the other tab, not")
check(any(role_name(n) == "page tab list" for n in nodes), "the tabs in a page tab list")
check(by_name("Beta's page") is None, "only the selected tab's page is there")
home, away = by_name("Home"), by_name("Away")
check(home and role_name(home) == "list item" and home["state"] >> SELECTED & 1, "the navigation list's first entry, a list item, selected")
check(away and not away["state"] >> SELECTED & 1, "the other, not")
check(any(role_name(n) == "list box" for n in nodes), "the entries in a list box")

print(f"{len(failures)} failed")
sys.exit(1 if failures else 0)
