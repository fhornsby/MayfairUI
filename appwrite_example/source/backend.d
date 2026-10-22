module backend;

import appwrite;
import mayfair.windowing.app : App;
import mayfair.windowing.platform : Platform;

/*
    Sets an App up to use Appwrite: AppwriteD's callbacks run on its UI thread, and its views can
    ask for the Backend with @autowired. A free function, called as if it were one of App's,
    app.useAppwrite(...), as D lets any function whose first parameter is an App be: neither
    library knows about the other, so what joins them lives here, in the app.
*/
App useAppwrite(App app, string endpoint, string project)
{
    setDefaultDispatcher(new RunLater);
    return app.registerService(new Backend(endpoint, project));
}

/*
    The app's connection to Appwrite: one client, shared by every view that asks for it with
    @autowired Backend. Its methods block until the server answers, so views call them through
    AppwriteD's async(), which runs them on a worker thread.
*/
final class Backend
{
    enum database = "main";
    enum table = "todos";

    Client client;
    Account account;
    TablesDB tablesDB;
    Realtime realtime;

    this(string endpoint, string project)
    {
        client = new Client()
            .setEndpoint(endpoint)
            .setProject(project)
            .setCookieStore(FileCookieStore.forApp("MayfairTodo")); // stays signed in between runs
        account = new Account(client);
        tablesDB = new TablesDB(client);
        realtime = new Realtime(client);
    }

    /// The signed-in user: the one from the last run if their session's still good, otherwise a new anonymous one.
    models.User signIn()
    {
        try
            return account.get();
        catch (AppwriteException)
        {
            account.createAnonymousSession();
            return account.get();
        }
    }

    /// The user's to-dos, oldest first.
    models.Row[] todos()
    {
        return tablesDB.listRows(databaseId: database, tableId: table,
            queries: [Query.orderAsc("$createdAt"), Query.limit(100)]).rows;
    }

    /// Adds a to-do only `userId` can see and change.
    models.Row add(string title, string userId)
    {
        return tablesDB.createRow(databaseId: database, tableId: table, rowId: ID.unique(),
            data: serialize(Todo(title, false)),
            permissions: [
                Permission.read(Role.user(userId)),
                Permission.update(Role.user(userId)),
                Permission.delete_(Role.user(userId)),
            ]);
    }

    /// Ticks a to-do off, or back on.
    models.Row setDone(string rowId, bool done)
    {
        return tablesDB.updateRow(databaseId: database, tableId: table, rowId: rowId, data: serialize(["done": done]));
    }

    void remove(string rowId)
    {
        tablesDB.deleteRow(databaseId: database, tableId: table, rowId: rowId);
    }
}

/// A row of the todos table.
struct Todo
{
    string title;
    bool done;
}

/// Hands AppwriteD's callbacks -- async()'s results, realtime events -- to Mayfair's UI thread.
final class RunLater : Dispatcher
{
    void post(void delegate() task)
    {
        Platform.runLater(task);
    }
}
