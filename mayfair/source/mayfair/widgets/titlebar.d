module mayfair.widgets.titlebar;

import std.algorithm : canFind, splitter;
import std.string : indexOf, strip;
import mayfair.accessibility;
import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.button;
import mayfair.widgets.buttonbase;
import mayfair.widgets.icon;
import mayfair.widgets.input;
import mayfair.widgets.label;
import mayfair.widgets.layouts;
import mayfair.widgets.scene;
import mayfair.widgets.styling;
import mayfair.widgets.widget;

/*
    The bar along the top of a window, drawn by the app rather than the desktop: its title, the
    window's buttons, and whatever the app puts in it -- as macOS apps put a toolbar there, and
    GNOME's put buttons and tabs in a header bar.

        auto bar = new TitleBar("Documents")
            .addStart(new Button().graphic(new Icon("document-open-symbolic")).tooltip("Open"))
            .addEnd(new MenuButton().graphic(new Icon("open-menu-symbolic")).menu(appMenu));
        scene.titleBar(bar);

    Given one, a window draws its own decorations whatever the desktop is. Without one, the desktop
    draws them where it will, and Mayfair draws a plain one where it won't (see
    mayfair.windowing.decorations).

    The title is in the middle of the window, as GNOME's is, whatever's at either end -- moved
    aside only if they'd cover it. titleWidget puts something else there: a search field, or tabs.
    Dragging the bar anywhere that isn't a control moves the window, double clicking it maximises
    or restores it, and a secondary click shows the window's own menu. The minimise, maximise and
    close buttons are where the desktop's settings put them (GNOME's button-layout), at the end
    unless they say otherwise.

    Its style class is "title-bar", with :backdrop while the window doesn't have focus, as GNOME
    fades its title bars. Its parts are `.start`, `.end` and `.title`, and the window buttons are
    `.window-button`s.
*/
class TitleBar : CustomLayout
{
public:
    this(string title = null)
    {
        styleClass.add("title-bar");
        _start = new Row();
        _start.styleClass.add("start");
        _start.setAlignment(Pos.centreLeft);
        _end = new Row();
        _end.styleClass.add("end");
        _end.setAlignment(Pos.centreRight);
        _titleLabel = new Label(title);
        _titleLabel.styleClass.add("title");
        _centre = new Stack();
        _centre.add(_titleLabel);
        adopt(_start);
        adopt(_centre);
        adopt(_end);
        _title = title;
        addWindowButtons();
    }

    /// What it says in the middle: the window's title, unless titleWidget says otherwise.
    mixin(declareProperty!(string, "title", "null", q{ _titleLabel.setText(_title); }));

    /// Something in the middle in the title's place: a search field, a set of tabs. Null for the title.
    mixin(declareProperty!(Widget, "titleWidget", "null", q{ showTitleWidget(); }));

    /// Whether it shows the minimise, maximise and close buttons.
    mixin(declareProperty!(bool, "showWindowButtons", "true", q{
        foreach (b; _windowButtons)
            b.setVisible(_showWindowButtons && b._wanted);
    }));

    /// Adds `w` at the start, after what's there. Returns this, so calls chain.
    final TitleBar addStart(Widget w)
    {
        _start.add(w);
        if (_startButtonsFirst)
        {
            // The window buttons that go at the start stay first
            foreach (b; _windowButtons)
                if (b.parent is _start)
                {
                    _start.remove(b);
                    _start.add(b);
                }
        }
        return this;
    }

