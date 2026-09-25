module mayfair.accessibility;

// AccessKit's C API, generated from its header by ImportC (bindings/accesskit_c.c)
public import accesskit_c;

import core.atomic : atomicOp;

/*
    Accessibility: what the widgets are, described for screen readers and other assistive
    technology.

    AccessKit does the platform half -- AT-SPI on Linux, UI Automation on Windows, NSAccessibility
    on macOS -- given a tree of nodes that says what each widget is (a button, a label), what it's
    called, where it is, and what can be done to it. Every widget is a node, so that tree comes
    straight from the widget tree, and the kit keeps it up to date the way it keeps the drawing up
    to date: a widget whose description changes calls invalidateAccessible(), as it would
    invalidate(). See Widget for the rest.

    The names are JavaFX's (AccessibleRole, AccessibleAction, executeAccessibleAction), since
    that's the model the kit follows. The difference is direction: JavaFX asks a node about itself
    when a screen reader wants to know, where AccessKit is told everything up front, so a widget
    describes itself into an AccessibleNode rather than answering queries.
*/

/// What kind of thing a widget is, which decides how a screen reader presents it. JavaFX's AccessibleRole.
enum AccessibleRole
{
    node,              /// Nothing in particular: a container. What a plain Widget is.
    button,
    toggleButton,      /// A button that stays in or out; its state goes in AccessibleNode.toggled
    checkBox,
    radioButton,
    label,             /// Text that doesn't change by itself: its text goes in AccessibleNode.value
    textField,
    textArea,
    image,
    list,
    listItem,
    slider,
    progressIndicator,
    tab,
    menu,
    menuItem,
    textRun,           /// A stretch of a text field's text, with its characters laid out: see TextField
}

/// Something assistive technology can ask a widget to do. JavaFX's AccessibleAction.
enum AccessibleAction
{
    fire,          /// Activate it, as a click would
    requestFocus,
    increment,
    decrement,
    expand,
    collapse,
    showMenu,
    setValue,            /// Replace all of its text with AccessibleActionData.value
    replaceSelectedText, /// Replace the selected text with AccessibleActionData.value
    setTextSelection,    /// Select what AccessibleActionData.anchor and .focus say
}

/// A place in a text field's text, as assistive technology gives it: the text run it's in, by
/// id, and which character of that run.
struct AccessibleTextPosition
{
    ulong node;
    size_t character;
}

/// What an action needs to be done, beyond which action it is: JavaFX's parameters to
/// executeAccessibleAction. Only the fields the action is about are set.
struct AccessibleActionData
{
    string value;                  /// For setValue and replaceSelectedText
    AccessibleTextPosition anchor; /// For setTextSelection: where the selection starts,
    AccessibleTextPosition focus;  /// and where it ends, which is where the caret goes
}

/// A new node id, for a node a widget adds below itself that isn't a widget of its own -- a text
/// run, say. Unique for the life of the process, like a widget's.
ulong newAccessibleId() nothrow @nogc
{
    return atomicOp!"+="(lastAccessibleId, 1);
}

private shared ulong lastAccessibleId; // 0 is never handed out: it's the window's node

/*
    One widget's node, as it's being described. The kit has already given it the widget's role,
    bounds, children and disabled state, and the focus action if it's focus traversable; a widget
    adds what only it knows. Strings are copied, so they needn't outlive the call.
*/
struct AccessibleNode
{
    /// Its name: what a screen reader calls it. "Save", for a Save button.
    void label(const(char)[] text) nothrow @nogc
    {
        accesskit_node_set_label_with_length(node, text.ptr, text.length);
    }

    /// Its content: a label's text, a text field's contents, a slider's value as words.
    void value(const(char)[] text) nothrow @nogc
    {
        accesskit_node_set_value_with_length(node, text.ptr, text.length);
    }

    /// More about it than its name, read after it. A tooltip, say.
    void description(const(char)[] text) nothrow @nogc
    {
        accesskit_node_set_description_with_length(node, text.ptr, text.length);
    }

    /// Says it can do `action`. Only actions it says it can do are offered to the user.
    void addAction(AccessibleAction action) nothrow @nogc
    {
        accesskit_node_add_action(node, toAccessKit(action));
    }

    /// Whether a toggle button or check box is on.
    void toggled(bool on) nothrow @nogc
    {
        accesskit_node_set_toggled(node, on ? ACCESSKIT_TOGGLED_TRUE : ACCESSKIT_TOGGLED_FALSE);
    }

    /// What a text field shows when it's empty, as a hint to what goes in it.
    void placeholder(const(char)[] text) nothrow @nogc
    {
        accesskit_node_set_placeholder_with_length(node, text.ptr, text.length);
    }

    /// That its value can be read and selected but not changed.
    void readOnly() nothrow @nogc
    {
        accesskit_node_set_read_only(node);
    }

    /// Where it is, in points from the window's top left. Widgets get theirs for nothing; this is
    /// for nodes added with addChild().
    void bounds(float x, float y, float w, float h) nothrow @nogc
    {
        accesskit_node_set_bounds(node, accesskit_rect(x, y, x + w, y + h));
    }

    /// Which way its text reads. A text run has to say, or assistive technology can't tell where
    /// its characters are.
    void textDirection(bool rightToLeft) nothrow @nogc
    {
        accesskit_node_set_text_direction(node, rightToLeft ? ACCESSKIT_TEXT_DIRECTION_RIGHT_TO_LEFT
                                                            : ACCESSKIT_TEXT_DIRECTION_LEFT_TO_RIGHT);
    }

