module video;

import core.time : Duration, msecs, seconds;
import std.format : format;
import std.path : buildPath, dirName;
import mayfair;
import mayfair.media;
import mayfair.media.gstreamer;
import gallery : page, row;

/*
    The gallery's Video page: a MediaPlayer, played by GStreamer, shown in a MediaView, with
    every control Mayfair's own -- buttons and sliders that call the player, and read what it
    says it's doing from its properties.
*/
Widget videoPage(void delegate(string) report)
{
    // The gallery plays media with GStreamer: the app's choice, made once
    if (!MediaPlayer.backend)
        MediaPlayer.setBackend(new GStreamerBackend);

    auto player = new MediaPlayer(new Media(demoClip));
    auto view = new MediaView(player).accessibleText("The video");

    // The video, in a dark box, with what it's doing over its corner
    auto status = new Label("Loading").style("background-colour: rgba(0, 0, 0, 0.6); colour: white; "
                                             ~ "padding: 4 8; background-radius: 6;");
    auto stage = new VideoStage().alignment(Pos.topLeft).prefHeight(300);
    stage.style("background-colour: #101418; background-radius: 10;");
    stage.add(view).add(status.margin(Insets(10)));
    stage.onHidden = { player.pause(); }; // another page: no sound from one not seen

    // Play and pause, as one button; stop
    auto playPause = new Button("Play").graphic(new Icon("media-playback-start-symbolic"));
    playPause.setOnAction({
        if (player.status == MediaStatus.playing || player.status == MediaStatus.stalled)
            player.pause();
        else
            player.play();
    });
    auto stop = new Button().graphic(new Icon("media-playback-stop-symbolic")).accessibleText("Stop")
        .tooltip("Stop, and go back to the start");
    stop.setOnAction({ player.stop(); });

    // Where it's got to, which dragging seeks
    auto position = new Slider(0, 1, 0);
    position.setGrow(1);
    auto time = new Label("0:00 / 0:00");
    bool showingTime; // set while the slider's moved to match the player, so it doesn't seek
    void showTime()
    {
        const at = player.currentTime, of = player.media ? player.media.duration : Duration.zero;
        time.setText(format!"%s / %s"(clock(at), clock(of)));
        if (position.valueChanging)
            return; // the user's dragging it
        showingTime = true;
        position.setMax(of > Duration.zero ? of.total!"msecs" / 1000.0 : 1);
        position.setValue(at.total!"msecs" / 1000.0);
        showingTime = false;
    }
    player.currentTimeProperty.addListener((Duration was, Duration now) { showTime(); });
    position.valueProperty.addListener((double was, double now) {
        if (!showingTime)
            player.seek(msecs(cast(long) (now * 1000)));
    });

    // Volume and mute
    auto volume = new Slider(0, 1, 1).prefWidth(110).accessibleText("Volume");
    volume.valueProperty.addListener((double was, double now) { player.setVolume(now); });
    auto mute = new ToggleButton().graphic(new Icon("audio-volume-high-symbolic")).accessibleText("Mute")
        .tooltip("Mute");
    mute.selectedProperty.addListener((bool was, bool now) {
        player.setMute(now);
        mute.setGraphic(new Icon(now ? "audio-volume-muted-symbolic" : "audio-volume-high-symbolic"));
    });

    // Looping, how it fills the box, and full screen
    auto loop = new CheckBox("Loop");
    loop.selectedProperty.addListener((bool was, bool now) {
        player.setCycleCount(now ? MediaPlayer.indefinite : 1);
    });
    auto scaling = new ComboBox(["Fit", "Cover", "Stretch"]).selectedIndex(0).accessibleText("Scaling");
    scaling.selectedIndexProperty.addListener((int was, int now) { view.setScaling(cast(VideoScaling) now); });
    auto fullScreen = new Button().graphic(new Icon("view-fullscreen-symbolic")).accessibleText("Full screen")
        .tooltip("Full screen: the same player, in a window of its own");
    fullScreen.setOnAction({ showFullScreen(view, stage, player); });

    // Another video, chosen from the disk
    auto open = new Button("Open a video…").graphic(new Icon("document-open-symbolic"));
    open.setOnAction({
        new FileChooser().addFilter("Videos", "webm", "mkv", "mp4", "mov", "ogv", "ogg", "avi", "m4v")
            .addFilter("Audio", "mp3", "flac", "opus", "ogg", "wav", "m4a")
            .showOpenDialog(open, (path) {
                if (path)
                    player.setMedia(new Media(path));
            });
    });

    // What's playing, and what it's doing, from the player's properties
    auto about = new Label("").wrapText(true);
    void describe()
    {
        auto m = player.media;
        if (!m)
            return;
        string text = format!"%s · %s"(m.width ? format!"%s × %s"(m.width, m.height) : "no video", clock(m.duration));
        foreach (t; m.tracks)
            if (t.codec.length)
                text ~= format!" · %s %s"(t.kind, t.codec);
        about.setText(text);
    }
    player.statusProperty.addListener((MediaStatus was, MediaStatus now) {
        final switch (now)
        {
            case MediaStatus.unknown: status.setText("Loading"); break;
            case MediaStatus.ready: status.setText("Ready"); describe(); break;
            case MediaStatus.playing: status.setText("Playing"); break;
            case MediaStatus.paused: status.setText("Paused"); break;
            case MediaStatus.stalled: status.setText("Buffering"); break;
            case MediaStatus.stopped: status.setText("Stopped"); break;
            case MediaStatus.ended: status.setText("Ended"); break;
            case MediaStatus.halted: status.setText("Can't play this"); break;
            case MediaStatus.disposed: status.setText("Gone"); break;
        }
        const playing = now == MediaStatus.playing || now == MediaStatus.stalled;
        playPause.setText(playing ? "Pause" : "Play");
        playPause.setGraphic(new Icon(playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic"));
        showTime();
    });
    player.onError((MediaError e) {
        about.setText(e.toString);
        report("Media error: " ~ e.message);
    });
    player.onEndOfMedia({ report("Played to the end"); });
    player.onRepeat({ report(format!"Looped: %s times through"(player.currentCount)); });

    return page("Video", "A MediaPlayer, played by GStreamer, shown in a MediaView: a widget like any "
                ~ "other, under the label over its corner, clipped to its box. The controls are Mayfair's "
                ~ "own, reading what the player's doing from its properties. Full screen moves the same "
                ~ "view, still playing, to a window of its own.")
        .add(stage)
        .add(new Row().spacing(8).alignment(Pos.centreLeft).add(playPause).add(stop).add(position).add(time))
        .add(row(mute, volume, loop, new Label("Scaling"), scaling, fullScreen, open))
        .add(about);
}

/// The clip the page starts with: GStreamer's test patterns, made for the gallery (see media/README.md).
string demoClip() { return buildPath(dirName(__FILE_FULL_PATH__), "..", "media", "bars-and-ball.ogg"); }

/// A time as minutes and seconds.
string clock(Duration d)
{
    if (d == Media.indefinite)
        return "live";
    const s = d.total!"seconds";
    return format!"%d:%02d"(s / 60, s % 60);
}

/// The box the video's in, which says when it's out of the window: another page chosen.
final class VideoStage : Stack
{
    void delegate() onHidden;

protected:
    override void unmounted()
    {
        super.unmounted();
        if (onHidden)
            onHidden();
    }
}

/*
    Full screen: the view itself, moved from the page to a window that fills the screen, the
    player playing on through the move; and back again when that window closes.
*/
void showFullScreen(MediaView view, Stack stage, MediaPlayer player)
{
    auto overlay = new VideoStage().alignment(Pos.topRight);
    overlay.style("background-colour: black;");
    auto leave = new Button("Leave full screen").graphic(new Icon("view-restore-symbolic"));
    auto window = new Window("Video").setFullScreen(true);
    leave.setOnAction({ window.close(); });
    view.onMouseClicked((ref e) {
        if (e.clickCount == 2)
            window.close();
    });

    stage.remove(view);
    overlay.add(view).add(leave.margin(Insets(16)));
    window.scene = new Scene(overlay);
    window.onClosed({
        // Back where it was, behind the label
        overlay.remove(view);
        auto rest = stage.children.dup;
        foreach (c; rest)
            stage.remove(c);
        stage.add(view);
        foreach (c; rest)
            stage.add(c);
        view.onMouseClicked(null);
    });
    window.show();
}
