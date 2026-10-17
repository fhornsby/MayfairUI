#!/usr/bin/env bash
#
# Sets up a fresh Ubuntu 26.04 machine (or VM) to build and run Mayfair, then builds it once.
#
#   ./setup.sh            everything for the Linux build, then a first build
#   ./setup.sh --web      the same, plus LDC 1.43 with its Emscripten addon and the Emscripten SDK,
#                         for the browser build (mayfair/web/build.sh)
#   ./setup.sh --no-build install only; skip the first build
#
# Run it as yourself, not as root: it uses sudo for apt, and puts the web toolchain in your home
# (~/dlang and ~/emsdk, where mayfair_web_test/build.sh looks for them).
#
# What comes from where:
#   apt          the D compiler (LDC) and dub, SDL3, CMake, Meson, Ninja, a C/C++ compiler, Rust's
#                cargo (for mayfair-terminal), Vulkan and its Mesa drivers, and the bits Mayfair
#                asks the desktop for at run time
#   submodules   ThorVG, Yoga, FreeType, HarfBuzz, libunibreak, SheenBidi and litehtml, which
#                mayfair/vendor/build.sh compiles
#   downloads    wgpu-native and AccessKit, prebuilt, fetched by mayfair/vendor/build.sh itself
set -euo pipefail
cd "$(dirname "$0")"

web=false
build=true
for arg in "$@"; do
    case $arg in
        --web) web=true ;;
        --no-build) build=false ;;
        -h|--help) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (see --help)" >&2; exit 1 ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your own user, not root: it calls sudo where it needs to." >&2
    exit 1
fi
if [ "$(uname -m)" != x86_64 ]; then
    echo "Mayfair only builds on x86_64 Linux for now (wgpu-native and AccessKit are fetched prebuilt)." >&2
    exit 1
fi
. /etc/os-release
if [ "${ID:-}" != ubuntu ]; then
    echo "Warning: this is written for Ubuntu 26.04, and this is ${PRETTY_NAME:-unknown}. Carrying on." >&2
fi

echo "==> Installing packages"
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
    # WebGPU runs on Vulkan. Mesa's drivers include lavapipe, a software Vulkan, so a VM without
    # GPU passthrough still runs; vulkaninfo is there to check what it found
    libvulkan1 mesa-vulkan-drivers vulkan-tools
    # At run time Mayfair asks gsettings for the icon theme and the titlebar button layout, and
    # looks in /usr/share/fonts for fonts it doesn't carry itself
    libglib2.0-bin adwaita-icon-theme fonts-noto-core fonts-noto-color-emoji
)
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"

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
    # The first build downloads wgpu-native and AccessKit and compiles the vendored C and C++
    # libraries, which takes a few minutes; after that dub only checks they're up to date
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
