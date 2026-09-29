/*
    litehtml's document_container, passing each call on to the C function table in
    litehtml_shim.h, and the document's methods as C functions. See the header for why.

    Nothing thrown gets out: litehtml is C++ and may throw (std::bad_alloc, if nothing else), and
    an exception unwinding into D's frames is undefined behaviour. So every entry point catches.

    vendor/build.sh compiles this into build/litehtml/liblitehtml_shim.a.
*/
#include "litehtml_shim.h"

#include <litehtml.h>
#include <litehtml/render_item.h>
#include <algorithm>
#include <cstring>

using namespace litehtml;

struct lh_string
{
    std::string value;
};

namespace
{

lh_colour colour(const web_color& c) { return {c.red, c.green, c.blue, c.alpha}; }
lh_position pos(const position& p) { return {p.x, p.y, p.width, p.height}; }

lh_radii radii(const border_radiuses& r)
{
    return {r.top_left_x, r.top_left_y, r.top_right_x, r.top_right_y,
            r.bottom_right_x, r.bottom_right_y, r.bottom_left_x, r.bottom_left_y};
}

lh_border border(const litehtml::border& b) { return {b.width, (int) b.style, colour(b.color)}; }

lh_background_layer layer(const background_layer& l)
{
    lh_background_layer out;
    out.border_box = pos(l.border_box);
    out.clip_box = pos(l.clip_box);
    out.origin_box = pos(l.origin_box);
    out.border_radius = radii(l.border_radius);
    out.repeat = (int) l.repeat;
    out.is_root = l.is_root;
    return out;
}

std::vector<lh_colour_stop> stops(const background_layer::gradient_base& g)
{
    std::vector<lh_colour_stop> out;
    out.reserve(g.color_points.size());
    for (const auto& p : g.color_points)
        out.push_back({p.offset, colour(p.color)});
    return out;
}

class Container final : public document_container
{
public:
    explicit Container(const lh_callbacks& callbacks) : cb(callbacks) {}

    uint_ptr create_font(const font_description& d, const document*, font_metrics* fm) override
    {
        lh_font_description desc;
        desc.family = d.family.c_str();
        desc.size = d.size;
        desc.italic = d.style != font_style_normal;
        desc.weight = d.weight;
        desc.decoration_line = d.decoration_line;
        // auto and from-font are the font's own; a length litehtml has already made pixels
        desc.decoration_thickness = d.decoration_thickness.is_predefined() ? 0 : d.decoration_thickness.val();
        desc.decoration_style = (int) d.decoration_style;
        desc.decoration_colour = colour(d.decoration_color);
        desc.decoration_current_colour = d.decoration_color.is_current_color;
        lh_font_metrics m = {};
        auto font = cb.create_font(cb.user, &desc, &m);
        if (fm)
        {
            fm->font_size = m.font_size;
            fm->height = m.height;
            fm->ascent = m.ascent;
            fm->descent = m.descent;
            fm->x_height = m.x_height;
            fm->ch_width = m.ch_width;
            fm->draw_spaces = m.draw_spaces;
            fm->sub_shift = m.sub_shift;
            fm->super_shift = m.super_shift;
        }
        return font;
    }

    void delete_font(uint_ptr font) override { cb.delete_font(cb.user, font); }
    pixel_t text_width(const char* text, uint_ptr font) override { return cb.text_width(cb.user, text, font); }

    void draw_text(uint_ptr hdc, const char* text, uint_ptr font, web_color c, const position& p) override
    {
        cb.draw_text(cb.user, hdc, text, font, colour(c), pos(p));
    }

    pixel_t pt_to_px(float pt) const override { return pt * 96 / 72; }
    pixel_t get_default_font_size() const override { return cb.default_font_size; }
    const char* get_default_font_name() const override { return cb.default_font_name; }

    void draw_list_marker(uint_ptr hdc, const list_marker& marker) override
    {
        lh_list_marker m;
        m.image = marker.image.c_str();
        m.base_url = marker.baseurl ? marker.baseurl : "";
        m.type = (int) marker.marker_type;
        m.colour = colour(marker.color);
        m.pos = pos(marker.pos);
        m.font = marker.font;
        cb.draw_list_marker(cb.user, hdc, &m);
    }

    void load_image(const char* src, const char* base, bool redraw) override
    {
        cb.load_image(cb.user, src, base ? base : "", redraw);
    }

