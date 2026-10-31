module mayfair.strings;

import core.atomic : atomicLoad, atomicOp, atomicStore, MemoryOrder;
import std.meta : AliasSeq;
import std.traits : BaseClassesTuple, getUDAs, hasUDA;
import mayfair.xml.parser : Document, Element, XmlException, parseXml;

/*
    An app's text, in one language or many, in one file: what JavaFX's ResourceBundle is to
    FXML's `%key`, and laid out as Apple's string catalogues are, each string with its
    translations beside it. Every string is read and checked as the program's compiled.

        resources/
            strings.xml
            views/main.xml

    with "resources" among dub's stringImportPaths. strings.xml names its languages, the first
    the one every string has to be in, and has each string in as many of them as it's been
    translated into:

        <strings languages="en-GB fr de zh">
            <string id="hello">
                <en-GB>Hello</en-GB>
                <fr>Bonjour</fr>
                <de>Hallo</de>
                <zh>你好</zh>
            </string>
            <string id="welcome">
                <en-GB>Welcome back, {0}</en-GB>
                <fr>Bon retour, {0}</fr>
            </string>
            <string id="ok">OK</string>         <!-- the same in every language -->
        </strings>

    A string's text on its own, with no languages in it, is the first language's. An app that
    isn't translated yet needs no languages="..." at all: it's in UK English, en-GB.

    A view puts one in with `%` and its id, as FXML does:

        <Label text="%hello"/>
        <Button>%hello</Button>             <!-- \% for text that starts with a % -->

    code has tr!, with what fills a string's {0}, {1} and so on:

        status.setText(tr!"welcome"(user.name));

    and a field can be marked to be filled with one, by its own name or the id given:

        @View("main.xml")
        class Main
        {
            @localised string hello;                    // the string with id="hello"
            @Localised("welcome") string greeting;      // the one with id="welcome"
        }

    View.load fills a controller's @localised fields before it builds the view, as it does
    @autowired ones, and those of the app's own widgets a view makes; anything else made with
    `new` is filled in by localise(), which returns it: `auto page = localise(new Page)`.

    Each of these is a compile error, at the line it's on: an id that isn't in strings.xml, a
    language that isn't among its languages="...", a string missing from the first language, a
    translation whose {0}s aren't the ones the first language's has, a string with {0}s in a
    view, which has nothing to fill them, or tr! given more or fewer than it has. A string that
    hasn't been translated into a language is shown in the first language, as Android does.

    Which language
    --------------
    By default the program has every language in it, and shows the one the person running it
    has asked for, as gettext works it out: the languages in $LANGUAGE (fr:de), then the one in
    $LC_ALL, $LC_MESSAGES or $LANG (fr_CA.UTF-8). In the browser that's the browser's language,
    which Emscripten puts in $LANG. The first of those strings.xml has is shown -- fr-CA if it
    has that, else fr, else any French -- and if it has none of them, its first language. It's
    worked out once, when the first string's asked for: after that, a string's an index into a
    table, with nothing to lock or compare. Try one with `LANGUAGE=fr ./app`, or call
    setLanguage("fr") before the views are loaded.

    Or one language can be chosen as the program's compiled, so it's the only one in it and every
    string is a constant, with a version naming it:

        dub build --d-version=MayfairLanguage_fr
        dub build --d-version=MayfairLanguage_zh_CN    (a - in its name is a _)

    or `"versions": ["MayfairLanguage_fr"]` in a dub configuration of the app's own. A language
    strings.xml doesn't have is a compile error. setLanguage does nothing in a program built for
    one language.

    Languages are named as BCP 47 names them, as in fr, pt-BR and zh-Hans: two letters for the
    language (Chinese is zh, German de), then a region or script if it matters.

    What's in a string: its text, with the space at its ends trimmed and any run of spaces and
    line breaks inside it made one space, as Android does; \n for a line break, \t a tab, and
    \\ a backslash. {0} to {9} and up are filled in by tr!'s arguments, in order, and can be in
    a different order in a translation.

    Views made before the language changes keep the text they were made with: load them again
    to show it in the new one, as JavaFX's FXMLLoader needs.
*/

/// Marks a string field to fill with the string whose id is the field's name, from strings.xml.
enum localised = Localised.init;

/// ditto. `@Localised("welcome")` fills it with the string with id="welcome".
struct Localised
{
    string id;
}

