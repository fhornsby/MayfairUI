module mayfair.widgets.slider;

import mayfair.accessibility;
import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.input;
import mayfair.widgets.styling;
import mayfair.widgets.widget;

/// Which way something runs. JavaFX's Orientation.
enum Orientation { horizontal, vertical }

/*
    A value picked by dragging a thumb along a track: JavaFX's Slider.

        auto volume = new Slider(0, 100, 50);
        volume.valueProperty.addListener((double was, double now) { ... });

    Dragging the thumb moves the value with it; pressing on the track jumps the thumb there, as
    JavaFX's does, and dragging on carries it. The arrow keys move it by blockIncrement, Home and
    End to either end. With snapToTicks, it settles on the nearest tick -- every majorTickUnit,
    divided by minorTickCount -- when it's let go of, or moved by a key.

    Its style class is "slider", with :horizontal or :vertical, and it's made of parts for a
    stylesheet: `.track`, along its length; `.fill`, the track up to the thumb -- Mayfair's, where
    JavaFX's has none -- and `.thumb`. A vertical slider's minimum is at the bottom.

    To a screen reader it's a slider with its value and range, which can be moved a step at a
    time or set.
*/
class Slider : Widget
{
public:
    this(double min = 0, double max = 100, double value = 0)
    {
        _min = min;
        _max = max;
        _value = value;
        styleClass.add("slider");
        setAccessibleRole(AccessibleRole.slider);
        setFocusTraversable(true);

        _track = part("track");
        _fill = part("fill");
        _thumb = part("thumb");
        // The track and fill lie behind the thumb, outside the flow; the thumb is in it, so the
        // slider's as thick as it is
        YGNodeStyleSetPositionType(_track.node, YGPositionTypeAbsolute);
        YGNodeStyleSetPositionType(_fill.node, YGPositionTypeAbsolute);
        YGNodeStyleSetAlignItems(node, YGAlignCenter);
        // Where the thumb goes depends on its size, which comes from the stylesheet
        _thumb.prefWidthProperty.addListener((float was, float now) { arrange(); });
        _thumb.prefHeightProperty.addListener((float was, float now) { arrange(); });
        orientationChanged();
    }

    mixin(declareProperty!(double, "min", "0", q{ changed(); }));     /// The least it can be
    mixin(declareProperty!(double, "max", "100", q{ changed(); }));   /// The most it can be

    /// The value, between min and max.
    mixin(declareProperty!(double, "value", "0", q{ changed(); }));

    /// Which way it runs.
    mixin(declareProperty!(Orientation, "orientation", "Orientation.horizontal", q{ orientationChanged(); }));

    /// How far the arrow keys move it.
    mixin(declareProperty!(double, "blockIncrement", "10"));

    /// The ticks it snaps to: one every majorTickUnit, and minorTickCount more between each.
    mixin(declareProperty!(double, "majorTickUnit", "25"));
    mixin(declareProperty!(int, "minorTickCount", "3")); /// ditto

    /// Whether it settles on the nearest tick when it's let go of, or moved by a key.
    mixin(declareProperty!(bool, "snapToTicks", "false"));

    /// Whether it's being dragged: the value is on its way, not settled. JavaFX's valueChanging.
    mixin(declareReadOnlyProperty!(bool, "valueChanging", "false", q{ pseudoClassStateChanged(pseudo!"value-changing", _valueChanging); }));

    /// Moves it up by blockIncrement, or down, as far as it goes.
    void increment() { settle(_value + _blockIncrement); }
    void decrement() { settle(_value - _blockIncrement); } /// ditto

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    // Only as thick as its thumb, and as long as it's given
    override float computeMaxHeight() const nothrow @nogc
    {
        return _orientation == Orientation.horizontal ? usePrefSize : float.infinity;
    }

    override float computeMaxWidth() const nothrow @nogc
    {
        return _orientation == Orientation.vertical ? usePrefSize : float.infinity;
    }

    override void handleMouse(ref MouseEvent event)
    {
        const b = boundsInScene;
        const along = horizontal ? event.sceneX - b.minX : event.sceneY - b.minY;
        switch (event.type)
        {
            case MouseEventType.pressed:
                if (event.button != MouseButton.primary)
                    break;
                requestFocus();
                // On the thumb it's held where it was taken; on the track, it jumps to put its
                // middle under the pointer, and is held there
                const t = _thumb.boundsInScene;
                const start = horizontal ? t.minX - b.minX : t.minY - b.minY;
                const size = thumbLength;
                _grab = along >= start && along < start + size ? along - start : size / 2;
                _setValueChanging(true);
                dragTo(along);
                event.consume();
                break;
            case MouseEventType.dragged:
                if (!valueChanging)
                    break;
                dragTo(along);
                event.consume();
                break;
            case MouseEventType.released:
                if (!valueChanging || event.button != MouseButton.primary)
                    break;
                _setValueChanging(false);
                settle(_value);
                event.consume();
                break;
            default:
                break;
        }
    }

    override void handleKey(ref KeyEvent event)
    {
        if (event.type != KeyEventType.pressed)
            return;
        switch (event.code)
        {
            case KeyCode.right, KeyCode.up: increment(); break;
            case KeyCode.left, KeyCode.down: decrement(); break;
            case KeyCode.home: settle(_min); break;
            case KeyCode.end: settle(_max); break;
            default: return;
        }
        event.consume();
    }

