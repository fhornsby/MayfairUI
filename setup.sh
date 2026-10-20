#!/usr/bin/env bash
#
# Sets up a fresh Ubuntu 26.04 or FreeBSD 14 machine (or VM) to build and run Mayfair, then builds
# it once. On FreeBSD, install bash first (pkg install bash), and sudo if you haven't got it.
#
#   ./setup.sh            everything for the desktop build, then a first build
#   ./setup.sh --web      the same, plus LDC 1.43 with its Emscripten addon and the Emscripten SDK,
#                         for the browser build (mayfair/web/build.sh). Linux only.
#   ./setup.sh --no-build install only; skip the first build
#
# Run it as yourself, not as root: it uses sudo for apt or pkg, and puts the web toolchain in your
# home (~/dlang and ~/emsdk, where mayfair_web_test/build.sh looks for them).
#
# What comes from where:
#   apt or pkg   the D compiler (LDC) and dub, SDL3, CMake, Meson, Ninja, a C/C++ compiler, Rust's
#                cargo (for mayfair-terminal), Vulkan and its Mesa drivers, and the bits Mayfair
#                asks the desktop for at run time
#   submodules   ThorVG, Yoga, FreeType, HarfBuzz, libunibreak, SheenBidi and litehtml, which
#                mayfair/vendor/build.sh compiles
#   build.sh     wgpu-native and AccessKit: downloaded prebuilt on Linux x86_64, and built from
#                source with cargo everywhere else, FreeBSD included
set -euo pipefail
cd "$(dirname "$0")"

web=false
build=true
for arg in "$@"; do
    case $arg in
        --web) web=true ;;
        --no-build) build=false ;;
        -h|--help) sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (see --help)" >&2; exit 1 ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your own user, not root: it calls sudo where it needs to." >&2
    exit 1
fi

os=$(uname -s)
case $os in
    Linux) ;;
    FreeBSD)
        if $web; then
            echo "The browser build's toolchain (LDC's Emscripten addon, the Emscripten SDK) is set up on Linux only." >&2
            exit 1
        fi ;;
    *) echo "Mayfair builds on Linux and FreeBSD, and this is $os." >&2; exit 1 ;;
esac

echo "==> Installing packages"
if [ "$os" = Linux ]; then
    . /etc/os-release
    if [ "${ID:-}" != ubuntu ]; then
        echo "Warning: this is written for Ubuntu 26.04, and this is ${PRETTY_NAME:-unknown}. Carrying on." >&2
    fi
    packages=(
        # Fetching and unpacking: git for the submodules, curl and unzip for wgpu-native and AccessKit
        git curl ca-certificates unzip xz-utils
        # Compilers and build tools. LDC is the only D compiler Mayfair supports; binutils gives
        # vendor/build.sh nm and objcopy
        build-essential binutils patch pkg-config cmake meson ninja-build ldc dub
        # mayfair-terminal's native half is Rust (cargo 1.85 or later)
        cargo rustc
        # SDL3, which Mayfair links, with the Wayland and X11 libraries it uses
        libsdl3-dev libwayland-client0 libwayland-cursor0 libwayland-egl1 libxkbcommon0 libdecor-0-0
        # WebGPU runs on Vulkan; vulkaninfo is there to check what it found. Where Vulkan is only
        # Mesa's software lavapipe -- a VM on virgl, say -- Mayfair falls back to OpenGL ES through
        # EGL, which virgl does pass to the host's GPU, and failing that to its CPU renderer
        libvulkan1 mesa-vulkan-drivers vulkan-tools libegl1 libgles2 libgl1-mesa-dri mesa-utils
        # At run time Mayfair asks gsettings for the icon theme and the titlebar button layout, and
        # looks in /usr/share/fonts for fonts it doesn't carry itself
        libglib2.0-bin adwaita-icon-theme fonts-noto-core fonts-noto-color-emoji
    )
    # Off x86_64 there are no prebuilt wgpu-native and AccessKit, so build.sh builds them, and
    # wgpu-native's bindgen needs libclang
    if [ "$(uname -m)" != x86_64 ]; then
        packages+=(libclang-dev)
    fi
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
else
    packages=(
        # The base system has the C/C++ compiler (clang), make, patch, unzip and sha256
        git curl pkgconf cmake meson ninja ldc dub
        # Rust, for wgpu-native and AccessKit, which build.sh builds from source here, and for
        # mayfair-terminal. LLVM gives wgpu-native's bindgen libclang, and build.sh llvm-objcopy.
        rust llvm
        # SDL3, which Mayfair links, with the Wayland libraries it uses
        sdl3 wayland libxkbcommon libdecor
        # WebGPU runs on Vulkan, through Mesa's drivers (with drm-kmod loaded) or NVIDIA's;
        # failing that, OpenGL ES through EGL, and failing that Mayfair's CPU renderer
        vulkan-loader vulkan-tools mesa-libs mesa-dri
        # At run time Mayfair asks gsettings for the icon theme and the titlebar button layout,
        # the desktop portal for file choosers, and looks in /usr/local/share/fonts for fonts
        glib dbus xdg-desktop-portal adwaita-icon-theme noto-basic noto-emoji
    )
    sudo pkg install -y "${packages[@]}"
