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

/// Selecting any number: Ctrl+click adding and taking away, Shift+click a range from the anchor,
/// Ctrl+Shift adding one; the keys, with Shift a range and with Ctrl moving without selecting;
/// Ctrl+Space and Ctrl+A; one at a time again; and a table's selection staying with its items when sorted.
void multipleSelection()
{
    ListView!string list;
    TableView!City table;
    int changes;
    int[] activated;
    run("lists: selecting any number", {
        string[] items;
        foreach (i; 0 .. 100)
            items ~= format!"Item %d"(i);
        list = new ListView!string(items).selectionMode(SelectionMode.multiple)
            .onSelectionChanged({ changes++; }).onActivate((int i) { activated ~= i; });
        City[] cities;
        foreach (i; 0 .. 20)
            cities ~= City(format!"City %02d"(i), (i * 37) % 100, "England");
        table = new TableView!City(cities).selectionMode(SelectionMode.multiple).prefSize(300, 200);
        table.add(new TableColumn!City("Name", (City c) => c.name))
             .add(new TableColumn!City("People", (City c) => c.people.to!string));
        return cast(Widget) new Row().padding(20).spacing(20).add(list).add(table);
    }, (Driver d) {
        ListCell!string cell(size_t index)
        {
            foreach (w; rowsOf(list))
                if (auto c = cast(ListCell!string) w)
                    if (c.visible && c.index == index)
                        return c;
            return null;
        }
        void clickRow(size_t index, SDL_Keymod mods = SDL_Keymod.KMOD_NONE)
        {
            ListCell!string c;
            d.ui({ c = cell(index); });
            d.hold(mods);
            d.click(c);
            d.hold(SDL_Keymod.KMOD_NONE);
        }
        int[] selected() { int[] s; d.ui({ s = list.selectedIndices; }); return s; }

        clickRow(2);
        d.expect(selected, [2], "a click: that row");
        clickRow(4, SDL_Keymod.KMOD_LCTRL);
        d.expect(selected, [2, 4], "Ctrl+click adds");
        clickRow(7, SDL_Keymod.KMOD_LSHIFT);
        d.expect(selected, [4, 5, 6, 7], "Shift+click: from the last row clicked, in place of what was");
        clickRow(0, cast(SDL_Keymod) (SDL_Keymod.KMOD_LCTRL | SDL_Keymod.KMOD_LSHIFT));
        d.expect(selected, [0, 1, 2, 3, 4, 5, 6, 7], "Ctrl+Shift+click adds the range");
        clickRow(5, SDL_Keymod.KMOD_LCTRL);
        d.expect(selected, [0, 1, 2, 3, 4, 6, 7], "Ctrl+click on a selected row takes it away");
        d.ui({ d.check(list.isSelected(list.selectedIndex), "selectedIndex is still a selected row"); });

        d.key(SDL_Keycode.SDLK_DOWN);
        d.expect(selected, [6], "Down: the next row alone");
        d.key(SDL_Keycode.SDLK_DOWN, SDL_Keymod.KMOD_LSHIFT);
        d.key(SDL_Keycode.SDLK_DOWN, SDL_Keymod.KMOD_LSHIFT);
        d.expect(selected, [6, 7, 8], "Shift+Down: a range");
        d.key(SDL_Keycode.SDLK_DOWN, SDL_Keymod.KMOD_LCTRL);
        d.ui({
            d.check(cell(9).isCurrent && !cell(9).isSelected, "Ctrl+Down: the keys move, and nothing's selected");
            d.check(!cell(8).isCurrent, "the current row moved off");
        });
        d.expect(selected, [6, 7, 8]);
        d.key(SDL_Keycode.SDLK_SPACE, SDL_Keymod.KMOD_LCTRL);
        d.expect(selected, [6, 7, 8, 9], "Ctrl+Space adds it");
        d.key(SDL_Keycode.SDLK_RETURN);
        d.ui({ d.expect(activated, [9], "Enter activates the current row"); });
        d.key(SDL_Keycode.SDLK_A, SDL_Keymod.KMOD_LCTRL);
        d.ui({
            d.expect(list.selectedItems.length, 100, "Ctrl+A: every row");
            d.check(changes >= 9, format!"onSelectionChanged heard each change: %s"(changes));
        });
        d.ui({ list.setSelectionMode(SelectionMode.single); });
        d.ui({ d.expect(list.selectedIndices.length, 1, "one at a time again: one"); });
        clickRow(3, SDL_Keymod.KMOD_LCTRL);
        d.expect(selected, [3], "and Ctrl+click only selects");

        // A table sorted: its selection goes with its items
        d.ui({
            table.select(0);
            table.select(2);
            table.sortBy(table.columns[1]);
            string[] names;
            foreach (c; table.selectedItems)
                names ~= c.name;
            import std.algorithm.sorting : sort;
            names.sort();
            d.expect(names, ["City 00", "City 02"], "sorted, the same items selected");
            d.check(table.selectedIndices != [0, 2], "in the rows they went to");
        });
    });
}

