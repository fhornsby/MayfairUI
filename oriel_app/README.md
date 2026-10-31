# Oriel App (Mayfair)

A hello world for the [Oriel](https://github.com/fhornsby/Oriel) desktop, written in Mayfair:
the Mayfair twin of the Oriel app template (OrielAvaloniaTemplate). It has the look of
Oriel Files and Oriel Settings: a sidebar, traffic lights at the top right, and light and dark
following the desktop.

On Oriel the sidebar is frosted glass, as a macOS one is: the desktop shows through it blurred,
all the way up behind the title bar, while the page beside it stays opaque. The blur is the compositor's, asked for over
`ext-background-effect-v1`, the standard Wayland protocol for it. Where nothing blurs
(Translucency off in Oriel Settings, or a desktop without the protocol, or X11) the window is
opaque, and it switches between the two while it runs. The Appearance page says which it is now.

```sh
cd oriel_app && dub run
```

## What's where

* `source/app.d`: the window. It gives the scene its own title bar, adds `oriel.css`, and asks
  for translucency with `app.setTranslucent(true)`.
* `resources/views/main.xml`: what's below the title bar, the sidebar and the first page.
* `resources/views/appearance.xml`, `source/appearance.d`: the second page, which follows
  `scene.translucentProperty`.
* `resources/values/strings.xml`: its text, in UK English, and `values-fr`, `values-de` and
  `values-zh` beside it, the same in French, German and Chinese. It's shown in the desktop's
  language; try another with `LANGUAGE=fr dub run`, or build for one alone with
  `dub build --d-version=MayfairLanguage_fr`.
* `resources/views/oriel.css`: the Oriel palette (the template's colours), the frosted sidebar under
  `.root:translucent`, and the traffic lights. Give a part of the window
  `backdrop-blur: true` and a translucent background to make it glass too.
