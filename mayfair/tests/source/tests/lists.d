module tests.lists;

import std.conv : to;
import std.format : format;
import std.math : abs;
import harness;
import mayfair;

// The rows a list has made, and which of them are showing something
private Widget[] rowsOf(Widget list)
{
    Widget[] found;
    void walk(Widget w)
    {
        if (cast(ListCell!string) w)
            found ~= w;
        foreach (c; w.children)
            walk(cast() c);
    }
    walk(list);
    return found;
}

/// Lists: ten thousand items with a screenful of rows; selecting by click and keys; End, and
/// scrolling half way, reusing the rows; activating; and the placeholder with none.
void listViews()
{
    ListView!string list;
    int[] activated;
    run("lists: list views", {
        string[] items;
        foreach (i; 0 .. 10_000)
            items ~= format!"Item %d"(i);
        list = new ListView!string(items).onActivate((int i) { activated ~= i; });
        return cast(Widget) new Column().padding(20).fillWidth(false).add(list);
    }, (Driver d) {
        size_t made;
        d.ui({
            made = rowsOf(list).length;
            d.check(made > 5 && made < 40, format!"a screenful of rows, not ten thousand: %s"(made));
        });

        ListCell!string third;
        d.ui({
            foreach (w; rowsOf(list))
                if (auto c = cast(ListCell!string) w)
                    if (c.visible && c.index == 2)
                        third = c;
        });
        d.click(third);
        d.ui({
            d.expect(list.selectedIndex, 2, "a click selects its row");
            d.check(third.isSelected, ":selected on it");
            d.check(list.focused, "and the list has focus");
        });
        d.key(SDL_Keycode.SDLK_DOWN);
        d.ui({ d.expect(list.selectedItem, "Item 3", "Down: the next"); });

        d.key(SDL_Keycode.SDLK_END);
        d.settle();
        d.ui({
            d.expect(list.selectedIndex, 9999, "End: the last");
            bool shown;
            foreach (w; rowsOf(list))
                if (auto c = cast(ListCell!string) w)
                    if (c.visible && c.index == 9999)
                        shown = c.boundsInScene.maxY <= list.boundsInScene.maxY + 0.5f;
            d.check(shown, "made, and scrolled into view");
            d.check(rowsOf(list).length <= made + 2, format!"with the rows it had: %s"(rowsOf(list).length));
        });

        // Half way down: rows from the middle, and no more of them
        d.ui({ (cast(ScrollPane) list.children[0].children[0]).setVvalue(0.5); });
        d.settle();
        d.ui({
            size_t lowest = size_t.max;
            foreach (w; rowsOf(list))
                if (auto c = cast(ListCell!string) w)
                    if (c.visible && c.index < lowest)
                        lowest = c.index;
            d.check(lowest > 4900 && lowest < 5000, format!"showing the middle: from %s"(lowest));
        });

        d.ui({ list.setSelectedIndex(0); list.scrollTo(0); });
        d.settle();
        d.ui({
            foreach (w; rowsOf(list))
                if (auto c = cast(ListCell!string) w)
                    if (c.visible && c.index == 1)
                        third = c;
        });
        d.click(third);
        d.click(third, float.nan, 2);
        d.ui({ d.expect(activated, [1], "a double click activates"); });
        d.key(SDL_Keycode.SDLK_RETURN);
        d.ui({ d.expect(activated, [1, 1], "and Enter"); });

        d.ui({ list.setItems(null); });
        d.settle();
        d.ui({
            d.expect(list.selectedIndex, -1, "no items, nothing selected");
            size_t showing;
            foreach (w; rowsOf(list))
                if (w.visible)
                    showing++;
            d.expect(showing, 0, "and no rows showing");
        });
    });
}

private struct City { string name; int people; string country; }

/// Tables: a screenful of rows under a header; a click on a header sorting by it, then the other
/// way, then not, keeping the selection; dragging a header's edge; and the header scrolling
/// sideways with the rows.
void tableViews()
{
    TableView!City table;
    TableColumn!City name, people, country;
    run("lists: table views", {
        City[] cities;
        foreach (i; 0 .. 1000)
            cities ~= City(format!"City %03d"(i), (i * 7919) % 100_000, i % 2 ? "England" : "Scotland");
        name = new TableColumn!City("Name", (City c) => c.name);
        people = new TableColumn!City("People", (City c) => c.people.to!string).alignment(Alignment.end);
        country = new TableColumn!City("Country", (City c) => c.country);
        table = new TableView!City(cities).prefSize(420, 260);
        table.add(name).add(people).add(country);
        return cast(Widget) new Column().padding(20).fillWidth(false).add(table);
    }, (Driver d) {
        // A column's header: the header button saying its title
        Widget headerOf(TableColumn!City c)
        {
            Widget found;
            void walk(Widget w)
            {
                if (auto b = cast(ButtonBase) w)
                    if (b.styleClass.contains("column-header") && b.text == c.title)
                        found = b;
                foreach (child; w.children)
                    walk(cast() child);
            }
            walk(table);
            return found;
        }
        Widget[] rows()
        {
            Widget[] found;
            void walk(Widget w)
            {
                if (w.styleClass.contains("table-row"))
                    found ~= w;
                foreach (c; w.children)
                    walk(cast() c);
            }
            walk(table);
            return found;
        }
        d.ui({
            d.check(rows.length > 3 && rows.length < 30, format!"a screenful of rows: %s"(rows.length));
            d.check(headerOf(name).boundsInScene.maxY <= table.boundsInScene.minY + 50, "the header at the top");
        });

        d.ui({ table.setSelectedIndex(0); }); // City 000
        d.click(headerOf(people));
        d.ui({
            d.check(table.sortColumn is people && table.sortAscending, "a click on a header sorts by it");
            d.expect(table.itemAt(0).people, 0, "smallest first, as numbers");
            d.expect(table.selectedItem.name, "City 000", "the selection stays with its item");
        });
        d.click(headerOf(people));
        d.ui({ d.check(table.itemAt(0).people > table.itemAt(1).people, "again: the other way"); });
        d.click(headerOf(people));
        d.ui({
            d.check(table.sortColumn is null, "a third time: not sorted");
            d.expect(table.itemAt(5).name, "City 005", "the items' own order");
        });

        // Dragging the Name header's right edge, 60 points out
        float before;
        Bounds h;
        d.ui({ before = name.width; h = headerOf(name).boundsInScene; });
        d.press(h.maxX - 2, h.centreY);
        d.move(h.maxX + 30, h.centreY);
        d.move(h.maxX + 58, h.centreY);
        d.release(h.maxX + 58, h.centreY);
        d.settle();
        d.ui({
            d.check(abs(name.width - (before + 60)) < 1, format!"the edge dragged: %s to %s"(before, name.width));
            d.check(table.sortColumn is null, "without sorting");
        });

        // Wider than the table: scrolled across, the header goes with the rows
        d.ui({ name.width(600); });
        d.settle();
        d.ui({
            auto pane = cast(ScrollPane) table.children[1].children[0];
            pane.setHvalue(1);
        });
        d.settle();
        d.ui({
            Widget firstCell;
            foreach (r; rows)
                if (r.visible)
                {
                    firstCell = cast() r.children[0];
                    break;
                }
            d.expect(headerOf(name).boundsInScene.minX, firstCell.boundsInScene.minX, "the header scrolled with the rows");
            d.check(headerOf(name).boundsInScene.minX < table.boundsInScene.minX, "off to the left");
        });
    });
}
