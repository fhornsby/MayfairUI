module mayfair.properties.observable;

/// Told that a value has become out of date, without being told the new one. JavaFX's
/// InvalidationListener.
alias InvalidationListener = void delegate();

/// Told a value's old and new values when it changes. JavaFX's ChangeListener, less the
/// observable itself, which a D closure already has in hand.
alias ChangeListener(T) = void delegate(T oldValue, T newValue);

/// Something that can become out of date. JavaFX's Observable: what a Binding depends on,
/// whatever the type of its value.
interface Observable
{
    void addListener(InvalidationListener listener);
    void removeListener(InvalidationListener listener);
}

/// Stops a subscription, as JavaFX's Subscription.unsubscribe() does.
struct Subscription
{
    private void delegate() stop;

    void unsubscribe()
    {
        if (stop)
            stop();
        stop = null;
    }
}

/*
    A value that can be watched. JavaFX's ObservableValue: what Property, ReadOnlyProperty and
    Binding all are.

    There are two kinds of listener, as in JavaFX. An invalidation listener hears only that the
    value may have changed, and costs nothing to keep: a binding's value isn't worked out again
    until someone asks for it. A change listener hears the old and new values, which means working
    the new one out straight away, and hears nothing if it came out the same.

    Listeners run on whatever thread changed the value, which for anything a widget owns is the UI
    thread. They can add and remove listeners, including themselves, while being told.
*/
abstract class ObservableValue(T) : Observable
{
public:
    /// The current value.
    abstract T get();

    void addListener(InvalidationListener listener)
    {
        _invalidationListeners ~= listener;
    }

    void removeListener(InvalidationListener listener)
    {
        _invalidationListeners = without(_invalidationListeners, listener);
    }

    void addListener(ChangeListener!T listener)
    {
        if (!_changeListeners.length)
            _seen = get(); // what the first change will be measured from
        _changeListeners ~= listener;
    }

    void removeListener(ChangeListener!T listener)
    {
        _changeListeners = without(_changeListeners, listener);
    }

    /*
        Calls `action` with the value now, and again every time it changes, until unsubscribed.
        JavaFX's subscribe(Consumer): the one-liner for keeping something in step with a value
        from the start, where addListener would miss the value it starts with.
    */
    Subscription subscribe(void delegate(T value) action)
    {
        ChangeListener!T listener = (T oldValue, T newValue) { action(newValue); };
        addListener(listener);
        action(get());
        return Subscription({ removeListener(listener); });
    }

    /// A value worked out from this one, kept up to date with it. JavaFX's map().
    ObservableValue!U map(U)(U delegate(T value) f)
    {
        import mayfair.properties.binding : Binding;
        return new Binding!U(() => f(get()), this);
    }

protected:
    /// Tells every listener the value may have changed. The change listeners also get the old
    /// and new values -- if they differ.
    final void fireInvalidated()
    {
        // The arrays are replaced rather than changed when listeners are removed, so this walks
        // the ones there were when it started, whatever the listeners do
        foreach (listener; _invalidationListeners)
            listener();
        if (!_changeListeners.length)
            return;
        auto now = get();
        if (now == _seen)
            return;
        auto old = _seen;
        _seen = now;
        foreach (listener; _changeListeners)
            listener(old, now);
    }

private:
    InvalidationListener[] _invalidationListeners;
    ChangeListener!T[] _changeListeners;
    T _seen; // the value change listeners last heard of

    static L[] without(L)(L[] listeners, L listener)
    {
        foreach (i, l; listeners)
            if (l is listener)
                return listeners[0 .. i] ~ listeners[i + 1 .. $];
        return listeners;
    }
}
