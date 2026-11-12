# Sourced by vendor/build.sh and mayfair-terminal's native/build.sh: the few tools whose names or
# flags differ between Linux (GNU) and FreeBSD (BSD and LLVM), behind one name each.

# A SHA-256 of stdin, or of the files named, as the bare hex digest. Linux has sha256sum; FreeBSD's
# base has sha256, and only newer releases a sha256sum as well.
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@"
    else
        command sha256 -r "$@"
    fi | cut -d' ' -f1
}

# Each file's size and modification time, as "size mtime" per file
filestamp() {
    if stat -c %s / >/dev/null 2>&1; then
        stat -c '%s %Y' "$@" # GNU
    else
        stat -f '%z %m' "$@" # BSD
    fi
}

# An objcopy that can --weaken-symbols: GNU's on Linux, LLVM's on FreeBSD, where base's may be
# ELF Toolchain's, which can't, and the llvm package installs it under a versioned name.
objcopy_tool() {
    for t in objcopy llvm-objcopy $(ls /usr/local/bin/llvm-objcopy[0-9]* 2>/dev/null | sort -r); do
        if command -v "$t" >/dev/null 2>&1 && "$t" --help 2>&1 | grep -q -- --weaken-symbols; then
            echo "$t"
            return
        fi
    done
    echo "No objcopy that can --weaken-symbols: install binutils, or LLVM for llvm-objcopy" >&2
    return 1
}

# The global symbols an archive defines (text, data, bss, read-only), one per line, sorted
strong_symbols() {
    nm -g --defined-only "$1" 2>/dev/null | awk 'NF == 3 && $2 ~ /^[TDBR]$/ { print $3 }' | LC_ALL=C sort -u
}

# Takes the debugging information out of static library $1, in place, keeping the symbols it links
# by: GNU's or LLVM's strip, or macOS's, whose -S is the same
strip_debug() {
    if strip --version >/dev/null 2>&1; then
        strip --strip-debug "$1"
    elif command -v llvm-strip >/dev/null 2>&1; then
        llvm-strip --strip-debug "$1"
    else
        strip -S "$1"
    fi
}
