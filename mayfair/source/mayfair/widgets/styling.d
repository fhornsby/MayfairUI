module mayfair.widgets.styling;

import core.stdc.stdio : fprintf, stderr;
import core.time : usecs;
import mayfair.animation;
import mayfair.css;
import mayfair.text;
import mayfair.theme;
import mayfair.widgets.region;
import mayfair.widgets.scene;
import mayfair.widgets.widget;

/*
    The style engine: which rules apply to a widget, which of their declarations win, and what
    that sets its properties to. It runs as a pass over the tree before layout, of the widgets
    whose styles could have changed since the last.

    What could have changed a widget's style is the tree around it or the widget itself: added
    to a scene, given a class or an id or an inline style, or put in a new state -- hovered,
    focused, pressed. Each marks it, and whatever a change can reach below it, for the next pass
    (see markCssDirty). A state no stylesheet asks about marks nothing.

    The cascade is CSS's. A declaration marked !important beats one that isn't; then an inline
    style beats a stylesheet of the app's, and those beat the built-in theme; then the more
    specific selector wins, then the later rule. What wins sets the property -- unless code has
    set it and it's only the theme saying otherwise (see StyleOrigin).

    A variable, like --base, is found from the widget being styled upwards, so a button that
    declares --base for itself changes every colour its rules derive from it, while the rest of
    the tree keeps the root's. The built-in theme is built that way: a palette on .root, and
    rules that say which colour of it they mean.
*/

/// A styleable property of a widget class, as its declaration registers it: see declareStyleableProperty.
struct CssProperty
{
    immutable(string)[] names;
    bool inherits;
    void function(Widget, const(Value)*[], StyleOrigin, ref StyleContext) apply;
    void function(Widget, ref StyleContext) reset;
}

/// Registers `property` as one of `type`'s. Before main() runs, from each property's declaration.
void registerStyleable(TypeInfo_Class type, CssProperty property) nothrow
{
    registered[type] ~= property;
}

/// What converting a value needs to know: which widget it's for, for variables.
struct StyleContext
{
    Widget widget;
    float em = Theme.text_size;
    bool animate; // whether a change can transition: not the first time a widget's styled

    /// The declared value of `name` for the widget, or the nearest ancestor that declares it --
    /// for a popup, the ancestors of what it's shown for (see styleParent).
    const(Value)* lookup(string name)
    {
        for (auto w = widget; w; w = styleParent(w))
            if (auto d = find(w.declared, name))
                return d.value;
        return null;
    }
}

/*
    Transitions, JavaFX 23's: a property that CSS changes moves to its new value over time, if the
    widget's `transition` says so, rather than jumping to it.

        .button { transition: background-colour 150ms ease-out, scale-x 90ms; }

    Only a change that CSS makes -- a state coming or going, a class added -- and never the first
    styling of a widget, nor a value set in code, which stops any transition on its way. A
    property already on its way to a value keeps going; one sent somewhere else sets off from
    wherever it's got to. What can't be interpolated -- a font, a keyword -- changes at once.
*/
struct TransitionSpec
{
    string property;      /// A CSS name, or "all"
    float duration = 0;   /// Milliseconds
    float delay = 0;      /// Milliseconds before it starts
    Interpolator timing = ease;

    enum Interpolator ease = Interpolator(0.25, 0.1, 0.25, 1); // CSS's default
}

/// Sets a styleable property to `target`, through a transition if the widget has one for it.
/// What a property's declaration generates calls, with `set` putting a value in the property.
void styleValue(T)(Widget w, ref StyleContext c, const(string)[] names, T current, T target, void delegate(T) set)
{
    static if (interpolatable!T)
    {
        auto running = runningTransition(w, names[0]);
        const spec = c.animate ? transitionFor(w.transitionSpecs, names) : null;
        if (spec && spec.duration + spec.delay > 0)
        {
            if (auto r = cast(StyleTransition!T) running)
                if (r.to == target)
                    return; // already on its way there
            if (running)
                running.animation.stop();
            if (current == target)
            {
                forget(w, names[0]);
                return;
            }
            auto t = new StyleTransition!T(names[0], current, target, *spec, set);
            if (running)
                w.runningTransitions[running.index] = t;
            else
                w.runningTransitions ~= t;
            t.animation.onFinished({ forget(w, t.property); });
            t.animation.play();
            return;
        }
        if (running)
        {
            running.animation.stop();
            forget(w, names[0]);
        }
    }
    set(target);
}

