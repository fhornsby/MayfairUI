/*
    A to-do list kept in Appwrite, the way a Flutter app keeps one in Firebase: sign in, or make
    an account, and each user has a list of their own.

    Mayfair draws the window and AppwriteD talks to Appwrite, and neither knows the other's there.
    app.useAppwrite() joins them (see backend.d): it registers the app's Backend, which a page asks
    for with @autowired, and has AppwriteD hand results back on Mayfair's UI thread, so a page can
    call the server without blocking and update its widgets in the callback.

    It needs an Appwrite project of your own: its endpoint and ID, and the IDs of the database and
    table the to-dos go in. Copy .env.example to .env and fill them in; .env is ignored by git, so
    they stay on your machine. Each can also be set in the environment, which wins over the file:

        APPWRITE_PROJECT=<PROJECT_ID> dub run

    See README.md for setting up the project in the Appwrite console.
*/
module app;

import core.stdc.stdlib : exit;
import std.stdio : stderr;
import mayfair;
import backend;
import dotenv;
import loginpage;

void main()
{
    // The project's values, from .env or the environment: nothing to fall back on, as they're yours
    const endpoint = setting("APPWRITE_ENDPOINT"), project = setting("APPWRITE_PROJECT"),
          database = setting("APPWRITE_DATABASE"), table = setting("APPWRITE_TABLE");
    if (!endpoint.length || !project.length || !database.length || !table.length)
    {
        stderr.writeln("This example needs an Appwrite project of your own. Copy .env.example to .env and fill in\n"
                       ~ "its four values (README.md says where to find them), then run it again.");
        exit(1);
    }

    auto app = new App("To do");
    app.useAppwrite(endpoint, project, database, table);
    app.scene = new Scene(new LoginPage);
    app.run();
}
