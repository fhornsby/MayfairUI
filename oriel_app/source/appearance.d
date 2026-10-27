module appearance;

import mayfair;

/*
    The sidebar's second page, laid out in views/appearance.xml: whether the window's frosted
    glass right now. The scene says, in its translucentProperty, which follows the compositor's
    blur as it comes and goes: turn Translucency off in Oriel Settings and the page changes along
    with the window.
*/
@View("appearance.xml")
class AppearancePage : Column
{
public:
    this()
    {
        View.load(this);
    }

    /// Says whether `scene`, the window's, is translucent, from now on.
    void follow(Scene scene)
    {
        status.textProperty.bind(scene.translucentProperty.map((bool on) => on
            ? "Frosted glass is on: Oriel blurs the desktop behind this window."
            : "Frosted glass is off, so the window is opaque."));
    }

private:
    @xml Label status;
}
