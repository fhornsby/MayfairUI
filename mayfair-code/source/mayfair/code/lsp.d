module mayfair.code.lsp;

/*
    A language server client: the Language Server Protocol, over a server's standard input and
    output, as editors speak it to clangd, rust-analyzer, pyright, gopls and the rest.

        auto server = LanguageServer.forLanguage(languageFor(path), dirName(path));  // null if none's installed
        auto doc = new LspDocument(server, buffer, path);   // opened, and kept in step as it's edited
        new LspEditor(doc, view);                            // errors, completion, hovers, definitions in the view

    A server's a program of its own, started when it's asked for and stopped with stop(); this
    package only talks to it. Messages are read on a thread of the server's, and handled on the
    UI thread; requests are answered, through their delegates, on the UI thread too.

    Places are as the protocol has them -- lines, and columns in UTF-16 code units -- and become
    TextPositions here, with the buffer's own columns, by way of TextBuffer.utf16Column.
*/

import core.thread : Thread;
import std.algorithm : canFind, startsWith;
import std.conv : to;
import std.json;
import std.path : absolutePath, buildPath;
import std.process : Config, environment, pipeProcess, ProcessPipes, Redirect, kill, wait;
import std.stdio : File, stderr;
import std.string : indexOf, strip, toLower;
import mayfair;
import mayfair.code.language;

/// How bad a diagnostic is.
enum Severity { error = 1, warning = 2, information = 3, hint = 4 }

/// What a server says is wrong with the text: where, how bad, and what.
struct Diagnostic
{
    TextPosition start, end;
    Severity severity = Severity.error;
    string message;
    string source;     /// What found it: "pyright", "rustc"
}

/// A completion a server offers: what it's called, what it puts in, and what it is.
struct Completion
{
    string label;
    string insertText;  /// What's put in: the label, unless it says otherwise
    string detail;      /// A signature, a type
    int kind;           /// The protocol's CompletionItemKind: 2 a method, 3 a function, 6 a variable...
    TextPosition replaceFrom, replaceTo; /// What it replaces, if the server says; otherwise the word at the caret
    bool hasRange;
    string sortText;
}

/// A place in a file.
struct Location
{
    string path;
    TextPosition position;
}

/// A server, running.
final class LanguageServer
{
public:
    /*
        Starts `command` -- "clangd", or ["pyright-langserver", "--stdio"] -- for the project at
        `root`. It's started at once; status says when it's ready, or why it failed.
    */
    this(string[] command, string root)
    {
        this.command = command;
        this.root = absolutePath(root);
        start();
    }

    /// A server for `language`, if one that serves it is installed: null if not.
    static LanguageServer forLanguage(Language language, string root)
    {
        if (!language)
            return null;
        foreach (c; commandsFor(language.name))
            if (onPath(c[0]))
                return new LanguageServer(c, root);
        return null;
    }

    /// The servers this tries for a language, in order: the first installed is used.
    static string[][] commandsFor(string language)
    {
        switch (language)
        {
            case "Python": return [["pyright-langserver", "--stdio"], ["basedpyright-langserver", "--stdio"], ["pylsp"],
                                   ["jedi-language-server"]];
            case "C", "C++": return [["clangd"]];
            case "Rust": return [["rust-analyzer"]];
            case "Go": return [["gopls"]];
            case "D": return [["serve-d"]];
            case "JavaScript", "TypeScript": return [["typescript-language-server", "--stdio"]];
            case "Lua": return [["lua-language-server"]];
            case "Shell": return [["bash-language-server", "start"]];
            case "C#": return [["csharp-ls"], ["OmniSharp", "-lsp"]];
            case "Java": return [["jdtls"]];
            case "Zig": return [["zls"]];
            case "Ruby": return [["solargraph", "stdio"], ["ruby-lsp"]];
            case "HTML": return [["vscode-html-language-server", "--stdio"]];
            case "CSS": return [["vscode-css-language-server", "--stdio"]];
            case "JSON": return [["vscode-json-language-server", "--stdio"]];
            case "YAML": return [["yaml-language-server", "--stdio"]];
            default: return null;
        }
    }

