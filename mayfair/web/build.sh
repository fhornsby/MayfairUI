#!/usr/bin/env sh
#
# Builds a Mayfair app for the browser, as WebAssembly: a page, its script and its .wasm, in one
# folder to serve as it is.
#
#   mayfair/web/build.sh -o out/ [-I dir] [-J dir] [-p host-path@page-path] app.d [more.d ...]
#
#   -o   the folder to write index.html, index.js, index.wasm and index.data to
#   -I   a folder of the app's D modules, for imports, as dub's importPaths
#   -J   a folder for import("file"), as dub's stringImportPaths
#   -p   files for the page to have at run time, at a path of its own: an icon theme, say, as
#        -p /usr/share/icons/Adwaita@/usr/share/icons/Adwaita
#
# Needs LDC 1.43 or later, with its Emscripten addon, and the Emscripten SDK, both on the PATH:
#
#   source ~/dlang/ldc-1.43.0/activate
#   source ~/emsdk/emsdk_env.sh
#
# The page needs a browser with WebAssembly's newer exceptions (exnref), which D's use: Chrome 137
# or Firefox 131 on.
#
# What's different in the browser: ThorVG's CPU renderer only, for now; no LiteWebView, no
# accessibility, no file dialogs and no threads; and the app's main loop is the browser's (see
# App.run). Everything else is the same code as on Linux.
set -eu

out=
imports=
strings=
preloads=
while getopts o:I:J:p: opt; do
    case $opt in
        o) out=$OPTARG ;;
        I) imports="$imports -I$OPTARG" ;;
        J) strings="$strings -J$OPTARG" ;;
        p) preloads="$preloads -Xcc=--preload-file -Xcc=$OPTARG" ;;
        *) exit 1 ;;
    esac
done
shift $((OPTIND - 1))
if [ -z "$out" ] || [ $# -eq 0 ]; then
    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
fi
for tool in ldc2 emcc; do
    if ! command -v $tool > /dev/null; then
        echo "$tool isn't on the PATH: see the top of $0" >&2
        exit 1
    fi
done

here=$(cd "$(dirname "$0")" && pwd)
mayfair=$(dirname "$here")
vendor=$mayfair/vendor
built=$vendor/build-wasm
"$vendor/build-wasm.sh"

# sdl-d, from dub's cache, as dub would fetch it for a Linux build
sdl=$(ls -d "$HOME"/.dub/packages/sdl-d/*/sdl-d/source 2>/dev/null | tail -n 1)
if [ -z "$sdl" ]; then
    echo "sdl-d isn't in dub's cache: build Mayfair for Linux once (dub build) to fetch it" >&2
    exit 1
fi

# The C headers ImportC reads, as dub.json's cImportPaths
cimports="-P-I$vendor/thorvg/src/bindings/capi -P-I$vendor/wgpu-native/include -P-I$vendor/yoga
    -P-I$vendor/freetype/include -P-I$vendor/harfbuzz/src -P-I$vendor/libunibreak/src
    -P-I$vendor/accesskit/include -P-I$vendor/sheenbidi/Headers -P-I$mayfair/bindings"

objects=$here/build/obj
rm -rf "$objects"
mkdir -p "$objects" "$out"

# Mayfair, less the WebGPU renderer, and the C bindings, less wgpu-native's; then the stand-ins for
# what isn't built for the browser
echo "Compiling Mayfair"
# shellcheck disable=SC2046,SC2086 # the lists are words
ldc2 -mtriple=wasm32-unknown-emscripten -O -c -oq -od="$objects" \
    -I"$mayfair/source" -I"$mayfair/bindings" -I"$sdl" -J"$mayfair/fonts" -J"$mayfair/themes" $cimports \
    $(find "$mayfair/source" -name '*.d' -not -path '*/renderers/webgpu/*') \
    $(ls "$mayfair"/bindings/*.c | grep -v webgpu_c) \
    $(find "$sdl" -name '*.d') 2>&1 | grep -v "ALLOW_MEMORY_GROWTH" || true
emcc -O2 -c -I"$vendor/accesskit/include" -I"$mayfair/bindings" "$here/stubs.c" -o "$objects/stubs.o"

# The app, linked with all of it. SDL is Emscripten's own; libc++ is for ThorVG and Yoga, which
# are C++, built without exceptions.
echo "Linking"
# shellcheck disable=SC2086
ldc2 -mtriple=wasm32-unknown-emscripten -O -oq -od="$here/build/app" \
    -I"$mayfair/source" -I"$mayfair/bindings" -I"$sdl" -J"$mayfair/fonts" -J"$mayfair/themes" $cimports \
    $imports $strings "$@" "$objects"/*.o \
    "$built/thorvg/src/libthorvg-1.a" "$built/yoga/libyogacore.a" "$built/harfbuzz/src/libharfbuzz.a" \
    "$built/freetype/libfreetype.a" "$built/libunibreak/libunibreak.a" "$built/sheenbidi/libsheenbidi.a" \
    -Xcc=-sUSE_SDL=3 -Xcc=-lc++ -Xcc=-lc++abi -Xcc=--shell-file -Xcc="$here/shell.html" $preloads \
    -of="$out/index.html" 2>&1 | grep -v "ALLOW_MEMORY_GROWTH\|linker' input unused" || true
test -f "$out/index.wasm"
echo "Built $out/index.html"
