module mayfair.widgets.litewebview;

import mayfair.accessibility;
import litehtml_c : lh_position;
import mayfair.html.document;
import mayfair.layout;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.text;
import mayfair.theme;
import mayfair.widgets.input;
import mayfair.widgets.scrollpane;
import mayfair.widgets.widget;

/*
    Shows a page of HTML: help, release notes, a formatted report. A light JavaFX WebView.

        auto help = new LiteWebView();
        help.load("docs/index.html");
        help.loadContent("<h1>Hello</h1><p>Some <b>bold</b> text.</p>");

    It's litehtml underneath (see mayfair.html.document): HTML and CSS, laid out and drawn with
    Mayfair's own text and ThorVG, with no browser engine. So it has no JavaScript, no forms, and
    no network -- pictures and stylesheets come from files and data: URLs -- and what CSS it knows
    is litehtml's: blocks, inline text, floats, tables, flexbox, backgrounds, borders and
    gradients, but not transforms or animation. It's a document viewer, not a browser. A real web
    view comes later.

    The page scrolls in a ScrollPane, as JavaFX's does, and is laid out at its width. Links
    follow: to another file, which it loads; to a #fragment, which it scrolls to; and anywhere
    else -- https:, mailto: -- by the desktop, in the browser and so on. setOnLinkClicked sees a
    link first, and can consume it to do something else.

    Text is the theme's text colour, and links its accent, until the page says otherwise; its font
    is the theme's too, font() to change it. userStyleSheet goes over the page's defaults, for an
    app that shows pages of its own and wants them to look a certain way.

    Its style class is "lite-web-view".
*/
class LiteWebView : Widget
{
public:
    this(string html = null)
    {
        _content = new Content(this);
        _pane = new ScrollPane(_content);
        _pane.setFitToWidth(true);
        _pane.setFitToHeight(true); // at least as tall as the view, for the page's background to fill
        _font = defaultFont(Theme.text_size);
        styleClass.add("lite-web-view");
        setAccessibleRole(AccessibleRole.document);
        adopt(_pane);
        if (html.length)
            loadContent(html);
    }

    /// Shows `html`, whose links and pictures are relative to `location`: a file's path, or a
    /// directory's ending in /. Without one they're relative to the working directory.
    final void loadContent(string html, string location = null)
    {
        show(html, location, null);
    }

    /*
        Shows the file at `location`, a path or a file: URL, scrolled to its #fragment if it has
        one. Throws if it can't be read, and goes on showing what it was.
    */
    final void load(string location)
    {
        import std.string : indexOf;

        const hash = location.indexOf('#');
        const fragment = hash >= 0 ? location[hash + 1 .. $] : null;
        const where = resolveLocation(location, null);
        const html = readText(where);
        show(html, where, fragment);
    }

    /// Shows what it's showing again, read afresh if it's a file.
    final void reload()
    {
        if (_location.length && !schemeOf(_location))
            load(_location);
        else
            show(_html, _location, null);
    }

    /// Scrolls to the element with the id `name`, or the <a> with the name, as a link to "#name" does.
    final void scrollToFragment(string name)
    {
        _fragment = name;
        requestUpdate();
    }

    /*
        Where the element with the id `id` is, from the view's top left, as the page is laid out
        and scrolled now: to put a popup beside something on the page, say. All NaN if there's no
        such element, or the page isn't laid out yet.
    */
    final Bounds boundsOf(string id)
    {
        lh_position where;
        if (!find(id, false, where))
            return Bounds(float.nan, float.nan, float.nan, float.nan);
        const view = _pane.viewportBounds();
        const pane = _pane.boundsIn(this);
        return Bounds(pane.minX + where.x - view.minX, pane.minY + where.y - view.minY, where.width, where.height);
    }

    /// What the page's <title> says, or null.
    mixin(declareReadOnlyProperty!(string, "title", "null", q{ invalidateAccessible(); }, "private"));

    /// Where the page came from: the file it's from, or what loadContent was given.
    mixin(declareReadOnlyProperty!(string, "location", "null", null, "private"));

    /// Its text's font, where the page doesn't give one: its family, and the size 1em is.
    mixin(declareStyleableProperty!(Font, "font", "font, font-family, font-size, font-weight, font-style",
                                    "null", q{ restyle(); }, true));

    /// Its text's colour, where the page doesn't give one.
    mixin(declareStyleableProperty!(Colour, "textFill", "colour", "Theme.text_colour", q{ restyle(); }));

    /// Its links' colour, where the page doesn't give one.
    mixin(declareStyleableProperty!(Colour, "linkColour", "link-colour", "Colour(2, 132, 199)", q{ restyle(); }));

    /// CSS for every page it shows, over its defaults and under the page's own. JavaFX's
    /// userStyleSheetLocation, but the CSS itself.
    mixin(declareProperty!(string, "userStyleSheet", "null", q{ restyle(); }));

