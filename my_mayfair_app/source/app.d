import mayfair;
import core.thread : Thread;
import core.time : seconds;
import std.net.curl : get, HTTP;
import std.format : format;
import rating;

/// What the window's content does: views/main.xml says what it is.
@View("main.xml")
class HelloWorld
{
public:
    @xml Label label;
    @xml Rating stars;
    @xml Label ratingLabel;

    // Called once the view's built. The rating's score is observable, so the label can follow it:
    // bound, it changes whenever the score does, and Rating never needs to know it's there
    void initialise()
    {
        ratingLabel.textProperty.bind(stars.ratingProperty.map(
            (int n) => n ? format!"Rated %d out of %d"(n, stars.max) : "Not rated yet"));
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
    app.scene = new Scene(View.load(new HelloWorld));
    app.setTranslucent(true); // where the compositor blurs what's behind it
    app.setAssumesBlur(true); // which ours does, by its own rule rather than over a protocol
    app.run();
}
