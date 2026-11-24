The Video page's clip, made from GStreamer's own test patterns, so it's free of anyone's rights:
`bars-and-ball.ogg`, 480x270 at 25 fps for 6 s -- SMPTE colour bars with GStreamer's moving ball
over them, and a ticking tone -- as Theora and Vorbis in Ogg, which GStreamer's base plugins play.

Remade with:

    gst-launch-1.0 compositor name=mix background=black ! video/x-raw,width=480,height=270 ! videoconvert \
        ! theoraenc quality=40 ! queue ! oggmux name=m ! filesink location=bars-and-ball.ogg \
      videotestsrc pattern=smpte75 num-buffers=150 ! video/x-raw,width=480,height=270,framerate=25/1 ! mix. \
      videotestsrc pattern=ball background-color=0x00000000 foreground-color=0xffffffff num-buffers=150 \
        ! video/x-raw,format=BGRA,width=480,height=270,framerate=25/1 ! mix. \
      audiotestsrc wave=ticks freq=880 volume=0.4 samplesperbuffer=1764 num-buffers=150 \
        ! audio/x-raw,rate=44100,channels=2 ! audioconvert ! vorbisenc ! queue ! m.