/*
    Where `w` takes its variables and inherited properties from: its parent, or for a popup, which
    has none, the widget it's shown for. So a menu opened from a card with its own --accent has
    it too, and everything in a popup follows the colour scheme as the window does. Selectors
    still go by the real tree: a popup isn't inside what opened it, as far as `.card .item` goes.
*/
Widget styleParent(Widget w) nothrow @nogc
{
    return w.parent ? w.parent : w.styleOwner;
}

/// Stops the transition of `w`'s property `name`, if one's running: code set it, and that's final.
void cancelStyleTransition(Widget w, string name)
{
    if (auto running = runningTransition(w, name))
    {
        running.animation.stop();
        forget(w, name);
    }
}

/*
    Turns what a stylesheet says into a property's value. False if it can't: a colour where a
    number belongs, or a variable nothing declares. Each property type has its overload;
    most take one value, and a composite like a font takes several (see CssProperty.names).
*/
bool convertStyle(T)(const(Value)*[] values, ref StyleContext c, out T result)
{
    static if (is(T == Font))
        return convertFont(values, c, result);
    else static if (is(T == Background))
        return convertBackground(values, c, result);
    else static if (is(T == Border))
        return convertBorder(values, c, result);
    else
    {
        if (!values[0])
            return false;
        return convert(*values[0], c, result);
    }
}

bool convert(const Value v, ref StyleContext c, out float result)
{
    if (v.kind != ValueKind.number)
        return false;
    result = points(v, c.em);
    return true;
}

bool convert(const Value v, ref StyleContext c, out bool result)
{
    if (v.isIdentifier("true"))
        result = true;
    else if (!v.isIdentifier("false"))
        return false;
    return true;
}

bool convert(const Value v, ref StyleContext c, out string result)
{
    if (v.kind != ValueKind.text && v.kind != ValueKind.identifier)
        return false;
    result = v.name;
    return true;
}

/// Four sides, CSS's way: one for all, two for top and bottom then the sides, or all four from the top.
bool convert(const Value v, ref StyleContext c, out Insets result)
{
    float[4] n;
    const items = v.spaced;
    if (items.length < 1 || items.length > 4)
        return false;
    foreach (i, item; items)
        if (!convert(item, c, n[i]))
            return false;
    final switch (items.length)
    {
        case 1: result = Insets(n[0]); break;
        case 2: result = Insets(n[0], n[1]); break;
        case 3: result = Insets(n[0], n[1], n[2], n[1]); break;
        case 4: result = Insets(n[0], n[1], n[2], n[3]); break;
    }
    return true;
}

/// An enum member, by its name in CSS's style: `centre-left` for Pos.centreLeft.
bool convert(E)(const Value v, ref StyleContext c, out E result) if (is(E == enum))
{
    if (v.kind != ValueKind.identifier)
        return false;
    static foreach (member; __traits(allMembers, E))
    {
        if (v.name == kebab(member))
        {
            result = __traits(getMember, E, member);
            return true;
        }
    }
    return false;
}

/// A colour: written out, looked up, or derived from one of those.
bool convert(const Value v, ref StyleContext c, out Colour result)
{
    return colour(v, c, result, 0);
}

