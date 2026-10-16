module mayfair.xml.view;

import std.meta : AliasSeq;
import std.traits;
import mayfair.css.parser : CssException, parseDeclarations, Declaration;
import mayfair.css.value : Value;
import mayfair.images.image : Image;
import mayfair.properties.declare : DefaultProperty;
import mayfair.widgets.styling : StyleContext, convertStyle, kebab;
import mayfair.xml.parser;

/*
    A view: a tree of widgets written in XML, and the class that controls it. JavaFX's FXML and
    its controllers, read as the program's compiled rather than when it runs.

        <!-- main.xml -->
        <Column spacing="8" alignment="centre">
            <Label id="status" text="Ready"/>
            <TextField id="name"/>
            <Button text="Save" onAction="save"/>
        </Column>

        @View("main.xml")
        class Main
        {
            @xml Label status;          // set to the element with id="status"
            @xml TextField name;

            void save() { status.setText("Saved " ~ name.text); }
            void initialise() { ... }   // if it's there, called once the tree is built
        }

        auto main = new Main;
        app.scene = new Scene(View.load(main));

    with the folder main.xml is in among dub's stringImportPaths. load() returns the root, as its
    own type. A view with no controller is View.load!"about.xml"().

    Everything's worked out as it's compiled: a misspelt property, a value that isn't one, a
    handler the controller doesn't have, a field with no element to fill it -- each is a compile
    error, at the file and line it's on. What's left to run is the same code as building the tree
    by hand.

    As in FXML:

    - An element whose name starts with a capital is an object: `<Column>` is `new Column`. Mayfair's
      classes are all known; others need their module named first, `<?import my.widgets?>`, unless
      they're in the controller's own module.
    - Its attributes set its properties: spacing="8" is setSpacing(8). A value is read as CSS reads
      it -- `centre` for Pos.centre, `8 16` for Insets, `#3584e4` for a Colour -- and an Image is a
      file, compiled in. `styleClass` takes classes separated by spaces, and `stylesheets` CSS
      files, compiled in too.
    - Attributes named as a constructor's parameters are passed to it: `<Icon iconName="go-home"/>`
      is `new Icon(iconName: "go-home")`.
    - `id` sets the widget's id, for CSS, and fills the controller's field of that name if it's
      marked @xml. `fx:id`'s, without the prefix.
    - `onAction="save"` -- any setOn... -- hands it the controller's method, which can take what
      the handler's given or nothing. FXML's `#save`, without the #.
    - Children go in with add(), or into the class's @DefaultProperty if it has one (ScrollPane's
      content, Tab's). Text inside an element sets its default property: `<Label>Hi</Label>`.
    - An element whose name starts with a lower-case letter sets a property of the one it's in,
      for a property that takes a widget, or text: `<Dock><left><NavigationList/></left></Dock>`.
    - Attributes named for the parent's class go to its add(), by its parameters' names:
      `<Label Grid.column="1" Grid.row="2"/>` in a Grid is grid.add(label, column: 1, row: 2).
*/
struct View
{
    /// The XML file, as `import` would find it.
    string file;

    /// Builds the view `controller`'s class is marked with, filling in its @xml fields.
    static auto load(C)(C controller) if (is(C == class))
    {
        static assert(hasUDA!(C, View), C.stringof ~ " needs @View(\"file.xml\") to say which view it controls");
        enum file = getUDAs!(C, View)[0].file;
        return build!(import(file), file, C)(controller);
    }

    /// Builds the view in `file`, which has no controller.
    static auto load(string file)()
    {
        return build!(import(file), file, NoController)(NoController.init);
    }

    /// Builds a view from XML in the program's own source, `name` naming it in errors.
    static auto parse(string xml, string name = "view")()
    {
        return build!(xml, name, NoController)(NoController.init);
    }
}

/// Marks a controller's field for its view to fill in, from the element with that id. FXML's @FXML.
enum xml = XmlField.init;

/// ditto
struct XmlField {}

/// Builds `text`'s tree for `controller`. Public for the code it's generated into to see, not to call.
auto build(string text, string file, C)(C controller)
{
    enum parsed = read(text, file);
    static assert(parsed.error is null, parsed.error);
    enum Document doc = parsed.doc;
    static if (!is(C == NoController))
        mixin("import " ~ moduleName!C ~ ";");
    mixin(parsed.code);
}

