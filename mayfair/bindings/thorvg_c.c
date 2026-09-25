/*
    D bindings for ThorVG's C API (vendor/thorvg/src/bindings/capi/thorvg_capi.h).

    ldc's ImportC compiles this file as the D module `thorvg_c`: every function, struct and enum
    declared in the header becomes importable from D, so there are no hand-written bindings to keep
    in sync. D code should import it through `mayfair.renderers.thorvg`.

    It lives outside source/ because a C file's module name is always just its file name, so it
    can't be part of the `mayfair` package. The include path comes from cImportPaths in dub.json.

    The pragma marks every declaration @nogc nothrow, which is true of C code and lets them be
    called from @nogc nothrow D functions.
*/
#pragma attribute(push, nogc, nothrow)
#include <thorvg_capi.h>
#pragma attribute(pop)
