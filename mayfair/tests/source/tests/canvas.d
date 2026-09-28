module tests.canvas;

import std.format : format;
import std.math : abs;
import harness;
import mayfair;

private immutable png = import("four-by-two.png");

private bool near(Colour a, Colour b, int by = 2)
{
    return abs(a.r - b.r) <= by && abs(a.g - b.g) <= by && abs(a.b - b.b) <= by && abs(a.a - b.a) <= by;
}

private enum red = Colour(220, 38, 38), blue = Colour(37, 99, 235), clear = Colour(0, 0, 0, 0);

/// Canvases: drawing lands in the pixels, at the screen's scale, and stays there; each call keeps
/// to the state -- transform, clip, alpha -- it was made in; and what's drawn reads back, both as
/// colours and as a PNG.
void drawing()
{
    Canvas canvas, copy;
    run("canvas: drawing", {
        canvas = new Canvas(200, 120);
        copy = new Canvas(200, 120);
        // Drawn before it's in a window: it waits for the window, to know its pixels
        canvas.graphicsContext.setFill(red).fillRect(10, 10, 40, 20);
        return cast(Widget) new Column().padding(20).spacing(10).fillWidth(false).add(canvas).add(copy);
    }, (Driver d) {
        d.ui({
            const s = canvas.scene.scale;
            d.expect(canvas.pixelScale, s, "pixels at the screen's scale");
            d.expect(canvas.pixelWidth, cast(uint)(200 * s), "that many across");
            const b = canvas.boundsInScene;
            d.check(b.width == 200 && b.height == 120, format!"as big as it says: %s"(b));
            d.check(near(canvas.colourAt(20, 15), red), format!"drawn before it was shown: %s"(canvas.colourAt(20, 15)));
            d.expect(canvas.colourAt(5, 5), clear, "and nothing round it");
        });

        // A later frame draws over what's there, rather than starting again
        d.ui({ canvas.graphicsContext.setFill(blue).fillRect(40, 10, 40, 20); });
        d.settle();
        d.ui({
            d.check(near(canvas.colourAt(20, 15), red), "the first rectangle's still there");
            d.check(near(canvas.colourAt(60, 15), blue), "with the second over it");
            canvas.graphicsContext.clearRect(15, 12, 10, 10);
            d.expect(canvas.colourAt(20, 15), clear, "cleared");
            d.check(near(canvas.colourAt(12, 15), red), "only there");
        });

        // Transforms, and save and restore
        d.ui({
            auto g = canvas.graphicsContext;
            g.save().translate(100, 50).scale(2, 2).setFill(red).fillRect(0, 0, 10, 10).restore();
            d.check(near(canvas.colourAt(118, 68), red), "moved and scaled");
            d.expect(canvas.colourAt(122, 72), clear, "to twice the size, and no more");
            g.fillRect(0, 100, 4, 4);
            d.check(near(canvas.colourAt(2, 102), blue), "restored: no transform, and the fill before");
        });

        // A path, stroked and filled, and a clip
        d.ui({
            auto g = canvas.graphicsContext;
            g.setStroke(red).setLineWidth(4).beginPath().moveTo(150, 10).lineTo(190, 10).stroke();
            d.check(near(canvas.colourAt(170, 10), red), "a stroked path");
            d.check(near(canvas.colourAt(170, 13), clear), "as wide as the line");
            g.setFill(blue).beginPath().moveTo(150, 30).lineTo(190, 30).lineTo(150, 70).closePath().fill();
            d.check(near(canvas.colourAt(155, 35), blue), "a filled path");
            d.expect(canvas.colourAt(185, 65), clear, "on its own side of the diagonal");

            g.save().beginPath().rect(10, 80, 20, 20).clip();
            g.setFill(red).fillRect(0, 70, 60, 50);
            g.restore();
            d.check(near(canvas.colourAt(20, 90), red), "inside the clip");
            d.expect(canvas.colourAt(40, 90), clear, "not outside it");
            g.fillRect(40, 85, 5, 5);
            d.check(near(canvas.colourAt(42, 87), blue), "the clip goes with restore()");

            g.setGlobalAlpha(0.5).setFill(Colour(0, 0, 0)).fillRect(60, 80, 10, 10).setGlobalAlpha(1);
            d.check(near(canvas.colourAt(65, 85), Colour(0, 0, 0, 128)), format!"half opaque: %s"(canvas.colourAt(65, 85)));
        });

        // Text, and an image
        d.ui({
            auto g = canvas.graphicsContext;
            g.setFill(Colour(0, 0, 0)).setTextBaseline(TextBaseline.top).fillText("Mayfair", 80, 90);
            int inked;
            foreach (x; 80 .. 130)
                foreach (y; 90 .. 105)
                    if (canvas.colourAt(x, y).a > 128)
                        inked++;
            d.check(inked > 30, format!"text: %s points inked"(inked));
            d.expect(canvas.colourAt(80, 88), clear, "below the top it was given");

            // four-by-two.png: 4x2, stretched to 40x20
            g.setImageSmoothing(false).drawImage(Image.fromData(png, "four-by-two.png"), 150, 90, 40, 20);
            d.check(canvas.colourAt(155, 95).a == 255, "an image, stretched");
            d.expect(canvas.colourAt(195, 95), clear, "to the size asked for");
        });

        // What's drawn reads back as a PNG, which draws as it was
        d.ui({
            copy.graphicsContext.drawImage(canvas.snapshot, 0, 0, 200, 120);
        });
        d.settle();
        d.ui({
            foreach (p; [[12, 15], [60, 15], [20, 15], [155, 35], [65, 85]])
                d.check(near(copy.colourAt(p[0] + 0.5f, p[1] + 0.5f), canvas.colourAt(p[0] + 0.5f, p[1] + 0.5f), 3),
                        format!"the copy at %s: %s, the canvas %s"(p, copy.colourAt(p[0] + 0.5f, p[1] + 0.5f),
                                                                    canvas.colourAt(p[0] + 0.5f, p[1] + 0.5f)));
        });

        // Bigger keeps what's drawn; the pixels can be changed by hand
        d.ui({ canvas.setWidth(260); });
        d.settle();
        d.ui({
            d.check(canvas.boundsInScene.width == 260, "bigger");
            d.check(near(canvas.colourAt(60, 15), blue), "and what was drawn is where it was");
            d.expect(canvas.colourAt(230, 15), clear, "with the new part empty");
            auto pixels = canvas.pixels;
            const s = canvas.pixelScale;
            pixels[cast(size_t)(5 * s) * canvas.pixelWidth + cast(size_t)(250 * s)] = 0xff_00_ff_00;
            canvas.pixelsChanged();
            d.expect(canvas.colourAt(250, 5), Colour(0, 255, 0), "a pixel set by hand");
        });
    });
}

