module tests.popups;

import core.thread : Thread;
import core.time : msecs;
import std.format : format;
import std.math : abs;
import harness;
import mayfair;

private bool near(float a, float b) { return abs(a - b) <= 0.5f; }

/// Popups: placed below what they're for, or above without room; a press outside hides them and
/// does nothing else; Escape hides them; focus goes in and comes back; they take their variables
/// from what they're for; and they go when that does.
void placing()
{
    Button owner, low, under;
    Popup popup;
    Label inside;
    TextField field;
    Column root, themed;
    int underClicks;
    run("popups: placing and hiding", {
        root = new Column().padding(20).spacing(10).fillWidth(false);
        field = new TextField("focused");
        owner = new Button("Owner");
        under = new Button("Under").onAction({ underClicks++; });
        themed = new Column().style("--edge: #ff0000;");
        themed.add(owner);
        low = new Button("Low");
        inside = new Label("In the popup").style("colour: var(--edge);");
        popup = new Popup(new Column().padding(12).add(inside).add(new Button("Inside")));
        // `under` above the owner, where the popup below the owner doesn't cover it
        root.add(field).add(under).add(themed).add(new Widget().prefHeight(2000)).add(low);
        return cast(Widget) root;
    }, (Driver d) {
        d.click(field);
        d.ui({ popup.show(owner); });
        d.settle();
        Bounds p, o;
        d.ui({
            p = popup.boundsInScene;
            o = owner.boundsInScene;
            d.check(popup.showing, "showing");
            d.expect(p.minX, o.minX, "lined up with its owner");
            d.expect(p.minY, o.maxY + 4, "below it");
            d.expect(owner.scene.showingPopups.length, 1);
            d.check(!field.focused, "focus went into it");
            d.expect(inside.textFill, Colour(255, 0, 0), "its variables from its owner's ancestors");
        });

        // The rest of the window waits: a press on another button hides the popup and that's all
        d.click(under);
        d.ui({
            d.check(!popup.showing, "a press outside hides it");
            d.expect(underClicks, 0, "and reaches nothing else");
            d.check(field.focused, "focus back where it was");
        });

        d.ui({ popup.show(owner); });
        d.settle();
        d.key(SDL_Keycode.SDLK_ESCAPE);
        d.ui({ d.check(!popup.showing, "Escape hides it"); });

        // Near the bottom of the window: above instead
        d.ui({ low.scrollIntoView(); });
        d.ui({ popup.show(low); });
        d.settle();
        d.ui({
            d.check(popup.boundsInScene.maxY <= low.boundsInScene.minY, "no room below: above it");
            popup.hide();
        });

        // What it's for going takes it too
        d.ui({ popup.show(owner); });
        d.settle();
        d.ui({ themed.remove(owner); });
        d.ui({ d.check(!popup.showing, "gone with its owner"); });
    });
}

/// Menus: from a menu button, by the keys and the pointer; separators and disabled items skipped;
/// a check item switched; a context menu from a right click and the Menu key.
void menus()
{
    MenuButton button;
    ContextMenu menu, context;
    MenuItem open, save;
    CheckMenuItem wrap;
    Stack area;
    string[] done;
    run("popups: menus", {
        open = new MenuItem("Open", { done ~= "open"; }).accelerator("Ctrl+O");
        save = new MenuItem("Save", { done ~= "save"; });
        wrap = new CheckMenuItem("Wrap", { done ~= "wrap"; });
        menu = new ContextMenu().add(open).add(new MenuSeparator()).add(new MenuItem("Print").disable(true))
            .add(save).add(wrap);
        button = new MenuButton("Menu").menu(menu);
        area = new Stack().prefSize(200, 100);
        context = new ContextMenu().add(new MenuItem("Copy", { done ~= "copy"; }));
        area.contextMenu(context);
        return cast(Widget) new Column().padding(20).spacing(10).fillWidth(false).add(button).add(area);
    }, (Driver d) {
        d.click(button);
        d.ui({
            d.check(menu.showing, "the button shows its menu");
            d.check(menu.boundsInScene.minY >= button.boundsInScene.maxY, "below it");
            d.check(open.focused, "the first item has focus");
        });
        d.key(SDL_Keycode.SDLK_DOWN);
        d.ui({ d.check(save.focused, "Down: past the separator and what's disabled"); });
        d.key(SDL_Keycode.SDLK_RETURN);
        d.ui({
            d.expect(done, ["save"], "Enter chooses it");
            d.check(!menu.showing, "and the menu goes");
            d.check(button.focused, "focus back on the button");
        });

        d.click(button);
        d.click(wrap);
        d.ui({
            d.check(wrap.selected, "a check item, clicked, is on");
            d.expect(done, ["save", "wrap"]);
        });
        d.key(SDL_Keycode.SDLK_RETURN); // on the button, which has focus again: Enter isn't its key
        d.ui({ d.check(!menu.showing, "Enter on a menu button isn't a press"); });

        // A right click on the area: its menu, at the pointer
        Bounds a;
        d.ui({ a = area.boundsInScene; });
        d.click(a.minX + 30, a.minY + 40, 1, 3);
        d.ui({
            d.check(context.showing, "a right click shows the context menu");
            d.check(near(context.boundsInScene.minX, a.minX + 30) && near(context.boundsInScene.minY, a.minY + 40),
                    format!"at the pointer: %s"(context.boundsInScene));
        });
        d.key(SDL_Keycode.SDLK_ESCAPE);
        d.ui({ button.requestFocus(); });
        d.key(SDL_Keycode.SDLK_APPLICATION);
        d.ui({ d.check(!context.showing, "the Menu key on something without a menu shows none"); });
    });
}