    /// The selected text, or just the caret if anchor and focus are the same place.
    void textSelection(AccessibleTextPosition anchor, AccessibleTextPosition focus) nothrow @nogc
    {
        accesskit_node_set_text_selection(node, accesskit_text_selection(
            accesskit_text_position(anchor.node, anchor.character),
            accesskit_text_position(focus.node, focus.character)));
    }

    /*
        A text run's characters: how many bytes of its value each takes, where each starts along
        the run from its left edge, and how wide each is. "Character" means what a reader counts
        as one, which is a grapheme cluster, not a byte or a code point. `wordStarts` lists the
        characters that begin a word. Every array is in characters, and indexed by bytes, which is
        why a run holds at most 255 characters.
    */
    void characters(const(ubyte)[] lengths, const(float)[] positions, const(float)[] widths,
                    const(ubyte)[] wordStarts) nothrow @nogc
    {
        accesskit_node_set_character_lengths(node, lengths.length, lengths.ptr);
        accesskit_node_set_character_positions(node, positions.length, positions.ptr);
        accesskit_node_set_character_widths(node, widths.length, widths.ptr);
        accesskit_node_set_word_starts(node, wordStarts.length, wordStarts.ptr);
    }

    /*
        Adds a node below this one that isn't a widget: part of a widget that assistive technology
        needs to see as a thing of its own, like a stretch of a text field's text. `id` should come
        from newAccessibleId() and stay the same for as long as the part does. `describe` fills the
        new node in; it's sent along with this one.
    */
    void addChild(ulong id, AccessibleRole role, scope void delegate(ref AccessibleNode child) describe)
    {
        auto child = AccessibleNode(accesskit_node_new(toAccessKit(role)), update);
        describe(child);
        accesskit_tree_update_push_node(update, id, child.node); // which takes it over
        accesskit_node_push_child(node, id);
    }

    /// AccessKit's own node, for any of its properties without a name here.
    accesskit_node* raw() nothrow @nogc { return node; }

package(mayfair):
    accesskit_node* node;
    accesskit_tree_update* update; // the update it's going out in, which added children go in too
}

package(mayfair) accesskit_role toAccessKit(AccessibleRole role) nothrow @nogc
{
    final switch (role)
    {
        case AccessibleRole.node:              return ACCESSKIT_ROLE_GENERIC_CONTAINER;
        case AccessibleRole.button:            return ACCESSKIT_ROLE_BUTTON;
        case AccessibleRole.toggleButton:      return ACCESSKIT_ROLE_BUTTON; // a button with a toggled state is one
        case AccessibleRole.checkBox:          return ACCESSKIT_ROLE_CHECK_BOX;
        case AccessibleRole.radioButton:       return ACCESSKIT_ROLE_RADIO_BUTTON;
        case AccessibleRole.label:             return ACCESSKIT_ROLE_LABEL;
        case AccessibleRole.textField:         return ACCESSKIT_ROLE_TEXT_INPUT;
        case AccessibleRole.textArea:          return ACCESSKIT_ROLE_MULTILINE_TEXT_INPUT;
        case AccessibleRole.image:             return ACCESSKIT_ROLE_IMAGE;
        case AccessibleRole.list:              return ACCESSKIT_ROLE_LIST;
        case AccessibleRole.listItem:          return ACCESSKIT_ROLE_LIST_ITEM;
        case AccessibleRole.slider:            return ACCESSKIT_ROLE_SLIDER;
        case AccessibleRole.progressIndicator: return ACCESSKIT_ROLE_PROGRESS_INDICATOR;
        case AccessibleRole.tab:               return ACCESSKIT_ROLE_TAB;
        case AccessibleRole.menu:              return ACCESSKIT_ROLE_MENU;
        case AccessibleRole.menuItem:          return ACCESSKIT_ROLE_MENU_ITEM;
        case AccessibleRole.textRun:           return ACCESSKIT_ROLE_TEXT_RUN;
    }
}

package(mayfair) accesskit_action toAccessKit(AccessibleAction action) nothrow @nogc
{
    final switch (action)
    {
        case AccessibleAction.fire:         return ACCESSKIT_ACTION_CLICK;
        case AccessibleAction.requestFocus: return ACCESSKIT_ACTION_FOCUS;
        case AccessibleAction.increment:    return ACCESSKIT_ACTION_INCREMENT;
        case AccessibleAction.decrement:    return ACCESSKIT_ACTION_DECREMENT;
        case AccessibleAction.expand:       return ACCESSKIT_ACTION_EXPAND;
        case AccessibleAction.collapse:     return ACCESSKIT_ACTION_COLLAPSE;
        case AccessibleAction.showMenu:     return ACCESSKIT_ACTION_SHOW_CONTEXT_MENU;
        case AccessibleAction.setValue:     return ACCESSKIT_ACTION_SET_VALUE;
        case AccessibleAction.replaceSelectedText: return ACCESSKIT_ACTION_REPLACE_SELECTED_TEXT;
        case AccessibleAction.setTextSelection:    return ACCESSKIT_ACTION_SET_TEXT_SELECTION;
    }
}

/// The action AccessKit asked for, if it's one the kit has a name for.
package(mayfair) bool fromAccessKit(accesskit_action action, out AccessibleAction result) nothrow @nogc
{
    foreach (a; __traits(allMembers, AccessibleAction))
    {
        enum member = __traits(getMember, AccessibleAction, a);
        if (toAccessKit(member) == action)
        {
            result = member;
            return true;
        }
    }
    return false;
}