/// What build() is given for a view with no controller.
struct NoController {}

/// A file read, and the code it makes, or why it couldn't be: as an error, not a CTFE exception.
private struct Read
{
    Document doc;
    string code;
    string error;
}

private Read read(string text, string file) pure @safe
{
    Read r;
    try
    {
        r.doc = parseXml(text, file);
        r.code = generate(r.doc, file);
    }
    catch (XmlException e)
        r.error = e.msg;
    return r;
}

/*
    The code for a document: each element made, its attributes set, then put in its parent, in the
    order they're written. Element names are left for the compiler to look up, which is how an
    app's own widgets work with nothing to register; everything else is in the templates below,
    named from this module (the leading dot), so nothing an app imports can stand in for them.
*/
private string generate(const Document doc, string file) pure @safe
{
    string code = "import mayfair;\n";
    foreach (m; doc.imports)
        code ~= "import " ~ m ~ ";\n";
    size_t n;
    string[] ids;
    const root = emit(doc.root, "doc.root", file, code, n, ids);
    string list;
    foreach (i, id; ids)
        list ~= (i ? ", " : "") ~ quoted(id);
    code ~= ".finish!(C, " ~ quoted(file) ~ ", [" ~ list ~ "])(controller);\n";
    code ~= "return " ~ root ~ ";\n";
    return code;
}

private string emit(const Element e, string path, string file, ref string code, ref size_t n, ref string[] ids) pure @safe
{
    const v = "_mayfairW" ~ decimal(n++);
    const loc = quoted(file ~ ":" ~ decimal(e.line));
    if (!isUpper(e.name[0]))
        fail(file, e.line, "<" ~ e.name ~ "> sets a property, so it goes inside the element it's a property of");
    foreach (c; e.name)
        if (!(isUpper(c) || isLower(c) || (c >= '0' && c <= '9') || c == '_' || c == '.'))
            fail(file, e.line, "<" ~ e.name ~ "> can't be a D class's name");

    code ~= "static assert(is(" ~ e.name ~ "), " ~ quoted(file ~ ":" ~ decimal(e.line) ~ ": there's no class " ~ e.name
          ~ " here; if it's an app's own, name its module with <?import?>") ~ ");\n";
    code ~= "auto " ~ v ~ " = .create!(" ~ e.name ~ ", " ~ path ~ ".attributes, " ~ loc ~ ")(controller);\n";
    if (auto id = e.attribute("id"))
    {
        foreach (seen; ids)
            if (seen == id.value)
                fail(file, e.line, "a second id=\"" ~ id.value ~ "\"");
        ids ~= id.value;
    }

    if (e.text.length)
    {
        if (e.children.length)
            fail(file, e.line, "<" ~ e.name ~ "> has both text and elements in it");
        code ~= ".setText!(" ~ loc ~ ", " ~ path ~ ".text)(" ~ v ~ ");\n";
    }
    foreach (i, c; e.children)
    {
        const childPath = path ~ ".children[" ~ decimal(i) ~ "]";
        const childLoc = quoted(file ~ ":" ~ decimal(c.line));
        if (isLower(c.name[0]))
        {
            // A property element: <left>…</left>, or <text>…</text>
            if (c.attributes.length)
                fail(file, c.line, "<" ~ c.name ~ "> sets a property, and can't have attributes");
            if (!c.children.length)
                code ~= ".assign!(" ~ childLoc ~ ", " ~ quoted(c.name) ~ ", " ~ childPath ~ ".text)(" ~ v ~ ", controller);\n";
            else
            {
                if (c.text.length)
                    fail(file, c.line, "<" ~ c.name ~ "> has both text and elements in it");
                foreach (j, g; c.children)
                {
                    const value = emit(g, childPath ~ ".children[" ~ decimal(j) ~ "]", file, code, n, ids);
                    code ~= ".setProperty!(" ~ quoted(file ~ ":" ~ decimal(g.line)) ~ ", " ~ quoted(c.name) ~ ", "
                          ~ decimal(c.children.length) ~ ")(" ~ v ~ ", " ~ value ~ ");\n";
                }
            }
        }
        else
        {
            const child = emit(c, childPath, file, code, n, ids);
            code ~= ".place!(" ~ childLoc ~ ", .attached(" ~ childPath ~ ".attributes))(" ~ v ~ ", " ~ child ~ ");\n";
        }
    }
    return v;
}

