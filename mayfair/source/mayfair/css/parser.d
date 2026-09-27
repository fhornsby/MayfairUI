module mayfair.css.parser;

import mayfair.css.value;
import mayfair.theme : Colour;

/*
    A stylesheet, parsed. Mayfair's CSS is CSS 2.1's syntax, with property names of its own --
    the web's where the web has one, spelt the British way (`colour`, `background-colour`) -- and
    the web's custom properties for a theme's palette: `--accent: #0284c7` declares one, and
    `var(--accent)` uses it.

        .button:hover > .label, #save { colour: derive(var(--base), 20%); }

    The parser is plain D with no side effects, so it runs at compile time: a stylesheet written
    into the program (see stylesheet!()) is parsed while it's being compiled, a mistake in it is a
    compile error, and what's left in the program is this data. The same code parses at runtime,
    for a style string an app builds as it goes (Widget.style).

    What's understood: type, #id, .class and :pseudo-class selectors, the universal *, the
    descendant and child (>) combinators, selector lists, !important, comments, and @media
    (prefers-colour-scheme: dark | light). Anything else is an error: better to hear about a rule
    that can never apply than to wonder why it doesn't.
*/
struct StylesheetData
{
    Rule[] rules;
}

struct Rule
{
    Selector[] selectors;
    Declaration[] declarations;
    Media media;          /// Which colour scheme it's for, if only one
}

enum Media : ubyte { all, dark, light }

struct Declaration
{
    string property;
    Value value;
    bool important;
}

/// A selector: its compound parts, left to right, and what joins each to the next.
struct Selector
{
    Compound[] parts;
    Combinator[] combinators; /// One fewer than there are parts
    uint specificity;         /// CSS's: ids, then classes and pseudo-classes, then types, a byte each
}

enum Combinator : ubyte { descendant, child }

/// One element's worth of selector: `Button#save.primary:hover`.
struct Compound
{
    string type;              /// Empty for any, as * says
    string id;
    string[] classes;
    string[] pseudoClasses;
}

/// Thrown for a stylesheet that can't be parsed, with where. At compile time, a compile error.
class CssException : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(message, file, line);
    }
}

/// Parses a whole stylesheet.
StylesheetData parseStylesheet(string css) pure @safe
{
    auto p = Parser(css);
    StylesheetData sheet;
    p.rules(sheet.rules, Media.all, false);
    return sheet;
}

/// Parses the declarations of an inline style: what goes between the braces, without them.
Declaration[] parseDeclarations(string css) pure @safe
{
    auto p = Parser(css);
    auto declarations = p.declarations(false);
    p.skipSpace();
    if (!p.atEnd)
        p.fail("expected a declaration");
    return declarations;
}

private:

struct Parser
{
    string s;
    size_t at;
    bool inVar; // parsing var()'s arguments

    bool atEnd() const pure nothrow @safe @nogc { return at >= s.length; }
    char peek(size_t ahead = 0) const pure nothrow @safe @nogc { return at + ahead < s.length ? s[at + ahead] : '\0'; }

    noreturn fail(string what) const pure @safe
    {
        size_t line = 1, column = 1;
        foreach (c; s[0 .. at < s.length ? at : s.length])
        {
            if (c == '\n') { line++; column = 1; }
            else column++;
        }
        throw new CssException("CSS, line " ~ decimal(line) ~ ", column " ~ decimal(column) ~ ": " ~ what);
    }

    void skipSpace() pure @safe
    {
        while (!atEnd)
        {
            if (isSpace(peek()))
                at++;
            else if (peek() == '/' && peek(1) == '*')
            {
                at += 2;
                while (!atEnd && !(peek() == '*' && peek(1) == '/'))
                    at++;
                if (atEnd)
                    fail("a comment that never ends");
                at += 2;
            }
            else
                break;
        }
    }

    void expect(char c) pure @safe
    {
        skipSpace();
        if (peek() != c)
            fail("expected '" ~ c ~ "'");
        at++;
    }

    // Rules until the end, or a closing brace if `nested`
    void rules(ref Rule[] into, Media media, bool nested) pure @safe
    {
        while (true)
        {
            skipSpace();
            if (atEnd)
            {
                if (nested)
                    fail("a block that never ends");
                return;
            }
            if (peek() == '}')
            {
                if (!nested)
                    fail("a '}' with nothing to close");
                at++;
                return;
            }
            if (peek() == '@')
            {
                atRule(into);
                continue;
            }
            Rule rule;
            rule.media = media;
            rule.selectors = selectorList();
            expect('{');
            rule.declarations = declarations(true);
            expect('}');
            into ~= rule;
        }
    }

