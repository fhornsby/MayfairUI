# Appwrite example

A to-do list kept in [Appwrite](https://appwrite.io), as a Flutter app keeps one in Firebase.
Mayfair draws the window; [AppwriteD](https://github.com/fhornsby/AppWriteD), the Appwrite
client SDK for D, stores the data. The two libraries don't depend on each other, and only two
lines in `source/app.d` join them:

```d
setDefaultDispatcher(new RunLater);       // AppwriteD's callbacks run on Mayfair's UI thread
provide(new Backend(endpoint, project));  // what views ask for with @autowired
```

and the view asks for the backend with Mayfair's `@autowired`, rather than a constructor:

```d
@View("todolist.xml")
class TodoList
{
    @xml ListView!string todos;
    @autowired Backend backend;

    void initialise()
    {
        async(() => backend.signIn()).then((models.User user) { /* on the UI thread */ });
    }
}
```

## Running it

1. In the Appwrite console, make a project, and in it a database with ID `main` holding a table
   with ID `todos`, with a string column `title` (required) and a boolean column `done` (default
   false). In the table's settings turn on row security, and let **Users** create rows. Turn on
   anonymous sign-in under Auth > Settings.
2. Run it with your project's endpoint and ID:

   ```sh
   APPWRITE_ENDPOINT=https://<REGION>.cloud.appwrite.io/v1 APPWRITE_PROJECT=<PROJECT_ID> dub run
   ```

It signs in anonymously (and stays signed in between runs), lists your to-dos, and keeps the list
in step through a realtime subscription, so a second copy of the app signed in as the same user
updates as the first adds and ticks things off.

The `appwrited` dependency in `dub.json` is pinned to a commit of the AppwriteD repository; for a
local checkout, use `"appwrited": { "path": "../../AppWriteD" }` instead.
