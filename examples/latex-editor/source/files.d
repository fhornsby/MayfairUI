module files;

import std.file : exists, mkdirRecurse, write;
import std.path : buildPath, dirName, extension;
import std.string : strip;
import mayfair;
import project;

/*
    The project's files, down the left: a FilesPane, laid out in files.xml. Choosing a file asks
    the workspace to open it (onOpen); the buttons along its top make a file or a folder, in the
    folder chosen in the tree or the project's own, and refresh the tree.
*/
@View("files.xml")
final class FilesPane : Column
{
public:
    /// Hears a file chosen in the tree, to open.
    void delegate(string path) onOpen;

    this()
    {
        View.load(this);
        tree.onSelectionChanged({
            if (auto item = tree.selectedItem)
                if (!item.value.folder && onOpen)
                    onOpen(item.value.path);
        });
    }

    /// Shows `p`'s files.
    void show(Project p)
    {
        project = p;
        refresh();
    }

    /// Asks for a name, and makes a file -- or a folder -- of it in the folder chosen in the tree.
    void newFile() { ask("new_file", false); }
    void newFolder() { ask("new_folder", true); } /// ditto

    /// Reads the folder again, for files made or deleted elsewhere.
    void refresh()
    {
        if (project)
            tree.root = project.root;
    }

private:
    @xml TreeView!Entry tree;
    Project project;

    // Asks for a name, and makes it in the folder chosen in the tree -- or the one the chosen
    // file's in, or the project's -- then shows it, and opens a file
    void ask(string title, bool folder)
    {
        if (!project)
            return;
        string where = project.folder;
        if (auto item = tree.selectedItem)
            where = item.value.folder ? item.value.path : dirName(item.value.path);
        auto field = new TextField("").prefWidth(260).promptText(folder ? "figures" : "chapter.tex");
        new Dialog(title == "new_file" ? tr!"new_file" : tr!"new_folder")
            .extra(field)
            .addButton(tr!"cancel", null, ButtonKind.cancel)
            .addButton(tr!"create", {
                auto name = field.text.strip;
                if (!name.length)
                    return;
                if (!folder && !extension(name).length)
                    name ~= ".tex";
                const path = buildPath(where, name);
                try
                {
                    if (folder)
                        mkdirRecurse(path);
                    else if (!exists(path))
                        write(path, "");
                }
                catch (Exception) { return; }
                refresh();
                if (!folder && onOpen)
                    onOpen(path);
            }, ButtonKind.default_)
            .show(this);
        Platform.runLater({ field.requestFocus(); });
    }
}
