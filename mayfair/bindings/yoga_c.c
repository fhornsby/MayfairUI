/*
    D bindings for Yoga's C API (vendor/yoga/yoga/Yoga.h). Yoga is C++ inside, but its public API is C.

    Works the same way as thorvg_c.c: ldc's ImportC compiles it as the D module `yoga_c`.
    D code should import it through `mayfair.layout`.
*/
#pragma attribute(push, nogc, nothrow)
#include <yoga/Yoga.h>
#pragma attribute(pop)
