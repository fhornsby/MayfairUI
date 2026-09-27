module tests.images;

import core.thread : Thread;
import core.time : msecs;
import std.format : format;
import std.math : abs;
import harness;
import mayfair;

private immutable png = import("four-by-two.png");
private immutable tickSvg = import("tick-symbolic.svg");
private immutable slide = import("slide.json");

/// Image views: their image's own size, fitted by JavaFX's rules, and nothing for data that isn't an image.
void imageViews()
{
    ImageView natural, wide, stretched, boxed, svg, broken;
    Image bitmap;
    run("images: image views", {
        auto root = new Column().fillWidth(false).spacing(8).padding(20);
        bitmap = Image.fromData(png, "four-by-two.png");
        natural = new ImageView(bitmap);
        wide = new ImageView(bitmap).fitWidth(40).preserveRatio(true);
        stretched = new ImageView(bitmap).fitWidth(40);
        boxed = new ImageView(bitmap).fitWidth(30).fitHeight(30).preserveRatio(true);
        svg = new ImageView(Image.fromData(tickSvg));
        broken = new ImageView(Image.fromData("not an image at all"));
        root.add(natural).add(wide).add(stretched).add(boxed).add(svg).add(broken);
        return cast(Widget) root;
    }, (Driver d) {
        d.ui({
            d.expect(bitmap.format, ImageFormat.png);
            d.check(!bitmap.error, "the PNG decodes: " ~ bitmap.errorMessage);
            d.expect(bitmap.width, 4f, "its own width, once shown");
            d.expect(natural.boundsInScene.width, 4f, "as big as its image");
            d.expect(natural.boundsInScene.height, 2f);
            d.expect(wide.boundsInScene.width, 40f, "fitted to a width");
            d.expect(wide.boundsInScene.height, 20f, "with its shape kept");
            d.expect(stretched.boundsInScene.width, 40f, "fitted to a width without preserveRatio");
            d.expect(stretched.boundsInScene.height, 2f, "keeps its own height");
            d.expect(boxed.boundsInScene.width, 30f, "fitted inside both");
            d.expect(boxed.boundsInScene.height, 15f, "the largest that fits");
            d.expect(svg.boundsInScene.width, 16f, "an SVG's own size");
            d.check(broken.image.error, "data that isn't an image is an error");
            d.expect(broken.boundsInScene.width, 0f, "and shows nothing");
        });
        d.ui({ wide.setFitWidth(80); });
        d.ui({ d.expect(wide.boundsInScene.height, 40f, "refitted when the fit changes"); });
        d.ui({ natural.setImage(null); });
        d.ui({ d.expect(natural.boundsInScene.width, 0f, "no image, no size"); });
    });
}

/// A probe for an icon's colours: an Icon that lets the test at its picture.
private final class ProbeIcon : Icon
{
    this(Image image) { super(image); }
    this(string name) { super(name); }
    Tvg_Paint probe() { return picture; }
}

private struct Seen
{
    Colour[64] colours; // each painted shape's fill or stroke, in order
    size_t count;
}

private extern(C) bool collect(Tvg_Paint p, void* data) nothrow @nogc
{
    auto seen = cast(Seen*) data;
    Tvg_Type type;
    tvg_paint_get_type(p, &type);
    if (type != TVG_TYPE_SHAPE)
        return true;
    ubyte r, g, b, a;
    float width = 0;
    tvg_shape_get_stroke_width(p, &width);
    if (width > 0)
        tvg_shape_get_stroke_color(p, &r, &g, &b, &a);
    else
        tvg_shape_get_fill_color(p, &r, &g, &b, &a);
    if (seen.count < seen.colours.length)
        seen.colours[seen.count++] = Colour(r, g, b, a);
    return true;
}

private Colour[] coloursOf(Tvg_Paint picture)
{
    Seen seen;
    auto accessor = tvg_accessor_new();
    tvg_accessor_set(accessor, picture, &collect, &seen);
    tvg_accessor_del(accessor);
    return seen.colours[0 .. seen.count].dup;
}

