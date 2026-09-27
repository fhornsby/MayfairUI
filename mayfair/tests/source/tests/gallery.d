module tests.gallery;

import std.format : format;
import harness;
import mayfair;
import gallery : buildGallery;

// The first widget of type T at or below `w`, in tree order
private T find(T)(Widget w)
{
    if (auto t = cast(T) w)
        return t;
    foreach (child; w.children)
        if (auto found = find!T(cast() child))
            return found;
    return null;
}

// Every button at or below `w`
private Button[] buttonsIn(Widget w)
{
    Button[] found;
    if (auto b = cast(Button) w)
        found ~= b;
    foreach (child; w.children)
        found ~= buttonsIn(cast() child);
    return found;
}

// The heading of the page the gallery's showing
private string shownPage(Dock dock)
{
    auto pane = cast(ScrollPane) dock.centre;
    if (!pane || !pane.content)
        return null;
    auto heading = cast(Label) pane.content.children[0];
    return heading ? heading.text : null;
}

/// The gallery: every page in the sidebar shows, and it still does after using the controls on one.
void navigation()
{
    Dock dock;
    run("gallery: navigation", {
        dock = buildGallery();
        return cast(Widget) dock;
    }, (Driver d) {
        NavigationItem[] items;
        d.ui({
            foreach (child; dock.left.children)
                items ~= cast(NavigationItem) child;
            d.expect(items.length, 11, "a page for each part of the kit");
        });

        foreach (item; items)
        {
            d.click(item);
            d.ui({ d.expect(shownPage(dock), item.text, "the page clicked on"); });
        }

        // The last page's controls: type in a field, drag a slider, tick a box
        TextField first;
        Slider slider;
        CheckBox tick;
        d.ui({
            first = find!TextField(dock.centre);
            slider = find!Slider(dock.centre);
            tick = find!CheckBox(dock.centre);
        });
        d.click(first);
        d.type(" Byron");
        Bounds b;
        d.ui({
            d.expect(first.text, "Ada Byron", "typed into the field");
            b = slider.boundsInScene;
        });
        d.press(b.minX + 20, b.centreY);
        d.move(b.minX + 120, b.centreY);
        d.release(b.minX + 120, b.centreY);
        d.click(tick);

        foreach (item; items)
        {
            d.click(item);
            d.ui({ d.expect(shownPage(dock), item.text, "still navigable after using a page: " ~ item.text); });
        }

        // The keypad, whose keys are made in a loop too: each says which it is
        d.click(items[6]); // Layout
        Button five, zero;
        d.ui({
            foreach (b; buttonsIn(dock.centre))
            {
                if (b.text == "5") five = b;
                if (b.text == "0") zero = b;
            }
            five.scrollIntoView();
        });
        d.settle();
        d.click(five);
        d.ui({ d.expect((cast(Label) dock.bottom).text, "Key 5", "each key its own"); });
        d.ui({ zero.scrollIntoView(); });
        d.settle();
        d.click(zero);
        d.ui({ d.expect((cast(Label) dock.bottom).text, "Key 0"); });
    });
}