private bool colour(const Value v, ref StyleContext c, out Colour result, int depth)
{
    if (depth > 16)
        return false; // a variable defined in terms of itself
    final switch (v.kind)
    {
        case ValueKind.colour:
            result = v.colour;
            return true;
        case ValueKind.identifier:
            return false; // a named colour is a colour already; anything else isn't one
        case ValueKind.function_:
            if (v.name == "var")
            {
                // The variable where it's declared, on this widget or above it; failing that the fallback
                auto found = c.lookup(v.items[0].name);
                if (found && colour(*found, c, result, depth + 1))
                    return true;
                return v.items.length == 2 && colour(v.items[1], c, result, depth + 1);
            }
            if (v.name == "derive" && v.items.length == 2 && v.items[1].kind == ValueKind.number)
            {
                Colour base;
                if (!colour(v.items[0], c, base, depth + 1))
                    return false;
                const by = v.items[1].unit == Unit.percent ? v.items[1].number / 100 : v.items[1].number;
                result = derive(base, by);
                return true;
            }
            if (v.name == "ladder" && v.items.length >= 2)
            {
                Colour base;
                if (!colour(v.items[0], c, base, depth + 1))
                    return false;
                Colour[] stops;
                float[] offsets;
                foreach (stop; v.items[1 .. $])
                {
                    Colour s;
                    if (stop.kind != ValueKind.list || stop.items.length != 2 || !colour(stop.items[0], c, s, depth + 1))
                        return false;
                    stops ~= s;
                    offsets ~= stop.items[1].unit == Unit.percent ? stop.items[1].number / 100 : stop.items[1].number;
                }
                result = ladder(base, stops, offsets);
                return true;
            }
            return false;
        case ValueKind.number, ValueKind.text, ValueKind.list, ValueKind.commas:
            return false;
    }
}

/// Corners from one to four numbers, from the top left clockwise, as CSS gives them.
bool convert(const Value v, ref StyleContext c, out CornerRadii result)
{
    Insets four; // the same one-to-four rule as insets, and the same order
    if (!convert(v, c, four))
        return false;
    result = CornerRadii(four.top, four.right, four.bottom, four.left);
    return true;
}

/*
    A background, from background-colour, background-radius and background-insets: a
    layer for each colour, and its radii and insets from the same place in the others' lists --
    or their last, if they're shorter, as JavaFX does.
*/
private bool convertBackground(const(Value)*[] values, ref StyleContext c, out Background result)
{
    if (!values[0])
        return true; // radii and insets with no colours: nothing to draw
    const colours = values[0].layers;
    auto fills = new BackgroundFill[colours.length];
    foreach (i, ref f; fills)
    {
        if (!convert(colours[i], c, f.fill))
            return false;
        if (values[1] && !convert(nth(values[1].layers, i), c, f.radii))
            return false;
        if (values[2] && !convert(nth(values[2].layers, i), c, f.insets))
            return false;
    }
    result.fills = fills;
    return true;
}

/// A border, the same way from border-colour, border-width, border-radius and border-insets.
private bool convertBorder(const(Value)*[] values, ref StyleContext c, out Border result)
{
    if (!values[0])
        return true;
    const colours = values[0].layers;
    auto strokes = new BorderStroke[colours.length];
    foreach (i, ref b; strokes)
    {
        // A colour per side is CSS's, but a stroke is one colour here: the first, the top's
        if (!convert(colours[i].spaced[0], c, b.colour))
            return false;
        if (values[1] && !convert(nth(values[1].layers, i).spaced[0], c, b.width))
            return false;
        if (values[2] && !convert(nth(values[2].layers, i), c, b.radii))
            return false;
        if (values[3] && !convert(nth(values[3].layers, i), c, b.insets))
            return false;
    }
    result.strokes = strokes;
    return true;
}

private const(Value) nth(const(Value)[] layers, size_t i)
{
    return layers[i < layers.length ? i : $ - 1];
}