    /// Hears about a link as it's clicked, before it's followed; consume the event not to follow it.
    final void setOnLinkClicked(LinkHandler handler) nothrow @nogc { _onLinkClicked = handler; }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    override void placeChild(Widget child) nothrow @nogc
    {
        child.place(1, false, false, YGAlignStretch);
    }

    override void unmounted()
    {
        // Its pictures are ThorVG's, and ThorVG may stop before it's back in a window: the page
        // is made again then
        dropDocument();
        _parse = true;
    }

    override void update()
    {
        if (!scene || !_content.page)
            return;
        if (_parse)
        {
            dropDocument();
            _doc = new HtmlDocument(_html, _location, _font ? _font : defaultFont(Theme.text_size), userCss());
            _parse = false;
            _relayout = true;
            _setTitle(_doc.title);
        }
        const view = _pane.viewportBounds();
        if (view.width <= 0)
            return; // not laid out yet: its content's laidOut asks again when it is
        if (_relayout || view.width != _laidOutWidth || view.height != _laidOutHeight)
        {
            _doc.layout(view.width, view.width, view.height);
            _laidOutWidth = view.width;
            _laidOutHeight = view.height;
            _relayout = false;
            _redraw = true;
            _content.sizeTo(_doc.width, _doc.height);
        }
        if (_redraw)
        {
            tvg_scene_remove(_content.page, null);
            const w = _doc.width > view.width ? _doc.width : view.width;
            const h = _doc.height > view.height ? _doc.height : view.height;
            _drawnScale = scene.pixelScale;
            _doc.draw(_content.page, _drawnScale, w, h);
            _redraw = false;
            _content.invalidate();
        }
        if (_fragment.length)
            revealFragment();
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        if (_title.length)
            node.label(_title);
    }

private:
    ScrollPane _pane;
    Content _content;
    HtmlDocument _doc;
    string _html;
    string _fragment;       // to scroll to once it's laid out
    LinkHandler _onLinkClicked;
    bool _parse = true;     // _html is new, or how it's styled: make the document again
    bool _relayout;         // lay it out again, as something changed how it looks
    bool _redraw;           // draw it again
    float _laidOutWidth = 0, _laidOutHeight = 0;
    float _drawnScale = 0;

    void show(string html, string location, string fragment)
    {
        _html = html;
        _setLocation(location);
        _fragment = fragment;
        _parse = true;
        _pane.setVvalue(0);
        _pane.setHvalue(0);
        requestUpdate();
    }

    void restyle() nothrow @nogc
    {
        _parse = true;
        requestUpdate();
    }

    void dropDocument() nothrow
    {
        if (_content.page)
            tvg_scene_remove(_content.page, null); // what it drew, before its pictures go
        if (_doc)
            _doc.dispose();
        _doc = null;
    }

    // The theme's colours, and the app's own CSS after them. litehtml's defaults colour links by
    // a:link, so these do too: as specific, and later, they win over it, and the page's own
    // rules, later again, win over them.
    string userCss()
    {
        import std.format : format;

        static string css(Colour c) { return format!"rgba(%d, %d, %d, %.3f)"(c.r, c.g, c.b, c.a / 255.0); }
        return format!"html { color: %s; }\na:link, a:visited { color: %s; }\n"(css(_textFill), css(_linkColour))
            ~ _userStyleSheet;
    }

