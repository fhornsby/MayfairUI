module tests.subpixel;

import harness;
import mayfair;
import mayfair.text.raster : Behind;

/*
    What's behind a widget's text, which subpixel text is mixed with as it's drawn: the window's
    fill, an ancestor's background, a translucent one mixed over it, and a new colour followed.
*/
void behindText()
{
    Label onWindow, onPanel, onTint;
    Column panel;
    run("text: what's behind it, for subpixel text", {
        auto root = new Column().spacing(8).padding(8);
        onWindow = new Label("on the window");
        panel = new Column().padding(4).style("background-colour: #ffffff");
        onPanel = new Label("on a white panel");
        auto tint = new Column().padding(4).style("background-colour: rgba(0, 0, 0, 0.2)");
        onTint = new Label("tinted");
        tint.add(onTint);
        panel.add(onPanel).add(tint);
        root.add(onWindow).add(panel);
        return cast(Widget) root;
    }, (Driver d) {
        d.ui({
            d.expect(onWindow.behind, Behind.solid(onWindow.scene.fill), "the window's fill");
            d.expect(onPanel.behind, Behind.solid(Colour(255, 255, 255)), "its parent's background");
            d.expect(onTint.behind, Behind.solid(Colour(204, 204, 204)), "a translucent one mixed over it");
            panel.style("background-colour: #000080");
        });
        d.settle();
        d.ui({
            d.expect(onPanel.behind, Behind.solid(Colour(0, 0, 128)), "drawn again over the new colour");
            d.expect(onTint.behind, Behind.solid(Colour(0, 0, 102)), "and what's inside it");
        });
    });
}
