# Mayfair

Mayfair is a desktop UI toolkit for the D programming language. It features retained-mode widgets laid out in a tree, styled with CSS, optionally described in XML, and drawn on the GPU with vector graphics.

> **Mayfair is at v0.1.** It's usable, and I am building personal and toy apps with it, but the API is still heavily in development and will have breaking changes. Mayfair is not ready for anything more than simple prototyping and playing with, and definitely not ready for production.
>
> It's also a side project, so updates may be slow and irregular, and it could be dropped
> altogether.

```d
import mayfair;

void main()
{
    auto app = new App("Hello");
    auto greeting = new Label("Hello, world");

    auto column = new Column;
    column.setSpacing(12);
    column.setAlignment(Pos.centre);
    column.add(greeting);
    column.add(new Button("Say hello").onAction({ greeting.setText("Hello from Mayfair"); }));

    app.scene = new Scene(column);
    app.run();
}
```

The same window can be written as a view, with its layout in XML and its behaviour in a class:

```xml
<!-- resources/views/main.xml -->
<Column spacing="12" alignment="centre">
    <Label id="greeting" text="Hello, world"/>
    <Button text="Say hello" onAction="sayHello"/>
</Column>
```

```d
import mayfair;

@View("main.xml")
class Main
{
    @xml Label greeting;

    private void sayHello() { greeting.setText("Hello from Mayfair"); }
}

void main()
{
    auto app = new App("Hello");
    app.scene = new Scene(View.load(new Main));
    app.run();
}
```