    // Where the element with the id `id` is in the document, or with `orName`, the <a> named it
    bool find(string id, bool orName, out lh_position where)
    {
        import std.format : format;
        import std.string : replace;

        if (!_doc)
            return false;
        const quoted = id.replace(`\`, `\\`).replace(`"`, `\"`);
        return _doc.find(format!`[id="%s"]`(quoted), where)
            || (orName && _doc.find(format!`a[name="%s"]`(quoted), where));
    }

    // Scrolls to _fragment, once there's a layout to find it in
    void revealFragment()
    {
        lh_position where;
        const found = find(_fragment, true, where);
        // "#top" is the top of the page, as in a browser, unless something on it is called that
        if (!found && _fragment == "top")
            _pane.setVvalue(0);
        _fragment = null;
        if (!found)
            return;
        // From the document's size rather than the content's: a page just loaded isn't laid out yet
        const view = _pane.viewportBounds();
        const room = _doc.height - view.height;
        _pane.setVvalue(room > 0 ? (where.y < room ? where.y / room : 1) : 0);
    }

    // A link's been clicked: to the app first, then followed
    void follow(string url)
    {
        import sdl.misc : SDL_OpenURL;
        import std.string : indexOf, toStringz;

        const hash = url.indexOf('#');
        const fragment = hash >= 0 ? url[hash + 1 .. $] : null;
        auto event = LinkEvent(url, hash == 0 ? _location : _doc ? _doc.resolve(url) : url);
        if (_onLinkClicked)
            _onLinkClicked(event);
        if (event.consumed)
            return;
        // Where this page is, less any fragment: the same page, only scrolled
        if (hash == 0 || (event.location == _location && fragment.length))
        {
            scrollToFragment(fragment);
            return;
        }
        if (schemeOf(event.location) && schemeOf(event.location) != "data")
        {
            SDL_OpenURL(url.toStringz);
            return;
        }
        try
        {
            show(readText(event.location), event.location, fragment);
        }
        catch (Exception)
        {
            // A link to nothing that can be read goes nowhere, as a missing file does in a browser
        }
    }

    // The page itself, scrolled: as big as the document, and drawing it
    final static class Content : Widget
    {
        LiteWebView view;
        Tvg_Paint holder, page;
        float docWidth = 0, docHeight = 0;

        this(LiteWebView view)
        {
            this.view = view;
            styleClass.add("content");
            setAccessibleHidden(true);
            YGNodeSetContext(node, cast(void*) this);
            YGNodeSetMeasureFunc(node, &measurePage);
        }

        // As big as the document, which is at least as wide and tall as the view: see the pane's fits
        void sizeTo(float w, float h) nothrow @nogc
        {
            docWidth = w;
            docHeight = h;
            YGNodeStyleSetMinWidth(node, w);
            YGNodeStyleSetMinHeight(node, h);
            YGNodeMarkDirty(node);
            invalidate();
        }

        float height() nothrow @nogc { return YGNodeLayoutGetHeight(node); }

    protected:
        override bool takesChildren() const nothrow @nogc { return false; }

        override void mounted() nothrow
        {
            // The page is drawn in a scene of its own, which paint() puts where the content is:
            // the holder has the widget's opacity and scale, and the page inside it the place
            holder = addPaint(tvg_scene_new());
            page = tvg_scene_new();
            tvg_scene_add(holder, page);
            view._redraw = true;
            view.requestUpdate();
        }

        override void unmounted()
        {
            holder = page = null; // gone with the holder
        }

        override void laidOut(float x, float y, float w, float h) nothrow @nogc
        {
            const v = view._pane.viewportBounds();
            if (v.width != view._laidOutWidth || v.height != view._laidOutHeight)
                view.requestUpdate();
            if (scene && scene.pixelScale != view._drawnScale)
            {
                view._redraw = true; // its text is rendered for the pixels of the display it's on
                view.requestUpdate();
            }
        }

        override void paint(float x, float y, float w, float h) nothrow @nogc
        {
            if (page)
            {
                auto m = Tvg_Matrix(1, 0, x, 0, 1, y, 0, 0, 1);
                tvg_paint_set_transform(page, &m);
            }
        }

        override void handleMouse(ref MouseEvent event)
        {
            auto doc = view._doc;
            if (!doc)
                return;
            bool changed;
            final switch (event.type)
            {
            case MouseEventType.moved, MouseEventType.dragged:
                changed = doc.mouseMoved(event.x, event.y);
                break;
            case MouseEventType.pressed:
                if (event.button == MouseButton.primary)
                    changed = doc.mousePressed(event.x, event.y);
                break;
            case MouseEventType.released:
                if (event.button == MouseButton.primary)
                    changed = doc.mouseReleased(event.x, event.y);
                break;
            case MouseEventType.exited:
                changed = doc.mouseLeft();
                break;
            case MouseEventType.clicked, MouseEventType.entered:
                break;
            }
            setCursor(doc.cursor == "pointer" ? Cursor.hand : Cursor.inherit);
            if (changed)
            {
                view._relayout = true;
                view.requestUpdate();
            }
            // Followed only now: litehtml has finished with the click, and the page it's in
            if (auto link = doc.takeClickedLink())
                view.follow(link);
        }
    }
}

/// A link in a LiteWebView, clicked.
struct LinkEvent
{
    string url;       /// As the page has it: "other.html#part", "#part", "https://..."
    string location;  /// Where it leads: the file's path, or the URL itself if it's not a file
    bool consumed;

    /// Stops the view following it.
    void consume() nothrow @nogc { consumed = true; }
}

/// What a LiteWebView calls when a link's clicked.
alias LinkHandler = void delegate(ref LinkEvent event);

/// Yoga measuring the page: as big as the document, as last laid out.
private extern(C) YGSize measurePage(YGNodeConstRef node, float width, YGMeasureMode widthMode,
                                        float height, YGMeasureMode heightMode) nothrow @nogc
{
    auto self = cast(LiteWebView.Content) YGNodeGetContext(node);
    if (!self)
        return YGSize(0, 0);
    return YGSize(self.docWidth, self.docHeight);
}
