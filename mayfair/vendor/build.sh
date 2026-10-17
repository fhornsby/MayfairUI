#!/usr/bin/env sh
#
# Builds Mayfair's native dependencies. dub runs this before every build (preGenerateCommands in
# dub.json). The first run downloads wgpu-native and compiles ThorVG, which takes a minute or two;
# after that it only checks everything is up to date.
#
#   vendor/thorvg/          ThorVG source, a git submodule pinned to a commit. Never modified.
#   vendor/patches/thorvg/  Mayfair's changes to ThorVG, applied to a copy in vendor/build/thorvg-src
#   vendor/yoga/            Yoga source, a git submodule pinned to a release. Never modified.
#   vendor/freetype/        FreeType source, a git submodule pinned to a release. Never modified.
#   vendor/harfbuzz/        HarfBuzz source, a git submodule pinned to a release. Never modified.
#   vendor/libunibreak/     libunibreak source, a git submodule pinned to a release. Never modified.
#   vendor/sheenbidi/       SheenBidi source, a git submodule pinned to a release. Never modified.
#   vendor/litehtml/        litehtml source, a git submodule pinned to a release. Never modified.
#   vendor/wgpu-native/     wgpu-native prebuilt release, downloaded here (git-ignored)
#   vendor/accesskit/       AccessKit's C bindings, prebuilt release, downloaded here (git-ignored)
#   vendor/build/           Patched ThorVG source and build output (git-ignored). Delete it to rebuild
#                           with new options.
#
# Only Linux x86_64 for now.
set -eu
cd "$(dirname "$0")"

WGPU_VERSION=v27.0.4.1 # the version ThorVG's wg engine is written against (see its README)
WGPU_SHA256=9385b8a9e4e6f0b00264757577511097104fedf6db7819aa3e34a106c3dc0a42
WGPU_ZIP=wgpu-linux-x86_64-release.zip

# AccessKit is Rust, like wgpu-native, and comes the same way: a release with static libraries
# already built, so building Mayfair needs no Rust toolchain. The zip has every platform's in it;
# only the header and this platform's static library are kept.
ACCESSKIT_VERSION=0.23.0
ACCESSKIT_SHA256=dd2f84f51bea0bcf01270a7505b2b85a7945d40d703b6f479d64963accb4b95d
ACCESSKIT_ZIP=accesskit-c-$ACCESSKIT_VERSION.zip

for m in thorvg/meson.build yoga/yoga/Yoga.h freetype/include/ft2build.h litehtml/include/litehtml.h \
         harfbuzz/src/hb.h libunibreak/src/linebreak.h sheenbidi/Headers/SheenBidi/SheenBidi.h; do
    if [ ! -f "$m" ]; then
        echo "vendor/${m%%/*} is empty. Run: git submodule update --init" >&2
        exit 1
    fi
done

if [ "$(cat wgpu-native/version 2>/dev/null)" != "$WGPU_VERSION" ]; then
    echo "Downloading wgpu-native $WGPU_VERSION"
    rm -rf wgpu-native
    mkdir -p wgpu-native
    curl -sSfL -o wgpu-native/$WGPU_ZIP \
        "https://github.com/gfx-rs/wgpu-native/releases/download/$WGPU_VERSION/$WGPU_ZIP"
    echo "$WGPU_SHA256  wgpu-native/$WGPU_ZIP" | sha256sum -c --quiet
    unzip -q wgpu-native/$WGPU_ZIP -d wgpu-native
    rm wgpu-native/$WGPU_ZIP

    # The release has no pkg-config file, which ThorVG's meson build looks for
    mkdir -p wgpu-native/lib/pkgconfig
    cat > wgpu-native/lib/pkgconfig/wgpu_native.pc <<EOF