/*
    A font, from font (JavaFX's shorthand: `italic bold 14px "Noto Sans"`) and the four it's
    short for, which override it: font-family, font-size, font-weight, font-style.
    In that order in `values`. A family that isn't installed, or "System", is the default font.
*/
private bool convertFont(const(Value)*[] values, ref StyleContext c, out Font result)
{
    string family;
    float size = Theme.text_size;
    FontWeight weight = FontWeight.regular;
    bool italic;

    bool style(const Value v)
    {
        if (v.isIdentifier("italic") || v.isIdentifier("oblique"))
            italic = true;
        else if (!v.isIdentifier("normal"))
            return false;
        return true;
    }
    bool weightOf(const Value v)
    {
        if (v.kind == ValueKind.number && v.unit == Unit.none && v.number >= 100 && v.number <= 900)
            weight = cast(FontWeight)(cast(int)(v.number / 100) * 100);
        else if (v.isIdentifier("bold") || v.isIdentifier("bolder"))
            weight = FontWeight.bold;
        else if (v.isIdentifier("normal"))
            weight = FontWeight.regular;
        else if (v.isIdentifier("lighter"))
            weight = FontWeight.light;
        else
            return false;
        return true;
    }
    bool sizeOf(const Value v)
    {
        if (v.kind != ValueKind.number || (v.unit == Unit.none && v.number >= 100))
            return false;
        size = v.unit == Unit.percent ? Theme.text_size * v.number / 100 : points(v, c.em);
        return true;
    }
    string familyOf(const Value v)
    {
        string name;
        foreach (item; v.spaced)
            name ~= (name.length ? " " : "") ~ item.name;
        return name;
    }

    if (auto shorthand = values[0])
    {
        const items = shorthand.spaced;
        size_t i;
        while (i < items.length && (style(items[i]) || weightOf(items[i])))
            i++;
        if (i >= items.length || !sizeOf(items[i]))
            return false;
        i++;
        foreach (item; items[i .. $])
            family ~= (family.length ? " " : "") ~ item.name;
    }
    if (values.length > 1 && values[1])
        family = familyOf(*values[1]);
    if (values.length > 2 && values[2] && !sizeOf(*values[2]))
        return false;
    if (values.length > 3 && values[3] && !weightOf(*values[3]))
        return false;
    if (values.length > 4 && values[4] && !style(*values[4]))
        return false;

    result = family.length && family != "System" ? font(family, size, weight, italic)
                                                 : defaultFont(size, weight, italic);
    return true;
}

/// Whether a property of type T can move smoothly from one value to another.
enum bool interpolatable(T) = is(T == float) || is(T == Colour) || is(T == Insets) || is(T == CornerRadii)
                              || is(T == Background) || is(T == Border);

/// The value `t` of the way from `a` to `b`. A background or border with a different number of
/// layers can't be blended, so it changes halfway, as CSS does with what it can't blend.
T interpolateStyle(T)(T a, T b, double t)
{
    static if (is(T == float))
        return cast(float)(a + (b - a) * t);
    else static if (is(T == Colour))
        return a.interpolate(b, t);
    else static if (is(T == Insets))
        return Insets(interpolateStyle(a.top, b.top, t), interpolateStyle(a.right, b.right, t),
                      interpolateStyle(a.bottom, b.bottom, t), interpolateStyle(a.left, b.left, t));
    else static if (is(T == CornerRadii))
        return CornerRadii(interpolateStyle(a.topLeft, b.topLeft, t), interpolateStyle(a.topRight, b.topRight, t),
                           interpolateStyle(a.bottomRight, b.bottomRight, t), interpolateStyle(a.bottomLeft, b.bottomLeft, t));
    else static if (is(T == Background))
    {
        if (a.fills.length != b.fills.length)
            return t < 0.5 ? a : b;
        auto fills = new BackgroundFill[a.fills.length];
        foreach (i, ref f; fills)
            f = BackgroundFill(interpolateStyle(a.fills[i].fill, b.fills[i].fill, t),
                               interpolateStyle(a.fills[i].radii, b.fills[i].radii, t),
                               interpolateStyle(a.fills[i].insets, b.fills[i].insets, t));
        Background result;
        result.fills = fills;
        return result;
    }
    else static if (is(T == Border))
    {
        if (a.strokes.length != b.strokes.length)
            return t < 0.5 ? a : b;
        auto strokes = new BorderStroke[a.strokes.length];
        foreach (i, ref s; strokes)
            s = BorderStroke(interpolateStyle(a.strokes[i].colour, b.strokes[i].colour, t),
                             interpolateStyle(a.strokes[i].width, b.strokes[i].width, t),
                             interpolateStyle(a.strokes[i].radii, b.strokes[i].radii, t),
                             interpolateStyle(a.strokes[i].insets, b.strokes[i].insets, t));
        Border result;
        result.strokes = strokes;
        return result;
    }
}

