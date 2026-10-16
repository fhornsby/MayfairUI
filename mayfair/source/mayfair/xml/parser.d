module mayfair.xml.parser;

/*
    Reads a view's XML into a tree of elements, as it's compiled: see mayfair.xml.view for what the
    tree becomes.

    XML 1.0 as views use it: elements, attributes in either quotes, text, comments, CDATA, the five
    named entities and numeric ones, and processing instructions -- `<?import my.widgets?>` says
    where element names are looked up, and `<?xml ...?>` is skipped. No DTDs and no namespaces:
    nothing a view needs, and anything else is an error, with the line it's on.
*/

/// An element: `<Column spacing="8">`, what's in it, and the line it starts on.
struct Element
{
    string name;
    Attribute[] attributes;
    Element[] children;
    string text;    /// Any text directly inside it, joined, with the space around it trimmed
    uint line;

    /// The attribute called `name`, or null.
    const(Attribute)* attribute(string name) const pure nothrow @safe @nogc return
    {
        foreach (k; 0 .. attributes.length)
            if (attributes[k].name == name)
                return &attributes[k];
        return null;
    }
}

/// An attribute, with its entities already replaced.
struct Attribute
{
    string name;
    string value;
}

/// A whole file: its root element and the modules its <?import?> instructions name.
struct Document
{
    string[] imports;
    Element root;
}

/// Thrown for XML that can't be read, with the file and line. At compile time, a compile error.
class XmlException : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(message, file, line);
    }
}

/// Parses `xml`, naming `file` in any error.
Document parseXml(string xml, string file = "view") pure @safe
{
    auto p = XmlParser(xml, file);
    Document doc;
    p.misc(doc.imports);
    if (p.atEnd || p.peek != '<')
        p.fail("expected the root element");
    doc.root = p.element();
    p.misc(doc.imports);
    if (!p.atEnd)
        p.fail("only one root element is allowed");
    return doc;
}

private:

struct XmlParser
{
    string s;
    string file;
    size_t i;
    uint line = 1;

    bool atEnd() const pure nothrow @safe @nogc { return i >= s.length; }
    char peek() const pure nothrow @safe @nogc { return s[i]; }
    bool startsWith(string t) const pure nothrow @safe @nogc
    {
        return s.length - i >= t.length && s[i .. i + t.length] == t;
    }

    void advance(size_t n = 1) pure nothrow @safe @nogc
    {
        foreach (_; 0 .. n)
            if (s[i++] == '\n')
                line++;
    }

    noreturn fail(string message) const pure @safe
    {
        throw new XmlException(file ~ ":" ~ decimal(line) ~ ": " ~ message);
    }

    void skipSpace() pure nothrow @safe @nogc
    {
        while (!atEnd && isSpace(peek))
            advance();
    }

    /// Comments, processing instructions and space, outside the root or between children.
    void misc(ref string[] imports) pure @safe
    {
        for (;;)
        {
            skipSpace();
            if (startsWith("<!--"))
                comment();
            else if (startsWith("<?"))
                instruction(imports);
            else if (startsWith("<!DOCTYPE"))
                fail("DTDs aren't supported");
            else
                return;
        }
    }

    void comment() pure @safe
    {
        const from = line;
        advance(4);
        while (!startsWith("-->"))
        {
            if (atEnd)
            {
                line = from;
                fail("a comment that never ends");
            }
            advance();
        }
        advance(3);
    }

    void instruction(ref string[] imports) pure @safe
    {
        advance(2);
        const target = name();
        const start = i;
        while (!startsWith("?>"))
        {
            if (atEnd)
                fail("<?" ~ target ~ " that never ends");
            advance();
        }
        const content = trim(s[start .. i]);
        advance(2);
        if (target == "import")
        {
            // A module, as D names it. JavaFX's `.*`, for all of a package, means the same here
            string m = content;
            if (m.length > 2 && m[$ - 2 .. $] == ".*")
                m = m[0 .. $ - 2];
            if (!m.length)
                fail("<?import?> needs a module");
            foreach (c; m)
                if (!isNameChar(c) && c != '.')
                    fail("<?import " ~ content ~ "?> isn't a module name");
            imports ~= m;
        }
        else if (target != "xml")
            fail("unknown instruction <?" ~ target ~ "?>");
    }

