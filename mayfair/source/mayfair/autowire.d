module mayfair.autowire;

import core.sync.mutex : Mutex;
import std.meta : AliasSeq;
import std.traits : BaseClassesTuple, fullyQualifiedName, getUDAs, hasUDA;

/*
    Services a view asks for by type, without a constructor to pass them through: Spring's
    @Autowired, worked out as the program's compiled rather than by reflection when it runs.

        void main()
        {
            auto app = new App("Books");
            app.registerService(new Library("books.db"))   // anything the app's views share: a
               .registerService(new Settings);             // database, a web API's client, settings
            app.scene = new Scene(View.load(new Main));
            app.run();
        }

        @View("main.xml")
        class Main
        {
            @xml Label status;
            @autowired Library library;         // filled in by View.load, before initialise()

            void initialise() { status.setText(library.title); }
        }

    View.load fills a controller's @autowired fields before it builds the view, so they're there
    for initialise() and every handler. So are those of an app's own widgets that a view makes
    (<BookList/> with an @autowired field of its own), and of a widget with a view of its own,
    loading it with View.load(this). Anything else -- a page made with `new`, say -- is filled in
    by autowire(), which returns it:

        auto details = autowire(new BookDetails(book));

    Which fields to fill is worked out for each class as it's compiled, from its own fields and
    its base classes', private ones too, as @xml's are. Only finding each service happens when
    it runs, by the type the field is declared with: registerService!Storage(new DiskStorage) for
    a field that's a Storage. A field already set is left alone, so a test can hand a view a
    stand-in before loading it. Nothing registered for a field is an AutowireException naming the
    class, the field and its type, unless it's marked @Autowired(required: false), which leaves it
    null.

    The services are the App's, and the App's the one made last (one runs at a time), so a view
    needs no App handed to it to find them. They're registered before the app runs and only read
    after, so a background thread can use them through the view, or with
    App.current.service!Library(). (App.current is the same App on every thread: a plain variable
    at module level is the thread's own in D, and null on any other, the trap this saves an app
    from.)
*/

/// Marks a field to fill with the service registered for its type.
enum autowired = Autowired.init;

/// ditto. `@Autowired(required: false)` leaves the field null when nothing's registered for it.
struct Autowired
{
    bool required = true;
}

/// Thrown when an @autowired field's type has nothing registered for it.
class AutowireException : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(message, file, line);
    }
}

/// An App's services, by the type each was registered as. Safe to use from any thread.
final class Services
{
    /// Makes `service` what fills @autowired fields of type T, replacing any T registered before.
    void add(T)(T service) if (is(T == class) || is(T == interface))
    {
        if (service is null)
            throw new AutowireException("registerService!" ~ T.stringof ~ " was given null; to take a service away, "
                                        ~ "use unregisterService");
        synchronized (lock)
            entries[typeid(T)] = cast(Object) service;
    }

    /// Takes away the service registered for T, if there is one.
    void remove(T)() if (is(T == class) || is(T == interface))
    {
        synchronized (lock)
            entries.remove(typeid(T));
    }

    /// Whether something's registered for T.
    bool has(T)() if (is(T == class) || is(T == interface))
    {
        return find!T() !is null;
    }

    /// The service registered for T. Throws an AutowireException if there isn't one.
    T get(T)() if (is(T == class) || is(T == interface))
    {
        auto service = find!T();
        if (service is null)
            throw new AutowireException("nothing is registered as " ~ fullyQualifiedName!T
                                        ~ "; give the App one with registerService()");
        return service;
    }

    /// The service registered for T, or null.
    T find(T)()
    {
        Object service;
        synchronized (lock)
            if (auto found = typeid(T) in entries)
                service = *found;
        return cast(T) service;
    }

private:
    Object[TypeInfo] entries;
    Mutex lock;

    this() // only the App makes one
    {
        lock = new Mutex;
    }
}

/// Fills `target`'s @autowired fields, those still null, from the App's services, and returns it.
T autowire(T)(T target) if (is(T == class))
{
    static foreach (B; AliasSeq!(T, BaseClassesTuple!T))
    {
        static if (!is(B == Object))
        {
            static foreach (i; 0 .. B.tupleof.length)
            {{
                static if (hasUDA!(B.tupleof[i], Autowired))
                {
                    alias F = typeof(B.tupleof[i]);
                    enum name = B.stringof ~ "." ~ __traits(identifier, B.tupleof[i]);
                    static assert(is(F == class) || is(F == interface),
                                  name ~ " is @autowired, so it has to be a class or interface, not " ~ F.stringof);
                    enum required = isRequired!(getUDAs!(B.tupleof[i], Autowired));
                    auto base = cast(B) target; // the field's own class, for a field of a base class
                    if (base.tupleof[i] is null)
                    {
                        auto services = currentServices;
                        auto service = services is null ? null : services.find!F();
                        if (service is null && required)
                            throw new AutowireException(name ~ " is @autowired, but nothing is registered as "
                                ~ fullyQualifiedName!F ~ (services is null
                                    ? "; make the App and give it one with registerService() before loading the view"
                                    : "; give the App one with registerService() before loading the view"));
                        base.tupleof[i] = service;
                    }
                }
            }}
        }
    }
    return target;
}

