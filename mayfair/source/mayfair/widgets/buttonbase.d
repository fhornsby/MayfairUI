module mayfair.widgets.buttonbase;

import core.time : Duration;
import mayfair.accessibility;
import mayfair.animation;
import mayfair.layout;
import mayfair.properties;
import mayfair.text;
import mayfair.theme;
import mayfair.widgets.input;
import mayfair.widgets.label;
import mayfair.widgets.layouts : Pos, placeChildren, horizontal, vertical;
import mayfair.widgets.styling;
import mayfair.widgets.widget;

/*
    What every control you press has in common: JavaFX's ButtonBase. Button, ToggleButton,
    RadioButton and CheckBox are each one.

    Pressing it is JavaFX's. The primary button going down on it arms it; dragging off disarms it
    and dragging back on arms it again; and it fires on release, and only if it's armed then. So a
    press you change your mind about can be taken back by moving away before letting go. The
    keyboard works the same way, with Space: down arms, up fires. What firing does is the subclass's
    -- a button runs its action; a check box toggles, then runs it -- which is fire().

    Its text is a Label, which is how JavaFX's skins draw it too, styled as "text" and in the
    control's own text fill and font. To a screen reader the text is the control's name rather than
    a label inside it, so the Label is left out of the accessibility tree and the control says it.

    Its states for a stylesheet are :hover, :armed (pressed in), :focused, :focus-visible and
    :disabled.
*/
@DefaultProperty("text")
abstract class ButtonBase : Widget
{
public:
    this(string text)
    {
        _text = text;
        _label = new Label(text).accessibleHidden(true);
        _label.styleClass.remove("label");
        _label.styleClass.add("text");
        _label.textFillProperty.bind(textFillProperty);
        _label.fontProperty.bind(fontProperty);
        _label.wrapTextProperty.bind(wrapTextProperty);
        _label.textAlignmentProperty.bind(textAlignmentProperty);
        _label.lineSpacingProperty.bind(lineSpacingProperty);
        adopt(_label);
        // Any graphic beside the text, not above it: JavaFX's default contentDisplay, LEFT
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionRow);
        placeChildren(node, horizontal(_alignment), vertical(_alignment));
        YGNodeStyleSetGap(node, YGGutterAll, _graphicTextGap);
        setFocusTraversable(true);

        // A press and release in one, for a control pressed by a key that isn't its own or by a
        // screen reader: armed, as far as the stylesheet can tell, for as long as a press takes to show
        _flash = new Timeline(KeyFrame(Duration.zero, { pseudoClassStateChanged(pseudo!"armed", true); }),
                              KeyFrame(Theme.button_press_time, { pseudoClassStateChanged(pseudo!"armed", armed); }));
    }

    /// What it says.
    mixin(declareProperty!(string, "text", "null", q{
        _label.setText(_text);
        showLabel();
        invalidateAccessible();
    }));

    /*
        A picture before the text -- an Icon, usually. JavaFX's Labeled.graphic.

            new Button("Save").graphic(new Icon("document-save-symbolic"))
            new Button().graphic(new Icon("edit-find-symbolic")).accessibleText("Search")

        It's the control's now, and hidden from screen readers, which hear the control's text. A
        button with a graphic and no text is only as wide as the graphic, and needs accessibleText
        to be something a screen reader can say.
    */
    mixin(declareProperty!(Widget, "graphic", "null", q{ placeGraphic(); }));

    /// The colour of its text. JavaFX's Labeled.textFill.
    mixin(declareStyleableProperty!(Colour, "textFill", "colour", "Theme.text_colour"));

    /// Its text's font. JavaFX's Labeled.font.
    mixin(declareStyleableProperty!(Font, "font", "font, font-family, font-size, font-weight, font-style",
                                    "null", "", true));

    /// Whether its text wraps to its width, how the lines line up, and the room between them: Label's.
    mixin(declareStyleableProperty!(bool, "wrapText", "wrap-text", "false"));
    mixin(declareStyleableProperty!(TextAlignment, "textAlignment", "text-align", "TextAlignment.left")); /// ditto
    mixin(declareStyleableProperty!(float, "lineSpacing", "line-spacing", "0")); /// ditto

    /// Space between the graphic, a check box's box or a radio button's ring, and the text. JavaFX's graphicTextGap.
    mixin(declareStyleableProperty!(float, "graphicTextGap", "graphic-text-gap", "4",
                                    q{ YGNodeStyleSetGap(node, YGGutterAll, _graphicTextGap); }));

    /// Where its graphic and text sit, when it's bigger than they are: at the left, in the middle
    /// down, unless it's a button, whose are in the middle both ways.
    mixin(declareStyleableProperty!(Pos, "alignment", "alignment", "Pos.centreLeft",
                                    q{ placeChildren(node, horizontal(_alignment), vertical(_alignment)); }));

    /// What to do when it fires. JavaFX's setOnAction.
    final void setOnAction(void delegate() handler) nothrow @nogc
    {
        _onAction = handler;
    }

    /// The same, returning this as its own type so calls chain.
    final This onAction(this This)(void delegate() handler)
    {
        _onAction = handler;
        return cast(This) this;
    }

    /// Does what pressing it does, as though it had been clicked. JavaFX's fire(): a button runs its
    /// action, and a toggle toggles first.
    void fire()
    {
        if (_onAction)
            _onAction();
    }

    /// Whether it's pressed in and will fire when let go: held down with the pointer still over it,
    /// or with Space. JavaFX's armed.
    mixin(declareReadOnlyProperty!(bool, "armed", "false", q{ pseudoClassStateChanged(pseudo!"armed", _armed); }));