    /// Whether it's starting, ready to be asked, or stopped -- failed, or told to.
    enum Status { starting, ready, stopped }

    mixin(declareReadOnlyProperty!(Status, "status", "Status.starting"));

    /// Why it stopped, if it failed.
    string failure() const { return _failure; }

    /// What the server's called, as it says: "pyright", "rust-analyzer".
    string serverName() const { return _serverName; }

    /// The characters after which it offers completions: ".", "::".
    string[] completionTriggers() const { return triggers.dup; }

    /// Asks `method` of it, with `params`; `done` hears the result, or an error's message, on the UI thread.
    void request(string method, JSONValue params, void delegate(JSONValue result, string error) done)
    {
        if (_status == Status.stopped)
        {
            if (done)
                done(JSONValue(null), "the server isn't running");
            return;
        }
        const id = ++nextId;
        if (done)
            pending[id] = done;
        send(JSONValue(["jsonrpc": JSONValue("2.0"), "id": JSONValue(id), "method": JSONValue(method),
                        "params": params]), method != "initialize");
    }

    /// Tells it `method`, with `params`, wanting no answer.
    void notify(string method, JSONValue params)
    {
        if (_status == Status.stopped)
            return;
        send(JSONValue(["jsonrpc": JSONValue("2.0"), "method": JSONValue(method), "params": params]), true);
    }

    /// Hears what it says unasked: diagnostics, log messages. `method` is the protocol's.
    void addListener(void delegate(string method, JSONValue params) listener) { listeners ~= listener; }

    /// ditto
    void removeListener(void delegate(string method, JSONValue params) listener)
    {
        foreach (i, l; listeners)
            if (l is listener)
            {
                listeners = listeners[0 .. i] ~ listeners[i + 1 .. $];
                return;
            }
    }

    /// Asks it to shut down, and stops it.
    void stop()
    {
        if (_status == Status.stopped)
            return;
        if (_status == Status.ready)
        {
            request("shutdown", JSONValue(null), null);
            notify("exit", JSONValue(null));
        }
        _setStatus(Status.stopped);
        try
        {
            pipes.stdin.close();
            // A moment to go of its own accord; then it's made to
            import core.time : msecs;
            Thread.sleep(50.msecs);
            kill(pipes.pid);
        }
        catch (Exception) {}
    }

    /// A file's path as the protocol has it, and back.
    static string uriOf(string path)
    {
        import std.uri : encode;
        auto p = absolutePath(path);
        version (Windows)
        {
            import std.array : replace;
            p = "/" ~ p.replace("\\", "/");
        }
        return "file://" ~ encode(p);
    }

    /// ditto
    static string pathOf(string uri)
    {
        import std.uri : decode;
        if (!uri.startsWith("file://"))
            return uri;
        auto p = decode(uri["file://".length .. $]);
        version (Windows)
            if (p.length > 2 && p[0] == '/' && p[2] == ':')
                p = p[1 .. $];
        return p;
    }

private:
    string[] command;
    string root;
    ProcessPipes pipes;
    string _failure, _serverName;
    string[] triggers;
    long nextId;
    void delegate(JSONValue, string)[long] pending;
    void delegate(string, JSONValue)[] listeners;
    string[] waiting;   // what's sent before it's ready, sent once it is

    static bool onPath(string program)
    {
        import std.file : exists;
        import std.path : pathSeparator, isAbsolute;
        import std.array : split;
        if (isAbsolute(program))
            return exists(program);
        foreach (dir; environment.get("PATH", "").split(pathSeparator))
        {
            version (Windows)
            {
                foreach (ext; ["", ".exe", ".cmd", ".bat"])
                    if (exists(buildPath(dir, program ~ ext)))
                        return true;
            }
            else if (exists(buildPath(dir, program)))
                return true;
        }
        return false;
    }