    override void unmounted()
    {
        _setValueChanging(false);
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        node.numeric(_value, _min, _max, _blockIncrement);
        node.addAction(AccessibleAction.increment);
        node.addAction(AccessibleAction.decrement);
        node.addAction(AccessibleAction.setValue);
    }

    override bool executeAccessibleAction(AccessibleAction action, ref const AccessibleActionData data)
    {
        switch (action)
        {
            case AccessibleAction.increment: increment(); return true;
            case AccessibleAction.decrement: decrement(); return true;
            case AccessibleAction.setValue:
                double v = data.number;
                if (v != v)
                {
                    import std.conv : to, ConvException;
                    try
                        v = data.value.to!double;
                    catch (ConvException)
                        return false;
                }
                settle(v);
                return true;
            default:
                return super.executeAccessibleAction(action, data);
        }
    }

private:
    Widget _track, _fill, _thumb;
    float _grab = 0; // where along the thumb it's held, while dragging

    bool horizontal() const nothrow @nogc { return _orientation == Orientation.horizontal; }

    Widget part(string name)
    {
        auto w = new Widget().styleClass(name).accessibleHidden(true);
        adopt(w);
        return w;
    }

    // How far along the range the value is, from 0 to 1
    double fraction() const nothrow @nogc
    {
        if (_max <= _min)
            return 0;
        const f = (_value - _min) / (_max - _min);
        return f < 0 ? 0 : f > 1 ? 1 : f;
    }

    // The thumb's size along the slider, as the stylesheet sets it, or as it was laid out
    float thumbLength() nothrow
    {
        const set = horizontal ? _thumb.prefWidth : _thumb.prefHeight;
        if (set == set)
            return set;
        const b = _thumb.boundsInScene;
        return horizontal ? b.width : b.height;
    }

    /// Where the pointer, `along` the slider, puts the value, with the thumb held `_grab` in.
    void dragTo(float along)
    {
        const b = boundsInScene;
        const room = (horizontal ? b.width : b.height) - thumbLength;
        if (room <= 0)
            return;
        double f = (along - _grab) / room;
        if (!horizontal)
            f = 1 - f; // the minimum's at the bottom
        f = f < 0 ? 0 : f > 1 ? 1 : f;
        setValue(_min + f * (_max - _min));
    }

    /// Sets the value to `v`, within the range, and on a tick if it snaps to them.
    void settle(double v)
    {
        if (_snapToTicks && _majorTickUnit > 0)
        {
            import std.math : round;
            const tick = _majorTickUnit / (_minorTickCount + 1);
            v = _min + round((v - _min) / tick) * tick;
        }
        setValue(v < _min ? _min : v > _max ? _max : v);
    }

    void changed()
    {
        arrange();
        invalidateAccessible();
    }

    void orientationChanged()
    {
        YGNodeStyleSetFlexDirection(node, horizontal ? YGFlexDirectionRow : YGFlexDirectionColumn);
        pseudoClassStateChanged(pseudo!"horizontal", horizontal);
        pseudoClassStateChanged(pseudo!"vertical", !horizontal);
        maxChanged();
        arrange();
    }

    /*
        Puts the thumb and the fill where the value says, in percentages of the slider's length so
        the layout keeps them there whatever size it's given, less a correction in points for the
        thumb's own size: its middle travels from half its size in at one end to half its size in
        at the other.
    */
    void arrange() nothrow
    {
        const f = fraction;
        const t = thumbLength;
        foreach (w; [_track, _fill, _thumb])
            foreach (edge; [YGEdgeLeft, YGEdgeRight, YGEdgeTop, YGEdgeBottom])
            {
                YGNodeStyleSetPosition(w.node, edge, float.nan);
                YGNodeStyleSetMargin(w.node, edge, 0);
            }
        if (horizontal)
        {
            YGNodeStyleSetPosition(_track.node, YGEdgeLeft, 0);
            YGNodeStyleSetPosition(_track.node, YGEdgeRight, 0);
            YGNodeStyleSetPosition(_fill.node, YGEdgeLeft, 0);
            YGNodeStyleSetPositionPercent(_fill.node, YGEdgeRight, (1 - f) * 100);
            YGNodeStyleSetMargin(_fill.node, YGEdgeRight, (f - 0.5) * t);
            YGNodeStyleSetPositionPercent(_thumb.node, YGEdgeLeft, f * 100);
            YGNodeStyleSetMargin(_thumb.node, YGEdgeLeft, -f * t);
        }
        else
        {
            YGNodeStyleSetPosition(_track.node, YGEdgeTop, 0);
            YGNodeStyleSetPosition(_track.node, YGEdgeBottom, 0);
            YGNodeStyleSetPosition(_fill.node, YGEdgeBottom, 0);
            YGNodeStyleSetPositionPercent(_fill.node, YGEdgeTop, (1 - f) * 100);
            YGNodeStyleSetMargin(_fill.node, YGEdgeTop, (f - 0.5) * t);
            YGNodeStyleSetPositionPercent(_thumb.node, YGEdgeTop, (1 - f) * 100);
            YGNodeStyleSetMargin(_thumb.node, YGEdgeTop, -(1 - f) * t);
        }
        invalidate();
    }
}
