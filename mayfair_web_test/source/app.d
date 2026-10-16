import mayfair;

void main()
{
    auto status = new Label("Hello from Mayfair, in a browser");
    auto column = View.parse!(`<Column spacing="12" alignment="centre" padding="24">
        <Button text="Click me"/>
        <CheckBox text="A check box"/>
        <Slider/>
    </Column>`)();
    column.add(status);
    int clicks;
    (cast(Button) column.children[0]).onAction({ status.setText("Clicked " ~ (++clicks).to!string ~ " times"); });
    auto app = new App("Mayfair in a browser");
    app.scene = new Scene(column);
    app.run();
}
import std.conv : to;
