module mayfair.code.lspeditor;

/*
    What a language server knows, shown in a TextView as it's edited:

        - errors and warnings: underlined with a squiggle, a dot beside their line, and their
          message in a tooltip when the pointer rests on them;
        - completions: a list under the caret, after one of the server's trigger characters
          (".", "::") or Ctrl+Space, narrowed as a word's typed; Up and Down choose, Enter or Tab
          put it in, Escape puts it away;
        - what something is: a tooltip, the pointer resting on it;
        - where it's defined: F12, or a Ctrl+click, which onGoToDefinition hears.

        auto editor = new LspEditor(document, view);
        editor.onGoToDefinition((Location l) { open(l.path, l.position); });
*/

import std.algorithm : canFind, filter, max, min, sort, startsWith;
import std.array : array;
import std.string : toLower;
import std.uni : isAlphaNum;
import mayfair;
import mayfair.code.lsp;

final class LspEditor
{
public:
    this(LspDocument document, TextView view)
    {
        this.document = document;
        this.view = view;
        auto b = document.buffer;
        errorTag = new TextTag("error").underlined(Underline.squiggle, Colour(229, 57, 53)).ranked(20);
        warningTag = new TextTag("warning").underlined(Underline.squiggle, Colour(240, 160, 0)).ranked(19);
        infoTag = new TextTag("information").underlined(Underline.squiggle, Colour(30, 136, 229)).ranked(18);
        hintTag = new TextTag("hint").underlined(Underline.single, Colour(140, 140, 140)).ranked(17);
        document.addDiagnosticsListener(&showDiagnostics);
        b.addListener(&edited);
        view.addKeyFilter(&key);
        view.onHover(&hovered, &hoverEnded);
        view.onControlClick((TextPosition at) { goToDefinition(at); });
        view.caretPositionProperty.addListener((TextPosition was, TextPosition now) { caretMoved(); });
        showDiagnostics();
    }

    LspDocument document;
    TextView view;

    /// Hears where F12 or a Ctrl+click says something's defined: for the app to open, if it's another file.
    /// Unset, a definition in this file is gone to, and one in another isn't.
    LspEditor onGoToDefinition(void delegate(Location) handler) { _onGoToDefinition = handler; return this; }

    /// Asks for completions at the caret, and shows them.
    void complete()
    {
        const at = view.caretPosition;
        const gen = ++requests;
        document.complete(at, (Completion[] list) {
            if (gen != requests)
                return; // asked again since, or put away
            if (view.caretPosition != at && !(view.caretPosition.line == at.line && view.caretPosition.column > at.column))
                return; // the caret's gone elsewhere since
            all = list;
            showCompletions();
        });
    }

    /// Goes to the definition of what's at `at`: in this view, or by onGoToDefinition.
    void goToDefinition(TextPosition at)
    {
        document.definition(at, (Location[] found) {
            if (!found.length)
                return;
            if (_onGoToDefinition)
                _onGoToDefinition(found[0]);
            else if (found[0].path == document.path)
                view.placeCaret(found[0].position);
        });
    }

    /// Whether the completion list is showing.
    bool completing() const { return list !is null && list.showing; }

    /// What the list shows now: for tests.
    string[] completionLabels()
    {
        string[] labels;
        foreach (c; shown)
            labels ~= c.label;
        return labels;
    }

    /// Stops showing what the server says, and following the view.
    void detach()
    {
        hideCompletions();
        hideTooltip();
        auto b = document.buffer;
        b.removeListener(&edited);
        foreach (t; [errorTag, warningTag, infoTag, hintTag])
            b.removeTagEverywhere(t);
        foreach (m; marks)
            view.removeGutterMark(m);
    }

private:
    TextTag errorTag, warningTag, infoTag, hintTag;
    TextMark[] marks;
    void delegate(Location) _onGoToDefinition;
    Completion[] all, shown;
    uint requests;     // completions asked for: an answer to any but the last is dropped
    int chosen;
    Popup list;
    Column rows;
    Popup tooltip;

    // Diagnostics

