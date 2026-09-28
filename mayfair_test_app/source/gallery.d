module gallery;

import std.format : format;
import mayfair;

/*
    Mayfair's gallery: every widget the kit has, on a page of its own, as other kits' demo apps
    show theirs. The pages are down the left; the switch at the top right goes between light and
    dark, and what's been clicked or changed is reported along the bottom.

    It's built here, apart from the app that shows it, so the end-to-end tests can drive it too.
*/

/// The gallery, starting on the page called `start`, or the first.
Dock buildGallery(string start = null)
{
    auto status = new Label("Ready").padding(Insets(6, 12));
    void report(string what) { status.setText(what); }

    // The pages, in the order the sidebar lists them
    struct Page { string name, icon; Widget content; }
    Page[] pages = [
        Page("Buttons", "input-mouse-symbolic", buttonsPage(&report)),
        Page("Toggles", "object-select-symbolic", togglesPage(&report)),
        Page("Text", "format-text-bold-symbolic", textPage(&report)),
        Page("Sliders & progress", "media-playlist-shuffle-symbolic", rangePage(&report)),
        Page("Images & icons", "image-x-generic-symbolic", imagesPage()),
        Page("Animation", "media-playback-start-symbolic", animationPage(&report)),
        Page("Layout", "view-grid-symbolic", layoutPage(&report)),
        Page("Tabs", "view-paged-symbolic", tabsPage(&report)),
        Page("Popups", "view-more-symbolic", popupsPage(&report)),
        Page("Lists & tables", "view-list-symbolic", listsPage(&report)),
        Page("Styling", "applications-graphics-symbolic", stylingPage(&report)),
        Page("Properties", "emblem-system-symbolic", propertiesPage()),
    ];

    // Each page scrolls on its own, down only: fitToWidth keeps it the width of the window
    auto dock = new Dock();
    auto sidebar = new NavigationList();
    sidebar.style("background-colour: var(--field);");
    ScrollPane[] panes;
    foreach (page; pages)
    {
        sidebar.add(page.name, page.icon);
        panes ~= new ScrollPane(page.content).fitToWidth(true);
        if (page.name == start)
            sidebar.setSelectedIndex(cast(int) panes.length - 1);
    }
    dock.setCentre(panes[sidebar.selectedIndex]);
    sidebar.selectedIndexProperty.addListener((int was, int now) { dock.setCentre(panes[now]); });

    // The page, the sidebar and the status bar; the title bar is the window's (see buildTitleBar)
    dock.left(new ScrollPane(sidebar).fitToWidth(true)).bottom(status);
    return dock;
}


alias Report = void delegate(string);

/*
    The gallery's title bar: its name, and the switch between light and dark at the end. Given
    to the scene, it makes the window draw its own decorations, wherever it is.
*/
TitleBar buildTitleBar(Dock gallery)
{
    auto dark = new ToggleButton("Dark").graphic(new Icon("weather-clear-night-symbolic"))
        .tooltip("Switch between light and dark");
    dark.setOnAction({
        gallery.scene.setColourScheme(dark.selected ? ColourScheme.dark : ColourScheme.light);
    });
    return new TitleBar("Mayfair gallery")
        .addStart(new Icon(Image.fromData(import("tick-symbolic.svg"), "mayfair.svg")).iconSize(20))
        .addEnd(dark);
}

/*
    Actions made in a loop are made here, a call each. A delegate made in a loop's body shares
    that body's variables with every other made there, so they'd all see the last iteration's --
    every key reporting the last key. Made in a function of its own, each has its own.
*/
void delegate() reportKey(Report report, string key)
{
    return { report("Key " ~ key); };
}

// A page: a heading, a line on what it shows, and its sections
Column page(string title, string about)
{
    auto c = new Column().spacing(20).padding(24);
    c.add(new Label(title).style("font-size: 24px; font-weight: bold;"));
    c.add(new Label(about).wrapText(true));
    return c;
}

// A section of a page: a smaller heading over what it shows
Column section(string title, Widget content)
{
    auto c = new Column().spacing(10);
    c.add(new Label(title).style("font-size: 15px; font-weight: bold;"));
    c.add(content);
    return c;
}

