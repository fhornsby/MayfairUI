module mayfair.autowire;

import core.sync.mutex : Mutex;
import std.meta : AliasSeq;
import std.traits : BaseClassesTuple, fullyQualifiedName, getUDAs, hasUDA;

/*
    Services a view asks for by type, without a constructor to pass them through: Spring's
    @Autowired, worked out as the program's compiled rather than by reflection when it runs.

        void main()
        {
            provide(new Library("books.db"));   // anything the app's views share: a database, a
            provide(new Settings);              // web API's client, the user's settings
            auto app = new App("Books");
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
    it runs, by the type the field is declared with: provide!Storage(new DiskStorage) for a field
    that's a Storage. A field already set is left alone, so a test can hand a view a stand-in
    before loading it. Nothing provided for a field is an AutowireException naming the class,
    the field and its type, unless it's marked @Autowired(required: false), which leaves it null.

    Services are provided once, before the app runs, and only read after, so a background thread
    can use them through the view, or with provided!T(). (They're kept in one place for the whole
    program, not each thread's own: a plain variable at module level is the thread's own in D,
    and null on any other thread, the trap this saves an app from.)
*/

/// Marks a field to fill with the service provided for its type.
enum autowired = Autowired.init;

/// ditto. `@Autowired(required: false)` leaves the field null when nothing's provided for it.
struct Autowired
{
    bool required = true;
}

/// Thrown when an @autowired field's type has nothing provided for it.
class AutowireException : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(message, file, line);
    }
}

/// Makes `service` what fills @autowired fields of type T, replacing any T provided before.
void provide(T)(T service) if (is(T == class) || is(T == interface))
{
    if (service is null)
        throw new AutowireException("provide!" ~ T.stringof ~ " was given null; to take a service away, use unprovide");
    synchronized (lock)
        services[typeid(T)] = cast(Object) service;
}

/// Takes away the service provided for T, if there is one.
void unprovide(T)() if (is(T == class) || is(T == interface))
{
    synchronized (lock)
        services.remove(typeid(T));
}

/// Whether something's provided for T.
bool isProvided(T)() if (is(T == class) || is(T == interface))
{
    return find!T() !is null;
}

/// The service provided for T. Throws an AutowireException if there isn't one.
T provided(T)() if (is(T == class) || is(T == interface))
{
    auto service = find!T();
    if (service is null)
        throw new AutowireException("nothing provides " ~ fullyQualifiedName!T ~ "; call provide() with one first");
    return service;
}

/// Fills `target`'s @autowired fields, those still null, and returns it.
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
                        auto service = find!F();
                        if (service is null && required)
                            throw new AutowireException(name ~ " is @autowired, but nothing provides "
                                                        ~ fullyQualifiedName!F ~ "; call provide() with one before it's loaded");
                        base.tupleof[i] = service;
                    }
                }
            }}
        }
    }
    return target;
}

private:

__gshared Object[TypeInfo] services;
__gshared Mutex lock;

shared static this()
{
    lock = new Mutex;
}

T find(T)()
{
    Object service;
    synchronized (lock)
        if (auto found = typeid(T) in services)
            service = *found;
    return cast(T) service;
}

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

    class TestNotAClass
    {
        @autowired int count;
    }
}

unittest
{
    auto settings = new TestSettings;
    provide(settings);
    provide!TestStorage(new TestDisk);
    scope (exit)
    {
        unprovide!TestSettings();
        unprovide!TestStorage();
    }

    auto page = autowire(new TestPage);
    assert(page.storage.load() == "from disk");
    assert(page.settings is settings && page.settings2 is settings);
    assert(page.log is null);        // not required, and nothing provides it
    assert(page.unmarked is null);   // not @autowired

    // A field already set is left alone: how a test hands a view a stand-in
    auto standIn = new TestSettings;
    auto other = new TestPage;
    other.settings2 = standIn;
    autowire(other);
    assert(other.settings2 is standIn && other.settings is settings);

    // Nothing provided for a required field names the field and the type
    try
    {
        autowire(new TestNeedsLog);
        assert(false);
    }
    catch (AutowireException e)
        assert(e.msg == "TestNeedsLog.log is @autowired, but nothing provides mayfair.autowire.TestLog; "
                        ~ "call provide() with one before it's loaded", e.msg);

    // Looking one up directly, and replacing it
    assert(provided!TestSettings() is settings && isProvided!TestStorage && !isProvided!TestLog);
    auto newer = new TestSettings;
    provide(newer);
    assert(provided!TestSettings() is newer);
    unprovide!TestLog();             // nothing to take away is fine
    try
    {
        provided!TestLog();
        assert(false);
    }
    catch (AutowireException e)
    {
    }

    // Registered by the type asked for: a TestDisk isn't a TestStorage field's service unless provided as one
    unprovide!TestStorage();
    provide(new TestDisk);
    assert(!isProvided!TestStorage);
    unprovide!TestDisk();

    static assert(!__traits(compiles, autowire(new TestNotAClass)));   // an int can't be provided
    static assert(!__traits(compiles, provide(5)));
}

unittest
{
    // A background thread sees what the main thread provided
    import core.thread : Thread;

    auto settings = new TestSettings;
    provide(settings);
    scope (exit)
        unprovide!TestSettings();
    TestSettings seen;
    auto thread = new Thread({ seen = provided!TestSettings(); });
    thread.start();
    thread.join();
    assert(seen is settings);
}