/// The string with id `id`, in the language being shown, with its {0}, {1}... filled in from `args`.
string tr(string id, Args...)(Args args)
{
    enum c = catalogue!();
    enum k = c.indexOf(id);
    static if (k < 0)
        static assert(false, missing(c, id));
    else static if (Args.length != c.arity[k])
        static assert(false, stringsFile ~ "'s " ~ id ~ " has " ~ slots(c.arity[k]) ~ ", and tr!\"" ~ id ~ "\" was given "
                      ~ (Args.length == 1 ? "1 thing" : decimal(Args.length) ~ " things") ~ " to fill in");
    else static if (Args.length)
    {
        import std.conv : to;
        string[Args.length] filling;
        static foreach (i; 0 .. Args.length)
            filling[i] = to!string(args[i]);
        return fill(.text!k, filling[]);
    }
    else
        return .text!k;
}

/// The language strings are being shown in: a BCP 47 name, as in "fr" or "en-GB".
string currentLanguage()()
{
    enum c = catalogue!();
    static if (pinned!() >= 0)
        return c.languages[pinned!()];
    else
    {
        enum string[] all = c.languages;
        static immutable string[] languages = all;
        return languages[languageIndex!()()];
    }
}

/// Fills `target`'s @localised fields with their strings, and returns it.
T localise(T)(T target) if (is(T == class))
{
    static foreach (B; AliasSeq!(T, BaseClassesTuple!T))
    {
        static if (!is(B == Object))
        {
            static foreach (i; 0 .. B.tupleof.length)
            {{
                static if (hasUDA!(B.tupleof[i], Localised))
                {
                    enum field = B.stringof ~ "." ~ __traits(identifier, B.tupleof[i]);
                    enum id = idOf!(__traits(identifier, B.tupleof[i]), getUDAs!(B.tupleof[i], Localised));
                    static assert(is(typeof(B.tupleof[i]) : const(char)[]),
                                  field ~ " is @localised, so it has to be a string, not " ~ typeof(B.tupleof[i]).stringof);
                    enum c = catalogue!();
                    enum k = c.indexOf(id);
                    static if (k < 0)
                        static assert(false, field ~ " is @localised, but " ~ missing(c, id));
                    else static if (c.arity[k])
                        static assert(false, field ~ " is @localised, but " ~ stringsFile ~ "'s " ~ id
                                      ~ " has {n} to fill in; set it with tr!\"" ~ id ~ "\"(...) instead");
                    else
                        (cast(B) target).tupleof[i] = .text!k;
                }
            }}
        }
    }
    return target;
}

/// Shows strings in `language`, or the first of `languages` there's a translation into, from now on.
void setLanguage(string language) @safe
{
    setLanguages([language]);
}

/// ditto. null goes back to the languages asked for when the app was started.
void setLanguages(string[] languages) @trusted
{
    synchronized
    {
        chosen = languages.dup;
        overridden = languages !is null;
    }
    atomicOp!"+="(generation, 1); // so each table works out its language again
}

/// The languages the person running the app has asked for, most wanted first, as BCP 47 names.
string[] preferredLanguages() @trusted
{
    synchronized
        return overridden ? chosen.dup : systemLanguages();
}

/// The string a view's `%id` stands for. Public for the code views generate to call.
string resourceString(string id, string loc)()
{
    enum c = catalogue!();
    enum k = c.indexOf(id);
    static if (k < 0)
        static assert(false, loc ~ ": " ~ missing(c, id));
    else static if (c.arity[k])
        static assert(false, loc ~ ": " ~ stringsFile ~ "'s " ~ id ~ " has {n} to fill in, and a view has nothing to "
                      ~ "fill them with; set it from the controller with tr!\"" ~ id ~ "\"(...)");
    else
        return .text!k;
}

private:

/// The language strings are in when strings.xml doesn't name its languages.
enum defaultLanguage = "en-GB";

/// Where the strings are, among the string imports.
enum stringsFile = "strings.xml";

/*
    The strings, read as the program's compiled. A template, so the file's looked for with the
    app's string imports, not Mayfair's, and only once something asks for a string.
*/
template catalogue()
{
    static assert(__traits(compiles, import(stringsFile)), "there's no " ~ stringsFile ~ " for the app's strings: make "
                  ~ "one in resources, with resources among the stringImportPaths in dub.json");
    enum Catalogue read = compile(import(stringsFile), stringsFile);
    static assert(read.error is null, read.error);
    enum Catalogue catalogue = read;
}

