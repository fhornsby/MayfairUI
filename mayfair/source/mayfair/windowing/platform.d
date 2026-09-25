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
        const hasTasks = pending.length > 0;
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
        lock.unlock_nothrow();
        return tasks;
    }
}

private __gshared Mutex lock;
private __gshared void delegate()[] pending;
private __gshared void function() nothrow @nogc wake;

shared static this()
{
    lock = new Mutex;
}
