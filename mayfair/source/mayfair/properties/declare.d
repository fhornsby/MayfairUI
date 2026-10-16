module mayfair.properties.declare;

/*
    Declares a property on a class the way JavaFX's classes have them: a getter, a setter, and the
    Property itself.

        mixin(declareProperty!(string, "text", `""`, q{ reshape(); }));

    gives the class

        string text()                        the value
        void setText(string value)           sets it: JavaFX's setter
        C text(string value)                 sets it and returns the object, as its own type, so
                                             calls chain: new Column().padding(16).spacing(12)
        Property!string textProperty()       the property, to bind, bind to, or listen to

    The two setters are for two places. The chaining one is for building a tree from outside, and
    needs its object named: D can't work out "its own type" for a call on an implicit `this`
    from inside a subclass. setText works anywhere, and is what a widget uses on itself.

    and runs the last argument, the class's own reaction, whenever the value actually changes,
    however it changed: set directly, set through the property, or pulled in from a binding.

    As JavaFX does, the Property object is only made when someone asks for it. Until then the
    value is a plain field, which matters when a widget has twenty settings and most apps touch
    two of them. Once it exists, a change through it is picked up straight away, so the field is
    always the current value -- which is what lets the getter be @nogc, for paint code to read.

    declareReadOnlyProperty is the same for state an object reports rather than takes: the
    getter and a ReadOnlyProperty to watch are public, and the setter is `_setName`, with
    whatever visibility is asked for, for the object itself to call.
*/
enum string declareProperty(T, string name, string initial, string changed = "") =
    declare!T(name, initial, changed, false, "", null, false);

/*
    The same, with the type spelt as `typeName` says, for a class template whose property's type is
    one of its parameters: `declarePropertyOf!(T[], "T[]", "items", "null")`. The code this makes
    names the type as text, and a type an app defines isn't visible by its own name from inside the
    template's module, where its parameter's name is.
*/
enum string declarePropertyOf(T, string typeName, string name, string initial, string changed = "") =
    declare!T(name, initial, changed, false, "", null, false, typeName);

/// ditto
enum string declareReadOnlyProperty(T, string name, string initial, string changed = "",
                                    string setterVisibility = "private") =
    declare!T(name, initial, changed, true, setterVisibility, null, false);

/*
    A property CSS can set too: JavaFX's StyleableProperty. `css` is its name in a stylesheet,
    or several, comma-separated, for one set from more than one -- a font, from font-size,
    font-family and the rest -- and `inherits` says whether a widget with none of them set
    takes its parent's, as a font does.

        mixin(declareStyleableProperty!(Insets, "padding", "padding", "Insets.init", q{ applyPadding(); }));

    Besides the property, it keeps where the value came from, which decides what can change it,
    as in JavaFX: the built-in theme gives way to code, and code to an app's stylesheets and a
    widget's inline style. It also tells the style engine the property is there (see
    mayfair.widgets.styling), which is all a widget has to do to be styleable.

    Only for a Widget's properties, in the mayfair.widgets package.
*/
enum string declareStyleableProperty(T, string name, string css, string initial, string changed = "",
                                     bool inherits = false) =
    declare!T(name, initial, changed, false, "", css, inherits);

/*
    Properties from fields marked @observable, for a class of an app's own: the same getter,
    setters and Property as declareProperty makes, without spelling them out as text.

        class Counter : Row
        {
            mixin Properties;                   // once, in each class with any

            @observable private int _count;     // count(), setCount(), count(3) and countProperty
            @observable private int _step = 1;

            void countChanged() { refresh(); }  // if it's there, called whenever count changes
        }

    A field's name starts with an underscore, which the property's doesn't: _count makes count.
    Observable, because what it makes can be watched -- listened to, or bound to and from -- as
    any Property can, besides being set from code and from a view.
*/
mixin template Properties()
{
    import mayfair.properties.declare : isObservableField, observableProperty;
    static foreach (_mayfairMember; __traits(derivedMembers, typeof(this)))
        static if (isObservableField!(typeof(this), _mayfairMember))
            mixin(observableProperty!(typeof(__traits(getMember, typeof(this), _mayfairMember)))(_mayfairMember));
}

