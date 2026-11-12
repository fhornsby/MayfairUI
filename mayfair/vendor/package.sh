#!/usr/bin/env sh
#
# Packs what vendor/build.sh built into one archive for this platform, for an app's build to
# download rather than build: mayfair-native-VERSION-OS-ARCH.tar.xz, and its SHA-256 beside it.
# CI makes one for each platform and attaches them to the release.
#
#   vendor/package.sh [VERSION] [OUT_DIR]     VERSION defaults to `git describe`, OUT_DIR to dist/
#
# The archive is exactly the part of vendor/ that dub.json uses, at the same paths: the static
# libraries in its lflags, the headers in its cImportPaths (which ImportC reads as Mayfair is
# compiled), and each library's licence. Unpacked into vendor/, it leaves a copy of Mayfair
# looking as though build.sh had run. The paths are read from dub.json, so the two can't drift.
set -eu
cd "$(dirname "$0")"
. ./tools.sh

VERSION=${1:-$(git describe --tags --always 2>/dev/null || echo unknown)}
OUT=${2:-../dist}

case "$(uname -s)" in
    Linux) OS=linux ;;
    FreeBSD) OS=freebsd ;;
    Darwin) OS=macos ;;
    *) OS=$(uname -s | tr '[:upper:]' '[:lower:]') ;;
esac
case "$(uname -m)" in
    x86_64|amd64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) ARCH=$(uname -m) ;;
esac
NAME=mayfair-native-$VERSION-$OS-$ARCH

# What dub.json links (its "$PACKAGE_DIR/vendor/..." lflags) and the headers it reads ("vendor/..."
# in cImportPaths), relative to vendor/
LIBS=$(sed -n '/"lflags"/,/\]/p' ../dub.json | grep -o '"\$PACKAGE_DIR/vendor/[^"]*"' | sed 's#"\$PACKAGE_DIR/vendor/##; s#"$##')
HEADER_DIRS=$(sed -n '/"cImportPaths"/,/\]/p' ../dub.json | grep -o '"vendor/[^"]*"' | sed 's#"vendor/##; s#"$##')
if [ -z "$LIBS" ] || [ -z "$HEADER_DIRS" ]; then
    echo "Couldn't read the libraries and headers from dub.json" >&2
    exit 1
fi

STAGE=build/package/$NAME
rm -rf build/package
mkdir -p "$STAGE"

for lib in $LIBS; do
    if [ ! -f "$lib" ]; then
        echo "vendor/$lib isn't there: run vendor/build.sh first" >&2
        exit 1
    fi
    mkdir -p "$STAGE/$(dirname "$lib")"
    cp "$lib" "$STAGE/$lib"
    # Without debugging information, which is most of the Rust libraries' size, and which an app's
    # build doesn't need: the symbols it links by stay. MAYFAIR_KEEP_DEBUG=1 keeps it.
    if [ "${MAYFAIR_KEEP_DEBUG:-0}" != 1 ]; then
        strip_debug "$STAGE/$lib"
    fi
done

# Every header under each folder, keeping the folders, as #include finds them by their paths
for dir in $HEADER_DIRS; do
    if [ ! -d "$dir" ]; then
        echo "vendor/$dir isn't there: run vendor/build.sh first" >&2
        exit 1
    fi
    find "$dir" -type f \( -name '*.h' -o -name '*.hh' -o -name '*.hpp' \) | while read -r h; do
        mkdir -p "$STAGE/$(dirname "$h")"
        cp "$h" "$STAGE/$h"
    done
done

# Each library's licence, as it came, and Mayfair's notices, which have them all -- wgpu-native's
# release has none of its own
mkdir -p "$STAGE/licences"
cp ../THIRD_PARTY_NOTICES.md "$STAGE/licences/"
for project in thorvg yoga freetype harfbuzz libunibreak sheenbidi litehtml wgpu-native accesskit; do
    for f in "$project"/LICENSE* "$project"/LICENCE* "$project"/COPYING* "$project"/docs/FTL.TXT; do
        [ -f "$f" ] && cp "$f" "$STAGE/licences/$project-$(basename "$f")"
    done
done

# What it is, for whoever finds it unpacked
cat > "$STAGE/MAYFAIR-NATIVE" <<EOF
Mayfair's native libraries, prebuilt: unpack into mayfair/vendor/ in place of running build.sh.
version  $VERSION
platform $OS-$ARCH
built    $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
for lib in $LIBS; do
    echo "lib      $lib $(sha256 "$STAGE/$lib")" >> "$STAGE/MAYFAIR-NATIVE"
done

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
tar -C "$STAGE" -cJf "$OUT/$NAME.tar.xz" .
(cd "$OUT" && sha256 "$NAME.tar.xz" > "$NAME.tar.xz.sha256")
rm -rf build/package
echo "$OUT/$NAME.tar.xz"
echo "SHA-256 $(cat "$OUT/$NAME.tar.xz.sha256")"
