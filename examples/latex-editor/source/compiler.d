module compiler;

import core.thread : Thread;
import core.time : Duration, MonoTime;
import std.algorithm : canFind, endsWith, startsWith;
import std.array : join;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, timeLastModified;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, isAbsolute, stripExtension;
import std.process : environment, execute, Config;
import std.regex : ctRegex, matchAll, matchFirst;
import std.string : lineSplitter, strip;
import mayfair;
import project;

/// Which TeX engine compiles: pdfLaTeX, or XeLaTeX or LuaLaTeX for system fonts and Unicode.
enum Engine { pdfLaTeX, xeLaTeX, luaLaTeX }

/// An error or warning from a compile: where it was, and what it said.
struct Problem
{
    string file;    /// The file it's in, absolute; null if the log doesn't say
    int line;       /// From 1; 0 if the log doesn't say
    string message;
    bool error;     /// An error, which stops the PDF being right; otherwise a warning

    /// As the logs list shows it.
    string toString() const
    {
        const where = file.length ? baseName(file) ~ (line ? ":" ~ line.to!string : "") : "";
        return (error ? "Error  " : "Warning  ") ~ (where.length ? where ~ "  " : "") ~ message;
    }
}

/// How a compile went.
struct CompileResult
{
    bool ran;           /// Whether TeX could be run at all
    bool succeeded;     /// Whether it made a PDF with no errors
    string pdf;         /// The PDF, if there is one: this compile's, or the last one's
    bool fresh;         /// Whether this compile made the PDF, rather than leaving the last one
    Problem[] problems;
    Duration took;
    string failure;     /// Why it couldn't run, if it couldn't
}

/*
    Compiles a project's main file, on a thread of its own, so typing carries on while TeX works.

    It runs latexmk where it's installed, as Overleaf does, which runs the engine as many times as
    the cross-references need, and BibTeX or Biber when there's a bibliography; where it isn't,
    the engine itself, twice. Always with SyncTeX, so the editor and the PDF can find each other's
    places, and nonstop, so an error is listed rather than waited on. What it makes goes in the
    project's .build folder.

    One compile at a time: asked for while one's running, another follows it, once.
*/
final class Compiler
{
    Engine engine;

    /// Compiles `p`'s main file, then calls `done` on the UI thread.
    void compile(Project p, void delegate(CompileResult) done)
    {
        if (running)
        {
            again = true;
            againWith = done;
            return;
        }
        running = true;
        const folder = p.folder, main = p.mainFile, output = p.outputFolder, pdf = p.pdf;
        const which = engine;
        new Thread({
            auto result = run(folder, main, output, pdf, which);
            Platform.runLater(finished(p, result, done));
        }).start();
    }

    /// Whether it's compiling now.
    bool busy() const { return running; }

private:
    bool running, again;
    void delegate(CompileResult) againWith;

    // Built in a function of its own, so each compile's closure has its own result
    void delegate() finished(Project p, CompileResult result, void delegate(CompileResult) done)
    {
        return {
            running = false;
            done(result);
            if (again)
            {
                again = false;
                compile(p, againWith);
            }
        };
    }
}

/// Whether `program` is on the PATH.
bool installed(string program)
{
    import std.path : pathSeparator;
    import std.algorithm : splitter;
    foreach (dir; environment.get("PATH", "").splitter(pathSeparator))
        if (dir.length && exists(buildPath(dir, program)))
            return true;
    return false;
}

private:

