module mayfair.windowing.wayland.blur;

import core.stdc.string : strcmp;

/*
    Asks the compositor to blur what's behind parts of the window: those with backdrop-blur on (see
    Widget.backdropBlur). Over ext-background-effect-v1, a Wayland protocol GNOME has from Mutter 51
    and KDE from Plasma 6.7; on another compositor, or X11, there's no blur and nothing's asked.

    The region is double-buffered, as Wayland's surface state is: set before a frame's presented,
    it's the region from that frame on. Like WindowMover, it works on SDL's connection through an
    event queue of its own, with libwayland-client opened at run time; the protocol's interfaces,
    which libwayland-client doesn't have, are written out here rather than generated.
*/
struct BackgroundBlur
{
    /// Room for the region's rectangles, which Scene.backdropBlurRegion fills before setRegion.
    int[4][1024] rects;

    /// Sets up on SDL's `display`, for its `surface`. False if the compositor doesn't blur.
    bool open(void* display, void* surface) nothrow @nogc
    {
        version (Posix)
        {
            import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;
            if (!display || !surface)
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
            compositorInterface = dlsym(lib, "wl_compositor_interface");
            surfaceInterface = dlsym(lib, "wl_surface_interface");
            regionInterface = dlsym(lib, "wl_region_interface");
            if (!found || !registryInterface || !compositorInterface || !surfaceInterface || !regionInterface)
            {
                close();
                return false;
            }
            fillInterfaces();

            this.display = display;
            queue = fn.display_create_queue(display);
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
            // One round trip to hear of the globals, one for the manager's capabilities
            fn.display_roundtrip_queue(display, queue);
            if (!manager || !compositor)
            {
                close();
                return false;
            }
            fn.display_roundtrip_queue(display, queue);
            enum getBackgroundEffect = 1;
            effect = fn.proxy_marshal_flags(manager, getBackgroundEffect, &effectSurfaceInterface,
                                            fn.proxy_get_version(manager), 0, null, surface);
            if (!effect)
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
            enum destroy = 0, destructor = 1; // request 0 of both, which destroys the proxy too
            if (effect) fn.proxy_marshal_flags(effect, destroy, null, fn.proxy_get_version(effect), destructor);
            if (manager) fn.proxy_marshal_flags(manager, destroy, null, fn.proxy_get_version(manager), destructor);
            if (compositor) fn.proxy_destroy(compositor);
            if (registry) fn.proxy_destroy(registry);
            if (queue) fn.event_queue_destroy(queue);
            if (lib) dlclose(lib);
        }
        this = BackgroundBlur.init;
    }

    /// Whether the compositor blurs: set up, and it says it can.
    bool available() const nothrow @nogc { return effect !is null && blurs; }

    /// Hears what's arrived on our queue: the capabilities, which can change.
    void dispatch() nothrow @nogc
    {
        if (queue)
            fn.display_dispatch_queue_pending(display, queue);
    }

