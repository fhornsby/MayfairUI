module mayfair.widgets.tabpane;

import mayfair.accessibility;
import mayfair.images;
import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.button;
import mayfair.widgets.buttonbase;
import mayfair.widgets.icon;
import mayfair.widgets.input;
import mayfair.widgets.layouts;
import mayfair.widgets.scrollpane;
import mayfair.widgets.styling;
import mayfair.widgets.widget;

/*
    One page at a time, with a row of tabs to choose between them. JavaFX's TabPane.

        auto tabs = new TabPane();
        tabs.add(new Tab("General", generalPage));
        tabs.add(new Tab("Advanced", advancedPage));
        tabs.add(new Tab("notes.txt", editor).graphic(new Icon("text-x-generic-symbolic")).closable(true));

    Clicking a tab shows its page. From the keyboard, the tabs are one stop for Tab, at the
    selected one, and Left and Right move along them; Ctrl+Page Down and Ctrl+Page Up go to the
    next and previous from anywhere in the pane, as they do in GNOME's apps. A closable tab has a
    close button, and Ctrl+W on it closes it too; closing the selected tab selects its
    neighbour. More tabs than fit scroll sideways, and the selected one's kept in view.

    Only the selected tab's page is in the tree, so what's on the others isn't drawn, laid out, or
    reached by Tab or a screen reader, and keeps whatever state it had for when it's shown again.

    Its style class is "tab-pane". Inside it, the tabs are in a `.tab-header-area`, each a `.tab`
    -- :selected for the one shown -- with a `.tab-close-button` if it closes, and the page is in
    a `.tab-content-area`. To a screen reader the tabs are a tab list, and the page a tab panel.
*/
class TabPane : Widget
{
public:
    this()
    {
        styleClass.add("tab-pane");
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionColumn);

        _strip = new Row().alignment(Pos.bottomLeft).fillHeight(false);
        _strip.setAccessibleRole(AccessibleRole.tabList);
        // Scrolling sideways when there are more tabs than fit, as tall as the tabs
        _headerArea = new ScrollPane(_strip).fitToHeight(true);
        _headerArea.setVbarPolicy(ScrollBarPolicy.never);
        _headerArea.styleClass.add("tab-header-area");
        _headerArea.setAccessibleHidden(true);
        adopt(_headerArea);

        _body = new Stack();
        _body.styleClass.add("tab-content-area");
        _body.setAccessibleRole(AccessibleRole.tabPanel);
        _body.setGrow(1);
        adopt(_body);
    }

    /// Adds `tab` at the end. The first tab added is selected. Returns this, so calls chain.
    final TabPane add(Tab tab)
    {
        return insert(_tabs.length, tab);
    }

    /// Adds `tab` at `index`, before the tab that's there now.
    final TabPane insert(size_t index, Tab tab)
    {
        if (tab._pane)
            tab._pane.remove(tab);
        if (index > _tabs.length)
            index = _tabs.length;
        tab._pane = this;
        tab._header = new TabHeader(this, tab);
        _tabs = _tabs[0 .. index] ~ tab ~ _tabs[index .. $];
        _strip.add(tab._header);
        // In the strip in the same order as the tabs
        if (index + 1 < _tabs.length)
        {
            _strip.remove(tab._header);
            foreach (t; _tabs[index + 1 .. $])
                _strip.remove(t._header);
            foreach (t; _tabs[index .. $])
                _strip.add(t._header);
        }
        if (_selectedIndex < 0)
            setSelectedIndex(0);
        else if (index <= _selectedIndex)
            setSelectedIndex(_selectedIndex + 1); // the same tab, one further along
        return this;
    }

    /// Takes `tab` out. If it was selected, the one after it is, or failing that the one before.
    final TabPane remove(Tab tab)
    {
        foreach (i, t; _tabs)
        {
            if (t !is tab)
                continue;
            const wasSelected = cast(int) i == _selectedIndex;
            _strip.remove(tab._header);
            _tabs = _tabs[0 .. i] ~ _tabs[i + 1 .. $];
            tab._pane = null;
            tab._header = null;
            if (wasSelected)
            {
                _selectedIndex = -1; // so the new selection is a change, and shown
                showSelected(null);
                setSelectedIndex(_tabs.length == 0 ? -1 : cast(int)(i < _tabs.length ? i : _tabs.length - 1));
            }
            else if (cast(int) i < _selectedIndex)
                setSelectedIndex(_selectedIndex - 1);
            break;
        }
        return this;
    }

    alias remove = Widget.remove; // its own parts, as ever

    /// The tabs, in order.
    final const(Tab)[] tabs() const nothrow @nogc { return _tabs; }

    /// Which tab is shown, from 0; -1 when there are none.
    mixin(declareProperty!(int, "selectedIndex", "-1", q{ selectionChanged(); }));

    /// The tab shown, or null.
    final Tab selectedTab() nothrow @nogc
    {
        return _selectedIndex >= 0 && _selectedIndex < _tabs.length ? _tabs[_selectedIndex] : null;
    }

    /// Shows `tab`, which must be one of this pane's.
    final void select(Tab tab)
    {
        foreach (i, t; _tabs)
            if (t is tab)
                setSelectedIndex(cast(int) i);
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; } // pages go in as tabs

    override void handleKey(ref KeyEvent event)
    {
        if (event.type != KeyEventType.pressed || !event.control || _tabs.length == 0)
            return;
        const n = cast(int) _tabs.length;
        if (event.code == KeyCode.pageDown)
            setSelectedIndex((_selectedIndex + 1) % n);
        else if (event.code == KeyCode.pageUp)
            setSelectedIndex((_selectedIndex + n - 1) % n);
        else
            return;
        event.consume();
    }