    void start()
    {
        try
            pipes = pipeProcess(command, Redirect.stdin | Redirect.stdout | Redirect.stderr, null, Config.none, root);
        catch (Exception e)
        {
            fail("it couldn't be started: " ~ e.msg);
            return;
        }
        // Its output, read on a thread of its own; its errors, read and dropped, so it never blocks on them
        auto output = pipes.stdout, errors = pipes.stderr;
        auto self = this;
        auto reader = new Thread({ readMessages(self, output); });
        reader.isDaemon = true;
        reader.start();
        auto drain = new Thread({
            try
                foreach (line; errors.byLine)
                {
                    if (environment.get("MAYFAIR_LSP_TRACE"))
                        stderr.writeln("[lsp stderr] ", line);
                }
            catch (Exception) {}
        });
        drain.isDaemon = true;
        drain.start();

        auto capabilities = parseJSON(`{
            "textDocument": {
                "synchronization": { "didSave": true, "dynamicRegistration": false },
                "publishDiagnostics": { "relatedInformation": false },
                "completion": { "completionItem": { "snippetSupport": false, "documentationFormat": ["plaintext"] } },
                "hover": { "contentFormat": ["plaintext", "markdown"] },
                "definition": { "linkSupport": false }
            },
            "workspace": { "workspaceFolders": true, "configuration": true },
            "general": { "positionEncodings": ["utf-16"] }
        }`);
        auto params = JSONValue([
            "processId": JSONValue(processId),
            "rootUri": JSONValue(uriOf(root)),
            "rootPath": JSONValue(root),
            "capabilities": capabilities,
            "clientInfo": JSONValue(["name": JSONValue("Mayfair")]),
            "workspaceFolders": JSONValue([JSONValue(["uri": JSONValue(uriOf(root)), "name": JSONValue(root)])]),
        ]);
        request("initialize", params, (JSONValue result, string error) {
            if (error.length)
            {
                fail("it wouldn't start: " ~ error);
                return;
            }
            try
            {
                if (auto info = "serverInfo" in result)
                    if (auto n = "name" in *info)
                        _serverName = n.str;
                if (auto caps = "capabilities" in result)
                    if (auto c = "completionProvider" in *caps)
                        if (c.type == JSONType.object)
                            if (auto t = "triggerCharacters" in *c)
                                foreach (x; t.array)
                                    triggers ~= x.str;
            }
            catch (Exception) {}
            notify("initialized", JSONValue(string[string].init));
            _setStatus(Status.ready);
            foreach (w; waiting)
                write(w);
            waiting = null;
        });
    }

    static int processId()
    {
        import std.process : thisProcessID;
        return thisProcessID;
    }

    void fail(string why)
    {
        _failure = why;
        _setStatus(Status.stopped);
        foreach (id, done; pending.dup)
            done(JSONValue(null), why);
        pending = null;
    }

    void send(JSONValue message, bool waitUntilReady)
    {
        const body = message.toString;
        if (waitUntilReady && _status == Status.starting)
        {
            waiting ~= body;
            return;
        }
        write(body);
    }

    void write(string body)
    {
        try
        {
            pipes.stdin.write("Content-Length: ", body.length, "\r\n\r\n", body);
            pipes.stdin.flush();
            if (environment.get("MAYFAIR_LSP_TRACE"))
                stderr.writeln("[lsp ->] ", body.length > 300 ? body[0 .. 300] ~ "…" : body);
        }
        catch (Exception e)
            fail("it stopped: " ~ e.msg);
    }

