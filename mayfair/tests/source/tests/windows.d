module tests.windows;

import harness;
import mayfair;

// Asks the desktop's way for `w` to close, as its close button would
private void requestClose(Window w)
{
    SDL_Event e;
    e.type = SDL_EventType.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
    e.window.windowID = SDL_GetWindowID(w.nativeWindow);
    SDL_PushEvent(&e);
}

/// A second window: opened from a button, its own input going to its own widgets, closing when
/// asked unless it says not to, and opening again afterwards.
void secondWindow()
{
    Button open, press;
    TextField field;
    Window second;
    int opened, pressed, closed;
    bool mayClose;
    run("windows: a second one, its input, closing and opening again", {
        second = new Window("Second");
        second.setSize(320, 200);
        auto column = new Column().padding(20);
        press = new Button("Press").onAction({ pressed++; });
        field = new TextField;
        column.add(press).add(field);
        second.scene = new Scene(column);
        second.scene.setColourScheme(ColourScheme.dark);
        second.onCloseRequest({ return mayClose; }).onClosed({ closed++; });

        open = new Button("Open").onAction({ opened++; second.show(); });
        return cast(Widget) new Column().padding(20).add(open);
    }, (Driver d) {
        const mainID = d.windowID;
        d.click(open);
        d.settle();
        d.ui({
            d.expect(opened, 1);
            d.expect(App.current.windows.length, 2, "two windows open");
            d.check(second.showing && second.nativeWindow !is null, "the second one's open");
            d.check(Window.of(press) is second, "a widget's window is the one it's in");
            d.check(Window.of(open) is App.current.window, "and the main one's are in that");
            d.windowID = SDL_GetWindowID(second.nativeWindow);
        });
        d.settle();

        d.click(press);
        d.click(field);
        d.type("hello");
        d.settle();
        d.ui({
            d.expect(pressed, 1, "a click in the second window goes to its button");
            d.expect(opened, 1, "and not to the main one's");
            d.expect(field.text, "hello", "typing goes to its focused field");
        });

        d.ui({ requestClose(second); });
        d.settle();
        d.ui({
            d.check(second.showing, "kept open when its onCloseRequest says no");
            d.expect(closed, 0);
            mayClose = true;
            requestClose(second);
        });
        d.settle();
        d.ui({
            d.check(!second.showing && second.nativeWindow is null, "closed when it says yes");
            d.expect(closed, 1, "its onClosed told");
            d.expect(App.current.windows.length, 1, "the main one still open");
            d.windowID = mainID;
        });

        d.click(open);
        d.settle();
        d.ui({
            d.check(second.showing && second.nativeWindow !is null, "opened again");
            d.expect(field.text, "hello", "with the same widgets");
            d.windowID = SDL_GetWindowID(second.nativeWindow);
        });
        d.settle();
        d.click(press);
        d.settle();
        d.ui({
            d.expect(pressed, 2, "and working");
            second.close();
        });
        d.settle();
        d.ui({ d.expect(App.current.windows.length, 1, "close() closes it"); });
        d.windowID = mainID;
    });
}

/// A modal window keeps input from its owner while it's open, and closes with it.
void modalWindow()
{
    Button behind, inDialog;
    Window dialog;
    int behindClicks, dialogClicks;
    run("windows: a modal one over its owner", {
        behind = new Button("Behind").onAction({ behindClicks++; });
        return cast(Widget) new Column().padding(20).add(behind);
    }, (Driver d) {
        const mainID = d.windowID;
        d.ui({
            dialog = new Window("Dialog").setSize(240, 120);
            inDialog = new Button("OK").onAction({ dialogClicks++; });
            dialog.scene = new Scene(new Column().padding(20).add(inDialog));
            dialog.setOwner(App.current.window).setModal(true).show();
        });
        d.settle();
        d.click(behind);
        d.settle();
        d.ui({
            d.expect(behindClicks, 0, "the owner takes no clicks while the modal one's open");
            d.windowID = SDL_GetWindowID(dialog.nativeWindow);
        });
        d.settle();
        d.click(inDialog);
        d.settle();
        d.ui({
            d.expect(dialogClicks, 1, "the modal one does");
            requestClose(App.current.window);
        });
        d.settle();
        d.ui({
            d.check(App.current.window.showing, "the owner can't be closed under it");
            dialog.close();
            d.windowID = mainID;
        });
        d.settle();
        d.click(behind);
        d.settle();
        d.ui({ d.expect(behindClicks, 1, "with it closed, the owner takes clicks again"); });

        // Closing the owner closes what it owns
        d.ui({ dialog.show(); });
        d.settle();
        d.ui({
            auto extra = new Window("Unowned");
            extra.scene = new Scene(new Column());
            extra.show();
        });
        d.settle();
        d.ui({
            d.expect(App.current.windows.length, 3);
            App.current.window.close();
        });
        d.settle();
        d.ui({
            d.check(!dialog.showing, "the dialog closed with its owner");
            d.expect(App.current.windows.length, 1, "and the unowned one kept the app running");
        });
    });
}
