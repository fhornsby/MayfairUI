/*
    A to-do list kept in Appwrite, the way a Flutter app keeps one in Firebase.

    Mayfair draws the window and AppwriteD talks to Appwrite, and neither knows the other's there.
    app.useAppwrite() joins them (see backend.d): it registers the app's Backend, which a view asks
    for with @autowired, and has AppwriteD hand results back on Mayfair's UI thread, so a view can
    call the server without blocking and update its widgets in the callback.

        APPWRITE_ENDPOINT=https://fra.cloud.appwrite.io/v1 APPWRITE_PROJECT=<id> dub run

    See README.md for the project to make in the Appwrite console.
*/
module app;

import std.process : environment;
import mayfair;
import backend;
import todolist;

void main()
{
    auto app = new App("To do");
    app.useAppwrite(environment.get("APPWRITE_ENDPOINT", "https://cloud.appwrite.io/v1"),
                    environment.get("APPWRITE_PROJECT", "<PROJECT_ID>"));
    app.scene = new Scene(View.load(new TodoList));
    app.run();
}
