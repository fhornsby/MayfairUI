module tests.focus;

import harness;
import mayfair;

/*
    The keyboard, disabling and removing, on a column of buttons:

        spacer   removed partway, which slides everything below it up under a still pointer
        A        the default button: Enter presses it wherever focus is
        B        the cancel button: Escape presses it
        C        disables A when pressed
        D        removes itself when pressed
*/
void keyboardDisableRemove()
{
    Widget root, spacer;
    Button a, b, c, dButton;
    int aCount, bCount, cCount, dCount, bExited;

    static Widget sized(Widget w)
    {
        return w.prefSize(100, 40);
    }

    run("focus: keyboard, default and cancel, disable, remove, repick", {
        root = new Column().fillWidth(false);
        spacer = sized(new Widget);
        a = new Button("A").defaultButton(true).onAction({ aCount++; });
        b = new Button("B").cancelButton(true).onAction({ bCount++; });
        c = new Button("C").onAction({ cCount++; a.disable(true); });
        dButton = new Button("D").onAction({ dCount++; });
        b.onMouseExited((ref e) { bExited++; });
        dButton.onMousePressed((ref e) { root.remove(dButton); });
        foreach (w; [spacer, cast(Widget) a, b, c, dButton])
            root.add(sized(w));
        return root;
    }, (Driver d) {
        d.key(SDL_Keycode.SDLK_TAB);                       // focus A
        d.key(SDL_Keycode.SDLK_SPACE);                     // A
        d.ui({ d.expect(aCount, 1, "Space presses the focused button"); d.check(a.focusVisible, "A shows focus"); });
        d.key(SDL_Keycode.SDLK_TAB);                       // focus B
        d.key(SDL_Keycode.SDLK_RETURN);                    // A, the default
        d.key(SDL_Keycode.SDLK_ESCAPE);                    // B, the cancel
        d.ui({ d.expect(aCount, 2, "Enter presses the default button"); d.expect(bCount, 1, "Escape presses cancel"); });
        d.key(SDL_Keycode.SDLK_TAB, SDL_Keymod.KMOD_LSHIFT); // back to A
        d.key(SDL_Keycode.SDLK_SPACE);
        d.ui({ d.expect(aCount, 3, "Shift+Tab went back to A"); });

        d.click(c);                                        // disables A, and takes focus
        d.click(a);                                        // disabled: nothing
        d.ui({
            d.expect(cCount, 1);
            d.expect(aCount, 3, "a disabled button ignores clicks");
            d.check(a.disabled && !a.focused, "A disabled and unfocused");
            d.check(c.focused && !c.focusVisible, "a click focuses without showing it");
        });
        d.key(SDL_Keycode.SDLK_TAB);                       // D
        d.key(SDL_Keycode.SDLK_TAB);                       // wraps past disabled A to B
        d.key(SDL_Keycode.SDLK_SPACE);
        d.ui({ d.expect(bCount, 2, "Tab skips disabled widgets"); });

        d.click(dButton);                                  // removes itself as it's pressed
        d.ui({
            d.expect(dCount, 0, "a button removed mid-press doesn't fire");
            d.check(dButton.parent is null && dButton.shape is null, "D gone, shapes and all");
            d.check(!root.pressed, "the press didn't outlive D");
        });

        Bounds bb;
        d.ui({ bb = b.boundsInScene; });
        d.move(bb.centerX, bb.centerY);                    // over B
        d.ui({ root.remove(spacer); });                    // B slides up from under the pointer, C in
        d.settle();
        d.settle();
        d.ui({
            d.expect(bExited, 1, "B heard the pointer leave without it moving");
            d.check(!b.hover && c.hover, "hover moved from B to C");
        });
    });
}