/// Which of the catalogue's languages was chosen as the program was compiled, or -1 for none.
template pinned()
{
    enum c = catalogue!();
    enum string[] candidates = c.languages ~ isoLanguages;
    enum int[] set = () {
        int[] r;
        static foreach (i, l; candidates)
            static if (isVersion!("MayfairLanguage_" ~ versionName(l)))
                r ~= cast(int) i;
        return r;
    }();
    static if (set.length == 0)
        enum pinned = -1;
    else
    {
        enum int[] found = () { int[] r; foreach (i; set) if (!isIn(candidates[i], r, candidates)) r ~= i; return r; }();
        static assert(found.length == 1, "the program's being compiled for more than one language: MayfairLanguage_"
                      ~ versionName(candidates[found[0]]) ~ " and MayfairLanguage_" ~ versionName(candidates[found[1]]));
        enum chosen = match(c.languages, [candidates[found[0]]]);
        static assert(chosen >= 0, "the program's being compiled for " ~ candidates[found[0]] ~ " (MayfairLanguage_"
                      ~ versionName(candidates[found[0]]) ~ "), but " ~ stringsFile ~ " has no "
                      ~ candidates[found[0]] ~ " or language like it: it has " ~ joined(c.languages));
        enum pinned = chosen;
    }
}

/// String `k`, in the language being shown.
template text(size_t k)
{
    enum c = catalogue!();
    static if (pinned!() >= 0)
        enum string text = c.texts[k * c.languages.length + pinned!()];
    else
    {
        enum string[] row = c.texts[k * c.languages.length .. (k + 1) * c.languages.length];
        static immutable string[] texts = row;
        @property string text() { return texts[languageIndex!()()]; }
    }
}

/*
    Which of the catalogue's languages to show. Worked out the first time it's asked, and again
    after setLanguage; otherwise it's what it was, with nothing locked. Two threads asking at once
    the first time both work it out, the same.
*/
size_t languageIndex()() @trusted
{
    enum string[] all = catalogue!().languages;
    static immutable string[] languages = all;
    __gshared size_t index;
    static shared size_t workedOutFor; // the generation it was worked out for: 0 for none yet
    const now = atomicLoad!(MemoryOrder.acq)(generation);
    if (atomicLoad!(MemoryOrder.acq)(workedOutFor) != now)
    {
        const found = match(languages, preferredLanguages());
        index = found < 0 ? 0 : found;
        atomicStore!(MemoryOrder.rel)(workedOutFor, now);
    }
    return index;
}

shared size_t generation = 1;   // one more each time setLanguage changes what's wanted
__gshared string[] chosen;      // setLanguages'
__gshared bool overridden;

/// What strings.xml says: its languages, and every string in each of them.
struct Catalogue
{
    string[] languages;     /// The first, which every string's in, then the rest
    string[] ids;
    string[] texts;         /// String k in language l is texts[k * languages.length + l]
    size_t[] arity;         /// How many {n} each has to fill in
    string error;

    ptrdiff_t indexOf(string id) const pure nothrow @safe @nogc
    {
        foreach (i, n; ids)
            if (n == id)
                return i;
        return -1;
    }
}