/// Trees: a click on an arrow opening an item, loading what's below it once; the keys opening,
/// closing and moving in and out; closing round the selection moving it up; a double click opening
/// and activating; rows indented by depth; and selecting an item deep inside opening the way to it.
void treeViews()
{
    TreeView!string tree;
    TreeItem!string home, documents, notes, old, letter, music, readme;
    int loads;
    TreeItem!string[] activated;
    run("lists: tree views", {
        notes = new TreeItem!string("notes.txt");
        letter = new TreeItem!string("letter.txt");
        documents = new TreeItem!string("Documents").icon("folder-symbolic").childrenLoader({
            loads++;
            old = new TreeItem!string("Old", letter).icon("folder-symbolic");
            return [notes, new TreeItem!string("todo.txt"), old];
        });
        music = new TreeItem!string("Music", new TreeItem!string("song.ogg")).icon("folder-symbolic");
        readme = new TreeItem!string("readme.txt");
        home = new TreeItem!string("Home", documents, music, readme).expanded(true);
        tree = new TreeView!string(home).prefSize(300, 320).onActivate((TreeItem!string i) { activated ~= i; });
        return cast(Widget) new Column().padding(20).fillWidth(false).add(tree);
    }, (Driver d) {
        TreeCell!string cellOf(TreeItem!string item)
        {
            TreeCell!string found;
            void walk(Widget w)
            {
                if (auto c = cast(TreeCell!string) w)
                    if (c.visible && c.item is item)
                        found = c;
                foreach (child; w.children)
                    walk(cast() child);
            }
            walk(tree);
            return found;
        }
        Widget arrowOf(TreeItem!string item)
        {
            foreach (child; cellOf(item).children)
                if (child.styleClass.contains("disclosure"))
                    return cast() child;
            return null;
        }
        void clickArrow(TreeItem!string item)
        {
            Widget arrow;
            d.ui({ arrow = arrowOf(item); });
            d.click(arrow);
        }
        void clickRow(TreeItem!string item, ubyte clicks = 1)
        {
            TreeCell!string c;
            d.ui({ c = cellOf(item); });
            d.click(c, float.nan, clicks);
        }

        d.ui({
            d.expect(tree.rowCount, 4, "the root and what's below it");
            d.expect(loads, 0, "nothing loaded before it's opened");
        });
        clickArrow(documents);
        d.settle();
        d.ui({
            d.check(documents.expanded, "a click on the arrow opens it");
            d.expect(loads, 1, "loading what's below it");
            d.expect(tree.rowCount, 7);
            d.check(tree.selectedItem is null, "without selecting it");
            d.check(cellOf(notes).boundsInScene.minX == cellOf(documents).boundsInScene.minX,
                    "rows span the tree");
            const step = arrowOf(notes).boundsInScene.minX - arrowOf(documents).boundsInScene.minX;
            d.check(abs(step - tree.indent) < 0.5f, format!"a step down, indented by `indent`: %s"(step));
            d.expect(cellOf(notes).children[2].boundsInScene.minX, cellOf(old).children[2].boundsInScene.minX,
                     "siblings' texts line up, with an icon or without");
        });

        clickRow(notes);
        d.ui({ d.check(tree.selectedItem is notes, "a click on a row selects it"); });
        d.key(SDL_Keycode.SDLK_LEFT);
        d.ui({ d.check(tree.selectedItem is documents, "Left from a leaf: the item it's in"); });
        d.key(SDL_Keycode.SDLK_LEFT);
        d.settle();
        d.ui({ d.check(!documents.expanded && tree.rowCount == 4, "Left again closes it"); });
        d.key(SDL_Keycode.SDLK_RIGHT);
        d.settle();
        d.ui({ d.check(documents.expanded, "Right opens it"); });
        d.key(SDL_Keycode.SDLK_RIGHT);
        d.ui({ d.check(tree.selectedItem is notes, "Right again: the first below it"); });
        d.ui({ d.expect(loads, 1, "loaded only the once"); });

        clickArrow(documents);
        d.settle();
        d.ui({
            d.check(!documents.expanded, "its arrow closes it");
            d.check(tree.selectedItem is documents, "and the selection inside moves up to it");
        });

        clickRow(music);
        clickRow(music, 2);
        d.settle();
        d.ui({
            d.check(music.expanded, "a double click opens it");
            d.expect(activated, [music], "and activates it");
        });
        clickRow(readme);
        d.key(SDL_Keycode.SDLK_RETURN);
        d.ui({ d.expect(activated, [music, readme], "Enter activates"); });

        d.ui({ tree.select(letter); });
        d.settle();
        d.ui({
            d.check(documents.expanded && old.expanded, "selecting one deep inside opens the way to it");
            d.check(tree.isSelected(letter) && tree.rowOf(letter) >= 0, "and it's selected");
            d.check(cellOf(letter) !is null, "and in view");
        });
    });
}