Row row(Widget[] items...)
{
    auto r = new Row().spacing(12).alignment(Pos.centreLeft).fillHeight(false);
    foreach (item; items)
        r.add(item);
    return r;
}

Widget buttonsPage(Report report)
{
    auto clicks = new Property!int(0);
    auto counter = new Label("Not clicked yet");
    clicks.addListener((int was, int now) { counter.setText(format!"Clicked %d times"(now)); });

    return page("Buttons", "Push buttons run an action when clicked. Enter presses the default button "
                ~ "wherever focus is, and Escape the cancel button.")
        .add(section("Kinds", row(
            new Button("Default").defaultButton(true).onAction({ clicks.set(clicks.get + 1); report("Default pressed"); }),
            new Button("Plain").onAction({ clicks.set(clicks.get + 1); report("Plain pressed"); }),
            new Button("Cancel").cancelButton(true).onAction({ clicks.set(0); report("Cancelled: count reset"); }),
            new Button("Disabled").disable(true),
            counter)))
        .add(section("With icons", row(
            new Button("Save").graphic(new Icon("document-save-symbolic")).onAction({ report("Save"); }),
            new Button("Copy").graphic(new Icon("edit-copy-symbolic")).onAction({ report("Copy"); }),
            new Button("Delete").graphic(new Icon("user-trash-symbolic")).disable(true),
            new Button().graphic(new Icon("edit-find-symbolic")).accessibleText("Search").tooltip("Search")
                .onAction({ report("Search"); }),
            new Button().graphic(new Icon("open-menu-symbolic")).accessibleText("Menu").tooltip("Menu")
                .onAction({ report("Menu"); }))))
        .add(section("Toggle buttons", row(
            new ToggleButton("Bold").graphic(new Icon("format-text-bold-symbolic"))
                .onAction({ report("Bold toggled"); }),
            new ToggleButton("Italic").graphic(new Icon("format-text-italic-symbolic"))
                .onAction({ report("Italic toggled"); }),
            new ToggleButton("Underline").graphic(new Icon("format-text-underline-symbolic"))
                .onAction({ report("Underline toggled"); }))));
}

Widget togglesPage(Report report)
{
    auto size = new ToggleGroup;
    auto small = new RadioButton("Small").toggleGroup(size);
    auto medium = new RadioButton("Medium").toggleGroup(size).selected(true);
    auto large = new RadioButton("Large").toggleGroup(size);
    size.selectedToggleProperty.addListener((ToggleButton was, ToggleButton now) {
        report("Size: " ~ (now ? now.text : "none"));
    });

    return page("Toggles", "Check boxes are on or off, or neither: a check box that allows it cycles through "
                ~ "indeterminate too. Radio buttons in a group allow one choice, and the arrow keys move between them.")
        .add(section("Check boxes", new Column().spacing(8)
            .add(new CheckBox("Wrap lines").selected(true).onAction({ report("Wrap lines toggled"); }))
            .add(new CheckBox("Some of these").allowIndeterminate(true).indeterminate(true)
                .onAction({ report("Some of these toggled"); }))
            .add(new CheckBox("Can't change this").selected(true).disable(true))))
        .add(section("Radio buttons", new Column().spacing(8).add(small).add(medium).add(large)));
}