    // @media (prefers-colour-scheme: dark) { ... }: the one media query there's a use for
    void atRule(ref Rule[] into) pure @safe
    {
        at++;
        const keyword = identifier();
        if (keyword != "media")
            fail("@" ~ keyword ~ " isn't supported: only @media (prefers-colour-scheme: ...)");
        expect('(');
        skipSpace();
        const feature = identifier();
        if (feature == "prefers-color-scheme")
            fail("it's spelt prefers-colour-scheme here");
        if (feature != "prefers-colour-scheme")
            fail("only @media (prefers-colour-scheme: ...) is supported");
        expect(':');
        skipSpace();
        const scheme = identifier();
        Media media;
        if (scheme == "dark")
            media = Media.dark;
        else if (scheme == "light")
            media = Media.light;
        else
            fail("prefers-colour-scheme is dark or light, not " ~ scheme);
        expect(')');
        expect('{');
        rules(into, media, true);
    }

    Selector[] selectorList() pure @safe
    {
        Selector[] list;
        while (true)
        {
            list ~= selector();
            skipSpace();
            if (peek() != ',')
                return list;
            at++;
        }
    }

    Selector selector() pure @safe
    {
        Selector sel;
        skipSpace();
        sel.parts ~= compound();
        while (true)
        {
            const before = at;
            skipSpace();
            const spaced = at > before;
            if (peek() == '>')
            {
                at++;
                skipSpace();
                sel.combinators ~= Combinator.child;
                sel.parts ~= compound();
            }
            else if (spaced && startsCompound(peek()))
            {
                sel.combinators ~= Combinator.descendant;
                sel.parts ~= compound();
            }
            else
                break;
        }
        foreach (part; sel.parts)
        {
            if (part.id.length)
                sel.specificity += 1 << 16;
            sel.specificity += cast(uint)(part.classes.length + part.pseudoClasses.length) << 8;
            if (part.type.length)
                sel.specificity += 1;
        }
        return sel;
    }

    static bool startsCompound(char c) pure nothrow @safe @nogc
    {
        return c == '*' || c == '.' || c == '#' || c == ':' || isNameStart(c);
    }

    Compound compound() pure @safe
    {
        Compound c;
        bool any;
        if (peek() == '*')
        {
            at++;
            any = true;
        }
        else if (isNameStart(peek()))
        {
            c.type = identifier();
            any = true;
        }
        while (true)
        {
            const k = peek();
            if (k == '.')
            {
                at++;
                c.classes ~= identifier();
            }
            else if (k == '#')
            {
                at++;
                if (c.id.length)
                    fail("a selector with two ids");
                c.id = identifier();
            }
            else if (k == ':')
            {
                at++;
                c.pseudoClasses ~= identifier();
            }
            else
                break;
            any = true;
        }
        if (!any)
            fail("expected a selector");
        return c;
    }

    // Declarations up to a '}' (left for the caller) or the end
    Declaration[] declarations(bool inBlock) pure @safe
    {
        Declaration[] list;
        while (true)
        {
            skipSpace();
            if (atEnd || peek() == '}')
            {
                if (atEnd && inBlock)
                    fail("a block that never ends");
                return list;
            }
            if (peek() == ';')
            {
                at++;
                continue;
            }
            Declaration d;
            d.property = identifier();
            expect(':');
            d.value = value(d.important);
            list ~= d;
            skipSpace();
            if (peek() == ';')
                at++;
            else if (!atEnd && peek() != '}')
                fail("expected ';' after " ~ d.property);
        }
    }

    // A declaration's value: space-separated terms in comma-separated groups, and !important
    Value value(out bool important) pure @safe
    {
        Value[] groups;
        Value[] terms;
        while (true)
        {
            skipSpace();
            const k = peek();
            if (atEnd || k == ';' || k == '}' || k == ')')
                break;
            if (k == '!')
            {
                at++;
                skipSpace();
                if (identifier() != "important")
                    fail("expected !important");
                important = true;
                continue;
            }
            if (k == ',')
            {
                at++;
                groups ~= join(terms);
                terms = null;
                continue;
            }
            terms ~= term();
        }
        if (!terms.length)
            fail(groups.length ? "a value that ends with a comma" : "a declaration with no value");
        groups ~= join(terms);
        if (groups.length == 1)
            return groups[0];
        Value v;
        v.kind = ValueKind.commas;
        v.items = groups;
        return v;
    }

