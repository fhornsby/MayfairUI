# Oriel App (Mayfair)

A hello world for the [Oriel](https://github.com/fhornsby/Oriel) desktop, written in Mayfair:
the Mayfair twin of the Oriel app template (OrielAvaloniaTemplate). It has the look of
Oriel Files and Oriel Settings: a sidebar, traffic lights at the top right, and light and dark
following the desktop.

On Oriel the window is frosted glass: the sidebar, the page and the title bar each let the
desktop show through, blurred. The blur is the compositor's, asked for over
`ext-background-effect-v1`, the standard Wayland protocol for it. Where nothing blurs
(Translucency off in Oriel Settings, or a desktop without the protocol, or X11) the window is
opaque, and it switches between the two while it runs. The Appearance page says which it is now.

```sh
cd oriel_app && dub run
```

## What's where

* `source/app.d`: the window. It gives the scene its own title bar, adds `oriel.css`, and asks
  for translucency with `app.setTranslucent(true)`.
* `views/main.xml`: what's below the title bar, the sidebar and the first page.
* `views/appearance.xml`, `source/appearance.d`: the second page, which follows
  `scene.translucentProperty`.
* `views/oriel.css`: the Oriel palette (the template's colours), the frosted glass under
  `.root:translucent`, and the traffic lights. Give a part of the window
  `backdrop-blur: true` and a translucent background to make it glass too.
