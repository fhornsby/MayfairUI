module dialogs;

/*
    The viewer's dialogs: what a document is (its inspector), printing, exporting -- as a PDF, with
    or without a password, or as pictures -- editing a note's or text box's text, and asking
    whether to save before closing.
*/

import std.algorithm : canFind, endsWith, startsWith;
import std.array : split;
import std.conv : to;
import std.file : exists, getSize, tempDir;
import std.format : format;
import std.path : baseName, buildPath, dirName, stripExtension;
import std.process : execute, spawnProcess, Config;
import std.string : lineSplitter, strip, toLower;
import mayfair;
import mayfair.pdf;

/// The document's details: its file, its pages, what it says about itself.
void showInfo(Widget owner, PdfDocument doc, PdfView view)
{
    auto grid = new Column().spacing(6).prefWidth(420);
    void line(string name, string value)
    {
        if (!value.length)
            return;
        grid.add(new Row().spacing(12)
            .add(new Label(name).prefWidth(110).style("colour: var(--prompt-text);"))
            .add(new Label(value).wrapText(true).maxWidth(300).grow(1)));
    }
    const path = doc.path;
    line("File", baseName(path));
    line("Where", dirName(path));
    try
        line("Size", bytes(getSize(path)));
    catch (Exception) {}
    line("Pages", doc.pageCount.to!string);
    const s = doc.pageSize(view.currentPage);
    line("Page size", format!"%.0f × %.0f pt (%.0f × %.0f mm)"(s.width, s.height, s.width * 25.4 / 72, s.height * 25.4 / 72));
    const meta = doc.metadata;
    foreach (key; ["Title", "Author", "Subject", "Keywords", "Creator", "Producer"])
        if (auto v = key in meta)
            line(key, *v);
    if (auto v = "CreationDate" in meta)
        line("Created", pdfDate(*v));
    if (auto v = "ModDate" in meta)
        line("Modified", pdfDate(*v));
    const info = doc.info;
    line("PDF version", info.pdfVersion);
    line("Encrypted", info.encrypted ? "Yes" : "No");
    line("Form", info.hasForm ? "Has fields to fill in" : "");
    line("Edited", doc.edited ? "Yes, not saved yet" : "");
    new Dialog("Document Info").extra(grid).addButton("Close", null, ButtonKind.default_).show(owner);
}

private string bytes(ulong n)
{
    if (n < 1024)
        return format!"%s bytes"(n);
    if (n < 1024 * 1024)
        return format!"%.1f KB"(n / 1024.0);
    return format!"%.1f MB"(n / (1024.0 * 1024));
}

/// A PDF date -- "D:20261124093000+01'00'" -- as a person reads one.
string pdfDate(string d)
{
    if (d.startsWith("D:"))
        d = d[2 .. $];
    if (d.length < 8)
        return d;
    string s = d[0 .. 4] ~ "-" ~ d[4 .. 6] ~ "-" ~ d[6 .. 8];
    if (d.length >= 12)
        s ~= " " ~ d[8 .. 10] ~ ":" ~ d[10 .. 12];
    return s;
}

/// Edits annotation `a`'s text -- a note's, a text box's -- in a dialog; `done` with the text, unless cancelled.
void editText(PdfView view, int page, PdfAnnotation a, void delegate(string text) done)
{
    auto area = new TextArea(a.text).prefWidth(360).prefHeight(a.kind == PdfAnnotationKind.note ? 160 : 110);
    area.setWrapText(true);
    auto dialog = new Dialog(a.kind == PdfAnnotationKind.note ? "Note" : "Text")
        .extra(area)
        .addButton("Cancel", { done(a.text); }, ButtonKind.cancel)
        .addButton("Done", { done(area.text); }, ButtonKind.default_);
    dialog.show(view);
    import mayfair.windowing.platform : Platform;
    Platform.runLater({ area.requestFocus(); area.selectAll(); });
}

/// Asks whether to save `doc`'s changes: `then` once it's saved or the changes are let go; not if cancelled.
void askToSave(Widget owner, PdfDocument doc, void delegate(void delegate()) save, void delegate() then)
{
    new Dialog(format!"Save the changes to “%s”?"(baseName(doc.path)))
        .text("If you don't, they're lost.")
        .addStartButton("Don't Save", then)
        .addButton("Cancel", null, ButtonKind.cancel)
        .addButton("Save", { save(then); }, ButtonKind.default_)
        .show(owner);
}