The XML is read and compiled into a widget tree at compile time, so a mistake in a view (a misspelt widget, a handler that
doesn't exist) is a compile error, not a crash.

## What's in it

Mayfair builds on other people's libraries for drawing, layout and text (see [Thanks](#thanks)),
and adds the toolkit around them.

- **Widgets:** buttons, check boxes, toggles, text fields and areas, password fields, sliders,
  progress bars, combo boxes, menus, dialogs, tabs, list, tree and table views (virtualised, so
  they scale to large data), a navigation sidebar, a scroll pane, a canvas, images, icons, Lottie
  animations, and LiteWebView for simple HTML.
- **Layout:** rows, columns, grids, docks and flexbox (Yoga).
- **Styling:** CSS, with variables. The default theme follows the desktop's light or dark mode,
  its icon theme, where it puts the title-bar buttons, and how it smooths text.
- **Properties:** observable properties that can be listened to, mapped and bound to each other.
- **Text:** full Unicode: shaping (HarfBuzz), bidirectional text, line breaking, and
  selectable, copyable labels.
- **Translation:** an app's strings in `strings.xml`, one entry per language.
- **Accessibility:** screen readers are told about every widget, through AccessKit.
- **Rendering:** ThorVG on WebGPU (Vulkan or Metal underneath), falling back to OpenGL and then
  to the CPU where the GPU can't.
- **Wayland first:** client-side decorations, fractional scaling, and frame pacing to the
  compositor.

A terminal widget, on alacritty_terminal, is a separate package: [`mayfair-terminal`](mayfair-terminal).

## Platforms

| Platform | |
|---|---|
| Linux (Wayland and X11) | The main target: developed and tested on (Ubuntu 26.04, GNOME) |
| FreeBSD | A primary intended target, but untested for now |
| macOS and Windows | Not supported, as I can't test on them |

I won't be supporting macOS or Windows directly, but I'm happy to take fixes that get Mayfair
running there. Some parts only work on Linux and the BSDs for now: screen readers are spoken to
through AT-SPI, and the file chooser is the desktop portal's.

An experimental browser build (WebAssembly, through Emscripten) is in [`mayfair/web`](mayfair/web),
but it currently doesn't work, since desktop features were added.

## Building

Mayfair currently needs LDC 1.41 or later, dub, SDL3, CMake, Meson and a C/C++ compiler; Rust's
cargo too, for `mayfair-terminal`, and for Mayfair itself anywhere but Linux x86_64. DMD or GDC
may work instead of LDC, as long as their D front end is 2.111 or later, but neither is tested,
and DMD's code is slower, as its optimiser isn't as good. On Ubuntu 26.04 or FreeBSD 14,
`setup.sh` installs all of it and builds the gallery:

```sh
git clone --recurse-submodules https://github.com/fhornsby/MayfairUI.git
cd MayfairUI
./setup.sh
cd examples/gallery && dub run
```

To use Mayfair in an app, depend on it by path in the app's `dub.json`:

```json
"dependencies": {
    "mayfair": { "path": "../MayfairUI/mayfair" }
}
```

The first build compiles its C and C++ dependencies (`mayfair/vendor/build.sh`), which takes a
few minutes; after that they're only rebuilt when they change.

## Examples

| | |
|---|---|
| [`gallery`](examples/gallery) | Every widget, a page each |
| [`hello-xml`](examples/hello-xml) | Hello world, its window written in XML, with widgets of its own |
| [`hello-web`](examples/hello-web) | The same, in a browser |
| [`markdown-editor`](examples/markdown-editor) | A Markdown editor: a folder's files, a tab per document, and a live preview |
| [`appwrite-todo`](examples/appwrite-todo) | A to-do list stored in Appwrite, with sign-in |
| [`oriel-hello`](examples/oriel-hello) | An app for the Oriel desktop environment (currently unreleased), with a frosted-glass sidebar |

## To do

What's still to be done, that I know of:

**Text**
- Plurals in `strings.xml`, so "1 file" and "3 files" can each be translated. Most languages
  don't count the way English does: French treats 0 as singular, Russian and Polish have three or
  four forms, and Arabic has six.
- Read the display's subpixel layout (RGB, BGR or vertical) from Wayland's `wl_output`, rather
  than assuming RGB.
- At 14px, lowercase letters come out a pixel taller than Zed's, as the hinting rounds their
  height up.
- Choose a default font. IBM Plex Sans is bundled for now, so Mayfair can be compared side by
  side with Zed.
- Justified text: `TextAlignment.justify` lines text up on the left for now.

**Desktop**
- A settings source for Oriel, so that on Oriel Mayfair stops reading GNOME's GSettings.

**Platforms**
- Test on FreeBSD, a primary target that's untested so far.
- Fix the browser build, and give it more than the CPU renderer.

**Building**
- Try building with DMD and GDC, which are allowed but untested, and with D front ends older
  than 2.111 (LDC 1.41's), to find what really works. 2.106 (LDC 1.36) can't: its ImportC has no
  `#pragma attribute`.

**Before 1.0**
- Audit the code by hand, once a few apps have been built with it (see below).

## Licence

Mayfair is under the [MIT licence](LICENSE), and everything it depends on is under a permissive
licence too: nothing is copyleft, so an app built with it can be statically linked and closed
source.

Static linking does mean an app built with Mayfair has to ship its dependencies' notices:
[`mayfair/THIRD_PARTY_NOTICES.md`](mayfair/THIRD_PARTY_NOTICES.md) has all of them, and
[`mayfair-terminal/THIRD_PARTY_NOTICES.md`](mayfair-terminal/THIRD_PARTY_NOTICES.md) has the
terminal's.

## Thanks

Mayfair stands on a lot of other people's work.

**The libraries it's built on:** [ThorVG](https://www.thorvg.org) draws everything,
[wgpu](https://wgpu.rs) puts it on the GPU, [Yoga](https://yogalayout.dev) lays it out,
[FreeType](https://freetype.org) and [HarfBuzz](https://harfbuzz.github.io) set its text,
[SheenBidi](https://github.com/Tehreer/SheenBidi) and
[libunibreak](https://github.com/adah1972/libunibreak) handle right-to-left text and line breaks,
[litehtml](https://github.com/litehtml/litehtml) lays out HTML, [AccessKit](https://accesskit.dev)
speaks to screen readers, [SDL](https://libsdl.org) opens the windows,
[alacritty_terminal](https://github.com/alacritty/alacritty) runs the terminal, and
[IBM Plex](https://www.ibm.com/plex/) and [DejaVu](https://dejavu-fonts.github.io) are its current default fonts.
And [D](https://dlang.org) and [LDC](https://github.com/ldc-developers/ldc), which it's written in.

**The toolkits it learnt from:** [JavaFX](https://openjfx.io) above all: the scene and its tree
of widgets, styling with CSS, views written in markup, and observable properties are all its
ideas, respelt. [GNOME](https://www.gnome.org) and GTK, for how a Linux app should look and
behave: the default theme, overlay scroll bars, client-side decorations and the icon theme follow
them. [Flutter](https://flutter.dev), for how layout and painting are split. And
[Spring](https://spring.io), for `@autowired`.

## About its development

Mayfair is written with the help of AI (Claude, by Anthropic), and the commits it helped with
say so. Further breaking changes are expected. Once a few apps have been made (to a reasonable production standard), and any bugs or oddities have been worked out, I intend to audit the code by hand. From then on, changes made with AI help are kept small and reviewed one at a time.
