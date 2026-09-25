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
    declare!T(name, initial, changed, false, "");

/// ditto
enum string declareReadOnlyProperty(T, string name, string initial, string changed = "",
                                    string setterVisibility = "private") =
    declare!T(name, initial, changed, true, setterVisibility);

private string declare(T)(string name, string initial, string changed, bool readOnly, string setterVisibility)
{
    const type = T.stringof;
    const field = "_" ~ name;
    const object = "_" ~ name ~ "Property";
    const listener = "_" ~ name ~ "Invalidated";
    // A class-typed value can't come back out of a const getter as mutable, so only value types
    // get the const one
    const getterAttributes = is(T == class) ? "nothrow @nogc" : "const nothrow @nogc";
    const propertyType = readOnly ? "ReadOnlyWrapper!(" ~ type ~ ")" : "Property!(" ~ type ~ ")";

    string code;
    code ~= "private " ~ type ~ " " ~ field ~ " = " ~ initial ~ ";\n";
    code ~= "private " ~ propertyType ~ " " ~ object ~ ";\n";
    code ~= "final " ~ type ~ " " ~ name ~ "() " ~ getterAttributes ~ " { return " ~ field ~ "; }\n";

    // The setter: through the property if there is one, which tells its listeners and so this
    const setter = readOnly ? setterVisibility ~ " final void _set" ~ capitalised(name)
                            : "public final void set" ~ capitalised(name);
    code ~= setter ~ "(" ~ type ~ " value)\n{\n"
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
          ~ "    auto value = " ~ object ~ ".get();\n"
          ~ "    if (value == " ~ field ~ ") return;\n"
          ~ "    " ~ field ~ " = value;\n"
          ~ "    " ~ changed ~ "\n"
          ~ "}\n";
    return code;
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
