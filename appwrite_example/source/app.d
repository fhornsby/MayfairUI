/*
    A to-do list kept in Appwrite, the way a Flutter app keeps one in Firebase: sign in, or make
    an account, and each user has a list of their own.

    Mayfair draws the window and AppwriteD talks to Appwrite, and neither knows the other's there.
    app.useAppwrite() joins them (see backend.d): it registers the app's Backend, which a page asks
    for with @autowired, and has AppwriteD hand results back on Mayfair's UI thread, so a page can
    call the server without blocking and update its widgets in the callback.

    The four values below are the Appwrite project's; each can be overridden from the environment:

        APPWRITE_ENDPOINT=https://<REGION>.cloud.appwrite.io/v1 APPWRITE_PROJECT=<id> dub run

    See README.md for setting up the project in the Appwrite console.
*/
module app;

import std.process : environment;
import mayfair;
import backend;
import loginpage;

void main()
{
    auto app = new App("To do");
    app.useAppwrite(environment.get("APPWRITE_ENDPOINT", "https://fra.cloud.appwrite.io/v1"),
                    environment.get("APPWRITE_PROJECT", "6ada176900340fc9f0f4"),
                    environment.get("APPWRITE_DATABASE", "6ada194a000daac65883"),
                    environment.get("APPWRITE_TABLE", "6ada19500029a9ed6eec"));
    app.scene = new Scene(new LoginPage);
    app.run();
}
