module mayfair.windowing.wayland.toplevel;

import core.stdc.string : strcmp;
import mayfair.windowing.backend : ScrollSource;

/*
    A pointer of Mayfair's own on SDL's Wayland connection, on an event queue of its own, for what
    the compositor says about the pointer that SDL keeps to itself or drops. It hears everything
    SDL's pointer does. libwayland-client is opened at run time, as SDL opens it. Two things:

    Moving a window drawing its own title bar, the way GTK does: the press goes to the app, which
    asks the compositor to move the window only once the pointer's gone a little way with the
    button down. Then a double click can be told from the start of a drag. SDL's hit test can't do
    that: it hands the compositor the press itself, straight away, and the app never hears of it.
    xdg_toplevel.move wants the serial of the press it's for, which SDL keeps to itself.

    What scrolling is from, and when it stops: wl_pointer's axis_source says, for each scroll,
    whether it's a wheel, fingers on a touchpad, or something continuous, and axis_stop says when
    the fingers lift. SDL ignores both, and gives a wheel's notch and a touchpad's movement as
    amounts that have to be told apart by their sizes, and no lift at all -- so a scroll pane
    would have to guess when to start gliding. GTK and Qt go by these; so does Mayfair, where the
    compositor offers version 5 of the seat, as every current one does.
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

    /// The version the pointer's bound at: 5 or more, and the compositor says what scrolls are from.
    uint pointerVersion() nothrow @nogc { return pointer ? fn.proxy_get_version(pointer) : 0; }

    /// What the last scroll was from, as the compositor said: unknown if it can't say.
    ScrollSource scrollSource() const nothrow @nogc { return source; }

    /// Whether fingers scrolling have lifted since this was last asked.
    bool takeFingersLifted() nothrow @nogc
    {
        const was = lifted;
        lifted = false;
        return was;
    }

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
    ScrollSource source; // what the last scroll was from
    bool lifted;         // fingers scrolling lifted, not yet asked about

    // Version 5 of wl_seat and wl_pointer, for axis_source and axis_stop; 1 where that's all there is
    enum maxVersion = 5;
    struct RegistryListener
    {
        extern (C) void function(void*, void*, uint, const(char)*, uint) nothrow @nogc global;
        extern (C) void function(void*, void*, uint) nothrow @nogc globalRemove;
    }
    struct SeatListener
    {
        extern (C) void function(void*, void*, uint) nothrow @nogc capabilities;
        extern (C) void function(void*, void*, const(char)*) nothrow @nogc name;  // version 2
    }
    struct PointerListener
    {
        extern (C) nothrow @nogc:
        void function(void*, void*, uint, void*, int, int) enter;
        void function(void*, void*, uint, void*) leave;
        void function(void*, void*, uint, int, int) motion;
        void function(void*, void*, uint, uint, uint, uint) button;
        void function(void*, void*, uint, uint, int) axis;
        // Version 5
        void function(void*, void*) frame;
        void function(void*, void*, uint) axisSource;
        void function(void*, void*, uint, uint) axisStop;
        void function(void*, void*, uint, int) axisDiscrete;
    }
    static immutable registryListener = RegistryListener(&global, &globalRemove);
    static immutable seatListener = SeatListener(&capabilities, &seatName);
    static immutable pointerListener = PointerListener(&enter, &leave, &motion, &button, &axis,
                                                       &frame, &axisSource, &axisStop, &axisDiscrete);

    static extern (C) void global(void* data, void* registry, uint name, const(char)* iface, uint version_) nothrow @nogc
    {
        auto self = cast(WindowMover*) data;
        if (self.seat || strcmp(iface, "wl_seat") != 0)
            return; // the first seat: a desktop has one
        enum bind = 0;
        const v = version_ < maxVersion ? version_ : maxVersion;
        self.seat = self.fn.proxy_marshal_flags(registry, bind, self.seatInterface, v, 0, name, "wl_seat".ptr, v, null);
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
        self.pointer = self.fn.proxy_marshal_flags(seat, getPointer, self.pointerInterface, self.fn.proxy_get_version(seat), 0, null);
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
    static extern (C) void seatName(void*, void*, const(char)*) nothrow @nogc {}
    static extern (C) void frame(void*, void*) nothrow @nogc {}
    static extern (C) void axisDiscrete(void*, void*, uint, int) nothrow @nogc {}

    static extern (C) void axisSource(void* data, void*, uint s) nothrow @nogc
    {
        // wl_pointer.axis_source: wheel 0, finger 1, continuous 2, wheel_tilt 3
        auto self = cast(WindowMover*) data;
        self.source = s == 1 ? ScrollSource.finger : s == 2 ? ScrollSource.continuous : ScrollSource.wheel;
        self.lifted = false; // moving again
    }

    static extern (C) void axisStop(void* data, void*, uint, uint) nothrow @nogc
    {
        // Sent for each axis that was scrolling; one lift is all that's wanted
        auto self = cast(WindowMover*) data;
        if (self.source == ScrollSource.finger)
            self.lifted = true;
    }
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

    The events arrive as SDL reads the connection, on the main thread. Every window's xdg_toplevel
    shares the one table, so each is told apart by the proxy the event comes with, in a table of
    the module's: SDL's listeners are all the same table too, but that's SDL's business.
*/
struct TileWatcher
{
    /// Watches `toplevel`, the window's xdg_toplevel. False if it can't, when `tiled` stays false.
    bool open(void* toplevel) nothrow @nogc
    {
        version (Posix)
        {
            import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;
            if (!toplevel || mine)
                return mine && mine.toplevel is toplevel;
            // An entry for a toplevel gone without close() -- replaced by SDL, and not yet
            // noticed by its window -- whose memory this one now has
            foreach (ref w; watches)
                if (w.toplevel is toplevel)
                    w.clear();
            Watch* free;
            foreach (ref w; watches)
                if (!w.toplevel)
                {
                    free = &w;
                    break;
                }
            if (!free)
                return false; // more windows than there's room for: the rest keep their shadows tiled
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
            free.sdlListener = cast(const(ToplevelListener)*) listener;
            free.tiled = false;
            free.toplevel = toplevel;
            object[1] = &ownListener;
            watch = free;
            generation = free.generation;
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
            if (auto w = mine)
                (cast(const(void)**) w.toplevel)[1] = w.sdlListener;
            if (lib)
                dlclose(lib);
        }
        forget();
        lib = null;
    }