    void showDiagnostics()
    {
        auto b = document.buffer;
        foreach (t; [errorTag, warningTag, infoTag, hintTag])
            b.removeTagEverywhere(t);
        foreach (m; marks)
        {
            view.removeGutterMark(m);
            b.deleteMark(m);
        }
        marks = null;
        bool[int] marked;
        foreach (d; document.diagnostics)
        {
            auto end = d.end;
            if (end <= d.start)
            {
                // Nothing wide: the word, or character, it's at
                const l = b.line(d.start.line);
                size_t e = d.start.column;
                while (e < l.length && (isAlphaNum(l[e]) || l[e] == '_'))
                    e++;
                end = TextPosition(d.start.line, e > d.start.column ? e : min(d.start.column + 1, l.length));
            }
            b.applyTag(tagFor(d.severity), d.start, end);
            if (d.start.line !in marked && d.severity <= Severity.warning)
            {
                marked[d.start.line] = true;
                auto m = b.createMark(TextPosition(d.start.line, 0), true);
                marks ~= m;
                view.addGutterMark(m, d.severity == Severity.error ? Colour(229, 57, 53) : Colour(240, 160, 0));
            }
        }
    }

    TextTag tagFor(Severity s)
    {
        final switch (s)
        {
            case Severity.error: return errorTag;
            case Severity.warning: return warningTag;
            case Severity.information: return infoTag;
            case Severity.hint: return hintTag;
        }
    }

    // Completion

    bool key(ref KeyEvent event)
    {
        if (event.type != KeyEventType.pressed)
            return false;
        hideTooltip();
        const ctrl = event.control || event.meta;
        if (ctrl && event.code == KeyCode.space)
        {
            complete();
            return true;
        }
        if (event.code == KeyCode.f12)
        {
            goToDefinition(view.caretPosition);
            return true;
        }
        if (!completing)
            return false;
        switch (event.code)
        {
            case KeyCode.up:
                choose(chosen - 1);
                return true;
            case KeyCode.down:
                choose(chosen + 1);
                return true;
            case KeyCode.pageUp:
                choose(chosen - 8);
                return true;
            case KeyCode.pageDown:
                choose(chosen + 8);
                return true;
            case KeyCode.enter, KeyCode.numpadEnter, KeyCode.tab:
                accept();
                return true;
            case KeyCode.escape:
                hideCompletions();
                return true;
            default:
                return false;
        }
    }

    // Typing: a trigger character asks again; a word's characters narrow what's shown
    void edited(ref const BufferChange c)
    {
        if (!view.focused)
            return;
        const ins = c.inserted;
        if (ins.length >= 1 && ins.length <= 2 && !c.removed.length)
        {
            foreach (t; document.server.completionTriggers)
                if (t.length && (ins == t || (ins.length == 1 && t[$ - 1] == ins[0] && precededBy(c.start, t[0 .. $ - 1]))))
                {
                    Platform.runLater({ complete(); });
                    return;
                }
        }
        if (completing)
            Platform.runLater({ showCompletions(); });
    }

    bool precededBy(TextPosition at, string text)
    {
        if (!text.length)
            return true;
        const l = document.buffer.line(at.line);
        return at.column >= text.length && l[at.column - text.length .. at.column] == text;
    }

    /// The word before the caret, being typed: what the list's narrowed by.
    TextPosition wordStart()
    {
        const at = view.caretPosition;
        const l = document.buffer.line(at.line);
        size_t s = at.column;
        while (s > 0 && (isAlphaNum(l[s - 1]) || l[s - 1] == '_' || l[s - 1] >= 0x80))
            s--;
        return TextPosition(at.line, s);
    }

    void caretMoved()
    {
        if (!completing)
            return;
        // Off the line, or before the word: the list's for somewhere else
        const at = view.caretPosition, start = wordStart();
        if (at.line != start.line)
            hideCompletions();
    }

