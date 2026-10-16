module mayfair.widgets.scrollpane;

import core.stdc.math : roundf;
import core.time : dur;
import mayfair.accessibility;
import mayfair.animation;
import mayfair.layout;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.theme;
import mayfair.widgets.input;
import mayfair.widgets.widget;

/// When a ScrollPane shows a bar. JavaFX's ScrollPane.ScrollBarPolicy, less ALWAYS: the bars are
/// GNOME's overlay ones, which are only there while they're wanted.
enum ScrollBarPolicy
{
    asNeeded, /// Whenever the content is bigger than the view that way. The default.
    never,    /// Not at all. It still scrolls, by the wheel, the keyboard and a screen reader.
}

/*
    Shows part of something bigger than itself, and scrolls to show the rest. JavaFX's ScrollPane.

        new ScrollPane(longList).fitToWidth(true).grow(1)

    The content is laid out at its own preferred size, however big, and the pane shows as much
    of it as fits. fitToWidth and fitToHeight make it the view's width or height instead, as far
    as its min and max let it: fitToWidth is what a list that only scrolls up and down wants.
    Where it's scrolled to is hvalue and vvalue, from 0 at the start to 1 at the end, as in JavaFX,
    so a pane scrolled to the bottom stays there as content is added.

    The bars are GNOME's rather than JavaFX's: thin, drawn over the content, and only there while
    something's happening. They fade in when the pane scrolls or the pointer moves over it, and
    out again a second after it stops. Over a bar the pointer widens it to take hold of: drag the
    thumb, or press beside it to jump there and carry on dragging.

    It scrolls by the wheel or a touchpad (see ScrollEvent) -- sideways with Shift, or by
    itself for a touchpad -- and by Page Up and Page Down from anything inside it that doesn't use
    them.

    Scrolling moves smoothly. A wheel's notch, or a page, is eased into rather than jumped to, and
    notches in quick succession add up to where it's heading. A touchpad follows the fingers
    exactly, and when they lift, carries on at the speed they were going and slows to a stop, as
    GNOME's does. Any scroll, or a press anywhere in the pane, takes over from a glide on its way.
    SDL doesn't say when fingers lift, so a moment with no movement is taken to mean they have:
    fingers resting on the pad start a glide, and moving again stops it at once. Tab moving focus to something out of view scrolls it into view. To a screen reader it's
    a scroll view, with its position and the actions to change it, and everything in it can be
    asked to scroll into view.

    Scrolling doesn't redraw the content. It's drawn once, in a layer of its own clipped to the
    pane (see Widget.clipChildren), and scrolling moves the layer.
*/
@DefaultProperty("content")
class ScrollPane : Widget
{
public:
    this(Widget content = null)
    {
        // The content goes in a view, which lays it out unconstrained across; the pane itself
        // does the same down. Flexbox's overflow: scroll frees only the main axis, so it takes two.
        _view = new View(this);
        _view.setAccessibleHidden(true); // layout's business: the content is the pane's, to a screen reader
        adopt(_view);
        YGNodeStyleSetOverflow(node, YGOverflowScroll);
        setAccessibleRole(AccessibleRole.scrollPane);
        styleClass.add("scroll-pane");

        _show = fade(Theme.scroll_bar_fade_time, (t) { _shownAmount = t; invalidate(); });
        _widen = fade(Theme.scroll_bar_widen_time, (t) { _wideAmount = t; invalidate(); });
        _linger = new Timeline(KeyFrame(Theme.scroll_bar_linger_time, { lingerOver(); }));
        _motion = new Motion(this);
        _lift = new Timeline(KeyFrame(Theme.scroll_lift_time, { glide(); }));
        // A press anywhere in it catches a glide, as a finger on a phone does -- whatever's pressed,
        // and whether or not it takes the press itself
        pressedProperty.addListener((bool was, bool now) { if (now) stopMotion(); });
        if (content)
            setContent(content);
    }

    /// The part of the content in view: where it starts, from the content's top left, and how
    /// big the view is -- as of the last layout, and where it's scrolled to since. JavaFX's viewportBounds.
    final Bounds viewportBounds() nothrow @nogc
    {
        return Bounds(scrollX, scrollY, _view_[0], _view_[1]);
    }