// Printing: by the system's printing, CUPS, with lp -- on Linux, the BSDs and macOS

/// The printers CUPS has, the default first; null if there's no CUPS.
string[] printers()
{
    string[] found;
    try
    {
        auto list = execute(["lpstat", "-e"]);
        if (list.status != 0)
            return null;
        foreach (l; list.output.lineSplitter)
            if (l.strip.length)
                found ~= l.strip;
        auto d = execute(["lpstat", "-d"]);
        if (d.status == 0)
        {
            const parts = d.output.strip.split(": ");
            if (parts.length == 2 && found.canFind(parts[1]))
                found = [parts[1]] ~ found.remove(parts[1]);
        }
    }
    catch (Exception)
        return null;
    return found;
}

private string[] remove(string[] list, string item)
{
    string[] kept;
    foreach (l; list)
        if (l != item)
            kept ~= l;
    return kept;
}

/// Asks how to print `doc`, then prints it -- as it is now, with what's marked on it -- with lp.
void print(Widget owner, PdfDocument doc, PdfView view, void delegate(string) report)
{
    version (Windows)
    {
        new Dialog("Printing isn't here yet").text("On Windows, export the PDF and print it from another app.")
            .addButton("OK", null, ButtonKind.default_).show(owner);
        return;
    }
    else
    {
        auto names = printers();
        if (!names.length)
        {
            new Dialog("There's no printer").text("Printing goes through CUPS, the system's printing, and it has no printers, or isn't installed.")
                .addButton("OK", null, ButtonKind.default_).show(owner);
            return;
        }
        auto printer = new ComboBox(names).selectedIndex(0);
        auto copies = new TextField("1").prefWidth(60);
        auto which = new ComboBox(["All pages", "This page", "Pages:"]).selectedIndex(0);
        auto range = new TextField("").promptText("1-3, 5").prefWidth(120);
        auto form = new Column().spacing(8)
            .add(new Row().spacing(8).alignment(Pos.centreLeft).add(new Label("Printer").prefWidth(70)).add(printer))
            .add(new Row().spacing(8).alignment(Pos.centreLeft).add(new Label("Copies").prefWidth(70)).add(copies))
            .add(new Row().spacing(8).alignment(Pos.centreLeft).add(new Label("Pages").prefWidth(70)).add(which).add(range));
        new Dialog("Print").extra(form)
            .addButton("Cancel", null, ButtonKind.cancel)
            .addButton("Print", {
                const target = names[printer.selectedIndex < 0 ? 0 : printer.selectedIndex];
                string pages;
                if (which.selectedIndex == 1)
                    pages = (view.currentPage + 1).to!string;
                else if (which.selectedIndex == 2)
                    pages = range.text.strip;
                const file = buildPath(tempDir, "mayfair-print-" ~ baseName(doc.path));
                doc.save(file, PdfSaveOptions(true, true), (PdfError error) {
                    if (error)
                    {
                        report("It couldn't be printed: " ~ error.message);
                        return;
                    }
                    auto command = ["lp", "-d", target, "-n", copies.text.strip.length ? copies.text.strip : "1"];
                    if (pages.length)
                        command ~= ["-P", pages];
                    command ~= file;
                    try
                    {
                        auto r = execute(command);
                        report(r.status == 0 ? "Sent to " ~ target : "It couldn't be printed: " ~ r.output.strip);
                    }
                    catch (Exception e)
                        report("It couldn't be printed: " ~ e.msg);
                });
            }, ButtonKind.default_)
            .show(owner);
    }
}

// Exporting

/// Whether qpdf is there, to encrypt with.
bool haveQpdf()
{
    try
        return execute(["qpdf", "--version"]).status == 0;
    catch (Exception)
        return false;
}

