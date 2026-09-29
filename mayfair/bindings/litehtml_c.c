/*
    D bindings for litehtml, through the C face litehtml_shim.cpp puts on it (litehtml_shim.h):
    litehtml itself is C++, which ImportC can't read. See thorvg_c.c for how this works.

    Unlike the others, it isn't marked @nogc: the callbacks D gives it lay text out and load
    images, which allocate, and the document calls them from inside lh_document_render and
    lh_document_draw. Nothing thrown gets out of them, or of the shim.
*/
#pragma attribute(push, nothrow)
#include "litehtml_shim.h"
#pragma attribute(pop)
