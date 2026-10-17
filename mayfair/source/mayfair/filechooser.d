module mayfair.filechooser;

import mayfair.log;
import std.string : fromStringz, toStringz;
import sdl.dialog : SDL_FileDialogType, SDL_PROP_FILE_DIALOG_ACCEPT_STRING, SDL_PROP_FILE_DIALOG_FILTERS_POINTER,
    SDL_PROP_FILE_DIALOG_LOCATION_STRING, SDL_PROP_FILE_DIALOG_MANY_BOOLEAN, SDL_PROP_FILE_DIALOG_NFILTERS_NUMBER,
    SDL_PROP_FILE_DIALOG_TITLE_STRING, SDL_PROP_FILE_DIALOG_WINDOW_POINTER, SDL_ShowFileDialogWithProperties, SDL_DialogFileCallback;
import sdl.error : SDL_GetError;
import sdl.properties;
import mayfair.widgets.widget : Widget;
import mayfair.windowing.platform : Platform;

/// A kind of file to offer in a FileChooser: a name for it, and the extensions it has.
struct ExtensionFilter
{
    string description;  /// what the user sees, e.g. "Pictures"
    string[] extensions; /// without the dot, e.g. ["png", "jpg"]; ["*"] for any file
}

/*
    The desktop's own dialog for choosing a file to open or save: JavaFX's FileChooser. On Linux
    it's the one xdg-desktop-portal shows (GNOME's, KDE's, whichever the desktop has), so it looks
    and works like every other app's, and a sandboxed app is let at what's chosen in it.

        new FileChooser()
            .title("Open picture")
            .addFilter("Pictures", "png", "jpg", "svg")
            .showOpenDialog(window, (path) {
                if (path)
                    load(path);
            });

    Unlike JavaFX's, it doesn't wait for the answer: the dialog is another process's window, and
    the UI carries on drawing while it's up. What was chosen is handed to the function given, on
    the UI thread, once the user has chosen -- or null, or an empty list, if they cancelled, or
    there was no dialog to show. The dialog is over the window `owner` is in, and modal to it
    where the desktop can do that.

    A save dialog asks before replacing a file that's there already, so what it gives back is
    safe to write to.
*/
class FileChooser
{
public:
    /// The dialog's title. The desktop picks one, e.g. "Open File", if it's null.
    final string title() const { return _title; }
    /// ditto
    final FileChooser title(string value) { _title = value; return this; }

    /// The folder it starts in. The desktop picks one if it's null, or isn't a folder there is:
    /// usually the last one used.
    final string initialDirectory() const { return _initialDirectory; }
    /// ditto
    final FileChooser initialDirectory(string value) { _initialDirectory = value; return this; }

    /// The name a save dialog suggests, e.g. "Untitled.txt". With no initialDirectory, the dialog
    /// then starts in the working directory, as the desktop can't be given a name on its own.
    final string initialFileName() const { return _initialFileName; }
    /// ditto
    final FileChooser initialFileName(string value) { _initialFileName = value; return this; }

    /// What the button that chooses says, in place of the desktop's "Open" or "Save".
    final string acceptText() const { return _acceptText; }
    /// ditto
    final FileChooser acceptText(string value) { _acceptText = value; return this; }

    /// The kinds of file offered, the first shown first. None means any file.
    final const(ExtensionFilter)[] filters() const { return _filters; }

    /// Offers files ending in any of `extensions` (no dots) as a kind called `description`.
    final FileChooser addFilter(string description, string[] extensions...)
    {
        _filters ~= ExtensionFilter(description, extensions.dup);
        return this;
    }

    /// Takes away the kinds of file offered, for any file again.
    final FileChooser clearFilters()
    {
        _filters = null;
        return this;
    }

    /// Asks for a file to open, and hands `chosen` its path, or null if none was chosen.
    final void showOpenDialog(Widget owner, void delegate(string path) chosen)
    {
        show(SDL_FileDialogType.SDL_FILEDIALOG_OPENFILE, owner, false, (paths) {
            chosen(paths.length ? paths[0] : null);
        });
    }

    /// Asks for any number of files to open, and hands `chosen` their paths: none if none were.
    final void showOpenMultipleDialog(Widget owner, void delegate(string[] paths) chosen)
    {
        show(SDL_FileDialogType.SDL_FILEDIALOG_OPENFILE, owner, true, chosen);
    }

    /// Asks for a folder, and hands `chosen` its path, or null if none was chosen. Filters don't
    /// apply; the initial directory does. JavaFX's DirectoryChooser.
    final void showDirectoryDialog(Widget owner, void delegate(string path) chosen)
    {
        show(SDL_FileDialogType.SDL_FILEDIALOG_OPENFOLDER, owner, false, (paths) {
            chosen(paths.length ? paths[0] : null);
        });
    }

    /// Asks where to save a file, and hands `chosen` the path, or null if the user cancelled.
    final void showSaveDialog(Widget owner, void delegate(string path) chosen)
    {
        show(SDL_FileDialogType.SDL_FILEDIALOG_SAVEFILE, owner, false, (paths) {
            chosen(paths.length ? paths[0] : null);
        });
    }

package(mayfair):
    /// Whether a dialog is up, which the App has to keep an ear out for: see run().
    static bool waiting() nothrow @nogc
    {
        return asked > 0;
    }

private:
    string _title, _initialDirectory, _initialFileName, _acceptText;
    ExtensionFilter[] _filters;