    /// Blurs behind the first `count` of `rects`, from the next frame presented; none for no blur.
    /// Asks only if they're not what it asked for last.
    void setRegion(size_t count) nothrow @nogc
    {
        if (!effect)
            return;
        // FNV-1a, to tell whether they've changed without keeping a copy
        ulong hash = 14695981039346656037UL;
        foreach (r; rects[0 .. count])
            foreach (v; r)
                hash = (hash ^ cast(uint) v) * 1099511628211UL;
        if (count == lastCount && hash == lastHash)
            return;
        lastCount = count;
        lastHash = hash;

        enum setBlurRegion = 1;
        if (!count)
        {
            fn.proxy_marshal_flags(effect, setBlurRegion, null, fn.proxy_get_version(effect), 0, null);
            fn.display_flush(display);
            return;
        }
        enum createRegion = 1, add = 1, destroy = 0, destructor = 1;
        auto region = fn.proxy_marshal_flags(compositor, createRegion, regionInterface, fn.proxy_get_version(compositor), 0, null);
        if (!region)
            return;
        foreach (r; rects[0 .. count])
            fn.proxy_marshal_flags(region, add, null, fn.proxy_get_version(region), 0, r[0], r[1], r[2], r[3]);
        fn.proxy_marshal_flags(effect, setBlurRegion, null, fn.proxy_get_version(effect), 0, region);
        // The effect copies the region, so it can go straight away
        fn.proxy_marshal_flags(region, destroy, null, fn.proxy_get_version(region), destructor);
        fn.display_flush(display);
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
        int function(void*) display_flush;
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
    const(void)* registryInterface, compositorInterface, surfaceInterface, regionInterface;
    void* display, queue, registry, compositor, manager, effect;
    bool blurs;              // the compositor's said it can
    size_t lastCount;        // what was asked for last
    ulong lastHash;

    struct RegistryListener
    {
        extern (C) void function(void*, void*, uint, const(char)*, uint) nothrow @nogc global;
        extern (C) void function(void*, void*, uint) nothrow @nogc globalRemove;
    }
    struct ManagerListener
    {
        extern (C) void function(void*, void*, uint) nothrow @nogc capabilities;
    }
    static immutable registryListener = RegistryListener(&global, &globalRemove);
    static immutable managerListener = ManagerListener(&capabilities);

    static extern (C) void global(void* data, void* registry, uint name, const(char)* iface, uint version_) nothrow @nogc
    {
        auto self = cast(BackgroundBlur*) data;
        enum bind = 0;
        if (!self.manager && strcmp(iface, managerInterface.name) == 0)
        {
            self.manager = self.fn.proxy_marshal_flags(registry, bind, &managerInterface, 1, 0, name,
                                                       managerInterface.name, 1, null);
            if (self.manager)
                self.fn.proxy_add_listener(self.manager, &managerListener, data);
        }
        else if (!self.compositor && strcmp(iface, "wl_compositor") == 0)
            self.compositor = self.fn.proxy_marshal_flags(registry, bind, self.compositorInterface, 1, 0, name,
                                                          "wl_compositor".ptr, 1, null);
    }
    static extern (C) void globalRemove(void*, void*, uint) nothrow @nogc {}

    static extern (C) void capabilities(void* data, void*, uint flags) nothrow @nogc
    {
        enum blur = 1;
        (cast(BackgroundBlur*) data).blurs = (flags & blur) != 0;
    }

    /*
        The protocol's two interfaces, as wayland-scanner would write them from
        ext-background-effect-v1.xml: each request's and event's name, its arguments' types as
        letters ("n" a new object, "o" an object, "?" one that can be null, "u" a number), and the
        interface of each object argument. Those that point to libwayland-client's own are filled
        in once it's opened.
    */
    struct Message { const(char)* name, signature; const(void)** types; }
    struct Interface { const(char)* name; int version_; int methodCount; const(Message)* methods; int eventCount; const(Message)* events; }

    __gshared const(void)*[2] noTypes;                 // for messages with no object arguments
    __gshared const(void)*[2] getBackgroundEffectTypes; // the new effect, and the wl_surface
    __gshared const(void)*[1] setBlurRegionTypes;      // the wl_region
    __gshared Message[2] managerRequests, effectRequests;
    __gshared Message[1] managerEvents;
    __gshared Interface managerInterface, effectSurfaceInterface;

    void fillInterfaces() nothrow @nogc
    {
        getBackgroundEffectTypes = [&effectSurfaceInterface, surfaceInterface];
        setBlurRegionTypes = [regionInterface];
        managerRequests = [Message("destroy", "", noTypes.ptr),
                           Message("get_background_effect", "no", getBackgroundEffectTypes.ptr)];
        managerEvents = [Message("capabilities", "u", noTypes.ptr)];
        effectRequests = [Message("destroy", "", noTypes.ptr),
                          Message("set_blur_region", "?o", setBlurRegionTypes.ptr)];
        managerInterface = Interface("ext_background_effect_manager_v1", 1, 2, managerRequests.ptr, 1, managerEvents.ptr);
        effectSurfaceInterface = Interface("ext_background_effect_surface_v1", 1, 2, effectRequests.ptr, 0, null);
    }
}
