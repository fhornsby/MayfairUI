module mayfair.media.gstreamer.gst;

/*
    The part of GStreamer's C API this backend uses, found at run time in the system's GStreamer
    -- dlopen, or LoadLibrary -- rather than linked: so building an app needs no GStreamer, and an
    app run where there's none says so, as an error from its player, rather than not starting.

    Hand-written, as GStreamer's headers bring GLib's with them, which ImportC can't read whole.
    Handles are opaque (`void*`); the few structs read here, and the constants, are GStreamer 1.x's
    stable ABI, checked against the headers by tools/check-abi.sh. The functions are what every
    GStreamer from 1.14 on has.
*/

alias gboolean = int;
alias GstClockTime = ulong;

enum : int
{
    GST_STATE_NULL = 1,
    GST_STATE_READY = 2,
    GST_STATE_PAUSED = 3,
    GST_STATE_PLAYING = 4,
}

enum : int
{
    GST_STATE_CHANGE_FAILURE = 0,
    GST_STATE_CHANGE_SUCCESS = 1,
    GST_STATE_CHANGE_ASYNC = 2,
    GST_STATE_CHANGE_NO_PREROLL = 3,
}

enum GST_FORMAT_TIME = 3;
enum GST_SEEK_FLAG_FLUSH = 1, GST_SEEK_FLAG_ACCURATE = 2, GST_SEEK_FLAG_KEY_UNIT = 4;
enum GST_MAP_READ = 1;
enum GST_FLOW_OK = 0;
enum GstClockTime GST_CLOCK_TIME_NONE = ulong.max;

enum : uint
{
    GST_MESSAGE_EOS = 1 << 0,
    GST_MESSAGE_ERROR = 1 << 1,
    GST_MESSAGE_WARNING = 1 << 2,
    GST_MESSAGE_TAG = 1 << 4,
    GST_MESSAGE_BUFFERING = 1 << 5,
    GST_MESSAGE_STATE_CHANGED = 1 << 6,
    GST_MESSAGE_CLOCK_LOST = 1 << 10,
    GST_MESSAGE_APPLICATION = 1 << 14,
    GST_MESSAGE_DURATION_CHANGED = 1 << 18,
    GST_MESSAGE_LATENCY = 1 << 19,
    GST_MESSAGE_ASYNC_DONE = 1 << 21,
}

// Error codes, in their domains
enum GST_RESOURCE_ERROR_NOT_FOUND = 3, GST_RESOURCE_ERROR_OPEN_READ = 5, GST_RESOURCE_ERROR_READ = 9,
     GST_RESOURCE_ERROR_NOT_AUTHORIZED = 15;
enum GST_STREAM_ERROR_TYPE_NOT_FOUND = 4, GST_STREAM_ERROR_WRONG_TYPE = 5, GST_STREAM_ERROR_CODEC_NOT_FOUND = 6,
     GST_STREAM_ERROR_DECODE = 7, GST_STREAM_ERROR_DEMUX = 9, GST_STREAM_ERROR_FORMAT = 11;
enum GST_CORE_ERROR_MISSING_PLUGIN = 12;

/*
    A GstMessage's type and source, read from the struct as the GST_MESSAGE_TYPE and
    GST_MESSAGE_SRC macros do: after its GstMiniObject (64 bytes on a 64-bit machine), its type,
    a 64-bit timestamp, then the source.
*/
static assert(size_t.sizeof == 8, "GstMessage's layout below is a 64-bit machine's");
enum messageTypeOffset = 64, messageSourceOffset = 80;

uint messageType(void* message) nothrow @nogc
{
    return *cast(uint*) (cast(ubyte*) message + messageTypeOffset);
}

void* messageSource(void* message) nothrow @nogc
{
    return *cast(void**) (cast(ubyte*) message + messageSourceOffset);
}

struct GstMapInfo
{
    void* memory;
    int flags;
    ubyte* data;
    size_t size;
    size_t maxsize;
    void*[4] userData;
    void*[4] reserved;
}
static assert(GstMapInfo.sizeof == 104 && GstMapInfo.data.offsetof == 16);

/// GstAppSinkCallbacks: as big as 1.24's, which older ones read the start of.
struct GstAppSinkCallbacks
{
extern (C) nothrow @nogc:
    void function(void* appsink, void* userData) eos;
    int function(void* appsink, void* userData) newPreroll;
    int function(void* appsink, void* userData) newSample;
    void*[4] rest;
}
static assert(GstAppSinkCallbacks.sizeof == 56);

struct GError
{
    uint domain;
    int code;
    char* message;
}

