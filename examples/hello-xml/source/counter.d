module counter;

import mayfair;
import std.conv : to;

/*
    A number, with buttons either side to take some off and add some on: a widget made in code,
    with no view of its own. A view sets it through its setters, as it would any widget's:

        <Counter count="3" step="5"/>

    which is setCount(3) and setStep(5). Plain methods are all a view needs; see ProfileCard for
    properties that other code can watch, too.
*/
class Counter : Row
{
public:
    this()
    {
        _value = new Label("0");
        setSpacing(8);
        setAlignment(Pos.centre);
        add(new Button("−").onAction({ setCount(_count - _step); }));
        add(_value);
        add(new Button("+").onAction({ setCount(_count + _step); }));
    }

    /// The number it shows.
    int count() const { return _count; }

    /// ditto
    void setCount(int count)
    {
        _count = count;
        _value.setText(count.to!string);
    }

    /// How much each button changes it by.
    void setStep(int step) { _step = step; }

protected:
    // Only as wide as what's in it, as a button is, so the layout it's in decides where it sits
    override float computeMaxWidth() const nothrow @nogc { return usePrefSize; }

private:
    Label _value;
    int _count;
    int _step = 1;
}
