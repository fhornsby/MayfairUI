module mayfair.log;

import core.stdc.stdio : FILE, fprintf, fputs, fputc, stderr;
import core.stdc.stdlib : getenv;
import core.stdc.string : strcmp;

/*
    What Mayfair has to tell whoever is running the app, on stderr, a line at a time:

        [Mayfair] Vulkan is only available in software here (llvmpipe)
        [Mayfair] Using the opengl renderer, as webgpu couldn't start
        [Mayfair] warning: CSS: colour: not a colour
        [Mayfair] error: SDL_Init failed: no video device

    The tag says which part of the program a line is from, among the app's own output and dub's.
    In a terminal it's in colour by level -- green, yellow, red, as cargo and dub do -- and plain
    when stderr is a file or a pipe, or NO_COLOR is set, so a log file holds no escape codes.

    No timestamps: these are read as they come, and a service's journal stamps each line itself.
    For where the time goes, there's MAYFAIR_TRACE (mayfair.trace).

    All of this is @nogc nothrow, for the renderers and SDL callbacks, and takes printf's formats.
*/

/// Something worth knowing that isn't wrong: which renderer was fallen back to, say
void logInfo(A...)(scope const(char)* format, A args) nothrow @nogc {
    write(Level.info, format, args);
}

/// Something wrong that Mayfair carries on past: CSS it couldn't read, a renderer that wouldn't start
void logWarning(A...)(scope const(char)* format, A args) nothrow @nogc {
    write(Level.warning, format, args);
}

/// Something wrong that stops what was asked for: no window, no renderer at all
void logError(A...)(scope const(char)* format, A args) nothrow @nogc {
    write(Level.error, format, args);
}

private:

enum Level { info, warning, error }

void write(A...)(Level level, scope const(char)* format, A args) nothrow @nogc {
    // One line, whole, even with other threads writing too
    flockfile(stderr);
    scope(exit) funlockfile(stderr);
    static immutable const(char)*[3] colours = ["\x1b[1;32m", "\x1b[1;33m", "\x1b[1;31m"];
    static immutable const(char)*[3] labels = ["", "warning: ", "error: "];
    if (coloured()) {
        fprintf(stderr, "[%sMayfair\x1b[0m] ", colours[level]);
        if (level != Level.info)
            fprintf(stderr, "%s%s\x1b[0m", colours[level], labels[level]);
    } else {
        fprintf(stderr, "[Mayfair] %s", labels[level]);
    }
    static if (A.length)
        fprintf(stderr, format, args);
    else
        fputs(format, stderr);
    fputc('\n', stderr);
}

/// Whether stderr is a terminal that wants colour. Worked out once.
bool coloured() nothrow @nogc {
    version (Emscripten)
        return false; // the browser's console shows escape codes as they are
    else {
        __gshared byte answer = -1;
        if (answer < 0) {
            import core.sys.posix.unistd : isatty;
            const noColour = getenv("NO_COLOR");
            const term = getenv("TERM");
            answer = isatty(2) && !(noColour && *noColour) && !(term && strcmp(term, "dumb") == 0);
        }
        return answer == 1;
    }
}

extern (C) void flockfile(FILE*) nothrow @nogc;
extern (C) void funlockfile(FILE*) nothrow @nogc;
