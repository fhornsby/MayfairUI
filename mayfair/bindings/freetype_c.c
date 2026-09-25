/*
    D bindings for FreeType (vendor/freetype/include). FreeType turns a font file into glyph
    outlines and metrics; HarfBuzz decides which glyphs and where, and ThorVG draws them.

    Works the same way as thorvg_c.c: ldc's ImportC compiles it as the D module `freetype_c`.
    D code should import it through `mayfair.text.freetype`.

    ftoutln.h is here for FT_Outline_Decompose(), which walks a loaded glyph's outline and calls
    back with move/line/conic/cubic segments. That callback is how a glyph becomes a ThorVG path,
    and so it's the whole of Mayfair's vector text route.

    tttables.h is for FT_Get_Sfnt_Table(), which reads a face's OS/2 table: its weight and width
    class, which the font index in mayfair.text.fonts matches requests against.
*/
#pragma attribute(push, nogc, nothrow)
#include <ft2build.h>
#include <freetype/freetype.h>
#include <freetype/ftoutln.h>
#include <freetype/tttables.h>
#pragma attribute(pop)