fi

echo "==> Fetching the vendored sources (git submodules)"
if [ -d .git ]; then
    git submodule update --init
else
    echo "Not a git checkout, so no submodules to fetch: clone the repository rather than copy it." >&2
    exit 1
fi

if $web; then
    LDC_VERSION=1.43.0
    LDC_DIR="$HOME/dlang/ldc-$LDC_VERSION"
    ADDON_SHA256=86af4b9ff3ba41e8e090e1a496213ca36f6b90afaaed62392d5e520d46bb0717
    EMSDK_VERSION=6.0.12

    echo "==> Installing LDC $LDC_VERSION into ~/dlang, for the browser build"
    if [ ! -x "$LDC_DIR/bin/ldc2" ]; then
        mkdir -p "$HOME/dlang"
        curl -fsSL -o "$HOME/dlang/install.sh" https://dlang.org/install.sh
        bash "$HOME/dlang/install.sh" install "ldc-$LDC_VERSION"
    fi

    # The Emscripten target's runtime libraries come separately, as an addon unpacked over LDC
    if [ ! -d "$LDC_DIR/lib-emscripten-wasm32" ]; then
        echo "==> Adding LDC's Emscripten addon"
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        addon=ldc2-$LDC_VERSION-addon-emscripten.tar.xz
        curl -fsSL -o "$tmp/$addon" \
            "https://github.com/ldc-developers/ldc/releases/download/v$LDC_VERSION/$addon"
        echo "$ADDON_SHA256  $tmp/$addon" | sha256sum -c --quiet
        tar -xJf "$tmp/$addon" -C "$LDC_DIR"
    fi

    echo "==> Installing the Emscripten SDK $EMSDK_VERSION into ~/emsdk"
    if [ ! -d "$HOME/emsdk" ]; then
        git clone --depth 1 https://github.com/emscripten-core/emsdk.git "$HOME/emsdk"
    fi
    "$HOME/emsdk/emsdk" install "$EMSDK_VERSION"
    "$HOME/emsdk/emsdk" activate "$EMSDK_VERSION"
fi

if $build; then
    # The first build gets wgpu-native and AccessKit (downloaded, or built from source on FreeBSD)
    # and compiles the vendored C and C++ libraries, which takes a few minutes; after that dub only
    # checks they're up to date
    echo "==> Building Mayfair"
    (cd mayfair && dub build)
    echo "==> Building the test app"
    (cd mayfair_test_app && dub build)
fi

echo
echo "Done. To run the test app:"
echo "    cd mayfair_test_app && dub run"
if $web; then
    echo "For the browser build:"
    echo "    cd mayfair_web_test && ./build.sh && cd out && python3 -m http.server 8765"
fi
