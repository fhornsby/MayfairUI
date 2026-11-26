module header;

import mayfair;
import workspace;

/*
    The title bar, laid out in header.xml: a TitleBar of the app's own, whose buttons and menu
    hand what they do to the workspace. Its middle says the project's name, and its background
    runs on behind the files, as the sidebar's frosted glass, in the Oriel theme.
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

private:
    Workspace workspace;

    void toggleFiles() { workspace.toggleFiles(); }
    void togglePdf() { workspace.togglePdf(); }
    void goToPdf() { workspace.goToPdf(); }
    void openProject() { workspace.chooseProject(); }
    void newFile() { workspace.files.newFile(); }
    void save() { workspace.save(); }
    void saveAll() { workspace.saveAll(); }
    void closeTab() { workspace.closeCurrent(); }
    void compile() { workspace.compile(); }
}
