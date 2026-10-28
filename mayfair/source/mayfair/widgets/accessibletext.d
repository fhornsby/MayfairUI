module mayfair.widgets.accessibletext;

import mayfair.accessibility;
import mayfair.widgets.textinputcontrol : concealer, concealed;

/*
    Text laid out in lines, as a screen reader is given it: what a text field and a selectable label
    have in common. AccessKit wants text as text runs -- a line at a time, each saying where every
    character is, which way it reads and where words start -- which is what lets a screen reader
    read by character, word or line, follow the selection and set it.

    The lines are the widget's own, each with `start` (where in the text it starts), `line` (an
    EditableLine), `x` and `top` (where it is from the text's top left) and `breaks` (whether a
    line break in the text ends it, rather than wrapping).
*/
package struct AccessibleText
{
public:
    /*
        Adds the runs of `lines` below `node`, the text's top left at `ox`, `oy` in the window, and
        the selection from `anchor` to `caret`. `conceals` gives the runs dots for the text, as a
        password field's.
    */
    void describe(L)(ref AccessibleNode node, const(L)[] lines, float ox, float oy, float lineHeight,
                     bool conceals, size_t anchor, size_t caret)
    {
        runs = null;
        foreach (li, ref l; lines)
        {
            auto line = &l.line;
            // Runs on this line: a new one wherever the direction changes, or at 255 characters,
            // as AccessKit counts a run's characters in bytes
            size_t[] firsts = [0];
            foreach (i; 1 .. line.length)
                if (line.rightToLeft[i] != line.rightToLeft[i - 1] || i - firsts[$ - 1] >= charactersPerRun)
                    firsts ~= i;
            firsts ~= line.length;
            foreach (r; 0 .. firsts.length - 1)
                runs ~= Run(nextRunId(), firsts[r], firsts[r + 1], cast(uint) li);
        }
        foreach (k, ref run; runs)
        {
            const l = &lines[run.lineIndex];
            const line = &l.line;
            const lastOfLine = k + 1 == runs.length || runs[k + 1].lineIndex != run.lineIndex;
            // A line that a line break ends has it at the end of its last run, with no width
            const withBreak = lastOfLine && l.breaks && run.lineIndex + 1 < lines.length;
            const first = run.first, last = run.last;
            const rtl = line.length && line.rightToLeft[first < line.length ? first : $ - 1];
            const prevId = k > 0 && runs[k - 1].lineIndex == run.lineIndex ? runs[k - 1].id : 0;
            const nextId = !lastOfLine ? runs[k + 1].id : 0;
            node.addChild(run.id, AccessibleRole.textRun, (ref AccessibleNode r) {
                // The run's extent, which its characters are measured from: from its right edge,
                // if it reads right to left
                float x0 = float.infinity, x1 = -float.infinity;
                foreach (i; first .. last)
                {
                    if (line.left[i] < x0) x0 = line.left[i];
                    if (line.right[i] > x1) x1 = line.right[i];
                }
                if (first == last)
                    x0 = x1 = line.xAt(line.stops[first]);

                ubyte[] lengths, wordStarts;
                float[] positions, widths;
                foreach (i; first .. last)
                {
                    const bytes = conceals ? concealer.length : line.stops[i + 1] - line.stops[i];
                    lengths ~= cast(ubyte)(bytes < 255 ? bytes : 255);
                    positions ~= rtl ? x1 - line.right[i] : line.left[i] - x0;
                    widths ~= line.right[i] - line.left[i];
                    if (line.wordStart[i])
                        wordStarts ~= cast(ubyte)(i - first);
                }
                string value = conceals ? concealed(last - first) : line.text[line.stops[first] .. line.stops[last]];
                if (withBreak)
                {
                    value ~= "\n";
                    lengths ~= 1;
                    positions ~= rtl ? 0 : x1 - x0;
                    widths ~= 0;
                }
                r.value(value);
                r.textDirection(rtl);
                r.characters(lengths, positions, widths, wordStarts);
                r.boundsInScene(ox + l.x + x0, oy + l.top, x1 - x0, lineHeight);
                if (prevId)
                    r.previousOnLine(prevId);
                if (nextId)
                    r.nextOnLine(nextId);
            });
        }
        node.textSelection(position(lines, anchor), position(lines, caret));
    }

    /// Whether `id` is one of the runs, as last described.
    bool owns(ulong id) const nothrow @nogc
    {
        foreach (ref run; runs)
            if (run.id == id)
                return true;
        return false;
    }

    /*
        AccessKit's place in a run back to an offset in the text of `lines`, `textLength` long; or
        `otherwise` if it's not in one of the runs.
    */
    size_t offsetOf(L)(const(L)[] lines, AccessibleTextPosition p, size_t textLength, size_t otherwise) const nothrow @nogc
    {
        foreach (ref run; runs)
        {
            if (run.id != p.node)
                continue;
            const character = run.first + p.character;
            const l = &lines[run.lineIndex < lines.length ? run.lineIndex : $ - 1];
            if (character >= l.line.stops.length)
            {
                const end = l.start + l.line.text.length;
                return end < textLength ? end + (l.breaks ? 1 : 0) : textLength;
            }
            return l.start + l.line.stops[character];
        }
        return otherwise;
    }

private:
    struct Run
    {
        ulong id;
        size_t first, last; // characters of its line
        uint lineIndex;
    }

    enum charactersPerRun = 255;

    Run[] runs;      // as last described
    ulong[] runIds;  // ids handed out for them, reused in order so a screen reader keeps its place
    size_t nextRun;

    ulong nextRunId()
    {
        if (!runs.length)
            nextRun = 0;
        if (nextRun == runIds.length)
            runIds ~= newAccessibleId();
        return runIds[nextRun++];
    }

    /// A text offset as AccessKit gives places in text: a run, and a character in it. A place
    /// between two runs is at the start of the second, except at the very end.
    AccessibleTextPosition position(L)(const(L)[] lines, size_t offset) const nothrow @nogc
    {
        foreach_reverse (ref run; runs)
        {
            const l = &lines[run.lineIndex];
            if (offset < l.start)
                continue;
            const character = l.line.indexOf(offset - l.start);
            if (character >= run.first)
                return AccessibleTextPosition(run.id, character - run.first);
        }
        return AccessibleTextPosition(runs.length ? runs[0].id : 0, 0);
    }
}
