#!/usr/bin/env bash
#
# Writes the third-party notices: what an app built with Mayfair has to ship, because everything
# is linked into it statically and the licences ask for their text to go with the binary.
#
#   tools/notices.sh      writes mayfair/THIRD_PARTY_NOTICES.md and
#                         mayfair-terminal/THIRD_PARTY_NOTICES.md
#
# Run it again when a submodule, the pinned wgpu-native or AccessKit, or mayfair-terminal's
# Cargo.lock changes. It needs cargo and cargo-about (cargo install cargo-about); it clones
# wgpu-native and accesskit-c at the commits vendor/build.sh pins, into a temporary directory.
set -euo pipefail
cd "$(dirname "$0")/.."
MAYFAIR=$PWD
TERMINAL=$MAYFAIR/../mayfair-terminal

command -v cargo-about >/dev/null || { echo "needs cargo-about: cargo install cargo-about" >&2; exit 1; }

pinned() { sed -n "s/^$1=\([^ ]*\).*/\1/p" vendor/build.sh; }
WGPU_VERSION=$(pinned WGPU_VERSION) WGPU_COMMIT=$(pinned WGPU_COMMIT)
ACCESSKIT_VERSION=$(pinned ACCESSKIT_VERSION) ACCESSKIT_COMMIT=$(pinned ACCESSKIT_COMMIT)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# cargo-about's settings: the platforms Mayfair builds for, only what ends up in the binary (no
# dev or build dependencies), and the licences that are fine. A crate under any other licence
# stops this, so it gets looked at rather than slipping in.
cat > "$work/about.toml" <<'EOF'
targets = [
    "x86_64-unknown-linux-gnu",
    "aarch64-unknown-linux-gnu",
    "x86_64-unknown-freebsd",
    "aarch64-apple-darwin",
]
ignore-dev-dependencies = true
ignore-build-dependencies = true
accepted = [
    "Apache-2.0",
    "Apache-2.0 WITH LLVM-exception",
    "MIT",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "ISC",
    "Zlib",
    "BSL-1.0",
    "CC0-1.0",
    "0BSD",
    "Unicode-3.0",
    "Unicode-DFS-2016",
]
EOF

# One section per distinct licence text, with the crates under it.
cat > "$work/about.hbs" <<'EOF'
{{#each licenses}}
#### {{{name}}}

Used by: {{#each used_by}}{{crate.name}} {{crate.version}}{{#unless @last}}, {{/unless}}{{/each}}

```text
{{{text}}}
```
{{/each}}
EOF

rust_notices() # <cargo manifest>
{
    cargo about generate --config "$work/about.toml" --manifest-path "$1" --locked "$work/about.hbs" 2>"$work/about.log" \
        || { cat "$work/about.log" >&2; exit 1; }
}

clone() # <url> <commit> <directory>
{
    git init -q "$3"
    git -C "$3" fetch -q --depth 1 "$1" "$2"
    git -C "$3" checkout -q FETCH_HEAD
}

licence() # <heading> <what it is> <file>
{
    printf '### %s\n\n%s\n\n```text\n%s\n```\n\n' "$1" "$2" "$(cat "$3")"
}

echo "Cloning wgpu-native $WGPU_VERSION and accesskit-c $ACCESSKIT_VERSION"
clone https://github.com/gfx-rs/wgpu-native.git "$WGPU_COMMIT" "$work/wgpu-native"
clone https://github.com/AccessKit/accesskit-c.git "$ACCESSKIT_COMMIT" "$work/accesskit-c"

echo "Writing THIRD_PARTY_NOTICES.md"
{
    cat <<'EOF'
# Third-party notices

Mayfair is under the MIT licence (see LICENSE at the top of the repository). It links the
libraries below into every app built with it, statically, so an app that ships has to ship
their notices too: this file, alongside the app or in its About box, does that.

Portions of this software are copyright © The FreeType Project (https://freetype.org).
All rights reserved.

<!-- Written by tools/notices.sh: edit that, not this. -->

## C and C++ libraries

EOF
    licence ThorVG "Vector drawing, on the GPU through WebGPU. MIT." vendor/thorvg/LICENSE
    licence Yoga "Flexbox layout. MIT." vendor/yoga/LICENSE
    licence FreeType "Font loading and rasterising. The FreeType Licence (FTL); its credit is above." vendor/freetype/docs/FTL.TXT
    licence HarfBuzz "Text shaping. MIT (\"Old MIT\")." vendor/harfbuzz/COPYING
    licence libunibreak "Line and word breaking. zlib." vendor/libunibreak/LICENCE
    licence SheenBidi "The Unicode bidirectional algorithm. Apache-2.0." vendor/sheenbidi/LICENSE
    licence litehtml "HTML and CSS layout, for LiteWebView. BSD-3-Clause." vendor/litehtml/LICENSE
    licence Gumbo "The HTML parser inside litehtml. Apache-2.0." vendor/litehtml/src/gumbo/LICENSE
    cat <<'EOF'
### SDL3

Windows, input and events. zlib: no notice is required in a binary, but thanks all the same.

### D runtime and standard library (druntime, Phobos)

Boost Software License 1.0, which asks for no notice in a binary.

## Fonts

Built into the library, as the fallback when the desktop has no font of its own.

EOF
    licence "IBM Plex Sans" "SIL Open Font License 1.1." fonts/LICENSE-IBMPlexSans.txt
    licence "DejaVu Sans" "The Bitstream Vera licence, with DejaVu's changes in the public domain." fonts/LICENSE-DejaVu.txt
    printf '## Rust libraries\n\n'
    printf '### wgpu-native %s\n\nWebGPU, on Vulkan, Metal or OpenGL. MIT or Apache-2.0, and the crates inside it:\n' "$WGPU_VERSION"
    rust_notices "$work/wgpu-native/Cargo.toml"
    printf '\n### AccessKit %s\n\nAccessibility: what screen readers are told. MIT or Apache-2.0, and the crates inside it:\n' "$ACCESSKIT_VERSION"
    rust_notices "$work/accesskit-c/Cargo.toml"
} > THIRD_PARTY_NOTICES.md

echo "Writing ../mayfair-terminal/THIRD_PARTY_NOTICES.md"
{
    cat <<'EOF'
# Third-party notices

mayfair-terminal is under the MIT licence (see LICENSE at the top of the repository). As well
as Mayfair's own (mayfair/THIRD_PARTY_NOTICES.md), an app that uses it links the Rust crates
below, statically, and has to ship their notices too.

<!-- Written by mayfair/tools/notices.sh: edit that, not this. -->

## alacritty_terminal, and the crates inside it

EOF
    rust_notices "$TERMINAL/native/Cargo.toml"
} > "$TERMINAL/THIRD_PARTY_NOTICES.md"
