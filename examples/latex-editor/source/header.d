module header;

import std.path : baseName;
import mayfair;
import workspace;

/*
    The title bar, laid out in header.xml: a TitleBar of the app's own, whose buttons and menu
    hand what they do to the workspace. Its middle says the project's name, and its background
    runs on behind the files, as the sidebar's frosted glass, in the Oriel theme. Its menu ends
    with the projects opened lately, as showRecent() is given them.
*/
@View("header.xml")
final class Header : TitleBar
{
public:
    this(Workspace workspace)
    {
        this.workspace = workspace;
        View.load(this);
    }

    /// Lists `projects` at the end of the menu, under Recent, each opening its project.
    void showRecent(string[] projects)
    {
        foreach (item; recentItems)
            if (item.parent)
                item.parent.remove(item);
        recentItems = null;
        if (!projects.length)
            return;
        recentItems ~= new MenuSeparator();
        auto heading = new MenuItem(tr!"recent");
        heading.setDisable(true);
        recentItems ~= heading;
        foreach (path; projects)
            recentItems ~= recentItem(path);
        foreach (item; recentItems)
            menu.add(item);
    }

private:
    Workspace workspace;
    @xml ContextMenu menu;
    Widget[] recentItems;

    // Each its own closure: one made in the loop above would share the loop's variable
    MenuItem recentItem(string path)
    {
        auto item = new MenuItem(baseName(path), { workspace.openProject(path); });
        item.setTooltip(path);
        return item;
    }

    void openFolder() { workspace.chooseProject(); }
    void toggleFiles() { workspace.toggleFiles(); }
    void togglePdf() { workspace.togglePdf(); }
    void goToPdf() { workspace.goToPdf(); }
    void newFile() { workspace.files.newFile(); }
    void save() { workspace.save(); }
    void saveAll() { workspace.saveAll(); }
    void closeTab() { workspace.closeCurrent(); }
    void compile() { workspace.compile(); }
}
