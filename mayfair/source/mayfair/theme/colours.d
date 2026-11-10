module mayfair.theme.colours;
import core.time : Duration, msecs;
import mayfair.theme : Colour;

struct Theme
{
    @disable this();   // namespace only, never instantiated

    // How things look is the built-in stylesheet's (themes/mayfair.css); what's here is how they
    // behave, and the few values something needs before any stylesheet has been applied
    enum Colour background_colour = Colour(15, 23, 42);    // behind the scene, under the root's own background
    enum Colour text_colour       = Colour(226, 232, 240); // text, before it's styled
    enum float text_size = 14;     // points, for text not given a font of its own
    enum float text_gamma = 2.2;   // how much light text's edges are lifted: see mayfair.text.raster
    // How much the stems of text that's hard to see are thickened: see mayfair.text.raster
    enum float text_darkening = 0.375;         // pixels, at most
    enum float text_darkening_contrast = 80;   // L* apart from what's behind it, from which none
    enum float text_darkening_full = 35;       // and at which all of it
    enum float text_darkening_ppem = 16;       // pixels to the em up to which all of it, none from twice it

    // Garbage collection, which the app's loop does between frames: see App.collectGarbage
    enum size_t gc_min_growth = 1 << 20;  // bytes allocated since the last collection before the next is worth it
    enum size_t gc_max_growth = 64 << 20; // bytes allocated before one's worth a frame, while animating

    enum Duration button_press_time   = 90.msecs;  // how long Enter or Escape shows a button pressed

    enum float text_field_width          = 200;  // points, before any growing or shrinking
    enum float caret_width               = 1.5;
    enum Duration caret_blink_time       = 1000.msecs; // one on and one off
    enum int caret_blink_count           = 10;  // blinks before it holds still, as GNOME's does
    enum int undo_limit                  = 100; // edits a text field remembers

    // Scrolling. The bars are GNOME's overlay ones: thin, over the content, and only there while
    // something's happening. Their colours are the stylesheet's.
    enum float scroll_step               = 40;  // points per notch of a wheel, as JavaFX's
    enum float scroll_bar_thin           = 3;   // points across, while it only shows where you are
    enum float scroll_bar_wide           = 8;   // points across, with the pointer over it to take hold of
    enum float scroll_bar_margin         = 3;   // points between a bar and the edge it runs along
    enum float scroll_bar_reach          = 14;  // points in from the edge the pointer takes hold of a bar in
    enum float scroll_bar_min_length     = 24;  // points: the least a thumb shrinks to, however long the content
    enum Duration scroll_bar_fade_time   = 200.msecs;
    enum Duration scroll_bar_widen_time  = 100.msecs;
    enum Duration scroll_bar_linger_time = 1000.msecs; // shown after the last scroll or movement
    enum float scroll_ease_time          = 0.045; // seconds: how quickly a wheel's notch is eased into
    enum float scroll_glide_time         = 0.325; // seconds: how quickly a touchpad's momentum dies away
    enum Duration scroll_lift_time       = 45.msecs; // no touchpad movement for this long: the fingers lifted
    enum float scroll_glide_min_speed    = 120;   // points a second: slower than this, lifting just stops
    enum float scroll_glide_max_speed    = 8000;  // points a second: the fastest a glide starts
    enum Duration popup_fade_time        = 120.msecs; // a popup fading in
    enum Colour popup_scrim              = Colour(0, 0, 0, 90); // over the window behind a modal popup
    enum Colour popup_shadow             = Colour(0, 0, 0, 70);
    enum float popup_shadow_blur         = 10;   // points
    enum float popup_shadow_offset       = 3;    // points down
    enum float popup_margin              = 8;    // points a popup keeps from the window's edges, if it can
    enum float window_margin             = 32;   // points round a window drawing its own frame, for its shadow
    enum float window_radius             = 12;   // points: its corners
    enum float window_resize_band        = 8;    // points outside its edge that take hold of it to size it
    enum Colour window_shadow            = Colour(0, 0, 0, 150);
    enum Colour window_shadow_backdrop   = Colour(0, 0, 0, 85); // without focus
    enum float window_shadow_blur        = 9;  // points: the blur's sigma, its shadow three times as wide
    enum float window_shadow_offset      = 4;    // points down
    enum Colour window_outline           = Colour(0, 0, 0, 36);
    enum Colour window_outline_dark      = Colour(255, 255, 255, 28);
    enum Duration tooltip_delay          = 500.msecs;  // resting on something before its tooltip shows
    enum Duration tooltip_browse_time    = 800.msecs;  // after one hides, the next shows at once for this long
    enum float tooltip_max_width         = 320;  // points: longer tooltips wrap
    enum Duration submenu_delay          = 200.msecs;  // resting on a menu's item before its submenu opens, or another closes
}