protected:
    override bool takesChildren() const nothrow @nogc { return false; } // its parts are its own

    // As big as its text and no bigger, as a JavaFX Labeled is: see Widget.maxWidth
    override float computeMaxWidth() const nothrow @nogc { return usePrefSize; }
    override float computeMaxHeight() const nothrow @nogc { return usePrefSize; }

    /// Its text's label, for a subclass laying out its parts round it.
    final Label label() nothrow @nogc { return _label; }

    /// Puts `indicator` first, before any graphic and the text: a check box's box, a radio button's
    /// ring. JavaFX's skins draw those apart from the graphic, and so does this.
    final void setIndicator(Widget indicator)
    {
        if (_indicator)
            remove(_indicator);
        _indicator = indicator;
        if (indicator)
            adopt(indicator, 0);
    }

    /// Shows it pressed for a moment, and fires: what a shortcut or a screen reader pressing it does.
    final void flashAndFire()
    {
        _flash.playFromStart();
        fire();
    }

    override void handleMouse(ref MouseEvent event)
    {
        switch (event.type)
        {
            case MouseEventType.entered:
                if (pressed) // the press started here and the pointer has come back
                    arm(true);
                break;
            case MouseEventType.exited:
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

    override void describeAccessible(ref AccessibleNode node)
    {
        node.label(_label.text);
        node.addAction(AccessibleAction.fire);
    }

    /// A screen reader pressing it looks like a key pressing it: in and out, and fire.
    override bool executeAccessibleAction(AccessibleAction action, ref const AccessibleActionData data)
    {
        if (action != AccessibleAction.fire)
            return super.executeAccessibleAction(action, data);
        flashAndFire();
        return true;
    }

    override void focusChanged()
    {
        if (!focused)
            arm(false); // a Space held down when focus went elsewhere never gets its release
    }

    override void disabledChanged()
    {
        // A disabled control hears nothing, so it lets go of any press now rather than waiting for
        // events that won't come
        arm(false);
    }

    override void unmounted()
    {
        _flash.stop();
        _setArmed(false);
        pseudoClassStateChanged(pseudo!"armed", false);
    }

private:
    Label _label;
    Widget _indicator, _shownGraphic;
    void delegate() _onAction;
    Timeline _flash;

    void placeGraphic()
    {
        if (_shownGraphic)
            remove(_shownGraphic);
        _shownGraphic = _graphic;
        if (_graphic)
        {
            _graphic.setAccessibleHidden(true);
            adopt(_graphic, _indicator ? 1 : 0);
        }
        showLabel();
    }

    /// The label takes no room, and leaves no gap, when there's a graphic and no text.
    void showLabel() nothrow @nogc
    {
        YGNodeStyleSetDisplay(_label.node, _graphic && !_text.length ? YGDisplayNone : YGDisplayFlex);
    }

    void arm(bool armed)
    {
        if (armed != this.armed)
            _setArmed(armed);
    }

    /// Lets go, firing if it was still armed.
    void release()
    {
        const wasArmed = this.armed;
        arm(false);
        if (wasArmed)
            fire();
    }
}
