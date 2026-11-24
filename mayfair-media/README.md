# mayfair-media

Video and audio for Mayfair, as JavaFX has them: a `Media` to play, a `MediaPlayer` to play it,
and a `MediaView` to show its video. The playing itself is done by a **backend** in a package of
its own, which the app chooses: this package has no media library in it, and nothing but its own
MIT licence.

| Package | What it is |
|---|---|
| `mayfair-media` | This one: the API, the backend interfaces, and `MediaView`. No GStreamer, no FFmpeg. |
| [`mayfair-gstreamer`](../mayfair-gstreamer) | A backend on the system's GStreamer: the first, and so far the only one. |
| `mayfair-ffmpeg` | Not written yet: a backend on FFmpeg, with SDL3 for the sound, under FFmpeg's terms. |

```d
import mayfair;
import mayfair.media;
import mayfair.media.gstreamer;

MediaPlayer.setBackend(new GStreamerBackend);   // once: the app's choice, made explicitly

auto player = new MediaPlayer(new Media("/home/me/Videos/holiday.webm"));
auto view = new MediaView(player);               // a widget like any other
auto play = new Button("Play").onAction({ player.play(); });
player.statusProperty.addListener((MediaStatus was, MediaStatus now) { ... });
...
player.dispose();                                // explicitly, when it's done with
```

The [gallery](../examples/gallery)'s Video page is a player built this way: play and pause, a
seek bar, the time, volume and mute, looping, how the video fills its box, full screen, and
opening another file.

## The API

**`Media`** is a file's path or a URI (`file://`, `https://`, `rtsp://`, whatever the backend
reads). Making one opens nothing: its `duration`, `width`, `height`, `pixelAspectRatio`, `tracks`
and `metadata` are properties, filled in as a player loads it.

**`MediaPlayer`** plays one at a time:

- `play()`, `pause()`, `stop()`, `seek(Duration)`
- `volume` (0 to 1) and `mute`, `cycleCount` (or `MediaPlayer.indefinite` to loop), `autoPlay`
- `status`, `currentTime`, `bufferProgress`, `error`, `currentCount`: what it's doing, as properties
- `onReady`, `onEndOfMedia`, `onRepeat`, `onError`
- `setMedia(Media)`: other media, played by the same player, from the start
- `dispose()`: stops it for good, and lets go of everything

Its `status` goes `unknown` (loading) → `ready` → `playing` / `paused` / `stalled` (buffering) /
`stopped` / `ended`, or `halted` on an error, and `disposed`. That's JavaFX's `MediaPlayer.Status`
with `ended` added, for a player that's stopped at the end: `play()` from there starts again.

**`MediaView`** shows a player's video. It's an ordinary widget: laid out, clipped by what holds it,
faded, transformed and drawn over like any other, in the window's own drawing. `scaling` is `fit`
(the default: the whole picture, with bars), `cover` (filling the view, cut off at its edges, for
a grid or a feed) or `stretch`; `videoBounds()` says where the picture is, for whatever's laid
over it. Its natural size is the video's.

## How it behaves

**Nothing waits on the UI thread.** Every call returns at once. Loading, seeking and every change
of state happen on the backend's threads, and the properties change when they have, not when they
were asked for: `play()` makes `status` `playing` once it's playing. Controls ask the player, and
show what its properties say.

**The player outlives its views.** A `MediaView` taken out of the window, moved to another one, put
into a full-screen window, or given another player, leaves its player playing as it was. Put back,
it shows the current frame at once. Only `dispose()` stops a player, and it has to be called: a
player that nothing refers to is still playing on the backend's thread, and still heard. `dispose()`
returns at once; the backend lets go of its threads and native resources on its own thread.

**Nothing late lands on the wrong media.** Everything a backend tells a player carries the
generation it's about, which `setMedia()` and `dispose()` move on: a frame, an error or an end from
media that's since been replaced is dropped (and the frame released). So a cell in a list that's
reused as it scrolls can give its player the next item's media without anything of the last item's
showing. (This is the lifecycle a feed needs; a feed that loads ahead of where it's scrolled to is
not built yet.)

**Frames are bounded.** A backend holds one decoded frame waiting for the UI thread (a
`FrameMailbox`): a newer one replaces it, and the older is released then and there. Video never
queues up behind a slow frame, and memory doesn't grow.

**Short loops and long films are the same API.** `cycleCount` loops a clip; `seek`, `currentTime`
and `bufferProgress` serve a two-hour film. Looping seeks back to the start at the end, which can
leave a gap of a frame or so; a gapless loop is to do.

## Writing a backend

A backend implements `MediaBackend` and `MediaSession` (see `backend.d`): one session per player,
whose methods are called on the UI thread and must return at once, and which tells its player what
happened through `MediaSessionHost`, on the UI thread. The rules are written out at the top of
`backend.d`. In short:

- Slow work on the backend's own threads; news to the UI thread with `Platform.runLater` from a
  thread the D runtime knows, or a `FrameMailbox` from one it doesn't (a library's streaming
  thread, which can't allocate).
- Frames as 32-bit `0xAARRGGBB` pixels (BGRA bytes), premultiplied, through `VideoFrame`.
- Every piece of news carries the generation it's for; `dispose()` is asynchronous.

The player does what's the same for every backend: status, looping, `stop`, ending, and dropping
stale news. So a backend is only the playing itself. An FFmpeg one would decode on a thread of
its own, keep its own clock, play the sound with SDL3's audio, and post frames and positions the
same way.

## Tests

`tests/` drives `MediaPlayer` and `MediaView` against a fake backend that does only what it's told,
so every state and every late or stale piece of news can be made to happen on cue:

```sh
cd tests && dub run
```

mayfair-gstreamer's tests play real media.

## Licence

MIT, as Mayfair is. This package plays nothing itself. Whatever backend an app adds brings its
library's licence with it, which this package's licence doesn't change.