/// An enum member's name as CSS writes it: `centreLeft` as `centre-left`. A trailing _, for a D keyword, goes.
string kebab(string name) pure nothrow @safe
{
    string out_;
    foreach (ch; name)
    {
        if (ch == '_')
            continue;
        if (ch >= 'A' && ch <= 'Z')
            out_ ~= "-" ~ cast(char)(ch + 32);
        else
            out_ ~= ch;
    }
    return out_;
}

unittest
{
    static assert(kebab("centreLeft") == "centre-left" && kebab("default_") == "default");
}

/*
    A widget's style classes, JavaFX's getStyleClass(): the names `.button` selects by. A control
    has its own from the start -- a Button is "button" -- and an app adds its own:

        save.styleClass.add("primary");
*/
final class StyleClassList
{
    /// Adds each of `names` it doesn't have already.
    void add(string[] names...) nothrow
    {
        bool changed;
        foreach (n; names)
        {
            if (!contains(n))
            {
                _names ~= n;
                changed = true;
            }
        }
        if (changed)
            markCssDirty(_owner, true);
    }

    void remove(string name) nothrow
    {
        foreach (i, n; _names)
        {
            if (n == name)
            {
                _names = _names[0 .. i] ~ _names[i + 1 .. $];
                markCssDirty(_owner, true);
                return;
            }
        }
    }

    bool contains(string name) const nothrow @nogc
    {
        foreach (n; _names)
            if (n == name)
                return true;
        return false;
    }

    const(string)[] names() const nothrow @nogc { return _names; }
    size_t length() const nothrow @nogc { return _names.length; }

package:
    this(Widget owner) nothrow
    {
        _owner = owner;
    }

private:
    Widget _owner;
    string[] _names;
}

/// Stylesheets that style a tree: a Scene's, or a widget's for everything below it. JavaFX's
/// getStylesheets(). Changing them restyles what they style.
final class StylesheetList
{
    void add(Stylesheet sheet)
    {
        _sheets ~= sheet;
        _changed();
    }

    void remove(Stylesheet sheet)
    {
        foreach (i, s; _sheets)
        {
            if (s is sheet)
            {
                _sheets = _sheets[0 .. i] ~ _sheets[i + 1 .. $];
                _changed();
                return;
            }
        }
    }

    void clear()
    {
        _sheets = null;
        _changed();
    }

    inout(Stylesheet)[] sheets() inout nothrow @nogc { return _sheets; }

package:
    this(void delegate() changed) nothrow
    {
        _changed = changed;
    }

private:
    Stylesheet[] _sheets;
    void delegate() _changed;
}

/*
    Marks `w` for restyling in the next pass, and everything below it too if `below`: it's been
    added to a scene, or its classes changed, which a descendant's selector could mention.
*/
void markCssDirty(Widget w, bool below) nothrow @nogc
{
    if (!w)
        return;
    w.cssDirty = true;
    if (below)
        w.cssBelow = true;
    for (auto p = w.parent; p && !p.cssChildDirty; p = p.parent)
        p.cssChildDirty = true;
    if (w.scene)
        w.scene.cssRequested = true;
}

/// The pseudo-class `name`, found once. For a widget's own states, as it changes them.
PseudoClass pseudo(string name)()
{
    static PseudoClass pc;
    static bool found;
    if (!found)
    {
        pc = PseudoClass.get(name);
        found = true;
    }
    return pc;
}

/// A widget's pseudo-class `pc` going on or off.
void pseudoClassChanged(Widget w, PseudoClass pc, bool on) nothrow @nogc
{
    const was = w.pseudoClasses;
    w.pseudoClasses = on ? was | pc.bit : was & ~pc.bit;
    if (w.pseudoClasses == was || !PseudoClass.affects(pc.bit))
        return;
    markCssDirty(w, PseudoClass.affectsBelow(pc.bit));
}

package(mayfair):

