module mayfair.theme.oriel;

import mayfair.css.stylesheet : Stylesheet, stylesheet;

/*
    The look of the Oriel desktop's apps, as a stylesheet over Mayfair's own (themes/oriel.css):
    its palette, light and dark, its traffic lights, and frosted-glass sidebars running up behind
    the title bar.

        auto scene = new Scene(root).titleBar(titleBar);
        scene.stylesheets.add(orielStylesheet);   // on the scene, so the title bar has it too
        titleBar.setSidebar(sidebar);             // the sidebar, given .sidebar, which the bar follows
        app.setTranslucent(true);                 // glass where the compositor blurs; opaque elsewhere
*/
Stylesheet orielStylesheet()
{
    return stylesheet!(import("oriel.css"));
}
