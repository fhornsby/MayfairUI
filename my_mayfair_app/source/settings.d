module settings;

import mayfair;
import details;

/*
    The sidebar's second page, laid out in views/settings.xml: a button that goes from the window's
    page, sidebar and all, to a page of its own, DetailsPage.
*/
@View("settings.xml")
class SettingsPage : Column
{
public:
    this()
    {
        View.load(this);
    }

private:
    void openDetails()
    {
        scene.setRoot(new DetailsPage(scene.root));
    }
}