/// The services of the App made last. Set by App's constructor.
package(mayfair) __gshared Services currentServices;

/// A new set of services, for an App.
package(mayfair) Services newServices()
{
    return new Services;
}

private:

/// Whether a field marked with `udas` has to be filled: @autowired and @Autowired do, @Autowired(required: false) doesn't.
template isRequired(udas...)
{
    static if (is(typeof(udas[0]) == Autowired))
        enum isRequired = udas[0].required;
    else
        enum isRequired = true; // @Autowired, the type rather than a value of it
}

version (unittest)
{
    interface TestStorage
    {
        string load();
    }

    class TestDisk : TestStorage
    {
        string load() { return "from disk"; }
    }

    class TestSettings
    {
        string theme = "dark";
    }

    class TestLog
    {
    }

    class TestBase
    {
        @autowired private TestSettings baseSettings;  // a base class's, and private
        TestSettings settings() { return baseSettings; }
    }

    class TestPage : TestBase
    {
        @autowired TestStorage storage;
        @Autowired TestSettings settings2;               // the type, not a value of it
        @Autowired(required: false) TestLog log;
        TestSettings unmarked;
    }

    class TestNeedsLog
    {
        @autowired TestLog log;
    }

    class TestOptional
    {
        @Autowired(required: false) TestLog log;
    }

    class TestNotAClass
    {
        @autowired int count;
    }
}

unittest
{
    // As an App would: it makes the services and makes them current (see App.registerService)
    auto saved = currentServices;
    scope (exit)
        currentServices = saved;
    auto services = currentServices = newServices();

    auto settings = new TestSettings;
    services.add(settings);
    services.add!TestStorage(new TestDisk);

    auto page = autowire(new TestPage);
    assert(page.storage.load() == "from disk");
    assert(page.settings is settings && page.settings2 is settings);
    assert(page.log is null);        // not required, and nothing registered
    assert(page.unmarked is null);   // not @autowired

    // A field already set is left alone: how a test hands a view a stand-in
    auto standIn = new TestSettings;
    auto other = new TestPage;
    other.settings2 = standIn;
    autowire(other);
    assert(other.settings2 is standIn && other.settings is settings);

    // Nothing registered for a required field names the field and the type
    try
    {
        autowire(new TestNeedsLog);
        assert(false);
    }
    catch (AutowireException e)
        assert(e.msg == "TestNeedsLog.log is @autowired, but nothing is registered as mayfair.autowire.TestLog; "
                        ~ "give the App one with registerService() before loading the view", e.msg);

    // Looking one up directly, and replacing it
    assert(services.get!TestSettings() is settings && services.has!TestStorage && !services.has!TestLog);
    auto newer = new TestSettings;
    services.add(newer);
    assert(services.get!TestSettings() is newer);
    services.remove!TestLog();       // nothing to take away is fine
    try
    {
        services.get!TestLog();
        assert(false);
    }
    catch (AutowireException e)
    {
    }

    // Registered by the type asked for: a TestDisk isn't a TestStorage field's service unless registered as one
    services.remove!TestStorage();
    services.add(new TestDisk);
    assert(!services.has!TestStorage);

    static assert(!__traits(compiles, autowire(new TestNotAClass)));   // an int can't be registered
    static assert(!__traits(compiles, services.add(5)));

    // With no App yet, the message says to make one
    currentServices = null;
    try
    {
        autowire(new TestNeedsLog);
        assert(false);
    }
    catch (AutowireException e)
        assert(e.msg == "TestNeedsLog.log is @autowired, but nothing is registered as mayfair.autowire.TestLog; "
                        ~ "make the App and give it one with registerService() before loading the view", e.msg);
    assert(autowire(new TestOptional).log is null); // fields that aren't required need no App
}

unittest
{
    // A background thread sees the services the main thread registered
    import core.thread : Thread;

    auto saved = currentServices;
    scope (exit)
        currentServices = saved;
    auto services = currentServices = newServices();
    auto settings = new TestSettings;
    services.add(settings);
    TestSettings seen;
    auto thread = new Thread({ seen = currentServices.get!TestSettings(); });
    thread.start();
    thread.join();
    assert(seen is settings);
}