/// libgstreamer-1.0's functions, as they're used here.
struct Core
{
extern (C) nothrow @nogc:
    gboolean function(int*, char***, GError**) init_check;
    void* function(const(char)*, const(char)*) element_factory_make;
    void* function(const(char)*, gboolean, GError**) parse_bin_from_description;
    int function(void*, int) element_set_state;
    void* function(void*) element_get_bus;
    gboolean function(void*, int, long*) element_query_position;
    gboolean function(void*, int, long*) element_query_duration;
    gboolean function(void*, int, int, long) element_seek_simple;
    void* function(void*, GstClockTime) bus_timed_pop;
    gboolean function(void*, void*) bus_post;
    void function(void*, gboolean) bus_set_flushing;
    void* function(void*, void*) message_new_application;
    void function(void*, GError**, char**) message_parse_error;
    void function(void*, int*, int*, int*) message_parse_state_changed;
    void function(void*, int*) message_parse_buffering;
    void function(void*, void**) message_parse_tag;
    void* function(const(char)*) structure_new_empty;
    gboolean function(const(void)*, const(char)*, int*) structure_get_int;
    gboolean function(const(void)*, const(char)*, int*, int*) structure_get_fraction;
    gboolean function(const(void)*, const(char)*, char**) tag_list_get_string;
    void function(void*) mini_object_unref;
    void function(void*) object_unref;
    void* function(void*) sample_get_buffer;
    void* function(void*) sample_get_caps;
    gboolean function(void*, GstMapInfo*, int) buffer_map;
    void function(void*, GstMapInfo*) buffer_unmap;
    void* function(const(void)*, uint) caps_get_structure;
    void* function(void*, const(char)*) bin_get_by_name;
    void* function(void*) pad_get_current_caps;
    uint function() resource_error_quark;
    uint function() stream_error_quark;
    uint function() core_error_quark;
}

/// libgstapp-1.0's.
struct App
{
extern (C) nothrow @nogc:
    void function(void*, GstAppSinkCallbacks*, void*, void function(void*)) sink_set_callbacks;
    void* function(void*) sink_pull_sample;
    void* function(void*) sink_pull_preroll;
}

/// libgobject-2.0's.
struct GObject
{
extern (C) nothrow @nogc:
    void function(void*, const(char)*, ...) object_set;
    void function(void*, const(char)*, ...) object_get;
    void function(void*, const(char)*, ...) signal_emit_by_name;
}

/// libglib-2.0's.
struct GLib
{
extern (C) nothrow @nogc:
    void function(void*) free;
    void function(GError*) error_free;
}

/// GStreamer, opened: `gst`, `app`, `gobject` and `glib` hold its functions, once load() has said so.
struct Gst
{
    Core gst;
    App app;
    GObject gobject;
    GLib glib;
    bool loaded;
    string failure; /// Why it didn't load, if it didn't

    /*
        Opens the system's GStreamer, and finds what's used of it. False, with `failure` saying
        why, if it isn't there. Called on a backend thread: opening the libraries is quick, but
        GStreamer's own start-up (see initialise) can take seconds, the first time, as it looks at
        its plugins.
    */
    bool load()
    {
        if (loaded)
            return true;
        version (Windows)
        {
            enum names = ["gstreamer-1.0-0.dll", "gstapp-1.0-0.dll", "gobject-2.0-0.dll", "glib-2.0-0.dll"];
        }
        else version (OSX)
        {
            // Homebrew's and MacPorts's on the library path, or the official framework's
            enum names = ["libgstreamer-1.0.0.dylib", "libgstapp-1.0.0.dylib", "libgobject-2.0.0.dylib", "libglib-2.0.0.dylib"];
        }
        else
        {
            enum names = ["libgstreamer-1.0.so.0", "libgstapp-1.0.so.0", "libgobject-2.0.so.0", "libglib-2.0.so.0"];
        }
        void*[4] libs;
        foreach (i, name; names)
        {
            libs[i] = open(name);
            if (!libs[i])
            {
                failure = "GStreamer isn't installed: " ~ name ~ " wasn't found";
                return false;
            }
        }
        if (!resolve(libs[0], "gst_", gst) || !resolve(libs[1], "gst_app_", app)
            || !resolve(libs[2], "g_", gobject) || !resolve(libs[3], "g_", glib))
            return false;
        loaded = true;
        return true;
    }

private:
    static void* open(string name)
    {
        import std.string : toStringz;
        version (Windows)
        {
            import core.sys.windows.winbase : LoadLibraryA;
            return cast(void*) LoadLibraryA(name.toStringz);
        }
        else
        {
            import core.sys.posix.dlfcn : dlopen, RTLD_LOCAL, RTLD_NOW;
            auto lib = dlopen(name.toStringz, RTLD_NOW | RTLD_LOCAL);
            version (OSX)
                if (!lib)
                    lib = dlopen(("/Library/Frameworks/GStreamer.framework/Versions/1.0/lib/" ~ name).toStringz,
                                 RTLD_NOW | RTLD_LOCAL);
            return lib;
        }
    }

    static void* symbol(void* lib, string name)
    {
        import std.string : toStringz;
        version (Windows)
        {
            import core.sys.windows.winbase : GetProcAddress;
            import core.sys.windows.windef : HMODULE;
            return cast(void*) GetProcAddress(cast(HMODULE) lib, name.toStringz);
        }
        else
        {
            import core.sys.posix.dlfcn : dlsym;
            return dlsym(lib, name.toStringz);
        }
    }

    bool resolve(T)(void* lib, string prefix, ref T into)
    {
        static foreach (member; __traits(allMembers, T))
        {{
            auto f = symbol(lib, prefix ~ member);
            if (!f)
            {
                failure = "this GStreamer is too old: it has no " ~ prefix ~ member;
                return false;
            }
            mixin("into." ~ member ~ " = cast(typeof(into." ~ member ~ ")) f;");
        }}
        return true;
    }
}

/// The process's GStreamer: opened and started once, by the first session's thread, with
/// mayfair.media.gstreamer.session.startGStreamer, which the rest wait for.
__gshared Gst gstreamer;
