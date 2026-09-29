module mayfair.trace;

import core.stdc.stdio : FILE, fopen, fclose, fprintf, fputc, setvbuf, stderr, _IOLBF;
import core.stdc.stdlib : getenv;
import sdl.timer : SDL_GetTicksNS;

/*
    Frame timing trace, for finding out where the time goes, e.g. during a resize. It's off unless the app
    is run with MAYFAIR_TRACE set to a file to write to:

        MAYFAIR_TRACE=trace.txt dub run

    Every line starts with the time in milliseconds since tracing started. All of this is @nogc nothrow,
    so it can be used from the frame phases and SDL callbacks.
*/

private __gshared FILE* traceFile;
private __gshared ulong traceStart;

/// Opens the trace file if MAYFAIR_TRACE is set. Call once at startup.
void traceOpen() nothrow @nogc {
    const(char)* path = getenv("MAYFAIR_TRACE");
    if (!path || !*path)
        return;
    traceFile = fopen(path, "w");
    if (!traceFile) {
        fprintf(stderr, "Couldn't open trace file %s\n", path);
        return;
    }
    setvbuf(traceFile, null, _IOLBF, 0); // write out every line, so nothing is lost if the app crashes
    traceStart = SDL_GetTicksNS();
}

void traceClose() nothrow @nogc {
    if (traceFile) {
        fclose(traceFile);
        traceFile = null;
    }
}

/// Whether tracing is on: for gathering what only a trace wants, which costs something to find out.
bool tracing() nothrow @nogc {
    return traceFile !is null;
}

/// Current time in nanoseconds. It's the same clock SDL uses for event timestamps.
ulong traceNow() nothrow @nogc {
    return SDL_GetTicksNS();
}

/// Milliseconds between two traceNow() values.
double traceMs(ulong from, ulong to) nothrow @nogc {
    return (to - from) / 1_000_000.0;
}

/// Writes a printf-style line to the trace, if tracing is on. Only pass C types (no D strings).
void trace(Args...)(const(char)* format, Args args) nothrow @nogc {
    if (!traceFile)
        return;
    fprintf(traceFile, "%10.3f  ", traceMs(traceStart, traceNow()));
    fprintf(traceFile, format, args);
    fputc('\n', traceFile);
}
