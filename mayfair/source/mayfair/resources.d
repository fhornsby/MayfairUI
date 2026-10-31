module mayfair.resources;

/*
    What an app compiles in besides its code, in one folder, as Android's res and a JavaFX
    project's resources are:

        resources/
            views/main.xml          the views, and their CSS
            views/main.css
            strings.xml             the app's text, in each language it's in (see mayfair.strings)
            images/logo.svg         anything else, wherever suits

    with it among dub's stringImportPaths:

        "stringImportPaths": ["resources"]

    A file's looked for in views/ first, then from the top: @View("main.xml") is
    resources/views/main.xml, and an image="images/logo.svg" in a view is resources/images/logo.svg.
    An app whose views are in a folder of their own, among the stringImportPaths as "views", works
    as it always has.
*/

/// The text of `file`, compiled in: from views/ if it's there, else from the top of the resources.
template resource(string file)
{
    static if (__traits(compiles, import("views/" ~ file)))
        enum string resource = import("views/" ~ file);
    else static if (__traits(compiles, import(file)))
        enum string resource = import(file);
    else
        static assert(false, "there's no " ~ file ~ " in resources/views or resources, or a folder among dub's "
                      ~ "stringImportPaths");
}
