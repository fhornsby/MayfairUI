module details;

import mayfair;

/*
    A page of the whole window, laid out in views/details.xml, with a button back to the one it
    took the place of. That one's kept as it was, so back is just where it was left: the
    sidebar on the same page, the counter at the same count.
*/
@View("details.xml")
class DetailsPage : Column
{
public:
    /// A page in place of `previous`, the window's root, which Back shows again.
    this(Widget previous)
    {
        this.previous = previous;
        View.load(this);
    }

private:
    Widget previous;

    void back()
    {
        scene.setRoot(previous);
    }
}