    void showCompletions()
    {
        hideTooltip();
        const start = wordStart(), at = view.caretPosition;
        const typed = document.buffer.textIn(start, at).toLower;
        // Those starting with what's typed, then those with it elsewhere in them, each in the server's order
        shown = all.filter!(c => !typed.length || filterText(c).toLower.startsWith(typed)).array
              ~ (typed.length > 1 ? all.filter!(c => !filterText(c).toLower.startsWith(typed)
                                                  && filterText(c).toLower.canFind(typed)).array : null);
        if (!shown.length)
        {
            hideCompletions();
            return;
        }
        if (shown.length > 200)
            shown = shown[0 .. 200];
        if (!list)
        {
            rows = new Column().padding(Insets(4));
            auto pane = new ScrollPane(rows).prefWidth(380).maxHeight(260);
            pane.setFitToWidth(true);
            list = new Popup(pane);
            list.setTakesFocus(false); // the view keeps the keyboard: Up, Down, Enter come by its key filter
            list.setAutoHide(false);
            list.styleClass.add("completion-list");
        }
        while (rows.children.length)
            rows.remove(cast(Widget) rows.children[0]);
        foreach (i, c; shown)
            rows.add(row(cast(int) i, c));
        chosen = 0;
        highlight();
        const r = view.rectInScene(start);
        if (!list.showing)
            list.showAt(view, r.minX - 8, r.maxY + 2);
    }

    static string filterText(ref const Completion c) { return c.label; }

    Widget row(int i, Completion c)
    {
        auto label = new Label(c.label).grow(1);
        auto r = new Row().spacing(10).padding(Insets(3, 8)).alignment(Pos.centreLeft);
        r.add(new Label(kindName(c.kind)).prefWidth(56).style("font-size: 11px; colour: var(--prompt-text);"));
        r.add(label);
        if (c.detail.length)
            r.add(new Label(c.detail.length > 40 ? c.detail[0 .. 40] ~ "…" : c.detail)
                  .style("font-size: 11px; colour: var(--prompt-text);"));
        r.setCursor(Cursor.hand);
        r.setOnMouseClicked((ref e) { chosen = i; accept(); });
        return r;
    }

    static string kindName(int k)
    {
        switch (k)
        {
            case 2: return "method";
            case 3: return "function";
            case 4: return "constructor";
            case 5: return "field";
            case 6: return "variable";
            case 7: return "class";
            case 8: return "interface";
            case 9: return "module";
            case 10: return "property";
            case 13: return "enum";
            case 14: return "keyword";
            case 15: return "snippet";
            case 21: return "constant";
            case 22: return "struct";
            default: return "";
        }
    }

    void choose(int i)
    {
        if (!shown.length)
            return;
        chosen = i < 0 ? 0 : i >= shown.length ? cast(int) shown.length - 1 : i;
        highlight();
    }

    void highlight()
    {
        foreach (i, r; rows.children)
            (cast(Widget) r).setStyle(i == chosen ? "background-colour: var(--row-selected); background-radius: 4;" : "");
    }

    void accept()
    {
        if (!completing || chosen >= shown.length)
            return;
        const c = shown[chosen];
        hideCompletions();
        auto b = document.buffer;
        const at = view.caretPosition;
        const from = c.hasRange && c.replaceFrom.line == at.line ? c.replaceFrom : wordStart();
        const to = c.hasRange && c.replaceTo > at ? c.replaceTo : at;
        b.breakMerging();
        view.select(from, to);
        view.replaceSelection(c.insertText);
        b.breakMerging();
    }

    void hideCompletions()
    {
        requests++; // what's asked for and still coming isn't wanted now
        if (list && list.showing)
            list.hide();
    }

    // Hovering

    void hovered(TextPosition at, float sceneX, float sceneY)
    {
        // What's wrong there, first; then what the server says it is
        string[] lines;
        foreach (d; document.diagnostics)
            if (at >= d.start && at <= (d.end > d.start ? d.end : TextPosition(d.start.line, d.start.column + 1)))
                lines ~= (d.source.length ? d.source ~ ": " : "") ~ d.message;
        document.hover(at, (string text) {
            if (text.length)
                lines ~= text;
            if (lines.length)
                showTooltip(lines, sceneX, sceneY);
        });
    }

    void hoverEnded() { hideTooltip(); }

    void showTooltip(string[] lines, float x, float y)
    {
        import std.array : join;
        hideTooltip();
        auto text = new Label(lines.join("\n\n")).wrapText(true).maxWidth(520);
        text.styleClass.add("code-tooltip");
        tooltip = new Popup(new Column().padding(Insets(8, 10)).add(text));
        tooltip.setTakesFocus(false);
        tooltip.setAutoHide(false);
        tooltip.setPointerTransparent(true);
        tooltip.showAt(view, x + 8, y + 18);
    }

    void hideTooltip()
    {
        if (tooltip && tooltip.showing)
            tooltip.hide();
        tooltip = null;
    }
}
