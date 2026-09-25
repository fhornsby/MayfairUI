module mayfair.widgets.button;

import mayfair.accessibility;
import mayfair.animation;
import mayfair.layout;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.theme;
import mayfair.widgets.input;
import mayfair.widgets.label;
import mayfair.widgets.widget;

/*
    A push button: some text on a rounded rectangle, which runs its action when clicked.

        new Button("Save").onAction({ save(); })

    It behaves like JavaFX's. Pressing the primary button on it arms it; dragging off disarms it
    and dragging back on arms it again; and the action runs on release, and only if it's armed
    then. So a press you change your mind about can be taken back by moving away before letting go.

    The keyboard works the same way, with Space: down arms, up fires. Enter doesn't press the
    focused button, as JavaFX's doesn't -- it presses the default button, wherever focus is, and
    Escape presses the cancel button. Those are what a dialog's OK and Cancel are.

    Transitions give it its feel. One fades the fill towards the hover colour as the pointer comes
    over it; another darkens it and shrinks it slightly while it's armed, so it looks pushed in;
    and a third fades the focus ring in and out. Each runs backwards when its state ends, from
    wherever it has got to, so a quick pass over the button never jumps.

    The text is a Label child, which is how JavaFX's own button skin draws it too. To a screen
    reader, though, the text is the button's name rather than a label inside it, so the Label is
    left out of the accessibility tree and the button says the text itself.
*/
class Button : Widget
{
public:
    this(string text)
    {
        _text = text;
        _label = new Label(text).textFill(Theme.button_text_colour).accessibleHidden(true);
        add(_label);
        setFocusTraversable(true);
        setAccessibleRole(AccessibleRole.button);
        setPadding(Insets(Theme.button_padding_y, Theme.button_padding_x));
        // Centring its one child is how a button lays out, not a setting, so it's Yoga's directly
        YGNodeStyleSetJustifyContent(node, YGJustifyCenter);
        YGNodeStyleSetAlignItems(node, YGAlignCenter);

        _hoverFade = fade(Theme.button_hover_time, (t) { _hoverAmount = t; invalidate(); });
        _pressFade = fade(Theme.button_press_time, (t) { _pressAmount = t; invalidate(); });
        _ringFade = fade(Theme.focus_ring_time, (t) { _ringAmount = t; invalidate(); });
        // A press and release in one: in and straight back out, for a button pressed by Enter or Escape
        _flash = fade(Theme.button_press_time, (t) { _flashAmount = t; invalidate(); });
        _flash.cycleCount(2).autoReverse(true);
    }

    /// What it says.
    mixin(declareProperty!(string, "text", "null", q{
        _label.setText(_text);
        invalidateAccessible();
    }));

    /// What to do when the button is clicked. JavaFX's setOnAction.
    void setOnAction(void delegate() handler) nothrow @nogc
    {
        _onAction = handler;
    }

    /// The same, returning this so calls chain.
    Button onAction(void delegate() handler) nothrow @nogc
    {
        _onAction = handler;
        return this;
    }

    /// Runs the action, as though the button had been clicked.
    void fire()
    {
        if (_onAction)
            _onAction();
    }

    /// Whether this is the button Enter presses, wherever focus is. It's drawn in the accent colour.
    mixin(declareProperty!(bool, "defaultButton", "false", q{ invalidate(); }));

    /// Whether this is the button Escape presses, wherever focus is.
    mixin(declareProperty!(bool, "cancelButton", "false"));

    /// Whether it's pressed in and will fire when let go: held down with the pointer still over it,
    /// or with Space. JavaFX's armed.
    mixin(declareReadOnlyProperty!(bool, "armed", "false"));

protected:
    override void handleMouse(ref MouseEvent event)
    {
        switch (event.type)
        {
            case MouseEventType.entered:
                _hoverFade.playForward();
                if (pressed) // the press started here and the pointer has come back
                    arm(true);
                break;
            case MouseEventType.exited:
                _hoverFade.playReverse();
                arm(false);
                break;
            case MouseEventType.pressed:
                if (event.button == MouseButton.primary)
                {
                    requestFocus();
                    arm(true);
                    event.consume();
                }
                break;
            case MouseEventType.released:
                if (event.button == MouseButton.primary)
                {
                    event.consume();
                    release();
                }
                break;
            default:
                break;
        }
    }

