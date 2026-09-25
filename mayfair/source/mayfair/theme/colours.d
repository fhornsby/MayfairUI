module mayfair.theme.colours;
import core.time : Duration, msecs;
import mayfair.theme : Colour;

struct Theme
{
    @disable this();   // namespace only, never instantiated

    enum Colour background_colour = Colour(15, 23, 42);
    enum Colour text_colour       = Colour(226, 232, 240);
    enum Colour accent_colour     = Colour(56, 189, 248);
    enum Colour border_colour     = Colour(51, 65, 85, 200);

    enum float text_size = 14;     // points, for text not given a font of its own

    enum Colour button_colour         = Colour(51, 65, 85);
    enum Colour button_hover_colour   = Colour(71, 85, 105);
    enum Colour button_pressed_colour = Colour(30, 41, 59);
    enum Colour button_text_colour    = text_colour;
    // A default button -- the one Enter presses -- is drawn in the accent, so it's clear which that is
    enum Colour default_button_colour         = Colour(2, 132, 199);
    enum Colour default_button_hover_colour   = Colour(14, 165, 233);
    enum Colour default_button_pressed_colour = Colour(3, 105, 161);
    enum float button_radius          = 8;     // points
    enum float button_padding_x       = 16;
    enum float button_padding_y       = 8;
    enum float button_press_shrink    = 0.04;  // how much smaller a button is while held down
    enum Duration button_hover_time   = 150.msecs;
    enum Duration button_press_time   = 90.msecs;

    enum Colour focus_ring_colour     = accent_colour;
    enum float focus_ring_width       = 2;     // points
    enum Duration focus_ring_time     = 120.msecs;

    enum float disabled_opacity       = 0.4;   // how much of a disabled control still shows

    enum Colour text_field_colour        = Colour(30, 41, 59);
    enum Colour text_field_border_colour = Colour(71, 85, 105);
    enum Colour text_field_hover_colour  = Colour(100, 116, 139); // the border, with the pointer over it
    enum Colour prompt_text_colour       = Colour(148, 163, 184); // what an empty field shows as a hint
    enum Colour selection_colour         = Colour(56, 189, 248, 90);
    enum float text_field_width          = 200;  // points, before any growing or shrinking
    enum float text_field_padding_x      = 10;
    enum float text_field_padding_y      = 7;
    enum float text_field_radius         = 6;
    enum float caret_width               = 1.5;
    enum Duration caret_blink_time       = 1000.msecs; // one on and one off
    enum int caret_blink_count           = 10;  // blinks before it holds still, as GNOME's does
    enum int undo_limit                  = 100; // edits a text field remembers
}
