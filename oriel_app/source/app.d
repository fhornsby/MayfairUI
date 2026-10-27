/*
    A hello world for the Oriel desktop, the Mayfair twin of the Oriel app template
    (OrielAvaloniaTemplate): the look of Oriel Files and Oriel Settings, with the traffic lights at
    the top right and light and dark following the desktop, and a sidebar of frosted glass where
    Oriel blurs what's behind the window, running up behind the title bar as macOS's do. Where nothing blurs -- Translucency off in Oriel Settings, or a
    desktop that doesn't offer blur over ext-background-effect-v1 -- it's an ordinary opaque
    window, and it goes from one to the other as it runs.

    views/main.xml is the window below its title bar, and views/oriel.css its look.
*/
module app;

import mayfair;
import appearance;

/// What the window's content does: views/main.xml says what it is.
@View("main.xml")
class MainWindow
{
public:
    @xml Dock dock;
    @xml NavigationList nav;
    @xml Column welcome;
    @xml Label greeting;
    AppearancePage appearance;

    // Called once the view's built. The sidebar's entries each show their page beside it
    void initialise()
    {
        appearance = new AppearancePage;
        nav.selectedIndexProperty.addListener((int was, int now) {
            dock.setCentre(now == 0 ? cast(Widget) welcome : appearance);
        });
    }

private:
    void sayHello()
    {
        greeting.setVisible(true);
    }
}

void main()
{
    auto app = new App("Oriel App");
    app.setSize(640, 400);
    auto window = new MainWindow;
    auto scene = new Scene(View.load(window));
    // A title bar of its own, as the Oriel apps have: the traffic lights, and the sidebar's glass at its start
    scene.titleBar(new TitleBar);
    // On the scene rather than the root, so the title bar's styled by it too
    scene.stylesheets.add(stylesheet!(import("oriel.css")));
    window.appearance.follow(scene);
    app.setTranslucent(true); // where the compositor blurs what's behind it, which Oriel does
    app.scene = scene;
    app.run();
}
