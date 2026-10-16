#!/usr/bin/env python3
"""
Writes web/stubs.c: a stand-in, for the browser, for each AccessKit and litehtml function Mayfair's
D code calls. Run it from anywhere when the code starts calling one more and the browser build
says so (an undefined symbol when linking).

Neither library is built for WebAssembly (see vendor/build-wasm.sh), and the code that calls them
never runs there, but the linker wants every function the code names. Each stand-in's signature
is copied from the real header, which stubs.c includes, so the compiler checks it.
"""
import pathlib
import re

here = pathlib.Path(__file__).resolve().parent
mayfair = here.parent
headers = [mayfair / "vendor/accesskit/include/accesskit.h", mayfair / "bindings/litehtml_shim.h"]

# The functions the D code calls
used = set()
for d in (mayfair / "source").rglob("*.d"):
    used |= set(re.findall(r"\b((?:accesskit|lh)_\w+)\s*\(", d.read_text()))

# Their declarations, from the headers, comments out and all on one line
declared = {}
for h in headers:
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", h.read_text(), flags=re.S)
    for m in re.finditer(r"([A-Za-z_][\w\s\*]*?)\b((?:accesskit|lh)_\w+)\s*\(([^;{()]*)\)\s*;", " ".join(text.split())):
        ret, name, args = m.group(1).strip(), m.group(2), m.group(3)
        ret = re.sub(r"^(?:extern|LH_API|ACCESSKIT_API)\s+", "", ret)
        declared[name] = (ret, args)

lines = [
    "/*",
    "    Stand-ins, for the browser, for the AccessKit and litehtml functions Mayfair's code calls.",
    "    Written by make-stubs.py: run it again, rather than editing this, when the code calls another.",
    "*/",
    "#include <stdbool.h>",
    "#include <stddef.h>",
    "#include <stdint.h>",
    '#include "accesskit.h"',
    '#include "litehtml_shim.h"',
    "",
]
for name in sorted(used):
    if name not in declared or re.match(r"accesskit_(unix|windows|macos)_", name):
        continue  # a type or a macro; or for another platform, which the header hides off it
    ret, args = declared[name]
    body = "" if ret == "void" else f" static {ret} none; return none;"  # zero, whatever the type
    lines.append(f"{ret} {name}({args}) {{{body} }}")
(here / "stubs.c").write_text("\n".join(lines) + "\n")
print(f"{len(lines) - 10} stand-ins")
