/*
    D bindings for SheenBidi (vendor/sheenbidi/Headers), the Unicode Bidirectional Algorithm
    (UAX #9): given text mixing left-to-right and right-to-left scripts, it says which stretches
    run which way and what order they're shown in. HarfBuzz shapes one direction at a time and
    leaves the ordering to its caller, so this is what comes before it.

    Works the same way as thorvg_c.c: ldc's ImportC compiles it as the D module `sheenbidi_c`.
    D code should import it through `mayfair.text.bidi`.
*/
#pragma attribute(push, nogc, nothrow)
#include <SheenBidi/SheenBidi.h>
#pragma attribute(pop)
