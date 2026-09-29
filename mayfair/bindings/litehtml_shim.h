/*
    A C face on litehtml, which is C++ all the way through: its documents are shared_ptrs, its
    strings std::strings, and what it asks of the program showing a document is a C++ class to
    subclass, document_container. None of that crosses into D. litehtml_shim.cpp subclasses it
    once, turning every virtual call into a call through the table of plain C function pointers
    below, with plain C structs for arguments; and the document's own methods become lh_document_*
    functions. D fills in the table (mayfair.widgets.litewebview).

    Every length is in CSS pixels, which Mayfair takes as points: the Scene's one transform does the
    rest, as for everything else.

    Strings coming back from D -- a stylesheet @import names, text a text-transform changes -- go
    through lh_string_set, into a std::string the shim owns, so nothing has to agree on who frees what.
*/
#ifndef MAYFAIR_LITEHTML_SHIM_H
#define MAYFAIR_LITEHTML_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lh_document lh_document;
typedef struct lh_string lh_string; /* a std::string of the shim's, to be filled in */

typedef struct { float x, y, width, height; } lh_position;
typedef struct { uint8_t r, g, b, a; } lh_colour;

/* Each corner's radii, across and down */
typedef struct
{
    float top_left_x, top_left_y, top_right_x, top_right_y;
    float bottom_right_x, bottom_right_y, bottom_left_x, bottom_left_y;
} lh_radii;

/* litehtml's border_style, in its order */
enum
{
    LH_BORDER_NONE, LH_BORDER_HIDDEN, LH_BORDER_DOTTED, LH_BORDER_DASHED, LH_BORDER_SOLID,
    LH_BORDER_DOUBLE, LH_BORDER_GROOVE, LH_BORDER_RIDGE, LH_BORDER_INSET, LH_BORDER_OUTSET,
};

typedef struct { float width; int style; lh_colour colour; } lh_border;
typedef struct { lh_border left, top, right, bottom; lh_radii radius; } lh_borders;

/* litehtml's background_repeat */
enum { LH_REPEAT, LH_REPEAT_X, LH_REPEAT_Y, LH_NO_REPEAT };

/*
    Where one layer of a box's background goes. Nothing is drawn outside clip_box, with
    border_radius at its corners; an image's one copy is origin_box, which repeating tiles from.
*/
typedef struct
{
    lh_position border_box, clip_box, origin_box;
    lh_radii border_radius;
    int repeat;
    bool is_root;
} lh_background_layer;

typedef struct { float offset; lh_colour colour; } lh_colour_stop;

typedef struct
{
    const lh_colour_stop* stops;
    size_t stop_count;
    float x1, y1, x2, y2;       /* linear: from, to */
    float cx, cy, rx, ry;       /* radial and conic: centre; radial: radii */
    float angle;                /* conic: where it starts, in degrees clockwise from the top */
} lh_gradient;

/* litehtml's text_decoration_line bits and text_decoration_style */
enum { LH_UNDERLINE = 1, LH_OVERLINE = 2, LH_LINE_THROUGH = 4 };
enum { LH_DECORATION_SOLID, LH_DECORATION_DOUBLE, LH_DECORATION_DOTTED, LH_DECORATION_DASHED, LH_DECORATION_WAVY };

typedef struct
{
    const char* family;         /* as CSS says it: a list, comma separated, names maybe quoted */
    float size;
    bool italic;                /* italic or oblique */
    int weight;                 /* 100 to 900 */
    int decoration_line;        /* LH_UNDERLINE | ... */
    float decoration_thickness; /* 0 for the font's own */
    int decoration_style;
    lh_colour decoration_colour;
    bool decoration_current_colour; /* the decoration's the text's colour, whatever decoration_colour says */
} lh_font_description;

typedef struct
{
    float font_size, height, ascent, descent, x_height, ch_width;
    bool draw_spaces;
    float sub_shift, super_shift;
} lh_font_metrics;

/* litehtml's list_style_type, the ones drawn as shapes rather than text */
enum { LH_MARKER_NONE, LH_MARKER_CIRCLE, LH_MARKER_DISC, LH_MARKER_SQUARE };

typedef struct
{
    const char* image;          /* empty, or where list-style-image says */
    const char* base_url;
    int type;                   /* litehtml's list_style_type: LH_MARKER_* for a shape, more for text */
    lh_colour colour;
    lh_position pos;
    uintptr_t font;
} lh_list_marker;