/*
    The templates the generated code calls. Each is told its place in the file, as "main.xml:12",
    for its errors.
*/

/// Makes a T from the attributes its constructor takes, and sets it from the rest.
T create(T, Attribute[] attributes, string loc, C)(C controller)
{
    static if (is(T == class) && __traits(hasMember, T, "__ctor"))
    {
        alias constructors = __traits(getOverloads, T, "__ctor");
        enum chosen = choose!(T, constructors)(names(attributes), 0, loc);
        static if (chosen.index < 0)
            static assert(false, chosen.error);
        else
        {
            alias ctor = constructors[chosen.index];
            enum used = chosen.used;
            auto object = mixin("new T(" ~ arguments!(ctor, "ctor", attributes, used, loc, 0)() ~ ")");
        }
    }
    else
    {
        static assert(is(T == class), loc ~ ": " ~ T.stringof ~ " isn't a class");
        enum string[] used = [];
        auto object = new T;
    }

    static foreach (a; attributes)
        static if (!contains(a.name, '.') && !isIn(a.name, used))
            .assign!(loc, a.name, a.value)(object, controller);
    static if (hasId(attributes))
        .inject!(loc, idOf(attributes))(controller, object);
    return object;
}

/// Sets `object`'s property `name` from the text of an attribute or property element.
void assign(string loc, string name, string text, T, C)(T object, C controller)
{
    static if (name == "styleClass")
    {
        static foreach (c; words(text))
            object.styleClass.add(c);
    }
    else static if (name == "stylesheets")
    {
        import mayfair.css.stylesheet : stylesheet;
        static foreach (f; words(text))
            object.stylesheets.add(stylesheet!(import(f)));
    }
    else
    {
        enum setter = "set" ~ capitalised(name);
        static assert(__traits(hasMember, T, setter), loc ~ ": " ~ T.stringof ~ " has no property " ~ name);
        alias overloads = __traits(getOverloads, T, setter);
        enum index = settable!(overloads)(text);
        static assert(index >= 0, loc ~ ": " ~ T.stringof ~ "." ~ setter ~ " doesn't take one value");
        alias P = Parameters!(overloads[index])[0];
        static if (isCallable!P)
            __traits(getMember, object, setter)(.handler!(P, loc, name, text)(controller));
        else
            __traits(getMember, object, setter)(.value!(P, text, loc ~ ": " ~ name)());
    }
}

/// Sets `object`'s default property from the text inside its element.
void setText(string loc, string text, T)(T object)
{
    enum property = defaultProperty!T;
    static assert(property.length, loc ~ ": " ~ T.stringof ~ " doesn't take text inside it; set a property instead");
    .assign!(loc, property, text)(object, NoController.init);
}

/// Sets `object`'s property `name` to `value`, from a property element.
void setProperty(string loc, string name, size_t count, T, V)(T object, V value)
{
    static if (name == "children")
        .place!(loc, [])(object, value);
    else
    {
        enum setter = "set" ~ capitalised(name);
        static assert(__traits(hasMember, T, setter), loc ~ ": " ~ T.stringof ~ " has no property " ~ name);
        static assert(count == 1, loc ~ ": <" ~ name ~ "> holds one element, not " ~ decimal(count));
        static assert(__traits(compiles, __traits(getMember, object, setter)(value)),
                      loc ~ ": " ~ T.stringof ~ "." ~ name ~ " can't be a " ~ V.stringof);
        __traits(getMember, object, setter)(value);
    }
}