Widget textPage(Report report)
{
    auto name = new TextField().promptText("Your name").prefWidth(220);
    auto greet = new Button("Greet");
    auto greeting = new Label("");
    // Disabled for as long as the field's empty: one binding, no handlers
    greet.disableProperty.bind(name.textProperty.isEmpty);
    void sayHello() { greeting.setText("Hello, " ~ name.text); report("Greeted " ~ name.text); }
    greet.setOnAction(&sayHello);
    name.setOnAction(&sayHello);

    // An installed family by name. One that isn't installed falls back to the default font.
    auto serif = font("DejaVu Serif", 18);

    return page("Text", "Labels shape their text with HarfBuzz, so ligatures, kerning, right-to-left and "
                ~ "characters from fallback fonts all just work. Text fields and areas edit it, with "
                ~ "undo, selection, the clipboard and input methods.")
        .add(section("Labels", new Column().spacing(8)
            .add(new Label("The default font, at the theme's text size"))
            .add(new Label("A serif, by family name: Affinity fjord VAV").font(serif))
            .add(new Label("Ligatures: fi fl ffi · Fallback: 漢字 ∑ ➜ · Mixed: שלום world"))
            .add(new Label("Labels wrap when they're told to, breaking where the text allows: after spaces, "
                ~ "around CJK like 漢字漢字漢字, at hyphens. Mixed text wraps in its own order too, so שלום עולם, "
                ~ "זהו טקסט in the middle of a sentence stays where it belongs. Narrow the window to see it.")
                .wrapText(true))
            .add(new Label("Centred, and wrapped: a line of text laid out in the middle of the width it's given.")
                .wrapText(true).textAlignment(TextAlignment.centre).maxWidth(float.infinity))))
        .add(section("Text field", new Column().spacing(8)
            .add(row(new Label("Name"), name, greet))
            .add(greeting)))
        .add(section("Text area", new TextArea("A text area holds several lines. This one wraps them to its "
            ~ "width, and scrolls when there are more than fit.\n\nEnter starts a new paragraph; Tab types a "
            ~ "tab, and Ctrl+Tab moves on.").wrapText(true).prefRowCount(5)));
}

Widget rangePage(Report report)
{
    auto amount = new Slider(0, 100, 40).prefWidth(280);
    auto progress = new ProgressBar(0.4).prefWidth(280);
    auto value = new Label("40");
    amount.valueProperty.addListener((double was, double now) {
        progress.setProgress(now / 100);
        value.setText(format!"%.0f"(now));
    });
    auto volume = new Slider(0, 10, 7).orientation(Orientation.vertical).prefHeight(140);
    auto snapping = new Slider(0, 100, 50).snapToTicks(true).prefWidth(280);
    snapping.valueProperty.addListener((double was, double now) { report(format!"Snapped to %s"(now)); });

    return page("Sliders & progress", "A slider picks a value by dragging, clicking the track, or the arrow, "
                ~ "Page and Home and End keys. A progress bar shows how far something has got, or slides to and "
                ~ "fro while it doesn't know.")
        .add(section("A slider driving a progress bar", new Column().spacing(12)
            .add(row(amount, value))
            .add(row(progress))))
        .add(section("Snapping to ticks, and vertical", row(snapping, volume)))
        .add(section("Indeterminate", row(new ProgressBar().prefWidth(280))));
}

Widget imagesPage()
{
    auto hills = Image.fromData(import("hills.svg"), "hills.svg");
    auto pixels = Image.fromData(import("pixels.png"), "pixels.png");
    auto tick = Image.fromData(import("tick-symbolic.svg"), "tick-symbolic.svg");

    return page("Images & icons", "An ImageView shows a PNG, JPEG, WebP or SVG. SVGs are drawn as vectors, "
                ~ "so they're sharp at any size. Icons come from the desktop's icon theme by name, and symbolic "
                ~ "ones are drawn in the colour of the text around them.")
        .add(section("SVG, at its own size and fitted", row(
            new ImageView(hills),
            new ImageView(hills).fitWidth(120).preserveRatio(true),
            new ImageView(hills).fitWidth(60).preserveRatio(true))))
        .add(section("PNG, smoothed and not", row(
            new ImageView(pixels).fitWidth(144).preserveRatio(true),
            new ImageView(pixels).fitWidth(144).preserveRatio(true).smooth(false))))
        .add(section("Icons from the theme", row(
            new Icon("folder").iconSize(48),
            new Icon("user-home").iconSize(48),
            new Icon("user-trash-symbolic").iconSize(32),
            new Icon("dialog-warning-symbolic").iconSize(32),
            new Icon("emblem-favorite-symbolic").iconSize(32))))
        .add(section("An app's own icon, recoloured", row(
            new Icon(tick).iconSize(32),
            new Icon(tick).iconSize(32).style("icon-colour: var(--accent);"),
            new Icon(tick).iconSize(32).style("icon-colour: #16a34a;"),
            new Icon(tick).iconSize(32).style("icon-colour: #dc2626;"))));
}