/// Menu bars: a title's menu below it; moving along the bar switches menus, and a press on the open
/// title closes it; F10, Left and Right; submenus by the keys and by resting on them; choosing in one
/// puts every menu away; and accelerators, with the menus closed.
void menuBars()
{
    MenuBar bar;
    Menu file, edit, recent;
    MenuItem open, notes, undo;
    CheckMenuItem wrap;
    Button content;
    string[] done;
    run("popups: menu bars", {
        open = new MenuItem("Open", { done ~= "open"; }).accelerator("Ctrl+O");
        notes = new MenuItem("notes.txt", { done ~= "notes"; });
        recent = new Menu("Open recent").add(notes).add(new MenuItem("todo.txt", { done ~= "todo"; }));
        file = new Menu("File").add(open).add(recent).add(new MenuSeparator())
            .add(new MenuItem("Quit", { done ~= "quit"; }).accelerator("Ctrl+Q").disable(true));
        undo = new MenuItem("Undo", { done ~= "undo"; }).accelerator("Ctrl+Z");
        wrap = new CheckMenuItem("Wrap", { done ~= "wrap"; }).accelerator("Ctrl+Shift+W");
        edit = new Menu("Edit").add(undo).add(wrap);
        bar = new MenuBar().add(file).add(edit);
        content = new Button("Content").onAction({ done ~= "content"; });
        // The button off to the right, clear of where the menus drop down
        return cast(Widget) new Column().add(bar).add(new Column().padding(20).fillWidth(false)
            .alignment(Pos.topRight).add(content));
    }, (Driver d) {
        const(Popup)[] showing() { return bar.scene.showingPopups; }
        d.click(file);
        d.ui({
            d.check(file.showing, "a click on a title opens its menu");
            d.check(open.boundsInScene.minY > file.boundsInScene.maxY, "below it");
            d.check(open.focused, "with focus on its first item");
        });
        d.move(edit.boundsInScene.centreX, edit.boundsInScene.centreY);
        d.ui({ d.check(edit.showing && !file.showing, "moving along the bar opens the next menu"); });
        d.click(edit);
        d.ui({
            d.check(!edit.showing, "a click on the open title closes it");
            d.expect(showing.length, 0);
        });

        // The keys
        d.key(SDL_Keycode.SDLK_F10);
        d.ui({ d.check(file.showing && open.focused, "F10 opens the first menu"); });
        d.key(SDL_Keycode.SDLK_RIGHT);
        d.ui({ d.check(edit.showing && !file.showing && undo.focused, "Right: the next menu"); });
        d.key(SDL_Keycode.SDLK_LEFT);
        d.ui({ d.check(file.showing && !edit.showing, "Left: back"); });
        d.key(SDL_Keycode.SDLK_DOWN);
        d.ui({ d.check(recent.focused, "Down to the submenu's item"); });
        d.key(SDL_Keycode.SDLK_RIGHT);
        d.ui({
            d.check(recent.showing && notes.focused, "Right opens the submenu, focus in it");
            d.check(file.showing, "its menu still open");
            d.check(notes.boundsInScene.minX >= recent.boundsInScene.maxX, "beside it");
        });
        d.key(SDL_Keycode.SDLK_LEFT);
        d.ui({ d.check(!recent.showing && recent.focused && file.showing, "Left closes it, focus back on its item"); });
        d.key(SDL_Keycode.SDLK_RIGHT);
        d.key(SDL_Keycode.SDLK_RETURN);
        d.ui({
            d.expect(done, ["notes"], "Enter chooses in the submenu");
            d.expect(showing.length, 0, "and every menu goes");
        });

        // The pointer resting on a submenu's item opens it, leaving focus there
        d.click(file);
        d.move(recent.boundsInScene.centreX, recent.boundsInScene.centreY);
        d.ui({ d.check(!recent.showing, "not straight away"); });
        Thread.sleep(400.msecs);
        d.settle();
        d.ui({ d.check(recent.showing && recent.focused, "after resting on it, focus still on it"); });
        d.click(notes);
        d.ui({
            d.expect(done, ["notes", "notes"], "a click chooses in it");
            d.expect(showing.length, 0, "and every menu goes");
        });

        // A press elsewhere puts it away, and does nothing else
        d.click(file);
        d.click(content);
        d.ui({
            d.check(!file.showing, "a press outside closes it");
            d.expect(done, ["notes", "notes"], "and reaches nothing else");
        });

        // Accelerators, with the menus closed
        d.key(SDL_Keycode.SDLK_O, SDL_Keymod.KMOD_LCTRL);
        d.key(SDL_Keycode.SDLK_W, cast(SDL_Keymod) (SDL_Keymod.KMOD_LCTRL | SDL_Keymod.KMOD_LSHIFT));
        d.key(SDL_Keycode.SDLK_Q, SDL_Keymod.KMOD_LCTRL);
        d.key(SDL_Keycode.SDLK_Z);
        d.ui({
            d.expect(done, ["notes", "notes", "open", "wrap"], "Ctrl+O and Ctrl+Shift+W; not a disabled item's, or Z alone");
            d.check(wrap.selected, "a check item's accelerator switches it");
            d.expect(showing.length, 0, "without opening anything");
        });
    });
}

