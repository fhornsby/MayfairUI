Clips for the tests, made with GStreamer's own test sources, so they're free of anyone's rights:

- `red-blue.ogg`: 160x120, 2 s at 25 fps -- a second of red, then a second of blue -- with a 440 Hz
  tone. Theora and Vorbis in Ogg, which GStreamer's base plugins play.
- `green.ogg`: 320x240, 1 s of green, with a 660 Hz tone.

Remade with:

    V="video/x-raw,width=160,height=120,framerate=25/1"
    gst-launch-1.0 concat name=c ! videoconvert ! theoraenc ! queue ! oggmux name=m ! filesink location=red-blue.ogg \
      videotestsrc pattern=solid-color foreground-color=0xffff0000 num-buffers=25 ! $V ! c. \
      videotestsrc pattern=solid-color foreground-color=0xff0000ff num-buffers=25 ! $V ! c. \
      audiotestsrc wave=sine freq=440 volume=0.2 samplesperbuffer=1764 num-buffers=50 ! audio/x-raw,rate=44100,channels=1 ! audioconvert ! vorbisenc ! queue ! m.

    V="video/x-raw,width=320,height=240,framerate=25/1"
    gst-launch-1.0 videotestsrc pattern=solid-color foreground-color=0xff00ff00 num-buffers=25 ! $V ! videoconvert ! theoraenc ! queue ! oggmux name=m ! filesink location=green.ogg \
      audiotestsrc wave=sine freq=660 volume=0.2 samplesperbuffer=1764 num-buffers=25 ! audio/x-raw,rate=44100,channels=1 ! audioconvert ! vorbisenc ! queue ! m.