/// A transition on its way, of one of a widget's properties.
abstract class RunningTransition
{
    string property;
    Transition animation;
    size_t index; // where it is in the widget's list, as runningTransition() found it
}

/// Stops every transition of `w`'s: it's leaving the scene.
void stopTransitions(Widget w)
{
    foreach (t; w.runningTransitions)
        t.animation.stop();
    w.runningTransitions = null;
}

/// A declaration that won, for one property of one widget: what's looked up and inherited.
struct Declared
{
    string name;
    const(Value)* value;
    StyleOrigin origin;
}

/// The style pass: restyles whatever's been marked in `scene`'s tree since the last one.
void applyCss(Scene scene)
{
    if (!scene.cssRequested || !scene.root)
        return;
    scene.cssRequested = false;
    restyleTree(scene, scene.root, false);
    foreach (p; scene.popups)
        restyleTree(scene, p, false);
}

private:

final class StyleTransition(T) : RunningTransition
{
    T from, to;

    this(string property, T from, T to, TransitionSpec spec, void delegate(T) set)
    {
        this.property = property;
        this.from = from;
        this.to = to;
        // The delay is the first part of the animation's time, with the curve over the rest
        const total = spec.delay + spec.duration;
        const start = total > 0 ? spec.delay / total : 0;
        const timing = spec.timing;
        animation = new Transition((cast(long)(total * 1000)).usecs, (double linear) {
            const t = linear <= start ? 0 : start >= 1 ? 1 : timing.curve((linear - start) / (1 - start));
            set(interpolateStyle(this.from, this.to, t));
        }).interpolator(Interpolator.linear);
    }
}

RunningTransition runningTransition(Widget w, string property)
{
    foreach (i, t; w.runningTransitions)
    {
        if (t.property == property)
        {
            t.index = i;
            return t;
        }
    }
    return null;
}

void forget(Widget w, string property)
{
    foreach (i, t; w.runningTransitions)
    {
        if (t.property == property)
        {
            w.runningTransitions = w.runningTransitions[0 .. i] ~ w.runningTransitions[i + 1 .. $];
            return;
        }
    }
}

const(TransitionSpec)* transitionFor(const(TransitionSpec)[] specs, const(string)[] names)
{
    // The last that names it wins, as CSS's lists do
    foreach_reverse (ref s; specs)
    {
        if (s.property == "all")
            return &s;
        foreach (n; names)
            if (s.property == n)
                return &s;
    }
    return null;
}

/*
    A widget's transitions, from its declarations: `transition`, or its longhands if
    transition-property is declared, whose lists pair up by position and repeat as CSS's do.
*/
TransitionSpec[] transitionsOf(const(Declared)[] declared)
{
    static bool timingOf(const Value v, ref Interpolator result)
    {
        if (v.kind == ValueKind.function_ && v.name == "cubic-bezier" && v.items.length == 4)
        {
            result = Interpolator(v.items[0].number, v.items[1].number, v.items[2].number, v.items[3].number);
            return true;
        }
        if (v.kind != ValueKind.identifier)
            return false;
        switch (v.name)
        {
            case "ease": result = TransitionSpec.ease; return true;
            case "linear": result = Interpolator.linear; return true;
            case "ease-in": result = Interpolator.easeIn; return true;
            case "ease-out": result = Interpolator.easeOut; return true;
            case "ease-in-out": result = Interpolator.easeBoth; return true;
            default: return false;
        }
    }
    static bool isTime(const Value v) { return v.kind == ValueKind.number && (v.unit == Unit.ms || v.unit == Unit.s); }

    TransitionSpec[] specs;
    if (auto properties = find(declared, "transition-property"))
    {
        const(Value)[] durations, delays, timings;
        if (auto d = find(declared, "transition-duration")) durations = d.value.layers;
        if (auto d = find(declared, "transition-delay")) delays = d.value.layers;
        if (auto d = find(declared, "transition-timing-function")) timings = d.value.layers;
        foreach (i, p; properties.value.layers)
        {
            TransitionSpec s;
            s.property = p.name;
            if (durations.length) s.duration = milliseconds(durations[i % durations.length]);
            if (delays.length) s.delay = milliseconds(delays[i % delays.length]);
            if (timings.length) timingOf(timings[i % timings.length], s.timing);
            specs ~= s;
        }
        return specs;
    }
    if (auto shorthand = find(declared, "transition"))
    {
        foreach (layer; shorthand.value.layers)
        {
            TransitionSpec s;
            s.property = "all";
            bool timed;
            foreach (item; layer.spaced)
            {
                if (isTime(item))
                {
                    if (!timed) s.duration = milliseconds(item);
                    else s.delay = milliseconds(item);
                    timed = true;
                }
                else if (!timingOf(item, s.timing) && item.kind == ValueKind.identifier)
                    s.property = item.name;
            }
            specs ~= s;
        }
    }
    return specs;
}

