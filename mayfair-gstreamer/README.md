# mayfair-gstreamer

A [mayfair-media](../mayfair-media) backend on [GStreamer](https://gstreamer.freedesktop.org): the
GStreamer installed on the system does the reading, demuxing, decoding, buffering, timing, keeping
sound and picture in step, and playing the sound. Mayfair shows the video in a `MediaView` and draws
the controls. GStreamer's own widgets (GTK's, Qt's) and its video windows aren't used, and nothing
of GTK or Qt is needed.

```d
import mayfair.media;
import mayfair.media.gstreamer;

MediaPlayer.setBackend(new GStreamerBackend);
```

```json
"dependencies": {
    "mayfair-media": { "path": "../MayfairUI/mayfair-media" },
    "mayfair-gstreamer": { "path": "../MayfairUI/mayfair-gstreamer" }
}
```

## How it works

Each player has a `playbin`, GStreamer's all-in-one player, which finds the demuxer and decoders
for whatever it's given. Its video goes to an `appsink` (by way of `videoconvert`) as BGRA frames,
which Mayfair shows as images in its own drawing, a copy a frame. Its sound goes to GStreamer's
`autoaudiosink`: PipeWire, PulseAudio, ALSA, CoreAudio or WASAPI, whichever the system has.
`new GStreamerBackend("fakesink sync=true")` plays none, keeping time as though it did: for tests,
or a machine with no sound.

Each player's session has a thread of its own. It starts GStreamer, builds the pipeline, changes
its state, seeks, and takes it all down, so the UI thread never waits on GStreamer. Each media
loaded gets a new pipeline, so nothing the last one says as it stops can reach the next. Frames
come from GStreamer's streaming threads through a mailbox that holds the newest one only (see
mayfair-media), and the `appsink` keeps at most two, dropping the oldest. A stream that's
buffering pauses until it's filled up, as GStreamer asks applications to.

**Using the system's GStreamer.** GStreamer isn't linked into the app: it's found when the first
player loads something (`dlopen`, or `LoadLibrary` on Windows). So:

- an app builds without GStreamer or its headers;
- an app runs without it, and its players halt with `MediaErrorKind.backendUnavailable`, saying
  what's missing; `GStreamerBackend.available()` asks up front;
- it plays whatever the system's GStreamer plugins play, and gets their fixes as the system
  updates them.

It declares the few parts of GStreamer's C API it uses itself (`source/.../gst.d`), as
GStreamer's headers bring GLib's with them. `tools/check-abi.sh` checks those declarations
against the installed headers.

## What it needs

GStreamer 1.14 or later, with its base plugins at least. GStreamer runs on Linux, the BSDs,
macOS, Windows, Android and iOS. This backend looks for it in the usual places on Linux, the BSDs,
macOS and Windows, but has only been tested on Linux (see below).

| System | Install |
|---|---|
| Debian, Ubuntu | `sudo apt install gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav` |
| Fedora | `sudo dnf install gstreamer1-plugins-base gstreamer1-plugins-good gstreamer1-plugins-bad-free gstreamer1-plugin-libav` |
| FreeBSD | `pkg install gstreamer1-plugins-good gstreamer1-plugins-bad gstreamer1-libav` (and the plugins for the formats wanted) |
| macOS | GStreamer's runtime installer from gstreamer.freedesktop.org (its framework is looked for), or Homebrew's `gstreamer` |
| Windows | GStreamer's MSVC runtime installer, with its `bin` folder on the `PATH` |

Most desktop Linux systems have GStreamer and its base and good plugins already, as their own
media apps use them.

What plays depends on which plugins are installed:

| Plugins | Brings |
|---|---|
| base | `playbin`, Ogg, Theora, Vorbis, Opus: enough for this package's tests and the gallery's clip |
| good | WebM and Matroska, MP4 and MOV, VP8 and VP9, FLAC, WAV, and the PulseAudio sink |
| bad | AV1 (with dav1d) and more |
| ugly | some older formats and codecs |
| libav | FFmpeg's decoders: H.264, HEVC, AAC and most others |

Media whose format or codec has no plugin halts with `MediaErrorKind.unsupported`, and its error's
`details` says which plugins might play it.

## Licences

This package is MIT. **That doesn't change GStreamer's terms**, or any plugin's: an app that uses
it uses GStreamer under GStreamer's licences.

- GStreamer itself, and its base and good plugins, are **LGPL-2.1-or-later**.
- The bad and ugly plugins are mostly LGPL too, but some have other licences, and the ugly ones are
  those with patent or distribution problems.
- gst-libav is LGPL, and wraps FFmpeg, which is LGPL-2.1-or-later or GPL, depending on how it was
  built: the system's build decides.
- Patents on codecs (H.264, HEVC and AAC among them) are apart from any copyright licence. Whether
  they matter to an app depends on where it's distributed and how.

An app that uses the GStreamer the system already has distributes none of it. An app that bundles
GStreamer with itself (as an installer on Windows or macOS would) distributes GStreamer and its
plugins, and has to meet their licences: for the LGPL, among other things, letting users replace
the GStreamer libraries with their own. This package loads them at run time, from separate files,
which allows that. This is a summary to point the way, not legal advice: the licences themselves,
and the plugins' documentation, say what applies.

## Tested

Tested in a Linux container: real windows on Xvfb, with no physical GPU, display or sound device.
Nothing else has been tested yet.

| | Tested |
|---|---|
| System | Ubuntu 24.04, x86-64 |
| GStreamer | 1.24.2: core, base and good plugins |
| Media | Theora and Vorbis in Ogg (the test and gallery clips) |
| Display | X11 (Xvfb) |
| Mayfair's renderer | WebGPU on lavapipe (Mesa's software Vulkan), and the CPU renderer |
| Sound | `fakesink sync=true` in the tests; the default `autoaudiosink` in the gallery, with no sound device to play to |

Not tested yet: Wayland, a real GPU, sound heard from a real device, the OpenGL renderer (Xvfb
couldn't make a window for it), other formats and codecs, network streams and their buffering,
media with non-square pixels (only through mayfair-media's fake backend), subtitles, FreeBSD,
macOS and Windows.

## Tests

`tests/` plays real media through real windows (see mayfair/tests' harness). It covers:

- loading;
- playing to the end, and again;
- pausing and seeking, paused and playing;
- stopping;
- looping;
- volume and mute;
- replacing the media, once and in quick succession, with no frame of the old media shown after;
- errors: missing files, and files that aren't media;
- a view taken out of the window and put back while its player plays;
- disposal while loading and while playing. This also checks that `dispose()` never keeps the UI
  thread waiting, and that every thread the sessions started ends.

```sh
cd tests && dub run
```

It's skipped, saying why, where GStreamer isn't installed.
