module tests.buttons;

import harness;
import mayfair;

/// Clicking a button fires it; pressing, dragging off and letting go takes the press back;
/// dragging back on before letting go fires it after all. Hover and click events along the way.
void clicking()
{
    Button b;
    int actions, clicked, entered, exited;
    run("button: click, drag off, drag back on", {
        auto root = new Column();
        YGNodeStyleSetAlignItems(root.node, YGAlignFlexStart);
        b = new Button("Press");
        b.onAction({ actions++; });
        b.onMouseClicked((ref e) { clicked++; })
         .onMouseEntered((ref e) { entered++; })
         .onMouseExited((ref e) { exited++; });
        root.add(b);
        return cast(Widget) root;
    }, (Driver d) {
        Bounds bb;
        d.ui({ bb = b.boundsInScene; });
        const x = bb.centerX, y = bb.centerY;

        d.click(x, y);
        d.ui({ d.expect(actions, 1, "a click fires"); });

        d.move(x, y);
        d.press(x, y);
        d.move(400, 300);
        d.release(400, 300);
        d.ui({
            d.expect(actions, 1, "released off the button");
            d.check(!b.hover && !b.pressed, "neither hovered nor pressed after");
        });

        d.move(x, y);
        d.press(x, y);
        d.move(400, 300);
        d.move(x + 1, y + 1);
        d.release(x + 1, y + 1);
        d.ui({
            d.expect(actions, 2, "dragged off and back on");
            d.expect(clicked, 2, "clicks");
            d.expect(entered, 3, "enters");
            d.expect(exited, 2, "exits");
        });
    });
}