__gshared CssProperty[][TypeInfo_Class] registered;
const(CssProperty)[][TypeInfo_Class] everyProperty; // a class's and all it inherits, worked out once

const(CssProperty)[] propertiesOf(TypeInfo_Class type)
{
    if (auto known = type in everyProperty)
        return *known;
    const(CssProperty)[] all;
    for (auto t = type; t; t = t.base)
        if (auto own = t in registered)
            all ~= *own;
    everyProperty[type] = all;
    return all;
}

void restyleTree(Scene scene, Widget w, bool force)
{
    bool below = force || w.cssBelow;
    if (force || w.cssDirty)
    {
        // Its declarations are what its children look up and inherit, so if they changed, so might theirs
        if (restyle(scene, w))
            below = true;
        w.runRestyled();
    }
    const children = below || w.cssChildDirty;
    w.cssDirty = w.cssBelow = w.cssChildDirty = false;
    if (w.updateRequested)
    {
        w.updateRequested = false;
        w.runUpdate();
    }
    if (children)
        foreach (child; w.children)
            restyleTree(scene, cast() child, below);
}

struct Candidate
{
    const(Declaration)* declaration;
    StyleOrigin origin;
    uint specificity;
    uint order;

    // Which of two declarations of a property wins: the greater
    int opCmp(ref const Candidate other) const
    {
        if (declaration.important != other.declaration.important)
            return declaration.important ? 1 : -1;
        if (origin != other.origin)
            return origin < other.origin ? -1 : 1;
        if (specificity != other.specificity)
            return specificity < other.specificity ? -1 : 1;
        return order < other.order ? -1 : order > other.order ? 1 : 0;
    }
}

/// Works out `w`'s declarations and sets its properties from them. Whether its declarations changed.
bool restyle(Scene scene, Widget w)
{
    Candidate[] found;
    uint sheetOrder;
    const scheme = scene.effectiveColourScheme;
    void from(Stylesheet sheet, StyleOrigin origin)
    {
        if (sheet)
            gather(sheet, origin, sheetOrder++, w, scheme, found);
    }
    from(scene.userAgentStylesheet ? scene.userAgentStylesheet : defaultUserAgentStylesheet, StyleOrigin.userAgent);
    foreach (sheet; scene.stylesheets.sheets)
        from(sheet, StyleOrigin.author);
    // The widgets' own, outermost first, so the nearest wins a tie
    Widget[] chain;
    for (auto a = w; a; a = a.parent)
        if (a.ownStylesheets && a.ownStylesheets.sheets.length)
            chain ~= a;
    foreach_reverse (a; chain)
        foreach (sheet; a.ownStylesheets.sheets)
            from(sheet, StyleOrigin.author);
    foreach (ref d; w.inlineDeclarations)
        found ~= Candidate(&d, StyleOrigin.inline, uint.max, uint.max);

    // The winner for each property: sorted by name, then cascade, and the last of each name wins
    import std.algorithm.sorting : sort;
    found.sort!((a, b) => a.declaration.property < b.declaration.property
                          || (a.declaration.property == b.declaration.property && a < b));
    Declared[] declared;
    foreach (i, ref c; found)
        if (i + 1 == found.length || found[i + 1].declaration.property != c.declaration.property)
            declared ~= Declared(c.declaration.property, &c.declaration.value, c.origin);

    const changed = declared != w.declared;
    w.declared = declared;
    w.transitionSpecs = transitionsOf(declared);

    auto context = StyleContext(w);
    context.animate = w.styled; // the first styling sets things as they are, with nothing to move from
    scope (exit) w.styled = true;
    foreach (ref property; propertiesOf(typeid(w)))
    {
        const(Value)*[8] values;
        StyleOrigin origin;
        bool any;
        foreach (i, name; property.names)
        {
            auto d = find(declared, name);
            if (!d && property.inherits)
                for (auto a = styleParent(w); a && !d; a = styleParent(a))
                    d = find(a.declared, name);
            if (d)
            {
                values[i] = d.value;
                if (d.origin > origin)
                    origin = d.origin;
                any = true;
            }
        }
        if (any)
        {
            try
                property.apply(w, values[0 .. property.names.length], origin, context);
            catch (Exception e)
                warn(property.names[0], e.msg);
        }
        else
            property.reset(w, context);
    }
    return changed;
}

