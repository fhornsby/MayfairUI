module todolist;

import std.algorithm : map;
import std.array : array;
import appwrite;
import mayfair;
import backend;

/*
    The list: views/todolist.xml says what it looks like. It has no constructor to be handed the
    Backend through; it's @autowired, there before initialise() runs.

    Every call to the server goes through async(), so the window keeps drawing while it waits, and
    the then() and onError() callbacks run on the UI thread (main() set that up), where they can
    change widgets directly. A realtime subscription keeps the list in step with the server, so
    after adding, ticking or deleting a to-do it's the event that comes back that redraws it.
*/
@View("todolist.xml")
class TodoList
{
    @xml Label status;
    @xml TextField newTodo;
    @xml ListView!string todos;
    @autowired Backend backend;

    void initialise()
    {
        status.setText("Signing in…");
        async(() => backend.signIn())
            .then((models.User user) {
                userId = user.id;
                status.setText("Signed in" ~ (user.name.length ? " as " ~ user.name : ""));
                backend.realtime.subscribe(Channel.tablesdb(Backend.database).table(Backend.table).row(),
                                           (RealtimeMessage message) { refresh(); });
                refresh();
            })
            .onError(&failed);
    }

private:
    models.Row[] rows;   // what the list shows, in the same order
    string userId;

    void add()
    {
        auto title = newTodo.text;
        if (!title.length || !userId.length)
            return;
        newTodo.setText("");
        async(() => backend.add(title, userId)).onError(&failed);
    }

    void toggle(int index)
    {
        auto row = rows[index];
        async(() => backend.setDone(row.id, !row["done"].boolean)).onError(&failed);
    }

    void remove()
    {
        if (todos.selectedIndex < 0)
            return;
        auto id = rows[todos.selectedIndex].id;
        async(() => backend.remove(id)).onError(&failed);
    }

    void refresh()
    {
        async(() => backend.todos())
            .then((models.Row[] latest) {
                rows = latest;
                todos.setItems(latest.map!(r => (r["done"].boolean ? "✓ " : "    ") ~ r["title"].str).array);
            })
            .onError(&failed);
    }

    void failed(Exception e)
    {
        status.setText(e.msg);
    }
}
