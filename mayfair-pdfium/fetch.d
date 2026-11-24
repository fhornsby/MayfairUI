/+ dub.sdl:
    name "mayfair-pdfium-fetch"
+/
/*
    PDFium, there before mayfair-pdfium's built: few systems package it, so this downloads a
    prebuilt one from the pdfium-binaries project (github.com/bblanchon/pdfium-binaries), at the
    version below, checks it against the checksum pinned here for its platform, and unpacks it
    into pdfium/ beside this script: its library, its licences, and its headers (which
    tools/check-abi.sh reads). dub.json's copyFiles then puts the library beside the app.

    Run by dub.json's preGenerateCommands, with the package's folder. Once it's there it's left
    alone, until the version here changes.

        MAYFAIR_PDFIUM_FETCH=no     download nothing: use the system's PDFium, or MAYFAIR_PDFIUM's
                                    (see mayfair.pdf.pdfium)

    A download that fails doesn't fail the build: the app's documents say PDFium's missing, and why.
*/
module fetch;

import std.file : exists, mkdirRecurse, read, readText, remove, rmdirRecurse, write;
import std.format : format;
import std.path : buildPath, dirName;
import std.process : environment, execute;
import std.stdio : stderr, writeln;
import std.string : strip;

enum release = "chromium/8179";

/// Each platform's archive's SHA-256, as downloaded and checked when the version above was chosen.
enum string[string] checksums = [
    "linux-x64": "b4766a6bf2856efbcc6c3cc7d6ae9022bdc6bb36ddc1acdd92d1f1873f773f4b",
    "linux-arm64": "18bb6d568257b28d14f6c3b8bfb48caf73d4615b319ca4d43b424c2a03431d9f",
    "mac-x64": "b29bbfe37efcad5b443fa3556c0485ec96fc1992d5b19d84df49d48fbed1d0d2",
    "mac-arm64": "44b7c6f55dd33454d0909728bd0adf6c86a8e141b36f07a6b6f50e228e1dfb46",
    "win-x64": "836a77c9053f624839c66010cddea7b675628a36b8831d2330178bb169d241b6",
    "win-arm64": "9c659bf0cd9bdefcbf7ec0e4b1675c2961e0fdfd4ce097b411efd9742832fe06",
];

int main(string[] args)
{
    const package_ = args.length > 1 ? args[1] : dirName(__FILE_FULL_PATH__);
    if (environment.get("MAYFAIR_PDFIUM_FETCH", "") == "no")
        return 0;
    const platform = thisPlatform;
    if (platform !in checksums)
    {
        writeln("pdfium-binaries has no PDFium for ", platform, ": mayfair-pdfium will use the system's, "
                ~ "or MAYFAIR_PDFIUM's");
        return 0;
    }
    const folder = buildPath(package_, "pdfium");
    const stamp = buildPath(folder, "FETCHED");
    const want = release ~ " " ~ platform;
    if (exists(stamp) && readText(stamp).strip == want)
        return 0;

    try
    {
        const archive = buildPath(package_, "pdfium-download.tgz");
        const url = format!"https://github.com/bblanchon/pdfium-binaries/releases/download/%s/pdfium-%s.tgz"(release, platform);
        writeln("Downloading PDFium (", release, ", ", platform, ")");
        auto got = execute(["curl", "-fsSL", "--retry", "2", "-o", archive, url]);
        if (got.status != 0)
            throw new Exception(url ~ ": " ~ got.output.strip);
        scope (exit) if (exists(archive)) remove(archive);
        const actual = sha256(archive);
        if (actual != checksums[platform])
            throw new Exception(format!"the download's SHA-256 is %s, not %s: not using it"(actual, checksums[platform]));
        if (exists(folder))
            rmdirRecurse(folder);
        mkdirRecurse(folder);
        // tar is on every platform PDFium's built for, Windows 10 and on included
        auto unpacked = execute(["tar", "xzf", archive, "-C", folder]);
        if (unpacked.status != 0)
            throw new Exception("couldn't unpack it: " ~ unpacked.output.strip);
        write(stamp, want ~ "\n");
        return 0;
    }
    catch (Exception e)
    {
        stderr.writeln("PDFium couldn't be downloaded: ", e.msg);
        stderr.writeln("mayfair-pdfium will use the system's PDFium, or MAYFAIR_PDFIUM's, if there is one");
        return 0;
    }
}

/// This platform, as pdfium-binaries names them.
string thisPlatform()
{
    version (linux) enum os = "linux";
    else version (OSX) enum os = "mac";
    else version (Windows) enum os = "win";
    else version (FreeBSD) enum os = "freebsd";
    else enum os = "unknown";
    version (X86_64) enum arch = "x64";
    else version (AArch64) enum arch = "arm64";
    else enum arch = "unknown";
    return os ~ "-" ~ arch;
}

string sha256(string file)
{
    import std.digest : toHexString, LetterCase;
    import std.digest.sha : sha256Of;
    return toHexString!(LetterCase.lower)(sha256Of(cast(const(ubyte)[]) read(file))).idup;
}
