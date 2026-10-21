/*
    A to-do list kept in Appwrite, the way a Flutter app keeps one in Firebase.

    Mayfair draws the window and AppwriteD talks to Appwrite, and neither knows the other's there.
    Two lines here join them: the app provides its Backend, which a view asks for with @autowired,
    and tells AppwriteD to hand results back on Mayfair's UI thread (RunLater, in backend.d), so a
    view can call the server without blocking and update its widgets in the callback.

        APPWRITE_ENDPOINT=https://fra.cloud.appwrite.io/v1 APPWRITE_PROJECT=<id> dub run

    See README.md for the project to make in the Appwrite console.
*/
module app;

import std.process : environment;
import appwrite : setDefaultDispatcher;
import mayfair;
import backend;
import todolist;

void main()
{
    setDefaultDispatcher(new RunLater);
    provide(new Backend(environment.get("APPWRITE_ENDPOINT", "https://cloud.appwrite.io/v1"),
                        environment.get("APPWRITE_PROJECT", "<PROJECT_ID>")));

    auto app = new App("To do");
    app.scene = new Scene(View.load(new TodoList));
    app.run();
}