    /// A message from it, on the UI thread.
    void received(JSONValue m)
    {
        if (environment.get("MAYFAIR_LSP_TRACE"))
        {
            const s = m.toString;
            stderr.writeln("[lsp <-] ", s.length > 300 ? s[0 .. 300] ~ "…" : s);
        }
        const hasMethod = ("method" in m) !is null, hasId = ("id" in m) !is null;
        if (hasMethod && hasId)
        {
            // A request of ours: answered as simply as it can be
            const method = m["method"].str;
            JSONValue result = JSONValue(null);
            if (method == "workspace/configuration")
            {
                JSONValue[] items;
                if (auto p = "params" in m)
                    if (auto it = "items" in *p)
                        foreach (_; it.array)
                            items ~= JSONValue(null);
                result = JSONValue(items);
            }
            else if (method == "workspace/workspaceFolders")
                result = JSONValue([JSONValue(["uri": JSONValue(uriOf(root)), "name": JSONValue(root)])]);
            send(JSONValue(["jsonrpc": JSONValue("2.0"), "id": m["id"], "result": result]), false);
            return;
        }
        if (hasMethod)
        {
            const method = m["method"].str;
            auto params = "params" in m ? m["params"] : JSONValue(null);
            foreach (l; listeners.dup)
                l(method, params);
            return;
        }
        if (hasId)
        {
            long id;
            try
                id = m["id"].type == JSONType.integer ? m["id"].integer : m["id"].str.to!long;
            catch (Exception)
                return;
            if (auto done = id in pending)
            {
                auto d = *done;
                pending.remove(id);
                if (auto e = "error" in m)
                    d(JSONValue(null), ("message" in *e) ? (*e)["message"].str : "an error");
                else
                    d("result" in m ? m["result"] : JSONValue(null), null);
            }
        }
    }

    void ended()
    {
        if (_status != Status.stopped)
            fail(_failure.length ? _failure : "it stopped");
    }
}

/// A message's delivery, on the UI thread: a closure of its own, as one made in the reading loop would
/// share the loop's variable with every other, and see a later message by the time it ran.
private void delegate() delivery(LanguageServer server, JSONValue message)
{
    return { server.received(message); };
}

/// The server's messages, read from `output` on a thread of their own, each handed to the UI thread.
private void readMessages(LanguageServer server, File output)
{
    try
    {
        while (true)
        {
            // The headers, up to a blank line; Content-Length is the one that matters
            size_t length;
            while (true)
            {
                auto line = output.readln();
                if (line is null)
                {
                    Platform.runLater({ server.ended(); });
                    return;
                }
                line = line.strip;
                if (!line.length)
                    break;
                if (line.toLower.startsWith("content-length:"))
                    length = line["content-length:".length .. $].strip.to!size_t;
            }
            if (!length)
                continue;
            auto bytes = new char[length];
            auto got = output.rawRead(bytes);
            if (got.length != length)
            {
                Platform.runLater({ server.ended(); });
                return;
            }
            JSONValue message;
            try
                message = parseJSON(bytes);
            catch (Exception)
                continue;
            Platform.runLater(delivery(server, message));
        }
    }
    catch (Exception)
        Platform.runLater({ server.ended(); });
}

/*
    A buffer, open in a server: sent when it's opened, and each edit as it's made, so the server
    sees what's typed; and what the server says about it -- diagnostics -- kept, and told to
    listeners. Ask it for completions, hovers and definitions at a place.
*/
final class LspDocument
{
public:
    this(LanguageServer server, TextBuffer buffer, string path, string languageId = null)
    {
        this.server = server;
        this.buffer = buffer;
        this.path = path;
        uri = LanguageServer.uriOf(path);
        auto lang = languageFor(path);
        this.languageId = languageId.length ? languageId : lang ? idFor(lang.name) : "plaintext";
        buffer.addListener(&edited);
        server.addListener(&heard);
        server.notify("textDocument/didOpen", JSONValue(["textDocument": JSONValue([
            "uri": JSONValue(uri), "languageId": JSONValue(this.languageId),
            "version": JSONValue(version_), "text": JSONValue(buffer.text)])]));
    }

    LanguageServer server;
    TextBuffer buffer;
    string path, uri, languageId;

    /// What the server last said is wrong with it.
    Diagnostic[] diagnostics;

    /// Hears each new set of diagnostics.
    void addDiagnosticsListener(void delegate() listener) { diagnosticListeners ~= listener; }

