import mayfair;
import editor;
import core.thread : Thread;
import core.time : seconds;
import std.net.curl : get, HTTP;
import std.format : format;


@View("main.xml")
class HelloWorld
{
public:
    @xml Label label;
    @xml Dock dock;
    @xml NavigationList nav;
    @xml Column home;

    // Called once the view's built. The rating's score is observable, so the label can follow it:
    // bound, it changes whenever the score does, and Rating never needs to know it's there
    void initialise()
    {

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


void main(string[] args)
{
    auto app = new App("OverBrief");
    app.setSize(1200, 780);
    // auto editor = new Editor(args.length > 1 ? args[1] : null);
    auto hello = new HelloWorld();
    auto view = View.load(hello);
    auto scene = new Scene(view);//.titleBar(editor.titleBar);
    scene.stylesheets.add(orielStylesheet);
    scene.stylesheets.add(stylesheet!editorStyle);
    app.scene = scene;
    app.setTranslucent(true);
    // app.window.onCloseRequest(() => editor.quitting());
    app.run();
}