    /// What it shows and scrolls.
    mixin(declareProperty!(Widget, "content", "null", q{ _view.show(_content); }));

    /// How far it's scrolled across, from 0 at the left to 1 at the right. JavaFX's hvalue.
    mixin(declareProperty!(float, "hvalue", "0", q{ scrolled(); }));

    /// How far it's scrolled down, from 0 at the top to 1 at the bottom. JavaFX's vvalue.
    mixin(declareProperty!(float, "vvalue", "0", q{ scrolled(); }));

    /// Whether the content is made the view's width, rather than its own. JavaFX's fitToWidth.
    mixin(declareProperty!(bool, "fitToWidth", "false", q{ refit(); }));

    /// Whether the content is made the view's height, rather than its own. JavaFX's fitToHeight.
    mixin(declareProperty!(bool, "fitToHeight", "false", q{ refit(); }));

    /// When the bar along the bottom shows. JavaFX's hbarPolicy.
    mixin(declareProperty!(ScrollBarPolicy, "hbarPolicy", "ScrollBarPolicy.asNeeded", q{ invalidate(); }));

    /// When the bar down the side shows. JavaFX's vbarPolicy.
    mixin(declareProperty!(ScrollBarPolicy, "vbarPolicy", "ScrollBarPolicy.asNeeded", q{ invalidate(); }));

    /// The bars' thumbs' colour, and theirs under the pointer or held. Mayfair's own, as JavaFX's
    /// bars are widgets of their own with backgrounds, where these are the pane's.
    mixin(declareStyleableProperty!(Colour, "thumbColour", "thumb-colour", "Colour(128, 128, 128, 128)", q{ invalidate(); }));
    mixin(declareStyleableProperty!(Colour, "thumbHoverColour", "thumb-hover-colour", "Colour(128, 128, 128, 200)", q{ invalidate(); })); /// ditto

protected:
    // Its view, and nothing else: content goes in `content`
    override bool takesChildren() const nothrow @nogc { return false; }

    override void mounted() nothrow
    {
        clipChildren();
        // Added after the content's layer, so they're drawn over it
        _bars[Axis.horizontal] = addPaint();
        _bars[Axis.vertical] = addPaint();
    }

    override void unmounted()
    {
        _dragging = _overBar = Axis.none;
        _barsUp = false;
        stopMotion();
        _linger.stop();
        _show.stop();
        _widen.stop();
        _shownAmount = _wideAmount = 0;
    }

    override void placeChild(Widget child) nothrow @nogc
    {
        // The view: as tall as the pane when fitting the content to it, and otherwise as the content
        child.place(fits(Axis.vertical) ? 1 : 0, false, false, YGAlignStretch);
        fromOwnSize(child, fits(Axis.vertical));
    }

    /*
        Works out how far it can scroll, now the content's been laid out, and moves the content's
        layer to where it's scrolled to. The values are fractions, so a change in the content's size
        moves what's shown with it, as JavaFX's do: at the bottom, it stays at the bottom.
    */
    override void laidOut(float x, float y, float w, float h) nothrow @nogc
    {
        const view = viewport(x, y, w, h);
        const maxX = snap(max0(extent(Axis.horizontal) - view.width));
        const maxY = snap(max0(extent(Axis.vertical) - view.height));
        const offX = snap(clamp01(_hvalue) * maxX);
        const offY = snap(clamp01(_vvalue) * maxY);
        if (maxX != _max[0] || maxY != _max[1] || offX != _offset[0] || offY != _offset[1]
            || view.width != _view_[0] || view.height != _view_[1])
        {
            _max = [maxX, maxY];
            _offset = [offX, offY];
            _view_ = [view.width, view.height];
            invalidate(); // the bars
            invalidateAccessible(); // how far it scrolls
        }
        scrollChildren(offX, offY);
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        const view = viewport(x, y, w, h);
        foreach (axis; [Axis.horizontal, Axis.vertical])
        {
            auto bar = _bars[axis];
            tvg_shape_reset(bar);
            if (!hasBar(axis) || _shownAmount <= 0)
                continue;
            const r = thumb(axis, view);
            const radius = (axis == Axis.vertical ? r.width : r.height) / 2;
            tvg_shape_append_rect(bar, r.minX, r.minY, r.width, r.height, radius, radius, true);
            const held = axis == _overBar || axis == _dragging;
            tvg_shape_set_fill_color(bar, (held ? _thumbHoverColour : _thumbColour).tupleof);
            tvg_paint_set_opacity(bar, cast(ubyte)(255 * _shownAmount * effectiveOpacity));
        }
    }