    void show(SDL_FileDialogType type, Widget owner, bool many, void delegate(string[]) chosen)
    {
        auto request = new Request;
        request.chosen = chosen;
        foreach (f; _filters)
            request.filters ~= SdlFilter(f.description.toStringz, patternOf(f.extensions).toStringz);

        const props = SDL_CreateProperties();
        scope(exit) SDL_DestroyProperties(props);
        if (_title)
            SDL_SetStringProperty(props, SDL_PROP_FILE_DIALOG_TITLE_STRING, _title.toStringz);
        if (_acceptText)
            SDL_SetStringProperty(props, SDL_PROP_FILE_DIALOG_ACCEPT_STRING, _acceptText.toStringz);
        if (auto location = locationOf(_initialDirectory,
                                       type == SDL_FileDialogType.SDL_FILEDIALOG_SAVEFILE ? _initialFileName : null))
            SDL_SetStringProperty(props, SDL_PROP_FILE_DIALOG_LOCATION_STRING, location.toStringz);
        if (request.filters.length)
        {
            SDL_SetPointerProperty(props, SDL_PROP_FILE_DIALOG_FILTERS_POINTER, request.filters.ptr);
            SDL_SetNumberProperty(props, SDL_PROP_FILE_DIALOG_NFILTERS_NUMBER, request.filters.length);
        }
        if (owner && owner.scene && owner.scene.nativeWindow)
            SDL_SetPointerProperty(props, SDL_PROP_FILE_DIALOG_WINDOW_POINTER, owner.scene.nativeWindow);
        SDL_SetBooleanProperty(props, SDL_PROP_FILE_DIALOG_MANY_BOOLEAN, many);

        // SDL holds only a raw pointer to the request, which the GC can't see: it stays in
        // `outstanding` until answered
        outstanding[cast(void*) request] = request;
        asked++;
        // Cast to @nogc: it allocates, which is fine, as SDL doesn't call it from anywhere that minds
        SDL_ShowFileDialogWithProperties(type, cast(SDL_DialogFileCallback) &answered, cast(void*) request, props);
    }
}

private:

// SDL's SDL_DialogFileFilter, which sdl-d has as two char** by mistake
struct SdlFilter
{
    const(char)* name;
    const(char)* pattern;
}

final class Request
{
    void delegate(string[]) chosen;
    SdlFilter[] filters; // kept, with their strings, for as long as SDL might read them
}

__gshared Request[void*] outstanding;
__gshared int asked; // dialogs up, for FileChooser.waiting(); only the UI thread changes it

/*
    The dialog's answer, from SDL: on Linux, from inside SDL_PumpEvents on the UI thread, but on
    some platforms from one of its own, so it goes to the UI thread by runLater() either way. The
    list is SDL's and gone once this returns, so it's copied first -- which, on a thread of SDL's,
    needs the thread known to D's runtime while it's here.
*/
extern(C) void answered(void* data, const(const(char)*)* list, int filter) nothrow
{
    try
        hand(data, list);
    catch (Exception e)
        logWarning("FileChooser: the answer was lost: %.*s", cast(int) e.msg.length, e.msg.ptr);
}

void hand(void* data, const(const(char)*)* list)
{
    import core.thread : Thread, thread_attachThis, thread_detachThis;

    const foreign = Thread.getThis() is null;
    if (foreign)
        thread_attachThis();
    scope(exit) if (foreign)
        thread_detachThis();

    string[] paths;
    string error;
    if (!list)
        error = fromStringz(SDL_GetError()).idup;
    else
        for (auto p = list; *p; p++)
            paths ~= fromStringz(*p).idup;

    Platform.runLater({
        auto request = outstanding[data];
        outstanding.remove(data);
        asked--;
        if (error.length)
            logWarning("FileChooser: no dialog to show: %.*s", cast(int) error.length, error.ptr);
        request.chosen(paths);
    });
}

// What SDL wants for a filter: its extensions separated by semicolons, or "*" for anything
string patternOf(const string[] extensions)
{
    import std.algorithm : canFind, map;
    import std.array : join;
    import std.string : chompPrefix;

    if (!extensions.length || extensions.canFind("*"))
        return "*";
    return extensions.map!(e => e.chompPrefix("*.").chompPrefix(".")).join(";");
}

/*
    The one "location" SDL takes for both where to start and what to call a file: a folder to
    open in, or for a save, a path in the folder. SDL looks at what's there before telling the
    portal: a file that exists is suggested as it is, and otherwise the path is split into the
    folder and a name -- but only if the folder exists. If it doesn't, SDL passes the whole path
    as the folder, and the name is lost, so a folder that isn't there counts as none.
*/
string locationOf(string directory, string fileName)
{
    import std.file : getcwd, isDir;
    import std.path : buildPath;

    bool exists(string folder)
    {
        try
            return folder.isDir;
        catch (Exception)
            return false;
    }

    if (directory.length && !exists(directory))
        directory = null;
    if (!fileName.length)
        return directory.length ? directory : null;
    return buildPath(directory.length ? directory : getcwd(), fileName);
}

unittest
{
    assert(patternOf(["png", "jpg"]) == "png;jpg");
    assert(patternOf(["*.png", ".svg"]) == "png;svg");
    assert(patternOf(["png", "*"]) == "*");
    assert(patternOf(null) == "*");

    import std.file : getcwd;
    import std.path : buildPath;

    assert(locationOf(null, null) is null);
    assert(locationOf("/tmp", null) == "/tmp");
    assert(locationOf("/tmp", "notes.txt") == "/tmp/notes.txt");
    // A folder that isn't there: none, and the name in the working directory
    assert(locationOf("/no/such/folder", null) is null);
    assert(locationOf("/no/such/folder", "notes.txt") == buildPath(getcwd(), "notes.txt"));
    assert(locationOf(null, "notes.txt") == buildPath(getcwd(), "notes.txt"));
}
