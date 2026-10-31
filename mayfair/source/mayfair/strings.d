module mayfair.strings;

import std.meta : AliasSeq;
import std.traits : BaseClassesTuple, getUDAs, hasUDA;
import mayfair.xml.parser : Document, Element, XmlException, parseXml;

/*
    An app's text, in one language or many: Android's strings.xml, and what JavaFX's
    ResourceBundle is to FXML's `%key`. Every string is read and checked as the program's
    compiled; only which language to show is left for it to work out when it runs.

        resources/
            views/main.xml
            values/strings.xml          the strings, in UK English
            values-fr/strings.xml       the same strings in French
            values-de/strings.xml       ...and German
            values-zh/strings.xml       ...and Chinese

    with "resources" among dub's stringImportPaths. values/strings.xml has every string, and
    names the translations there are:

        <resources translations="fr de zh">
            <string name="hello">Hello</string>
            <string name="welcome">Welcome back, {0}</string>
        </resources>

    and each translation has whichever of them it's translated, by the same names:

        <!-- values-fr/strings.xml -->
        <resources>
            <string name="hello">Bonjour</string>
            <string name="welcome">Bon retour, {0}</string>
        </resources>

    A view puts one in with `%` and its name, as FXML does:

        <Label text="%hello"/>
        <Button>%hello</Button>             <!-- \% for text that starts with a % -->

    code has tr!, with what fills a string's {0}, {1} and so on:

        status.setText(tr!"welcome"(user.name));

    and a field can be marked to be filled with one, by its own name or the one given:

        @View("main.xml")
        class Main
        {
            @localised string hello;                    // the string called hello
            @Localised("welcome") string greeting;      // the one called welcome
        }

    View.load fills a controller's @localised fields before it builds the view, as it does
    @autowired ones, and those of the app's own widgets a view makes; anything else made with
    `new` is filled in by localise(), which returns it: `auto page = localise(new Page)`.

    Each of these is a compile error, at the line it's on: a name that isn't in
    values/strings.xml, a translation of a string that isn't there, a translation whose {0}s
    aren't the ones the original has, a string with {0}s in a view, which has nothing to fill
    them, or tr! given more or fewer than it has. A string a translation leaves out is shown as
    values/strings.xml has it, as Android does.

    Which language
    --------------
    The one the person running the app has asked for, as gettext works it out: the languages in
    $LANGUAGE (fr:de), then the one in $LC_ALL, $LC_MESSAGES or $LANG (fr_CA.UTF-8). In the
    browser that's the browser's language, which Emscripten puts in $LANG. The first of these
    the app has a translation for is the one shown -- fr-CA if it has that, else fr, else any
    French -- and if it has none of them, values/strings.xml's. Try one with
    `LANGUAGE=fr ./app`, or setLanguage("fr") before the views are loaded.

    Or the language can be chosen as the program's compiled, so it has only that one in it and
    every string's a constant -- a build for one market, say -- with a version naming it:

        dub build --d-version=MayfairLanguage_fr
        dub build --d-version=MayfairLanguage_zh_CN    (a - in its name is a _)

    or `"versions": ["MayfairLanguage_fr"]` in a dub configuration of the app's own. One for a
    language the app has no translation of is a compile error.

    Language names are BCP 47's, as in values-fr, values-pt-BR and values-zh-Hans: two letters
    for the language (Chinese is zh, German de), then a region or script if it matters.
    values/strings.xml is in UK English unless its <resources> says otherwise with
    language="...".

    What's in a string: its text, with the space at its ends trimmed and any run of spaces and
    line breaks inside it made one space, as Android does; \n for a line break, \t a tab, and
    \\ a backslash. {0} to {9} and up are filled in by tr!'s arguments, in order, and can be in
    a different order in a translation.

    Views made before the language changes keep the text they were made with: load them again
    to show it in the new one, as JavaFX's FXMLLoader needs.
*/

/// Marks a string field to fill with the string of the same name, from values/strings.xml.
enum localised = Localised.init;

