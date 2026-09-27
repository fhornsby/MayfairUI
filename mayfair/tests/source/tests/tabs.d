module tests.tabs;

import std.format : format;
import harness;
import mayfair;

// The headers in a tab pane's strip, in order
private TabHeader[] headersOf(TabPane pane)
{
    TabHeader[] found;
    void walk(Widget w)
    {
        if (auto h = cast(TabHeader) w)
            found ~= h;
        else
            foreach (child; w.children)
                walk(cast() child);
    }
    walk(pane.children[0]);
    return found;
}

/// Tab panes: the first tab shown, a click showing another, only the shown page in the tree, the
/// keys, closing, and inserting before the selected tab.
void tabPanes()
{
    TabPane pane;
    Tab one, two, three;
    Button inOne;
    TextField inTwo;
    string[] closed;
    run("tabs: tab panes", {
        pane = new TabPane().prefSize(400, 200);
        inOne = new Button("In one");
        inTwo = new TextField("in two");
        one = new Tab("One", new Column().padding(8).add(inOne));
        two = new Tab("Two", new Column().padding(8).add(inTwo)).closable(true).onClosed({ closed ~= "Two"; });
        three = new Tab("Three", new Label("Three's page")).closable(true).onClosed({ closed ~= "Three"; });
        pane.add(one).add(two).add(three);
        return cast(Widget) new Column().padding(20).fillWidth(false).add(pane);
    }, (Driver d) {
        d.ui({
            d.expect(pane.selectedIndex, 0, "the first tab, to start with");
            d.check(one.selected && inOne.scene !is null, "its page shown");
            d.check(two.content.parent is null && inTwo.scene is null, "the others not in the tree at all");
            d.expect(headersOf(pane).length, 3);
        });

        d.click(headersOf(pane)[1]);
        d.ui({
            d.expect(pane.selectedIndex, 1, "a click shows its tab");
            d.check(inTwo.scene !is null && inOne.scene is null, "and swaps the page");
            d.check(headersOf(pane)[1].isSelected && !headersOf(pane)[0].isSelected, ":selected moves with it");
        });

        // From inside the page, Ctrl+Page Down and Up go along the tabs
        d.click(inTwo);
        d.key(SDL_Keycode.SDLK_PAGEDOWN, SDL_Keymod.KMOD_LCTRL);
        d.ui({ d.expect(pane.selectedIndex, 2, "Ctrl+Page Down: the next tab"); });
        d.ui({ d.check(headersOf(pane)[2].focused, "focus in a page that went goes to its tab"); });
        d.key(SDL_Keycode.SDLK_PAGEDOWN, SDL_Keymod.KMOD_LCTRL);
        d.ui({ d.expect(pane.selectedIndex, 0, "and round to the first"); });

        // On the tabs, Left and Right
        d.ui({ headersOf(pane)[0].requestFocus(); });
        d.key(SDL_Keycode.SDLK_RIGHT);
        d.ui({
            d.expect(pane.selectedIndex, 1, "Right: the next tab");
            d.check(headersOf(pane)[1].focused, "with focus");
        });
        d.key(SDL_Keycode.SDLK_LEFT);
        d.key(SDL_Keycode.SDLK_LEFT);
        d.ui({ d.expect(pane.selectedIndex, 2, "Left from the first goes round to the last"); });

        // Closing: Ctrl+W on a closable tab, and its close button
        d.key(SDL_Keycode.SDLK_W, SDL_Keymod.KMOD_LCTRL);
        d.ui({
            d.expect(pane.tabs.length, 2, "Ctrl+W closes it");
            d.expect(closed, ["Three"], "and says so");
            d.expect(pane.selectedIndex, 1, "the one before it selected, as it was the last");
        });
        Button close;
        d.ui({
            foreach (child; headersOf(pane)[1].children)
                if (auto b = cast(Button) child)
                    close = b;
        });
        d.click(close);
        d.ui({
            d.expect(pane.tabs.length, 1, "its close button closes it");
            d.expect(closed, ["Three", "Two"]);
            d.expect(pane.selectedTab.text, "One", "and what's left is shown");
        });

        // Inserting before the selected tab keeps the same tab selected
        d.ui({ pane.insert(0, new Tab("Zero", new Label("Zero's page"))); });
        d.ui({
            d.expect(pane.selectedTab.text, "One", "still One");
            d.expect(headersOf(pane)[0].text, "Zero", "the new tab first in the strip");
        });
        d.ui({
            pane.remove(pane.selectedTab);
            pane.remove(pane.selectedTab);
        });
        d.ui({ d.expect(pane.selectedIndex, -1, "no tabs, nothing selected"); });
    });
}

/// Navigation lists: the first selected, a click selecting, a second click leaving it so, and the
/// arrow keys, Home and End.
void navigationLists()
{
    NavigationList list;
    int[] changes;
    run("tabs: navigation lists", {
        list = new NavigationList().add("Wi-Fi", "network-wireless-symbolic").add("Bluetooth")
            .add("Displays").add("Sound");
        list.selectedIndexProperty.addListener((int was, int now) { changes ~= now; });
        return cast(Widget) new Column().padding(20).fillWidth(false).add(list.prefWidth(200));
    }, (Driver d) {
        NavigationItem item(int i) { return cast(NavigationItem) list.children[i]; }
        d.ui({
            d.expect(list.selectedIndex, 0, "the first, to start with");
            d.check(item(0).isSelected, ":selected on it");
            d.expect(item(0).boundsInScene.width, list.boundsInScene.width - 12, "each entry the list's width, inside its padding");
        });
        d.click(item(2));
        d.ui({ d.expect(list.selectedIndex, 2, "a click selects"); });
        d.click(item(2));
        d.ui({
            d.expect(list.selectedIndex, 2, "and clicking it again leaves it selected");
            d.expect(changes, [2], "without a change in between");
        });
        d.key(SDL_Keycode.SDLK_DOWN);
        d.ui({ d.expect(list.selectedIndex, 3, "Down: the next"); });
        d.key(SDL_Keycode.SDLK_DOWN);
        d.ui({ d.expect(list.selectedIndex, 3, "and no further than the last"); });
        d.key(SDL_Keycode.SDLK_HOME);
        d.ui({
            d.expect(list.selectedIndex, 0, "Home: the first");
            d.check(item(0).focused, "with focus");
        });
        d.key(SDL_Keycode.SDLK_END);
        d.key(SDL_Keycode.SDLK_UP);
        d.ui({ d.expect(list.selectedIndex, 2, "End, then Up"); });
    });
}