    void get_image_size(const char* src, const char* base, size& sz) override
    {
        float w = 0, h = 0;
        cb.get_image_size(cb.user, src, base ? base : "", &w, &h);
        sz.width = w;
        sz.height = h;
    }

    void draw_image(uint_ptr hdc, const background_layer& l, const std::string& url, const std::string& base) override
    {
        auto out = layer(l);
        cb.draw_image(cb.user, hdc, &out, url.c_str(), base.c_str());
    }

    void draw_solid_fill(uint_ptr hdc, const background_layer& l, const web_color& c) override
    {
        auto out = layer(l);
        cb.draw_solid_fill(cb.user, hdc, &out, colour(c));
    }

    void draw_linear_gradient(uint_ptr hdc, const background_layer& l, const background_layer::linear_gradient& g) override
    {
        auto out = layer(l);
        auto s = stops(g);
        lh_gradient grad = {};
        grad.stops = s.data();
        grad.stop_count = s.size();
        grad.x1 = g.start.x;
        grad.y1 = g.start.y;
        grad.x2 = g.end.x;
        grad.y2 = g.end.y;
        cb.draw_linear_gradient(cb.user, hdc, &out, &grad);
    }

    void draw_radial_gradient(uint_ptr hdc, const background_layer& l, const background_layer::radial_gradient& g) override
    {
        auto out = layer(l);
        auto s = stops(g);
        lh_gradient grad = {};
        grad.stops = s.data();
        grad.stop_count = s.size();
        grad.cx = g.position.x;
        grad.cy = g.position.y;
        grad.rx = g.radius.x;
        grad.ry = g.radius.y;
        cb.draw_radial_gradient(cb.user, hdc, &out, &grad);
    }

    void draw_conic_gradient(uint_ptr hdc, const background_layer& l, const background_layer::conic_gradient& g) override
    {
        auto out = layer(l);
        auto s = stops(g);
        lh_gradient grad = {};
        grad.stops = s.data();
        grad.stop_count = s.size();
        grad.cx = g.position.x;
        grad.cy = g.position.y;
        grad.rx = grad.ry = g.radius;
        grad.angle = g.angle;
        cb.draw_conic_gradient(cb.user, hdc, &out, &grad);
    }

    void draw_borders(uint_ptr hdc, const borders& b, const position& p, bool root) override
    {
        lh_borders out = {border(b.left), border(b.top), border(b.right), border(b.bottom), radii(b.radius)};
        cb.draw_borders(cb.user, hdc, &out, pos(p), root);
    }

    void set_caption(const char* caption) override { cb.set_caption(cb.user, caption); }
    void set_base_url(const char* base) override { cb.set_base_url(cb.user, base ? base : ""); }
    void link(const std::shared_ptr<document>&, const element::ptr&) override {}
    void on_anchor_click(const char* url, const element::ptr&) override { cb.anchor_click(cb.user, url); }
    void on_mouse_event(const element::ptr&, mouse_event) override {}
    void set_cursor(const char* cursor) override { cb.set_cursor(cb.user, cursor); }

    void transform_text(string& text, text_transform tt) override
    {
        lh_string s{text};
        cb.transform_text(cb.user, &s, (int) tt);
        text = std::move(s.value);
    }

    void import_css(string& text, const string& url, string& base) override
    {
        lh_string t, b{base};
        cb.import_css(cb.user, &t, url.c_str(), &b);
        text = std::move(t.value);
        base = std::move(b.value);
    }

    void set_clip(const position& p, const border_radiuses& r) override { cb.set_clip(cb.user, pos(p), radii(r)); }
    void del_clip() override { cb.del_clip(cb.user); }

    void get_viewport(position& viewport) const override
    {
        lh_position v = {};
        cb.get_viewport(cb.user, &v);
        viewport = position(v.x, v.y, v.width, v.height);
    }

    element::ptr create_element(const char*, const string_map&, const std::shared_ptr<document>&) override
    {
        return nullptr; // litehtml's own, for every tag
    }

    void get_media_features(media_features& media) const override
    {
        position viewport;
        get_viewport(viewport);
        media.type = media_type_screen;
        media.width = viewport.width;
        media.height = viewport.height;
        media.device_width = viewport.width;
        media.device_height = viewport.height;
        media.color = 8;
        media.color_index = 0;
        media.monochrome = 0;
        media.resolution = 96;
    }

