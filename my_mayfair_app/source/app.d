import mayfair;
import core.thread : Thread;
import core.time : seconds;
import std.net.curl : get, HTTP;
import std.format : format;
import rating;
import settings;

/// What the window's content does: views/main.xml says what it is.
@View("main.xml")
class HelloWorld
{
public:
    @xml Label label;
    @xml Rating stars;
    @xml Label ratingLabel;
    @xml Dock dock;
    @xml NavigationList nav;
    @xml Column home;
    SettingsPage settings;

    // Called once the view's built. The rating's score is observable, so the label can follow it:
    // bound, it changes whenever the score does, and Rating never needs to know it's there
    void initialise()
    {
        ratingLabel.textProperty.bind(stars.ratingProperty.map(
            (int n) => n ? format!"Rated %d out of %d"(n, stars.max) : "Not rated yet"));

        // The sidebar's entries, Home and Settings, each show their page beside it
        settings = new SettingsPage;
        nav.selectedIndexProperty.addListener((int was, int now) {
            dock.setCentre(now == 0 ? cast(Widget) home : settings);
        });
    }

private:
    void sayHello()
    {
        label.setText("Asking…");
        // The request blocks until the server answers, so it runs on a thread of its own and the
        // window carries on drawing. Widgets belong to the UI thread, so the answer goes back to
        // it through runLater rather than being set from here.
        new Thread({
            string result;
            try
            {
                auto http = HTTP();
                http.operationTimeout = 10.seconds;
                get("https://example.com", http); // throws on a network error or a non-2xx status
                result = "It's good";
            }
            catch (Exception e)
                result = "Something went wrong";
            Platform.runLater({ label.setText(result); });
        }).start();
    }
}

void main()
{
    auto app = new App("Hello world");
    auto view = View.load(new HelloWorld);
    app.scene = new Scene(view);
    app.run();
}
