module tests.splitpane;

import std.format : format;
import std.math : abs;
import harness;
import mayfair;

/// A split pane shares its width between its children as its dividers say: dragged, stopped by a
/// child's minimum, a sidebar keeping its width as the pane grows, a hidden child giving its room
/// to the others; and the same, one above another, from a view.
void splitPane()
{
    SplitPane split;
    Widget a, b, c;
    float[] heard;
    run("split pane: dividers, dragging, keeping a size", {
        a = new Column().minWidth(120);
        b = new Column();
        c = new Column().minWidth(100);
        split = new SplitPane().prefSize(805, 300);
        split.add(a, keepSize: true).add(b).add(c);
        split.setDividerPositions([0.25f, 0.75f]);
        split.dividerPositionsProperty.addListener((float[] was, float[] now) { heard = now.dup; });
        return cast(Widget) new Column().padding(20).fillWidth(false).add(split);
    }, (Driver d) {
        Bounds p, ba, bb, bc;
        void measure() { d.ui({ p = split.boundsInScene; ba = a.boundsInScene; bb = b.boundsInScene; bc = c.boundsInScene; }); }
        bool near(float x, float y) { return abs(x - y) <= 1; }
        measure();
        // 805 less two dividers of 5 is 795: a quarter, a half and a quarter of it
        d.check(near(ba.width, 198.75f) && near(bb.width, 397.5f) && near(bc.width, 198.75f),
                format!"shared as the positions say: %s %s %s"(ba.width, bb.width, bc.width));
        d.check(near(bb.minX, ba.maxX + 5) && near(bc.minX, bb.maxX + 5), "a divider between each");
        d.ui({ d.expect(split.panes.length, 3, "its panes are its children less its dividers"); });

        // Dragging the first divider 100 points right
        const x = ba.maxX + 2, y = p.centreY;
        d.move(x, y);
        d.press(x, y);
        d.move(x + 50, y);
        d.move(x + 100, y);
        d.release(x + 100, y);
        measure();
        d.check(near(ba.width, 298.75f) && near(bb.width, 297.5f), format!"dragged: %s %s"(ba.width, bb.width));
        d.check(heard.length == 2 && abs(heard[0] - 303.75f / 795) < 0.01f, format!"listeners heard: %s"(heard));

        // Into the third child's minimum: it stops there
        const x2 = bb.maxX + 2;
        d.press(x2, y);
        d.move(x2 + 400, y);
        d.release(x2 + 400, y);
        measure();
        d.check(near(bc.width, 100), format!"stopped by the minimum: %s"(bc.width));

        // Wider: the first keeps its width, the others share what's gained
        const before = ba.width, middle = bb.width, last = bc.width;
        d.ui({ split.setPrefWidth(1005); });
        d.settle();
        measure();
        d.check(near(ba.width, before), format!"kept its size: %s, was %s"(ba.width, before));
        d.check(near(bb.width + bc.width, middle + last + 200), format!"the rest grew: %s %s"(bb.width, bc.width));

        // The middle one hidden: the others share its room, and get it back
        float shownA, shownC;
        d.ui({ b.setVisible(false); });
        d.settle();
        measure();
        d.check(near(ba.width + bc.width, 1005 - 5), format!"hidden: the rest share its room: %s %s"(ba.width, bc.width));
        d.ui({ b.setVisible(true); });
        d.settle();
        measure();
        d.check(near(ba.width, before) && bb.width > 100, format!"shown again: %s %s %s"(ba.width, bb.width, bc.width));
    });

    SplitPane stacked;
    run("split pane: one above another, from a view", {
        stacked = View.parse!(`
            <SplitPane id="split" orientation="vertical" dividerPositions="0.3" prefWidth="300" prefHeight="405">
                <Column><Label text="Top"/></Column>
                <Column><Label text="Bottom"/></Column>
            </SplitPane>`)();
        return cast(Widget) new Column().padding(20).fillWidth(false).add(stacked);
    }, (Driver d) {
        d.ui({
            auto s = stacked;
            auto top = s.panes[0], bottom = s.panes[1];
            d.check(abs(top.boundsInScene.height - 120) <= 1 && abs(bottom.boundsInScene.height - 280) <= 1,
                    format!"vertical, as the view says: %s %s"(top.boundsInScene.height, bottom.boundsInScene.height));
            d.check(abs(bottom.boundsInScene.minY - top.boundsInScene.maxY - 5) <= 1, "the divider between them");
        });
    });
}
