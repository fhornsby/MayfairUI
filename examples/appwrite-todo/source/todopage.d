module todopage;

import appwrite;
import mayfair;
import backend;
import loginpage;

/*
    The list, laid out in resources/views/todos.xml, for the user signed in on the LoginPage. Sign out goes
    back to a new one.

    Every call to the server goes through async(), so the window keeps drawing while it waits, and
    the then() and onError() callbacks run on the UI thread (main() set that up), where they can
    change widgets directly. The list's fetched again once each change is made, and a realtime
    subscription keeps it in step with changes made anywhere else: another window, another device.
*/
@View("todos.xml")
class TodoPage : Column
{
public:
    this(models.User user)
    {
        this.user = user;
        View.load(this);
    }

    void initialise()
    {
        status.setText("Signed in as " ~ (user.name.length ? user.name : user.email));
        todos.cellFactory(() => cast(ListCell!Todo) new TodoCell(&setDone));
        subscription = backend.realtime.subscribe(backend.channel, (RealtimeMessage message) { refresh(); });
        refresh();
    }

private:
    @xml Label status;
    @xml TextField newTodo;
    @xml ListView!Todo todos;
    @autowired Backend backend;
    models.User user;
    RealtimeSubscription subscription;

    void addTodo()
    {
        auto title = newTodo.text;
        if (!title.length)
            return;
        newTodo.setText("");
        async(() => backend.add(title, user.id)).then({ refresh(); }).onError(&failed);
    }

    void setDone(Todo todo, bool done)
    {
        async(() => backend.setDone(todo.id, done)).then({ refresh(); }).onError(&failed);
    }

    void remove()
    {
        if (todos.selectedIndex < 0)
            return;
        auto id = todos.selectedItem.id;
        async(() => backend.remove(id)).then({ refresh(); }).onError(&failed);
    }

    void signOut()
    {
        subscription.unsubscribe(); // the last one, so the realtime connection closes too
        async(() => backend.signOut()).then({ scene.setRoot(new LoginPage); });
    }

    void refresh()
    {
        async(() => backend.todos())
            .then((Todo[] latest) { todos.setItems(latest); })
            .onError((Exception e) { status.setText(e.msg); });
    }

    void failed(Exception e)
    {
        status.setText(e.msg);
        refresh(); // a box ticked when the change didn't go through goes back as it was
    }
}

/// One of the list's rows: a box to tick, then what's to do.
final class TodoCell : ListCell!Todo
{
public:
    /// `onTick` is told which to-do's box was ticked, and whether it's ticked now.
    this(void delegate(Todo, bool) onTick)
    {
        done = new CheckBox().accessibleText("Done");
        done.onAction({ onTick(item, done.selected); });
        add(done);
    }

    override void updateItem(Todo todo)
    {
        done.setSelected(todo.done);
        label.setText(todo.title);
    }

private:
    CheckBox done;
}