Widget animationPage(Report report)
{
    // The spinner's ring is a colour slot, which the stylesheet sets to the accent, light or dark
    auto spinner = new LottieView(Image.fromData(import("spinner.json"), "spinner.json"))
        .fitWidth(96).preserveRatio(true).style("--lottie-ring: var(--accent);");
    auto plain = new LottieView(Image.fromData(import("spinner.json"), "spinner.json"))
        .fitWidth(96).preserveRatio(true);

    auto pause = new ToggleButton("Pause").graphic(new Icon("media-playback-pause-symbolic"));
    pause.setOnAction({
        if (pause.selected)
            spinner.animation.pause();
        else
            spinner.animation.play();
        report(pause.selected ? "Paused" : "Playing");
    });
    auto reverse = new Button("Reverse").graphic(new Icon("media-seek-backward-symbolic"));
    reverse.setOnAction({
        spinner.animation.rate(-spinner.animation.rate);
        report(spinner.animation.rate < 0 ? "Backwards" : "Forwards");
    });
    auto speed = new Slider(0.25, 3, 1).prefWidth(200);
    speed.valueProperty.addListener((double was, double now) {
        const sign = spinner.animation.rate < 0 ? -1 : 1;
        spinner.animation.rate(sign * now);
    });

    auto hover = new Button("Hover over me");
    hover.style("transition: background-colour 400ms ease-in-out, scale-x 400ms, scale-y 400ms;");

    return page("Animation", "A LottieView plays a Lottie animation, drawn as vectors. Its playback is an "
                ~ "Animation like any other, so it pauses, reverses and changes speed; and a colour the file "
                ~ "makes a slot can come from the stylesheet. CSS transitions animate style changes.")
        .add(section("Lottie: the ring from the stylesheet, and as the file has it", row(spinner, plain)))
        .add(section("Controlling it", row(pause, reverse, new Label("Speed"), speed)))
        .add(section("A CSS transition", row(hover)));
}

Widget layoutPage(Report report)
{
    // Stack: a badge over an icon
    auto badge = new Label("3").style("background-colour: #dc2626; background-radius: 9; padding: 1 6; "
                                      ~ "colour: white; font-size: 11px;");
    auto inbox = new Stack().alignment(Pos.topRight)
        .add(new Icon("mail-unread-symbolic").iconSize(32).margin(Insets(6)))
        .add(badge);
    auto loading = new Stack()
        .add(new Widget().prefSize(200, 80).style("background-colour: var(--field); background-radius: 8;"))
        .add(new Label("Behind a spinner"))
        .add(new ProgressBar().prefWidth(120).maxWidth(Widget.usePrefSize).opacity(0.6).margin(Insets(50, 0, 0, 0)));

    // Dock: the shape of a window, in miniature
    Widget part(string name, string colour)
    {
        auto l = new Label(name).padding(6);
        l.style("background-colour: " ~ colour ~ "; background-radius: 4; colour: #0f172a;");
        return new Stack().add(new Widget().style("background-colour: " ~ colour ~ "; background-radius: 4;")).add(l);
    }
    auto window = new Dock().spacing(4).prefSize(360, 200)
        .top(part("Top", "#bae6fd")).bottom(part("Bottom", "#bae6fd"))
        .left(part("Left", "#fde68a")).right(part("Right", "#fde68a"))
        .centre(part("Centre", "#bbf7d0"));

    // Grid: a form
    auto form = new Grid().columnGap(12).rowGap(10).maxWidth(520);
    form.addRow(0, new Label("Name"), new TextField().promptText("Your name"));
    form.addRow(1, new Label("Email address"), new TextField().promptText("you@example.com"));
    form.addRow(2, new Label("Bio"), new TextArea().prefRowCount(3).wrapText(true));
    form.add(new CheckBox("Send me the newsletter"), 1, 3);
    form.add(new Label("The labels' column is as wide as the widest label; the fields' takes the rest. "
                       ~ "This note spans both, and wraps to them.").wrapText(true), 0, 4, 2);
    form.add(new Button("Save").defaultButton(true).onAction({ report("Saved"); }), 1, 5);
    form.column(1).grow(1);
    form.row(2).alignment(Alignment.start);

    // Grid: a keypad, every key filling its cell
    auto keypad = new Grid().columnGap(6).rowGap(6);
    Button key(string name)
    {
        return new Button(name).maxWidth(float.infinity).onAction(reportKey(report, name));
    }
    foreach (i, name; ["7", "8", "9", "4", "5", "6", "1", "2", "3"])
        keypad.add(key(name), cast(int)(i % 3), cast(int)(i / 3));
    keypad.add(key("0"), 0, 3, 2);
    keypad.add(key("."), 2, 3);
    foreach (c; 0 .. 3)
        keypad.column(c).prefSize(48);

    // Row and Column
    auto rows = new Column().spacing(6)
        .add(row(new Button("One"), new Button("Two"), new Button("Three")))
        .add(new Row().spacing(6).add(new Button("Grows").grow(1).maxWidth(float.infinity)).add(new Button("Fixed")));

    return page("Layout", "Row and Column lay their children out along a line, with flexbox underneath. Stack "
                ~ "puts them one on another, Dock round the edges, and Grid in rows and columns that line up.")
        .add(section("Row and Column", rows))
        .add(section("Stack: a badge on an icon, and a spinner over content", row(inbox, loading)))
        .add(section("Dock", window))
        .add(section("Grid: a form", form))
        .add(section("Grid: spans", keypad));
}

