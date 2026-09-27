module mayfair.widgets.imageview;

import mayfair.accessibility;
import mayfair.images;
import mayfair.layout;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.widgets.widget;

/*
    Shows an Image. JavaFX's ImageView.

        new ImageView(new Image("photo.jpg")).fitWidth(200).preserveRatio(true)

    It's as big as its image, unless fitWidth or fitHeight say otherwise, and preserveRatio keeps
    the image's shape while fitting it -- JavaFX's rules exactly, down to preserveRatio with both
    fits taking the largest size that fits inside the two. Given more room than that by the
    layout, as by a pref size in a stylesheet, it draws the image to fill it, or with preserveRatio
    as big as fits and centred. Its padding goes round the image, as a Region's would.

    An SVG is drawn as the vectors it is, so it's sharp at any size and on any screen; a PNG, JPEG
    or WebP is scaled, smoothly unless `smooth` is off, which is what pixel art wants. A Lottie
    image shows its first frame: LottieView plays one.

    Its style class is "image-view". To a screen reader it's an image, named by its accessibleText,
    which is where its alt text goes; one that's only decoration wants accessibleHidden instead.
*/
class ImageView : Widget
{
public:
    this(Image image = null)
    {
        _image = image;
        styleClass.add("image-view");
        setAccessibleRole(AccessibleRole.image);
        YGNodeSetContext(node, cast(void*) this);
        YGNodeSetMeasureFunc(node, &measureImageView);
    }

    /// What it shows.
    mixin(declareProperty!(Image, "image", "null", q{ reload(); }));

    /// The width to fit the image to, in points; 0 for the image's own. JavaFX's fitWidth.
    mixin(declareProperty!(float, "fitWidth", "0", q{ remeasure(); }));

    /// The height to fit the image to, in points; 0 for the image's own. JavaFX's fitHeight.
    mixin(declareProperty!(float, "fitHeight", "0", q{ remeasure(); }));

    /// Whether fitting keeps the image's shape. JavaFX's preserveRatio.
    mixin(declareProperty!(bool, "preserveRatio", "false", q{ remeasure(); }));

    /// Whether a scaled bitmap is smoothed, or its pixels kept square. JavaFX's smooth.
    mixin(declareProperty!(bool, "smooth", "true", q{ applyFilter(); }));

protected:
    override bool takesChildren() const nothrow @nogc { return false; } // Yoga measures it, as a leaf

    // As big as its image and no bigger, as JavaFX's is: see Widget.maxWidth
    override float computeMaxWidth() const nothrow @nogc { return usePrefSize; }
    override float computeMaxHeight() const nothrow @nogc { return usePrefSize; }

    override void mounted() nothrow
    {
        // The picture sits in a scene of its own: paintTree gives each of a widget's paints its
        // opacity and scale as a transform, and the picture needs a transform of its own to be
        // placed and sized, which inside the scene it can have
        _holder = addPaint(tvg_scene_new());
        load();
    }

    override void unmounted()
    {
        // The holder went with the widget's other paints, and took the picture with it
        const had = _picture !is null;
        _picture = null;
        _holder = null;
        if (had)
            released();
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        if (!_picture || _naturalWidth <= 0 || _naturalHeight <= 0)
            return;
        // Inside the padding, as the layout worked it out
        const l = YGNodeLayoutGetPadding(node, YGEdgeLeft), t = YGNodeLayoutGetPadding(node, YGEdgeTop);
        const cw = w - l - YGNodeLayoutGetPadding(node, YGEdgeRight);
        const ch = h - t - YGNodeLayoutGetPadding(node, YGEdgeBottom);
        if (cw <= 0 || ch <= 0)
            return;
        float sx = cw / _naturalWidth, sy = ch / _naturalHeight;
        float ox = x + l, oy = y + t;
        if (_preserveRatio)
        {
            const s = sx < sy ? sx : sy;
            ox += (cw - _naturalWidth * s) / 2;
            oy += (ch - _naturalHeight * s) / 2;
            sx = sy = s;
        }
        auto m = Tvg_Matrix(sx, 0, ox, 0, sy, oy, 0, 0, 1);
        tvg_paint_set_transform(_picture, &m);
    }

