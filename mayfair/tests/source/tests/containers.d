module tests.containers;

import core.time : msecs;
import std.exception : collectException;
import std.format : format;
import std.math : abs;
import harness;
import mayfair;

private bool near(float a, float b) { return abs(a - b) <= 0.5f; }

/// Stacks: as big as the biggest child, containers filling it, controls where alignment says,
/// re-laid out when a child changes, and clicks reaching what's on top.
void stacks()
{
    Stack stack;
    Widget back;
    Button front;
    int clicks;
    run("containers: stacks", {
        auto root = new Column().fillWidth(false).padding(20);
        back = new Widget().prefSize(200, 120);
        front = new Button("On top").onAction({ clicks++; });
        stack = new Stack();
        stack.add(back).add(front);
        root.add(stack);
        return cast(Widget) root;
    }, (Driver d) {
        Bounds s, f;
        d.ui({
            s = stack.boundsInScene;
            f = front.boundsInScene;
            d.expect(s.width, 200f, "as wide as its widest child");
            d.expect(s.height, 120f, "and as tall as its tallest");
            d.expect(back.boundsInScene, s, "a container fills it");
            d.check(near(f.centreX, s.centreX) && near(f.centreY, s.centreY), format!"a control in the middle: %s in %s"(f, s));
            d.check(f.width < 200, "at its own size");
        });
        d.click(front);
        d.ui({ d.expect(clicks, 1, "a click reaches the control on top"); });

        d.ui({ stack.setAlignment(Pos.bottomRight); });
        d.settle();
        d.ui({
            f = front.boundsInScene;
            d.check(near(f.maxX, s.maxX) && near(f.maxY, s.maxY), format!"alignment: bottom right, %s in %s"(f, s));
        });

        d.ui({ back.prefSize(300, 150); });
        d.settle();
        d.ui({
            d.expect(stack.boundsInScene.width, 300f, "a child growing grows it");
            d.expect(back.boundsInScene.height, 150f);
        });

        d.ui({ front.setText("A much longer label than it had before"); });
        d.settle();
        d.ui({
            f = front.boundsInScene;
            d.check(near(f.maxX, stack.boundsInScene.maxX), "a control's new size, placed again");
        });

        d.ui({ stack.remove(back); });
        d.settle();
        d.ui({ d.expect(stack.boundsInScene.width, front.boundsInScene.width, "taken out: as big as what's left"); });
    });
}

/// Docks: the parts around the edges at their own sizes, the centre with the rest, spacing
/// between, reading order in the tree, and parts replaced and removed.
void docks()
{
    Dock dock;
    Widget top, bottom, left, right, centre;
    Button save;
    run("containers: docks", {
        dock = new Dock().spacing(4);
        top = new Widget().prefHeight(40);
        bottom = new Widget().prefHeight(20);
        left = new Widget().prefWidth(100);
        right = new Widget().prefWidth(50);
        centre = new Widget();
        // Set out of order: the tree is in reading order regardless
        dock.centre(centre).bottom(bottom).right(right).left(left).top(top);
        return cast(Widget) dock;
    }, (Driver d) {
        Bounds all;
        d.ui({
            all = dock.boundsInScene;
            d.check(dock.children == [top, left, centre, right, bottom], "in reading order");
            d.expect(top.boundsInScene, Bounds(all.minX, all.minY, all.width, 40), "the top: full width, its own height");
            d.expect(bottom.boundsInScene, Bounds(all.minX, all.maxY - 20, all.width, 20), "the bottom");
            const middleTop = all.minY + 44, middleHeight = all.height - 40 - 20 - 8;
            d.expect(left.boundsInScene, Bounds(all.minX, middleTop, 100, middleHeight), "the left: its own width, between");
            d.expect(right.boundsInScene, Bounds(all.maxX - 50, middleTop, 50, middleHeight), "the right");
            d.expect(centre.boundsInScene, Bounds(all.minX + 104, middleTop, all.width - 100 - 50 - 8, middleHeight),
                     "the centre: what's left");
        });

        d.ui({
            save = new Button("Save");
            dock.setTop(save);
        });
        d.settle();
        d.ui({
            d.check(top.parent is null, "a part replaced is taken out");
            const b = save.boundsInScene;
            d.check(b.minX == all.minX && b.minY == all.minY && b.width < all.width,
                    format!"a control at the top left, at its own size: %s"(b));
            d.expect(left.boundsInScene.minY, b.maxY + 4, "the middle below it");
        });

        d.ui({
            dock.setLeft(null);
            dock.setRight(null);
        });
        d.settle();
        d.ui({ d.expect(centre.boundsInScene.width, all.width, "no sides: the centre is the full width"); });

        d.ui({ d.check(collectException(dock.add(new Widget)) !is null, "its parts are set by name, not add()"); });
    });
}

