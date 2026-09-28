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
            d.expect(root.boundsInScene.minY, b.maxY, "the root below the bar");
        });

        d.click(open);
        d.ui({ d.expect(opened, 1, "a button in it works"); });

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
