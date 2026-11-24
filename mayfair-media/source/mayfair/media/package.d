module mayfair.media;

/*
    Video and audio for Mayfair: a Media to play, a MediaPlayer to play it, and a MediaView to show
    its video, as JavaFX has them -- played by a backend the app chooses, in a package of its own.

        import mayfair.media;
        import mayfair.media.gstreamer;   // mayfair-gstreamer

        MediaPlayer.setBackend(new GStreamerBackend);
        auto player = new MediaPlayer(new Media("clip.webm"));
        auto view = new MediaView(player);
        player.play();

    This package has no library of its own to play anything with, so it carries no licence but
    its own: what plays media -- GStreamer's, FFmpeg's -- is in its backend's package, under its
    library's terms. See mayfair-media's README.
*/

public import mayfair.media.backend;
public import mayfair.media.media;
public import mayfair.media.player;
public import mayfair.media.view;
