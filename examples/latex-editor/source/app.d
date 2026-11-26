/*
    OverBrief: a LaTeX editor in the manner of Overleaf, on the desktop. A project's files down
    the left, the file being edited in the middle, and the PDF it makes on the right, compiled
    with the TeX that's installed, and SyncTeX going between the two.

        dub run                       the sample project, in sample/
        dub run -- ~/thesis           a project's folder
        dub run -- ~/thesis/main.tex  a file, and the project it's in

    The window's laid out in XML, a view for each part, and each part's code in a module of its own:

        resources/views/main.xml      the three panes, side by side     workspace.d
        resources/views/files.xml     the project's files               files.d
        resources/views/preview.xml   the PDF, and the compile's logs   preview.d
        resources/views/header.xml    the title bar                     header.d
        resources/strings.xml         the app's text
        resources/latex.css           its look, over the Oriel theme

    and with no view of their own: project.d (the folder, and which file's the main one),
    documents.d (a file open in the editor), compiler.d (latexmk, and its log) and synctex.d.
*/
import std.file : thisExePath;
import std.path : buildPath, dirName;
import mayfair;
import mayfair.pdf;
import header;
import workspace;

void main(string[] args)
{
    auto app = new App(tr!"app_name");
    app.setSize(1440, 860);

    auto work = new Workspace;
    auto content = View.load(work);
    work.header = new Header(work);
    work.header.setSidebar(work.files); // its background runs on behind the files, as glass

    auto scene = new Scene(content).titleBar(work.header);
    scene.stylesheets.add(orielStylesheet);
    scene.stylesheets.add(stylesheet!(import("latex.css")));
    app.scene = scene;
    app.setTranslucent(true);
    app.window.onCloseRequest(() => work.quitting());

    work.openProject(args.length > 1 ? args[1] : buildPath(dirName(thisExePath), "sample"));
    app.run();
}
