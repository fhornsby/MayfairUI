module mayfair.properties.property;

import mayfair.properties.observable;

/*
    A value that can be set, watched, and bound to another. JavaFX's Property.

        auto name = new Property!string("");
        name.addListener((string was, string now) { writeln(now); });
        name.set("Ada");

    Bound to another observable value, it takes that value, and keeps taking it: setting it
    yourself is then an error, as it is in JavaFX, until it's unbound. It picks the value up
    lazily, as JavaFX's do -- not when the source changes, but when it's next asked -- so a chain
    of bindings does no work that nothing looks at.

    Bound both ways to another property with bindBidirectional, each takes the other's value
    whenever it's set: a slider and a text field showing the same number, say.

    Every setting on a widget is one of these (see declareProperty), so anything a widget shows
    can be bound to anything else.
*/
class Property(T) : ObservableValue!T
{
public:
    this(T initial = T.init)
    {
        _value = initial;
    }

    override T get()
    {
        if (!_valid)
        {
            _value = _source.get();
            _valid = true;
        }
        return _value;
    }

    /// Sets the value. An error while it's bound: it follows its source then.
    void set(T value)
    {
        if (_source)
            throw new Exception("A bound value cannot be set: unbind it first");
        if (value == _value)
            return;
        _value = value;
        fireInvalidated();
    }

    /// Makes this take `source`'s value from now on, until unbind() or another bind().
    void bind(ObservableValue!T source)
    {
        if (source is this)
            throw new Exception("A property can't be bound to itself");
        unbind();
        _source = source;
        source.addListener(&sourceInvalidated);
        _valid = false;
        fireInvalidated();
    }

    /// Stops following the source, keeping the value it had.
    void unbind()
    {
        if (!_source)
            return;
        _value = get();
        _source.removeListener(&sourceInvalidated);
        _source = null;
        _valid = true;
    }

    bool isBound() const nothrow @nogc { return _source !is null; }

    /*
        Keeps this and `other` the same both ways: setting either sets the other. This takes
        other's value to start with. Neither is bound in the one-way sense, so either can still be
        set; it's JavaFX's bindBidirectional.
    */
    void bindBidirectional(Property!T other)
    {
        if (other is this)
            throw new Exception("A property can't be bound to itself");
        set(other.get());
        auto link = new BidirectionalLink!T(this, other);
        _links ~= link;
        other._links ~= link;
    }

    void unbindBidirectional(Property!T other)
    {
        foreach (link; _links)
        {
            if (link.other(this) is other)
            {
                link.cut();
                _links = without(_links, link);
                other._links = without(other._links, link);
                return;
            }
        }
    }

private:
    T _value;
    bool _valid = true;
    ObservableValue!T _source;
    BidirectionalLink!T[] _links;

    void sourceInvalidated()
    {
        if (!_valid)
            return; // already out of date, and everything after it already told so
        _valid = false;
        fireInvalidated();
    }

    static L[] without(L)(L[] links, L link)
    {
        foreach (i, l; links)
            if (l is link)
                return links[0 .. i] ~ links[i + 1 .. $];
        return links;
    }
}

// Two properties kept equal: each one's change sets the other, with a guard so the echo stops there
private final class BidirectionalLink(T)
{
    Property!T a, b;
    bool updating;

    this(Property!T a, Property!T b)
    {
        this.a = a;
        this.b = b;
        a.addListener(&aChanged);
        b.addListener(&bChanged);
    }

    Property!T other(Property!T p) { return p is a ? b : a; }

    void cut()
    {
        a.removeListener(&aChanged);
        b.removeListener(&bChanged);
    }

    void aChanged(T was, T now) { copy(b, now); }
    void bChanged(T was, T now) { copy(a, now); }

    void copy(Property!T to, T value)
    {
        if (updating)
            return;
        updating = true;
        scope(exit) updating = false;
        to.set(value);
    }
}

/*
    A property that can be watched but not set, except by whoever owns it. JavaFX's
    ReadOnlyProperty: what a widget hands out for state it reports rather than takes -- whether
    the pointer's over it, where the caret is.

    The owner keeps a ReadOnlyWrapper, which it can set, and hands out the wrapper's
    readOnlyProperty(), which follows it.
*/
class ReadOnlyProperty(T) : ObservableValue!T
{
    override T get() { return _wrapper.get(); }

private:
    ReadOnlyWrapper!T _wrapper;

    this(ReadOnlyWrapper!T wrapper)
    {
        _wrapper = wrapper;
        wrapper.addListener(&fireInvalidated);
    }
}

/// The owner's side of a ReadOnlyProperty: a Property it can set, and a read-only view of it to
/// hand out. JavaFX's ReadOnlyObjectWrapper.
class ReadOnlyWrapper(T) : Property!T
{
    this(T initial = T.init)
    {
        super(initial);
    }

    /// The view to hand out, which can be watched and bound to but not set.
    ReadOnlyProperty!T readOnlyProperty()
    {
        if (!_view)
            _view = new ReadOnlyProperty!T(this);
        return _view;
    }

private:
    ReadOnlyProperty!T _view;
}

unittest
{
    auto p = new Property!int(1);
    int[] changes;
    int invalidations;
    p.addListener((int was, int now) { changes ~= [was, now]; });
    p.addListener({ invalidations++; });
    p.set(2);
    p.set(2); // no change, no news
    assert(p.get == 2 && changes == [1, 2] && invalidations == 1);

    // Bound, it follows its source, lazily, and can't be set
    auto source = new Property!int(10);
    p.bind(source);
    assert(p.isBound && p.get == 10 && changes == [1, 2, 2, 10]);
    source.set(11);
    assert(p.get == 11);
    bool threw;
    try p.set(5); catch (Exception) threw = true;
    assert(threw);
    p.unbind();
    source.set(12);
    assert(p.get == 11 && !p.isBound);

    // Both ways
    auto a = new Property!string("a"), b = new Property!string("b");
    a.bindBidirectional(b);
    assert(a.get == "b");
    a.set("x");
    assert(b.get == "x");
    b.set("y");
    assert(a.get == "y");
    a.unbindBidirectional(b);
    b.set("z");
    assert(a.get == "y");

    // subscribe hears the value now and every change, until unsubscribed
    int[] seen;
    auto s = source.subscribe((int v) { seen ~= v; });
    source.set(13);
    s.unsubscribe();
    source.set(14);
    assert(seen == [12, 13]);

    // Read-only: watchable, bindable to, not settable from outside
    auto wrapper = new ReadOnlyWrapper!bool(false);
    auto view = wrapper.readOnlyProperty;
    bool heard;
    view.addListener((bool was, bool now) { heard = now; });
    wrapper.set(true);
    assert(view.get && heard);
    static assert(!__traits(compiles, view.set(false)));
}