/// Icons: square at their size, symbolic ones in the text's colour -- a default button's too --
/// following a stylesheet, and named ones from the desktop's theme.
void icons()
{
    ProbeIcon plain, onDefault, named;
    Button withIcon, iconOnly;
    run("images: icons", {
        auto root = new Column().fillWidth(false).spacing(8).padding(20);
        plain = new ProbeIcon(Image.fromData(tickSvg, "tick-symbolic.svg"));
        onDefault = new ProbeIcon(Image.fromData(tickSvg, "tick-symbolic.svg"));
        named = new ProbeIcon("edit-copy-symbolic");
        withIcon = new Button("Copy").graphic(onDefault).defaultButton(true);
        iconOnly = new Button().graphic(new Icon(Image.fromData(tickSvg))).accessibleText("Done");
        root.add(plain).add(withIcon).add(iconOnly).add(named);
        return cast(Widget) root;
    }, (Driver d) {
        // Light, where a default button's text is a different colour from the rest
        d.ui({ plain.scene.setColourScheme(ColourScheme.light); });
        d.ui({
            d.expect(plain.boundsInScene.width, 16f, "16 points, as GNOME's are");
            auto colours = coloursOf(plain.probe);
            d.expect(colours.length, 2, "both shapes");
            // The light theme's var(--text), #0f172a; the square keeps its half alpha
            d.expect(colours[0], Colour(0x0f, 0x17, 0x2a, 255), "the stroke, in the text's colour");
            d.expect(colours[1], Colour(0x0f, 0x17, 0x2a, 128), "the fill, keeping its alpha");
            d.expect(coloursOf(onDefault.probe)[0], Colour(255, 255, 255, 255), "on a default button, its text's colour");
        });

        d.ui({ plain.setStyle("icon-colour: #b91c1c; icon-size: 32px;"); });
        d.ui({
            d.expect(coloursOf(plain.probe)[0], Colour(0xb9, 0x1c, 0x1c, 255), "recoloured by a stylesheet");
            d.expect(coloursOf(plain.probe)[1].a, cast(ubyte) 128, "the alpha still its own");
            d.expect(plain.boundsInScene.width, 32f, "and resized");
        });

        d.ui({ plain.setSymbolic(false); });
        d.ui({ d.expect(coloursOf(plain.probe)[0], Colour(0x2e, 0x34, 0x36, 255), "not symbolic: its own colours"); });

        d.ui({
            // The icon, the gap, then the text
            auto icon = withIcon.children[0];
            auto text = withIcon.children[1];
            d.check(icon is onDefault, "the graphic comes first");
            d.expect(text.boundsInScene.minX - icon.boundsInScene.maxX, 4f, "graphicTextGap between them");
            d.check(abs(icon.boundsInScene.centreY - withIcon.boundsInScene.centreY) <= 0.5,
                    format!"centred on the button: %s in %s"(icon.boundsInScene, withIcon.boundsInScene));
            d.expect(iconOnly.boundsInScene.width, 16f + 32f, "no text: only the icon, in the padding");
        });

        d.ui({
            // Whatever the desktop's theme, a GNOME desktop has this one; elsewhere there may be none
            if (IconTheme.lookup("edit-copy-symbolic", 16).length)
            {
                d.check(named.image && !named.image.error, "a named icon is found and loads");
                d.expect(named.boundsInScene.width, 16f);
                d.check(named.symbolic, "a -symbolic name is symbolic");
                foreach (c; coloursOf(named.probe))
                    d.check(c.r == 0x0f && c.g == 0x17 && c.b == 0x2a, format!"a themed icon in the text's colour: %s"(c));
            }
        });
    });
}