/// Puts `child` in `parent`: with add(), passing it the `attached` attributes, or as its default property.
void place(string loc, Attribute[] attached, P, T)(P parent, T child)
{
    static if (attached.length)
    {
        static foreach (a; attached)
            static assert(isClassOf!P(a.name[0 .. indexOf(a.name, '.')]),
                          loc ~ ": " ~ a.name ~ " is for a child of a " ~ a.name[0 .. indexOf(a.name, '.')]
                          ~ ", and this is in a " ~ P.stringof);
        static assert(__traits(hasMember, P, "add"), loc ~ ": " ~ P.stringof ~ " has no add() for " ~ attached[0].name);
        alias overloads = __traits(getOverloads, P, "add");
        enum chosen = choose!(P, overloads)(names(attached, true), 1, loc);
        static assert(chosen.index >= 0, chosen.error);
        alias add = overloads[chosen.index];
        static assert(is(T : Parameters!add[0]), loc ~ ": a " ~ T.stringof ~ " can't go in a " ~ P.stringof);
        mixin("parent.add(child, " ~ arguments!(add, "add", attached, chosen.used, loc, 1, true)() ~ ");");
    }
    else
    {
        enum property = defaultProperty!P;
        static if (property.length && __traits(compiles, __traits(getMember, parent, "set" ~ capitalised(property))(child)))
            __traits(getMember, parent, "set" ~ capitalised(property))(child);
        else
        {
            static assert(__traits(compiles, parent.add(child)), loc ~ ": a " ~ T.stringof ~ " can't go in a " ~ P.stringof);
            parent.add(child);
        }
    }
}

/// Fills the controller's field `id` with `object`, if it's marked @xml.
void inject(string loc, string id, C, T)(C controller, T object)
{
    static if (!is(C == NoController) && __traits(hasMember, C, id))
    {
        static if (isMarkedField!(C, id))
        {
            alias F = typeof(__traits(getMember, controller, id));
            static assert(is(T : F), loc ~ ": id=\"" ~ id ~ "\" is a " ~ T.stringof ~ ", but " ~ C.stringof ~ "." ~ id
                                     ~ " is a " ~ F.stringof);
            __traits(getMember, controller, id) = object;
        }
    }
}

/// Checks every @xml field has been filled in, and calls the controller's initialise(), if it has one.
void finish(C, string file, string[] ids)(C controller)
{
    static if (!is(C == NoController))
    {
        static foreach (m; __traits(allMembers, C))
            static if (isMarkedField!(C, m))
                static assert(isIn(m, ids), C.stringof ~ "." ~ m ~ " is marked @xml, but " ~ file ~ " has no id=\"" ~ m ~ "\"");
        static if (__traits(hasMember, C, "initialise"))
            controller.initialise();
    }
}

/// The attributes for the parent's add(): those with a dot.
Attribute[] attached(const Attribute[] attributes) pure nothrow @safe
{
    Attribute[] result;
    foreach (a; attributes)
        if (contains(a.name, '.'))
            result ~= a;
    return result;
}

private:

/// The controller's method `name`, as a handler of type H.
H handler(H, string loc, string attribute, string name, C)(C controller)
{
    static assert(!is(C == NoController), loc ~ ": " ~ attribute ~ "=\"" ~ name ~ "\" needs a controller to call; "
                                        ~ "load the view with View.load(controller)");
    static assert(__traits(hasMember, C, name), loc ~ ": " ~ C.stringof ~ " has no method " ~ name ~ " for " ~ attribute);
    auto method = &__traits(getMember, controller, name);
    static if (is(typeof(method) : H))
        return method;
    else static if (is(typeof(method) == delegate) && Parameters!(typeof(method)).length == 0)
        return ignoring!H(method); // the handler's given an event, and the method doesn't want it
    else
        static assert(false, loc ~ ": " ~ C.stringof ~ "." ~ name ~ " can't handle " ~ attribute ~ ": it needs to take "
                           ~ (Parameters!H.length ? Parameters!H.stringof ~ ", or nothing" : "nothing"));
}

/// A handler of type H that calls `f` and drops what it's given.
H ignoring(H, F)(F f)
{
    alias P = Parameters!H;
    mixin(() {
        string s = "return delegate(";
        static foreach (i, storage; ParameterStorageClassTuple!H)
            s ~= (i ? ", " : "") ~ ((storage & ParameterStorageClass.ref_) ? "ref " : "") ~ "P[" ~ decimal(i) ~ "] _" ~ decimal(i);
        return s ~ ") { f(); };";
    }());
}

/// The text of an attribute as a P, worked out as it's compiled if it can be.
template value(P, string text, string loc)
{
    static if (is(P : Image))
    {
        P value() { return Image.fromData(import(text), text); }
    }
    else static if (__traits(compiles, { enum c = convert!P(text); }))
    {
        enum c = convert!P(text);
        static assert(c.error is null, loc ~ ": " ~ c.error);
        P value() { return c.value; }
    }
    else // what only converts at run time: a font, which needs the fonts loaded to find
    {
        P value()
        {
            auto c = convert!P(text);
            if (c.error)
                throw new XmlException(loc ~ ": " ~ c.error);
            return c.value;
        }
    }
}

