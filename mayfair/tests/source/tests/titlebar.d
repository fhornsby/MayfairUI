module tests.titlebar;

import core.thread : Thread;
import core.time : msecs;
import std.format : format;
import std.math : abs;
import harness;
import mayfair;

// The first widget below `w` that `pred` picks out
private Widget findIn(Widget w, bool delegate(Widget) pred)
{
    if (pred(w))
        return w;
    foreach (c; w.children)
        if (auto f = findIn(cast() c, pred))
            return f;
    return null;
}

/// A title bar of the app's own: its title in the middle of the window, what's added at either
/// end, the window's buttons, a button in it working, maximising and restoring, and the root below it.
void titleBars()
{
    Column root;
    TitleBar bar;
    Button open;
    int opened;
    run("title bar: an app's own", {
        root = new Column().padding(20);
        root.add(new Label("Content"));
        return cast(Widget) root;
    }, (Driver d) {
        d.ui({
            open = new Button("Open").onAction({ opened++; });
            bar = new TitleBar("Documents").addStart(open).addEnd(new Button("Share"));
            root.scene.titleBar(bar);
        });
        d.settle();
        Label title;
        WindowButton maximise;
        d.ui({
            title = cast(Label) findIn(bar, (w) => cast(Label) w && w.styleClass.contains("title"));
            maximise = cast(WindowButton) findIn(bar, (w) => cast(WindowButton) w && w.accessibleText == "Maximise");
            const b = bar.boundsInScene, t = title.boundsInScene;
            d.check(abs(t.centreX - b.centreX) <= 1, format!"the title in the middle of the window: %s in %s"(t, b));
            d.expect(title.text, "Documents");
            d.check(open.boundsInScene.minX < t.minX, "what's added at the start, before it");
            d.check(maximise !is null, "the window's buttons, as the desktop has them");
            if (!maximise)
                return;
            d.expect(root.boundsInScene.minY, b.maxY, "the root below the bar");
        });

        d.click(open);
        d.ui({ d.expect(opened, 1, "a button in it works"); });
        if (!maximise)
            return; // no window buttons to try

        d.click(maximise);
        Thread.sleep(600.msecs);
        d.settle();
        d.ui({ d.expect(maximise.accessibleText, "Restore", "maximised, the button restores"); });
        d.click(maximise);
        Thread.sleep(600.msecs);
        d.settle();
        d.ui({ d.expect(maximise.accessibleText, "Maximise", "and restored, it maximises again"); });

        // The bar where there's nothing: a click leaves the window be, a double click maximises it
        // (measured afresh each time: maximised, the frame's margin goes and the bar moves up)
        float emptyX, emptyY;
        void findEmpty()
        {
            d.ui({
                emptyX = (open.boundsInScene.maxX + title.boundsInScene.minX) / 2;
                emptyY = bar.boundsInScene.centreY;
            });
        }
        findEmpty();
        d.click(emptyX, emptyY);
        Thread.sleep(600.msecs);
        d.settle();
        d.ui({ d.expect(maximise.accessibleText, "Maximise", "a click on the bar doesn't maximise"); });
        d.click(emptyX, emptyY, 2);
        Thread.sleep(600.msecs);
        d.settle();
        d.ui({ d.expect(maximise.accessibleText, "Restore", "a double click on the bar maximises"); });
        findEmpty();
        d.click(emptyX, emptyY);
        d.click(emptyX, emptyY, 2);
        Thread.sleep(600.msecs);
        d.settle();
        d.ui({ d.expect(maximise.accessibleText, "Maximise", "and another restores"); });
    });
}

/*
    A title bar over a sidebar, in the Oriel theme: its glass (the first layer) over the sidebar
    only, and the page's colour beside it, following the sidebar as it's hidden and resized; the
    compositor asked to blur behind that much of it; and the glass translucent with the window.
*/
void sidebarGlass()
{
    // A root that can be put in :translucent, as the App does where the compositor blurs
    static class Root : Dock
    {
        void translucent(bool on) { pseudoClassStateChanged(pseudo!"translucent", on); }
    }
    Root root;
    Column side;
    TitleBar bar;
    run("title bar: over a sidebar", {
        root = new Root();
        side = new Column().prefWidth(180).minWidth(180).maxWidth(180);
        side.styleClass.add("sidebar");
        side.add(new Label("Sidebar"));
        auto page = new Column().grow(1);
        page.styleClass.add("page");
        page.add(new Label("Page"));
        root.setLeft(side);
        root.setCentre(page);
        return cast(Widget) root;
    }, (Driver d) {
        d.ui({
            bar = new TitleBar("Documents").sidebar(side);
            root.scene.titleBar(bar);
            root.scene.stylesheets.add(orielStylesheet);
        });
        d.settle();
        void layers(float glass, string what)
        {
            d.ui({
                const w = bar.boundsInScene.width;
                d.check(bar.background.fills.length == 2, "the Oriel title bar's two layers");
                if (bar.background.fills.length != 2)
                    return;
                const g = bar.backgroundInsets(0, w), p = bar.backgroundInsets(1, w);
                d.check(abs((w - g.right) - glass) <= 1, format!"%s: the glass %s across, not %s"(what, glass, w - g.right));
                d.check(abs(p.left - glass) <= 1, format!"%s: the page's colour from %s, not %s"(what, glass, p.left));
            });
        }
        float edge = 0;
        d.ui({ edge = side.boundsInScene.maxX - bar.boundsInScene.minX; });
        d.check(edge > 170, format!"the sidebar laid out: %s"(edge));
        layers(edge, "over the sidebar");

        // Blurred behind: the compositor's asked to blur where the first layer is (Scene.backdropBlurRegion
        // takes it from backgroundInsets, as above), so over the sidebar only
        d.ui({ d.check(bar.backdropBlur && side.backdropBlur, "the bar and the sidebar both glass"); });

        // Hidden: the page's colour all the way across; back, wider: the glass with it
        d.ui({ root.setLeft(null); });
        d.settle();
        layers(0, "with the sidebar hidden");
        d.ui({
            side.setPrefWidth(260);
            side.setMinWidth(260);
            side.setMaxWidth(260);
            root.setLeft(side);
        });
        d.settle();
        d.ui({ edge = side.boundsInScene.maxX - bar.boundsInScene.minX; });
        layers(edge, "with the sidebar back, wider");
        d.check(edge > 250, format!"wider: %s"(edge));

        // The window translucent: the glass is, the page beside it isn't. The bar isn't below the
        // root, whose variables it takes, so it has to be restyled with it
        Colour before;
        d.ui({ before = bar.background.fills[0].fill; root.translucent(true); });
        d.settle();
        d.ui({
            const glass = bar.background.fills[0].fill, page = bar.background.fills[1].fill;
            d.check(glass.a < 255 && glass != before, format!"the bar's glass translucent: %s, was %s"(glass, before));
            d.expect(page.a, 255, "the page's colour beside it opaque");
            d.check(side.background.fills.length && side.background.fills[0].fill == glass,
                    "the sidebar's colour, up to the top of the window");
        });
        d.ui({ root.translucent(false); });
        d.settle();
        d.ui({ d.expect(bar.background.fills[0].fill, before, "opaque again, with the window"); });
    });
}