    void get_language(string& language, string& culture) const override
    {
        language = "en";
        culture = "";
    }

private:
    lh_callbacks cb;
};

} // namespace

struct lh_document
{
    Container container;
    document::ptr doc;

    explicit lh_document(const lh_callbacks& cb) : container(cb) {}
};

extern "C" {

void lh_string_set(lh_string* s, const char* text, size_t length)
{
    try { s->value.assign(text, length); } catch (...) {}
}

const char* lh_string_get(const lh_string* s, size_t* length)
{
    if (length)
        *length = s->value.size();
    return s->value.c_str();
}

lh_document* lh_document_create(const char* html, size_t length, const lh_callbacks* callbacks, const char* user_css)
{
    lh_document* d = nullptr;
    try
    {
        d = new lh_document(*callbacks);
        estring text(std::string(html, length), encoding::utf_8, confidence::certain);
        d->doc = document::createFromString(text, &d->container, master_css, user_css ? user_css : "");
        if (d->doc)
            return d;
    }
    catch (...) {}
    delete d;
    return nullptr;
}

void lh_document_destroy(lh_document* doc)
{
    try { delete doc; } catch (...) {}
}

float lh_document_render(lh_document* doc, float max_width)
{
    try { return doc->doc->render(max_width); } catch (...) { return 0; }
}

float lh_document_width(lh_document* doc) { return doc->doc->width(); }
float lh_document_height(lh_document* doc) { return doc->doc->height(); }

void lh_document_draw(lh_document* doc, uintptr_t hdc, float x, float y, const lh_position* clip)
{
    try
    {
        if (clip)
        {
            position c(clip->x, clip->y, clip->width, clip->height);
            doc->doc->draw(hdc, x, y, &c);
        }
        else
            doc->doc->draw(hdc, x, y, nullptr);
    }
    catch (...) {}
}

bool lh_document_mouse_over(lh_document* doc, float x, float y)
{
    try
    {
        position::vector boxes;
        return doc->doc->on_mouse_over(x, y, x, y, boxes);
    }
    catch (...) { return false; }
}

bool lh_document_mouse_down(lh_document* doc, float x, float y)
{
    try
    {
        position::vector boxes;
        return doc->doc->on_lbutton_down(x, y, x, y, boxes);
    }
    catch (...) { return false; }
}

bool lh_document_mouse_up(lh_document* doc, float x, float y)
{
    try
    {
        position::vector boxes;
        return doc->doc->on_lbutton_up(x, y, x, y, boxes);
    }
    catch (...) { return false; }
}

bool lh_document_mouse_leave(lh_document* doc)
{
    try
    {
        position::vector boxes;
        return doc->doc->on_mouse_leave(boxes);
    }
    catch (...) { return false; }
}

bool lh_document_mouse_cancel(lh_document* doc)
{
    try
    {
        position::vector boxes;
        return doc->doc->on_button_cancel(boxes);
    }
    catch (...) { return false; }
}

bool lh_document_media_changed(lh_document* doc)
{
    try { return doc->doc->media_changed(); } catch (...) { return false; }
}

bool lh_document_find(lh_document* doc, const char* selector, lh_position* where)
{
    try
    {
        auto root = doc->doc->root();
        auto el = root ? root->select_one(selector) : nullptr;
        if (!el)
            return false;
        // An inline element -- a link, a <span> -- has no box of its own, only one on each line it's
        // on, placed as its render item is but from where that is. Its placement alone is a point
        // at the start of its first line.
        auto ri = el->get_render_item();
        position::vector boxes;
        if (ri)
            ri->get_inline_boxes(boxes);
        if (boxes.empty())
        {
            *where = pos(el->get_placement());
            return true;
        }
        const auto placed = ri->get_placement();
        const auto dx = placed.x - ri->pos().x, dy = placed.y - ri->pos().y;
        pixel_t left = boxes[0].left(), top = boxes[0].top(), right = boxes[0].right(), bottom = boxes[0].bottom();
        for (const auto& b : boxes)
        {
            left = std::min(left, b.left());
            top = std::min(top, b.top());
            right = std::max(right, b.right());
            bottom = std::max(bottom, b.bottom());
        }
        *where = {left + dx, top + dy, right - left, bottom - top};
        return true;
    }
    catch (...) { return false; }
}

} // extern "C"