struct Converted(P)
{
    P value;
    string error;
}

Converted!P convert(P)(string text)
{
    Converted!P r;
    static if (is(P == string))
        r.value = text;
    else static if (is(P == bool))
    {
        if (text == "true")
            r.value = true;
        else if (text != "false")
            r.error = "expected true or false, not \"" ~ text ~ "\"";
    }
    else static if (is(P == enum))
    {
        string choices;
        static foreach (member; __traits(allMembers, P))
        {
            if (text == member || text == kebab(member))
                return Converted!P(__traits(getMember, P, member));
            choices ~= (choices.length ? ", " : "") ~ kebab(member);
        }
        r.error = "\"" ~ text ~ "\" isn't one of " ~ choices;
    }
    else static if (isIntegral!P)
    {
        bool negative = text.length && text[0] == '-';
        const digits = negative ? text[1 .. $] : text;
        long n;
        foreach (d; digits)
        {
            if (d < '0' || d > '9' || n > long.max / 10)
                return Converted!P(P.init, "expected a whole number, not \"" ~ text ~ "\"");
            n = n * 10 + (d - '0');
        }
        if (!digits.length || (negative ? -n : n) < P.min || (negative ? -n : n) > P.max)
            r.error = "expected a whole number, not \"" ~ text ~ "\"";
        else
            r.value = cast(P)(negative ? -n : n);
    }
    else static if (isFloatingPoint!P && !is(P == float))
    {
        auto f = convert!float(text);
        r.value = f.value;
        r.error = f.error;
    }
    else static if (__traits(compiles, (const(Value)*[] v, ref StyleContext c, out P p) => convertStyle(v, c, p)))
    {
        // As CSS says it, to read as CSS reads it
        Declaration[] declared;
        try
            declared = parseDeclarations("value: " ~ text);
        catch (CssException e)
            return Converted!P(P.init, "\"" ~ text ~ "\" can't be read: " ~ e.msg);
        const(Value)*[5] values; // the first, and none of the longhands a composite reads after it
        values[0] = &declared[0].value;
        StyleContext context;
        if (!convertStyle(values[], context, r.value))
            r.error = "\"" ~ text ~ "\" isn't a " ~ P.stringof;
    }
    else
        r.error = "a " ~ P.stringof ~ " can't be written as text; set it with an element inside";
    return r;
}

/*
    Which of `overloads` to call with arguments named `given`, after the first `skip` (the child,
    for add): one whose parameters include them all, and that needs nothing more. The one taking
    the most of them, if several do. `used` is the names it takes, for create to leave the rest to
    setters: those not a parameter are properties.
*/
struct Choice
{
    int index = -1;
    string[] used;
    string error;
}

Choice choose(T, overloads...)(string[] given, size_t skip, string loc)
{
    const bool forAdd = skip > 0;
    Choice best;
    size_t bestCount;
    string[] signatures;
    static foreach (i, overload; overloads)
    {{
        enum string[] parameters = [ParameterIdentifierTuple!overload];
        alias defaults = ParameterDefaults!overload;
        bool[] required;
        static foreach (k; 0 .. parameters.length)
            required ~= is(defaults[k] == void);
        string signature;
        foreach (k, p; parameters)
            if (k >= skip)
                signature ~= (signature.length ? ", " : "") ~ p ~ (required[k] ? "" : "?");
        signatures ~= signature;

        bool fits = parameters.length >= skip;
        string[] used;
        foreach (k, p; parameters)
        {
            if (k < skip)
                continue;
            if (isIn(p, given))
                used ~= p;
            else if (required[k])
                fits = false;
        }
        if (forAdd && used.length != given.length)
            fits = false; // add's attributes are all for it
        if (fits && (best.index < 0 || used.length > bestCount))
        {
            best.index = i;
            best.used = used;
            bestCount = used.length;
        }
    }}
    if (best.index < 0)
    {
        string list;
        foreach (s; signatures)
            list ~= "\n    (" ~ s ~ ")";
        best.error = loc ~ ": " ~ (forAdd ? T.stringof ~ ".add() takes none of these: " ~ joined(given)
                                          : T.stringof ~ " can't be made from these attributes")
                   ~ "; it takes" ~ list;
    }
    return best;
}

