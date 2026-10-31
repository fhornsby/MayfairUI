# Appwrite example

A to-do list kept in [Appwrite](https://appwrite.io), as a Flutter app keeps one in Firebase.
Mayfair draws the window; [AppwriteD](https://github.com/fhornsby/AppWriteD), the Appwrite
client SDK for D, stores the data. The two libraries don't depend on each other; one call in
`source/app.d` joins them:

```d
auto app = new App("To do");
app.useAppwrite(endpoint, project, database, table);
app.scene = new Scene(new LoginPage);
```

`useAppwrite` isn't one of `App`'s methods but the app's own function, in `source/backend.d`,
which D lets you call as if it were (any function whose first parameter is an `App` can be):

```d
App useAppwrite(App app, string endpoint, string project, string database, string table)
{
    setDefaultDispatcher(new RunLater);  // AppwriteD's callbacks run on Mayfair's UI thread
    return app.registerService(new Backend(endpoint, project, database, table)); // what pages ask for with @autowired
}
```

and a page asks for the backend with Mayfair's `@autowired`, rather than a constructor:

```d
@View("login.xml")
class LoginPage : Column
{
    @xml TextField email;
    @xml PasswordField password;
    @autowired Backend backend;

    void signIn()
    {
        async(() => backend.signIn(email.text, password.text))
            .then((models.User user) { scene.setRoot(new TodoPage(user)); })   // on the UI thread
            .onError((Exception e) { status.setText(e.msg); });
    }
}
```

## The app

It opens on a login page (`LoginPage`, `resources/views/login.xml`): an email address and password to sign
in with, or **Create account** to make one. Once signed in, the window shows the list
(`TodoPage`, `resources/views/todos.xml`) in its place with `scene.setRoot`. Each to-do has a box to tick it
off, and **Sign out** goes back to the login page. Someone still signed in from the last run goes
straight to their list: the session's kept in a file between runs.

Each user sees only their own to-dos, and the list keeps in step through a realtime subscription,
so a second copy of the app signed in as the same user updates as the first adds and ticks things
off.

## Setting up Appwrite

In the [Appwrite console](https://cloud.appwrite.io), for your project:

1. **Auth > Settings**: check **Email/Password** is on (it is in a new project). Nothing else is
   needed for sign-in; anonymous sign-in, which the first version of this example used, can be
   turned off.
2. **Auth > Security** (optional): **Password dictionary** refuses common passwords, and
   **Password history** stops a user reusing one. Appwrite always needs 8 characters or more.
3. **Databases**: make a database, and in it a table with two columns: `title`, a string of up to
   255 characters, required; and `done`, a boolean, not required, defaulting to false. The keys
   are case-sensitive.
4. In the table's **Security** tab: under Permissions, add **All users** with **Create** ticked, and
   nothing else; then turn on **Row level security**. The app gives each row it makes Read, Update
   and Delete for the user who made it, and row security is what makes those count. Click each
   section's own **Update**.
5. **Auth > Users** lists everyone who's made an account, where you can block or delete one.

Then put the project's values in `source/app.d` -- the endpoint (with your region, as the
console's project settings show it), the project ID, and the database's and table's IDs -- or set
them in the environment:

```sh
APPWRITE_ENDPOINT=https://<REGION>.cloud.appwrite.io/v1 APPWRITE_PROJECT=<PROJECT_ID> \
APPWRITE_DATABASE=<DATABASE_ID> APPWRITE_TABLE=<TABLE_ID> dub run
```

The `appwrited` dependency in `dub.json` is pinned to a commit of the AppwriteD repository, fetched
over SSH while that repository's private; for a local checkout, use
`"appwrited": { "path": "../../AppWriteD" }` instead.