    /// Completions at `at`.
    void complete(TextPosition at, void delegate(Completion[]) done)
    {
        server.request("textDocument/completion", positionParams(at), (JSONValue r, string error) {
            Completion[] list;
            if (!error.length)
                try
                {
                    JSONValue[] items;
                    if (r.type == JSONType.array)
                        items = r.array;
                    else if (r.type == JSONType.object && ("items" in r))
                        items = r["items"].array;
                    foreach (it; items)
                    {
                        Completion c;
                        c.label = it["label"].str;
                        c.insertText = c.label;
                        if (auto t = "insertText" in it)
                            if (t.type == JSONType.string)
                                c.insertText = t.str;
                        if (auto d = "detail" in it)
                            if (d.type == JSONType.string)
                                c.detail = d.str;
                        if (auto k = "kind" in it)
                            if (k.type == JSONType.integer)
                                c.kind = cast(int) k.integer;
                        if (auto s = "sortText" in it)
                            if (s.type == JSONType.string)
                                c.sortText = s.str;
                        if (auto e = "textEdit" in it)
                        {
                            auto range = "range" in *e ? (*e)["range"] : "replace" in *e ? (*e)["replace"] : JSONValue(null);
                            if (range.type == JSONType.object)
                            {
                                c.replaceFrom = positionOf(range["start"]);
                                c.replaceTo = positionOf(range["end"]);
                                c.hasRange = true;
                            }
                            if (auto nt = "newText" in *e)
                                c.insertText = nt.str;
                        }
                        list ~= c;
                    }
                }
                catch (Exception) {}
            import std.algorithm : sort;
            list.sort!((a, b) => (a.sortText.length ? a.sortText : a.label) < (b.sortText.length ? b.sortText : b.label));
            done(list);
        });
    }

    /// What's at `at`, as the server describes it: a type, a signature, documentation. Empty for nothing.
    void hover(TextPosition at, void delegate(string) done)
    {
        server.request("textDocument/hover", positionParams(at), (JSONValue r, string error) {
            string text;
            if (!error.length && r.type == JSONType.object)
                try
                    text = contentsText(r["contents"]);
                catch (Exception) {}
            done(text.strip);
        });
    }

    /// Where what's at `at` is defined.
    void definition(TextPosition at, void delegate(Location[]) done)
    {
        server.request("textDocument/definition", positionParams(at), (JSONValue r, string error) {
            Location[] found;
            if (!error.length)
                try
                {
                    JSONValue[] items = r.type == JSONType.array ? r.array : r.type == JSONType.object ? [r] : null;
                    foreach (it; items)
                    {
                        const u = "uri" in it ? it["uri"].str : it["targetUri"].str;
                        auto range = "range" in it ? it["range"] : it["targetSelectionRange"];
                        const p = LanguageServer.pathOf(u);
                        // A place in another file is as the protocol has it, its column in UTF-16: near enough
                        TextPosition pos = p == path ? positionOf(range["start"])
                                         : TextPosition(cast(int) range["start"]["line"].integer,
                                                        cast(size_t) range["start"]["character"].integer);
                        found ~= Location(p, pos);
                    }
                }
                catch (Exception) {}
            done(found);
        });
    }

    /// Tells the server it's been saved.
    void saved()
    {
        server.notify("textDocument/didSave", JSONValue(["textDocument": JSONValue(["uri": JSONValue(uri)])]));
    }

    /// Tells the server it's closed, and stops following it.
    void close()
    {
        buffer.removeListener(&edited);
        server.removeListener(&heard);
        server.notify("textDocument/didClose", JSONValue(["textDocument": JSONValue(["uri": JSONValue(uri)])]));
    }

    /// A place as the protocol has it -- line, character in UTF-16 -- in this buffer.
    TextPosition positionOf(JSONValue p)
    {
        const line = cast(int) p["line"].integer;
        const ch = cast(size_t) p["character"].integer;
        return buffer.clamp(TextPosition(line, buffer.byteColumn(line, ch)));
    }

