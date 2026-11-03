module mayfair.widgets.dialog;

import mayfair.accessibility;
import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.button;
import mayfair.widgets.input;
import mayfair.widgets.label;
import mayfair.widgets.layouts;
import mayfair.widgets.popup;
import mayfair.widgets.styling;
import mayfair.widgets.widget;

/// What a dialog's button does besides its own action: which key presses it.
enum ButtonKind
{
    normal,
    default_, /// Enter presses it, wherever focus is in the dialog; drawn in the accent
    cancel,   /// Escape presses it
}

/*
    A question, over the window, that has to be answered before anything else: a title, what it's
    about, and buttons to answer with. The window behind is dimmed and waits.

        new Dialog("Delete “notes.txt”?")
            .text("It will be gone for good.")
            .addButton("Cancel", null, ButtonKind.cancel)
            .addButton("Delete", { deleteIt(); }, ButtonKind.default_)
            .show(window);

    Any of its buttons closes it, having done what it does. Enter presses the default button and
    Escape the cancel one -- or with no cancel button, just closes it. Something more than text,
    such as a field to fill in, goes in `extra`, under the text. A button that does something
    beside answering -- Help, Import… -- goes at the start of the row, apart from the others, with
    addStartButton.

    Its style class is "dialog", as well as "popup", with a `.title`, the `.text`, and the
    `.buttons`. To a screen reader it's a dialog named by its title.
*/
@DefaultProperty("extra")
class Dialog : Popup
{
public:
    this(string title)
    {
        _titleLabel = new Label(title).wrapText(true);
        _titleLabel.styleClass.add("title");
        _textLabel = new Label("").wrapText(true);
        _textLabel.styleClass.add("text");
        _textLabel.setVisible(false);
        _buttons = new Row().alignment(Pos.centreRight).fillHeight(false);
        _buttons.styleClass.add("buttons");
        _box = new Column();
        _box.styleClass.add("dialog-box");
        _box.add(_titleLabel).add(_textLabel).add(_buttons);
        super(_box);
        _title = title;
        styleClass.add("dialog");
        setModal(true);
        setAutoHide(false);
        setAccessibleRole(AccessibleRole.dialog);
        setAccessibleText(title);
    }

    /// Its title.
    mixin(declareProperty!(string, "title", "null", q{
        _titleLabel.setText(_title);
        setAccessibleText(_title);
    }));

    /// What it's about, under the title. Wraps.
    mixin(declareProperty!(string, "text", "null", q{
        _textLabel.setText(_text);
        _textLabel.setVisible(_text.length > 0);
    }));

    /// Anything more, under the text: a field to fill in, a check box.
    mixin(declareProperty!(Widget, "extra", "null", q{ showExtra(); }));

    /// Adds a button saying `text`, which does `action` -- if there is one -- and closes the dialog.
    final Dialog addButton(string text, void delegate() action = null, ButtonKind kind = ButtonKind.normal)
    {
        auto b = new Button(text).onAction(closing(action));
        b.setDefaultButton(kind == ButtonKind.default_);
        b.setCancelButton(kind == ButtonKind.cancel);
        _buttons.add(b);
        return this;
    }

    /*
        Adds a button saying `text` at the start of the row of buttons, on its own with a gap
        between it and the others, as GNOME and macOS put Help: one that does something beside
        answering. It does `action`, if there is one, and closes the dialog. Enter and Escape
        don't press it. One only; another replaces it.
    */
    final Dialog addStartButton(string text, void delegate() action = null)
    {
        Widget[] answers;
        foreach (w; _buttons.children.dup)
        {
            if (w !is _startButton && w !is _gap)
                answers ~= w;
            _buttons.remove(w);
        }
        _startButton = new Button(text).onAction(closing(action));
        if (!_gap)
            _gap = new Row().grow(1);   // pushes the answers to the end
        _buttons.add(_startButton).add(_gap);
        foreach (w; answers)
            _buttons.add(w);
        return this;
    }

    /// Shows it, in the middle of the window `owner` is in.
    final Dialog show(Widget owner)
    {
        showCentred(owner);
        return this;
    }

protected:
    override void handleKey(ref KeyEvent event)
    {
        // Escape with no cancel button to press: just close it
        if (event.type == KeyEventType.pressed && event.code == KeyCode.escape)
        {
            foreach (w; _buttons.children)
                if (auto b = cast(Button) w)
                    if (b.cancelButton)
                        return; // it's the button's, as a shortcut
            event.consume();
            hide();
        }
    }

private:
    Column _box;
    Label _titleLabel, _textLabel;
    Row _buttons;
    Widget _shownExtra;
    Button _startButton;
    Row _gap;           // between the start button and the rest

    void delegate() closing(void delegate() action)
    {
        return {
            hide();
            if (action)
                action();
        };
    }

    void showExtra()
    {
        if (_shownExtra)
            _box.remove(_shownExtra);
        _shownExtra = _extra;
        if (_extra)
        {
            _box.remove(_buttons);
            _box.add(_extra).add(_buttons);
        }
    }
}
