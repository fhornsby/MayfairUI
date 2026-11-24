module mayfair.media.view;

import mayfair.accessibility;
import mayfair.layout;
import mayfair.media.backend;
import mayfair.media.player;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.widgets.widget;

/*
    Shows a MediaPlayer's video: JavaFX's MediaView. It's a widget like any other, so the video is
    laid out, clipped by what holds it, faded, moved and drawn over -- by controls laid on top,
    or a menu -- with everything round it, in the window's own drawing.

        auto view = new MediaView(player).scaling(VideoScaling.fit);
        view.onMouseClicked((ref e) { player.status == MediaStatus.playing ? player.pause() : player.play(); });

    The video keeps its shape, filling as much of the view as it can and centred (`fit`, the
    default), or filling all of it and cut off at the edges (`cover`, for a tile in a grid or a
    feed), or stretched to it (`stretch`). Its natural size, until layout says otherwise, is the
    video's, a point a pixel.

    The view only shows the player: taking it out of the window, moving it to another, or giving
    it another player leaves the player playing, and disposing of the player is the app's to do.
    While it's in a window it shows each frame the player decodes, as an image -- a copy of it,
    made on the UI thread, which a GPU texture shared with the backend could one day save. Put
    back, it shows the player's current frame at once.

    Its style class is "media-view"; what's round the video, when it doesn't fill the view, is its
    background. To a screen reader it's an image, named by its accessibleText.
*/
class MediaView : Widget
{
public:
    this(MediaPlayer player = null)
    {
        styleClass.add("media-view");
        setAccessibleRole(AccessibleRole.image);
        YGNodeSetContext(node, cast(void*) this);
        YGNodeSetMeasureFunc(node, &measureMediaView);
        watcher = new Watcher(this);
        if (player)
            setMediaPlayer(player);
    }

    /// The player it shows.
    mixin(declareProperty!(MediaPlayer, "mediaPlayer", "null", q{ playerChanged(); }));

    /// How the video fills the view.
    mixin(declareProperty!(VideoScaling, "scaling", "VideoScaling.fit", q{ invalidate(); }));

    /// Whether the video's smoothed as it's scaled, or its pixels kept sharp.
    mixin(declareProperty!(bool, "smooth", "true", q{ applyFilter(); }));

    /// Where the video is, in the window, as it was last drawn: inside the view, less any bars,
    /// or beyond it where `cover` cuts it off. Empty while there's no frame to show. For what's
    /// laid over the picture itself: subtitles, say.
    final Bounds videoBounds() const nothrow @nogc { return _picture ? _videoBounds : Bounds.init; }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    override void mounted() nothrow
    {
        _holder = addPaint(tvg_scene_new());
        _clip = tvg_shape_new();
        tvg_paint_set_clip(_holder, _clip);
        _picture = null;
        watch(_mediaPlayer);
        frameDirty = true;
        requestUpdate();
    }

    override void unmounted()
    {
        // The holder took the picture and the clip with it. The player plays on.
        _holder = _clip = _picture = null;
        watch(null);
    }

    override void update()
    {
        if (frameDirty)
            showFrame();
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        if (_clip)
        {
            tvg_shape_reset(_clip);
            tvg_shape_append_rect(_clip, x, y, w, h, 0, 0, true);
        }
        if (!_picture || !shownW || !shownH || w <= 0 || h <= 0)
            return;
        // The video's own shape, its pixels made square
        const vw = shownW * shownPixelAspect, vh = cast(float) shownH;
        float dw = w, dh = h;
        final switch (_scaling)
        {
            case VideoScaling.fit:
                const s = w / vw < h / vh ? w / vw : h / vh;
                dw = vw * s;
                dh = vh * s;
                break;
            case VideoScaling.cover:
                const s = w / vw > h / vh ? w / vw : h / vh;
                dw = vw * s;
                dh = vh * s;
                break;
            case VideoScaling.stretch:
                break;
        }
        _videoBounds = Bounds(x + (w - dw) / 2, y + (h - dh) / 2, dw, dh);
        auto m = Tvg_Matrix(dw / shownW, 0, _videoBounds.minX, 0, dh / shownH, _videoBounds.minY, 0, 0, 1);
        tvg_paint_set_transform(_picture, &m);
    }

package:
    // The size it'd like: the video's, its pixels made square
    void naturalSize(out float w, out float h) nothrow @nogc
    {
        w = shownW * shownPixelAspect;
        h = shownH;
    }

private:
    Tvg_Paint _holder, _clip, _picture;
    Bounds _videoBounds;
    MediaPlayer watching;
    Watcher watcher;
    bool frameDirty;
    uint shownW, shownH;
    float shownPixelAspect = 1;
    uint[] packed;  // a frame whose rows have padding, without it, as ThorVG takes it

