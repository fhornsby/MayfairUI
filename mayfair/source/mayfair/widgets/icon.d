module mayfair.widgets.icon;

import std.algorithm : endsWith;
import std.math : ceil;
import mayfair.images;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.theme;
import mayfair.widgets.imageview;
import mayfair.widgets.widget;

/*
    A small picture that stands for something -- on a button, beside a label, in a toolbar -- drawn
    in the colour of the text around it. From the desktop's icon theme by name, or from the app's
    own image:

        new Button("Copy").graphic(new Icon("edit-copy-symbolic"))
        new Icon(Image.fromData(import("brand.svg"), "brand.svg"))

    A named icon is the desktop's, so the app looks like the rest of it: Adwaita's on GNOME, Yaru's
    on Ubuntu. See IconTheme for how the name is found.

    Symbolic icons -- the monochrome outlines GNOME uses on its buttons, named "...-symbolic" --
    are drawn in `iconColor`, as GTK draws them in the text colour. That's what keeps an icon
    legible on a dark theme, on a default button's accent, and faded with its disabled button. An
    icon of the app's own is taken to be one of those, as an icon on a control nearly always is; a
    full-colour one, as a named one without "-symbolic" is, keeps its colours. `symbolic` says
    which, either way.

    It's square, `iconSize` on each side -- 16, as GNOME's are -- and a picture of another shape is
    fitted inside and centred, so icons of different shapes still line up. Size and colour are the
    stylesheet's, as icon-size and icon-colour, and the theme colours an icon as its button's or
    label's text. Its style class is "icon".

    Recolouring an SVG changes the colour of each shape in it, so it costs nothing to draw. A bitmap
    has no shapes to recolour, so a symbolic PNG is drawn through ThorVG's fill effect instead: the
    same result, rendered off-screen first.
*/
class Icon : ImageView
{
public:
    /// The desktop theme's icon called `iconName`: "document-save-symbolic", say.
    this(string iconName)
    {
        styleClass.add("icon");
        setPreserveRatio(true);
        _symbolic = iconName.endsWith("-symbolic");
        _iconName = iconName;
        applySize();
    }

    /// The app's own icon, drawn in `iconColor`.
    this(Image image)
    {
        super(image);
        styleClass.add("icon");
        setPreserveRatio(true);
        _symbolic = true;
        applySize();
    }

    /// The name of the desktop theme's icon it shows; null for one that shows its own image.
    mixin(declareProperty!(string, "iconName", "null", q{ lookUp(); }));

    /// How big it is, in points, both ways.
    mixin(declareStyleableProperty!(float, "iconSize", "icon-size", "16", q{ applySize(); }));

    /// The colour a symbolic icon is drawn in: the text's, as the theme has it.
    mixin(declareStyleableProperty!(Colour, "iconColor", "icon-colour", "Theme.text_colour", q{ recolour(); }));

    /// Whether it's drawn in iconColor, rather than its own colours. See above.
    mixin(declareProperty!(bool, "symbolic", "false", q{ reload(); }));

protected:
    override void mounted() nothrow
    {
        try
            lookUp(); // for this screen's scale, now that there is one
        catch (Exception) {}
        super.mounted();
    }

    override void preferredSize(out float w, out float h) nothrow @nogc
    {
        w = h = _iconSize;
    }

    override void loaded() nothrow
    {
        recolour();
    }

private:
    string _lookedUpName;              // what the named icon was last found for
    int _lookedUpSize, _lookedUpScale;

    void applySize()
    {
        setFitWidth(_iconSize);
        setFitHeight(_iconSize);
        lookUp(); // a theme may have a better one for the new size
    }

    /// Finds the named icon for this size and screen, and shows it if it's a different file.
    void lookUp()
    {
        if (!_iconName.length)
        {
            if (_lookedUpName.length) // it was named, and isn't any more: nothing to show
            {
                _lookedUpName = null;
                setImage(null);
            }
            return;
        }
        if (!scene)
            return;
        const size = cast(int) ceil(_iconSize);
        const scale = cast(int) ceil(scene.scale);
        if (_iconName == _lookedUpName && size == _lookedUpSize && scale == _lookedUpScale)
            return;
        _lookedUpName = _iconName;
        _lookedUpSize = size;
        _lookedUpScale = scale;
        try
        {
            const path = IconTheme.lookup(_iconName, size, scale);
            if (image && path.length && image.name == path)
                return;
            setImage(path.length ? new Image(path) : null);
        }
        catch (Exception)
            setImage(null);
    }

    /*
        Draws it in iconColor, if it's symbolic. A shape keeps its alpha -- a symbolic icon's
        fainter parts are drawn with less of it -- and the colour's own alpha goes on the picture
        as a whole, so recolouring again, to another colour, starts from the same place.
    */
    void recolour() nothrow
    {
        auto p = picture;
        if (!p)
            return;
        tvg_scene_clear_effects(holder);
        if (!_symbolic)
            return; // in its own colours, as it was loaded
        auto accessor = tvg_accessor_new();
        Recolouring r = Recolouring(_iconColor);
        tvg_accessor_set(accessor, p, &recolourShape, &r);
        tvg_accessor_del(accessor);
        tvg_paint_set_opacity(p, _iconColor.a);
        if (!r.shapes) // a bitmap: nothing to recolour but the pixels themselves
            tvg_scene_add_effect_fill(holder, _iconColor.r, _iconColor.g, _iconColor.b, 255);
        invalidate();
    }
}

private:

struct Recolouring
{
    Colour colour;
    size_t shapes; // how many shapes were painted with something
}

// For each paint in the picture, depth first: a shape with a fill or a stroke has it in the colour
extern(C) bool recolourShape(Tvg_Paint p, void* data) nothrow @nogc
{
    auto r = cast(Recolouring*) data;
    Tvg_Type type;
    if (tvg_paint_get_type(p, &type) != TVG_RESULT_SUCCESS || type != TVG_TYPE_SHAPE)
        return true;
    ubyte red, green, blue, alpha;
    Tvg_Gradient gradient;
    bool painted;
    if (tvg_shape_get_gradient(p, &gradient) == TVG_RESULT_SUCCESS && gradient)
    {
        tvg_shape_set_fill_color(p, r.colour.r, r.colour.g, r.colour.b, 255);
        painted = true;
    }
    else if (tvg_shape_get_fill_color(p, &red, &green, &blue, &alpha) == TVG_RESULT_SUCCESS && alpha)
    {
        tvg_shape_set_fill_color(p, r.colour.r, r.colour.g, r.colour.b, alpha);
        painted = true;
    }
    float width = 0;
    if (tvg_shape_get_stroke_width(p, &width) == TVG_RESULT_SUCCESS && width > 0)
    {
        Tvg_Gradient strokeGradient;
        if (tvg_shape_get_stroke_gradient(p, &strokeGradient) == TVG_RESULT_SUCCESS && strokeGradient)
        {
            tvg_shape_set_stroke_color(p, r.colour.r, r.colour.g, r.colour.b, 255);
            painted = true;
        }
        else if (tvg_shape_get_stroke_color(p, &red, &green, &blue, &alpha) == TVG_RESULT_SUCCESS && alpha)
        {
            tvg_shape_set_stroke_color(p, r.colour.r, r.colour.g, r.colour.b, alpha);
            painted = true;
        }
    }
    if (painted)
        r.shapes++;
    return true;
}