/// The named arguments for `overload`, from `attributes` (by their names after the dot, for add).
string arguments(alias overload, string name, Attribute[] attributes, string[] used, string loc, size_t skip, bool dotted = false)()
{
    string s;
    static foreach (k, p; ParameterIdentifierTuple!overload)
        static if (k >= skip && isIn(p, used))
            s ~= (s.length ? ", " : "") ~ p ~ ": .value!(Parameters!(" ~ name ~ ")[" ~ decimal(k) ~ "], " ~ quoted(find(attributes, p, dotted)) ~ ", " ~ quoted(loc ~ ": " ~ p) ~ ")()";
    return s;
}

string find(Attribute[] attributes, string name, bool dotted) pure @safe
{
    foreach (a; attributes)
        if ((dotted ? a.name[indexOf(a.name, '.') + 1 .. $] : a.name) == name)
            return a.value;
    assert(false);
}

/// Which overload of a setter takes one value: the first.
int settable(overloads...)(string text)
{
    static foreach (i, overload; overloads)
        static if (Parameters!overload.length == 1)
            return i;
    return -1;
}

/// T's default property, or the nearest of its base classes': where children and text go.
template defaultProperty(T)
{
    static if (hasUDA!(T, DefaultProperty))
        enum defaultProperty = getUDAs!(T, DefaultProperty)[0].name;
    else static if (is(T == class) && BaseClassesTuple!T.length)
        enum defaultProperty = .defaultProperty!(BaseClassesTuple!T[0]);
    else
        enum defaultProperty = "";
}

template isMarkedField(C, string m)
{
    static if (__traits(compiles, __traits(getMember, C, m)) && !isSomeFunction!(__traits(getMember, C, m))
               && __traits(compiles, hasUDA!(__traits(getMember, C, m), XmlField)))
        enum isMarkedField = hasUDA!(__traits(getMember, C, m), XmlField);
    else
        enum isMarkedField = false;
}

/// Whether `name` is P's class or one it inherits from: what Grid.row can be on a child of.
bool isClassOf(P)(string name)
{
    static foreach (B; AliasSeq!(P, BaseClassesTuple!P))
        if (__traits(identifier, B) == name)
            return true;
    return false;
}

string[] names(const Attribute[] attributes, bool dotted = false) pure @safe
{
    string[] result;
    foreach (a; attributes)
        if (contains(a.name, '.') == dotted)
            result ~= dotted ? a.name[indexOf(a.name, '.') + 1 .. $] : a.name;
    return result;
}

bool hasId(const Attribute[] attributes) pure nothrow @safe @nogc
{
    foreach (a; attributes)
        if (a.name == "id")
            return true;
    return false;
}