/// Copying from a table: the selected rows by Ctrl+C and a right click's Copy, and with selectable
/// text, a cell's text selected by a drag while a click still selects the row.
void tableCopying()
{
    TableView!City table;
    TableColumn!City name, people;
    run("lists: copying from a table", {
        auto cities = [City("Leeds", 812_000, "England"), City("Bath", 94_000, "England"),
                       City("Perth", 47_000, "Scotland")];
        name = new TableColumn!City("Name", (City c) => c.name);
        people = new TableColumn!City("People", (City c) => c.people.to!string);
        table = new TableView!City(cities).prefSize(360, 200);
        table.add(name).add(people).add(new TableColumn!City("Country", (City c) => c.country));
        table.setSelectionMode(SelectionMode.multiple);
        return cast(Widget) new Column().padding(20).fillWidth(false).add(table);
    }, (Driver d) {
        enum ctrl = SDL_Keymod.KMOD_LCTRL, shift = SDL_Keymod.KMOD_LSHIFT;
        // Each row's cells, top to bottom
        Label[][] cells()
        {
            Label[][] found;
            void walk(Widget w)
            {
                if (w.styleClass.contains("table-row"))
                {
                    Label[] row;
                    foreach (c; w.children)
                        row ~= cast(Label) c;
                    found ~= row;
                }
                foreach (c; w.children)
                    walk(cast() c);
            }
            walk(table);
            return found;
        }
        ContextMenu menu() { auto p = table.scene.showingPopups; return p.length ? cast(ContextMenu) p[$ - 1] : null; }
        d.preserveClipboard();

        Bounds leeds, bath, perth;
        d.ui({
            auto c = cells;
            leeds = c[0][0].boundsInScene;
            bath = c[1][0].boundsInScene;
            perth = c[2][0].boundsInScene;
        });
        d.click(leeds.minX + 5, leeds.centreY);
        d.click(bath.minX + 5, bath.centreY, 1, 1);
        d.key(SDL_Keycode.SDLK_DOWN, shift);
        d.key(SDL_Keycode.SDLK_C, ctrl);
        d.ui({ d.expect(Clipboard.text, "Bath\t94000\tEngland\nPerth\t47000\tScotland",
                        "Ctrl+C copies the selected rows, tab-separated"); });

        d.ui({ Clipboard.text = ""; });
        d.click(leeds.minX + 5, leeds.centreY, 1, 3);
        d.ui({
            d.expect(table.selectedIndices, [0], "a right click off the selection selects its row");
            d.check(menu !is null, "and shows the table's menu");
        });
        d.click(menu.items[0]);
        d.ui({ d.expect(Clipboard.text, "Leeds\t812000\tEngland", "whose Copy copies it"); });

        // Selectable text
        d.ui({ name.selectable(true); Clipboard.text = ""; });
        float lStart, lEnd;
        d.ui({
            auto c = cells[2][0];
            auto line = editableLine(c.font, "Perth");
            lStart = perth.minX + c.padding.left + 1;
            lEnd = perth.minX + c.padding.left + line.xAt(3);
        });
        d.press(lStart, perth.centreY);
        d.move(lEnd, perth.centreY);
        d.release(lEnd, perth.centreY);
        d.ui({
            d.expect(cells[2][0].selectedText, "Per", "a drag in a selectable cell selects its text");
            d.expect(table.selectedIndices, [2], "and the press still selected its row");
            d.check(cells[2][0].focused, "the cell has focus, to copy from");
        });
        d.key(SDL_Keycode.SDLK_C, ctrl);
        d.ui({ d.expect(Clipboard.text, "Per", "Ctrl+C copies the cell's selection"); });
        d.click(lEnd, perth.centreY, 1, 3);
        d.ui({ d.check(menu !is null && menu.items.length == 3, "a right click on it: the cell's menu"); });
        d.key(SDL_Keycode.SDLK_ESCAPE);
        d.key(SDL_Keycode.SDLK_UP);
        d.ui({ d.expect(table.selectedIndices, [1], "the arrow keys still move the row"); });
        d.ui({ d.check(!cells[0][1].selectable, "a column not made selectable isn't"); });
        d.ui({ table.setSelectableText(true); d.check(cells[0][1].selectable, "selectableText makes all of them"); });
    });
}