Widget tabsPage(Report report)
{
    // A document per tab, each closable, and a button that opens another
    auto documents = new TabPane().prefHeight(220);
    int opened;
    Tab document(string name)
    {
        auto editor = new TextArea("This is " ~ name ~ ". Each tab keeps its own text while another is shown.")
            .wrapText(true);
        editor.margin(Insets(12));
        return new Tab(name, editor).graphic(new Icon("text-x-generic-symbolic")).closable(true)
            .onClosed(reportClosed(report, name));
    }
    documents.add(document("notes.txt")).add(document("todo.txt")).add(document("ideas.txt"));
    auto open = new Button("New tab").graphic(new Icon("tab-new-symbolic")).onAction({
        opened++;
        auto tab = document(format!"untitled %d.txt"(opened));
        documents.add(tab);
        documents.select(tab);
        report("Opened " ~ tab.text);
    });

    // Settings-style tabs: fixed pages, with icons
    auto settings = new TabPane().prefHeight(160);
    settings.add(new Tab("General", new Label("General settings would go here.").padding(16))
                     .graphic(new Icon("preferences-system-symbolic")))
        .add(new Tab("Appearance", new Row().spacing(12).padding(16)
                     .add(new CheckBox("Dark style")).add(new CheckBox("Large text")))
                     .graphic(new Icon("applications-graphics-symbolic")))
        .add(new Tab("About", new Label("Mayfair, a UI kit in D.").padding(16))
                     .graphic(new Icon("help-about-symbolic")));

    return page("Tabs", "A tab pane shows one page at a time, with a tab for each. Click a tab, or from the "
                ~ "keyboard use Left and Right on the tabs, or Ctrl+Page Up and Ctrl+Page Down from anywhere "
                ~ "in the pane. A closable tab closes with its button or Ctrl+W.")
        .add(section("Documents", new Column().spacing(8).add(row(open)).add(documents)))
        .add(section("Settings", settings));
}

void delegate() reportClosed(Report report, string name)
{
    return { report("Closed " ~ name); };
}