    string name() pure @safe
    {
        const start = i;
        if (atEnd || !isNameStart(peek))
            fail("expected a name");
        while (!atEnd && isNameChar(peek))
            advance();
        return s[start .. i];
    }

    Element element() pure @safe
    {
        Element e;
        e.line = line;
        advance(); // <
        e.name = name();
        if (contains(e.name, ':'))
            fail("namespaces aren't supported: " ~ e.name);

        for (;;)
        {
            const spaced = !atEnd && isSpace(peek);
            skipSpace();
            if (atEnd)
                fail("<" ~ e.name ~ " that never ends");
            if (startsWith("/>"))
            {
                advance(2);
                return e;
            }
            if (peek == '>')
            {
                advance();
                break;
            }
            if (!spaced)
                fail("expected a space before the next attribute");
            Attribute a;
            a.name = name();
            if (a.name == "xmlns" || contains(a.name, ':'))
                fail("namespaces aren't supported: " ~ a.name);
            if (e.attribute(a.name))
                fail(e.name ~ " has " ~ a.name ~ " twice");
            skipSpace();
            if (atEnd || peek != '=')
                fail("expected = after " ~ a.name);
            advance();
            skipSpace();
            if (atEnd || (peek != '"' && peek != '\''))
                fail("expected " ~ a.name ~ "'s value, in quotes");
            const quote = peek;
            advance();
            const start = i;
            while (!atEnd && peek != quote)
            {
                if (peek == '<')
                    fail("< in an attribute: write &lt;");
                advance();
            }
            if (atEnd)
                fail(a.name ~ "'s value never ends");
            a.value = entities(s[start .. i]);
            advance();
            e.attributes ~= a;
        }

        // What's inside: children, text, comments, and CDATA, up to the end tag
        string text;
        for (;;)
        {
            if (atEnd)
            {
                line = e.line;
                fail("<" ~ e.name ~ "> is never closed");
            }
            if (startsWith("</"))
            {
                advance(2);
                const end = name();
                if (end != e.name)
                    fail("</" ~ end ~ "> closes <" ~ e.name ~ ">");
                skipSpace();
                if (atEnd || peek != '>')
                    fail("expected > after </" ~ end);
                advance();
                break;
            }
            if (startsWith("<!--"))
                comment();
            else if (startsWith("<![CDATA["))
            {
                advance(9);
                const start = i;
                while (!startsWith("]]>"))
                {
                    if (atEnd)
                        fail("CDATA that never ends");
                    advance();
                }
                text ~= s[start .. i];
                advance(3);
            }
            else if (startsWith("<?"))
            {
                string[] ignored;
                instruction(ignored);
                if (ignored.length)
                    fail("<?import?> belongs before the root element");
            }
            else if (peek == '<')
                e.children ~= element();
            else
            {
                const start = i;
                while (!atEnd && peek != '<')
                    advance();
                text ~= entities(s[start .. i]);
            }
        }
        e.text = trim(text);
        return e;
    }

    /// `text` with &amp; and the rest replaced.
    string entities(string text) pure @safe
    {
        if (!contains(text, '&'))
            return text;
        string result;
        size_t j;
        while (j < text.length)
        {
            if (text[j] != '&')
            {
                result ~= text[j++];
                continue;
            }
            size_t end = j + 1;
            while (end < text.length && text[end] != ';')
                end++;
            if (end == text.length)
                fail("an & that isn't an entity: write &amp;");
            const entity = text[j + 1 .. end];
            switch (entity)
            {
                case "amp": result ~= '&'; break;
                case "lt": result ~= '<'; break;
                case "gt": result ~= '>'; break;
                case "quot": result ~= '"'; break;
                case "apos": result ~= '\''; break;
                default:
                    if (entity.length > 1 && entity[0] == '#')
                        result ~= codePoint(entity[1 .. $]);
                    else
                        fail("unknown entity &" ~ entity ~ ";");
            }
            j = end + 1;
        }
        return result;
    }