prefix=$(pwd)/wgpu-native
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: wgpu_native
Description: wgpu-native prebuilt release
Version: ${WGPU_VERSION#v}
Libs: -L\${libdir} -lwgpu_native
Cflags: -I\${includedir}
EOF
    echo "$WGPU_VERSION" > wgpu-native/version
fi

if [ "$(cat accesskit/version 2>/dev/null)" != "$ACCESSKIT_VERSION" ]; then
    echo "Downloading AccessKit $ACCESSKIT_VERSION"
    rm -rf accesskit
    mkdir -p accesskit
    curl -sSfL -o accesskit/$ACCESSKIT_ZIP \
        "https://github.com/AccessKit/accesskit-c/releases/download/$ACCESSKIT_VERSION/$ACCESSKIT_ZIP"
    echo "$ACCESSKIT_SHA256  accesskit/$ACCESSKIT_ZIP" | sha256sum -c --quiet
    top=accesskit-c-$ACCESSKIT_VERSION
    unzip -q accesskit/$ACCESSKIT_ZIP -d accesskit \
        "$top/include/*" "$top/lib/linux/x86_64/static/*" "$top/LICENSE-*"
    mv accesskit/$top/include accesskit/include
    mv accesskit/$top/lib/linux/x86_64/static accesskit/lib
    mv accesskit/$top/LICENSE-* accesskit/
    rm -rf accesskit/$top accesskit/$ACCESSKIT_ZIP
    echo "$ACCESSKIT_VERSION" > accesskit/version
fi

# wgpu-native and AccessKit are both Rust static libraries, and each carries its own copy of the
# Rust runtime. Most of it has per-build hashes in its symbol names and so can't clash, but a few
# dozen symbols are plain C names -- compiler-rt's arithmetic helpers and rust_eh_personality, the
# unwinder hook -- which then are defined twice, and the link fails. They're all ABI-stable, so any
# one copy serves both libraries. Rather than let the linker accept duplicates in general, which
# would hide a real clash, AccessKit's copies of exactly those symbols are made weak, in a copy of
# its library, and the linker takes wgpu's. The list is worked out from the two archives each time
# either changes, so it stays right across upgrades.
ACCESSKIT_STAMP="$ACCESSKIT_VERSION $WGPU_VERSION"
if [ "$(cat build/accesskit/stamp 2>/dev/null)" != "$ACCESSKIT_STAMP" ]; then
    echo "Reconciling AccessKit's Rust runtime with wgpu-native's"
    rm -rf build/accesskit
    mkdir -p build/accesskit
    strong() { nm -g --defined-only "$1" 2>/dev/null | awk 'NF == 3 && $2 ~ /^[TDBR]$/ { print $3 }' | LC_ALL=C sort -u; }
    strong accesskit/lib/libaccesskit.a > build/accesskit/accesskit.syms
    strong wgpu-native/lib/libwgpu_native.a > build/accesskit/wgpu.syms
    LC_ALL=C comm -12 build/accesskit/accesskit.syms build/accesskit/wgpu.syms > build/accesskit/shared.syms
    objcopy --weaken-symbols=build/accesskit/shared.syms accesskit/lib/libaccesskit.a build/accesskit/libaccesskit.a
    echo "$ACCESSKIT_STAMP" > build/accesskit/stamp
fi

# Copy ThorVG's source out of the submodule and apply our patches, redoing it (and the build) whenever
# the pinned commit or a patch changes
THORVG_STAMP="$(git -C thorvg rev-parse HEAD) $(cat patches/thorvg/*.patch | sha256sum)"
if [ "$(cat build/thorvg-src.stamp 2>/dev/null)" != "$THORVG_STAMP" ]; then
    echo "Preparing patched ThorVG source"
    rm -rf build/thorvg-src build/thorvg
    mkdir -p build/thorvg-src
    git -C thorvg archive HEAD | tar -x -C build/thorvg-src
    for p in patches/thorvg/*.patch; do
        patch -s -p1 -d build/thorvg-src < "$p"
    done
    echo "$THORVG_STAMP" > build/thorvg-src.stamp
fi

# The image loaders are ThorVG's own copies -- LodePNG (zlib licence), jpgd (public domain) and
# libwebp's decoder (BSD) -- which -Dstatic=true picks over the system's libpng, libjpeg and libwebp,
# so an app has nothing more to ship or find. Lottie brings RapidJSON (MIT) and, for expressions,
# JerryScript (Apache-2.0). The options are in the stamp, so changing them here reconfigures.
#
# Three engines: wg for WebGPU, the default; gl for machines whose GPU does OpenGL but not Vulkan, a
# VM on virgl say; cpu for the rest (see chooseRenderers in mayfair.windowing.app). gl is built for
# OpenGL ES, which it reaches through EGL and libGLESv2.so.2 -- what SDL uses on Wayland, and what
# every Mesa install has. Its desktop-GL variant looks for libGL.so, which only the -dev package
# provides, and through GLX. Both are loaded at run time, so a machine without them still starts.
THORVG_OPTIONS="--buildtype=release -Ddefault_library=static -Dengines=cpu,wg,gl -Dbindings=capi
    -Dloaders=svg,ttf,lottie,png,jpg,webp -Dstatic=true -Dextra=lottie_exp,opengl_es"
if [ ! -f build/thorvg/build.ninja ] || [ "$(cat build/thorvg/options.stamp 2>/dev/null)" != "$THORVG_OPTIONS" ]; then
    rm -rf build/thorvg
    # shellcheck disable=SC2086 # the options are words
    PKG_CONFIG_PATH="$(pwd)/wgpu-native/lib/pkgconfig" meson setup build/thorvg build/thorvg-src $THORVG_OPTIONS
    echo "$THORVG_OPTIONS" > build/thorvg/options.stamp
fi
ninja -C build/thorvg

# Yoga: only its library folder, as the top-level CMake project also builds tests and downloads googletest
if [ ! -f build/yoga/build.ninja ]; then
    cmake -S yoga/yoga -B build/yoga -G Ninja -DCMAKE_BUILD_TYPE=Release
fi
ninja -C build/yoga

# The text stack. Four libraries, each doing one job that the others don't:
#   FreeType     opens a font file and turns a glyph id into an outline, with metrics and hinting
#   HarfBuzz     turns text + font into glyph ids and positions, honouring GSUB/GPOS
#   libunibreak  says where a line is allowed to break (UAX #14), which neither of the others does
#   SheenBidi    puts mixed left-to-right and right-to-left text in the order it's shown (UAX #9),
#                which HarfBuzz needs done before it's handed each run

# FreeType, with everything optional off: Mayfair hands it font bytes it has already read, so it
# needs no compressed-font or bitmap-image support. HarfBuzz is off too, which breaks the FreeType
# <-> HarfBuzz dependency cycle -- it only sharpens autohinting for complex scripts, and HarfBuzz
# below is built against this FreeType rather than the other way round.
if [ ! -f build/freetype/build.ninja ]; then
    cmake -S freetype -B build/freetype -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DFT_DISABLE_ZLIB=TRUE -DFT_DISABLE_BZIP2=TRUE -DFT_DISABLE_PNG=TRUE \
        -DFT_DISABLE_HARFBUZZ=TRUE -DFT_DISABLE_BROTLI=TRUE
fi
ninja -C build/freetype

# HarfBuzz looks FreeType up through pkg-config, and has to find the one just built rather than
# whatever the machine happens to have installed. FreeType's CMake build writes no .pc file, so
# here is one pointing at our headers and our static library. The version is FreeType's libtool
# version (26:6:20 for 2.14.3), which is what HarfBuzz's freetype_min_version is compared against.
mkdir -p build/pkgconfig
cat > build/pkgconfig/freetype2.pc <<EOF
prefix=$(pwd)
libdir=\${prefix}/build/freetype
includedir=\${prefix}/freetype/include

Name: FreeType 2
Description: A free, high-quality, and portable font engine.
Version: 26.6.20
Libs: -L\${libdir} -lfreetype
Cflags: -I\${includedir}
EOF

# HarfBuzz: shaping only. Everything that pulls in another library or builds a separate one is off
# -- glib and gobject above all, and subset/raster/vector/gpu, which are their own .a files that
# Mayfair doesn't link. FreeType stays on, for hb_ft_font_create().
if [ ! -f build/harfbuzz/build.ninja ]; then
    PKG_CONFIG_PATH="$(pwd)/build/pkgconfig" meson setup build/harfbuzz harfbuzz \
        --buildtype=release -Ddefault_library=static \
        -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
        -Dicu=disabled -Dgraphite2=disabled -Dchafa=disabled -Dpng=disabled -Dzlib=disabled \
        -Dsubset=disabled -Draster=disabled -Dvector=disabled -Dgpu=disabled \
        -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dintrospection=disabled \
        -Dbenchmark=disabled
fi
ninja -C build/harfbuzz

# libunibreak ships autotools only, and its sources are few enough that compiling them straight is
# simpler than requiring autoconf and automake on the build machine. Which files are translation
# units of their own is not obvious -- the generated tables in eastasianwidthdata.c and friends are
# #included into eastasianwidthdef.c and friends, so compiling them separately duplicates every
# symbol in them. Rather than keep a copy of that list here and watch it rot, read the one upstream
# already maintains in Makefile.am.
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

if [ -z "$UNIBREAK_SRCS" ]; then
    echo "Could not read libunibreak_la_SOURCES from libunibreak/src/Makefile.am" >&2
    exit 1
fi

# The source list is in the stamp as well as the commit, so changing this recipe rebuilds too
UNIBREAK_STAMP="$(git -C libunibreak rev-parse HEAD) $(echo "$UNIBREAK_SRCS" | sha256sum)"
if [ "$(cat build/libunibreak/stamp 2>/dev/null)" != "$UNIBREAK_STAMP" ]; then
    echo "Building libunibreak"
    rm -rf build/libunibreak
    mkdir -p build/libunibreak
    for c in $UNIBREAK_SRCS; do
        cc -O2 -fPIC -c "libunibreak/src/$c" -o "build/libunibreak/${c%.c}.o"
    done
    ar rcs build/libunibreak/libunibreak.a build/libunibreak/*.o
    echo "$UNIBREAK_STAMP" > build/libunibreak/stamp
fi

# SheenBidi builds as a single translation unit when SB_CONFIG_UNITY is set: SheenBidi.c #includes
# every other source file, so one compile covers it and there's no list here to keep in step.
SHEENBIDI_STAMP="$(git -C sheenbidi rev-parse HEAD)"
if [ "$(cat build/sheenbidi/stamp 2>/dev/null)" != "$SHEENBIDI_STAMP" ]; then
    echo "Building SheenBidi"
    rm -rf build/sheenbidi
    mkdir -p build/sheenbidi
    cc -O2 -fPIC -DSB_CONFIG_UNITY -Isheenbidi/Headers -Isheenbidi/Source \
        -c sheenbidi/Source/SheenBidi.c -o build/sheenbidi/SheenBidi.o
    ar rcs build/sheenbidi/libsheenbidi.a build/sheenbidi/SheenBidi.o
    echo "$SHEENBIDI_STAMP" > build/sheenbidi/stamp
fi

# litehtml lays out and draws HTML and CSS, for LiteWebView. Only its library, with the copy of
# Gumbo (Google's HTML5 parser, Apache-2.0) it bundles. It's C++ throughout, so D reaches it through
# a shim of Mayfair's own, bindings/litehtml_shim.cpp, which puts a C API on it; that's built here
# too, as dub only compiles C. The shim is in the stamp, so changing it rebuilds it.
if [ ! -f build/litehtml/build.ninja ]; then
    cmake -S litehtml -B build/litehtml -G Ninja -DCMAKE_BUILD_TYPE=Release -DLITEHTML_BUILD_TESTING=OFF
fi
ninja -C build/litehtml

LITEHTML_SHIM_STAMP="$(git -C litehtml rev-parse HEAD) $(cat ../bindings/litehtml_shim.cpp ../bindings/litehtml_shim.h | sha256sum)"
if [ "$(cat build/litehtml/shim.stamp 2>/dev/null)" != "$LITEHTML_SHIM_STAMP" ]; then
    echo "Building the litehtml shim"
    c++ -std=c++17 -O2 -fPIC -Wall -Ilitehtml/include -Ilitehtml/include/litehtml \
        -c ../bindings/litehtml_shim.cpp -o build/litehtml/litehtml_shim.o
    ar rcs build/litehtml/liblitehtml_shim.a build/litehtml/litehtml_shim.o
    echo "$LITEHTML_SHIM_STAMP" > build/litehtml/shim.stamp
fi