/// The catalogue in strings.xml's text, or why it can't be read.
Catalogue compile(string xml, string file) pure @safe
{
    Catalogue c;
    try
    {
        const doc = parseXml(xml, file);
        const root = doc.root;
        if (root.name != "strings")
            fail(file, root.line, "the strings go in <strings>, not <" ~ root.name ~ ">");
        if (root.text.length)
            fail(file, root.line, "text in <strings> needs to be in a <string id=\"...\">");
        foreach (a; root.attributes)
            if (a.name != "languages")
                fail(file, root.line, "<strings> has no " ~ a.name);
        if (auto a = root.attribute("languages"))
        {
            foreach (t; words(a.value))
            {
                const l = checkedLanguage(t, file, root.line);
                foreach (seen; c.languages)
                    if (sameTag(seen, l))
                        fail(file, root.line, "languages=\"" ~ a.value ~ "\" has " ~ l ~ " twice");
                c.languages ~= l;
            }
            if (!c.languages.length)
                fail(file, root.line, "languages=\"\" needs at least one language, the one every string's in");
        }
        else
            c.languages = [defaultLanguage];
        const n = c.languages.length;
        const languageList = "<strings languages=\"" ~ joinedBy(c.languages, " ") ~ "\">";

        foreach (e; root.children)
        {
            if (e.name != "string")
                fail(file, e.line, "<" ~ e.name ~ "> can't go in <strings>: it holds <string id=\"...\">s");
            const idAttribute = e.attribute("id");
            if (!idAttribute)
                fail(file, e.line, "<string> needs an id=\"...\"");
            foreach (a; e.attributes)
                if (a.name != "id")
                    fail(file, e.line, "<string> has no " ~ a.name);
            const id = idAttribute.value;
            if (!isIdentifier(id))
                fail(file, e.line, "id=\"" ~ id ~ "\" isn't a name: it's letters, digits and _, not starting with a digit, "
                     ~ "as a D field's is");
            if (c.indexOf(id) >= 0)
                fail(file, e.line, "a second string with id=\"" ~ id ~ "\"");

            // Its text in each language: the first's for those it hasn't been translated into
            auto texts = new string[n];
            auto lines = new uint[n];
            if (e.children.length && e.text.length)
                fail(file, e.line, "<string id=\"" ~ id ~ "\"> has text and languages both: put the text in <"
                     ~ c.languages[0] ~ ">");
            if (!e.children.length)
            {
                texts[0] = unescaped(e.text, file, e.line);
                lines[0] = e.line;
            }
            foreach (t; e.children)
            {
                ptrdiff_t l = -1;
                foreach (i, language; c.languages)
                    if (sameTag(language, t.name))
                        l = i;
                if (l < 0)
                    fail(file, t.line, "<" ~ t.name ~ "> isn't one of the languages in " ~ languageList
                         ~ "; add it there to translate into it");
                if (lines[l])
                    fail(file, t.line, id ~ " is in " ~ c.languages[l] ~ " twice");
                if (t.attributes.length)
                    fail(file, t.line, "<" ~ t.name ~ "> holds a string's text, and has no " ~ t.attributes[0].name);
                if (t.children.length)
                    fail(file, t.line, "<" ~ t.name ~ "> holds text, not elements");
                texts[l] = unescaped(t.text, file, t.line);
                lines[l] = t.line;
            }
            if (!lines[0])
                fail(file, e.line, id ~ " isn't in " ~ c.languages[0] ~ ", the first language, which every string has "
                     ~ "to be in for those it isn't translated into");

            // Its {n}s: numbered from {0}, and the same in every language
            auto uses = placeholders(texts[0], file, lines[0]);
            uint highest;
            foreach (x; uses)
                highest = x > highest ? x : highest;
            foreach (i; 0 .. uses.length ? highest + 1 : 0)
                if (!isIn(cast(uint) i, uses))
                    fail(file, lines[0], id ~ " has {" ~ decimal(highest) ~ "} but no {" ~ decimal(i) ~ "}: they're "
                         ~ "numbered from {0}, one for each thing tr! is given");
            foreach (l; 1 .. n)
            {
                if (!lines[l])
                {
                    texts[l] = texts[0];
                    continue;
                }
                const u = placeholders(texts[l], file, lines[l]);
                if (!sameSet(u, uses))
                    fail(file, lines[l], id ~ " has " ~ listed(u) ~ " in " ~ c.languages[l] ~ ", and " ~ listed(uses) ~ " in "
                         ~ c.languages[0]);
            }

            c.ids ~= id;
            c.arity ~= uses.length;
            c.texts ~= texts;
        }
    }
    catch (XmlException e)
        c.error = e.msg;
    return c;
}

/*
    Which of `available` to show for the most wanted of `preferred` it can: the same language and
    region (fr-CA for fr-CA), else the language alone (fr), else the same language in any region
    (fr-CH). -1 if it has none of them.
*/
ptrdiff_t match(const string[] available, const string[] preferred) pure nothrow @safe
{
    foreach (p; preferred)
    {
        foreach (i, a; available)
            if (sameTag(a, p))
                return i;
        foreach (i, a; available)
            if (sameTag(a, primary(p)))
                return i;
        foreach (i, a; available)
            if (sameTag(primary(a), primary(p)))
                return i;
    }
    return -1;
}