    // The pointer takes hold of a bar anywhere near the edge it runs along, while it's showing
    override bool claimsPoint(float x, float y) nothrow @nogc
    {
        return barAt(x, y) != Axis.none;
    }

    override void handleMouse(ref MouseEvent event)
    {
        switch (event.type)
        {
            case MouseEventType.entered:
                showBars();
                break;
            case MouseEventType.moved:
                // From anywhere over the pane, content included, unless the content used it
                showBars();
                overBar(barAt(event.sceneX, event.sceneY));
                break;
            case MouseEventType.exited:
                overBar(Axis.none);
                break;
            case MouseEventType.pressed:
                if (event.button != MouseButton.primary)
                    break;
                const axis = barAt(event.sceneX, event.sceneY);
                if (axis == Axis.none)
                    break;
                // On the thumb it's held where it was taken; beside it, it jumps to put its middle
                // under the pointer, as GNOME's does, and is held there
                const t = thumb(axis, screenViewport());
                const p = along(axis, event.sceneX, event.sceneY);
                const start = axis == Axis.vertical ? t.minY : t.minX;
                const length = axis == Axis.vertical ? t.height : t.width;
                _grab = p >= start && p < start + length ? p - start : length / 2;
                _dragging = axis;
                dragTo(p);
                event.consume();
                break;
            case MouseEventType.dragged:
                if (_dragging == Axis.none)
                    break;
                dragTo(along(_dragging, event.sceneX, event.sceneY));
                event.consume();
                break;
            case MouseEventType.released:
                if (_dragging == Axis.none || event.button != MouseButton.primary)
                    break;
                _dragging = Axis.none;
                overBar(barAt(event.sceneX, event.sceneY));
                if (_overBar == Axis.none)
                    _widen.playReverse();
                _linger.playFromStart();
                invalidate();
                event.consume();
                break;
            default:
                break;
        }
    }

    override void handleScroll(ref ScrollEvent event)
    {
        // Only what it can scroll: a pane that only scrolls down leaves sideways to what's around it
        const dx = _max[0] > 0 ? -event.deltaX : 0, dy = _max[1] > 0 ? -event.deltaY : 0;
        if (dx == 0 && dy == 0)
            return;
        if (event.device == ScrollDevice.touchpad)
            follow(event.time, dx, dy);
        else
            easeBy(dx, dy);
        showBars();
        event.consume();
    }

    override void handleKey(ref KeyEvent event)
    {
        if (event.type != KeyEventType.pressed || _max[1] <= 0)
            return;
        if (event.code == KeyCode.pageDown)
            easeBy(0, page(_view_[1]));
        else if (event.code == KeyCode.pageUp)
            easeBy(0, -page(_view_[1]));
        else
            return;
        showBars();
        event.consume();
    }

    override void reveal(Bounds rect)
    {
        stopMotion(); // focus going somewhere, or a screen reader: straight there
        // `rect` is from the pane's top left, and the content starts inside its padding
        const left = rect.minX - YGNodeLayoutGetPadding(node, YGEdgeLeft);
        const top = rect.minY - YGNodeLayoutGetPadding(node, YGEdgeTop);
        scrollTo(bringIn(scrollX, left, rect.width, _view_[0]), bringIn(scrollY, top, rect.height, _view_[1]));
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        node.scroll(_offset[0], _max[0], _offset[1], _max[1]);
        if (_max[1] > 0)
        {
            node.addAction(AccessibleAction.scrollUp);
            node.addAction(AccessibleAction.scrollDown);
        }
        if (_max[0] > 0)
        {
            node.addAction(AccessibleAction.scrollLeft);
            node.addAction(AccessibleAction.scrollRight);
        }
        if (_max[0] > 0 || _max[1] > 0)
            node.addAction(AccessibleAction.setScrollOffset);
    }