/* litehtml's text_transform */
enum { LH_TRANSFORM_NONE, LH_TRANSFORM_CAPITALIZE, LH_TRANSFORM_UPPERCASE, LH_TRANSFORM_LOWERCASE };

/*
    What a document asks of whoever shows it: document_container, one function each. `user` is
    lh_callbacks.user, every time; `hdc` is what lh_document_draw was given.
*/
typedef struct
{
    void* user;

    uintptr_t (*create_font)(void* user, const lh_font_description* description, lh_font_metrics* metrics);
    void (*delete_font)(void* user, uintptr_t font);
    float (*text_width)(void* user, const char* text, uintptr_t font);
    void (*draw_text)(void* user, uintptr_t hdc, const char* text, uintptr_t font, lh_colour colour, lh_position pos);
    float default_font_size;
    const char* default_font_name;

    void (*draw_list_marker)(void* user, uintptr_t hdc, const lh_list_marker* marker);
    void (*load_image)(void* user, const char* src, const char* base_url, bool redraw_on_ready);
    void (*get_image_size)(void* user, const char* src, const char* base_url, float* width, float* height);
    void (*draw_image)(void* user, uintptr_t hdc, const lh_background_layer* layer, const char* url, const char* base_url);
    void (*draw_solid_fill)(void* user, uintptr_t hdc, const lh_background_layer* layer, lh_colour colour);
    void (*draw_linear_gradient)(void* user, uintptr_t hdc, const lh_background_layer* layer, const lh_gradient* gradient);
    void (*draw_radial_gradient)(void* user, uintptr_t hdc, const lh_background_layer* layer, const lh_gradient* gradient);
    void (*draw_conic_gradient)(void* user, uintptr_t hdc, const lh_background_layer* layer, const lh_gradient* gradient);
    void (*draw_borders)(void* user, uintptr_t hdc, const lh_borders* borders, lh_position pos, bool root);

    void (*set_caption)(void* user, const char* caption);
    void (*set_base_url)(void* user, const char* base_url);
    void (*anchor_click)(void* user, const char* url);
    void (*set_cursor)(void* user, const char* cursor);
    void (*transform_text)(void* user, lh_string* text, int transform);
    /* A stylesheet at `url`, from <link> or @import: its text into `text`, and where it came from
       into `base_url`, for what it refers to in turn. `base_url` comes in as the one it's from. */
    void (*import_css)(void* user, lh_string* text, const char* url, lh_string* base_url);
    void (*set_clip)(void* user, lh_position pos, lh_radii radius);
    void (*del_clip)(void* user);
    void (*get_viewport)(void* user, lh_position* viewport);
} lh_callbacks;

/* Its contents, for a callback handed one to fill in */
void lh_string_set(lh_string* s, const char* text, size_t length);
const char* lh_string_get(const lh_string* s, size_t* length);

/*
    Parses `html` into a document, styled by litehtml's own user-agent stylesheet and then
    `user_css`, which may be null. `callbacks` is copied, but what it points to has to outlast the
    document. Null if litehtml threw.
*/
lh_document* lh_document_create(const char* html, size_t length, const lh_callbacks* callbacks, const char* user_css);
void lh_document_destroy(lh_document* doc);

/* Lays it out `max_width` wide, and says how wide it came out */
float lh_document_render(lh_document* doc, float max_width);
float lh_document_width(lh_document* doc);
float lh_document_height(lh_document* doc);

/* Draws what's inside `clip` (or all of it, for null) with its top left at `x`, `y` */
void lh_document_draw(lh_document* doc, uintptr_t hdc, float x, float y, const lh_position* clip);

/*
    The pointer, at `x`, `y` in the document. Each says whether what's drawn changed -- :hover and
    :active styles -- so it's to be laid out and drawn again. A click on a link calls anchor_click.
*/
bool lh_document_mouse_over(lh_document* doc, float x, float y);
bool lh_document_mouse_down(lh_document* doc, float x, float y);
bool lh_document_mouse_up(lh_document* doc, float x, float y);
bool lh_document_mouse_leave(lh_document* doc);
bool lh_document_mouse_cancel(lh_document* doc);

/* The viewport or media changed: whether styles did with it, and so it's to be laid out again */
bool lh_document_media_changed(lh_document* doc);

/*
    Where the first element `selector` matches is, from the document's top left: what a link to
    "#name" scrolls to. An inline element over several lines gives the rectangle round all of
    them. False if nothing matches.
*/
bool lh_document_find(lh_document* doc, const char* selector, lh_position* where);

#ifdef __cplusplus
}
#endif

#endif
