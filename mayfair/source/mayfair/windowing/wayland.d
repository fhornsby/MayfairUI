module mayfair.windowing.wayland;

import core.stdc.string : strcmp;

/*
    Moving a window drawing its own title bar, on Wayland, the way GTK does: the press goes to the
    app, which asks the compositor to move the window only once the pointer's gone a little way with
    the button down. Then a double click can be told from the start of a drag. SDL's hit test can't
    do that: it hands the compositor the press itself, straight away, and the app never hears of it.

    xdg_toplevel.move wants the serial of the press it's for, which SDL keeps to itself. So the
    WindowMover binds a pointer of its own on SDL's connection, on an event queue of its own, and
    hears every press SDL does. libwayland-client is opened at run time, as SDL opens it.
*/
struct WindowMover
{
    /// Sets up on SDL's `display`. False if it couldn't, and then SDL's hit test has to move the window.
    bool open(void* display) nothrow @nogc
    {
        version (Posix)
        {
            import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;
            if (!display)
                return false;
            lib = dlopen("libwayland-client.so.0", RTLD_NOW | RTLD_LOCAL);
            if (!lib)
                return false;
            bool found = true;
            static foreach (name; __traits(allMembers, Functions))
            {{
                auto f = dlsym(lib, "wl_" ~ name);
                found &= f !is null;
                mixin("fn." ~ name ~ " = cast(typeof(fn." ~ name ~ ")) f;");
            }}
            registryInterface = dlsym(lib, "wl_registry_interface");
            seatInterface = dlsym(lib, "wl_seat_interface");
            pointerInterface = dlsym(lib, "wl_pointer_interface");
            if (!found || !registryInterface || !seatInterface || !pointerInterface)
            {
                close();
                return false;
            }

            this.display = display;
            queue = fn.display_create_queue(display);
            // wl_display_get_registry, made through a wrapper so the registry, and all it binds,
            // is on our queue rather than SDL's
            auto wrapper = fn.proxy_create_wrapper(display);
            if (!queue || !wrapper)
            {
                if (wrapper) fn.proxy_wrapper_destroy(wrapper);
                close();
                return false;
            }
            fn.proxy_set_queue(wrapper, queue);
            enum getRegistry = 1;
            registry = fn.proxy_marshal_flags(wrapper, getRegistry, registryInterface, fn.proxy_get_version(wrapper), 0, null);
            fn.proxy_wrapper_destroy(wrapper);
            if (!registry)
            {
                close();
                return false;
            }
            fn.proxy_add_listener(registry, &registryListener, &this);
            // One round trip to hear of the seat, one for the seat to say it has a pointer
            fn.display_roundtrip_queue(display, queue);
            fn.display_roundtrip_queue(display, queue);
            if (!pointer)
            {
                close();
                return false;
            }
            return true;
        }
        else
            return false;
    }

    void close() nothrow @nogc
    {
        version (Posix)
        {
            import core.sys.posix.dlfcn : dlclose;
            if (pointer) fn.proxy_destroy(pointer);
            if (seat) fn.proxy_destroy(seat);
            if (registry) fn.proxy_destroy(registry);
            if (queue) fn.event_queue_destroy(queue);
            if (lib) dlclose(lib);
        }
        this = WindowMover.init;
    }

    bool available() const nothrow @nogc { return pointer !is null; }

    /// Hears what's arrived on our queue. Call once a turn of the loop, after SDL has read the
    /// connection, or the pointer's motion piles up there.
    void dispatch() nothrow @nogc
    {
        if (queue)
            fn.display_dispatch_queue_pending(display, queue);
    }