/// ditto. `@Localised("welcome")` fills it with the string called welcome.
struct Localised
{
    string name;
}

/// The string called `name`, in the language being shown, with its {0}, {1}... filled in from `args`.
string tr(string name, Args...)(Args args)
{
    enum c = catalogue!();
    enum k = c.indexOf(name);
    static if (k < 0)
        static assert(false, missing(c, name));
    else static if (Args.length != c.arity[k])
        static assert(false, stringsFile ~ "'s " ~ name ~ " has " ~ slots(c.arity[k]) ~ ", and tr!\"" ~ name ~ "\" was given "
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

/// The language strings are being shown in: a BCP 47 tag, as in "fr" or "en-GB".
string currentLanguage()()
{
    enum c = catalogue!();
    static if (pinned!() >= 0)
        return c.languages[pinned!()];
    else
    {
        enum string[] all = c.languages;
        static immutable string[] languages = all;
        return languages[languageFor(languages)];
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
                    enum name = nameOf!(__traits(identifier, B.tupleof[i]), getUDAs!(B.tupleof[i], Localised));
                    static assert(is(typeof(B.tupleof[i]) : const(char)[]),
                                  field ~ " is @localised, so it has to be a string, not " ~ typeof(B.tupleof[i]).stringof);
                    enum c = catalogue!();
                    enum k = c.indexOf(name);
                    static if (k < 0)
                        static assert(false, field ~ " is @localised, but " ~ missing(c, name));
                    else static if (c.arity[k])
                        static assert(false, field ~ " is @localised, but " ~ stringsFile ~ "'s " ~ name
                                      ~ " has {n} to fill in; set it with tr!\"" ~ name ~ "\"(...) instead");
                    else
                        (cast(B) target).tupleof[i] = .text!k;
                }
            }}
        }
    }
    return target;
}

/// Shows strings in `language`, or the first of `languages` there's a translation of, from now on.
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
        cachedFor = null;
    }
}

/// The languages the person running the app has asked for, most wanted first, as BCP 47 tags.
string[] preferredLanguages() @trusted
{
    synchronized
        return overridden ? chosen.dup : systemLanguages();
}

/// The string a view's `%name` stands for. Public for the code views generate to call.
string resourceString(string name, string loc)()
{
    enum c = catalogue!();
    enum k = c.indexOf(name);
    static if (k < 0)
        static assert(false, loc ~ ": " ~ missing(c, name));
    else static if (c.arity[k])
        static assert(false, loc ~ ": " ~ stringsFile ~ "'s " ~ name ~ " has {n} to fill in, and a view has nothing to "
                      ~ "fill them with; set it from the controller with tr!\"" ~ name ~ "\"(...)");
    else
        return .text!k;
}

private:

/// The language values/strings.xml is in unless it says otherwise.
enum defaultLanguage = "en-GB";

/// Where the strings are, among the string imports.
enum stringsFile = "values/strings.xml";

/// Where a translation's strings are: values-fr/strings.xml for fr.
string translationFile(string language) pure nothrow @safe
{
    return "values-" ~ language ~ "/strings.xml";
}

/*
    The strings, read as the program's compiled. A template, so the files are looked for with
    the app's string imports, not Mayfair's, and only once something asks for a string.
*/
template catalogue()
{
    static assert(__traits(compiles, import(stringsFile)), "there's no " ~ stringsFile ~ " for the app's strings: make one "
                  ~ "in resources/values, with resources among the stringImportPaths in dub.json");
    enum Header header = readHeader(import(stringsFile), stringsFile);
    static assert(header.error is null, header.error);
    static foreach (t; header.translations)
        static assert(__traits(compiles, import(translationFile(t))),
                      stringsFile ~ " says there's a " ~ t ~ " translation, but there's no " ~ translationFile(t));
    enum Catalogue read = compile(import(stringsFile), stringsFile, translationTexts!(header.translations));
    static assert(read.error is null, read.error);
    enum Catalogue catalogue = read;
}

