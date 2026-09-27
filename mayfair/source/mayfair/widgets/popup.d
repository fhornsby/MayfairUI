module mayfair.widgets.popup;

import mayfair.animation;
import mayfair.layout;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.theme;
import mayfair.widgets.layouts : Alignment;
import mayfair.widgets.scene;
import mayfair.widgets.widget;

/// Which side of what it's shown for a popup goes.
enum Side { below, above, right, left }

/*
    Something shown over the window, above everything in it, and gone again: what a menu, a
    drop-down's list, a tooltip and a dialog are each made of. JavaFX's Popup.

        auto popup = new Popup(new Label("Hello").padding(12));
        popup.show(button);                 // below the button
        popup.show(button, Side.right);     // beside it
        popup.showAt(widget, x, y);         // at a point, as a context menu is at the pointer
        popup.showCentred(widget);          // in the middle of the window, as a dialog is

    It's as big as its content asks, never bigger than the window, and placed against what it's
    shown for: below it, say, lined up with its left edge -- or above, if there isn't room below,
    and kept inside the window. It's drawn with a shadow under it, and fades in.

    What happens round it is up to its settings:

    - autoHide (on by default): while it's showing, the rest of the window doesn't respond -- the
      pointer over it lights nothing up -- and a press outside, or Escape, hides it, and that's all
      the press does. What a menu does.
    - modal: the window behind is dimmed, and doesn't respond at all until it's hidden in code.
      What a dialog does.
    - takesFocus (on by default): it has keyboard focus while it's showing -- the first thing in it
      Tab reaches, or itself -- and Tab stays inside it; when it's hidden, focus goes back to what
      had it. A tooltip doesn't.
    - pointerTransparent: the pointer passes through to what's underneath. A tooltip is.

    It takes its colours from what it's shown for: variables like --accent are looked up from
    there, so a popup opened from part of the window styled differently looks like that part.

    Its style class is "popup".
*/
class Popup : Widget
{
public:
    this(Widget content = null)
    {
        styleClass.add("popup");
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionColumn);
        _fade = new Transition(Theme.popup_fade_time, (t) { _shownAmount = t; if (scene) scene.paintRequested = true; });
        _fade.interpolator(Interpolator.easeOut);
        if (content)
            setContent(content);
    }

    /// What it shows.
    mixin(declareProperty!(Widget, "content", "null", q{ swapContent(); }));

    /// Whether a press outside it, or Escape, hides it, and the rest of the window waits meanwhile.
    mixin(declareProperty!(bool, "autoHide", "true"));

    /// Whether the window behind it is dimmed and doesn't respond until it's hidden.
    mixin(declareProperty!(bool, "modal", "false"));

    /// Whether it has keyboard focus while it's showing.
    mixin(declareProperty!(bool, "takesFocus", "true"));

    /// Whether the pointer passes through it to what's underneath.
    mixin(declareProperty!(bool, "pointerTransparent", "false"));

    /// Shows it `side` of `owner`, `gap` points away, lined up with the owner's start, middle or
    /// end as `alignment` says.
    final void show(Widget owner, Side side = Side.below, float gap = 4, Alignment alignment = Alignment.start)
    {
        _placement = Placement.beside;
        _side = side;
        _gap = gap;
        _alignment = alignment;
        open(owner);
    }

    /// Shows it with its top left at `x`, `y` points from the window's top left, for `owner`.
    final void showAt(Widget owner, float x, float y)
    {
        _placement = Placement.at;
        _atX = x;
        _atY = y;
        open(owner);
    }

    /// Shows it in the middle of the window `owner` is in.
    final void showCentred(Widget owner)
    {
        _placement = Placement.centre;
        open(owner);
    }

    /// Hides it, if it's showing, and anything shown over it since.
    final void hide()
    {
        if (_showingIn)
            _showingIn.hidePopup(this);
    }

    /// Whether it's showing.
    final bool showing() const nothrow @nogc { return _showingIn !is null; }

    /// What it was last shown for.
    final Widget owner() nothrow @nogc { return _owner; }

    /// What to do once it's been hidden, however that happened.
    final Popup onHidden(void delegate() handler) nothrow @nogc
    {
        _onHidden = handler;
        return this;
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; } // its content is a property

    /// Called once it's hidden, however that happened: for a subclass to put itself back to rest.
    void hidden() {}

