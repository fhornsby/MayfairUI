import std.stdio : writeln;
import mayfair;
import mayfair.terminal;

/*
    A window with a terminal in it, running the user's shell, or what's given:

        dub run                     the shell
        dub run -- htop             a program, and its arguments
*/
void main(string[] args)
{
    auto app = new App("Terminal");
    auto terminal = new Terminal(args[1 .. $]).grow(1);
    terminal.onExited((int status) {
        writeln("exited with ", status);
        App.quit();
    });
    app.scene = new Scene(terminal);
    terminal.requestFocus();
    app.run();
}