/// Marks a field as a property's value: see Properties.
enum observable = ObservableField.init;

/// ditto
struct ObservableField {}

/// Whether C's member `m` is a field marked @observable. For Properties, which has to see it.
template isObservableField(C, string m)
{
    import std.traits : hasUDA, isSomeFunction;
    static if (__traits(compiles, __traits(getMember, C, m)) && !isSomeFunction!(__traits(getMember, C, m))
               && __traits(compiles, hasUDA!(__traits(getMember, C, m), ObservableField))
               && hasUDA!(__traits(getMember, C, m), ObservableField))
    {
        static assert(m.length > 1 && m[0] == '_', C.stringof ~ "." ~ m ~ " is @observable, so its name starts with an "
                      ~ "underscore: _" ~ m ~ " makes the property " ~ m);
        enum isObservableField = true;
    }
    else
        enum isObservableField = false;
}

/// The code for the property whose value is the field `field`. For Properties.
string observableProperty(T)(string field)
{
    const name = field[1 .. $];
    const changed = "static if (__traits(hasMember, typeof(this), \"" ~ name ~ "Changed\")) " ~ name ~ "Changed();";
    return declare!T(name, "", changed, false, "", null, false, "typeof(" ~ field ~ ")", true);
}

/*
    Marks a class with the property its children go into when a view (see mayfair.xml) puts them
    in it without naming one, and that text inside its element sets: JavaFX's @DefaultProperty.

        @DefaultProperty("content")
        class ScrollPane : Widget

    A class without one, and without a base class with one, has its children add()ed.
*/
struct DefaultProperty
{
    string name;
}

