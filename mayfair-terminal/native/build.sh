#!/usr/bin/env sh
#
# Builds the terminal's native half: native/src/lib.rs, a C API on alacritty_terminal, as a static
# library. dub runs this before every build (preGenerateCommands in dub.json); after the first,
# cargo only checks it's up to date.
#
#   native/src/            The C API, in Rust
#   native/include/        Its header, which the D bindings read
#   native/Cargo.lock      Every crate pinned, so a build is the same build anywhere
#   native/target/         cargo's output (git-ignored)
#   native/build/          The library as linked, with its runtime reconciled (git-ignored)
#
# Unlike Mayfair itself, which downloads its Rust libraries ready built, this needs a Rust
# toolchain (cargo, 1.85 or later): alacritty_terminal has no C API of its own to download, so
# this is it. The first build downloads the crates.
#
# Takes Mayfair's package directory, which dub passes in, for the Rust libraries it links.
set -eu
cd "$(dirname "$0")"
MAYFAIR="${1:?usage: build.sh <mayfair package directory>}"

if ! command -v cargo >/dev/null 2>&1; then
    echo "mayfair-terminal needs Rust's cargo to build its native half: see https://rustup.rs" >&2
    exit 1
fi

cargo build --release --locked --quiet

# Mayfair links two Rust libraries already, wgpu-native and AccessKit, and this is a third. Each
# carries its own copy of the Rust runtime, and a few dozen of its symbols are plain C names --
# compiler-rt's arithmetic helpers, mostly -- which then are defined twice, and the link fails.
# Mayfair's vendor/build.sh explains this and does the same for AccessKit: this library's copies of
# exactly the symbols the others define too are made weak, in a copy of it, and the linker takes
# wgpu's. Mayfair's build makes those libraries, so if it hasn't run yet, it runs now.
WGPU="$MAYFAIR/vendor/wgpu-native/lib/libwgpu_native.a"
ACCESSKIT="$MAYFAIR/vendor/accesskit/lib/libaccesskit.a"
if [ ! -f "$WGPU" ] || [ ! -f "$ACCESSKIT" ]; then
    "$MAYFAIR/vendor/build.sh"
fi

LIB=target/release/libmayfair_terminal.a
# By size and time rather than contents: wgpu's library is tens of megabytes to read every build
STAMP="$(stat -c '%s %Y' "$LIB" "$WGPU" "$ACCESSKIT")"
if [ "$(cat build/stamp 2>/dev/null)" != "$STAMP" ]; then
    echo "Reconciling the terminal's Rust runtime with wgpu-native's"
    rm -rf build
    mkdir -p build
    strong() { nm -g --defined-only "$1" 2>/dev/null | awk 'NF == 3 && $2 ~ /^[TDBR]$/ { print $3 }' | LC_ALL=C sort -u; }
    strong "$LIB" > build/terminal.syms
    { strong "$WGPU"; strong "$ACCESSKIT"; } | LC_ALL=C sort -u > build/others.syms
    LC_ALL=C comm -12 build/terminal.syms build/others.syms > build/shared.syms
    objcopy --weaken-symbols=build/shared.syms "$LIB" build/libmayfair_terminal.a
    echo "$STAMP" > build/stamp
fi
