module mayfair.windowing.decorations;

import core.stdc.stdlib : getenv;
import core.stdc.string : strcmp;

/*
    Who draws a window's title bar and edges. The desktop should, and Mayfair lets it wherever it
    will: on X11 the window manager always does, and so does macOS; on Wayland, a compositor that
    offers the xdg-decoration protocol does -- KDE's, wlroots-based ones. GNOME's doesn't, and
    leaves every app to draw its own, which SDL would do through libdecor and its GTK plugin: GTK 3
    loaded to draw one bar. So there Mayfair draws it, with a TitleBar, and libdecor is kept from
    loading a plugin.

    An app can ask for a TitleBar of its own anywhere, to put its own things in it, as macOS apps
    do; then Mayfair draws the bar whatever the desktop would have done.
*/

/*
    Whether SDL is going to use Wayland: it's there, and nothing's asked for another driver first.
    SDL_VIDEO_DRIVER (or SDL2's SDL_VIDEODRIVER) is a list SDL tries in order, "wayland,x11" say,
    as Oriel's session sets it, so the first in it is the one to go by. A guess, for what has to be
    decided before SDL starts: once it has, SDL_GetCurrentVideoDriver says.
*/
bool onWayland() nothrow @nogc
{
    import core.sys.posix.strings : strncasecmp;
    auto driver = getenv("SDL_VIDEO_DRIVER");
    if (!driver || !*driver)
        driver = getenv("SDL_VIDEODRIVER");
    if (driver && *driver)
    {
        size_t first;
        while (driver[first] && driver[first] != ',')
            first++;
        if (first != "wayland".length || strncasecmp(driver, "wayland", first) != 0)
            return false;
    }
    const display = getenv("WAYLAND_DISPLAY");
    return display && *display;
}

/*
    Whether the Wayland compositor draws windows' decorations itself: whether it offers
    zxdg_decoration_manager_v1. Asked on a connection of its own, before SDL makes its, since
    whether to keep libdecor from drawing has to be decided before SDL starts. libwayland-client is
    opened at run time, as SDL opens it, so building Mayfair doesn't need it. Anything going wrong
    counts as yes: the compositor, or SDL, will do something sensible.
*/
bool compositorDecorates() nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.dlfcn : dlclose, dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;
        auto lib = dlopen("libwayland-client.so.0", RTLD_NOW | RTLD_LOCAL);
        if (!lib)
            return true;
        scope (exit) dlclose(lib);

        alias Connect = extern(C) void* function(const(char)*) nothrow @nogc;
        alias Disconnect = extern(C) void function(void*) nothrow @nogc;
        alias Roundtrip = extern(C) int function(void*) nothrow @nogc;
        alias GetVersion = extern(C) uint function(void*) nothrow @nogc;
        alias Marshal = extern(C) void* function(void*, uint, const(void)*, uint, uint, ...) nothrow @nogc;
        alias AddListener = extern(C) int function(void*, const(void)*, void*) nothrow @nogc;
        alias Destroy = extern(C) void function(void*) nothrow @nogc;

        auto connect = cast(Connect) dlsym(lib, "wl_display_connect");
        auto disconnect = cast(Disconnect) dlsym(lib, "wl_display_disconnect");
        auto roundtrip = cast(Roundtrip) dlsym(lib, "wl_display_roundtrip");
        auto getVersion = cast(GetVersion) dlsym(lib, "wl_proxy_get_version");
        auto marshal = cast(Marshal) dlsym(lib, "wl_proxy_marshal_flags");
        auto addListener = cast(AddListener) dlsym(lib, "wl_proxy_add_listener");
        auto destroy = cast(Destroy) dlsym(lib, "wl_proxy_destroy");
        auto registryInterface = dlsym(lib, "wl_registry_interface");
        if (!connect || !disconnect || !roundtrip || !getVersion || !marshal || !addListener || !destroy
            || !registryInterface)
            return true;

        auto display = connect(null);
        if (!display)
            return true;
        scope (exit) disconnect(display);

        // wl_display_get_registry, which the header has as an inline function: request 1 of wl_display
        enum getRegistry = 1;
        auto registry = marshal(display, getRegistry, registryInterface, getVersion(display), 0, null);
        if (!registry)
            return true;
        scope (exit) destroy(registry);

        static struct Listener
        {
            extern(C) void function(void*, void*, uint, const(char)*, uint) nothrow @nogc global;
            extern(C) void function(void*, void*, uint) nothrow @nogc globalRemove;
        }
        static extern(C) void global(void* data, void* registry, uint name, const(char)* iface, uint version_) nothrow @nogc
        {
            if (strcmp(iface, "zxdg_decoration_manager_v1") == 0)
                *cast(bool*) data = true;
        }
        static extern(C) void globalRemove(void*, void*, uint) nothrow @nogc {}
        static immutable Listener listener = Listener(&global, &globalRemove);

        bool offered;
        addListener(registry, &listener, &offered);
        roundtrip(display);
        return offered;
    }
    else
        return true;
}
