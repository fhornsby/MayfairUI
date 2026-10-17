module mayfair.windowing.accessibility;

import core.stdc.stdlib : calloc, free, malloc;
import mayfair.log;
import core.stdc.string : memcpy, strlen;
import sdl;
import mayfair.accessibility;
import mayfair.widgets;

/*
    The window's link to the platform's accessibility API, through AccessKit.

    AccessKit calls back from a thread of its own -- when a screen reader connects, and when one
    asks for something to be done -- and the widget tree belongs to the UI thread. So nothing is
    done on AccessKit's thread except to post an SDL event, which wakes the loop and is handled
    there like any other input. That includes the first tree: the activation handler returns
    nothing, and AccessKit then takes the next update as the whole tree, which is built on the UI
    thread after the frame that asked for it.

    Linux only for now, like the rest of the kit: the other platforms' adapters need the native
    window handle, and have the same shape once there's a renderer for them to go with.
*/
struct AccessibilityAdapter
{
    /// What the events this posts carry in their `code`.
    enum Request : int { activate, action }

    /// Starts listening for assistive technology. `eventType` is the SDL event type to post requests as.
    void open(SDL_Window* window, uint eventType) nothrow @nogc
    {
        this.window = window;
        poster = Poster(eventType, SDL_GetWindowID(window));
        version (linux)
            adapter = accesskit_unix_adapter_new(&activate, &poster, &act, &poster, &deactivate, null);
    }

    void close() nothrow @nogc
    {
        version (linux)
            if (adapter)
                accesskit_unix_adapter_free(adapter);
        adapter = null;
    }

    /// Asks for the whole tree to go with the next update, as a screen reader has just connected.
    void requestFullTree() nothrow @nogc { fullTreeRequested = true; }

    /// Whether an update would say anything.
    bool updateNeeded(Scene scene, double pointsToWindow) nothrow @nogc
    {
        return adapter && (fullTreeRequested || scene.accessibilityPending(pointsToWindow));
    }

    /// Sends what's changed in `scene`, if assistive technology is listening. Otherwise nothing is
    /// built: the whole tree is, when one starts listening.
    void update(Scene scene, const(char)[] title, double pointsToWindow)
    {
        auto context = UpdateContext(scene, title, pointsToWindow, fullTreeRequested);
        // The binding calls every C callback @nogc, but this one is called straight back, on this
        // thread, before update_if_active returns: widgets describing themselves are free to allocate.
        version (linux)
            accesskit_unix_adapter_update_if_active(adapter, cast(accesskit_tree_update_factory) &buildUpdate, &context);
        if (context.built && context.full)
            fullTreeRequested = false;
    }

    /// The window gained or lost keyboard focus.
    void windowFocus(bool focused) nothrow @nogc
    {
        version (linux)
            if (adapter)
                accesskit_unix_adapter_update_window_focus_state(adapter, focused);
    }

    /*
        Unpacks an action request posted from AccessKit's thread, and frees it. The request came
        with a copy of whatever data it had, since AccessKit's own is freed as soon as its callback
        returns.
    */
    static void takeAction(void* posted, out ulong target, out accesskit_action action,
                           out AccessibleActionData data)
    {
        auto p = cast(PendingAction*) posted;
        target = p.target;
        action = p.action;
        if (p.value)
        {
            data.value = p.value[0 .. strlen(p.value)].idup;
            free(p.value);
        }
        if (p.hasSelection)
        {
            data.anchor = AccessibleTextPosition(p.selection.anchor.node, p.selection.anchor.character_index);
            data.focus = AccessibleTextPosition(p.selection.focus.node, p.selection.focus.character_index);
        }
        data.page = p.page;
        data.number = p.number;
        data.scrollX = p.offset.x;
        data.scrollY = p.offset.y;
        free(p);
    }

    /// The window moved or changed size. Only X11 can say where a window is; Wayland keeps that
    /// from the app, and this does no harm there.
    void windowBoundsChanged() nothrow @nogc
    {
        version (linux)
        {
            if (!adapter)
                return;
            int x, y, w, h, top, left, bottom, right;
            SDL_GetWindowPosition(window, &x, &y);
            SDL_GetWindowSize(window, &w, &h);
            SDL_GetWindowBordersSize(window, &top, &left, &bottom, &right);
            accesskit_unix_adapter_set_root_window_bounds(adapter,
                accesskit_rect(x - left, y - top, x + w + right, y + h + bottom),
                accesskit_rect(x, y, x + w, y + h));
        }
    }

private:
    // What the handlers need to post an event, which is all they do. It lives in the adapter,
    // which lives in the App, a class, so the pointer AccessKit holds to it stays good.
    struct Poster
    {
        uint eventType;
        SDL_WindowID windowID;
    }