void gather(Stylesheet sheet, StyleOrigin origin, uint sheetOrder, Widget w, ColourScheme scheme, ref Candidate[] found)
{
    void consider(const(Stylesheet.Entry)[] entries)
    {
        foreach (ref e; entries)
        {
            const rule = &sheet.data.rules[e.rule];
            if ((rule.media == Media.dark && scheme != ColourScheme.dark)
                || (rule.media == Media.light && scheme != ColourScheme.light))
                continue;
            const selector = &rule.selectors[e.selector];
            if (!matches(*selector, e.pseudo, selector.parts.length - 1, w))
                continue;
            foreach (ref d; rule.declarations)
                found ~= Candidate(&d, origin, selector.specificity, sheetOrder << 20 | e.rule);
        }
    }
    consider(sheet.universal);
    if (auto e = typeSelector(w) in sheet.byType)
        consider(*e);
    foreach (c; w.styleClassNames)
        if (auto e = c in sheet.byClass)
            consider(*e);
    if (w.id.length)
        if (auto e = w.id in sheet.byId)
            consider(*e);
}

// Whether the selector's parts up to `i` match `w` and what's above it, matching right to left
bool matches(const Selector s, const(ulong)[] pseudo, size_t i, Widget w)
{
    if (!matchesPart(s.parts[i], pseudo[i], w))
        return false;
    if (i == 0)
        return true;
    if (s.combinators[i - 1] == Combinator.child)
        return w.parent && matches(s, pseudo, i - 1, w.parent);
    for (auto a = w.parent; a; a = a.parent)
        if (matches(s, pseudo, i - 1, a))
            return true;
    return false;
}

bool matchesPart(const Compound c, ulong pseudo, Widget w)
{
    if ((w.pseudoClasses & pseudo) != pseudo)
        return false;
    if (c.type.length && c.type != typeSelector(w))
        return false;
    if (c.id.length && c.id != w.id)
        return false;
    foreach (cls; c.classes)
        if (!w.hasStyleClass(cls))
            return false;
    return true;
}

/// What a type selector names a widget by: its class's name, as JavaFX's do. `Button`.
string typeSelector(Widget w) nothrow @nogc
{
    const full = typeid(w).name;
    foreach_reverse (i, ch; full)
        if (ch == '.')
            return full[i + 1 .. $];
    return full;
}

const(Declared)* find(const(Declared)[] declared, string name) nothrow @nogc
{
    size_t lo = 0, hi = declared.length;
    while (lo < hi)
    {
        const mid = (lo + hi) / 2;
        if (declared[mid].name < name)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo < declared.length && declared[lo].name == name ? &declared[lo] : null;
}

void warn(string property, string what)
{
    fprintf(stderr, "CSS: %.*s: %.*s\n", cast(int) property.length, property.ptr, cast(int) what.length, what.ptr);
}

/// The built-in theme, until an app gives its scene another. See theme/mayfair.css.
Stylesheet defaultUserAgentStylesheet()
{
    return stylesheet!(import("mayfair.css"));
}