Widget popupsPage(Report report)
{
    // A menu from a button, as GNOME's main menus are
    auto wrap = new CheckMenuItem("Word wrap", { report("Word wrap toggled"); }).selected(true);
    auto appMenu = new ContextMenu()
        .add(new MenuItem("New window", { report("New window"); }).accelerator("Ctrl+N"))
        .add(new MenuItem("Open…", { report("Open"); }).accelerator("Ctrl+O").graphic(new Icon("document-open-symbolic")))
        .add(new MenuItem("Save", { report("Save"); }).accelerator("Ctrl+S").graphic(new Icon("document-save-symbolic")))
        .add(new MenuSeparator())
        .add(wrap)
        .add(new MenuItem("Print", { report("Print"); }).disable(true))
        .add(new MenuSeparator())
        .add(new MenuItem("About Mayfair", { report("About"); }));
    auto menuButton = new MenuButton().graphic(new Icon("open-menu-symbolic")).menu(appMenu)
        .accessibleText("Main menu").tooltip("Main menu");
    auto menuWithText = new MenuButton("File").menu(appMenu);

    // A menu bar, with submenus; its accelerators work on this page, menus open or not
    auto menuBar = new MenuBar()
        .add(new Menu("File")
            .add(new MenuItem("New", { report("New"); }).accelerator("Ctrl+N"))
            .add(new MenuItem("Open…", { report("Open"); }).accelerator("Ctrl+O").graphic(new Icon("document-open-symbolic")))
            .add(new Menu("Open recent")
                .add(new MenuItem("notes.txt", { report("Open notes.txt"); }))
                .add(new MenuItem("todo.txt", { report("Open todo.txt"); }))
                .add(new Menu("Older")
                    .add(new MenuItem("letter.txt", { report("Open letter.txt"); }))))
            .add(new MenuItem("Save", { report("Save"); }).accelerator("Ctrl+S").graphic(new Icon("document-save-symbolic")))
            .add(new MenuSeparator())
            .add(new MenuItem("Quit", { report("Quit (not really)"); }).accelerator("Ctrl+Q")))
        .add(new Menu("Edit")
            .add(new MenuItem("Undo", { report("Undo"); }).accelerator("Ctrl+Z"))
            .add(new MenuItem("Redo", { report("Redo"); }).accelerator("Ctrl+Shift+Z").disable(true))
            .add(new MenuSeparator())
            .add(new MenuItem("Find…", { report("Find"); }).accelerator("Ctrl+F")))
        .add(new Menu("View")
            .add(new CheckMenuItem("Show sidebar", { report("Sidebar toggled"); }).selected(true).accelerator("F9"))
            .add(new Menu("Zoom")
                .add(new MenuItem("Zoom in", { report("Zoom in"); }).accelerator("Ctrl+="))
                .add(new MenuItem("Zoom out", { report("Zoom out"); }).accelerator("Ctrl+-"))
                .add(new MenuItem("Actual size", { report("Actual size"); }).accelerator("Ctrl+0"))));
    menuBar.style("background-colour: var(--field-border), var(--field); background-insets: 0, 1; background-radius: 8, 7;");

    // A right click anywhere in the box
    auto area = new Stack().prefSize(320, 100);
    area.style("background-colour: var(--field-border), var(--field); background-insets: 0, 1; background-radius: 8, 7;");
    area.add(new Label("Right-click here, or focus the button and press the Menu key"));
    area.contextMenu(new ContextMenu()
        .add(new MenuItem("Cut", { report("Cut"); }).accelerator("Ctrl+X"))
        .add(new MenuItem("Copy", { report("Copy"); }).accelerator("Ctrl+C").graphic(new Icon("edit-copy-symbolic")))
        .add(new MenuItem("Paste", { report("Paste"); }).accelerator("Ctrl+V").graphic(new Icon("edit-paste-symbolic"))));

    // Drop-downs
    auto size = new ComboBox(["Small", "Medium", "Large", "Extra large"]).selectedIndex(1);
    size.selectedIndexProperty.addListener((int was, int now) { report("Size: " ~ size.value); });
    auto country = new ComboBox(["France", "Germany", "Italy", "Spain", "United Kingdom"]).promptText("Choose a country");
    country.selectedIndexProperty.addListener((int was, int now) { report("Country: " ~ country.value); });

    // Dialogs
    auto confirm = new Button("Delete…").styleClass("danger");
    confirm.setOnAction({
        new Dialog("Delete “notes.txt”?")
            .text("It will be gone for good. This can't be undone.")
            .addButton("Cancel", { report("Kept it"); }, ButtonKind.cancel)
            .addButton("Delete", { report("Deleted (not really)"); }, ButtonKind.default_)
            .show(confirm);
    });
    auto rename = new Button("Rename…");
    rename.setOnAction({
        auto name = new TextField("notes.txt");
        auto d = new Dialog("Rename");
        d.extra(name)
            .addButton("Cancel", null, ButtonKind.cancel)
            .addButton("Rename", { report("Renamed to " ~ name.text); }, ButtonKind.default_)
            .show(rename);
    });
    auto sheet = stylesheet!(`.danger { --base: #dc2626; --hover-base: #ef4444; --pressed-base: #b91c1c; colour: white; }`);

    auto result = page("Popups", "Menus, drop-downs, tooltips and dialogs show over the window. A menu or "
                       ~ "drop-down goes with a click outside it or Escape; a dialog dims the window until it's "
                       ~ "answered. Rest the pointer on a button with a tooltip to see it.")
        .add(section("A menu bar", menuBar))
        .add(section("Menu buttons", row(menuButton, menuWithText)))
        .add(section("A context menu", area))
        .add(section("Drop-downs", row(new Label("Size"), size, new Label("Country"), country)))
        .add(section("Dialogs", row(confirm, rename)))
        .add(section("Tooltips", row(
            new Button().graphic(new Icon("edit-undo-symbolic")).accessibleText("Undo").tooltip("Undo the last change"),
            new Button().graphic(new Icon("edit-redo-symbolic")).accessibleText("Redo").tooltip("Redo what was undone"),
            new Button().graphic(new Icon("help-about-symbolic")).accessibleText("About")
                .tooltip("A longer tooltip wraps once it's wider than a comfortable line, so it never runs off the window"))));
    result.stylesheets.add(sheet);
    return result;
}