CompileResult run(string folder, string main, string output, string pdf, Engine engine)
{
    CompileResult result;
    if (!main)
    {
        result.failure = "there's no .tex file with a \\documentclass in the project";
        return result;
    }
    const started = MonoTime.currTime;
    try
        mkdirRecurse(output);
    catch (Exception e)
    {
        result.failure = e.msg;
        return result;
    }
    // Long log lines, rather than TeX's 79 characters, so messages and file names aren't broken
    string[string] env = ["max_print_line": "10000", "error_line": "254", "half_error_line": "238"];
    const program = engine == Engine.xeLaTeX ? "xelatex" : engine == Engine.luaLaTeX ? "lualatex" : "pdflatex";
    const common = ["-interaction=nonstopmode", "-file-line-error", "-synctex=1"];
    const before = exists(pdf) ? timeLastModified(pdf) : typeof(timeLastModified(pdf)).init;
    try
    {
        if (installed("latexmk"))
        {
            const flag = engine == Engine.xeLaTeX ? "-xelatex" : engine == Engine.luaLaTeX ? "-lualatex" : "-pdf";
            execute(["latexmk", flag, "-outdir=" ~ output] ~ common ~ [main], env, Config.none, size_t.max, folder);
        }
        else if (installed(program))
        {
            foreach (pass; 0 .. 2)
                execute([program, "-output-directory=" ~ output] ~ common ~ [main], env, Config.none, size_t.max, folder);
        }
        else
        {
            result.failure = "neither latexmk nor " ~ program ~ " is installed";
            return result;
        }
    }
    catch (Exception e)
    {
        result.failure = e.msg;
        return result;
    }
    result.ran = true;
    result.took = MonoTime.currTime - started;

    const log = buildPath(output, stripExtension(baseName(main)) ~ ".log");
    try
        result.problems = parseLog(readText(log), folder, main);
    catch (Exception) {}
    // The PDF: made this time, or as it was, if nothing's changed since -- latexmk leaves it
    // then -- or if this compile couldn't make one, as Overleaf shows the last that worked
    if (exists(pdf))
        result.pdf = pdf;
    result.fresh = result.pdf.length && timeLastModified(pdf) != before;
    bool errors;
    foreach (ref p; result.problems)
        errors |= p.error;
    result.succeeded = result.pdf.length && !errors;
    return result;
}

/*
    The errors and warnings in a TeX log. With -file-line-error an error says where it is,
    "./chapters/intro.tex:12: Undefined control sequence."; a warning only says its line, so its
    file is the one the log last said it opened -- "(./chapters/intro.tex" -- which is right but
    for warnings about what's already been closed.
*/
Problem[] parseLog(string log, string folder, string main)
{
    Problem[] problems;
    string current = main;
    string resolve(string file)
    {
        file = file.strip;
        if (!file.length)
            return main;
        return buildNormalizedPath(isAbsolute(file) ? file : buildPath(folder, file));
    }
    auto fileLine = ctRegex!`^(.+?\.(?:tex|sty|cls|bib|ltx)):(\d+): (.+)$`;
    auto opened = ctRegex!`\(((?:\./|/)[^()\s]+\.(?:tex|sty|cls|ltx))`;
    auto latexWarning = ctRegex!`^(?:LaTeX|Package \S+|Class \S+) Warning: (.+?)(?: on input line (\d+))?\.?$`;
    auto badBox = ctRegex!`^((?:Overfull|Underfull) \\[hv]box .*?) (?:in paragraph |in alignment )?at lines? (\d+)`;
    bool[string] seen;
    void add(Problem p)
    {
        const key = p.file ~ ":" ~ p.line.to!string ~ ":" ~ p.message;
        if (key in seen)
            return;
        seen[key] = true;
        problems ~= p;
    }
    foreach (line; log.lineSplitter)
    {
        // Files opened, on the way: the last one's where a warning is
        foreach (m; line.matchAll(opened))
            if (m[1].endsWith(".tex"))
                current = resolve(m[1]);
        if (auto m = line.matchFirst(fileLine))
        {
            add(Problem(resolve(m[1]), m[2].to!int, m[3].strip, true));
            continue;
        }
        if (line.startsWith("! "))
        {
            add(Problem(current, 0, line[2 .. $].strip, true));
            continue;
        }
        if (auto m = line.matchFirst(latexWarning))
        {
            add(Problem(current, m[2].length ? m[2].to!int : 0, m[1].strip, false));
            continue;
        }
        if (auto m = line.matchFirst(badBox))
            add(Problem(current, m[2].to!int, m[1].strip, false));
    }
    return problems;
}

unittest
{
    const log = "This is pdfTeX\n(./main.tex\nLaTeX2e <2023>\n(./sections/intro.tex\n"
        ~ "./sections/intro.tex:12: Undefined control sequence.\nl.12 \\foo\n"
        ~ "LaTeX Warning: Reference `fig:x' on page 1 undefined on input line 20.\n"
        ~ "Overfull \\hbox (3.2pt too wide) in paragraph at lines 30--31\n)\n"
        ~ "LaTeX Warning: There were undefined references.\n";
    auto ps = parseLog(log, "/p", "/p/main.tex");
    assert(ps.length == 4);
    assert(ps[0].error && ps[0].file == "/p/sections/intro.tex" && ps[0].line == 12
           && ps[0].message == "Undefined control sequence.");
    assert(!ps[1].error && ps[1].line == 20 && ps[1].file == "/p/sections/intro.tex");
    assert(ps[2].message.startsWith("Overfull") && ps[2].line == 30);
    assert(ps[3].line == 0);
}