    override bool executeAccessibleAction(AccessibleAction action, ref const AccessibleActionData data)
    {
        stopMotion();
        const stepX = data.page ? page(_view_[0]) : Theme.scroll_step;
        const stepY = data.page ? page(_view_[1]) : Theme.scroll_step;
        switch (action)
        {
            case AccessibleAction.scrollUp:        scrollTo(scrollX, scrollY - stepY); return true;
            case AccessibleAction.scrollDown:      scrollTo(scrollX, scrollY + stepY); return true;
            case AccessibleAction.scrollLeft:      scrollTo(scrollX - stepX, scrollY); return true;
            case AccessibleAction.scrollRight:     scrollTo(scrollX + stepX, scrollY); return true;
            case AccessibleAction.setScrollOffset: scrollTo(data.scrollX, data.scrollY); return true;
            default:                               return super.executeAccessibleAction(action, data);
        }
    }

private:
    enum Axis { horizontal, vertical, none }

    View _view;
    Tvg_Paint[2] _bars;
    // As of the last layout, in points: how far it can scroll, how far it has, and the view's size
    float[2] _max = [0, 0], _offset = [0, 0], _view_ = [0, 0];

    Transition _show, _widen; // the bars fading in and out, and the one under the pointer widening
    Timeline _linger;         // how long they stay after the last thing happened
    double _shownAmount = 0, _wideAmount = 0;
    bool _barsUp;             // whether they're showing, or on their way
    Axis _overBar = Axis.none, _wideBar = Axis.none, _dragging = Axis.none;
    float _grab = 0;          // where along the thumb it's held, while dragging

    // Where it's scrolled to in points, from the values, which are ahead of the last layout
    float scrollX() nothrow @nogc { return clamp01(_hvalue) * _max[0]; }
    float scrollY() nothrow @nogc { return clamp01(_vvalue) * _max[1]; }

    /*
        Smooth scrolling and momentum. One animation steps both, every frame while either's on
        its way: easing towards `_target`, for a wheel or a page, or gliding at `_velocity`, which
        dies away, after a touchpad's fingers lift. The touchpad's last few movements, with when
        they came, are kept to work out how fast the fingers were going.
    */
    Motion _motion;
    Timeline _lift;           // runs out when a touchpad's been still long enough to have been let go
    bool _easing, _gliding;
    float[2] _target = [0, 0], _velocity = [0, 0];
    struct Sample { double time; float dx, dy; }
    Sample[8] _samples;
    size_t _sampleCount;

    static final class Motion : Animation
    {
        ScrollPane pane;
        this(ScrollPane pane)
        {
            this.pane = pane;
            cycleDuration(dur!"seconds"(1));
            cycleCount(indefinite);
        }

    protected:
        override void step(double fraction) {}

        override void moved(double from, double to, bool fresh)
        {
            pane.step(to - from);
        }
    }

    /// A wheel's notch or a page: eased into, from where it's heading if it's on its way.
    void easeBy(float dx, float dy)
    {
        if (!_easing)
            _target = [scrollX, scrollY];
        stopGlide();
        _target[0] = clampTo(_target[0] + dx, _max[0]);
        _target[1] = clampTo(_target[1] + dy, _max[1]);
        _easing = true;
        startMotion();
    }

    /// A touchpad: straight there, remembering how fast, in case the fingers lift.
    void follow(double time, float dx, float dy)
    {
        _easing = _gliding = false;
        scrollTo(scrollX + dx, scrollY + dy);
        if (_sampleCount == _samples.length)
        {
            foreach (i; 1 .. _samples.length)
                _samples[i - 1] = _samples[i];
            _sampleCount--;
        }
        _samples[_sampleCount++] = Sample(time, dx, dy);
        _lift.playFromStart();
    }

