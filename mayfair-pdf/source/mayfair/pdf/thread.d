module mayfair.pdf.thread;

/*
    The PDF thread: one, for the process, on which the engine does everything -- opening documents,
    rendering, reading text -- so that an engine that isn't thread-safe needs no locks, and nothing
    it does waits on the UI thread, or keeps it waiting.

    Work is queued as jobs, each with a priority: what's on screen first, then what's about to be,
    then what's wanted in the background, like a search's text. Within a priority, first come first
    served. A job can be cancelled until it starts -- the page it was for scrolled away -- and is
    then skipped; one that's started runs to its end, and what it made is dropped if it was
    cancelled meanwhile. A job gets its results to the UI thread itself, with Platform.runLater.
*/

import core.atomic : atomicLoad, atomicStore;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import mayfair.pdf.engine;

/// How soon a job's wanted: the lower the sooner.
enum PdfPriority : int
{
    control = 0,    /// Opening and closing documents: before anything they'd affect
    visible = 1,    /// What's on screen now
    near = 2,       /// What's about to be: the next screenful, thumbnails in view
    background = 3, /// What's wanted sometime: text for a search, thumbnails out of view
}

/// Something for the PDF thread to do.
final class PdfJob
{
    this(PdfPriority priority, void delegate() work) nothrow
    {
        this.priority = priority;
        this.work = work;
    }

    /// Skips it, if it hasn't started; or marks what it makes as unwanted, if it has.
    void cancel() nothrow @nogc { atomicStore(_cancelled, true); }

    /// ditto
    bool cancelled() const nothrow @nogc { return atomicLoad(_cancelled); }

    /// Whether it's done -- run, or skipped -- as far as the PDF thread's concerned.
    bool finished() const nothrow @nogc { return atomicLoad(_finished); }

private:
    PdfPriority priority;
    void delegate() work;
    ulong order;
    shared bool _cancelled, _finished;
}

/*
    The thread, and the engine it runs. Everything here may be called from any thread; the engine
    is started on the PDF thread, by the first job that needs it.
*/
struct PdfThread
{
    @disable this(); // namespace only

    /// The engine documents are opened with. Set once, before the first document; after, it can't change.
    static bool setEngine(PdfEngine engine)
    {
        synchronized (lock)
        {
            if (started && engine !is chosen)
                return false;
            chosen = engine;
            return true;
        }
    }

    /// ditto
    static PdfEngine engine()
    {
        synchronized (lock)
            return chosen;
    }

    /// Queues `job`, starting the thread if it isn't running.
    static void submit(PdfJob job)
    {
        synchronized (lock)
        {
            job.order = next++;
            queue ~= job;
            if (!thread)
            {
                thread = new Thread(&run);
                thread.isDaemon = true; // stopped by the module's destructor
                thread.start();
            }
            ready.notify();
        }
    }

    /*
        The engine, started, for a job on the PDF thread: null if there's none, or it couldn't start,
        with `failure` saying why. It's started once, by the first job to ask.
    */
    static PdfEngine startedEngine(out string failure)
    {
        PdfEngine engine;
        synchronized (lock)
        {
            if (!started)
            {
                started = true;
                if (!chosen)
                    startFailure = "no PDF engine: give PdfDocument.setEngine one, such as mayfair-pdfium's PdfiumEngine";
                else
                    engineToStart = chosen;
            }
            engine = chosen;
        }
        if (engineToStart)
        {
            // Started outside the lock: it may take a while, loading its library
            string why;
            const ok = engineToStart.start(why);
            synchronized (lock)
            {
                if (!ok)
                    startFailure = why.length ? why : engineToStart.name ~ " couldn't start";
                engineToStart = null;
            }
        }
        synchronized (lock)
        {
            failure = startFailure;
            return startFailure.length ? null : engine;
        }
    }

    /// How many jobs are waiting: for tests.
    static size_t waiting()
    {
        synchronized (lock)
            return queue.length;
    }

private:
    __gshared Mutex lock;
    __gshared Condition ready;
    __gshared PdfJob[] queue;
    __gshared ulong next;
    __gshared Thread thread;
    __gshared PdfEngine chosen, engineToStart;
    __gshared bool started, stopping;
    __gshared string startFailure;

    static void run()
    {
        while (true)
        {
            PdfJob job;
            synchronized (lock)
            {
                while (!queue.length && !stopping)
                    ready.wait();
                if (stopping)
                    return;
                // The soonest wanted: lowest priority, then first queued
                size_t best;
                foreach (i, j; queue)
                    if (j.priority < queue[best].priority
                        || (j.priority == queue[best].priority && j.order < queue[best].order))
                        best = i;
                job = queue[best];
                queue = queue[0 .. best] ~ queue[best + 1 .. $];
            }
            if (!job.cancelled)
            {
                try
                    job.work();
                catch (Throwable t)
                {
                    import std.stdio : stderr;
                    try stderr.writeln("[Mayfair] a PDF job failed: ", t.msg); catch (Exception) {}
                }
            }
            atomicStore(job._finished, true);
        }
    }
}

shared static this()
{
    PdfThread.lock = new Mutex;
    PdfThread.ready = new Condition(PdfThread.lock);
}

/*
    The app's leaving: the thread's told to stop once the job it's on, if any, is done, and waited
    for a few seconds at most, before the runtime it runs on goes.
*/
shared static ~this()
{
    Thread running;
    synchronized (PdfThread.lock)
    {
        PdfThread.stopping = true;
        PdfThread.ready.notifyAll();
        running = PdfThread.thread;
    }
    const deadline = MonoTime.currTime + 3.seconds;
    while (running && running.isRunning && MonoTime.currTime < deadline)
        Thread.sleep(5.msecs);
}
