module mayfair.widgets.passwordfield;

import mayfair.accessibility;
import mayfair.text;
import mayfair.widgets.textfield;
import mayfair.widgets.textinputcontrol;

/*
    A field for a password, or anything else secret: it shows a dot for each character rather than
    the text. JavaFX's PasswordField.

        <PasswordField id="password" promptText="Password" onAction="signIn"/>

    Everything else is a TextField's, except what would let the secret out: it can't be copied or
    cut (paste still works, for a password manager's), selecting in it doesn't set the primary
    selection, and a screen reader hears the dots, as it would in any other app. With nothing but
    dots to go by there are no words in it either, so Ctrl+Left and Ctrl+Right go to its ends, and a
    double click selects it all.
*/
class PasswordField : TextField
{
public:
    this(string text = "")
    {
        super(text);
        setAccessibleRole(AccessibleRole.passwordField);
        styleClass.add("password-field");
    }

protected:
    override bool concealsText() const nothrow @nogc { return true; }

    // The text's own stops, so the caret and selection still count its characters as a reader
    // does, at where the dots that stand for them are
    override VisualLine[] layoutLines(string text)
    {
        const actual = editableLine(font, text);
        auto line = editableLine(font, concealed(actual.length));
        line.text = text;
        line.stops = actual.stops.dup;
        line.wordStart[] = line.wordEnd[] = line.boundary[] = false;
        line.boundary[0] = line.boundary[$ - 1] = true;
        line.wordStart[0] = line.wordEnd[$ - 1] = text.length > 0;
        return [VisualLine(0, line, 0, 0, true)];
    }
}

unittest
{
    static class Probe : PasswordField
    {
        this(string text) { super(text); }
        EditableLine shown() { return lines[0].line; }
    }
    auto field = new Probe("hé你");
    assert(field.text == "hé你");
    const line = field.shown;
    assert(line.text == "hé你" && line.stops == [0, 1, 3, 6], "the text's characters, not the dots'");
    assert(line.x.length == 4 && line.x[1] > 0 && line.x[2] - line.x[1] == line.x[1] - line.x[0],
           "each as wide as a dot");
    assert(line.previousWordStart(6) == 0 && line.nextWordEnd(0) == 6, "no words but the whole");
    field.selectAll();
    field.copy(); // does nothing; a test can't see the clipboard, but it mustn't throw either
    assert(field.selectedText == "hé你", "the app can still read it");
    assert(new Probe("").shown.stops == [0]);
}
