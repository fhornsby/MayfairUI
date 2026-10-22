module backend;

import std.algorithm : map;
import std.array : array;
import std.typecons : Nullable, nullable;
import appwrite;
import mayfair.windowing.app : App;
import mayfair.windowing.platform : Platform;

/*
    Sets an App up to use Appwrite: AppwriteD's callbacks run on its UI thread, and its views can
    ask for the Backend with @autowired. A free function, called as if it were one of App's,
    app.useAppwrite(...), as D lets any function whose first parameter is an App be: neither
    library knows about the other, so what joins them lives here, in the app.
*/
App useAppwrite(App app, string endpoint, string project, string database, string table)
{
    setDefaultDispatcher(new RunLater);
    return app.registerService(new Backend(endpoint, project, database, table));
}

/*
    The app's connection to Appwrite: one client, shared by every page that asks for it with
    @autowired Backend. Its methods block until the server answers, so pages call them through
    AppwriteD's async(), which runs them on a worker thread.
*/
final class Backend
{
    immutable string database, table; /// Where the to-dos are: the IDs the console shows

    Client client;
    Account account;
    TablesDB tablesDB;
    Realtime realtime;

    this(string endpoint, string project, string database, string table)
    {
        this.database = database;
        this.table = table;
        client = new Client()
            .setEndpoint(endpoint)
            .setProject(project)
            .setCookieStore(FileCookieStore.forApp("MayfairTodo")); // stays signed in between runs
        account = new Account(client);
        tablesDB = new TablesDB(client);
        realtime = new Realtime(client);
    }

    /// The user still signed in from the last run, if their session's good; null if nobody is.
    Nullable!(models.User) currentUser()
    {
        models.User user;
        try
            user = account.get();
        catch (AppwriteException e)
        {
            if (e.code == 401)
                return typeof(return).init; // never signed in, signed out, or the session ran out
            throw e;
        }
        // A session with no email address is an anonymous one, from before the app had a login
        // page: that doesn't count as signed in here
        if (!user.email.length)
        {
            signOut();
            return typeof(return).init;
        }
        return nullable(user);
    }

    /// Signs in with an email address and password, as an account made with signUp.
    models.User signIn(string email, string password)
    {
        account.createEmailPasswordSession(email: email, password: password);
        return account.get();
    }

    /// Makes an account, then signs in to it. The password needs 8 characters or more.
    models.User signUp(string email, string password)
    {
        account.create(userId: ID.unique(), email: email, password: password);
        return signIn(email, password);
    }

    /// Ends the session, on the server and here. Never throws: offline, it's still forgotten here.
    void signOut()
    {
        try
            account.deleteSession(sessionId: "current");
        catch (Exception)
        {
        }
        client.cookies.clear();
    }

    /// The realtime channel for the to-dos' rows.
    string channel()
    {
        return Channel.tablesdb(database).table(table).row();
    }

    /// The signed-in user's to-dos, oldest first.
    Todo[] todos()
    {
        return tablesDB.listRows(databaseId: database, tableId: table,
            queries: [Query.orderAsc("$createdAt"), Query.limit(100)]).rows
            .map!(row => Todo(row.id, row["title"].str, row["done"].boolean)).array;
    }

    /// Adds a to-do only `userId` can see and change.
    void add(string title, string userId)
    {
        tablesDB.createRow(databaseId: database, tableId: table, rowId: ID.unique(),
            data: serialize(["title": JSONValue(title), "done": JSONValue(false)]),
            permissions: [
                Permission.read(Role.user(userId)),
                Permission.update(Role.user(userId)),
                Permission.delete_(Role.user(userId)),
            ]);
    }

    /// Ticks a to-do off, or back on.
    void setDone(string id, bool done)
    {
        tablesDB.updateRow(databaseId: database, tableId: table, rowId: id, data: serialize(["done": done]));
    }

    void remove(string id)
    {
        tablesDB.deleteRow(databaseId: database, tableId: table, rowId: id);
    }
}

/// A row of the to-do table: its `title` and `done` columns, and the row's ID.
struct Todo
{
    string id;
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