package:
    enum Placement { beside, at, centre }
    Scene _showingIn;
    Tvg_Paint _layer, _scrim;  // the layer it's drawn in, and a modal one's dimming behind it
    Widget _focusBefore;       // what had focus when it took it
    bool _focusShownBefore;    // and whether that focus was shown
    double _shownAmount = 0;   // how far it's faded in

    /// Puts it where it goes, now its size is known, inside the window's content: `originX`, `originY`,
    /// `windowWidth` by `windowHeight` -- inside any shadow the window draws round itself.
    void place(float originX, float originY, float windowWidth, float windowHeight) nothrow @nogc
    {
        const w = YGNodeLayoutGetWidth(node), h = YGNodeLayoutGetHeight(node);
        // Worked out from the content's top left, and moved there at the end
        float x = 0, y = 0;
        final switch (_placement)
        {
            case Placement.centre:
                x = (windowWidth - w) / 2;
                y = (windowHeight - h) / 2;
                break;
            case Placement.at:
                x = _atX - originX;
                y = _atY - originY;
                if (x + w > windowWidth) x = x - w;   // to the left of the point, rather than off the edge
                if (y + h > windowHeight) y = y - h;  // or above it
                break;
            case Placement.beside:
                const b = _owner ? _owner.boundsIn(null) : Bounds(0, 0, 0, 0);
                const o = Bounds(b.minX - originX, b.minY - originY, b.width, b.height);
                final switch (_side)
                {
                    case Side.below, Side.above:
                        x = _alignment == Alignment.start ? o.minX
                          : _alignment == Alignment.centre ? o.centreX - w / 2 : o.maxX - w;
                        const below = o.maxY + _gap, above = o.minY - _gap - h;
                        const roomBelow = below + h <= windowHeight, roomAbove = above >= 0;
                        y = _side == Side.below ? (roomBelow || !roomAbove ? below : above)
                                                : (roomAbove || !roomBelow ? above : below);
                        break;
                    case Side.right, Side.left:
                        y = _alignment == Alignment.start ? o.minY
                          : _alignment == Alignment.centre ? o.centreY - h / 2 : o.maxY - h;
                        const right = o.maxX + _gap, left = o.minX - _gap - w;
                        const roomRight = right + w <= windowWidth, roomLeft = left >= 0;
                        x = _side == Side.right ? (roomRight || !roomLeft ? right : left)
                                                : (roomLeft || !roomRight ? left : right);
                        break;
                }
                break;
        }
        // Inside the window, as far as it fits
        if (x + w > windowWidth) x = windowWidth - w;
        if (y + h > windowHeight) y = windowHeight - h;
        if (x < 0) x = 0;
        if (y < 0) y = 0;
        const scale = scene ? scene.scale : 1.0f;
        import std.math : round;
        cellX = round((originX + x) * scale) / scale;
        cellY = round((originY + y) * scale) / scale;
    }

    void opened()
    {
        _shownAmount = 0;
        _fade.playFromStart();
    }

    void closed()
    {
        _fade.stop();
        hidden();
        if (_onHidden)
            _onHidden();
    }

private:
    Placement _placement;
    Side _side;
    Alignment _alignment;
    float _gap = 4, _atX = 0, _atY = 0;
    Widget _owner, _shownContent;
    Transition _fade;
    void delegate() _onHidden;

    void open(Widget owner)
    {
        auto scene = owner ? owner.scene : null;
        if (!scene)
            throw new Exception("a popup is shown for something in a window: this one's owner isn't in one");
        if (_showingIn)
            _showingIn.hidePopup(this);
        _owner = owner;
        styleOwner = owner;
        scene.showPopup(this);
    }

    void swapContent()
    {
        if (_shownContent)
            remove(_shownContent);
        _shownContent = _content;
        if (_content)
            adopt(_content);
    }
}