    /// Asks the compositor to move the window, `toplevel` its xdg_toplevel, by the pointer, while
    /// the press that's still down lasts. False if there's no press down to move it by.
    bool move(void* toplevel) nothrow @nogc
    {
        dispatch();
        if (!pointer || !toplevel || !held)
            return false;
        enum move = 5; // xdg_toplevel.move(seat, serial)
        fn.proxy_marshal_flags(toplevel, move, null, fn.proxy_get_version(toplevel), 0, seat, pressSerial);
        held = false; // the compositor has the pointer now, and keeps the release
        return true;
    }

private:
    // libwayland-client, as it names them less the "wl_"
    struct Functions
    {
        extern (C) nothrow @nogc:
        void* function(void*) display_create_queue;
        void function(void*) event_queue_destroy;
        int function(void*, void*) display_roundtrip_queue;
        int function(void*, void*) display_dispatch_queue_pending;
        void* function(void*) proxy_create_wrapper;
        void function(void*) proxy_wrapper_destroy;
        void function(void*, void*) proxy_set_queue;
        void* function(void*, uint, const(void)*, uint, uint, ...) proxy_marshal_flags;
        int function(void*, const(void)*, void*) proxy_add_listener;
        uint function(void*) proxy_get_version;
        void function(void*) proxy_destroy;
    }
    Functions fn;
    void* lib;
    const(void)* registryInterface, seatInterface, pointerInterface;
    void* display, queue, registry, seat, pointer;
    uint pressSerial; // the last press's
    bool held;        // and whether it's still down

    // Version 1 of wl_seat and wl_pointer: all that's needed, and the fewest events to listen for
    struct RegistryListener
    {
        extern (C) void function(void*, void*, uint, const(char)*, uint) nothrow @nogc global;
        extern (C) void function(void*, void*, uint) nothrow @nogc globalRemove;
    }
    struct SeatListener
    {
        extern (C) void function(void*, void*, uint) nothrow @nogc capabilities;
    }
    struct PointerListener
    {
        extern (C) nothrow @nogc:
        void function(void*, void*, uint, void*, int, int) enter;
        void function(void*, void*, uint, void*) leave;
        void function(void*, void*, uint, int, int) motion;
        void function(void*, void*, uint, uint, uint, uint) button;
        void function(void*, void*, uint, uint, int) axis;
    }
    static immutable registryListener = RegistryListener(&global, &globalRemove);
    static immutable seatListener = SeatListener(&capabilities);
    static immutable pointerListener = PointerListener(&enter, &leave, &motion, &button, &axis);

    static extern (C) void global(void* data, void* registry, uint name, const(char)* iface, uint version_) nothrow @nogc
    {
        auto self = cast(WindowMover*) data;
        if (self.seat || strcmp(iface, "wl_seat") != 0)
            return; // the first seat: a desktop has one
        enum bind = 0;
        self.seat = self.fn.proxy_marshal_flags(registry, bind, self.seatInterface, 1, 0, name, "wl_seat".ptr, 1, null);
        if (self.seat)
            self.fn.proxy_add_listener(self.seat, &seatListener, data);
    }
    static extern (C) void globalRemove(void*, void*, uint) nothrow @nogc {}

    static extern (C) void capabilities(void* data, void* seat, uint caps) nothrow @nogc
    {
        auto self = cast(WindowMover*) data;
        enum hasPointer = 1;
        if (!(caps & hasPointer) || self.pointer)
            return;
        enum getPointer = 0;
        self.pointer = self.fn.proxy_marshal_flags(seat, getPointer, self.pointerInterface, 1, 0, null);
        if (self.pointer)
            self.fn.proxy_add_listener(self.pointer, &pointerListener, data);
    }

    static extern (C) void button(void* data, void*, uint serial, uint, uint, uint state) nothrow @nogc
    {
        auto self = cast(WindowMover*) data;
        if (state == 1) // pressed
            self.pressSerial = serial;
        self.held = state == 1;
    }
    static extern (C) void leave(void* data, void*, uint, void*) nothrow @nogc
    {
        (cast(WindowMover*) data).held = false;
    }
    static extern (C) void enter(void*, void*, uint, void*, int, int) nothrow @nogc {}
    static extern (C) void motion(void*, void*, uint, int, int) nothrow @nogc {}
    static extern (C) void axis(void*, void*, uint, uint, int) nothrow @nogc {}
}