    struct UpdateContext
    {
        Scene scene;
        const(char)[] title;
        double pointsToWindow;
        bool full;
        bool built;
    }

    SDL_Window* window;
    Poster poster;
    bool fullTreeRequested;
    version (linux) accesskit_unix_adapter* adapter;
    else void* adapter;
}

// An action request on its way from AccessKit's thread to the UI thread, in C memory, since
// AccessKit's thread isn't one the D runtime knows about
private struct PendingAction
{
    accesskit_action action;
    ulong target;
    char* value;                        // copied, for setValue and replaceSelectedText
    bool hasSelection;
    accesskit_text_selection selection; // for setTextSelection
    bool page;                          // for scrollUp and the rest
    double number = double.nan;         // for setValue, given a number
    accesskit_point offset;             // for setScrollOffset
}

private void post(void* userdata, AccessibilityAdapter.Request request, void* payload) nothrow @nogc
{
    auto poster = cast(AccessibilityAdapter.Poster*) userdata;
    SDL_Event event;
    event.type = poster.eventType;
    event.user.windowID = poster.windowID;
    event.user.code = request;
    event.user.data1 = payload;
    SDL_PushEvent(&event); // safe from any thread
}

// Called on AccessKit's thread when a screen reader connects
private extern(C) accesskit_tree_update* activate(void* userdata) nothrow @nogc
{
    post(userdata, AccessibilityAdapter.Request.activate, null);
    return null; // the tree comes with the next update, built on the UI thread
}

// Called on AccessKit's thread, which has handed over the request to free
private extern(C) void act(accesskit_action_request* request, void* userdata) nothrow @nogc
{
    auto p = cast(PendingAction*) calloc(1, PendingAction.sizeof);
    if (p)
    {
        p.action = request.action;
        p.number = double.nan; // calloc's zero would be a number
        p.target = request.target_node;
        if (request.data.has_value)
        {
            const data = &request.data.value;
            if (data.tag == ACCESSKIT_ACTION_DATA_VALUE && data.value)
            {
                const length = strlen(data.value);
                p.value = cast(char*) malloc(length + 1);
                if (p.value)
                    memcpy(p.value, data.value, length + 1);
            }
            else if (data.tag == ACCESSKIT_ACTION_DATA_SET_TEXT_SELECTION)
            {
                p.hasSelection = true;
                p.selection = data.set_text_selection;
            }
            else if (data.tag == ACCESSKIT_ACTION_DATA_NUMERIC_VALUE)
                p.number = data.numeric_value;
            else if (data.tag == ACCESSKIT_ACTION_DATA_SCROLL_UNIT)
                p.page = data.scroll_unit == ACCESSKIT_SCROLL_UNIT_PAGE;
            else if (data.tag == ACCESSKIT_ACTION_DATA_SET_SCROLL_OFFSET)
                p.offset = data.set_scroll_offset;
        }
        post(userdata, AccessibilityAdapter.Request.action, p);
    }
    accesskit_action_request_free(request);
}

// Called on AccessKit's thread when the last screen reader goes. Nothing is kept for one, so
// there's nothing to let go of.
private extern(C) void deactivate(void* userdata) nothrow @nogc {}

// Called on the UI thread, from inside update_if_active, and only if something is listening
private extern(C) accesskit_tree_update* buildUpdate(void* userdata) nothrow
{
    auto context = cast(AccessibilityAdapter.UpdateContext*) userdata;
    try
    {
        auto update = context.scene.buildAccessibilityUpdate(context.full, context.title, context.pointsToWindow);
        context.built = true;
        return update;
    }
    catch (Exception e)
    {
        // Widgets' own failures are caught where they happen, so this is the kit's. It mustn't
        // return null, and an exception mustn't cross into Rust; and a first tree has to be a
        // whole one, or AccessKit panics. The window on its own is the smallest whole tree.
        logWarning("Accessibility update failed: %.*s", cast(int) e.msg.length, e.msg.ptr);
        auto update = accesskit_tree_update_with_focus(0);
        if (context.full)
        {
            accesskit_tree_update_set_tree_info(update, accesskit_tree_info_new(0));
            accesskit_tree_update_push_node(update, 0, accesskit_node_new(ACCESSKIT_ROLE_WINDOW));
        }
        return update;
    }
}