    /// The fingers lifted: carry on at the speed they were going over the last tenth of a second.
    void glide()
    {
        import std.math : sqrt;
        if (_sampleCount < 2)
            return;
        const last = _samples[_sampleCount - 1].time;
        size_t first = _sampleCount - 1;
        while (first > 0 && last - _samples[first - 1].time <= 0.1)
            first--;
        const span = last - _samples[first].time;
        float x = 0, y = 0;
        foreach (ref sample; _samples[first + 1 .. _sampleCount]) // each came at the end of its interval
        {
            x += sample.dx;
            y += sample.dy;
        }
        _sampleCount = 0;
        if (span <= 0)
            return;
        float vx = x / span, vy = y / span;
        const speed = sqrt(vx * vx + vy * vy);
        if (speed < Theme.scroll_glide_min_speed)
            return;
        if (speed > Theme.scroll_glide_max_speed)
        {
            vx *= Theme.scroll_glide_max_speed / speed;
            vy *= Theme.scroll_glide_max_speed / speed;
        }
        _velocity = [vx, vy];
        _gliding = true;
        startMotion();
    }

    void step(double dt)
    {
        import std.math : abs, exp, sqrt;
        float x = scrollX, y = scrollY;
        if (_easing)
        {
            const k = cast(float)(1 - exp(-dt / Theme.scroll_ease_time));
            x += (_target[0] - x) * k;
            y += (_target[1] - y) * k;
            if (abs(_target[0] - x) < 0.25f && abs(_target[1] - y) < 0.25f)
            {
                x = _target[0];
                y = _target[1];
                _easing = false;
            }
        }
        else if (_gliding)
        {
            x += _velocity[0] * dt;
            y += _velocity[1] * dt;
            const decay = cast(float) exp(-dt / Theme.scroll_glide_time);
            _velocity[0] *= decay;
            _velocity[1] *= decay;
            // Stopped by the end it runs into
            if (x <= 0 || x >= _max[0]) _velocity[0] = 0;
            if (y <= 0 || y >= _max[1]) _velocity[1] = 0;
            if (sqrt(_velocity[0] * _velocity[0] + _velocity[1] * _velocity[1]) < 10)
                _gliding = false;
        }
        scrollTo(x, y);
        if (_easing || _gliding)
            showBars();
        else
            _motion.stop();
    }

    void startMotion()
    {
        if (_motion.status != Status.running)
            _motion.play();
    }

    void stopGlide() nothrow @nogc
    {
        _gliding = false;
        _sampleCount = 0;
        _lift.stop();
    }

    /// Wherever it is now, it stays: something else is moving it.
    void stopMotion() nothrow @nogc
    {
        _easing = false;
        stopGlide();
        _motion.stop();
    }

    static float clampTo(float v, float max) nothrow @nogc
    {
        return v < 0 ? 0 : v > max ? max : v;
    }

    /// Scrolls to `x`, `y` points from the content's top left, as far as it goes.
    void scrollTo(float x, float y)
    {
        setHvalue(_max[0] > 0 ? clamp01(x / _max[0]) : 0);
        setVvalue(_max[1] > 0 ? clamp01(y / _max[1]) : 0);
    }

    void scrolled() nothrow @nogc
    {
        invalidate(); // laidOut() moves the content on the next paint
    }

    void refit() nothrow @nogc
    {
        placeChild(_view);
        _view.placeContent();
    }

    bool fits(Axis axis) nothrow @nogc
    {
        if (!_content)
            return false;
        return axis == Axis.vertical ? _fitToHeight && !_content.heightHeldToPref
                                     : _fitToWidth && !_content.widthHeldToPref;
    }

    /// How big the content is, with its margins, along `axis`: at least the view, which it fills
    /// when it's smaller.
    float extent(Axis axis) nothrow @nogc
    {
        const across = axis == Axis.horizontal;
        float size = across ? YGNodeLayoutGetWidth(_view.node) : YGNodeLayoutGetHeight(_view.node);
        if (_content)
        {
            auto n = _content.node;
            const own = across ? YGNodeLayoutGetWidth(n) + YGNodeLayoutGetMargin(n, YGEdgeLeft) + YGNodeLayoutGetMargin(n, YGEdgeRight)
                               : YGNodeLayoutGetHeight(n) + YGNodeLayoutGetMargin(n, YGEdgeTop) + YGNodeLayoutGetMargin(n, YGEdgeBottom);
            if (own > size)
                size = own;
        }
        return size;
    }

