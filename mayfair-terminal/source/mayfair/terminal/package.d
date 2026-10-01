/*
    A terminal emulator widget, for Mayfair: see Terminal. A library of its own beside Mayfair's
    rather than one of its widgets, as GNOME's VTE is beside GTK, since it brings a native library
    of its own with it, built from Rust (see native/).

        import mayfair;
        import mayfair.terminal;

        auto shell = new Terminal().grow(1);
*/
module mayfair.terminal;

public import mayfair.terminal.terminal;