/// A made-up person, for the table.
struct Person
{
    string name, city, email;
    int age;
}

/// A list cell with an icon before the text: what a cell factory makes.
class FileCell : ListCell!string
{
    this()
    {
        add(new Icon("text-x-generic-symbolic"));
    }
}

Widget listsPage(Report report)
{
    // Ten thousand items, of which only those in view are ever made
    string[] files;
    foreach (i; 0 .. 10_000)
        files ~= format!"Document %05d.txt"(i);
    // As a file manager's: Ctrl and Shift select more than one
    auto list = new ListView!string(files).prefSize(300, 260).selectionMode(SelectionMode.multiple);
    list.cellFactory({ return cast(ListCell!string) new FileCell; });
    list.onSelectionChanged({
        const n = list.selectedIndices.length;
        report(n == 1 ? "Selected " ~ list.selectedItem : format!"%d selected"(n));
    });
    list.onActivate((int i) { report("Opened " ~ files[i]); });

    // A table of made-up people, sortable by any column
    static immutable firsts = ["Ada", "Alan", "Grace", "Linus", "Margaret", "Dennis", "Barbara", "Ken", "Frances", "Tim"];
    static immutable lasts = ["Lovelace", "Turing", "Hopper", "Torvalds", "Hamilton", "Ritchie", "Liskov", "Thompson",
                              "Allen", "Berners-Lee"];
    static immutable cities = ["London", "Cambridge", "Leeds", "Edinburgh", "Bath", "York", "Bristol", "Oxford"];
    Person[] people;
    foreach (i; 0 .. 5_000)
    {
        const first = firsts[(i * 7) % firsts.length], last = lasts[(i * 3 + i / 10) % lasts.length];
        people ~= Person(first ~ " " ~ last, cities[(i * 5 + 1) % cities.length],
                         format!"%s.%s%d@example.com"(first, last, i), 18 + (i * 37) % 70);
    }
    auto table = new TableView!Person(people).prefSize(560, 300);
    table.add(new TableColumn!Person("Name", (Person p) => p.name))
         .add(new TableColumn!Person("Age", (Person p) => format!"%d"(p.age)).alignment(Alignment.end))
         .add(new TableColumn!Person("City", (Person p) => p.city))
         .add(new TableColumn!Person("Email", (Person p) => p.email));
    table.selectedIndexProperty.addListener((int was, int now) {
        if (now >= 0)
            report(format!"%s, %d, of %s"(table.selectedItem.name, table.selectedItem.age, table.selectedItem.city));
    });
    table.onActivate((int i) { report("Opened " ~ people[i].name); });

    // A made-up disk as deep as you like: each folder's contents made the first time it's opened
    TreeItem!string folder(string name, int depth)
    {
        return new TreeItem!string(name).icon("folder-symbolic").childrenLoader({
            TreeItem!string[] inside;
            foreach (i; 0 .. 4)
                inside ~= folder(format!"Folder %d.%d"(depth + 1, i + 1), depth + 1);
            foreach (i; 0 .. 12)
                inside ~= new TreeItem!string(format!"File %d.%02d.txt"(depth + 1, i + 1)).icon("text-x-generic-symbolic");
            return inside;
        });
    }
    auto disk = new TreeItem!string("Home").icon("user-home-symbolic")
        .add(folder("Documents", 0), folder("Music", 0), folder("Pictures", 0))
        .add(new TreeItem!string("readme.txt").icon("text-x-generic-symbolic"));
    auto tree = new TreeView!string(disk).prefSize(320, 300).showRoot(false);
    tree.onSelectionChanged({ if (auto item = tree.selectedItem) report("Selected " ~ item.value); });
    tree.onActivate((TreeItem!string item) { if (item.isLeaf) report("Opened " ~ item.value); });

    return page("Lists & tables", "A list or a table makes only the rows in view, however many items it has, "
                ~ "and gives rows that scroll out of view to those scrolling in. Click a table's header to sort "
                ~ "by it, click again for the other way, and drag its right edge to size the column. In the list, "
                ~ "Ctrl+click and Shift+click select more than one, as do Shift and Ctrl with the arrows, and Ctrl+A.")
        .add(section("A list of ten thousand, with a cell of its own, selecting any number", list))
        .add(section("A table of five thousand people", table))
        .add(section("A tree, each folder made the first time it's opened", tree));
}

