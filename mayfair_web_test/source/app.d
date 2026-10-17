import mayfair;
import std.conv : to;

/// What the page does: views/main.xml says what it is.
@View("main.xml")
class Main
{
    @xml Label status;
    private int clicks;

    private void clicked()
    {
        status.setText("Clicked " ~ (++clicks).to!string ~ " times");
    }
}

void main()
{
    auto app = new App("Mayfair Webapp");
    app.scene = new Scene(View.load(new Main));
    app.run();
}
