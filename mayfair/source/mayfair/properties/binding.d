module mayfair.properties.binding;

import mayfair.properties.observable;

/*
    A value worked out from others, and kept up to date with them. JavaFX's Binding.

        auto greeting = binding(() => "Hello, " ~ name.get, name);
        label.textProperty.bind(greeting);

    It lists what it depends on, and when any of them changes it marks itself out of date and
    says so; the value is worked out again only when next asked for. Anything bound to it asks
    straight away if it's showing on screen, and not at all if nothing's looking.

    The helpers below -- not, and, or, isEmpty, isEqualTo, greaterThan and friends, plus map on
    any ObservableValue -- make the common cases one call, as JavaFX's fluent API does:

        ok.disableProperty.bind(name.textProperty.isEmpty);
*/
class Binding(T) : ObservableValue!T
{
public:
    this(T delegate() compute, Observable[] dependencies...)
    {
        _compute = compute;
        _dependencies = dependencies.dup;
        foreach (d; _dependencies)
            d.addListener(&dependencyInvalidated);
    }

    override T get()
    {
        if (!_valid)
        {
            _value = _compute();
            _valid = true;
        }
        return _value;
    }

    /// Stops listening to what it depends on, so that it can be let go of while they live on.
    void dispose()
    {
        foreach (d; _dependencies)
            d.removeListener(&dependencyInvalidated);
        _dependencies = null;
    }

private:
    T delegate() _compute;
    Observable[] _dependencies;
    T _value;
    bool _valid;

    void dependencyInvalidated()
    {
        if (!_valid)
            return;
        _valid = false;
        fireInvalidated();
    }
}

/// A Binding worked out by `compute` from `dependencies`. JavaFX's Bindings.createObjectBinding.
Binding!T binding(T)(T delegate() compute, Observable[] dependencies...)
{
    return new Binding!T(compute, dependencies);
}

// The fluent helpers. Each is a Binding over the value, or values, it's called on.

ObservableValue!bool not(ObservableValue!bool a) { return binding(() => !a.get, a); }
ObservableValue!bool and(ObservableValue!bool a, ObservableValue!bool b) { return binding(() => a.get && b.get, a, b); }
ObservableValue!bool or(ObservableValue!bool a, ObservableValue!bool b) { return binding(() => a.get || b.get, a, b); }

ObservableValue!bool isEmpty(ObservableValue!string a) { return binding(() => a.get.length == 0, a); }
ObservableValue!bool isNotEmpty(ObservableValue!string a) { return binding(() => a.get.length != 0, a); }
ObservableValue!size_t length(ObservableValue!string a) { return binding(() => a.get.length, a); }
ObservableValue!string concat(ObservableValue!string a, ObservableValue!string b) { return binding(() => a.get ~ b.get, a, b); }

ObservableValue!bool isEqualTo(T)(ObservableValue!T a, T value) { return binding(() => a.get == value, a); }
ObservableValue!bool isEqualTo(T)(ObservableValue!T a, ObservableValue!T b) { return binding(() => a.get == b.get, a, b); }
ObservableValue!bool isNotEqualTo(T)(ObservableValue!T a, T value) { return binding(() => a.get != value, a); }

ObservableValue!bool greaterThan(T)(ObservableValue!T a, T value) { return binding(() => a.get > value, a); }
ObservableValue!bool lessThan(T)(ObservableValue!T a, T value) { return binding(() => a.get < value, a); }

ObservableValue!T add(T)(ObservableValue!T a, T value) { return binding(() => cast(T)(a.get + value), a); }
ObservableValue!T add(T)(ObservableValue!T a, ObservableValue!T b) { return binding(() => cast(T)(a.get + b.get), a, b); }
ObservableValue!T subtract(T)(ObservableValue!T a, T value) { return binding(() => cast(T)(a.get - value), a); }
ObservableValue!T multiply(T)(ObservableValue!T a, T value) { return binding(() => cast(T)(a.get * value), a); }
ObservableValue!T divide(T)(ObservableValue!T a, T value) { return binding(() => cast(T)(a.get / value), a); }
ObservableValue!T negate(T)(ObservableValue!T a) { return binding(() => cast(T)(-a.get), a); }

/// Whichever of two values `condition` picks. JavaFX's Bindings.when(...).then(...).otherwise(...).
ObservableValue!T when(T)(ObservableValue!bool condition, T then, T otherwise)
{
    return binding(() => condition.get ? then : otherwise, condition);
}

unittest
{
    import mayfair.properties.property;

    auto first = new Property!string("Ada");
    auto last = new Property!string("Lovelace");
    int computed;
    auto full = binding(() { computed++; return first.get ~ " " ~ last.get; }, first, last);

    // Worked out when asked, and not again until something it depends on changes
    assert(full.get == "Ada Lovelace" && full.get == "Ada Lovelace" && computed == 1);
    first.set("Augusta");
    last.set("King");
    assert(computed == 1); // nobody asked
    assert(full.get == "Augusta King" && computed == 2);

    // Bound to, it keeps a property up to date
    auto label = new Property!string;
    label.bind(full);
    first.set("Ada");
    assert(label.get == "Ada King");

    // The fluent helpers
    auto name = new Property!string("");
    auto disabled = new Property!bool;
    disabled.bind(name.isEmpty);
    assert(disabled.get);
    name.set("x");
    assert(!disabled.get);
    assert(name.isNotEmpty.and(new Property!bool(true)).get);
    assert(name.isEqualTo("x").get && !name.isEqualTo("y").get);
    auto n = new Property!int(3);
    assert(n.add(2).get == 5 && n.multiply(4).get == 12 && n.greaterThan(2).get);
    assert(n.map((int v) => v * 10).get == 30);
    assert(n.greaterThan(5).when("big", "small").get == "small");

    // A change listener on a binding hears each actual change
    string[] heard;
    full.addListener((string was, string now) { heard ~= now; });
    last.set("Byron");
    assert(heard == ["Ada Byron"]);
}
