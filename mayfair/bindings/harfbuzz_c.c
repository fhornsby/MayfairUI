/*
    D bindings for HarfBuzz (vendor/harfbuzz/src). HarfBuzz does the shaping: text plus a font in,
    glyph ids and positions out, honouring the font's GSUB and GPOS tables. That is the part
    ThorVG's own text support doesn't do -- it accumulates advances and legacy kern pairs, so no
    ligatures, no contextual forms, no mark positioning and no GPOS kerning.

    Works the same way as thorvg_c.c: ldc's ImportC compiles it as the D module `harfbuzz_c`.
    D code should import it through `mayfair.text.harfbuzz`.

    hb-ft.h is the bridge to FreeType: hb_ft_font_create() makes an hb_font_t that reads its
    metrics and tables straight from an FT_Face, so there is one source of truth for both.
*/
#pragma attribute(push, nogc, nothrow)
#include <hb.h>
#include <hb-ft.h>
#pragma attribute(pop)
