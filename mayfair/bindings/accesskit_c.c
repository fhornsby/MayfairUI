/*
    D bindings for AccessKit's C API (vendor/accesskit/include/accesskit.h), compiled by ImportC as
    the module `accesskit_c` the same way thorvg_c.c is. D code should import it through
    `mayfair.accessibility`.

    Only the functions for the platform being compiled for are declared: the header keeps each
    platform adapter behind its own #if.
*/
#pragma attribute(push, nogc, nothrow)
#include <accesskit.h>
#pragma attribute(pop)