    string codePoint(string digits) pure @safe
    {
        uint c;
        const hex = digits[0] == 'x';
        foreach (d; hex ? digits[1 .. $] : digits)
        {
            uint v;
            if (d >= '0' && d <= '9') v = d - '0';
            else if (hex && (d | 0x20) >= 'a' && (d | 0x20) <= 'f') v = (d | 0x20) - 'a' + 10;
            else fail("&#" ~ digits ~ "; isn't a character");
            c = c * (hex ? 16 : 10) + v;
            if (c > 0x10FFFF)
                fail("&#" ~ digits ~ "; isn't a character");
        }
        if ((hex && digits.length < 2) || (c >= 0xD800 && c <= 0xDFFF))
            fail("&#" ~ digits ~ "; isn't a character");
        // UTF-8, by hand: std.utf's encode isn't pure enough for here
        if (c < 0x80) return [cast(char) c];
        if (c < 0x800) return [cast(char)(0xC0 | c >> 6), cast(char)(0x80 | (c & 0x3F))];
        if (c < 0x10000) return [cast(char)(0xE0 | c >> 12), cast(char)(0x80 | (c >> 6 & 0x3F)), cast(char)(0x80 | (c & 0x3F))];
        return [cast(char)(0xF0 | c >> 18), cast(char)(0x80 | (c >> 12 & 0x3F)), cast(char)(0x80 | (c >> 6 & 0x3F)),
                cast(char)(0x80 | (c & 0x3F))];
    }
}

package(mayfair.xml):

bool isSpace(char c) pure nothrow @safe @nogc { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }
bool isNameStart(char c) pure nothrow @safe @nogc
{
    return (c | 0x20) >= 'a' && (c | 0x20) <= 'z' || c == '_' || c >= 0x80;
}
bool isNameChar(char c) pure nothrow @safe @nogc
{
    return isNameStart(c) || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == ':';
}

bool contains(string s, char c) pure nothrow @safe @nogc
{
    foreach (x; s)
        if (x == c)
            return true;
    return false;
}

string trim(string s) pure nothrow @safe @nogc
{
    size_t a, b = s.length;
    while (a < b && isSpace(s[a])) a++;
    while (b > a && isSpace(s[b - 1])) b--;
    return s[a .. b];
}

string decimal(size_t n) pure nothrow @safe
{
    if (n == 0)
        return "0";
    string r;
    for (; n; n /= 10)
        r = cast(char)('0' + n % 10) ~ r;
    return r;
}

unittest
{
    enum doc = parseXml(`<?xml version="1.0"?>
<?import my.widgets?>
<?import my.more.*?>
<!-- a view -->
<Column spacing="8" alignment='centre'>
    <Label text="Tom &amp; Jerry &#x263A;"/>
    <left><Button text="&lt;go&gt;"/></left>
    <Label>  Some <![CDATA[<raw>]]> text  </Label>
</Column>`, "test.xml");
    static assert(doc.imports == ["my.widgets", "my.more"]);
    static assert(doc.root.name == "Column" && doc.root.line == 5);
    static assert(doc.root.attribute("alignment").value == "centre");
    static assert(doc.root.children.length == 3);
    static assert(doc.root.children[0].attributes[0].value == "Tom & Jerry ☺");
    static assert(doc.root.children[1].name == "left" && doc.root.children[1].children[0].line == 7);
    static assert(doc.root.children[1].children[0].attributes[0].value == "<go>");
    static assert(doc.root.children[2].text == "Some <raw> text");

    static string error(string xml)
    {
        try
            parseXml(xml, "bad.xml");
        catch (XmlException e)
            return e.msg;
        return null;
    }
    assert(error("<A>\n<B></A>") == "bad.xml:2: </A> closes <B>");
    assert(error("<A x=\"1\" x=\"2\"/>") == "bad.xml:1: A has x twice");
    assert(error("<A/><B/>") == "bad.xml:1: only one root element is allowed");
    assert(error("<A>\n\n") == "bad.xml:1: <A> is never closed");
    assert(error("<A x=\"&nope;\"/>") == "bad.xml:1: unknown entity &nope;");
    assert(error("<fx:A/>") == "bad.xml:1: namespaces aren't supported: fx:A");
    assert(error("<A x=\"1\"y=\"2\"/>") == "bad.xml:1: expected a space before the next attribute");
}