string idOf(const Attribute[] attributes) pure nothrow @safe @nogc
{
    foreach (a; attributes)
        if (a.name == "id")
            return a.value;
    return null;
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

bool isIn(string s, const string[] list) pure nothrow @safe @nogc
{
    foreach (x; list)
        if (x == s)
            return true;
    return false;
}

size_t indexOf(string s, char c) pure nothrow @safe @nogc
{
    foreach (i, x; s)
        if (x == c)
            return i;
    return s.length;
}

string joined(const string[] list) pure @safe
{
    string s;
    foreach (i, x; list)
        s ~= (i ? ", " : "") ~ x;
    return s;
}

bool isUpper(char c) pure nothrow @safe @nogc { return c >= 'A' && c <= 'Z'; }
bool isLower(char c) pure nothrow @safe @nogc { return c >= 'a' && c <= 'z'; }

string capitalised(string s) pure nothrow @safe
{
    return s.length && isLower(s[0]) ? cast(char)(s[0] - 32) ~ s[1 .. $] : s;
}

/// `s` as a D string literal.
string quoted(string s) pure nothrow @safe
{
    string r = "\"";
    foreach (c; s)
    {
        switch (c)
        {
            case '"': r ~= "\\\""; break;
            case '\\': r ~= "\\\\"; break;
            case '\n': r ~= "\\n"; break;
            case '\r': r ~= "\\r"; break;
            case '\t': r ~= "\\t"; break;
            default: r ~= c;
        }
    }
    return r ~ "\"";
}

noreturn fail(string file, uint line, string message) pure @safe
{
    throw new XmlException(file ~ ":" ~ decimal(line) ~ ": " ~ message);
}

version (unittest)
{
    import mayfair.widgets;

    @View("test.xml")
    class TestController
    {
        @xml Label status;
        @xml private TextField name;   // private, as FXML's can be
        Button unmarked;               // not @xml, so left alone
        int saves, presses, initialised;

        void save() { saves++; status.setText("Saved " ~ name.text); }
        void pressed(ref MouseEvent e) { presses++; }
        void initialise() { initialised++; assert(status !is null); }
    }

    // Grid's add() by its parameters' names, a property element, default properties, and text
    enum layoutView = `<?xml version="1.0"?>
<Dock>
    <top><Label id="title" styleClass="title big">Hello &amp; welcome</Label></top>
    <centre>
        <ScrollPane>
            <Grid columnGap="12" rowGap="8" padding="8 16">
                <Label text="Name" Grid.column="0" Grid.row="0"/>
                <TextField Grid.column="1" Grid.row="0" grow="1"/>
                <Button text="Go" Grid.column="0" Grid.row="1" Grid.columnSpan="2"/>
            </Grid>
        </ScrollPane>
    </centre>
</Dock>`;
}

unittest
{
    import mayfair.widgets;

    auto column = View.parse!(`<Column spacing="8" alignment="centre" fillWidth="false">
        <Label text="One"/>
        <Button>Two</Button>
    </Column>`)();
    static assert(is(typeof(column) == Column));
    assert(column.spacing == 8 && column.alignment == Pos.centre && !column.fillWidth);
    assert(column.children.length == 2);
    assert((cast(Label) column.children[0]).text == "One");
    assert((cast(Button) column.children[1]).text == "Two");

    auto dock = View.parse!(layoutView, "layout.xml")();
    auto title = cast(Label) dock.top;
    assert(title.text == "Hello & welcome" && title.id == "title");
    assert(title.styleClass.contains("title") && title.styleClass.contains("big"));
    auto grid = cast(Grid) (cast(ScrollPane) dock.centre).content;
    assert(grid.columnGap == 12 && grid.padding == Insets(8, 16));
    assert(grid.children.length == 3 && grid.children[1].grow == 1);

    // A controller: its fields filled, its methods handlers, then initialise()
    auto c = new TestController;
    auto root = build!(`<Column>
        <Label id="status" text="Ready" onMouseClicked="pressed"/>
        <TextField id="name" text="Ann"/>
        <Button id="unmarked" text="Save" onAction="save" onMousePressed="save"/>
    </Column>`, "test.xml", TestController)(c);
    assert(c.initialised == 1 && c.status.text == "Ready" && c.name.text == "Ann");
    assert(c.unmarked is null);
    (cast(Button) root.children[2]).fire();
    assert(c.saves == 1 && c.status.text == "Saved Ann");

    // Mistakes are compile errors
    static assert(!__traits(compiles, View.parse!(`<Column spcing="8"/>`)()));             // no such property
    static assert(!__traits(compiles, View.parse!(`<Column spacing="wide"/>`)()));         // not a number
    static assert(!__traits(compiles, View.parse!(`<Column alignment="middle"/>`)()));     // not a Pos
    static assert(!__traits(compiles, View.parse!(`<Colum/>`)()));                         // no such class
    static assert(!__traits(compiles, View.parse!(`<Button onAction="save"/>`)()));        // no controller
    static assert(!__traits(compiles, View.parse!(`<Row><Label Grid.row="1"/></Row>`)())); // not in a Grid
    static assert(!__traits(compiles, View.parse!(`<Dock><left><Label/><Label/></left></Dock>`)()));
    static assert(!__traits(compiles, build!(`<Column><Label id="status"/></Column>`, "t.xml", TestController)(c))); // no name
    static assert(!__traits(compiles, build!(`<Column><Button id="status"/><TextField id="name"/></Column>`, "t.xml",
                                             TestController)(c))); // status isn't a Button
    static assert(!__traits(compiles, build!(`<Button id="status" onAction="nothing"/>`, "t.xml", TestController)(c)));
}
