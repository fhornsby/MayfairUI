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

private string declare(T)(string name, string initial, string changed, bool readOnly, string setterVisibility,
                          string css, bool inherits)
{
    const type = T.stringof;
    const field = "_" ~ name;
    const object = "_" ~ name ~ "Property";
    const listener = "_" ~ name ~ "Invalidated";
    // A class, or a struct holding an array, can't come back out of a const getter as mutable,
    // so only what converts from const gets the const one
    const getterAttributes = is(const(T) : T) ? "const nothrow @nogc" : "nothrow @nogc";
    const propertyType = readOnly ? "ReadOnlyWrapper!(" ~ type ~ ")" : "Property!(" ~ type ~ ")";

    string code;
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