private string declare(T)(string name, string initial, string changed, bool readOnly, string setterVisibility,
                          string css, bool inherits, string typeName = null, bool hasField = false)
{
    const type = typeName.length ? typeName : T.stringof;
    const field = "_" ~ name;
    const object = "_" ~ name ~ "Property";
    const listener = "_" ~ name ~ "Invalidated";
    // A class, or a struct holding an array, can't come back out of a const getter as mutable,
    // so only what converts from const gets the const one
    const getterAttributes = is(const(T) : T) ? "const nothrow @nogc" : "nothrow @nogc";
    const propertyType = readOnly ? "ReadOnlyWrapper!(" ~ type ~ ")" : "Property!(" ~ type ~ ")";

    string code;
    if (!hasField)
        code ~= "private " ~ type ~ " " ~ field ~ " = " ~ initial ~ ";\n";
    code ~= "private " ~ propertyType ~ " " ~ object ~ ";\n";
    code ~= "final " ~ type ~ " " ~ name ~ "() " ~ getterAttributes ~ " { return " ~ field ~ "; }\n";

    const styleable = css.length > 0;
    const origin = "_" ~ name ~ "Origin";
    const styling = "_" ~ name ~ "Styling";
    // A styleable property's CSS name: its first, for a composite, which is what a transition's keyed by
    const cssName = styleable ? splitNames(css)[0] : "";
    if (styleable)
        code ~= "import mayfair.css.stylesheet : StyleOrigin;\n"
              ~ "import mayfair.widgets.styling : cancelStyleTransition;\n"
              ~ "private StyleOrigin " ~ origin ~ ";\n"
              ~ "private bool " ~ styling ~ ";\n";

    // The setter: through the property if there is one, which tells its listeners and so this
    const setter = readOnly ? setterVisibility ~ " final void _set" ~ capitalised(name)
                            : "public final void set" ~ capitalised(name);
    code ~= setter ~ "(" ~ type ~ " value)\n{\n"
          ~ (styleable ? "    " ~ origin ~ " = StyleOrigin.user;\n"
                       ~ "    cancelStyleTransition(this, \"" ~ cssName ~ "\"); // code has the last word\n" : "")
          ~ "    if (" ~ object ~ ") " ~ object ~ ".set(value);\n"
          ~ "    else if (value != " ~ field ~ ") { " ~ field ~ " = value; " ~ changed ~ " }\n"
          ~ "}\n";
    if (!readOnly)
        code ~= "public final This " ~ name ~ "(this This)(" ~ type ~ " value)\n{\n"
              ~ "    set" ~ capitalised(name) ~ "(value);\n"
              ~ "    return cast(This) this;\n"
              ~ "}\n";

    code ~= "public final " ~ (readOnly ? "ReadOnlyProperty!(" ~ type ~ ")" : propertyType) ~ " "
          ~ name ~ "Property()\n{\n"
          ~ "    if (!" ~ object ~ ")\n    {\n"
          ~ "        " ~ object ~ " = new " ~ propertyType ~ "(" ~ field ~ ");\n"
          ~ "        " ~ object ~ ".addListener(&" ~ listener ~ ");\n"
          ~ "    }\n"
          ~ "    return " ~ object ~ (readOnly ? ".readOnlyProperty" : "") ~ ";\n"
          ~ "}\n";

    // The property changed, perhaps from a binding: take the value, and react if it's new
    code ~= "private void " ~ listener ~ "()\n{\n"
          ~ (styleable ? "    if (!" ~ styling ~ ") { " ~ origin ~ " = StyleOrigin.user; cancelStyleTransition(this, \"" ~ cssName
                       ~ "\"); } // set, or bound, from code\n" : "")
          ~ "    auto value = " ~ object ~ ".get();\n"
          ~ "    if (value == " ~ field ~ ") return;\n"
          ~ "    " ~ field ~ " = value;\n"
          ~ "    " ~ changed ~ "\n"
          ~ "}\n";

    if (styleable)
    {
        const style = "_style" ~ capitalised(name);
        const reset = "_reset" ~ capitalised(name);
        // What CSS sets it with: not while it's bound, and the theme never over code
        code ~= "package final void " ~ style ~ "(" ~ type ~ " value, StyleOrigin from)\n{\n"
              ~ "    if (" ~ object ~ " && " ~ object ~ ".isBound) return;\n"
              ~ "    if (from == StyleOrigin.userAgent && " ~ origin ~ " == StyleOrigin.user) return;\n"
              ~ "    " ~ styling ~ " = true;\n"
              ~ "    scope (exit) " ~ styling ~ " = false;\n"
              ~ "    " ~ origin ~ " = from;\n"
              ~ "    if (" ~ object ~ ") " ~ object ~ ".set(value);\n"
              ~ "    else if (value != " ~ field ~ ") { " ~ field ~ " = value; " ~ changed ~ " }\n"
              ~ "}\n";
        // Whether CSS set it, so that a stylesheet no longer setting it puts it back how it started
        code ~= "package final bool " ~ reset ~ "() const nothrow @nogc\n{\n"
              ~ "    return " ~ origin ~ " == StyleOrigin.userAgent || " ~ origin ~ " == StyleOrigin.author || "
              ~ origin ~ " == StyleOrigin.inline;\n"
              ~ "}\n";
        // Tells the style engine it's here, before main() runs. Standalone, as widget modules import
        // each other and a constructor's order among them doesn't matter.
        string names;
        foreach (i, n; splitNames(css))
            names ~= (i ? ", " : "") ~ "\"" ~ n ~ "\"";
        // In a struct of its own: a static constructor is named by where it is in its mixin, and two
        // properties' can be in the same place in theirs
        code ~= "import core.attribute : standalone;\n"
              ~ "private alias _cssOwner_" ~ name ~ " = typeof(this);\n"
              ~ "private struct _CssRegistration_" ~ name ~ "\n{\n"
              ~ "@standalone @trusted shared static this()\n{\n"
              ~ "    import mayfair.widgets.styling : registerStyleable, CssProperty, StyleContext, convertStyle, styleValue;\n"
              ~ "    import mayfair.widgets.widget : Widget;\n"
              ~ "    import mayfair.css.value : Value;\n"
              ~ "    alias Self = _cssOwner_" ~ name ~ ";\n"
              ~ "    static immutable string[] names = [" ~ names ~ "];\n"
              ~ "    registerStyleable(typeid(Self), CssProperty(names, " ~ (inherits ? "true" : "false") ~ ",\n"
              // Set by the winning declaration, through a transition if one's declared for it
              ~ "        function(Widget w, const(Value)*[] values, StyleOrigin from, ref StyleContext context) {\n"
              ~ "            " ~ type ~ " value;\n"
              ~ "            if (!convertStyle(values, context, value)) return;\n"
              ~ "            auto self = cast(Self) cast(void*) w;\n"
              ~ "            styleValue(w, context, names, self." ~ field ~ ", value, (" ~ type ~ " v) { self." ~ style ~ "(v, from); });\n"
              ~ "        },\n"
              // Nothing declares it now: back to how it started if CSS set it, through a transition likewise
              ~ "        function(Widget w, ref StyleContext context) {\n"
              ~ "            auto self = cast(Self) cast(void*) w;\n"
              ~ "            if (self." ~ reset ~ "())\n"
              ~ "                styleValue(w, context, names, self." ~ field ~ ", cast(" ~ type ~ ")(" ~ initial ~ "),\n"
              ~ "                           (" ~ type ~ " v) { self." ~ style ~ "(v, StyleOrigin.none); });\n"
              ~ "        }));\n"
              ~ "}\n"
              ~ "}\n";
    }
    return code;
}