    /// Adds `w` at the end, before the window buttons that go there.
    final TitleBar addEnd(Widget w)
    {
        _end.add(w);
        foreach (b; _windowButtons)
            if (b.parent is _end)
            {
                _end.remove(b);
                _end.add(b);
            }
        return this;
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    override void placeChild(Widget child) nothrow @nogc
    {
        setCell(child, false, true, Pos.centreLeft);
    }

    override void measureContent(float width, float height, out float w, out float h) nothrow @nogc
    {
        float sw, sh, cw, ch, ew, eh;
        measureCell(_start, float.nan, sw, sh);
        measureCell(_centre, float.nan, cw, ch);
        measureCell(_end, float.nan, ew, eh);
        w = sw + cw + ew + 2 * gap;
        h = sh > ch ? sh : ch;
        if (eh > h) h = eh;
    }

    override void arrange(float width, float height) nothrow @nogc
    {
        float sw, sh, cw, ch, ew, eh;
        measureCell(_start, float.nan, sw, sh);
        measureCell(_end, float.nan, ew, eh);
        measureCell(_centre, float.nan, cw, ch);
        layoutCell(_start, 0, 0, sw, height);
        layoutCell(_end, width - ew, 0, ew, height);
        // In the middle of the whole bar, unless that would cover either end
        const left = sw + gap, right = width - ew - gap;
        const room = right - left;
        if (cw > room)
            cw = room > 0 ? room : 0;
        float x = (width - cw) / 2;
        if (x < left) x = left;
        if (x + cw > right) x = right - cw;
        layoutCell(_centre, x, 0, cw, height);
    }

    override void handleMouse(ref MouseEvent event)
    {
        auto controls = scene ? scene.windowControls : null;
        if (!controls)
            return;
        // A drag from a press on the bar moves the window, once it's gone further than a hand
        // shakes during a double click (GTK's drag threshold)
        if (event.type == MouseEventType.dragged && _movePending)
        {
            enum threshold = 8;
            const dx = event.sceneX - _pressX, dy = event.sceneY - _pressY;
            if (dx * dx + dy * dy >= threshold * threshold)
            {
                _movePending = false;
                controls.beginMove();
            }
            event.consume();
            return;
        }
        if (event.type == MouseEventType.released)
            _movePending = false;

        // A press anywhere that isn't a control is the window's: its menu for the secondary
        // button, and maximising on a double click of the primary one. A single press of it
        // might be the start of a move -- or, where the window system takes the press to move
        // the window, has already been one
        if (event.type != MouseEventType.pressed || !isDragArea(event.target))
            return;
        if (event.button == MouseButton.secondary)
        {
            controls.showMenu(event.sceneX, event.sceneY);
            event.consume();
        }
        else if (event.button == MouseButton.primary && event.clickCount == 2)
        {
            _movePending = false;
            controls.toggleMaximised();
            event.consume();
        }
        else if (event.button == MouseButton.primary && controls.movesByDrag())
        {
            _movePending = true;
            _pressX = event.sceneX;
            _pressY = event.sceneY;
            event.consume();
        }
    }

package(mayfair):
    /// Whether a press at `x`, `y`, in the window, is on the bar where there's no control:
    /// somewhere to drag the window by.
    bool dragsWindowAt(float x, float y) nothrow @nogc
    {
        auto hit = pick(x, y);
        return hit && isDragArea(hit);
    }

    /// Whether a press at `w` -- what's under the pointer -- is on the bar itself rather than a
    /// control in it: somewhere to drag the window by.
    bool isDragArea(Widget w) nothrow @nogc
    {
        for (auto a = w; a && a !is this; a = a.parent)
            if (a.focusTraversable || cast(ButtonBase) a || a.acceptsTextInput)
                return false;
        return true;
    }

    /// The window was maximised or restored: the button says which it does now.
    void windowMaximised(bool on)
    {
        foreach (b; _windowButtons)
            if (b._kind == WindowButton.Kind.maximise)
                b.showMaximised(on);
    }

    /// The window gained or lost focus.
    void windowFocused(bool on)
    {
        pseudoClassStateChanged(pseudo!"backdrop", !on);
    }

private:
    enum gap = 12; // points kept between the title and either end
    Row _start, _end;
    Stack _centre;
    Label _titleLabel;
    Widget _shownTitleWidget;
    WindowButton[] _windowButtons;
    bool _startButtonsFirst;
    bool _movePending;     // the primary button went down on the bar, and a drag would move the window
    float _pressX, _pressY; // where, in the window

    void showTitleWidget()
    {
        if (_shownTitleWidget)
            _centre.remove(_shownTitleWidget);
        _shownTitleWidget = _titleWidget;
        _titleLabel.setVisible(_titleWidget is null);
        if (_titleWidget)
            _centre.add(_titleWidget);
    }

    // The desktop's button layout: "minimize,maximize:close" and the like -- what's before the
    // colon at the start, after it at the end
    void addWindowButtons()
    {
        const layout = buttonLayout();
        const colon = layout.indexOf(':');
        const startPart = colon >= 0 ? layout[0 .. colon] : "";
        const endPart = colon >= 0 ? layout[colon + 1 .. $] : layout;
        addButtons(startPart, _start);
        addButtons(endPart, _end);
    }

    void addButtons(const(char)[] part, Row box)
    {
        foreach (name; part.splitter(','))
        {
            WindowButton.Kind kind;
            switch (name.strip)
            {
                case "minimize": kind = WindowButton.Kind.minimise; break;
                case "maximize": kind = WindowButton.Kind.maximise; break;
                case "close":    kind = WindowButton.Kind.close; break;
                default: continue; // appmenu, icon, spacer: not buttons of the window's
            }
            auto b = new WindowButton(kind);
            _windowButtons ~= b;
            box.add(b);
            if (box is _start)
                _startButtonsFirst = true;
        }
    }
}

/// One of the window's own buttons in a title bar.
final class WindowButton : Button
{
public:
    enum Kind { minimise, maximise, close }

    this(Kind kind)
    {
        _kind = kind;
        styleClass.remove("button");
        styleClass.add("window-button");
        setFocusTraversable(false);
        static immutable icons = ["window-minimize-symbolic", "window-maximize-symbolic", "window-close-symbolic"];
        static immutable names = ["Minimise", "Maximise", "Close"];
        setGraphic(new Icon(icons[kind]));
        setAccessibleText(names[kind]);
        setTooltip(names[kind]);
    }

    override void fire()
    {
        auto controls = scene ? scene.windowControls : null;
        if (controls)
            final switch (_kind)
            {
                case Kind.minimise: controls.minimise(); break;
                case Kind.maximise: controls.toggleMaximised(); break;
                case Kind.close:    controls.close(); break;
            }
        super.fire();
    }

package:
    Kind _kind;
    bool _wanted = true;

    void showMaximised(bool on)
    {
        (cast(Icon) graphic).setIconName(on ? "window-restore-symbolic" : "window-maximize-symbolic");
        setAccessibleText(on ? "Restore" : "Maximise");
        setTooltip(on ? "Restore" : "Maximise");
    }
}

/*
    Which window buttons the desktop puts where: GNOME's org.gnome.desktop.wm.preferences
    button-layout, read once, as the icon theme is. Minimise, maximise and close at the end,
    elsewhere or if it can't be read.
*/
private string buttonLayout()
{
    static string layout;
    if (layout.length)
        return layout;
    layout = ":minimize,maximize,close";
    try
    {
        import std.process : execute;
        const r = execute(["gsettings", "get", "org.gnome.desktop.wm.preferences", "button-layout"]);
        if (r.status == 0)
        {
            const v = r.output.strip;
            if (v.length > 2 && v[0] == '\'' && v[$ - 1] == '\'')
                layout = v[1 .. $ - 1];
        }
    }
    catch (Exception) {}
    return layout;
}
