/+ dub.sdl:
    name "mayfair-native"
+/
/*
    Mayfair's native libraries, there before dub builds Mayfair: dub.json's preGenerateCommands
    runs this, with the vendor folder and Mayfair's version, as dub has it, as its arguments.

    A released version of Mayfair -- 0.2.0, as dub fetched it from the registry -- downloads them
    prebuilt: its release on GitHub has an archive for each platform (see vendor/package.sh and
    .github/workflows/native.yml), checked against the release's SHA256SUMS, and unpacked into
    vendor/, as though vendor/build.sh had run. Once there, they're left alone until the version
    changes. Anything else -- a git checkout, Mayfair's own development -- builds them from source
    with vendor/build.sh, as it always has, and so does a release whose download fails.

        MAYFAIR_NATIVE=build                build from source, whatever the version
        MAYFAIR_NATIVE=path/to/archive.zip  unpack an archive already downloaded: offline, say
        MAYFAIR_NATIVE_URL=https://...      download from a mirror of the releases
        MAYFAIR_NATIVE_VERSION=0.2.0        download that version's, whatever dub says this is

    It's D, run by dub, rather than a shell script, so it'll run on Windows too; and unpacks the
    archive itself, so needs nothing but curl, which every platform Mayfair builds on has.
*/
module native;

import std.algorithm : canFind, startsWith;
import std.file : exists, mkdirRecurse, read, readText, remove, write;
import std.format : format;
import std.path : buildPath, dirName, isAbsolute;
import std.process : environment, execute, spawnProcess, wait;
import std.stdio : stderr, stdout, writeln;
import std.string : lineSplitter, strip;

enum releases = "https://github.com/fhornsby/MayfairUI/releases/download";

int main(string[] args)
{
    const vendor = args.length > 1 ? args[1] : dirName(__FILE_FULL_PATH__);

    const choice = environment.get("MAYFAIR_NATIVE", "");
    if (choice == "build")
        return build(vendor);
    if (choice.length)
        return unpackLocal(choice, vendor);

    // The version as dub.json passes it, or as dub's environment has it, where the shell didn't
    // put it in the argument
    auto given = args.length > 2 && !args[2].startsWith("$") ? args[2] : environment.get("DUB_PACKAGE_VERSION", "");
    auto ver = environment.get("MAYFAIR_NATIVE_VERSION", given);
    if (ver.startsWith("v"))
        ver = ver[1 .. $];
    if (!isRelease(ver))
        return build(vendor); // a checkout, not a release: there's nothing to download for it
    const tag = "v" ~ ver;

    const stamp = buildPath(vendor, "build", "native.stamp");
    const want = tag ~ " " ~ platform;
    if (exists(stamp) && readText(stamp).strip == want)
        return 0; // downloaded already

    try
    {
        download(tag, vendor);
        mkdirRecurse(dirName(stamp));
        write(stamp, want ~ "\n");
        return 0;
    }
    catch (Exception e)
    {
        stderr.writeln("Mayfair's native libraries couldn't be downloaded: ", e.msg);
        stderr.writeln("Building them from source instead (MAYFAIR_NATIVE=build does so without trying)");
        return build(vendor);
    }
}

/// This platform's part of an archive's name, as vendor/package.sh names it: linux-x86_64, say.
string platform()
{
    version (linux) enum os = "linux";
    else version (FreeBSD) enum os = "freebsd";
    else version (OSX) enum os = "macos";
    else version (Windows) enum os = "windows";
    else enum os = "unknown";
    version (X86_64) enum arch = "x86_64";
    else version (AArch64) enum arch = "arm64";
    else enum arch = "unknown";
    return os ~ "-" ~ arch;
}

/// Whether `ver` is a released version's -- 0.2.0, or 0.2.0-beta.1 -- rather than a branch's or a commit's.
bool isRelease(string ver) pure @safe
{
    import std.regex : ctRegex, matchFirst;
    return !matchFirst(ver, ctRegex!`^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$`).empty;
}

