module mayfair.windowing.platform;

import core.sync.mutex : Mutex;

/*
    The UI thread's doorway for other threads. JavaFX's Platform.

    Widgets belong to the thread running the App, and must only be touched from it. A worker
    thread that has finished something -- loaded a file, heard back from a server -- hands the UI
    thread the code to show it with, through runLater(), and the App runs it with the rest of the
    frame's input, in the order it was given.

        new Thread({
            auto result = slowWork();
            Platform.runLater({ status.setText(result); });
        }).start();
*/
struct Platform
{
    @disable this(); // namespace only

    /// Runs `task` on the UI thread, soon. Safe to call from any thread, and before the App runs,
    /// in which case it waits for the App to start.
    static void runLater(void delegate() task)
    {
        lock.lock();
        pending ~= task;
        const signal = wake;
        lock.unlock();
        if (signal)
            signal();
    }

package(mayfair):
    /// How to wake the UI thread when a task arrives. Set by the App while it runs.
    static void wakeWith(void function() nothrow @nogc signal) nothrow @nogc
    {
        lock.lock_nothrow();
        wake = signal;
        const hasTasks = pending.length > 0 || signalled !is null;
        lock.unlock_nothrow();
        if (signal && hasTasks)
            signal(); // tasks given before the App started
    }

    /// The tasks given so far, which are now the caller's to run.
    static void delegate()[] take() nothrow
    {
        lock.lock_nothrow();
        auto tasks = pending;
        pending = null;
        auto notifiers = signalled;
        signalled = null;
        // Signalled ones are free to be signalled again from here on: whatever arrives now, the
        // task about to run may already see, but if not it'll run again
        for (auto n = notifiers; n; n = n.next)
            n.queued = false;
        lock.unlock_nothrow();
        // The list is newest first; tasks run oldest first
        size_t first = tasks.length;
        for (auto n = notifiers; n; n = n.next)
            tasks ~= n.task;
        foreach (i; 0 .. (tasks.length - first) / 2)
        {
            auto t = tasks[first + i];
            tasks[first + i] = tasks[$ - 1 - i];
            tasks[$ - 1 - i] = t;
        }
        return tasks;
    }
}

/*
    A task for the UI thread that a thread the D runtime doesn't know can ask for: one a C or Rust
    library started, reading a socket or a pseudoterminal. Such a thread can't call runLater(), as
    that allocates, and the garbage collector neither sees nor stops a thread it doesn't know.

    The Notifier is made on the UI thread, with its task, before the other thread needs it. Then
    signal() is safe from anywhere, allocates nothing, and has the task run on the UI thread soon,
    once, however many times it was called before it ran -- so a library telling it about every
    packet costs one run a frame, not one a packet.

        auto news = new Notifier({ readWhatArrived(); });
        // ...given to the library, whose thread calls:
        news.signal();

    The other thread holds it by a pointer the collector can't see, so whatever hands it over has
    to keep a reference to it, for as long as that thread may signal.
*/
final class Notifier
{
public:
    this(void delegate() task) nothrow
    {
        this.task = task;
    }

    /// Has the task run on the UI thread, soon. Safe from any thread, the D runtime's or not.
    void signal() nothrow @nogc
    {
        lock.lock_nothrow();
        const first = !queued;
        if (first)
        {
            queued = true;
            next = signalled;
            signalled = this;
        }
        const w = wake;
        lock.unlock_nothrow();
        if (first && w)
            w();
    }

private:
    void delegate() task;
    Notifier next;   // in `signalled`, while queued
    bool queued;
}

private __gshared Mutex lock;
private __gshared void delegate()[] pending;
private __gshared Notifier signalled; // newest first, through Notifier.next
private __gshared void function() nothrow @nogc wake;

shared static this()
{
    lock = new Mutex;
}

unittest
{
    // Signalled from a thread of the D runtime's own here, but signal() itself neither allocates nor
    // asks the runtime anything, which is the point
    int runs;
    auto n = new Notifier({ runs++; });
    auto m = new Notifier({ runs += 10; });
    n.signal();
    m.signal();
    n.signal(); // already waiting: no second run
    foreach (task; Platform.take())
        task();
    assert(runs == 11);
    foreach (task; Platform.take())
        task();
    assert(runs == 11, "nothing more till it's signalled again");
    n.signal();
    foreach (task; Platform.take())
        task();
    assert(runs == 12);
}
