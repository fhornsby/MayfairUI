module tests.dragdrop;

import std.format : format;
import harness;
import mayfair;

/// Dragging files and text in from another app: entered, over and exited as the drag moves over
/// widgets, and dropped -- with everything dropped -- only where a drag over was accepted.
void dropping()
{
    Label zone, plain;
    Column root;
    string[] happened;   // the zone's events, in order
    string[] files;
    string text;
    int rootOvers, rootDrops;
    run("drag and drop: files and text from another app", {
        root = new Column().padding(16).spacing(16).fillWidth(false);
        zone = new Label("Drop here").prefSize(200, 80);
        plain = new Label("Not here").prefSize(200, 80);
        zone.onDragEntered((ref e) { happened ~= "entered"; })
            .onDragExited((ref e) { happened ~= "exited"; })
            .onDragOver((ref e) {
                happened ~= "over";
                if (e.dragboard.hasFiles || e.dragboard.hasText)
                    e.acceptTransferModes(TransferMode.copy);
                e.consume();
            })
            .onDragDropped((ref e) {
                happened ~= "dropped";
                files = e.dragboard.files.dup;
                text = e.dragboard.text;
                e.setDropCompleted(true);
                e.consume();
            });
        // Bubbled to: hears what the zone doesn't consume
        root.onDragOver((ref e) { rootOvers++; })
            .onDragDropped((ref e) { rootDrops++; });
        root.add(zone).add(plain);
        return cast(Widget) root;
    }, (Driver d) {
        Bounds z, p;
        d.ui({ z = zone.boundsInScene; p = plain.boundsInScene; });

        // Two files, dragged over the zone and dropped on it
        d.dragOver(z.centreX, z.centreY);
        d.ui({
            d.expect(happened, ["entered", "over"], "dragged on");
            d.check(zone.draggedOver, "the zone knows it's dragged over");
            d.expect(rootOvers, 0, "the zone consumed over");
        });
        d.dragOver(z.centreX + 5, z.centreY);
        d.dropFiles(z.centreX + 5, z.centreY, "/home/me/a.txt", "/home/me/b c.png");
        d.ui({
            // over as it's dragged there, again as dropFiles moves it there, and again as it's
            // dropped, to see that it's still accepted
            d.expect(happened, ["entered", "over", "over", "over", "over", "dropped", "exited"], "dropped on");
            d.expect(files, ["/home/me/a.txt", "/home/me/b c.png"], "both files, in one drop");
            d.check(text is null, "no text");
            d.check(!zone.draggedOver && !root.draggedOver, "over nothing after");
            d.expect(rootDrops, 0, "the zone consumed dropped");
        });

        // Far more files than the input queue has room for events: each is one SDL event, but the
        // drop takes one place in the queue
        string[] many;
        foreach (i; 0 .. 200)
            many ~= format!"/home/me/photos/%03d.jpg"(i);
        d.dropFiles(z.centreX, z.centreY, many);
        d.ui({
            d.expect(files.length, 200, "every file of a big drop");
            d.check(files.length == 200 && files[0] == many[0] && files[199] == many[199], "in order");
            d.check(!zone.draggedOver, "over nothing after");
        });

        // Text
        happened = null;
        d.dropText(z.centreX, z.centreY, "some words\r\nand more");
        d.ui({
            d.expect(happened, ["entered", "over", "over", "dropped", "exited"], "text dropped");
            d.expect(text, "some words\nand more", "the text, its lines put back together");
            d.check(files.length == 0, "no files");
        });

        // Dropped somewhere that didn't accept it: the root hears over, bubbled, but nothing's dropped
        happened = null;
        d.dropFiles(p.centreX, p.centreY, "/home/me/a.txt");
        d.ui({
            d.check(happened.length == 0, "the zone heard nothing");
            d.check(rootOvers > 0, "over bubbled to the root");
            d.expect(rootDrops, 0, "nothing accepted it, so nothing's dropped");
        });

        // Over the zone, then off it, then out of the window with nothing dropped
        happened = null;
        d.dragOver(z.centreX, z.centreY);
        d.dragOver(p.centreX, p.centreY);
        d.dragLeave();
        d.ui({
            d.expect(happened, ["entered", "over", "exited"], "dragged across and away");
            d.check(!root.draggedOver, "over nothing after");
        });

        // A disabled widget hears nothing
        happened = null;
        d.ui({ zone.disable(true); });
        d.dropText(z.centreX, z.centreY, "ignored");
        d.ui({
            d.check(happened.length == 0, "disabled");
            zone.disable(false);
        });
    });
}