    static Value join(Value[] terms) pure nothrow @safe
    {
        if (terms.length == 1)
            return terms[0];
        Value v;
        v.kind = ValueKind.list;
        v.items = terms;
        return v;
    }

    Value term() pure @safe
    {
        Value v;
        const k = peek();
        if (k == '#')
        {
            at++;
            const start = at;
            while (isHex(peek()))
                at++;
            v.kind = ValueKind.colour;
            v.colour = hexColour(s[start .. at]);
            return v;
        }
        if (k == '"' || k == '\'')
        {
            at++;
            const start = at;
            while (!atEnd && peek() != k)
                at++;
            if (atEnd)
                fail("a string that never ends");
            v.kind = ValueKind.text;
            v.name = s[start .. at];
            at++;
            return v;
        }
        if (isDigit(k) || k == '.' || ((k == '-' || k == '+') && (isDigit(peek(1)) || peek(1) == '.')))
            return number();
        if (isNameStart(k))
        {
            const name = identifier();
            if (peek() == '(')
            {
                at++;
                v.kind = ValueKind.function_;
                v.name = name;
                bool important;
                const wasInVar = inVar;
                inVar = name == "var"; // where a variable's name can be on its own
                auto args = value(important); // comma-separated, as a declaration's layers are
                inVar = wasInVar;
                if (important)
                    fail("!important inside " ~ name ~ "()");
                v.items = args.kind == ValueKind.commas ? args.items : [args];
                skipSpace();
                if (peek() != ')')
                    fail("expected ')' to close " ~ name ~ "(");
                at++;
                return fold(v);
            }
            Colour named;
            if (namedColour(name, named))
            {
                v.kind = ValueKind.colour;
                v.colour = named;
                return v;
            }
            if (name.length >= 2 && name[0 .. 2] == "--" && !inVar)
                fail("a variable is used as var(" ~ name ~ "), not on its own");
            v.kind = ValueKind.identifier;
            v.name = name;
            return v;
        }
        fail("unexpected '" ~ k ~ "'");
    }

    Value number() pure @safe
    {
        Value v;
        v.kind = ValueKind.number;
        const start = at;
        bool negative;
        if (peek() == '-' || peek() == '+')
        {
            negative = peek() == '-';
            at++;
        }
        double n = 0;
        while (isDigit(peek()))
            n = n * 10 + (s[at++] - '0');
        if (peek() == '.')
        {
            at++;
            double scale = 0.1;
            while (isDigit(peek()))
            {
                n += (s[at++] - '0') * scale;
                scale /= 10;
            }
        }
        if (at == start + (negative || s[start] == '+' ? 1 : 0))
            fail("expected a number");
        v.number = cast(float)(negative ? -n : n);
        if (peek() == '%')
        {
            at++;
            v.unit = Unit.percent;
        }
        else if (isNameStart(peek()))
        {
            const unit = identifier();
            switch (unit)
            {
                case "px": v.unit = Unit.px; break;
                case "em": v.unit = Unit.em; break;
                case "pt": v.unit = Unit.pt; break;
                case "ms": v.unit = Unit.ms; break;
                case "s": v.unit = Unit.s; break;
                case "deg": v.unit = Unit.deg; break;
                default: fail("unknown unit " ~ unit);
            }
        }
        return v;
    }

    // A name: letters, digits, '-' and '_', not starting with a digit
    string identifier() pure @safe
    {
        const start = at;
        if (!isNameStart(peek()))
            fail("expected a name");
        while (isNameChar(peek()))
            at++;
        return s[start .. at];
    }

