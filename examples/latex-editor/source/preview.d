module preview;

import std.file : copy, exists, remove;
import std.path : buildPath, dirName;
import mayfair;
import mayfair.pdf;
import compiler;
import synctex : PdfPlace;

/*
    The PDF, as it was last compiled, on the right: a PreviewPane, laid out in preview.xml.

    Each compile's PDF is shown where the last one was being read: the same page, the same zoom.
    It's a copy that's shown, not the PDF TeX writes, as TeX writes that file while it compiles,
    and the copy shown is never written to. A double click on the PDF asks the workspace to go to
    the source that made what's there (onSourceWanted). The compile's errors and warnings are
    listed under the PDF when Logs is pressed, and choosing one goes to it (onProblemChosen).
*/
@View("preview.xml")
final class PreviewPane : Column
{
public:
    /// Recompile pressed, or Auto turned on or off, or the engine chosen.
    void delegate() onCompile;
    void delegate(bool on) onAutoChanged;    /// ditto
    void delegate(Engine) onEngineChanged;  /// ditto

    /// A problem chosen in the logs, to go to.
    void delegate(Problem) onProblemChosen;

    /// A place in the PDF double-clicked: page from 0, and where on it, in points.
    void delegate(int page, float x, float y) onSourceWanted;

    this()
    {
        View.load(this);
        pdf.setFit(PdfFit.width);
        pdf.onPagePressed((int page, float x, float y, int clicks) {
            if (clicks != 2 || !onSourceWanted)
                return false;
            onSourceWanted(page, x, y);
            return true;
        });
        pdf.currentPageProperty.addListener((int was, int now) { showPage(); });
        problemList.onSelectionChanged({
            const i = problemList.selectedIndex;
            if (i >= 0 && onProblemChosen)
                onProblemChosen(problemList.selectedItem);
        });
        engineBox.setSelectedIndex(0);
        engineBox.selectedIndexProperty.addListener((int was, int now) {
            if (onEngineChanged && now >= 0)
                onEngineChanged(cast(Engine) now);
        });
    }

    /// Says a compile's started.
    void compiling()
    {
        statusLabel.setText(tr!"compiling");
        compileButton.setDisable(true);
    }

    /// Shows how a compile went: its PDF, if it made one, and its problems.
    void show(CompileResult r)
    {
        compileButton.setDisable(false);
        problemList.setItems(r.problems.dup);
        int errors, warnings;
        foreach (ref p; r.problems)
            (p.error ? errors : warnings)++;
        logsButton.setText(errors + warnings ? tr!"logs" ~ " (" ~ to!string(errors + warnings) ~ ")" : tr!"logs");
        if (!r.ran)
        {
            statusLabel.setText(tr!"compile_failed"(r.failure));
            return;
        }
        statusLabel.setText(errors ? tr!"problems"(errors, warnings) : tr!"compiled"(seconds(r.took)));
        if (errors && !logsShown)
            toggleLogs();
        if (r.pdf.length)
            load(r.pdf);
    }

    /// Scrolls to `place`, a little above it, so the line's in view with what's before it.
    void scrollTo(PdfPlace place)
    {
        if (place.page < 0 || !pdf.document)
            return;
        pdf.goToPage(place.page, place.y - place.height - 60 > 0 ? place.y - place.height - 60 : 0);
    }

    /// The document shown, to ask SyncTeX about: the PDF TeX made, not the copy.
    string compiledPdf() const { return source; }

    /// Shows nothing: no PDF, no problems, as a project's closed.
    void clear()
    {
        if (auto old = pdf.document)
        {
            pdf.setDocument(null);
            old.close();
        }
        source = null;
        placeholder.setVisible(true);
        problemList.setItems(null);
        statusLabel.setText("");
        logsButton.setText(tr!"logs");
        compileButton.setDisable(false);
        showPage();
        if (logsShown)
            toggleLogs();
    }

private:
    @xml PdfView pdf;
    @xml Label placeholder, statusLabel, pageLabel;
    @xml Button compileButton;
    @xml ToggleButton autoButton, logsButton;
    @xml ComboBox engineBox;
    @xml Column logPane;
    @xml ListView!Problem problemList;
    string source;        // the PDF TeX made
    string[2] copies;     // the copies shown, one after the other
    int nextCopy;
    bool logsShown;

    // The new PDF, where the old one was being read
    void load(string made)
    {
        source = made;
        const copyPath = buildPath(dirName(made), nextCopy ? "preview-b.pdf" : "preview-a.pdf");
        nextCopy ^= 1;
        try
            copy(made, copyPath);
        catch (Exception)
            return;
        auto old = pdf.document;
        const page = pdf.currentPage, fit = pdf.fit, zoom = pdf.zoom;
        auto doc = PdfDocument.open(copyPath);
        doc.statusProperty.addListener((PdfStatus was, PdfStatus now) {
            if (now != PdfStatus.ready)
                return;
            pdf.setDocument(doc);
            if (fit == PdfFit.none)
                pdf.setZoom(zoom);
            else
                pdf.setFit(fit);
            pdf.goToPage(page < doc.pageCount ? page : doc.pageCount - 1);
            placeholder.setVisible(false);
            showPage();
            if (old)
                old.close();
        });
    }

    void showPage()
    {
        auto doc = pdf.document;
        pageLabel.setText(doc && doc.status == PdfStatus.ready ? tr!"page_of"(pdf.currentPage + 1, doc.pageCount) : "");
    }

    static string seconds(Duration d)
    {
        import std.format : format;
        return format!"%.1f s"(d.total!"msecs" / 1000.0);
    }

    // The toolbar's buttons
    void compile() { if (onCompile) onCompile(); }
    void autoChanged() { if (onAutoChanged) onAutoChanged(autoButton.selected); }
    void zoomIn() { pdf.zoomIn(); }
    void zoomOut() { pdf.zoomOut(); }
    void fitWidth() { pdf.setFit(PdfFit.width); }

    void toggleLogs()
    {
        logsShown = !logsShown;
        logsButton.setSelected(logsShown);
        logPane.setVisible(logsShown);
    }
}

private import std.conv : to;
private import core.time : Duration;
