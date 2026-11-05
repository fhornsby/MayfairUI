module dotenv;

/*
    Settings from a .env file: KEY=value on each line, as most tools read one. Blank lines and
    lines starting with # are skipped, and a value can be in quotes. Something already set in the
    environment wins over the file, so `APPWRITE_PROJECT=... dub run` still works.

    The example keeps its Appwrite project's IDs in one, out of git (see .env.example).
*/

/// The settings in `text`, a .env file's.
string[string] parseDotEnv(string text) pure @safe
{
    import std.string : indexOf, lineSplitter, strip;

    string[string] result;
    foreach (line; text.lineSplitter)
    {
        const l = line.strip;
        if (!l.length || l[0] == '#')
            continue;
        const eq = l.indexOf('=');
        if (eq <= 0)
            continue;
        auto key = l[0 .. eq].strip;
        if (key.length > 7 && key[0 .. 7] == "export ")
            key = key[7 .. $].strip;
        auto value = l[eq + 1 .. $].strip;
        if (value.length >= 2 && (value[0] == '"' || value[0] == '\'') && value[$ - 1] == value[0])
            value = value[1 .. $ - 1];
        result[key] = value;
    }
    return result;
}

/// The setting `key`: from the environment if it's set there, else from the .env file in the
/// current directory, if there is one. null if neither has it, or the file still has its
/// placeholder, `<...>`, from .env.example.
string setting(string key)
{
    import std.algorithm : canFind;
    import std.file : exists, readText;
    import std.process : environment;

    static string[string] file;
    static bool read;
    if (!read)
    {
        read = true;
        if (exists(".env"))
            file = parseDotEnv(readText(".env"));
    }
    auto value = environment.get(key, file.get(key, null));
    return value.canFind('<') ? null : value;
}

unittest
{
    const s = parseDotEnv(`
# A comment
APPWRITE_ENDPOINT=https://fra.cloud.appwrite.io/v1
APPWRITE_PROJECT = "abc123"
export APPWRITE_TABLE='t1'
not a setting
=no key
`);
    assert(s["APPWRITE_ENDPOINT"] == "https://fra.cloud.appwrite.io/v1");
    assert(s["APPWRITE_PROJECT"] == "abc123", "spaces round the = and quotes taken off");
    assert(s["APPWRITE_TABLE"] == "t1", "export, as a shell script would have it");
    assert(s.length == 3, "comments, blank lines and lines without a key skipped");
}
