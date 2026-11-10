#!/usr/bin/env sh
#
# Builds Mayfair's native dependencies for the browser, as WebAssembly with Emscripten, into
# vendor/build-wasm/. The same sources as build.sh, less what a browser has no use for or can't
# build:
#
#   wgpu-native   the browser has WebGPU of its own
#   AccessKit     no browser adapter
#   litehtml      uses C++ exceptions, which can't be linked alongside D's in WebAssembly (LDC's
#                 Emscripten support takes D's or C++'s, not both), so no LiteWebView in the browser
#
# Everything C++ is built with -fno-exceptions for the same reason. ThorVG has only its CPU engine
# for now, and no threads: D's WebAssembly runtime is single-threaded.
#
# Needs the Emscripten SDK on the PATH: source ~/emsdk/emsdk_env.sh
set -eu
cd "$(dirname "$0")"

if ! command -v emcc > /dev/null; then
    echo "emcc isn't on the PATH. Run: source ~/emsdk/emsdk_env.sh" >&2
    exit 1
fi

OUT=build-wasm
mkdir -p $OUT
FLAGS="-O2 -fno-exceptions"

# Meson's description of the target. pkg-config only ever finds our own .pc files, never the
# machine's, which are for Linux.
cat > $OUT/emscripten.ini <<EOF
[binaries]
c = 'emcc'
cpp = 'em++'
ar = 'emar'
pkg-config = 'pkg-config'

[properties]
pkg_config_libdir = '$(pwd)/$OUT/pkgconfig'

[built-in options]
c_args = ['-O2', '-fno-exceptions']
cpp_args = ['-O2', '-fno-exceptions']

[host_machine]
system = 'emscripten'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'
EOF

# ThorVG, patched as for Linux (build.sh prepares the source), with only the CPU engine
if [ ! -f build/thorvg-src.stamp ]; then
    echo "Run vendor/build.sh once first: it prepares ThorVG's patched source" >&2
    exit 1
fi
THORVG_OPTIONS="--buildtype=release -Ddefault_library=static -Dengines=cpu -Dbindings=capi -Dthreads=false
    -Dloaders=svg,ttf,lottie,png,jpg,webp -Dstatic=true -Dextra=lottie_exp"
if [ ! -f $OUT/thorvg/build.ninja ] || [ "$(cat $OUT/thorvg/options.stamp 2>/dev/null)" != "$THORVG_OPTIONS" ]; then
    rm -rf $OUT/thorvg
    # shellcheck disable=SC2086 # the options are words
    meson setup $OUT/thorvg build/thorvg-src --cross-file $OUT/emscripten.ini $THORVG_OPTIONS
    echo "$THORVG_OPTIONS" > $OUT/thorvg/options.stamp
fi
ninja -C $OUT/thorvg

# Yoga, compiled straight: its CMake defaults add -fexceptions after any flags given, and its code
# is written to build without them (it checks __cpp_exceptions, and aborts where it'd throw)
YOGA_STAMP="$(git -C yoga rev-parse HEAD)"
if [ "$(cat $OUT/yoga/stamp 2>/dev/null)" != "$YOGA_STAMP" ]; then
    echo "Building Yoga"
    rm -rf $OUT/yoga
    mkdir -p $OUT/yoga
    find yoga/yoga -name '*.cpp' | while read -r c; do
        o=$(echo "$c" | sed 's|^yoga/yoga/||; s|/|_|g; s|\.cpp$|.o|')
        em++ -std=c++20 $FLAGS -Iyoga -c "$c" -o "$OUT/yoga/$o"
    done
    emar rcs $OUT/yoga/libyogacore.a $OUT/yoga/*.o
    echo "$YOGA_STAMP" > $OUT/yoga/stamp
fi

# FreeType, as build.sh has it: Harmony, made again if it was built with ClearType-style rendering
if [ -f $OUT/freetype/CMakeCache.txt ] && grep -q FT_CONFIG_OPTION_SUBPIXEL_RENDERING $OUT/freetype/CMakeCache.txt; then
    rm -rf $OUT/freetype
fi
if [ ! -f $OUT/freetype/build.ninja ]; then
    emcmake cmake -S freetype -B $OUT/freetype -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="$FLAGS" \
        -DBUILD_SHARED_LIBS=OFF \
        -DFT_DISABLE_ZLIB=TRUE -DFT_DISABLE_BZIP2=TRUE -DFT_DISABLE_PNG=TRUE \
        -DFT_DISABLE_HARFBUZZ=TRUE -DFT_DISABLE_BROTLI=TRUE
fi
ninja -C $OUT/freetype

mkdir -p $OUT/pkgconfig
cat > $OUT/pkgconfig/freetype2.pc <<EOF
prefix=$(pwd)
libdir=\${prefix}/$OUT/freetype
includedir=\${prefix}/freetype/include

Name: FreeType 2
Description: A free, high-quality, and portable font engine.
Version: 26.6.20
Libs: -L\${libdir} -lfreetype
Cflags: -I\${includedir}
EOF

# HarfBuzz, as build.sh has it
if [ ! -f $OUT/harfbuzz/build.ninja ]; then
    meson setup $OUT/harfbuzz harfbuzz --cross-file $OUT/emscripten.ini \
        --buildtype=release -Ddefault_library=static \
        -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
        -Dicu=disabled -Dgraphite2=disabled -Dchafa=disabled -Dpng=disabled -Dzlib=disabled \
        -Dsubset=disabled -Draster=disabled -Dvector=disabled -Dgpu=disabled \
        -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dintrospection=disabled \
        -Dbenchmark=disabled
fi
ninja -C $OUT/harfbuzz

# libunibreak and SheenBidi, compiled straight, as build.sh does
UNIBREAK_SRCS=$(awk '
    /^libunibreak_la_SOURCES[ \t]*=/ { inlist = 1; sub(/^[^=]*=/, "") }
    inlist {
        continues = /\\[ \t]*$/
        gsub(/\\[ \t]*$/, "")
        n = split($0, parts, /[ \t]+/)
        for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
        if (!continues) exit
    }
' libunibreak/src/Makefile.am)
UNIBREAK_STAMP="$(git -C libunibreak rev-parse HEAD) $(echo "$UNIBREAK_SRCS" | sha256sum)"
if [ "$(cat $OUT/libunibreak/stamp 2>/dev/null)" != "$UNIBREAK_STAMP" ]; then
    echo "Building libunibreak"
    rm -rf $OUT/libunibreak
    mkdir -p $OUT/libunibreak
    for c in $UNIBREAK_SRCS; do
        emcc -O2 -c "libunibreak/src/$c" -o "$OUT/libunibreak/${c%.c}.o"
    done
    emar rcs $OUT/libunibreak/libunibreak.a $OUT/libunibreak/*.o
    echo "$UNIBREAK_STAMP" > $OUT/libunibreak/stamp
fi

SHEENBIDI_STAMP="$(git -C sheenbidi rev-parse HEAD)"
if [ "$(cat $OUT/sheenbidi/stamp 2>/dev/null)" != "$SHEENBIDI_STAMP" ]; then
    echo "Building SheenBidi"
    rm -rf $OUT/sheenbidi
    mkdir -p $OUT/sheenbidi
    emcc -O2 -DSB_CONFIG_UNITY -Isheenbidi/Headers -Isheenbidi/Source \
        -c sheenbidi/Source/SheenBidi.c -o $OUT/sheenbidi/SheenBidi.o
    emar rcs $OUT/sheenbidi/libsheenbidi.a $OUT/sheenbidi/SheenBidi.o
    echo "$SHEENBIDI_STAMP" > $OUT/sheenbidi/stamp
fi
