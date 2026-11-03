module rating;

import mayfair;

/*
    A score out of some number of stars, set by clicking one -- clicking the score's own star
    again takes it back to none. Made in code, like Counter, but its properties are observable:
    besides setRating() and setMax(), which a view sets them with, ratingProperty and maxProperty
    can be listened to and bound, so other things can follow the score without it knowing they're
    there.

        <Rating rating="3" max="5"/>

        label.textProperty.bind(stars.ratingProperty.map((int n) => format!"%d stars"(n)));
*/
class Rating : Row
{
public:
    mixin Properties;

    this()
    {
        setSpacing(2);
        setAlignment(Pos.centre);
        maxChanged();
    }

protected:
    // Only as wide as what's in it, as a button is, so the layout it's in decides where it sits
    override float computeMaxWidth() const nothrow @nogc { return usePrefSize; }

private:
    @observable int _rating;    /// How many stars it's given, from 0
    @observable int _max = 5;   /// How many stars there are to give

    Button[] stars;

    // Called by the properties when they change, however they're set
    void maxChanged()
    {
        foreach (star; stars)
            remove(star);
        stars = null;
        foreach (i; 0 .. _max)
            stars ~= star(i + 1);
        if (_rating > _max)
            setRating(_max); // which shows it
        else
            ratingChanged();
    }

    void ratingChanged()
    {
        foreach (i, star; stars)
            star.setText(i < _rating ? "★" : "☆");
    }

    // A star that gives `score`. A function of its own, so each click handler has its own score
    Button star(int score)
    {
        auto button = new Button().onAction({ setRating(score == _rating ? 0 : score); });
        button.setAccessibleText(score == 1 ? "1 star" : "%d stars".format(score));
        add(button);
        return button;
    }

    import std.format : format;
}