/// The languages in a locale's environment variables, as gettext reads them, as BCP 47 names.
string[] languagesFrom(string language, string lcAll, string lcMessages, string lang) pure @safe
{
    string[] result;
    // $LANGUAGE is a list, but means nothing in the C locale, as gettext has it
    const locale = lcAll.length ? lcAll : lcMessages.length ? lcMessages : lang;
    if (tagOf(locale).length || locale == "")
        foreach (l; split(language, ':'))
            if (auto t = tagOf(l))
                result ~= t;
    if (auto t = tagOf(locale))
        result ~= t;
    return result;
}

/// `locale` -- fr_CA.UTF-8@euro -- as a BCP 47 name, fr-CA; null for C, POSIX or nothing.
string tagOf(string locale) pure @safe
{
    size_t end = locale.length;
    foreach (i, ch; locale)
        if (ch == '.' || ch == '@')
        {
            end = i;
            break;
        }
    const name = locale[0 .. end];
    if (name.length == 0 || name == "C" || name == "POSIX")
        return null;
    char[] t = name.dup;
    foreach (ref ch; t)
        if (ch == '_')
            ch = '-';
    return t.idup;
}

/// `text` with {0}, {1} and so on replaced by `args`.
string fill(string text, const string[] args) pure @safe
{
    string r;
    size_t i;
    while (i < text.length)
    {
        size_t n, end;
        if (text[i] == '{' && placeholderAt(text, i, n, end) && n < args.length)
        {
            r ~= args[n];
            i = end;
        }
        else
            r ~= text[i++];
    }
    return r;
}

string[] systemLanguages() @trusted
{
    // C's getenv rather than std.process, which isn't there for the browser build
    import core.stdc.stdlib : getenv;
    import core.stdc.string : strlen;
    static string variable(const(char)* name)
    {
        auto value = getenv(name);
        return value is null ? "" : value[0 .. strlen(value)].idup;
    }
    return languagesFrom(variable("LANGUAGE"), variable("LC_ALL"), variable("LC_MESSAGES"), variable("LANG"));
}

template idOf(string field, udas...)
{
    static if (is(typeof(udas[0]) == Localised) && udas[0].id.length)
        enum idOf = udas[0].id;
    else
        enum idOf = field; // @localised, or the type alone, @Localised
}

template isVersion(string identifier)
{
    mixin("version (" ~ identifier ~ ") enum isVersion = true; else enum isVersion = false;");
}

/// Whether `tag` is one of `candidates` picked already, so pinning fr isn't fr twice.
bool isIn(string tag, const int[] already, const string[] candidates) pure nothrow @safe
{
    foreach (j; already)
        if (sameTag(candidates[j], tag))
            return true;
    return false;
}

string joinedBy(const string[] list, string by) pure @safe
{
    string s;
    foreach (i, x; list)
        s ~= (i ? by : "") ~ x;
    return s;
}

/// "Did you mean" for a name that isn't there.
string missing(const Catalogue c, string id) pure @safe
{
    string best;
    size_t bestDistance = size_t.max;
    foreach (n; c.ids)
    {
        const d = distance(n, id);
        if (d < bestDistance)
        {
            best = n;
            bestDistance = d;
        }
    }
    return stringsFile ~ " has no string with id=\"" ~ id ~ "\""
         ~ (best.length && bestDistance <= 1 + id.length / 3 ? "; did you mean " ~ best ~ "?" : "");
}

/// How many letters to change, add or take away to make `a` into `b`.
size_t distance(string a, string b) pure @safe
{
    auto row = new size_t[b.length + 1];
    foreach (j; 0 .. row.length)
        row[j] = j;
    foreach (i; 0 .. a.length)
    {
        size_t diagonal = row[0];
        row[0] = i + 1;
        foreach (j; 0 .. b.length)
        {
            const above = row[j + 1];
            const replaced = diagonal + (a[i] == b[j] ? 0 : 1);
            row[j + 1] = min3(above + 1, row[j] + 1, replaced);
            diagonal = above;
        }
    }
    return row[b.length];
}

size_t min3(size_t a, size_t b, size_t c) pure nothrow @safe @nogc
{
    const ab = a < b ? a : b;
    return ab < c ? ab : c;
}