/// Grids: columns as wide as their widest, rows as tall as their tallest, labels lined up with
/// fields, spans, growing, alignment and fixed sizes, and wrapping text as tall as its column
/// makes it.
void grids()
{
    Grid grid;
    Label name, longer, note;
    TextField nameField, longerField;
    Button save;
    TextArea bioAlone;
    int saved;
    run("containers: grids", {
        auto root = new Column().padding(20);
        grid = new Grid().columnGap(12).rowGap(8);
        name = new Label("Name");
        longer = new Label("A longer label");
        nameField = new TextField();
        longerField = new TextField();
        save = new Button("Save").onAction({ saved++; });
        note = new Label("A note under the form, long enough that it has to wrap when the grid is narrow.")
            .wrapText(true);
        grid.addRow(0, name, nameField);
        grid.addRow(1, longer, longerField);
        grid.add(save, 1, 2);
        grid.add(note, 0, 3, 2);
        grid.column(1).grow(1);
        root.add(grid);
        return cast(Widget) root;
    }, (Driver d) {
        Bounds g;
        d.ui({
            g = grid.boundsInScene;
            d.expect(grid.columnCount, 2);
            d.expect(grid.rowCount, 4);
            const labels = longer.boundsInScene.width;
            d.expect(name.boundsInScene.minX, g.minX, "labels at the start of their column");
            d.expect(nameField.boundsInScene.minX, g.minX + labels + 12, "fields after the widest label and the gap");
            d.expect(longerField.boundsInScene.minX, nameField.boundsInScene.minX, "lined up");
            d.check(near(nameField.boundsInScene.maxX, g.maxX),
                    format!"the growing column takes the room to spare: %s in %s"(nameField.boundsInScene, g));
            d.check(near(name.boundsInScene.centreY, nameField.boundsInScene.centreY), "a label in the middle of its row");
            d.expect(longerField.boundsInScene.minY, nameField.boundsInScene.maxY + 8, "the next row, after the gap");
            d.expect(save.boundsInScene.minX, nameField.boundsInScene.minX, "a control at the start of its column");
            d.check(save.boundsInScene.width < nameField.boundsInScene.width, "and at its own size");
            d.expect(note.boundsInScene.minX, g.minX, "a span of two columns, from the first");
        });
        d.click(save);
        d.ui({ d.expect(saved, 1, "a click reaches a control in a grid"); });

        // Narrow: the label column keeps its labels, the field column gives way, and the note wraps
        float oneLine;
        d.ui({
            oneLine = note.boundsInScene.height;
            grid.setMaxWidth(220);
        });
        d.settle();
        d.ui({
            d.expect(grid.boundsInScene.width, 220f);
            d.expect(nameField.boundsInScene.minX, g.minX + longer.boundsInScene.width + 12, "labels aren't squeezed");
            d.check(note.boundsInScene.height > oneLine * 2, format!"the note wraps to the grid: %s"(note.boundsInScene));
            d.check(note.boundsInScene.maxY <= grid.boundsInScene.maxY + 0.5f, "and the grid is as tall as it now is");
        });

        d.ui({
            grid.setMaxWidth(float.nan);
            grid.column(0).prefSize(200).alignment(Alignment.end);
        });
        d.settle();
        d.ui({
            d.expect(nameField.boundsInScene.minX, g.minX + 200 + 12, "a fixed width");
            d.check(near(name.boundsInScene.maxX, g.minX + 200), "labels at the end of their column");
        });

        d.ui({ grid.add(save, 0, 2); });
        d.settle();
        d.ui({ d.check(near(save.boundsInScene.maxX, g.minX + 200), "moved to another cell"); });

        // A text area asks for its rows as a flex basis, which a cell has to honour as a column would
        TextArea bio;
        float columnHeight;
        d.ui({
            bio = new TextArea().prefRowCount(3);
            grid.add(bio, 1, 5);
            auto alone = new TextArea().prefRowCount(3);
            grid.scene.root.add(alone);
            bioAlone = alone;
        });
        d.settle();
        d.ui({
            d.expect(bio.boundsInScene.height, bioAlone.boundsInScene.height, "a text area in a grid: as tall as in a column");
            grid.remove(bio);
            grid.scene.root.remove(bioAlone);
        });

        // Nothing happening: nothing running. A container that took its own sizing of its
        // children's cells for a change in them laid out again every frame, forever.
        {
            import core.thread : Thread;
            import core.time : seconds;
            import core.sys.posix.time : clock_gettime, timespec, CLOCK_PROCESS_CPUTIME_ID;
            double cpu()
            {
                timespec t;
                clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t);
                return t.tv_sec + t.tv_nsec / 1e9;
            }
            d.settle();
            Thread.sleep(300.msecs); // anything that was under way, finished
            const before = cpu();
            Thread.sleep(1.seconds);
            const used = cpu() - before;
            d.check(used < 0.1, format!"idle, it does nothing: %.3f s of CPU in a second"(used));
        }

        d.ui({ grid.remove(note); });
        d.settle();
        d.ui({
            d.expect(grid.rowCount, 3, "a row with nothing left in it goes");
            d.check(collectException((cast(Widget) grid).add(new Widget)) !is null, "children go in at a cell, not with add()");
        });
    });
}
