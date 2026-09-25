/*
    D bindings for libunibreak (vendor/libunibreak/src). It answers the question neither FreeType
    nor HarfBuzz does: where a line is allowed to break (UAX #14). Shaping and breaking are separate
    problems -- HarfBuzz will happily shape a paragraph into one run, and something still has to
    decide where that run may be cut.

    Works the same way as thorvg_c.c: ldc's ImportC compiles it as the D module `linebreak_c`.
    D code should import it through `mayfair.text.linebreak`.

    wordbreak.h and graphemebreak.h come along for what text editing needs later: grapheme clusters
    are the unit a caret moves by and backspace deletes, which is not the same as a code point.
*/
#pragma attribute(push, nogc, nothrow)
#include <linebreak.h>
#include <wordbreak.h>
#include <graphemebreak.h>
#pragma attribute(pop)