/*
    Asks how to export `doc` -- as a PDF, password-protected or not, or each page as a PNG -- and
    where, then does it. `pages` are those to export as pictures: those selected, or the current.
*/
void export_(Widget owner, PdfDocument doc, int[] pages, void delegate(string) report)
{
    auto format_ = new ComboBox(["PDF", "PNG pictures"]).selectedIndex(0);
    const qpdf = haveQpdf();
    auto encrypt = new CheckBox("Protect it with a password");
    encrypt.setDisable(!qpdf);
    auto password = new PasswordField().prefWidth(200).promptText("Password");
    auto again = new PasswordField().prefWidth(200).promptText("Again");
    auto resolution = new ComboBox(["72 pixels an inch", "150 pixels an inch", "300 pixels an inch"]).selectedIndex(1);
    auto pdfOptions = new Column().spacing(6).add(encrypt).add(password).add(again);
    if (!qpdf)
        pdfOptions.add(new Label("Protecting needs qpdf, which isn't installed.").style("colour: var(--prompt-text); font-size: 12px;"));
    auto pngOptions = new Column().spacing(6)
        .add(new Label(pages.length == 1 ? "Page " ~ (pages[0] + 1).to!string : format!"%s pages"(pages.length)))
        .add(resolution);
    auto options = new Stack();
    options.add(pdfOptions);
    format_.selectedIndexProperty.addListener((int was, int now) {
        while (options.children.length)
            options.remove(cast(Widget) options.children[0]);
        options.add(now == 1 ? cast(Widget) pngOptions : pdfOptions);
    });
    auto form = new Column().spacing(10)
        .add(new Row().spacing(8).alignment(Pos.centreLeft).add(new Label("Format").prefWidth(60)).add(format_))
        .add(options);
    auto dialog = new Dialog("Export").extra(form);
    dialog.addButton("Cancel", null, ButtonKind.cancel);
    dialog.addButton("Export…", {
        const asPng = format_.selectedIndex == 1;
        const protect = !asPng && encrypt.selected;
        if (protect && (!password.text.length || password.text != again.text))
        {
            report(password.text.length ? "The passwords aren't the same" : "Give it a password");
            return;
        }
        const pass = password.text;
        const dpi = [72, 150, 300][resolution.selectedIndex < 0 ? 1 : resolution.selectedIndex];
        const name = stripExtension(baseName(doc.path)) ~ (asPng ? ".png" : protect ? " (protected).pdf" : ".pdf");
        auto chooser = new FileChooser().title("Export").initialFileName(name);
        if (asPng)
            chooser.addFilter("PNG pictures", "png");
        else
            chooser.addFilter("PDF documents", "pdf");
        chooser.showSaveDialog(owner, (string file) {
            if (!file)
                return;
            if (asPng)
                exportPictures(doc, pages, file, dpi, report);
            else if (protect)
                exportProtected(doc, file, pass, report);
            else
                doc.save(file, PdfSaveOptions(true, true), (PdfError e) {
                    report(e ? "It couldn't be exported: " ~ e.message : "Exported " ~ baseName(file));
                });
        });
    }, ButtonKind.default_);
    dialog.show(owner);
}

private void exportProtected(PdfDocument doc, string file, string pass, void delegate(string) report)
{
    const plain = buildPath(tempDir, "mayfair-export-" ~ baseName(file));
    doc.save(plain, PdfSaveOptions(true, true), (PdfError e) {
        if (e)
        {
            report("It couldn't be exported: " ~ e.message);
            return;
        }
        try
        {
            // AES-256: the password to open it, and the same to change it
            auto r = execute(["qpdf", "--encrypt", pass, pass, "256", "--", plain, file]);
            import std.file : remove;
            try remove(plain); catch (Exception) {}
            report(r.status == 0 ? "Exported " ~ baseName(file) ~ ", with a password" : "It couldn't be protected: " ~ r.output.strip);
        }
        catch (Exception x)
            report("It couldn't be protected: " ~ x.msg);
    });
}

/// Each of `pages` rendered at `dpi`, to `file` -- or, for more than one, file-1.png, file-2.png...
void exportPictures(PdfDocument doc, int[] pages, string file, int dpi, void delegate(string) report)
{
    import mayfair.widgets.canvas : encodePng;
    import std.file : write;
    int left = cast(int) pages.length;
    foreach (page; pages)
    {
        const s = doc.pageSize(page);
        const target = pages.length == 1 ? file : format!"%s-%s.png"(stripExtension(file), page + 1);
        renderTo(doc, page, s, dpi / 72.0f, (PdfBitmap b) {
            try
                write(target, encodePng(b.pixels, b.width, b.height));
            catch (Exception e)
                report("It couldn't be written: " ~ e.msg);
            if (--left == 0)
                report(pages.length == 1 ? "Exported " ~ baseName(file) : format!"Exported %s pictures"(pages.length));
        });
    }
}

private void renderTo(PdfDocument doc, int page, PdfSize s, float scale, void delegate(PdfBitmap) done)
{
    doc.render(page, PdfRect(0, 0, s.width, s.height), scale, 0, PdfPriority.visible, done);
}