string checkedLanguage(string tag, string file, uint line) pure @safe
{
    // Letters and digits, in pieces separated by -: fr, en-GB, zh-Hans, es-419
    bool ok = tag.length && tag[0] != '-' && tag[$ - 1] != '-';
    foreach (i, ch; tag)
        if (!(isLetter(ch) || (ch >= '0' && ch <= '9') || (ch == '-' && tag[i - 1] != '-')))
            ok = false;
    if (ok)
        foreach (ch; primary(tag))
            if (!isLetter(ch))
                ok = false;
    if (!ok)
        fail(file, line, "\"" ~ tag ~ "\" isn't a language: name it as BCP 47 does, as in fr, en-GB or zh-Hans");
    return tag;
}

/// A string's text: runs of space made one, and \n, \t and \\ what they stand for.
string unescaped(string s, string file, uint line) pure @safe
{
    string r;
    bool space;
    for (size_t i = 0; i < s.length; i++)
    {
        const ch = s[i];
        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')
        {
            space = true;
            continue;
        }
        if (space && r.length)
            r ~= ' ';
        space = false;
        if (ch != '\\')
        {
            r ~= ch;
            continue;
        }
        if (++i == s.length)
            fail(file, line, "a \\ at the end of a string; \\\\ for a backslash");
        switch (s[i])
        {
            case 'n': r ~= '\n'; break;
            case 't': r ~= '\t'; break;
            case '\\': r ~= '\\'; break;
            default: fail(file, line, "\\" ~ s[i] ~ " isn't anything: \\n is a line break, \\t a tab, and \\\\ a backslash");
        }
    }
    return r;
}

/// The {n}s in `s`, each once.
uint[] placeholders(string s, string file, uint line) pure @safe
{
    uint[] r;
    foreach (i; 0 .. s.length)
    {
        size_t n, end;
        if (s[i] == '{' && placeholderAt(s, i, n, end))
        {
            if (n > 99)
                fail(file, line, "{" ~ decimal(n) ~ "} is more than a string has things to fill in");
            if (!isIn(cast(uint) n, r))
                r ~= cast(uint) n;
        }
    }
    return r;
}

/// Whether there's a {n} at `s[i]`: its number, and where it ends.
bool placeholderAt(string s, size_t i, out size_t n, out size_t end) pure nothrow @safe @nogc
{
    size_t j = i + 1;
    while (j < s.length && s[j] >= '0' && s[j] <= '9' && j - i < 6)
        n = n * 10 + (s[j++] - '0');
    if (j == i + 1 || j >= s.length || s[j] != '}')
        return false;
    end = j + 1;
    return true;
}

bool sameSet(const uint[] a, const uint[] b) pure nothrow @safe @nogc
{
    if (a.length != b.length)
        return false;
    foreach (x; a)
        if (!isIn(x, b))
            return false;
    return true;
}

/// "{0} {1}" for 2: what a string with `n` things to fill in has.
string slots(size_t n) pure @safe
{
    if (!n)
        return "nothing to fill in";
    string s;
    foreach (i; 0 .. n)
        s ~= (i ? " " : "") ~ "{" ~ decimal(i) ~ "}";
    return s;
}

string listed(const uint[] u) pure @safe
{
    if (!u.length)
        return "nothing to fill in";
    string s;
    foreach (i; 0 .. 100)
        if (isIn(cast(uint) i, u))
            s ~= (s.length ? " " : "") ~ "{" ~ decimal(i) ~ "}";
    return s;
}

/// Tags compared as BCP 47 does, without minding case: en-GB is en-gb.
bool sameTag(string a, string b) pure nothrow @safe @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
        if (lower(a[i]) != lower(b[i]))
            return false;
    return true;
}

/// The language of a tag, without its region or script: fr for fr-CA.
string primary(string tag) pure nothrow @safe @nogc
{
    foreach (i, ch; tag)
        if (ch == '-')
            return tag[0 .. i];
    return tag;
}

/// A tag as a version identifier: zh-Hans is zh_Hans.
string versionName(string tag) pure nothrow @safe
{
    char[] r = tag.dup;
    foreach (ref ch; r)
        if (ch == '-')
            ch = '_';
    return r.idup;
}

string[] words(string text) pure @safe
{
    string[] result;
    size_t start;
    foreach (i; 0 .. text.length + 1)
        if (i == text.length || text[i] == ' ' || text[i] == ',' || text[i] == '\n' || text[i] == '\t')
        {
            if (i > start)
                result ~= text[start .. i];
            start = i + 1;
        }
    return result;
}

