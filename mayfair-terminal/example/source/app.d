import std.stdio : writeln;
import mayfair;
import mayfair.terminal;

/*
    A window with a terminal in it, running the user's shell, or what's given:

        dub run                     the shell
        dub run -- htop             a program, and its arguments
*/

/*
    The title bar: the window's name, and the switch between light and dark at the end. Given
    to the scene, it makes the window draw its own decorations.
*/
TitleBar buildTitleBar(Scene scene)
{
    auto dark = new ToggleButton("Dark").graphic(new Icon("weather-clear-night-symbolic"))
        .tooltip("Switch between light and dark");
    dark.setOnAction({
        scene.setColourScheme(dark.selected ? ColourScheme.dark : ColourScheme.light);
    });
    return new TitleBar("Terminal").addEnd(dark);
}

void main(string[] args)
{
    auto app = new App("Terminal");
    auto terminal = new Terminal(args[1 .. $]).grow(1);
    terminal.onExited((int status) {
        writeln("exited with ", status);
        App.quit();
    });
    auto scene = new Scene(terminal);
    app.scene = scene.titleBar(buildTitleBar(scene));
    terminal.requestFocus();
    app.run();
}