/// Drop-downs: the list below, as wide at least, with the choice picked out; choosing from it;
/// and Up and Down changing the choice without it.
void comboBoxes()
{
    ComboBox combo;
    int[] changes;
    run("popups: drop-downs", {
        combo = new ComboBox(["Small", "Medium", "Large"]).selectedIndex(1);
        combo.selectedIndexProperty.addListener((int was, int now) { changes ~= now; });
        return cast(Widget) new Column().padding(20).fillWidth(false).add(combo);
    }, (Driver d) {
        d.ui({ d.expect(combo.text, "Medium", "it shows the choice"); });
        d.click(combo);
        Popup list;
        d.ui({
            d.expect(combo.scene.showingPopups.length, 1, "a click drops the list down");
            list = cast(Popup) combo.scene.showingPopups[0];
            d.check(list.boundsInScene.width >= combo.boundsInScene.width, "at least as wide");
            d.check(combo.showing, ":showing");
        });
        MenuItem large;
        d.ui({ large = cast(MenuItem) (cast(ContextMenu) list).items[2]; });
        d.click(large);
        d.ui({
            d.expect(combo.selectedIndex, 2, "choosing from the list chooses");
            d.expect(combo.value, "Large");
            d.check(!combo.showing, "and puts it away");
        });
        d.ui({ combo.requestFocus(); });
        d.key(SDL_Keycode.SDLK_UP);
        d.ui({
            d.expect(combo.value, "Medium", "Up: the one before, without the list");
            d.expect(combo.scene.showingPopups.length, 0);
        });
        d.key(SDL_Keycode.SDLK_RETURN);
        d.ui({ d.check(combo.showing, "Enter drops it down"); });
        d.key(SDL_Keycode.SDLK_ESCAPE);
        d.ui({
            d.check(!combo.showing, "Escape puts it away");
            d.expect(changes, [2, 1]);
        });
    });
}

