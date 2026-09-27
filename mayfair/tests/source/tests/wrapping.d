module tests.wrapping;

import std.format : format;
import std.math : abs;
import harness;
import mayfair;

private enum text = "Wrapping text takes the width it's given and breaks where the text allows it to.";

/// A wrapping label: as many lines as its width needs, and one when there's room; the text's own
/// line breaks; wrapping from a stylesheet; and in a row, with a max width.
void labels()
{
    Column column;
    Label wrapped, lines, styled, inRow, hebrew;
    run("wrapping: labels", {
        auto root = new Column().fillWidth(false).spacing(10).padding(10);
        column = new Column().prefWidth(200);
        wrapped = new Label(text).wrapText(true);
        column.add(wrapped);
        lines = new Label("one\ntwo\nthree");
        styled = new Label(text).style("wrap-text: true; max-width: 150; line-spacing: 4");
        auto row = new Row();
        inRow = new Label(text).wrapText(true).maxWidth(120);
        row.add(inRow);
        hebrew = new Label("שלום עולם, זהו טקסט ארוך שנשבר לשורות").wrapText(true).maxWidth(100);
        root.add(column).add(lines).add(styled).add(row).add(hebrew);
        return cast(Widget) root;
    }, (Driver d) {
        // How many lines a label's height makes, from its font's line height and spacing
        size_t count(Label l, float spacing = 0)
        {
            const lh = l.font.lineHeight;
            return cast(size_t)((l.boundsInScene.height + spacing) / (lh + spacing) + 0.5);
        }
        d.ui({
            const b = wrapped.boundsInScene;
            d.check(b.width <= 200, format!"wrapped to its column: %s wide"(b.width));
            d.check(count(wrapped) >= 3, format!"on several lines: %s"(count(wrapped)));
            d.expect(count(lines), 3, "the text's own line breaks, without wrapping");
            d.check(styled.boundsInScene.width <= 150 && count(styled, 4) >= 3, "wrapping from a stylesheet, lines spaced");
            d.check(inRow.boundsInScene.width <= 120 && count(inRow) >= 3, "in a row, to its max width");
            d.check(hebrew.boundsInScene.width <= 100 && count(hebrew) >= 2, "right-to-left text wraps too");
        });

        // Room for it all: one line, as wide as the text
        d.ui({ column.setPrefWidth(2000); });
        d.settle();
        d.ui({
            d.expect(count(wrapped), 1, "one line when it fits");
            d.check(wrapped.boundsInScene.width > 400, "as wide as the text");
        });
    });
}