    /// The part of the pane the content shows through: inside its padding.
    Bounds viewport(float x, float y, float w, float h) nothrow @nogc
    {
        const l = YGNodeLayoutGetPadding(node, YGEdgeLeft), t = YGNodeLayoutGetPadding(node, YGEdgeTop);
        return Bounds(x + l, y + t, w - l - YGNodeLayoutGetPadding(node, YGEdgeRight),
                      h - t - YGNodeLayoutGetPadding(node, YGEdgeBottom));
    }

    /// The same, where it's seen in the window, for the pointer.
    Bounds screenViewport() nothrow @nogc
    {
        const b = boundsInScene;
        return viewport(b.minX, b.minY, b.width, b.height);
    }

    bool hasBar(Axis axis) nothrow @nogc
    {
        const policy = axis == Axis.vertical ? _vbarPolicy : _hbarPolicy;
        return policy == ScrollBarPolicy.asNeeded && _max[axis] > 0;
    }

    /*
        Where a bar's thumb is, in the coordinates `view` is in. It runs along the far edge of the
        view, a margin in from it, stopping short of the corner when both bars are there. Its length
        is the fraction of the content that shows, but never too short to take hold of.
    */
    Bounds thumb(Axis axis, Bounds view) nothrow @nogc
    {
        const vertical = axis == Axis.vertical;
        const m = Theme.scroll_bar_margin;
        const corner = hasBar(vertical ? Axis.horizontal : Axis.vertical) ? Theme.scroll_bar_wide + m : 0;
        const trackStart = (vertical ? view.minY : view.minX) + m;
        const trackLength = max0((vertical ? view.height : view.width) - 2 * m - corner);
        const shown = _view_[axis];
        float length = trackLength * shown / (shown + _max[axis]);
        if (length < Theme.scroll_bar_min_length)
            length = Theme.scroll_bar_min_length;
        if (length > trackLength)
            length = trackLength;
        const position = trackStart + (_max[axis] > 0 ? (trackLength - length) * _offset[axis] / _max[axis] : 0);
        const wide = axis == _wideBar ? _wideAmount : 0;
        const thickness = Theme.scroll_bar_thin + (Theme.scroll_bar_wide - Theme.scroll_bar_thin) * wide;
        return vertical ? Bounds(view.maxX - m - thickness, position, thickness, length)
                        : Bounds(position, view.maxY - m - thickness, length, thickness);
    }

    /// Which bar the pointer at `x`, `y` in the window would take hold of, if either.
    Axis barAt(float x, float y) nothrow @nogc
    {
        if (!_barsUp)
            return Axis.none;
        const view = screenViewport();
        if (!view.contains(x, y))
            return Axis.none;
        if (hasBar(Axis.vertical) && x >= view.maxX - Theme.scroll_bar_reach)
            return Axis.vertical;
        if (hasBar(Axis.horizontal) && y >= view.maxY - Theme.scroll_bar_reach)
            return Axis.horizontal;
        return Axis.none;
    }

    static float along(Axis axis, float x, float y) nothrow @nogc
    {
        return axis == Axis.vertical ? y : x;
    }

    /// Scrolls so the thumb being dragged is held at `p`, along the bar in the window.
    void dragTo(float p)
    {
        const vertical = _dragging == Axis.vertical;
        const view = screenViewport();
        const t = thumb(_dragging, view);
        const trackStart = (vertical ? view.minY : view.minX) + Theme.scroll_bar_margin;
        const corner = hasBar(vertical ? Axis.horizontal : Axis.vertical) ? Theme.scroll_bar_wide + Theme.scroll_bar_margin : 0;
        const room = (vertical ? view.height : view.width) - 2 * Theme.scroll_bar_margin - corner
                   - (vertical ? t.height : t.width);
        if (room <= 0)
            return;
        const fraction = clamp01((p - _grab - trackStart) / room);
        if (vertical)
            setVvalue(fraction);
        else
            setHvalue(fraction);
        _linger.playFromStart();
    }