/// Downloads release `tag`'s archive for this platform, checks it, and unpacks it into `vendor`.
void download(string tag, string vendor)
{
    const base = environment.get("MAYFAIR_NATIVE_URL", releases);
    const name = format!"mayfair-native-%s-%s.zip"(tag, platform);
    const folder = buildPath(vendor, "build", "download");
    mkdirRecurse(folder);
    const sums = buildPath(folder, "SHA256SUMS"), archive = buildPath(folder, name);

    writeln("Downloading Mayfair's native libraries: ", name);
    stdout.flush(); // before anything's said on stderr
    fetch(format!"%s/%s/SHA256SUMS"(base, tag), sums);
    const expected = checksumOf(readText(sums), name);
    if (!expected.length)
        throw new Exception(format!"release %s has no archive for %s"(tag, platform));
    fetch(format!"%s/%s/%s"(base, tag, name), archive);

    const actual = sha256(archive);
    if (actual != expected)
    {
        remove(archive);
        throw new Exception(format!"%s isn't what the release says it is: its SHA-256 is %s, not %s"(name, actual, expected));
    }
    unpack(archive, vendor);
    remove(archive);
}

/// Unpacks an archive the user has, as MAYFAIR_NATIVE says, without checking it against a release.
int unpackLocal(string archive, string vendor)
{
    try
    {
        writeln("Unpacking Mayfair's native libraries from ", archive);
        stdout.flush();
        unpack(archive, vendor);
        return 0;
    }
    catch (Exception e)
    {
        stderr.writeln("Couldn't unpack ", archive, ": ", e.msg);
        return 1;
    }
}

/// The checksum SHA256SUMS (as sha256sum writes it) has for `name`, or null.
string checksumOf(string sums, string name) pure @safe
{
    foreach (line; sums.lineSplitter)
    {
        // "<hex>  <name>", or "<hex> *<name>" for a file read as binary
        import std.array : split;
        const parts = line.split;
        if (parts.length == 2 && (parts[1] == name || parts[1] == "*" ~ name))
            return parts[0];
    }
    return null;
}

/// Downloads `url` to `file`, with curl -- or FreeBSD's own fetch, where curl isn't installed.
void fetch(string url, string file)
{
    auto r = execute(["curl", "-fsSL", "--retry", "2", "-o", file, url]);
    version (FreeBSD)
        if (r.status != 0 && r.output.canFind("not found"))
            r = execute(["fetch", "-q", "-o", file, url]);
    if (r.status != 0)
        throw new Exception(format!"%s: %s"(url, r.output.strip));
}

string sha256(string file)
{
    import std.digest : toHexString, LetterCase;
    import std.digest.sha : sha256Of;
    return toHexString!(LetterCase.lower)(sha256Of(cast(const(ubyte)[]) read(file))).idup;
}

/// Unpacks zip `archive` into `vendor`, refusing anything that would land outside it.
void unpack(string archive, string vendor)
{
    import std.zip : ZipArchive;
    auto zip = new ZipArchive(read(archive));
    foreach (path, member; zip.directory)
    {
        if (isAbsolute(path) || path.canFind("..") || path.canFind('\\'))
            throw new Exception("the archive has a path outside vendor/ in it: " ~ path);
        if (path.length && path[$ - 1] == '/')
            continue; // a folder: made with what's in it
        const to = buildPath(vendor, path);
        mkdirRecurse(dirName(to));
        write(to, zip.expand(member));
    }
}

/// Builds them from source, as vendor/build.sh does.
int build(string vendor)
{
    version (Windows)
    {
        stderr.writeln("Mayfair's native libraries can't be built from source on Windows yet: use a release, "
                       ~ "or set MAYFAIR_NATIVE to an archive of them");
        return 1;
    }
    else
        return wait(spawnProcess(["sh", buildPath(vendor, "build.sh")]));
}

unittest
{
    assert(isRelease("0.2.0") && isRelease("1.10.3") && isRelease("0.2.0-beta.1"));
    assert(!isRelease("~main") && !isRelease("0.1.0+commit.5.g6ef748a") && !isRelease("") && !isRelease("0.2"));
    const sums = "aaa  mayfair-native-v0.2.0-linux-x86_64.zip\nbbb *mayfair-native-v0.2.0-linux-arm64.zip\n";
    assert(checksumOf(sums, "mayfair-native-v0.2.0-linux-x86_64.zip") == "aaa");
    assert(checksumOf(sums, "mayfair-native-v0.2.0-linux-arm64.zip") == "bbb");
    assert(checksumOf(sums, "mayfair-native-v0.2.0-macos-arm64.zip") is null);
}
