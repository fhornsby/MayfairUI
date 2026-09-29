module tests.web;

import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.format : format;
import std.math : abs, isNaN;
import std.path : buildPath;
import std.string : startsWith;
import harness;
import mayfair;

private immutable png = import("four-by-two.png");

// Clicks the middle of the element with the id `id` in `view`
private void clickOn(Driver d, LiteWebView view, string id)
{
    float x, y;
    d.ui({
        const v = view.boundsInScene, e = view.boundsOf(id);
        x = v.minX + e.centreX;
        y = v.minY + e.centreY;
    });
    d.click(x, y);
    d.settle();
}

/// LiteWebViews showing pages given them: laid out at the view's width, and scrolling; links to a
/// #fragment scroll to it, and a link the app consumes goes nowhere.
void pages()
{
    LiteWebView view;
    string[] clicked;
    run("web: pages", {
        view = new LiteWebView().prefSize(400, 300);
        view.setOnLinkClicked((ref LinkEvent e) {
            clicked ~= e.url;
            if (e.url.startsWith("https:"))
                e.consume();
        });
        view.loadContent(`<title>First page</title>
            <p id="p">Some words, enough of them to take up a few lines when the view is narrow, and
            to wrap again when it is narrower still.</p>
            <a id="down" href="#far">Down</a> <a id="out" href="https://example.org/">Out</a>
            <div id="far" style="margin-top: 1500px">Far</div>
            <div style="height: 1000px"></div>`);
        return cast(Widget) new Column().padding(20).fillWidth(false).add(view);
    }, (Driver d) {
        float wide;
        d.ui({
            d.expect(view.title, "First page", "the title's the page's");
            const p = view.boundsOf("p");
            d.check(abs(p.minX - 8) < 0.5, format!"inside the body's margin: %s"(p));
            d.check(p.width > 300 && p.width <= 400, format!"as wide as the view: %s"(p));
            wide = p.height;
            d.check(view.boundsOf("nothing").width.isNaN, "no such element: NaN");
            d.check(view.boundsOf("far").minY > 1000, "far down, out of view");
        });

        // A link to a fragment scrolls to it
        clickOn(d, view, "down");
        d.ui({
            d.expect(clicked, ["#far"], "the app heard about the link");
            const far = view.boundsOf("far");
            d.check(abs(far.minY) < 1, format!"scrolled to the top of it: %s"(far));
        });

        // One the app consumes isn't followed: it's still the same page, scrolled where it was
        d.ui({ view.scrollToFragment("out"); });
        d.settle();
        clickOn(d, view, "out");
        d.ui({
            d.expect(clicked, ["#far", "https://example.org/"], "the app heard about that one too");
            d.expect(view.title, "First page", "and it went nowhere");
        });

        // Narrower, it's laid out again: the paragraph wraps to more lines
        d.ui({ view.setPrefWidth(200); });
        d.settle();
        d.ui({
            const p = view.boundsOf("p");
            d.check(p.width <= 200, format!"as wide as the view is now: %s"(p));
            d.check(p.height > wide, format!"and taller, at %s than %s"(p.height, wide));
        });
    });
}

/// A LiteWebView showing files: what they refer to is relative to them, and a link to another
/// file loads it.
void files()
{
    const dir = buildPath(tempDir, format!"mayfair-web-%s"(cast(void*) &files));
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    const a = buildPath(dir, "a.html"), b = buildPath(dir, "b.html");
    write(buildPath(dir, "pic.png"), png);
    write(buildPath(dir, "style.css"), "#box { width: 123px; height: 45px; }");
    write(a, `<html><head><title>A</title><link rel="stylesheet" href="style.css"></head><body>
        <img id="pic" src="pic.png"> <div id="box"></div> <a id="next" href="b.html#end">B</a></body></html>`);
    write(b, `<title>B</title><a id="back" href="a.html">A</a><div style="height: 2000px"></div><p id="end">End</p>`);

    LiteWebView view;
    run("web: files", {
        view = new LiteWebView().prefSize(400, 300);
        view.load(a);
        return cast(Widget) new Column().padding(20).fillWidth(false).add(view);
    }, (Driver d) {
        d.ui({
            d.expect(view.title, "A", "the file's title");
            d.expect(view.location, a, "where it's from");
            const pic = view.boundsOf("pic");
            d.check(pic.width == 4 && pic.height == 2, format!"the picture beside it, at its own size: %s"(pic));
            const box = view.boundsOf("box");
            d.check(box.width == 123 && box.height == 45, format!"styled by the stylesheet beside it: %s"(box));
        });

        // A link to another file loads it, scrolled to its fragment
        clickOn(d, view, "next");
        d.ui({
            d.expect(view.title, "B", "the other file");
            d.expect(view.location, b, "from there");
            const end = view.boundsOf("end");
            d.check(end.minY >= 0 && end.maxY <= 300, format!"scrolled to the end: %s"(end));
        });

        // A file that isn't there throws, and leaves the page as it was
        d.ui({
            bool threw;
            try
                view.load(buildPath(dir, "missing.html"));
            catch (Exception)
                threw = true;
            d.check(threw, "loading a missing file throws");
            d.expect(view.title, "B", "and the page is the one it was");
        });

        d.ui({ view.scrollToFragment("back"); }); // at the top, scrolled out of view
        d.settle();
        clickOn(d, view, "back");
        d.ui({ d.expect(view.title, "A", "and back again, by a relative link"); });
    });
}