/// Dialogs: modal, so a click outside does nothing; Enter presses the default button and Escape the
/// cancel one; and each closes it.
void dialogs()
{
    Button open, under;
    Dialog dialog;
    string[] answers;
    int underClicks;
    run("popups: dialogs", {
        open = new Button("Open");
        under = new Button("Under").onAction({ underClicks++; });
        return cast(Widget) new Column().padding(20).spacing(10).fillWidth(false).add(open).add(under);
    }, (Driver d) {
        void show()
        {
            d.ui({
                dialog = new Dialog("Delete it?").text("For good.")
                    .addButton("Cancel", { answers ~= "cancel"; }, ButtonKind.cancel)
                    .addButton("Delete", { answers ~= "delete"; }, ButtonKind.default_);
                dialog.show(open);
            });
            d.settle();
        }
        show();
        d.ui({
            d.check(dialog.showing && dialog.modal, "showing, modal");
            // The window's content, from the top of its title bar, if it draws one, to the bottom of the root
            const b = dialog.boundsInScene, root = open.scene.root.boundsInScene;
            const top = open.scene.titleBar ? open.scene.titleBar.boundsInScene.minY : root.minY;
            d.check(near(b.centreX, root.centreX) && near(b.centreY, (top + root.maxY) / 2),
                    format!"in the middle of the window: %s in %s"(b, root));
        });
        d.click(under);
        d.ui({
            d.check(dialog.showing, "a click outside doesn't close it");
            d.expect(underClicks, 0, "or reach what's behind");
        });
        d.key(SDL_Keycode.SDLK_RETURN);
        d.ui({
            d.expect(answers, ["delete"], "Enter: the default button");
            d.check(!dialog.showing, "which closes it");
        });
        show();
        d.key(SDL_Keycode.SDLK_ESCAPE);
        d.ui({
            d.expect(answers, ["delete", "cancel"], "Escape: the cancel button");
            d.check(!dialog.showing, "which closes it too");
        });

        // A start button: at the start of the row, on its own, the answers still at the end
        Button importButton;
        d.ui({
            dialog = new Dialog("New list").addButton("Cancel", null, ButtonKind.cancel);
            dialog.addStartButton("Import…", { answers ~= "import"; });
            dialog.addButton("Create", { answers ~= "create"; }, ButtonKind.default_);
            dialog.show(open);
        });
        d.settle();
        d.ui({
            Row row;
            void find(Widget w)
            {
                if (w.styleClass.contains("buttons"))
                    row = cast(Row) w;
                foreach (c; w.children)
                    find(cast() c);
            }
            find(dialog);
            importButton = cast(Button) row.children[0];
            auto create = cast(Button) row.children[$ - 1];
            const box = row.boundsInScene;
            d.expect(importButton.text, "Import…", "first in the row");
            d.check(near(importButton.boundsInScene.minX, box.minX), "at its start");
            d.check(near(create.boundsInScene.maxX, box.maxX), "Create at its end");
        });
        d.click(importButton);
        d.ui({
            d.expect(answers, ["delete", "cancel", "import"], "it does what it does");
            d.check(!dialog.showing, "and closes it");
        });
    });
}

/// Tooltips: shown after resting on something, below it; gone when the pointer leaves or presses;
/// the next shown at once, while one was just showing.
void tooltips()
{
    Button first, second, plain;
    run("popups: tooltips", {
        first = new Button("First").tooltip("The first");
        second = new Button("Second").tooltip("The second");
        plain = new Button("Plain");
        return cast(Widget) new Column().padding(20).spacing(10).fillWidth(false).add(first).add(second).add(plain);
    }, (Driver d) {
        const(Popup)[] showing() { return first.scene.showingPopups; }
        d.move(first.boundsInScene.centreX, first.boundsInScene.centreY);
        d.ui({ d.expect(showing.length, 0, "not straight away"); });
        Thread.sleep(700.msecs);
        d.ui({
            d.expect(showing.length, 1, "after resting on it");
            d.check(showing.length && showing[0].boundsInScene.minY >= first.boundsInScene.maxY, "below it");
            d.check(showing.length && showing[0].pointerTransparent, "and the pointer passes through it");
        });
        d.move(second.boundsInScene.centreX, second.boundsInScene.centreY);
        d.ui({ d.expect(showing.length, 1, "the next at once, as one was showing"); });
        d.move(plain.boundsInScene.centreX, plain.boundsInScene.centreY);
        d.ui({ d.expect(showing.length, 0, "gone over something without one"); });
        d.move(first.boundsInScene.centreX, first.boundsInScene.centreY);
        Thread.sleep(700.msecs);
        d.click(first);
        d.ui({ d.expect(showing.length, 0, "a press puts it away"); });
        d.ui({ second.setDisable(true); });
        d.move(second.boundsInScene.centreX, second.boundsInScene.centreY);
        Thread.sleep(1500.msecs);
        d.ui({ d.expect(showing.length, 0, "none over something disabled"); });
    });
}

/// Visible: a widget that isn't takes no room, can't be clicked or reached by Tab, and is back as it was.
void visibility()
{
    Button a, b, c;
    int clicks;
    run("popups: visible", {
        a = new Button("A");
        b = new Button("B").onAction({ clicks++; });
        c = new Button("C");
        return cast(Widget) new Column().padding(20).spacing(10).fillWidth(false).add(a).add(b).add(c);
    }, (Driver d) {
        Bounds where;
        float cTop;
        d.ui({
            where = b.boundsInScene;
            cTop = c.boundsInScene.minY;
            b.setVisible(false);
        });
        d.settle();
        d.ui({ d.expect(c.boundsInScene.minY, where.minY, "not visible: it takes no room"); });
        d.click(where.centreX, where.centreY);
        d.ui({ d.expect(clicks, 0, "and can't be clicked"); });
        d.ui({ a.requestFocus(); });
        d.key(SDL_Keycode.SDLK_TAB);
        d.ui({ d.check(c.focused, "Tab goes past it"); });
        d.ui({ b.setVisible(true); });
        d.settle();
        d.ui({ d.expect(c.boundsInScene.minY, cTop, "visible again: where it was"); });
    });
}