private:
    Tab[] _tabs;
    Row _strip;
    ScrollPane _headerArea;
    Stack _body;
    Widget _shown; // the page in the body

    void selectionChanged()
    {
        if (_selectedIndex >= cast(int) _tabs.length)
        {
            setSelectedIndex(cast(int) _tabs.length - 1);
            return;
        }
        auto tab = selectedTab;
        foreach (t; _tabs)
            t._header.showSelected(t is tab);
        showSelected(tab ? tab._content : null);
        if (tab)
        {
            tab._header.scrollIntoView();
            if (tab._onSelected)
                tab._onSelected();
        }
    }

    void showSelected(Widget content)
    {
        if (_shown is content)
            return;
        // Focus in the page going away goes to its tab, rather than nowhere
        const focusWasInPage = _shown && scene && isInside(_shown);
        if (_shown)
            _body.remove(_shown);
        _shown = content;
        if (content)
            _body.add(content);
        if (focusWasInPage && selectedTab)
            selectedTab._header.requestFocus();
    }

    bool isInside(Widget w) nothrow @nogc
    {
        for (Widget f = scene ? scene.focusedWidget : null; f; f = f.parent)
            if (f is w)
                return true;
        return false;
    }

    /// Moves along the tabs from the one at `from` by `by`, as the arrow keys do, and focuses it.
    void step(TabHeader from, int by)
    {
        foreach (i, t; _tabs)
        {
            if (t._header !is from)
                continue;
            const n = cast(int) _tabs.length;
            const to = (cast(int) i + by + n) % n;
            setSelectedIndex(to);
            _tabs[to]._header.focusFromKeyboard();
            return;
        }
    }

    void close(Tab tab)
    {
        remove(tab);
        if (tab._onClosed)
            tab._onClosed();
    }
}

/*
    One of a TabPane's pages, and its tab: what the tab says, and what it shows. JavaFX's Tab.
    Not a widget itself -- the pane makes the tab's header, and shows the content when it's
    selected.
*/
@DefaultProperty("content")
final class Tab
{
public:
    this(string text, Widget content = null)
    {
        _text = text;
        _content = content;
    }

    /// What the tab says.
    mixin(declareProperty!(string, "text", "null", q{ if (_header) _header.setText(_text); }));

    /// A picture before the text: an Icon, usually.
    mixin(declareProperty!(Widget, "graphic", "null", q{ if (_header) _header.setGraphic(_graphic); }));

    /// What it shows when it's selected.
    mixin(declareProperty!(Widget, "content", "null", q{
        if (_pane && _pane.selectedTab is this)
            _pane.showSelected(_content);
    }));

    /// Whether it has a close button, to take it out of its pane.
    mixin(declareProperty!(bool, "closable", "false", q{ if (_header) _header.showCloseButton(_closable); }));

    /// The pane it's in, if any.
    TabPane tabPane() nothrow @nogc { return _pane; }

    /// Whether it's the one its pane shows.
    bool selected() nothrow @nogc { return _pane && _pane.selectedTab is this; }

    /// What to do when it's selected.
    Tab onSelected(void delegate() handler) nothrow @nogc { _onSelected = handler; return this; }

    /// What to do after it's been closed, by its close button or Ctrl+W.
    Tab onClosed(void delegate() handler) nothrow @nogc { _onClosed = handler; return this; }

private:
    TabPane _pane;
    TabHeader _header;
    void delegate() _onSelected, _onClosed;
}

/// A tab in a TabPane's strip: what's clicked on to show its page.
final class TabHeader : ButtonBase
{
public:
    this(TabPane pane, Tab tab)
    {
        super(tab.text);
        _pane = pane;
        _tab = tab;
        styleClass.add("tab");
        setAccessibleRole(AccessibleRole.tab);
        setAlignment(Pos.centre);
        if (tab.graphic)
            setGraphic(tab.graphic);
        showCloseButton(tab.closable);
    }

    /// Whether it's the one shown: the one Tab stops at, and the stylesheet's :selected.
    bool isSelected() const nothrow @nogc { return _selected; }

    override void fire()
    {
        _pane.select(_tab);
        super.fire();
    }

protected:
    override bool isTabStop() { return _selected; }

    override void handleKey(ref KeyEvent event)
    {
        if (event.type == KeyEventType.pressed && !event.control && !event.alt)
        {
            if (event.code == KeyCode.left || event.code == KeyCode.right)
            {
                _pane.step(this, event.code == KeyCode.right ? 1 : -1);
                event.consume();
                return;
            }
        }
        if (event.type == KeyEventType.pressed && event.control && event.code == KeyCode.w && _tab.closable)
        {
            _pane.close(_tab);
            event.consume();
            return;
        }
        super.handleKey(event);
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        super.describeAccessible(node);
        node.selected(_selected);
    }

private:
    TabPane _pane;
    Tab _tab;
    Button _close;
    bool _selected;

    void focusFromKeyboard() { requestFocusFromKeyboard(); }

    void showSelected(bool on)
    {
        _selected = on;
        pseudoClassStateChanged(pseudo!"selected", on);
        invalidateAccessible();
    }

    void showCloseButton(bool on)
    {
        if (on && !_close)
        {
            _close = new Button().graphic(new Icon("window-close-symbolic").iconSize(12));
            _close.styleClass.remove("button");
            _close.styleClass.add("tab-close-button");
            _close.setAccessibleText("Close " ~ _tab.text);
            _close.setFocusTraversable(false); // Ctrl+W closes from the keyboard
            _close.setOnAction({ _pane.close(_tab); });
            adopt(_close);
        }
        else if (!on && _close)
        {
            remove(_close);
            _close = null;
        }
    }
}