/// The text of translation files, by their languages.
template translationTexts(string[] languages)
{
    enum string[] translationTexts = () {
        string[] r;
        static foreach (l; languages)
            r ~= import(translationFile(l));
        return r;
    }();
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
                      ~ versionName(candidates[found[0]]) ~ "), but there's no " ~ translationFile(candidates[found[0]])
                      ~ " or translation like it; " ~ stringsFile ~ " has " ~ joined(c.languages));
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
        enum string[] all = c.languages;
        static immutable string[] languages = all;
        @property string text() { return texts[languageFor(languages)]; }
    }
}

/// What values/strings.xml says before its strings: its language, and the translations there are.
struct Header
{
    string language;
    string[] translations;
    string error;
}

/// Every string, in every language, in a table: `texts[k * languages.length + l]` is string k in language l.
struct Catalogue
{
    string[] languages;     /// The default first, then the translations
    string[] names;
    string[] texts;
    size_t[] arity;         /// How many {n} each has to fill in
    string error;

    ptrdiff_t indexOf(string name) const pure nothrow @safe @nogc
    {
        foreach (i, n; names)
            if (n == name)
                return i;
        return -1;
    }
}

Header readHeader(string xml, string file) pure @safe
{
    Header h;
    try
    {
        const doc = parseXml(xml, file);
        checkRoot(doc, file, true);
        h.language = defaultLanguage;
        if (auto a = doc.root.attribute("language"))
            h.language = checkedLanguage(a.value, file, doc.root.line);
        if (auto a = doc.root.attribute("translations"))
            foreach (t; words(a.value))
            {
                const l = checkedLanguage(t, file, doc.root.line);
                if (l == h.language || isIn(l, h.translations))
                    fail(file, doc.root.line, "translations=\"" ~ a.value ~ "\" has " ~ l ~ " twice, or as well as "
                         ~ "language=\"" ~ h.language ~ "\"");
                h.translations ~= l;
            }
    }
    catch (XmlException e)
        h.error = e.msg;
    return h;
}