    /// ditto, the other way
    JSONValue lspPosition(TextPosition at)
    {
        return JSONValue(["line": JSONValue(at.line), "character": JSONValue(buffer.utf16Column(at.line, at.column))]);
    }

private:
    int version_ = 1;
    void delegate()[] diagnosticListeners;

    static string idFor(string language)
    {
        switch (language)
        {
            case "C++": return "cpp";
            case "C#": return "csharp";
            case "Shell": return "shellscript";
            default: return language.toLower;
        }
    }

    JSONValue positionParams(TextPosition at)
    {
        return JSONValue(["textDocument": JSONValue(["uri": JSONValue(uri)]), "position": lspPosition(at)]);
    }

    // An edit: sent as the range it replaced -- in UTF-16, as the text was before -- and what's there now
    void edited(ref const BufferChange c)
    {
        version_++;
        const startUnits = buffer.utf16Column(c.start.line, c.start.column);
        size_t endUnits;
        const nl = c.removed.lastIndexOfNewline;
        if (nl < 0)
            endUnits = startUnits + utf16Length(c.removed);
        else
            endUnits = utf16Length(c.removed[nl + 1 .. $]);
        auto range = JSONValue([
            "start": JSONValue(["line": JSONValue(c.start.line), "character": JSONValue(startUnits)]),
            "end": JSONValue(["line": JSONValue(c.oldEnd.line), "character": JSONValue(endUnits)]),
        ]);
        server.notify("textDocument/didChange", JSONValue([
            "textDocument": JSONValue(["uri": JSONValue(uri), "version": JSONValue(version_)]),
            "contentChanges": JSONValue([JSONValue(["range": range, "text": JSONValue(c.inserted)])]),
        ]));
    }

    void heard(string method, JSONValue params)
    {
        if (method != "textDocument/publishDiagnostics")
            return;
        try
        {
            if (params["uri"].str != uri && LanguageServer.pathOf(params["uri"].str) != absolutePath(path))
                return;
            Diagnostic[] list;
            foreach (d; params["diagnostics"].array)
            {
                Diagnostic x;
                x.start = positionOf(d["range"]["start"]);
                x.end = positionOf(d["range"]["end"]);
                if (auto s = "severity" in d)
                    x.severity = cast(Severity) s.integer;
                x.message = d["message"].str;
                if (auto s = "source" in d)
                    if (s.type == JSONType.string)
                        x.source = s.str;
                list ~= x;
            }
            diagnostics = list;
            foreach (l; diagnosticListeners.dup)
                l();
        }
        catch (Exception) {}
    }

    static string contentsText(JSONValue c)
    {
        if (c.type == JSONType.string)
            return c.str;
        if (c.type == JSONType.array)
        {
            string s;
            foreach (x; c.array)
                s ~= (s.length ? "\n\n" : "") ~ contentsText(x);
            return s;
        }
        if (c.type == JSONType.object && ("value" in c))
            return stripFences(c["value"].str);
        return null;
    }

    /// Markdown's ``` fences off a hover's code: a tooltip shows it plainly.
    static string stripFences(string s)
    {
        import std.array : join, split;
        string[] kept;
        foreach (line; s.split("\n"))
            if (!line.strip.startsWith("```"))
                kept ~= line;
        return kept.join("\n");
    }
}

private long lastIndexOfNewline(string s)
{
    foreach_reverse (i, c; s)
        if (c == '\n')
            return cast(long) i;
    return -1;
}

private size_t utf16Length(string s)
{
    size_t n;
    for (size_t i = 0; i < s.length;)
    {
        const b = s[i];
        const len = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4;
        n += len == 4 ? 2 : 1;
        i += len;
    }
    return n;
}

unittest
{
    assert(LanguageServer.pathOf(LanguageServer.uriOf("/tmp/a b.d")) == "/tmp/a b.d");
    assert(utf16Length("a😀") == 3);
    assert(LanguageServer.commandsFor("Python").length > 0);
}