/// Copying from a list: the selected items by Ctrl+C and a right click's Copy, written as itemText says.
void listCopying()
{
    ListView!string list;
    run("lists: copying from a list", {
        list = new ListView!string(["Apple", "Banana", "Cherry"]).prefSize(200, 160);
        list.setSelectionMode(SelectionMode.multiple);
        return cast(Widget) new Column().padding(20).fillWidth(false).add(list);
    }, (Driver d) {
        enum ctrl = SDL_Keymod.KMOD_LCTRL, shift = SDL_Keymod.KMOD_LSHIFT;
        ListCell!string row(size_t index)
        {
            foreach (w; rowsOf(list))
                if (auto c = cast(ListCell!string) w)
                    if (c.visible && c.index == index)
                        return c;
            return null;
        }
        ContextMenu menu() { auto p = list.scene.showingPopups; return p.length ? cast(ContextMenu) p[$ - 1] : null; }
        d.preserveClipboard();

        d.click(row(0));
        d.key(SDL_Keycode.SDLK_DOWN, shift);
        d.key(SDL_Keycode.SDLK_C, ctrl);
        d.ui({ d.expect(Clipboard.text, "Apple\nBanana", "Ctrl+C copies the selected items, a line each"); });

        Bounds cherry;
        d.ui({ cherry = row(2).boundsInScene; Clipboard.text = ""; });
        d.click(cherry.centreX, cherry.centreY, 1, 3);
        d.ui({
            d.expect(list.selectedIndices, [2], "a right click off the selection selects its row");
            d.check(menu !is null && menu.items.length == 2, "and shows Copy and Select All");
        });
        d.click(menu.items[0]);
        d.ui({ d.expect(Clipboard.text, "Cherry", "Copy copies it"); });

        d.ui({ list.itemText((string s) => s ~ " pie"); });
        d.key(SDL_Keycode.SDLK_C, ctrl);
        d.ui({ d.expect(Clipboard.text, "Cherry pie", "written as itemText says"); });
    });
}