    /*
        The size it asks the layout for, before padding: JavaFX's ImageView's. With nothing to fit
        to, the image's own; fitting one way with preserveRatio, the other follows; fitting both
        ways, the largest that fits in both.
    */
    void preferredSize(out float w, out float h) nothrow @nogc
    {
        w = _naturalWidth;
        h = _naturalHeight;
        if (_preserveRatio && w > 0 && h > 0 && (_fitWidth > 0 || _fitHeight > 0))
        {
            float s = float.infinity;
            if (_fitWidth > 0)
                s = _fitWidth / w;
            if (_fitHeight > 0 && _fitHeight / h < s)
                s = _fitHeight / h;
            w *= s;
            h *= s;
            return;
        }
        if (_fitWidth > 0)
            w = _fitWidth;
        if (_fitHeight > 0)
            h = _fitHeight;
    }

    /// Makes the picture for `image`, ready to be drawn, or null if it can't be: a subclass that
    /// draws it some other way, as LottieView plays it, overrides this and released().
    Tvg_Paint createPicture(Image image) nothrow
    {
        auto p = tvg_picture_new();
        if (tvg_picture_load_data(p, image.dataPointer, image.dataLength, image.mimeType, image.resourcePath,
                                  image.copyOnLoad)
            != TVG_RESULT_SUCCESS)
        {
            tvg_paint_rel(p);
            return null;
        }
        return p;
    }

    /// The picture createPicture() made has been taken out of the scene. ThorVG has freed it,
    /// unless something else still holds it.
    void released() nothrow {}

    /// The picture's loaded and in the scene: for a subclass that does something to it, as an
    /// Icon recolours it.
    void loaded() nothrow {}

    /// The picture being drawn, while there is one; null otherwise.
    final Tvg_Paint picture() nothrow @nogc { return _picture; }

    /// The scene the picture's in, for effects on it as a whole. Null while it isn't mounted.
    final Tvg_Paint holder() nothrow @nogc { return _holder; }

    /// The image's own size, once its picture's loaded.
    final float naturalWidth() const nothrow @nogc { return _naturalWidth; }
    final float naturalHeight() const nothrow @nogc { return _naturalHeight; } /// ditto

    /// The image changed, or needs loading again: out with any picture there is, and in with the
    /// new one if it's mounted.
    final void reload() nothrow
    {
        if (_picture)
        {
            tvg_scene_remove(_holder, _picture);
            _picture = null;
            released();
        }
        if (_holder)
            load();
        else
            remeasure();
    }

    final void remeasure() nothrow @nogc
    {
        YGNodeMarkDirty(node);
        invalidate();
    }

private:
    Tvg_Paint _holder, _picture;
    float _naturalWidth = 0, _naturalHeight = 0;

    void load() nothrow
    {
        _naturalWidth = _naturalHeight = 0;
        if (_image && !_image.error)
        {
            auto p = createPicture(_image);
            float w = 0, h = 0;
            if (p)
                tvg_picture_get_size(p, &w, &h);
            _image.decoded(p !is null, w, h);
            if (p)
            {
                _picture = p;
                _naturalWidth = w;
                _naturalHeight = h;
                tvg_scene_add(_holder, p);
                applyFilter();
                loaded();
            }
        }
        remeasure();
    }

    void applyFilter() nothrow @nogc
    {
        if (_picture)
            tvg_picture_set_filter(_picture, _smooth ? TVG_FILTER_METHOD_BILINEAR : TVG_FILTER_METHOD_NEAREST);
        invalidate();
    }
}

/// Yoga measuring an image view: its preferred size, whatever room there is.
private extern(C) YGSize measureImageView(YGNodeConstRef node, float width, YGMeasureMode widthMode,
                                          float height, YGMeasureMode heightMode) nothrow @nogc
{
    auto self = cast(ImageView) YGNodeGetContext(node);
    if (!self)
        return YGSize(0, 0);
    float w, h;
    self.preferredSize(w, h);
    return YGSize(w, h);
}