/// Lottie: plays on its own, pauses and carries on, plays a marked part, and stays still if told to.
void lottie()
{
    LottieView playing, still;
    Column root;
    run("images: lottie", {
        root = new Column().fillWidth(false).spacing(8).padding(20);
        // One image, two views: each has an animation of its own, at its own frame
        auto image = Image.fromData(slide, "slide.json");
        playing = new LottieView(image);
        still = new LottieView(image).autoPlay(false).fitWidth(50).preserveRatio(true);
        root.add(playing).add(still);
        return cast(Widget) root;
    }, (Driver d) {
        d.ui({
            d.check(playing.image.animated, "a Lottie file is animated");
            d.expect(playing.boundsInScene.width, 100f, "its composition's size");
            d.expect(still.boundsInScene.height, 25f, "and fits as an ImageView does");
            d.expect(playing.totalFrames, 60f);
            d.expect(playing.animation.cycleDuration, 1000.msecs, "60 frames at 60 a second");
            d.expect(playing.animation.status, Status.running, "it plays as soon as it's shown");
            d.expect(still.animation.status, Status.stopped, "unless autoPlay is off");
            d.expect(playing.markers, ["first", "second"]);
        });
        Thread.sleep(200.msecs);
        float at;
        d.ui({
            at = playing.currentFrame;
            d.check(at > 0, format!"it's moved on: frame %s"(at));
            d.expect(still.currentFrame, 0f, "the still one hasn't");
            playing.animation.pause();
            at = playing.currentFrame;
        });
        Thread.sleep(100.msecs);
        d.ui({ d.expect(playing.currentFrame, at, "paused, it stays put"); });

        d.ui({ root.remove(playing); });
        d.ui({
            d.expect(playing.animation.status, Status.paused, "out of the scene, it's paused");
            playing.animation.play();
            root.remove(still);
        });
        d.ui({ root.add(still); });
        d.ui({ d.expect(still.animation.status, Status.stopped, "back in the scene, a still one's still still"); });

        d.ui({
            root.add(playing);
            playing.setMarker("second");
        });
        d.ui({
            d.check(!playing.image.error, "loaded again, from the same data: " ~ playing.image.errorMessage);
            d.expect(playing.totalFrames, 30f, "only the marked part");
            d.expect(playing.animation.cycleDuration, 500.msecs, "and its cycle is that long");
            d.expect(playing.animation.status, Status.running, "back in the scene, it plays on");
            playing.setMarker(null);
        });
        d.ui({ d.expect(playing.totalFrames, 60f, "no marker: all of it"); });
    });
}

/// A LottieView that lets the test at its picture.
private final class ProbeLottie : LottieView
{
    this(Image image) { super(image); }
    Tvg_Paint probe() { return picture; }
}

/// Lottie colour slots, from the stylesheet: a looked-up colour on the view or above it, following
/// the colour scheme, and the file's own colour when nothing says otherwise.
void lottieSlots()
{
    ProbeLottie view;
    Column root;
    run("images: lottie slots", {
        root = new Column().fillWidth(false).padding(20);
        view = new ProbeLottie(Image.fromData(slide, "slide.json"));
        view.autoPlay(false); // paused, so it's recoloured without a new frame to show it
        root.add(view);
        return cast(Widget) root;
    }, (Driver d) {
        bool near(Colour a, Colour b)
        {
            return abs(a.r - b.r) <= 1 && abs(a.g - b.g) <= 1 && abs(a.b - b.b) <= 1;
        }
        void expectColour(Colour want, string what, string file = __FILE__, size_t line = __LINE__)
        {
            d.ui({
                auto colours = coloursOf(view.probe);
                d.check(colours.length == 1 && near(colours[0], want),
                        format!"%s: expected %s, got %s"(what, want, colours), file, line);
            });
        }

        d.ui({ d.expect(view.image.colourSlots, ["square"], "the file's colour slot"); });
        expectColour(Colour(51, 102, 204), "nothing declared: the file's own colour");

        d.ui({ root.setStyle("--lottie-square: #ff0000;"); });
        d.settle();
        expectColour(Colour(255, 0, 0), "declared above it");

        d.ui({
            view.setStyle("--lottie-square: var(--accent);");
            view.scene.setColourScheme(ColourScheme.light);
        });
        d.settle();
        expectColour(Colour(0x02, 0x84, 0xc7), "its own, looked up: the light accent");

        d.ui({ view.scene.setColourScheme(ColourScheme.dark); });
        d.settle();
        expectColour(Colour(0x38, 0xbd, 0xf8), "and the dark one when the scheme changes");

        d.ui({
            view.setStyle(null);
            root.setStyle(null);
        });
        d.settle();
        expectColour(Colour(51, 102, 204), "taken away: the file's own again");
    });
}