    static final class Watcher : FrameWatcher
    {
        MediaView view;
        this(MediaView view) nothrow { this.view = view; }
        void frameChanged()
        {
            view.frameDirty = true;
            view.requestUpdate();
        }
    }

    void playerChanged()
    {
        if (_holder)
            watch(_mediaPlayer);
        frameDirty = true;
        requestUpdate();
    }

    /// Hears of `player`'s frames from now on, and no longer of the one before.
    void watch(MediaPlayer player) nothrow
    {
        try
        {
            if (watching is player)
                return;
            if (watching)
                watching.unwatch(watcher);
            watching = player;
            if (player)
                player.watch(watcher);
        }
        catch (Exception) {}
    }

    /// Shows the player's current frame, or nothing if it has none.
    void showFrame()
    {
        frameDirty = false;
        if (!_holder)
            return;
        auto frame = _mediaPlayer && !_mediaPlayer.disposed ? _mediaPlayer.currentFrame : null;
        const oldW = shownW * shownPixelAspect, oldH = shownH;
        if (_picture)
            tvg_scene_remove(_holder, _picture);
        _picture = null;
        scope (exit)
        {
            if (shownW * shownPixelAspect != oldW || shownH != oldH)
                YGNodeMarkDirty(node); // another size of video: its natural size changes
            invalidate();
        }
        if (!frame)
            return;

        size_t stride;
        const w = frame.width, h = frame.height;
        auto pixels = frame.map(stride);
        if (!pixels || !w || !h || stride < w * 4 || pixels.length < stride * (h - 1) + w * 4)
        {
            if (pixels)
                frame.unmap();
            return;
        }
        scope (exit) frame.unmap();
        const(uint)* data;
        if (stride == w * 4)
            data = cast(const(uint)*) pixels.ptr;
        else
        {
            if (packed.length != w * h)
                packed = new uint[w * h];
            foreach (y; 0 .. h)
                packed[y * w .. (y + 1) * w] = (cast(const(uint)*) (pixels.ptr + y * stride))[0 .. w];
            data = packed.ptr;
        }
        _picture = tvg_picture_new();
        tvg_picture_load_raw(_picture, data, w, h, TVG_COLORSPACE_ARGB8888, true); // a copy: the frame's the player's
        tvg_scene_add(_holder, _picture);
        shownW = w;
        shownH = h;
        shownPixelAspect = frame.pixelAspectRatio;
        applyFilter();
    }

    void applyFilter() nothrow @nogc
    {
        if (_picture)
            tvg_picture_set_filter(_picture, _smooth ? TVG_FILTER_METHOD_BILINEAR : TVG_FILTER_METHOD_NEAREST);
        invalidate();
    }
}

/// How a MediaView's video fills it.
enum VideoScaling
{
    fit,      /// As big as it can be, keeping its shape, centred: bars where it doesn't fill the view
    cover,    /// Filling the view, keeping its shape, centred: cut off where it overflows
    stretch,  /// Filling the view, its shape changed to the view's
}

private extern (C) YGSize measureMediaView(YGNodeConstRef node, float width, YGMeasureMode widthMode,
                                           float height, YGMeasureMode heightMode) nothrow @nogc
{
    auto self = cast(MediaView) YGNodeGetContext(node);
    float w = 0, h = 0;
    if (self)
        self.naturalSize(w, h);
    return YGSize(w, h);
}