    /*
        Works out a function now if its arguments are all literals: rgb() and friends always, and
        derive() and ladder() of a colour that's written out. Of a variable, they wait
        until they're applied (see mayfair.css.resolve).
    */
    Value fold(Value f) const pure @safe
    {
        Value colour(Colour c)
        {
            Value v;
            v.kind = ValueKind.colour;
            v.colour = c;
            return v;
        }
        float fraction(const Value v) // 50% or 0.5 alike
        {
            if (v.kind != ValueKind.number)
                fail(f.name ~ "() takes numbers");
            return v.unit == Unit.percent ? v.number / 100 : v.number;
        }
        float channelOf(const Value v) // 0-255, or a percentage of it
        {
            if (v.kind != ValueKind.number)
                fail(f.name ~ "() takes numbers");
            return v.unit == Unit.percent ? v.number * 2.55f : v.number;
        }
        ubyte clamp255(float x) { return cast(ubyte)(x < 0 ? 0 : x > 255 ? 255 : x + 0.5f); }

        switch (f.name)
        {
            case "rgb", "rgba":
                if (f.items.length != 3 && f.items.length != 4)
                    fail(f.name ~ "() takes three or four arguments");
                return colour(Colour(clamp255(channelOf(f.items[0])), clamp255(channelOf(f.items[1])),
                                     clamp255(channelOf(f.items[2])),
                                     f.items.length == 4 ? clamp255(fraction(f.items[3]) * 255) : 255));
            case "hsb", "hsba":
                if (f.items.length != 3 && f.items.length != 4)
                    fail(f.name ~ "() takes three or four arguments");
                return colour(fromHsb(f.items[0].number, fraction(f.items[1]), fraction(f.items[2]),
                                      f.items.length == 4 ? fraction(f.items[3]) : 1));
            case "derive":
                if (f.items.length != 2)
                    fail("derive() takes a colour and a percentage");
                if (f.items[0].kind == ValueKind.colour)
                    return colour(derive(f.items[0].colour, fraction(f.items[1])));
                return f;
            case "ladder":
                if (f.items.length < 2)
                    fail("ladder() takes a colour and stops");
                bool literal = f.items[0].kind == ValueKind.colour;
                foreach (stop; f.items[1 .. $])
                    literal = literal && stop.kind == ValueKind.list && stop.items.length == 2
                              && stop.items[0].kind == ValueKind.colour;
                if (!literal)
                    return f;
                Colour[] stops;
                float[] offsets;
                foreach (stop; f.items[1 .. $])
                {
                    stops ~= stop.items[0].colour;
                    offsets ~= fraction(stop.items[1]);
                }
                return colour(ladder(f.items[0].colour, stops, offsets));
            case "var":
                // var(--name), or var(--name, fallback): a theme variable, looked up where it's applied
                if (f.items.length < 1 || f.items.length > 2 || f.items[0].kind != ValueKind.identifier
                    || f.items[0].name.length < 3 || f.items[0].name[0 .. 2] != "--")
                    fail("var() takes a variable's name, like var(--accent), and optionally a fallback");
                return f;
            case "cubic-bezier", "steps":
                return f; // a transition's timing, which the transition works out
            default:
                fail("unknown function " ~ f.name ~ "()");
        }
    }

    Colour hexColour(string hex) const pure @safe
    {
        uint digit(char c) { return c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10; }
        ubyte pair(size_t i) { return cast(ubyte)(digit(hex[i]) * 16 + digit(hex[i + 1])); }
        ubyte single(size_t i) { return cast(ubyte)(digit(hex[i]) * 17); }
        switch (hex.length)
        {
            case 3: return Colour(single(0), single(1), single(2));
            case 4: return Colour(single(0), single(1), single(2), single(3));
            case 6: return Colour(pair(0), pair(2), pair(4));
            case 8: return Colour(pair(0), pair(2), pair(4), pair(6));
            default: fail("#" ~ hex ~ " isn't a colour: it takes 3, 4, 6 or 8 hex digits");
        }
    }
}