/// Painting: a canvas takes the mouse like anything else, so dragging on it draws.
void painting()
{
    Canvas canvas;
    run("canvas: painting with the mouse", {
        canvas = new Canvas(200, 100);
        float lastX, lastY;
        auto g = canvas.graphicsContext;
        g.setStroke(red).setLineWidth(6).setLineCap(StrokeLineCap.round);
        canvas.onMousePressed((ref MouseEvent e) { lastX = e.x; lastY = e.y; });
        canvas.onMouseDragged((ref MouseEvent e) {
            g.strokeLine(lastX, lastY, e.x, e.y);
            lastX = e.x;
            lastY = e.y;
        });
        return cast(Widget) new Column().padding(20).fillWidth(false).add(canvas);
    }, (Driver d) {
        Bounds b;
        d.ui({ b = canvas.boundsInScene; });
        d.press(b.minX + 20, b.minY + 50);
        foreach (i; 1 .. 9)
            d.move(b.minX + 20 + i * 20, b.minY + 50);
        d.release(b.minX + 180, b.minY + 50);
        d.settle();
        d.ui({
            foreach (x; [20, 60, 100, 140, 175])
                d.check(near(canvas.colourAt(x, 50), red), format!"painted at %s: %s"(x, canvas.colourAt(x, 50)));
            d.expect(canvas.colourAt(100, 40), clear, "only along the drag");
        });
    });
}