    void showBars()
    {
        if (!hasBar(Axis.horizontal) && !hasBar(Axis.vertical))
            return;
        if (!_barsUp)
        {
            _barsUp = true;
            _show.playForward();
        }
        _linger.playFromStart();
    }

    // A second after the last scroll or movement: they go, unless they're held or under the pointer
    void lingerOver()
    {
        if (_dragging != Axis.none || _overBar != Axis.none)
            return; // letting go, or moving off, starts the wait again
        _barsUp = false;
        _show.playReverse();
    }

    void overBar(Axis axis)
    {
        if (axis == _overBar)
            return;
        _overBar = axis;
        if (axis != Axis.none)
        {
            _wideBar = axis;
            _widen.playForward();
        }
        else if (_dragging == Axis.none)
        {
            _widen.playReverse();
            _linger.playFromStart();
        }
        invalidate();
    }

    /// A page's worth of scrolling: most of the view, so a line of what was showing still is.
    static float page(float view) nothrow @nogc { return view * 0.9f; }

    /// Where to scroll to along one axis, from `at`, to bring `start` .. `start + size` into a view
    /// `view` long: as little as will do it, and to its start if it can't all fit.
    static float bringIn(float at, float start, float size, float view) nothrow @nogc
    {
        if (start < at || size > view)
            return start;
        if (start + size > at + view)
            return start + size - view;
        return at;
    }

    /// `points` on the pixel grid, where Yoga puts everything else, so text scrolled stays sharp.
    float snap(float points) nothrow @nogc
    {
        const s = scene ? scene.scale : 1;
        return roundf(points * s) / s;
    }

    static float clamp01(float v) nothrow @nogc { return v < 0 ? 0 : v > 1 ? 1 : v == v ? v : 0; }
    static float max0(float v) nothrow @nogc { return v > 0 ? v : 0; }

    static Transition fade(Duration duration, void delegate(double) action)
    {
        return new Transition(duration, action).interpolator(Interpolator.easeOut);
    }
}

private:

import core.time : Duration;

/*
    What the content sits in: a row, which with overflow: scroll lets it be as wide as it likes,
    where the pane around it -- a column, likewise -- lets it be as tall. Nothing a user of the
    pane sees, as JavaFX's ScrollPane skin has a node of its own between the pane and the content.
*/
final class View : Widget
{
    ScrollPane pane;

    this(ScrollPane pane) nothrow @nogc
    {
        this.pane = pane;
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionRow);
        YGNodeStyleSetOverflow(node, YGOverflowScroll);
    }

    void show(Widget content)
    {
        foreach_reverse (child; children)
            remove(child);
        if (content)
            adopt(content);
    }

    override bool takesChildren() const nothrow @nogc { return false; }

    void placeContent() nothrow @nogc
    {
        foreach (child; children)
            placeChild(child);
    }

protected:
    // At its own size, unless the pane fits it to the view: then as wide, by growing along the
    // row, or as tall, by stretching across it
    override void placeChild(Widget child) nothrow @nogc
    {
        const fitH = pane.fits(ScrollPane.Axis.vertical);
        child.place(pane.fits(ScrollPane.Axis.horizontal) ? 1 : 0, false, fitH,
                    fitH ? YGAlignStretch : YGAlignFlexStart);
        fromOwnSize(child, pane.fits(ScrollPane.Axis.horizontal));
    }
}

/*
    Fitted to the view along a flex line, the content grows and shrinks to it -- but from its own
    size, not from nothing, as a growing child would by default. It's the same size in the view
    either way; what differs is how big the pane is asked to be: as big as its content along the
    axis it fits it on, as JavaFX's is, so a pane that only scrolls down is as wide as what's in
    it, and one that only scrolls across as tall.
*/
private void fromOwnSize(Widget child, bool fitted) nothrow @nogc
{
    if (!fitted)
        return;
    YGNodeStyleSetFlexBasisAuto(child.node);
    YGNodeStyleSetFlexShrink(child.node, 1);
}