string[] split(string s, char by) pure @safe
{
    string[] r;
    size_t start;
    foreach (i; 0 .. s.length + 1)
        if (i == s.length || s[i] == by)
        {
            if (i > start)
                r ~= s[start .. i];
            start = i + 1;
        }
    return r;
}

bool isIdentifier(string s) pure nothrow @safe @nogc
{
    if (!s.length || (s[0] >= '0' && s[0] <= '9'))
        return false;
    foreach (ch; s)
        if (!(isLetter(ch) || (ch >= '0' && ch <= '9') || ch == '_'))
            return false;
    return true;
}

bool isLetter(char ch) pure nothrow @safe @nogc { return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z'); }
char lower(char ch) pure nothrow @safe @nogc { return ch >= 'A' && ch <= 'Z' ? cast(char)(ch + 32) : ch; }

bool isIn(T)(T x, const T[] list) pure nothrow @safe @nogc
{
    foreach (y; list)
        if (x == y)
            return true;
    return false;
}

string joined(const string[] list) pure @safe
{
    string s;
    foreach (i, x; list)
        s ~= (i ? ", " : "") ~ x;
    return s;
}

string decimal(size_t n) pure nothrow @safe
{
    if (n == 0)
        return "0";
    char[20] buffer;
    size_t i = buffer.length;
    while (n)
    {
        buffer[--i] = cast(char)('0' + n % 10);
        n /= 10;
    }
    return buffer[i .. $].idup;
}

noreturn fail(string file, uint line, string message) pure @safe
{
    throw new XmlException(file ~ ":" ~ decimal(line) ~ ": " ~ message);
}

/// ISO 639-1's languages: what a MayfairLanguage_ version can name that the app hasn't got, to say so.
enum string[] isoLanguages = [
    "aa", "ab", "ae", "af", "ak", "am", "an", "ar", "as", "av", "ay", "az", "ba", "be", "bg", "bi", "bm", "bn", "bo",
    "br", "bs", "ca", "ce", "ch", "co", "cr", "cs", "cu", "cv", "cy", "da", "de", "dv", "dz", "ee", "el", "en", "eo",
    "es", "et", "eu", "fa", "ff", "fi", "fj", "fo", "fr", "fy", "ga", "gd", "gl", "gn", "gu", "gv", "ha", "he", "hi",
    "ho", "hr", "ht", "hu", "hy", "hz", "ia", "id", "ie", "ig", "ii", "ik", "io", "is", "it", "iu", "ja", "jv", "ka",
    "kg", "ki", "kj", "kk", "kl", "km", "kn", "ko", "kr", "ks", "ku", "kv", "kw", "ky", "la", "lb", "lg", "li", "ln",
    "lo", "lt", "lu", "lv", "mg", "mh", "mi", "mk", "ml", "mn", "mr", "ms", "mt", "my", "na", "nb", "nd", "ne", "ng",
    "nl", "nn", "no", "nr", "nv", "ny", "oc", "oj", "om", "or", "os", "pa", "pi", "pl", "ps", "pt", "qu", "rm", "rn",
    "ro", "ru", "rw", "sa", "sc", "sd", "se", "sg", "si", "sk", "sl", "sm", "sn", "so", "sq", "sr", "ss", "st", "su",
    "sv", "sw", "ta", "te", "tg", "th", "ti", "tk", "tl", "tn", "to", "tr", "ts", "tt", "tw", "ty", "ug", "uk", "ur",
    "uz", "ve", "vi", "vo", "wa", "wo", "xh", "yi", "yo", "za", "zh", "zu",
];

unittest
{
    enum xml = `<?xml version="1.0"?>
<strings languages="en-GB fr zh-Hans">
    <string id="hello">
        <en-GB>Hello</en-GB>
        <fr>Bonjour</fr>
        <zh-Hans>你好</zh-Hans>
    </string>
    <string id="welcome">
        <en-GB>Welcome back,
            {0}</en-GB>
    </string>
    <string id="moved">
        <en-GB>{0} moved {1} files to {0}</en-GB>
        <fr>{1} fichiers déplacés vers {0}</fr>
    </string>
    <string id="lines">One\nTwo \\ three</string>
</strings>`;

    enum c = compile(xml, "strings.xml");
    static assert(c.error is null, c.error);
    static assert(c.languages == ["en-GB", "fr", "zh-Hans"]);
    static assert(c.ids == ["hello", "welcome", "moved", "lines"]);
    static assert(c.arity == [0, 1, 2, 0]);
    static assert(c.texts[0 .. 3] == ["Hello", "Bonjour", "你好"]);
    static assert(c.texts[3 .. 6] == ["Welcome back, {0}", "Welcome back, {0}", "Welcome back, {0}"]); // not translated
    static assert(c.texts[7] == "{1} fichiers déplacés vers {0}");
    static assert(c.texts[9 .. 12] == ["One\nTwo \\ three", "One\nTwo \\ three", "One\nTwo \\ three"]);
    assert(fill(c.texts[7], ["Documents", "3"]) == "3 fichiers déplacés vers Documents");
    assert(fill("{0} and {1} and {2} and {x}", ["a", "b"]) == "a and b and {2} and {x}");

    // An app that isn't translated: no languages, and each string's text on its own
    enum plain = compile(`<strings><string id="hi">Hi</string></strings>`, "strings.xml");
    static assert(plain.error is null && plain.languages == ["en-GB"] && plain.texts == ["Hi"]);

    // Mistakes, at the line they're on
    static string error(string xml) { return compile(xml, "strings.xml").error; }
    static assert(error(`<strings languages="en-GB fr">
    <string id="hello"><en-GB>Hello</en-GB>
        <fe>Bonjour</fe></string>
</strings>`) == `strings.xml:3: <fe> isn't one of the languages in <strings languages="en-GB fr">; add it there to `
                ~ `translate into it`);
    static assert(error(`<strings languages="en-GB fr">
    <string id="hello"><fr>Bonjour</fr></string>
</strings>`) == "strings.xml:2: hello isn't in en-GB, the first language, which every string has to be in for those it "
                ~ "isn't translated into");
    static assert(error(`<strings><string id="a">x</string><string id="a">y</string></strings>`)
                  == `strings.xml:1: a second string with id="a"`);
    static assert(error(`<strings><string id="a">{1}</string></strings>`)
                  == "strings.xml:1: a has {1} but no {0}: they're numbered from {0}, one for each thing tr! is given");
    static assert(error(`<strings languages="en-GB fr">
<string id="a">
    <en-GB>{0} x</en-GB>
    <fr>x</fr>
</string></strings>`) == "strings.xml:4: a has nothing to fill in in fr, and {0} in en-GB");
    static assert(error(`<resources/>`) == "strings.xml:1: the strings go in <strings>, not <resources>");
    static assert(error(`<strings><string id="2a">x</string></strings>`).length);
    static assert(error(`<strings><string>x</string></strings>`).length);
    static assert(error(`<strings><string id="a">\q</string></strings>`).length);
    static assert(error(`<strings languages="fr fr"/>`).length);
    static assert(error(`<strings languages=""/>`).length);
    static assert(error(`<strings languages="f_r"/>`).length);
    static assert(error(`<strings><string id="a"><en-GB>x</en-GB><en-GB>y</en-GB></string></strings>`).length);
    static assert(error(`<strings><string id="a">x<en-GB>y</en-GB></string></strings>`).length);

    // Which language: exactly, then the language alone, then the language anywhere; then the first
    const available = ["en-GB", "fr", "pt-BR", "zh-Hans"];
    assert(match(available, ["fr-CA"]) == 1);
    assert(match(available, ["FR"]) == 1);
    assert(match(available, ["pt"]) == 2 && match(available, ["pt-PT"]) == 2);
    assert(match(available, ["en-US"]) == 0);
    assert(match(available, ["ja", "zh-CN", "fr"]) == 3);
    assert(match(available, ["ja"]) == -1 && match(available, []) == -1);

    // From the environment, as gettext reads it
    assert(languagesFrom("", "", "", "fr_CA.UTF-8") == ["fr-CA"]);
    assert(languagesFrom("de:fr", "", "", "en_GB.UTF-8") == ["de", "fr", "en-GB"]);
    assert(languagesFrom("", "pt_BR.UTF-8", "fr_FR.UTF-8", "en_GB.UTF-8") == ["pt-BR"]);
    assert(languagesFrom("", "", "fr_FR@euro", "en_GB.UTF-8") == ["fr-FR"]);
    assert(languagesFrom("de", "C", "", "") == []);  // the C locale: gettext ignores $LANGUAGE
    assert(languagesFrom("de", "", "", "") == ["de"]);
    assert(languagesFrom("", "", "", "POSIX") == []);
}