bool isSpace(char c) pure nothrow @safe @nogc { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'; }
bool isDigit(char c) pure nothrow @safe @nogc { return c >= '0' && c <= '9'; }
bool isHex(char c) pure nothrow @safe @nogc { return isDigit(c) || ((c | 0x20) >= 'a' && (c | 0x20) <= 'f'); }
bool isNameStart(char c) pure nothrow @safe @nogc { return (c | 0x20) >= 'a' && (c | 0x20) <= 'z' || c == '-' || c == '_'; }
bool isNameChar(char c) pure nothrow @safe @nogc { return isNameStart(c) || isDigit(c); }

string decimal(size_t n) pure nothrow @safe
{
    if (n == 0)
        return "0";
    string digits;
    for (; n; n /= 10)
        digits = cast(char)('0' + n % 10) ~ digits;
    return digits;
}

/// CSS's named colours, which JavaFX's are, and transparent.
bool namedColour(string name, out Colour c) pure nothrow @safe
{
    import std.ascii : toLower;
    char[32] lower;
    if (name.length > lower.length)
        return false;
    foreach (i, ch; name)
        lower[i] = toLower(ch);
    const key = lower[0 .. name.length];
    foreach (entry; colourNames)
    {
        if (entry.name == key)
        {
            c = entry.colour;
            return true;
        }
    }
    return false;
}

struct NamedColour { string name; Colour colour; }

static immutable NamedColour[] colourNames = [
    NamedColour("transparent", Colour(0, 0, 0, 0)),
    NamedColour("aliceblue", Colour(240, 248, 255)), NamedColour("antiquewhite", Colour(250, 235, 215)),
    NamedColour("aqua", Colour(0, 255, 255)), NamedColour("aquamarine", Colour(127, 255, 212)),
    NamedColour("azure", Colour(240, 255, 255)), NamedColour("beige", Colour(245, 245, 220)),
    NamedColour("bisque", Colour(255, 228, 196)), NamedColour("black", Colour(0, 0, 0)),
    NamedColour("blanchedalmond", Colour(255, 235, 205)), NamedColour("blue", Colour(0, 0, 255)),
    NamedColour("blueviolet", Colour(138, 43, 226)), NamedColour("brown", Colour(165, 42, 42)),
    NamedColour("burlywood", Colour(222, 184, 135)), NamedColour("cadetblue", Colour(95, 158, 160)),
    NamedColour("chartreuse", Colour(127, 255, 0)), NamedColour("chocolate", Colour(210, 105, 30)),
    NamedColour("coral", Colour(255, 127, 80)), NamedColour("cornflowerblue", Colour(100, 149, 237)),
    NamedColour("cornsilk", Colour(255, 248, 220)), NamedColour("crimson", Colour(220, 20, 60)),
    NamedColour("cyan", Colour(0, 255, 255)), NamedColour("darkblue", Colour(0, 0, 139)),
    NamedColour("darkcyan", Colour(0, 139, 139)), NamedColour("darkgoldenrod", Colour(184, 134, 11)),
    NamedColour("darkgray", Colour(169, 169, 169)), NamedColour("darkgreen", Colour(0, 100, 0)),
    NamedColour("darkgrey", Colour(169, 169, 169)), NamedColour("darkkhaki", Colour(189, 183, 107)),
    NamedColour("darkmagenta", Colour(139, 0, 139)), NamedColour("darkolivegreen", Colour(85, 107, 47)),
    NamedColour("darkorange", Colour(255, 140, 0)), NamedColour("darkorchid", Colour(153, 50, 204)),
    NamedColour("darkred", Colour(139, 0, 0)), NamedColour("darksalmon", Colour(233, 150, 122)),
    NamedColour("darkseagreen", Colour(143, 188, 143)), NamedColour("darkslateblue", Colour(72, 61, 139)),
    NamedColour("darkslategray", Colour(47, 79, 79)), NamedColour("darkslategrey", Colour(47, 79, 79)),
    NamedColour("darkturquoise", Colour(0, 206, 209)), NamedColour("darkviolet", Colour(148, 0, 211)),
    NamedColour("deeppink", Colour(255, 20, 147)), NamedColour("deepskyblue", Colour(0, 191, 255)),
    NamedColour("dimgray", Colour(105, 105, 105)), NamedColour("dimgrey", Colour(105, 105, 105)),
    NamedColour("dodgerblue", Colour(30, 144, 255)), NamedColour("firebrick", Colour(178, 34, 34)),
    NamedColour("floralwhite", Colour(255, 250, 240)), NamedColour("forestgreen", Colour(34, 139, 34)),
    NamedColour("fuchsia", Colour(255, 0, 255)), NamedColour("gainsboro", Colour(220, 220, 220)),
    NamedColour("ghostwhite", Colour(248, 248, 255)), NamedColour("gold", Colour(255, 215, 0)),
    NamedColour("goldenrod", Colour(218, 165, 32)), NamedColour("gray", Colour(128, 128, 128)),
    NamedColour("green", Colour(0, 128, 0)), NamedColour("greenyellow", Colour(173, 255, 47)),
    NamedColour("grey", Colour(128, 128, 128)), NamedColour("honeydew", Colour(240, 255, 240)),
    NamedColour("hotpink", Colour(255, 105, 180)), NamedColour("indianred", Colour(205, 92, 92)),
    NamedColour("indigo", Colour(75, 0, 130)), NamedColour("ivory", Colour(255, 255, 240)),
    NamedColour("khaki", Colour(240, 230, 140)), NamedColour("lavender", Colour(230, 230, 250)),
    NamedColour("lavenderblush", Colour(255, 240, 245)), NamedColour("lawngreen", Colour(124, 252, 0)),
    NamedColour("lemonchiffon", Colour(255, 250, 205)), NamedColour("lightblue", Colour(173, 216, 230)),
    NamedColour("lightcoral", Colour(240, 128, 128)), NamedColour("lightcyan", Colour(224, 255, 255)),
    NamedColour("lightgoldenrodyellow", Colour(250, 250, 210)), NamedColour("lightgray", Colour(211, 211, 211)),
    NamedColour("lightgreen", Colour(144, 238, 144)), NamedColour("lightgrey", Colour(211, 211, 211)),
    NamedColour("lightpink", Colour(255, 182, 193)), NamedColour("lightsalmon", Colour(255, 160, 122)),
    NamedColour("lightseagreen", Colour(32, 178, 170)), NamedColour("lightskyblue", Colour(135, 206, 250)),
    NamedColour("lightslategray", Colour(119, 136, 153)), NamedColour("lightslategrey", Colour(119, 136, 153)),
    NamedColour("lightsteelblue", Colour(176, 196, 222)), NamedColour("lightyellow", Colour(255, 255, 224)),
    NamedColour("lime", Colour(0, 255, 0)), NamedColour("limegreen", Colour(50, 205, 50)),
    NamedColour("linen", Colour(250, 240, 230)), NamedColour("magenta", Colour(255, 0, 255)),
    NamedColour("maroon", Colour(128, 0, 0)), NamedColour("mediumaquamarine", Colour(102, 205, 170)),
    NamedColour("mediumblue", Colour(0, 0, 205)), NamedColour("mediumorchid", Colour(186, 85, 211)),
    NamedColour("mediumpurple", Colour(147, 112, 219)), NamedColour("mediumseagreen", Colour(60, 179, 113)),
    NamedColour("mediumslateblue", Colour(123, 104, 238)), NamedColour("mediumspringgreen", Colour(0, 250, 154)),
    NamedColour("mediumturquoise", Colour(72, 209, 204)), NamedColour("mediumvioletred", Colour(199, 21, 133)),
    NamedColour("midnightblue", Colour(25, 25, 112)), NamedColour("mintcream", Colour(245, 255, 250)),
    NamedColour("mistyrose", Colour(255, 228, 225)), NamedColour("moccasin", Colour(255, 228, 181)),
    NamedColour("navajowhite", Colour(255, 222, 173)), NamedColour("navy", Colour(0, 0, 128)),
    NamedColour("oldlace", Colour(253, 245, 230)), NamedColour("olive", Colour(128, 128, 0)),
    NamedColour("olivedrab", Colour(107, 142, 35)), NamedColour("orange", Colour(255, 165, 0)),
    NamedColour("orangered", Colour(255, 69, 0)), NamedColour("orchid", Colour(218, 112, 214)),
    NamedColour("palegoldenrod", Colour(238, 232, 170)), NamedColour("palegreen", Colour(152, 251, 152)),
    NamedColour("paleturquoise", Colour(175, 238, 238)), NamedColour("palevioletred", Colour(219, 112, 147)),
    NamedColour("papayawhip", Colour(255, 239, 213)), NamedColour("peachpuff", Colour(255, 218, 185)),
    NamedColour("peru", Colour(205, 133, 63)), NamedColour("pink", Colour(255, 192, 203)),
    NamedColour("plum", Colour(221, 160, 221)), NamedColour("powderblue", Colour(176, 224, 230)),
    NamedColour("purple", Colour(128, 0, 128)), NamedColour("red", Colour(255, 0, 0)),
    NamedColour("rosybrown", Colour(188, 143, 143)), NamedColour("royalblue", Colour(65, 105, 225)),
    NamedColour("saddlebrown", Colour(139, 69, 19)), NamedColour("salmon", Colour(250, 128, 114)),
    NamedColour("sandybrown", Colour(244, 164, 96)), NamedColour("seagreen", Colour(46, 139, 87)),
    NamedColour("seashell", Colour(255, 245, 238)), NamedColour("sienna", Colour(160, 82, 45)),
    NamedColour("silver", Colour(192, 192, 192)), NamedColour("skyblue", Colour(135, 206, 235)),
    NamedColour("slateblue", Colour(106, 90, 205)), NamedColour("slategray", Colour(112, 128, 144)),
    NamedColour("slategrey", Colour(112, 128, 144)), NamedColour("snow", Colour(255, 250, 250)),
    NamedColour("springgreen", Colour(0, 255, 127)), NamedColour("steelblue", Colour(70, 130, 180)),
    NamedColour("tan", Colour(210, 180, 140)), NamedColour("teal", Colour(0, 128, 128)),
    NamedColour("thistle", Colour(216, 191, 216)), NamedColour("tomato", Colour(255, 99, 71)),
    NamedColour("turquoise", Colour(64, 224, 208)), NamedColour("violet", Colour(238, 130, 238)),
    NamedColour("wheat", Colour(245, 222, 179)), NamedColour("white", Colour(255, 255, 255)),
    NamedColour("whitesmoke", Colour(245, 245, 245)), NamedColour("yellow", Colour(255, 255, 0)),
    NamedColour("yellowgreen", Colour(154, 205, 50)),
];

unittest
{
    // At compile time, which is the point
    enum sheet = parseStylesheet(`
        /* a comment */
        .root { --base: #334155; --accent: rgb(56, 189, 248); }
        .button:hover > .label, #save { colour: derive(var(--base), 20%) !important; }
        Row.toolbar .button { padding: 4 8; background-colour: red, #fff8; }
        @media (prefers-colour-scheme: dark) { * { opacity: .5; } }
    `);
    static assert(sheet.rules.length == 4);
    static assert(sheet.rules[0].declarations[1].value.colour == Colour(56, 189, 248));

    // Specificity: `.button:hover > .label` is two classes and a pseudo-class; `#save` an id
    static assert(sheet.rules[1].selectors[0].specificity == 3 << 8);
    static assert(sheet.rules[1].selectors[0].combinators == [Combinator.child]);
    static assert(sheet.rules[1].selectors[1].specificity == 1 << 16);
    static assert(sheet.rules[1].declarations[0].important);
    static assert(sheet.rules[1].declarations[0].value.kind == ValueKind.function_); // of a lookup: later

    static assert(sheet.rules[2].selectors[0].parts[0].type == "Row");
    static assert(sheet.rules[2].selectors[0].combinators == [Combinator.descendant]);
    static assert(sheet.rules[2].declarations[0].value.spaced.length == 2);
    static assert(sheet.rules[2].declarations[1].value.layers[1].colour == Colour(255, 255, 255, 136));
    static assert(sheet.rules[3].media == Media.dark && sheet.rules[3].declarations[0].value.number == 0.5f);

    // derive() of a literal is worked out as it's parsed
    static assert(parseDeclarations("x: derive(#ececec, -30%)")[0].value.colour == Colour(0xa5, 0xa5, 0xa5));
    static assert(parseDeclarations("transition: opacity 150ms ease-out")[0].value.items[1].unit == Unit.ms);

    // Mistakes say where
    try
    {
        parseStylesheet(".a { x: 1 }\n.b { y 2 }");
        assert(false);
    }
    catch (CssException e)
        assert(e.msg == "CSS, line 2, column 8: expected ':'", e.msg);
    static assert(!__traits(compiles, { enum bad = parseStylesheet(".a { x: #12 }"); }));
}

// Variables: declared with --, used through var(), with a fallback if they're not declared
unittest
{
    enum d = parseDeclarations("--edge: var(--accent); colour: var(--missing, #fff)");
    static assert(d[0].property == "--edge" && d[0].value.name == "var" && d[0].value.items[0].name == "--accent");
    static assert(d[1].value.items.length == 2 && d[1].value.items[1].colour == Colour(255, 255, 255));

    string error(string css)
    {
        try
            parseStylesheet(css);
        catch (CssException e)
            return e.msg;
        return null;
    }
    assert(error(".a { colour: --accent }") == "CSS, line 1, column 22: a variable is used as var(--accent), not on its own");
    assert(error(".a { colour: var(accent) }").length, "var() of a name without --");
    assert(error("@media (prefers-color-scheme: dark) { }") == "CSS, line 1, column 29: it's spelt prefers-colour-scheme here");
}