    override void handleKey(ref KeyEvent event)
    {
        if (event.code != KeyCode.space)
            return;
        if (event.type == KeyEventType.pressed)
        {
            if (!event.repeat)
                arm(true);
        }
        else
        {
            release();
        }
        event.consume();
    }

    override void handleShortcut(ref KeyEvent event)
    {
        if (event.type != KeyEventType.pressed || event.repeat)
            return;
        const enter = event.code == KeyCode.enter || event.code == KeyCode.numpadEnter;
        if ((enter && _defaultButton) || (event.code == KeyCode.escape && _cancelButton))
        {
            event.consume();
            _flash.playFromStart();
            fire();
        }
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        node.label(_label.text);
        node.addAction(AccessibleAction.fire);
    }

    /// A screen reader pressing the button looks like Enter pressing a default one: in and out, and fire.
    override bool executeAccessibleAction(AccessibleAction action, ref const AccessibleActionData data)
    {
        if (action != AccessibleAction.fire)
            return super.executeAccessibleAction(action, data);
        _flash.playFromStart();
        fire();
        return true;
    }

    override void focusChanged()
    {
        focusVisible ? _ringFade.playForward() : _ringFade.playReverse();
        if (!focused)
            arm(false); // a Space held down when focus went elsewhere never gets its release
    }

    override void disabledChanged()
    {
        // A disabled button hears nothing, so it lets go of any state now rather than waiting for
        // events that won't come -- and picks hover back up if it's enabled under the pointer
        hover && !disabled ? _hoverFade.playForward() : _hoverFade.playReverse();
        arm(false);
        applyOpacity();
        invalidate();
    }

    override void mounted() nothrow
    {
        applyOpacity();
    }

    override void unmounted()
    {
        foreach (t; [_hoverFade, _pressFade, _ringFade, _flash])
            t.stop();
        _hoverAmount = _pressAmount = _ringAmount = _flashAmount = 0;
        _setArmed(false);
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        // The flash and a real press both push the button in; whichever is further in wins
        const pressAmount = _pressAmount > _flashAmount ? _pressAmount : _flashAmount;
        const fill = (_defaultButton ? Theme.default_button_colour : Theme.button_colour)
            .interpolate(_defaultButton ? Theme.default_button_hover_colour : Theme.button_hover_colour, _hoverAmount)
            .interpolate(_defaultButton ? Theme.default_button_pressed_colour : Theme.button_pressed_colour, pressAmount);
        tvg_shape_set_fill_color(shape, fill.tupleof);
        tvg_shape_append_rect(shape, x, y, w, h, Theme.button_radius, Theme.button_radius, true);

        // The focus ring is the rectangle's own stroke, faded in and out through its alpha
        auto ring = Theme.focus_ring_colour;
        ring.a = cast(ubyte)(ring.a * _ringAmount);
        tvg_shape_set_stroke_width(shape, _ringAmount > 0 ? Theme.focus_ring_width : 0);
        tvg_shape_set_stroke_color(shape, ring.tupleof);

        // Shrinks the button, text and all, about its centre. A transform rather than smaller
        // geometry so the label, which is its own shape, can go with it without re-laying out.
        const s = 1 - Theme.button_press_shrink * pressAmount;
        const cx = x + w / 2, cy = y + h / 2;
        auto m = Tvg_Matrix(s, 0, cx * (1 - s),
                            0, s, cy * (1 - s),
                            0, 0, 1);
        tvg_paint_set_transform(shape, &m);
        if (_label.shape)
            tvg_paint_set_transform(_label.shape, &m);
    }

private:
    Label _label;
    void delegate() _onAction;


    Transition _hoverFade, _pressFade, _ringFade, _flash;
    double _hoverAmount = 0, _pressAmount = 0, _ringAmount = 0, _flashAmount = 0; // each 0 to 1

    void arm(bool armed)
    {
        if (armed == this.armed)
            return;
        _setArmed(armed);
        armed ? _pressFade.playForward() : _pressFade.playReverse();
    }

    /// Lets go of the button, running the action if it was still armed.
    void release()
    {
        const wasArmed = this.armed;
        arm(false);
        if (wasArmed)
            fire();
    }

    // The label fades itself: it's disabled whenever the button is
    void applyOpacity() nothrow @nogc
    {
        if (shape)
            tvg_paint_set_opacity(shape, disabled ? cast(ubyte)(255 * Theme.disabled_opacity) : 255);
    }

    static Transition fade(Duration duration, void delegate(double) action)
    {
        return new Transition(duration, action).interpolator(Interpolator.easeOut);
    }

}
