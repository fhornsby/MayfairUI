module mayfair.widgets.progressbar;

import core.time : msecs;
import mayfair.accessibility;
import mayfair.animation;
import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.styling;
import mayfair.widgets.widget;

/*
    How far something has got: a bar filling along a track. JavaFX's ProgressBar.

        auto download = new ProgressBar(0);
        download.setProgress(received / total);

    Progress is from 0 to 1, or indeterminate -- ProgressBar.indeterminateProgress, -1, as JavaFX's
    is -- for work whose end isn't known yet, when a short bar slides to and fro instead. That's
    also what one made with no progress shows, as JavaFX's does.

    Its style class is "progress-bar", with :indeterminate or :determinate, and it's made of a
    `.track` and the `.bar` along it.
*/
class ProgressBar : Widget
{
public:
    enum double indeterminateProgress = -1; /// JavaFX's ProgressIndicator.INDETERMINATE_PROGRESS

    this(double progress = indeterminateProgress)
    {
        _progress = progress;
        styleClass.add("progress-bar");
        setAccessibleRole(AccessibleRole.progressIndicator);
        _track = new Widget().styleClass("track").accessibleHidden(true);
        _bar = new Widget().styleClass("bar").accessibleHidden(true);
        adopt(_track);
        adopt(_bar);
        // The track fills it; the bar lies over the track, as tall as it
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionRow);
        _track.setGrow(1);
        YGNodeStyleSetPositionType(_bar.node, YGPositionTypeAbsolute);
        YGNodeStyleSetPosition(_bar.node, YGEdgeTop, 0);
        YGNodeStyleSetPosition(_bar.node, YGEdgeBottom, 0);
        // Indeterminate: a quarter of the track, easing from one end to the other and back
        _slide = new Transition(1000.msecs, (t) {
            YGNodeStyleSetPositionPercent(_bar.node, YGEdgeLeft, t * (100 - slideWidth));
        });
        _slide.cycleCount(Animation.indefinite).autoReverse(true);
        progressChanged();
    }

    /// How far it's got, from 0 to 1, or indeterminateProgress.
    mixin(declareProperty!(double, "progress", "indeterminateProgress", q{ progressChanged(); }));

    /// Whether it doesn't know how far it's got.
    bool indeterminate() const nothrow @nogc { return _progress < 0; }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }
    override float computeMaxHeight() const nothrow @nogc { return usePrefSize; }

    override void mounted() nothrow
    {
        if (indeterminate)
            playSlide();
    }

    override void unmounted()
    {
        _slide.stop();
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        if (!indeterminate)
            node.numeric(_progress > 1 ? 1 : _progress, 0, 1);
    }

private:
    enum slideWidth = 25; // percent of the track, while indeterminate
    Widget _track, _bar;
    Transition _slide;

    void progressChanged()
    {
        pseudoClassStateChanged(pseudo!"indeterminate", indeterminate);
        pseudoClassStateChanged(pseudo!"determinate", !indeterminate);
        if (indeterminate)
        {
            YGNodeStyleSetWidthPercent(_bar.node, slideWidth);
            if (scene)
                playSlide();
        }
        else
        {
            _slide.stop();
            const p = _progress > 1 ? 1 : _progress;
            YGNodeStyleSetPosition(_bar.node, YGEdgeLeft, 0);
            YGNodeStyleSetWidthPercent(_bar.node, p * 100);
        }
        invalidate();
        invalidateAccessible();
    }

    void playSlide() nothrow
    {
        try
            _slide.play();
        catch (Exception) {}
    }
}