    /*
        Stops watching a toplevel that's already gone -- that SDL replaced with another -- without
        touching it, as close() would to give it its listener back.
    */
    void forget() nothrow @nogc
    {
        if (auto w = mine)
            w.clear();
        watch = null;
    }

    /// Whether the window's tiled against any edge, as the compositor last said.
    bool tiled() const nothrow @nogc { return mine && mine.tiled; }

    /// Whether it's watching a window.
    bool watching() const nothrow @nogc { return mine !is null; }

    /// The xdg_toplevel it's watching, if it is.
    const(void)* watched() const nothrow @nogc { return mine ? mine.toplevel : null; }

private:
    void* lib;
    Watch* watch;    // its entry in watches
    uint generation; // the entry's, when it was this watcher's: another's once it's been cleared

    // Its entry, if it's still its own
    inout(Watch)* mine() inout nothrow @nogc
    {
        return watch && watch.generation == generation && watch.toplevel ? watch : null;
    }
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

// A watched xdg_toplevel, the listener this goes in front of, and what it last said
struct Watch
{
    void* toplevel;
    const(ToplevelListener)* sdlListener;
    bool tiled;
    uint generation; // counts its clearings, so a watcher can tell it's no longer its own

    void clear() nothrow @nogc
    {
        toplevel = null;
        sdlListener = null;
        tiled = false;
        generation++;
    }
}

__gshared Watch[32] watches;

Watch* watchOf(void* toplevel) nothrow @nogc
{
    foreach (ref w; watches)
        if (w.toplevel is toplevel)
            return &w;
    assert(false, "an xdg_toplevel with this listener that isn't watched");
}

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
    auto w = watchOf(toplevel);
    w.tiled = tiled;
    w.sdlListener.configure(data, toplevel, width, height, states);
}

extern (C) void forwardClose(void* data, void* toplevel) nothrow @nogc
{
    watchOf(toplevel).sdlListener.close(data, toplevel);
}

extern (C) void forwardConfigureBounds(void* data, void* toplevel, int width, int height) nothrow @nogc
{
    watchOf(toplevel).sdlListener.configureBounds(data, toplevel, width, height);
}

extern (C) void forwardWmCapabilities(void* data, void* toplevel, WlArray* capabilities) nothrow @nogc
{
    watchOf(toplevel).sdlListener.wmCapabilities(data, toplevel, capabilities);
}

unittest {
    // What the compositor says about scrolling, as it says it: a wheel, then fingers, which lift
    WindowMover m;
    assert(m.scrollSource == ScrollSource.unknown && !m.takeFingersLifted);
    WindowMover.axisSource(&m, null, 0);
    assert(m.scrollSource == ScrollSource.wheel);
    WindowMover.axisStop(&m, null, 0, 0);
    assert(!m.takeFingersLifted, "a wheel doesn't lift");
    WindowMover.axisSource(&m, null, 1);
    assert(m.scrollSource == ScrollSource.finger);
    WindowMover.axisStop(&m, null, 0, 0);
    WindowMover.axisStop(&m, null, 0, 1); // both axes stop: one lift
    assert(m.takeFingersLifted && !m.takeFingersLifted);
    WindowMover.axisSource(&m, null, 2);
    assert(m.scrollSource == ScrollSource.continuous);
    WindowMover.axisSource(&m, null, 3);
    assert(m.scrollSource == ScrollSource.wheel, "a tilted wheel's a wheel");
}