/// The catalogue from values/strings.xml's text and its translations', in the order its header names them.
Catalogue compile(string xml, string file, string[] translations) pure @safe
{
    Catalogue c;
    try
    {
        auto header = readHeader(xml, file);
        if (header.error)
            throw new XmlException(header.error);
        c.languages = header.language ~ header.translations;
        const n = c.languages.length;
        uint[][] uses; // the {n} each string has, as the default has them

        const doc = parseXml(xml, file);
        foreach (e; doc.root.children)
        {
            const name = checkedString(e, file);
            if (c.indexOf(name) >= 0)
                fail(file, e.line, "a second string called " ~ name);
            const s = unescaped(e.text, file, e.line);
            auto u = placeholders(s, file, e.line);
            uint highest;
            foreach (x; u)
                highest = x > highest ? x : highest;
            foreach (i; 0 .. u.length ? highest + 1 : 0)
                if (!isIn(cast(uint) i, u))
                    fail(file, e.line, name ~ " has {" ~ decimal(highest) ~ "} but no {" ~ decimal(i) ~ "}: they're "
                         ~ "numbered from {0}, one for each thing tr! is given");
            c.names ~= name;
            c.arity ~= u.length;
            uses ~= u;
            foreach (l; 0 .. n)
                c.texts ~= s; // until a translation has its own
        }

        foreach (t, tx; translations)
        {
            const tfile = translationFile(header.translations[t]);
            const tdoc = parseXml(tx, tfile);
            checkRoot(tdoc, tfile, false);
            if (auto a = tdoc.root.attribute("language"))
                if (a.value != header.translations[t])
                    fail(tfile, tdoc.root.line, "language=\"" ~ a.value ~ "\" in a file for " ~ header.translations[t]);
            string[] seen;
            foreach (e; tdoc.root.children)
            {
                const name = checkedString(e, tfile);
                const k = c.indexOf(name);
                if (k < 0)
                    fail(tfile, e.line, missing(c, name));
                if (isIn(name, seen))
                    fail(tfile, e.line, "a second string called " ~ name);
                seen ~= name;
                const s = unescaped(e.text, tfile, e.line);
                const u = placeholders(s, tfile, e.line);
                if (!sameSet(u, uses[k]))
                    fail(tfile, e.line, name ~ " has " ~ listed(u) ~ ", and in " ~ file ~ " it has " ~ listed(uses[k]));
                c.texts[k * n + 1 + t] = s;
            }
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

/// The languages in a locale's environment variables, as gettext reads them, as BCP 47 tags.
string[] languagesFrom(string language, string lcAll, string lcMessages, string lang) pure @safe
{
    string[] result;
    // $LANGUAGE is a list, but only means anything when there's a locale, as gettext has it
    const locale = lcAll.length ? lcAll : lcMessages.length ? lcMessages : lang;
    if (tagOf(locale).length || locale == "")
        foreach (l; split(language, ':'))
            if (auto t = tagOf(l))
                result ~= t;
    if (auto t = tagOf(locale))
        result ~= t;
    return result;
}

/// `locale` -- fr_CA.UTF-8@euro -- as a BCP 47 tag, fr-CA; null for C, POSIX or nothing.
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

__gshared string[] chosen;          // setLanguages'
__gshared bool overridden;
__gshared const(string)[] cachedFor; // the languages an app has, for which...
__gshared size_t cachedIndex;        // ...this is the one to show

/// Which of `available` to show, `available[0]` being the default. Worked out once, until setLanguage.
size_t languageFor(const string[] available) @trusted
{
    synchronized
    {
        if (cachedFor !is null && cachedFor == available)
            return cachedIndex;
        const wanted = overridden ? chosen : systemLanguages();
        const found = match(available, wanted);
        cachedFor = available.dup;
        cachedIndex = found < 0 ? 0 : found;
        return cachedIndex;
    }
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

template nameOf(string field, udas...)
{
    static if (is(typeof(udas[0]) == Localised) && udas[0].name.length)
        enum nameOf = udas[0].name;
    else
        enum nameOf = field; // @localised, or the type alone, @Localised
}

template isVersion(string identifier)
{
    mixin("version (" ~ identifier ~ ") enum isVersion = true; else enum isVersion = false;");
}

/// Whether candidates[i] matches one of `already`'s, so pinning fr isn't fr twice.
bool isIn(string tag, const int[] already, const string[] candidates) pure nothrow @safe
{
    foreach (j; already)
        if (sameTag(candidates[j], tag))
            return true;
    return false;
}

/// "Did you mean" for a name that isn't there.
string missing(const Catalogue c, string name) pure @safe
{
    string best;
    size_t bestDistance = size_t.max;
    foreach (n; c.names)
    {
        const d = distance(n, name);
        if (d < bestDistance)
        {
            best = n;
            bestDistance = d;
        }
    }
    return stringsFile ~ " has no string called " ~ name
         ~ (best.length && bestDistance <= 1 + name.length / 3 ? "; did you mean " ~ best ~ "?" : "");
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

void checkRoot(const Document doc, string file, bool isDefault) pure @safe
{
    if (doc.root.name != "resources")
        fail(file, doc.root.line, "the strings go in <resources>, not <" ~ doc.root.name ~ ">");
    if (doc.root.text.length)
        fail(file, doc.root.line, "text in <resources> needs to be in a <string name=\"...\">");
    foreach (a; doc.root.attributes)
        if (a.name != "language" && (a.name != "translations" || !isDefault))
            fail(file, doc.root.line, "<resources> has no " ~ a.name ~ (a.name == "translations"
                 ? "; the translations there are are named in " ~ stringsFile : ""));
}

/// The name of a <string> element, checked.
string checkedString(const Element e, string file) pure @safe
{
    if (e.name != "string")
        fail(file, e.line, "<" ~ e.name ~ "> can't go in <resources>: it holds <string name=\"...\">s");
    const name = e.attribute("name");
    if (!name)
        fail(file, e.line, "<string> needs a name=\"...\"");
    foreach (a; e.attributes)
        if (a.name != "name")
            fail(file, e.line, "<string> has no " ~ a.name);
    if (e.children.length)
        fail(file, e.line, "<string name=\"" ~ name.value ~ "\"> holds text, not elements");
    if (!isIdentifier(name.value))
        fail(file, e.line, "name=\"" ~ name.value ~ "\" isn't a name: it's letters, digits and _, not starting with a digit, "
             ~ "as a D field's is");
    return name.value;
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
<resources translations="fr zh-Hans">
    <string name="hello">Hello</string>
    <string name="welcome">Welcome back,
        {0}</string>
    <string name="moved">{0} moved {1} files to {0}</string>
    <string name="lines">One\nTwo \\ three</string>
</resources>`;
    enum fr = `<resources>
    <string name="hello">Bonjour</string>
    <string name="moved">{1} fichiers déplacés vers {0}</string>
</resources>`;
    enum zh = `<resources language="zh-Hans"><string name="hello">你好</string></resources>`;

    enum c = compile(xml, "values/strings.xml", [fr, zh]);
    static assert(c.error is null, c.error);
    static assert(c.languages == ["en-GB", "fr", "zh-Hans"]);
    static assert(c.names == ["hello", "welcome", "moved", "lines"]);
    static assert(c.arity == [0, 1, 2, 0]);
    static assert(c.texts[0 .. 3] == ["Hello", "Bonjour", "你好"]);
    static assert(c.texts[3 .. 6] == ["Welcome back, {0}", "Welcome back, {0}", "Welcome back, {0}"]); // not translated
    static assert(c.texts[7] == "{1} fichiers déplacés vers {0}");
    static assert(c.texts[9] == "One\nTwo \\ three");
    assert(fill(c.texts[7], ["Documents", "3"]) == "3 fichiers déplacés vers Documents");
    assert(fill("{0} and {1} and {2} and {x}", ["a", "b"]) == "a and b and {2} and {x}");

    // Mistakes, at the file and line they're on
    static string error(string xml, string[] translations...) { return compile(xml, "values/strings.xml", translations).error; }
    enum two = `<resources translations="fr">
    <string name="hello">Hello</string>
    <string name="name">Name</string>
</resources>`;
    static assert(error(two, `<resources><string name="helo">Bonjour</string></resources>`)
                  == "values-fr/strings.xml:1: values/strings.xml has no string called helo; did you mean hello?");
    static assert(error(`<resources><string name="a">{0}</string><string name="a">x</string></resources>`)
                  == "values/strings.xml:1: a second string called a");
    static assert(error(`<resources><string name="a">{1}</string></resources>`)
                  == "values/strings.xml:1: a has {1} but no {0}: they're numbered from {0}, one for each thing tr! is given");
    static assert(error(`<resources translations="fr">
<string name="a">{0} x</string></resources>`, `<resources><string name="a">x</string></resources>`)
                  == "values-fr/strings.xml:1: a has nothing to fill in, and in values/strings.xml it has {0}");
    static assert(error(`<strings/>`) == "values/strings.xml:1: the strings go in <resources>, not <strings>");
    static assert(error(`<resources><string name="2a">x</string></resources>`).length);
    static assert(error(`<resources><string>x</string></resources>`).length);
    static assert(error(`<resources><string name="a">\q</string></resources>`).length);
    static assert(error(`<resources translations="fr fr"/>`).length);
    static assert(error(`<resources translations="en-GB"/>`).length);
    static assert(error(`<resources translations="f_r"/>`).length);
    static assert(error(`<resources translations="fr"/>`, `<resources translations="de"/>`).length);
    static assert(error(`<resources translations="fr"/>`, `<resources language="de"/>`).length);

    // Which language: exactly, then the language alone, then the language anywhere; then the default
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
