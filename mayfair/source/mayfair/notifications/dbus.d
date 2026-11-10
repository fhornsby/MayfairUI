module mayfair.notifications.dbus;

/*
    Just enough of libdbus for notifications: a connection to the session bus, method calls built
    argument by argument, and the signals that come back. libdbus is opened when it's first needed,
    as SDL opens it, and libwayland-client is opened for the Wayland backend: so it's no
    dependency to build Mayfair, and a machine without it only has no notifications.

    Not thread-safe: one thread owns the connection (see mayfair.notifications.linux).
*/

version (Posix):

import core.stdc.string : strlen;

// libdbus's opaque types, and those of its structs that live on the caller's stack. The structs'
// layouts aren't the caller's business, only their size: these are libdbus's on any platform,
// with room to spare.
struct DBusConnection;
struct DBusMessage;
align(8) struct DBusMessageIter { ubyte[128] opaque; }
align(8) struct DBusError
{
    const(char)* name;
    const(char)* message;
    ubyte[48] rest;
}

enum DBusBusType : int { session = 0 }

// Argument types, as their signature characters
enum : int
{
    typeInvalid = 0,
    typeByte = 'y',
    typeBoolean = 'b',
    typeInt32 = 'i',
    typeUint32 = 'u',
    typeString = 's',
    typeArray = 'a',
    typeVariant = 'v',
    typeStruct = 'r',
    typeDictEntry = 'e',
}

/// libdbus's functions, as they're used here.
struct Functions
{
extern (C) nothrow @nogc:
    void function(DBusError*) error_init;
    void function(DBusError*) error_free;
    uint function(const(DBusError)*) error_is_set;
    DBusConnection* function(DBusBusType, DBusError*) bus_get_private;
    void function(DBusConnection*, uint) connection_set_exit_on_disconnect;
    void function(DBusConnection*) connection_close;
    void function(DBusConnection*) connection_unref;
    void function(DBusConnection*, const(char)*, DBusError*) bus_add_match;
    uint function(DBusConnection*, int*) connection_get_unix_fd;
    uint function(DBusConnection*, int) connection_read_write;
    DBusMessage* function(DBusConnection*) connection_pop_message;
    uint function(DBusConnection*, DBusMessage*, uint*) connection_send;
    void function(DBusConnection*) connection_flush;
    DBusMessage* function(DBusConnection*, DBusMessage*, int, DBusError*) connection_send_with_reply_and_block;
    DBusMessage* function(const(char)*, const(char)*, const(char)*, const(char)*) message_new_method_call;
    void function(DBusMessage*) message_unref;
    uint function(DBusMessage*, const(char)*, const(char)*) message_is_signal;
    uint function(DBusMessage*, DBusError*, int, ...) message_get_args;
    void function(DBusMessage*, DBusMessageIter*) message_iter_init_append;
    uint function(DBusMessageIter*, int, const(void)*) message_iter_append_basic;
    uint function(DBusMessageIter*, int, const(void)*, int) message_iter_append_fixed_array;
    uint function(DBusMessageIter*, int, const(char)*, DBusMessageIter*) message_iter_open_container;
    uint function(DBusMessageIter*, DBusMessageIter*) message_iter_close_container;
}

/// libdbus, opened. `fn` is null until open() has succeeded.
struct LibDBus
{
    Functions fn;
    bool loaded;

    /// Opens libdbus and finds its functions. False if it isn't there.
    bool open() nothrow @nogc
    {
        import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;
        if (loaded)
            return true;
        version (OSX)
            enum name = "libdbus-1.3.dylib";
        else
            enum name = "libdbus-1.so.3";
        auto lib = dlopen(name, RTLD_NOW | RTLD_LOCAL);
        if (!lib)
            return false;
        static foreach (member; __traits(allMembers, Functions))
        {{
            auto f = dlsym(lib, "dbus_" ~ member);
            if (!f)
                return false;
            mixin("fn." ~ member ~ " = cast(typeof(fn." ~ member ~ ")) f;");
        }}
        loaded = true;
        return true;
    }
}

/*
    A method call's arguments, appended in order: `w.str("x").u32(1)`, and containers opened with
    a function that appends what's in them. Strings are made valid UTF-8 first, as libdbus would
    otherwise refuse them.
*/
struct Writer
{
    LibDBus* d;
    DBusMessageIter* it;

    Writer str(string s)
    {
        import std.string : toStringz;
        const z = valid(s).toStringz;
        d.fn.message_iter_append_basic(it, typeString, &z);
        return this;
    }

    Writer u32(uint v)
    {
        d.fn.message_iter_append_basic(it, typeUint32, &v);
        return this;
    }

    Writer i32(int v)
    {
        d.fn.message_iter_append_basic(it, typeInt32, &v);
        return this;
    }

    Writer byte_(ubyte v)
    {
        d.fn.message_iter_append_basic(it, typeByte, &v);
        return this;
    }

    Writer bytes(const(ubyte)[] data)
    {
        return array("y", (Writer w) {
            const p = data.ptr;
            w.d.fn.message_iter_append_fixed_array(w.it, typeByte, &p, cast(int) data.length);
        });
    }

    /// An array of `element` (a signature), its elements appended by `contents`.
    Writer array(string element, scope void delegate(Writer) contents)
    {
        return container(typeArray, element, contents);
    }

    Writer strings(const string[] list)
    {
        return array("s", (Writer w) {
            foreach (s; list)
                w.str(s);
        });
    }

    /// A variant holding a `signature`, appended by `contents`.
    Writer variant(string signature, scope void delegate(Writer) contents)
    {
        return container(typeVariant, signature, contents);
    }

    Writer struct_(scope void delegate(Writer) contents)
    {
        return container(typeStruct, null, contents);
    }

    /// One entry of an a{sv}: `key`, and a variant of `signature` appended by `contents`.
    Writer entry(string key, string signature, scope void delegate(Writer) contents)
    {
        return container(typeDictEntry, null, (Writer e) {
            e.str(key);
            e.variant(signature, contents);
        });
    }

private:
    Writer container(int type, string signature, scope void delegate(Writer) contents)
    {
        import std.string : toStringz;
        DBusMessageIter sub;
        d.fn.message_iter_open_container(it, type, signature.length ? signature.toStringz : null, &sub);
        contents(Writer(d, &sub));
        d.fn.message_iter_close_container(it, &sub);
        return this;
    }
}

/// `s`, with anything that isn't UTF-8 made U+FFFD.
string valid(string s) pure @safe
{
    import std.utf : decode, validate, UTFException;
    try
    {
        validate(s);
        return s;
    }
    catch (UTFException)
    {
        // A byte at a time where it isn't: decode() can skip what follows a bad byte
        string r;
        for (size_t i = 0; i < s.length;)
        {
            const start = i;
            try
            {
                decode(s, i);
                r ~= s[start .. i];
            }
            catch (UTFException)
            {
                r ~= "\uFFFD";
                i = start + 1;
            }
        }
        return r;
    }
}

/// A C string from libdbus as a D one of its own.
string copied(const(char)* s) nothrow
{
    return s ? s[0 .. strlen(s)].idup : null;
}

unittest
{
    assert(valid("café") == "café");
    assert(valid("a\xFFb") == "a�b", "invalid UTF-8 replaced, not refused");
}