Widget stylingPage(Report report)
{
    auto sheet = stylesheet!(`
        .danger { --base: #dc2626; --hover-base: #ef4444; --pressed-base: #b91c1c; colour: white; }
        .success { --base: #16a34a; --hover-base: #22c55e; --pressed-base: #15803d; colour: white; }
        .pill { background-radius: 16, 14; padding: 6 18; }
        .card { background-colour: var(--field); background-radius: 12; border-colour: var(--field-border);
                border-width: 1; border-radius: 12; padding: 16; }
        .purple { --accent: #7c3aed; --default-base: #7c3aed; --default-hover-base: #8b5cf6;
                  --default-pressed-base: #6d28d9; }
    `);

    auto themed = new Column().spacing(10).styleClass("card", "purple")
        .add(new Label("Everything in here has its --accent set to purple, from one rule."))
        .add(row(new Button("Default").defaultButton(true), new CheckBox("Checked").selected(true),
                 new Slider(0, 100, 60).prefWidth(160)));

    auto result = page("Styling", "Styles come from stylesheets, compiled into the app, in CSS with names of "
                       ~ "Mayfair's own. The theme's colours are variables, like --accent and --base, so one rule "
                       ~ "recolours everything that uses them. Use the switch at the top for dark.")
        .add(section("Classes that recolour a button", row(
            new Button("Delete").styleClass("danger").graphic(new Icon("user-trash-symbolic"))
                .onAction({ report("Deleted (not really)"); }),
            new Button("Confirm").styleClass("success").onAction({ report("Confirmed"); }),
            new Button("Pill").styleClass("pill"))))
        .add(section("Variables for part of the tree", themed))
        .add(section("An inline style", row(
            new Label("Just this label").style("colour: var(--accent); font-size: 18px; font-style: italic;"))));
    result.stylesheets.add(sheet);
    return result;
}

Widget propertiesPage()
{
    auto first = new TextField("Ada");
    auto last = new TextField("Lovelace");
    auto full = new Label("");
    // A label bound to two fields: it follows them, with no handler anywhere
    full.textProperty.bind(binding(() => first.text ~ " " ~ last.text, first.textProperty, last.textProperty));

    auto slider = new Slider(0, 100, 30).prefWidth(240);
    auto mirror = new Slider(0, 100, 30).prefWidth(240);
    mirror.valueProperty.bindBidirectional(slider.valueProperty);

    auto enable = new CheckBox("Enable the button");
    auto button = new Button("Only when ticked");
    button.disableProperty.bind(enable.selectedProperty.not);

    return page("Properties", "Every setting is a property, which can be listened to and bound. Bound, a "
                ~ "property follows another -- or several, through map and the rest -- and two can be bound "
                ~ "both ways.")
        .add(section("A label following two fields", new Column().spacing(8)
            .add(row(new Label("First"), first, new Label("Last"), last))
            .add(row(new Label("Full name:"), full))))
        .add(section("Two sliders bound both ways", new Column().spacing(8).add(row(slider)).add(row(mirror))))
        .add(section("Disabled while unticked", row(enable, button)));
}
