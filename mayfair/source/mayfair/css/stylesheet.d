module mayfair.css.stylesheet;

import mayfair.css.parser;

/*
    A stylesheet, ready to style with. JavaFX's Stylesheet.

    One written into the program is parsed as it's compiled, and costs nothing at startup but
    indexing its rules the first time it's used:

        scene.stylesheets.add(stylesheet!(import("app.css")));

    (with the file's folder in dub's stringImportPaths). parse() does the same at runtime, for CSS
    the program only has once it's running.
*/
final class Stylesheet
{
public:
    /// Parses `css` now. Throws CssException for CSS that can't be parsed.
    static Stylesheet parse(string css)
    {
        immutable StylesheetData parsed = parseStylesheet(css); // pure, so it can be immutable as it is
        return new Stylesheet(new immutable(StylesheetData)(parsed.rules));
    }

    this(immutable(StylesheetData)* data)
    {
        this.data = data;
        index();
    }

    immutable(StylesheetData)* data;

package(mayfair):
    /// A selector of one of the rules, ready to match: which rule, which of its selectors, and
    /// each part's pseudo-classes as a mask of PseudoClass bits.
    static struct Entry
    {
        uint rule;
        uint selector;
        ulong[] pseudo; // per part, left to right
    }

    /*
        Selectors by what their last part needs: an id, a class (the first, if several), a type,
        or none of them. A widget only has to try those under its own id, classes and type, which
        is most of the reason browsers do the same.
    */
    Entry[][string] byId, byClass, byType;
    Entry[] universal;

private:
    void index()
    {
        foreach (r, rule; data.rules)
        {
            foreach (s, selector; rule.selectors)
            {
                Entry e;
                e.rule = cast(uint) r;
                e.selector = cast(uint) s;
                foreach (i, part; selector.parts)
                {
                    ulong mask;
                    foreach (name; part.pseudoClasses)
                        mask |= PseudoClass.get(name).bit;
                    e.pseudo ~= mask;
                    // What changing state could change: see PseudoClass.affects
                    if (i + 1 < selector.parts.length)
                        PseudoClass.inAncestors |= mask;
                    else
                        PseudoClass.inTargets |= mask;
                }
                const last = selector.parts[$ - 1];
                if (last.id.length)
                    byId[last.id] ~= e;
                else if (last.classes.length)
                    byClass[last.classes[0]] ~= e;
                else if (last.type.length)
                    byType[last.type] ~= e;
                else
                    universal ~= e;
            }
        }
    }
}

/*
    Where a styleable property's value came from, which decides what can replace it. JavaFX's
    StyleOrigin, in its order: the built-in theme gives way to code, and code to an app's
    stylesheets, and those to a widget's inline style.
*/
enum StyleOrigin : ubyte
{
    none,      /// Nothing's set it: it has the value it started with
    userAgent, /// The built-in theme, or whatever an app puts in its place
    user,      /// Code: a setter, or a binding
    author,    /// A stylesheet of the Scene's or a widget's
    inline,    /// A widget's own style string
}

/// The stylesheet `css`, parsed while the program is compiled. The same Stylesheet every time.
Stylesheet stylesheet(string css)()
{
    static immutable StylesheetData data = parseStylesheet(css);
    static Stylesheet sheet; // per thread, and styling happens on the UI thread
    if (!sheet)
        sheet = new Stylesheet(&data);
    return sheet;
}

/*
    A state a widget can be in that a selector can ask about: :hover, :focused, :disabled...
    JavaFX's PseudoClass. The kit's widgets switch their own on and off; a widget of an app's can
    have ones of its own, with PseudoClass.get("name") and Widget.pseudoClassStateChanged().

    Each is a bit, so a widget's states are one number and matching a selector's is a mask. That
    allows 64, which is far more than any toolkit's controls have used between them.
*/
struct PseudoClass
{
    ubyte index;

    ulong bit() const pure nothrow @safe @nogc { return 1UL << index; }

    /// The pseudo-class called `name`, the same one every time it's asked for.
    static PseudoClass get(string name)
    {
        foreach (i, n; names)
            if (n == name)
                return PseudoClass(cast(ubyte) i);
        if (names.length == 64)
            throw new Exception("More than 64 pseudo-classes: " ~ name);
        names ~= name;
        return PseudoClass(cast(ubyte)(names.length - 1));
    }

    string name() const nothrow @nogc { return names[index]; }

    /*
        How much a change in these states could restyle, from what the stylesheets in use ask
        about. A state only a selector's last part mentions -- `.button:hover` -- can only change
        the widget in that state; one an earlier part mentions -- `.button:hover .label` -- can
        change what's below it too. Most states are neither, and change nothing.
    */
    static bool affects(ulong changed) nothrow @nogc { return (changed & (inTargets | inAncestors)) != 0; }
    static bool affectsBelow(ulong changed) nothrow @nogc { return (changed & inAncestors) != 0; }

package(mayfair):
    static __gshared ulong inTargets, inAncestors;

private:
    static __gshared string[] names;
}

unittest
{
    auto sheet = stylesheet!(`.a:hover .b, #c { x: 1 } Row { y: 2 } * { z: 3 }`);
    assert(sheet is stylesheet!(`.a:hover .b, #c { x: 1 } Row { y: 2 } * { z: 3 }`));
    assert(sheet.byClass["b"].length == 1 && sheet.byId["c"].length == 1);
    assert(sheet.byType["Row"][0].rule == 1 && sheet.universal[0].rule == 2);
    const hover = PseudoClass.get("hover");
    assert(sheet.byClass["b"][0].pseudo == [hover.bit, 0]);
    assert(PseudoClass.affectsBelow(hover.bit));
    assert(PseudoClass.get("hover") == hover);
}