/*
    Whether the window's tiled: snapped to half the screen, a quarter, or against another window.
    Its frame wants to be flat then, as a maximised one's is -- no shadow margin, square corners --
    or the shadow fills the edge of the space it's snapped to and the window looks short of it.
    GTK does the same, from the same states.

    The compositor says so in xdg_toplevel.configure, whose states SDL reads but keeps to itself.
    A proxy has one listener, SDL's (or libdecor's), so this one goes in front of it: libwayland
    keeps a proxy's listener as the second field of the wl_object at its start, the same since
    1.0, and this puts a table of its own there whose configure notes the states and then calls
    the one it took the place of, as every other event does straight away. Only once it's checked
    that the field holds what wl_proxy_get_listener says the listener is: if libwayland were ever
    laid out differently, it leaves the proxy alone, and the window keeps its shadow when tiled.

    The events arrive as SDL reads the connection, on the main thread, and there's one window, so
    the state is the module's.
*/
struct TileWatcher
{
    /// Watches `toplevel`, the window's xdg_toplevel. False if it can't, when `tiled` stays false.
    bool open(void* toplevel) nothrow @nogc
    {
        version (Posix)
        {
            import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;
            if (!toplevel || watched)
                return watched is toplevel;
            if (!lib)
                lib = dlopen("libwayland-client.so.0", RTLD_NOW | RTLD_LOCAL);
            if (!lib)
                return false;
            auto getListener = cast(const(void)* function(void*) nothrow @nogc) dlsym(lib, "wl_proxy_get_listener");
            if (!getListener)
                return false;
            auto object = cast(const(void)**) toplevel;  // { interface, implementation, id, ... }
            const listener = getListener(toplevel);
            if (!listener || object[1] !is listener)
                return false;   // not laid out as it's always been: leave it be
            sdlListener = cast(const(ToplevelListener)*) listener;
            object[1] = &ownListener;
            watched = toplevel;
            return true;
        }
        else
            return false;
    }

    /// Gives the proxy its own listener back, before the window and the proxy go.
    void close() nothrow @nogc
    {
        version (Posix)
        {
            import core.sys.posix.dlfcn : dlclose;
            if (watched)
                (cast(const(void)**) watched)[1] = sdlListener;
            if (lib)
                dlclose(lib);
        }
        watched = null;
        sdlListener = null;
        lib = null;
        tiledNow = false;
    }

    /// Whether the window's tiled against any edge, as the compositor last said.
    bool tiled() const nothrow @nogc { return tiledNow; }

    /// Whether it's watching a window.
    bool watching() const nothrow @nogc { return watched !is null; }

private:
    void* lib;
}

private:

// xdg_toplevel's events, in the order the protocol has them: up to version 6, which adds none
struct ToplevelListener
{
    extern (C) nothrow @nogc:
    void function(void*, void*, int, int, WlArray*) configure;
    void function(void*, void*) close;
    void function(void*, void*, int, int) configureBounds;     // version 4
    void function(void*, void*, WlArray*) wmCapabilities;      // version 5
}

struct WlArray
{
    size_t size, alloc;
    void* data;
}

__gshared void* watched;                           // the xdg_toplevel listened to
__gshared const(ToplevelListener)* sdlListener;    // whose listener this goes in front of
__gshared bool tiledNow;

static immutable ownListener = ToplevelListener(&forwardConfigure, &forwardClose, &forwardConfigureBounds, &forwardWmCapabilities);

extern (C) void forwardConfigure(void* data, void* toplevel, int width, int height, WlArray* states) nothrow @nogc
{
    // xdg_toplevel.state's tiled_left, tiled_right, tiled_top and tiled_bottom (version 2)
    enum tiledLeft = 5, tiledBottom = 8;
    bool tiled;
    if (states)
        foreach (s; (cast(const(uint)*) states.data)[0 .. states.size / uint.sizeof])
            if (s >= tiledLeft && s <= tiledBottom)
                tiled = true;
    tiledNow = tiled;
    sdlListener.configure(data, toplevel, width, height, states);
}

extern (C) void forwardClose(void* data, void* toplevel) nothrow @nogc
{
    sdlListener.close(data, toplevel);
}

extern (C) void forwardConfigureBounds(void* data, void* toplevel, int width, int height) nothrow @nogc
{
    sdlListener.configureBounds(data, toplevel, width, height);
}

extern (C) void forwardWmCapabilities(void* data, void* toplevel, WlArray* capabilities) nothrow @nogc
{
    sdlListener.wmCapabilities(data, toplevel, capabilities);
}