private string[] splitNames(string css)
{
    string[] names;
    size_t start;
    foreach (i; 0 .. css.length + 1)
    {
        if (i == css.length || css[i] == ',')
        {
            size_t a = start, b = i;
            while (a < b && css[a] == ' ') a++;
            while (b > a && css[b - 1] == ' ') b--;
            if (b > a)
                names ~= css[a .. b];
            start = i + 1;
        }
    }
    return names;
}

private string capitalised(string s)
{
    import std.ascii : toUpper;
    return s.length ? toUpper(s[0]) ~ s[1 .. $] : s;
}

unittest
{
    import mayfair.properties.property;

    static class Thing
    {
        int reactions;
        mixin(declareProperty!(string, "text", `"start"`, q{ reactions++; }));
        mixin(declareReadOnlyProperty!(bool, "busy", "false"));

        void work() { _setBusy(true); }
    }

    // The same from fields
    static class Base { int reactions; }
    static class Counter : Base
    {
        mixin Properties;
        @observable private int _count;
        @observable private string _title = "Hi";
        void countChanged() { reactions++; }
    }
    static class Fancier : Counter
    {
        mixin Properties;
        @observable private bool _shiny;
    }
    auto c = new Counter;
    assert(c.count == 0 && c.title == "Hi");
    assert(c.count(3) is c && c.reactions == 1);
    c.setCount(3);
    assert(c.reactions == 1); // no change, no reaction
    int countHeard;
    c.countProperty.addListener((int was, int now) { countHeard = now; });
    c.countProperty.set(7);
    assert(c.count == 7 && countHeard == 7 && c.reactions == 2);
    auto f = new Fancier;
    f.setShiny(true);
    f.setTitle("Bye");
    assert(f.shiny && f.title == "Bye");
    static assert(!__traits(compiles, { static class Bad { mixin Properties; @observable int count; } }));

    auto t = new Thing;
    assert(t.text == "start");
    assert(t.text("a") is t && t.reactions == 1);
    static assert(is(typeof(t.text("a")) == Thing)); // chains as its own type
    t.setText("a");
    t.text("a");
    assert(t.reactions == 1); // no change, no reaction

    // Through the property, and from a binding, it reacts the same
    t.textProperty.set("b");
    assert(t.text == "b" && t.reactions == 2);
    auto source = new Property!string("c");
    t.textProperty.bind(source);
    assert(t.text == "c" && t.reactions == 3);
    source.set("d");
    assert(t.text == "d" && t.reactions == 4);

    // Read-only from outside
    bool heard;
    t.busyProperty.addListener((bool was, bool now) { heard = now; });
    t.work();
    assert(t.busy && heard);
    static assert(!__traits(compiles, t.busy(false)));
}
