module signature;

/*
    Drawing a signature, to place on documents: a pad to sign on with the pointer (or a pen on a
    tablet), in a dialog. Kept with the others in the viewer's settings (see store.d).
*/

import mayfair;
import mayfair.pdf : PdfPoint;
import store : addSignature;

/// Where a signature's drawn: strokes, following the pointer while it's down.
final class SignaturePad : Widget
{
    this()
    {
        setPrefWidth(420);
        setPrefHeight(160);
        setCursor(Cursor.crosshair);
    }

    PdfPoint[][] strokes;

    void clear()
    {
        strokes = null;
        invalidate();
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    override void mounted() nothrow
    {
        auto holder = addPaint(tvg_scene_new());
        back = tvg_shape_new();
        tvg_shape_set_fill_color(back, 255, 255, 255, 255);
        tvg_shape_set_stroke_color(back, 0, 0, 0, 60);
        tvg_shape_set_stroke_width(back, 1);
        baseline = tvg_shape_new();
        tvg_shape_set_stroke_color(baseline, 0, 0, 0, 80);
        tvg_shape_set_stroke_width(baseline, 1);
        ink = tvg_shape_new();
        tvg_shape_set_stroke_color(ink, 20, 20, 60, 255);
        tvg_shape_set_stroke_width(ink, 2.5f);
        tvg_shape_set_stroke_cap(ink, TVG_STROKE_CAP_ROUND);
        tvg_shape_set_stroke_join(ink, TVG_STROKE_JOIN_ROUND);
        tvg_scene_add(holder, back);
        tvg_scene_add(holder, baseline);
        tvg_scene_add(holder, ink);
    }

    override void unmounted() { back = baseline = ink = null; }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        if (!back)
            return;
        tvg_shape_reset(back);
        tvg_shape_append_rect(back, x, y, w, h, 6, 6, true);
        tvg_shape_reset(baseline);
        tvg_shape_move_to(baseline, x + 24, y + h * 0.72f);
        tvg_shape_line_to(baseline, x + w - 24, y + h * 0.72f);
        tvg_shape_reset(ink);
        foreach (s; strokes)
            foreach (i, p; s)
            {
                if (i)
                    tvg_shape_line_to(ink, x + p.x, y + p.y);
                else
                {
                    tvg_shape_move_to(ink, x + p.x, y + p.y);
                    tvg_shape_line_to(ink, x + p.x + 0.1f, y + p.y);
                }
            }
    }

    override void handleMouse(ref MouseEvent event)
    {
        switch (event.type)
        {
            case MouseEventType.pressed:
                strokes ~= [PdfPoint(event.x, event.y)];
                break;
            case MouseEventType.dragged:
                if (strokes.length)
                    strokes[$ - 1] ~= PdfPoint(event.x, event.y);
                break;
            default:
                return;
        }
        invalidate();
        event.consume();
    }

private:
    Tvg_Paint back, baseline, ink;
}

/// Asks for a signature to be drawn, over `owner`'s window; `done` once one's been kept.
void drawSignature(Widget owner, void delegate() done)
{
    auto pad = new SignaturePad;
    auto clear = new Button("Clear");
    clear.setOnAction({ pad.clear(); });
    auto content = new Column().spacing(8).add(pad).add(new Row().add(clear));
    auto dialog = new Dialog("Sign your name")
        .text("Sign with the pointer, or a pen. It's kept for next time, on this computer only.")
        .extra(content)
        .addButton("Cancel", null, ButtonKind.cancel)
        .addButton("Keep It", {
            if (!pad.strokes.length)
                return;
            // Fitted to the ink: from its top left
            float l = float.max, t = float.max, r = 0, b = 0;
            foreach (s; pad.strokes)
                foreach (p; s)
                {
                    if (p.x < l) l = p.x;
                    if (p.y < t) t = p.y;
                    if (p.x > r) r = p.x;
                    if (p.y > b) b = p.y;
                }
            PdfPoint[][] moved;
            foreach (s; pad.strokes)
            {
                PdfPoint[] m;
                foreach (p; s)
                    m ~= PdfPoint(p.x - l + 2, p.y - t + 2);
                moved ~= m;
            }
            addSignature(moved, r - l + 4);
            done();
        }, ButtonKind.default_);
    dialog.show(owner);
}
