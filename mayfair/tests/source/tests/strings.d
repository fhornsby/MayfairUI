module tests.strings;

import harness;
import mayfair;
import mayfair.xml.view : buildText;

/*
    The app's strings, from assets/values/strings.xml and its French translation: in a view, in
    code, and in @localised fields, in whichever language is chosen.
*/

class Greeting
{
    @xml Label hello;
    @xml Button save;
    @xml ComboBox sizes;
    @xml Label percent;
    @localised string farewell;
    @Localised("hello") string title;
}

private enum view = `<Column spacing="8">
    <Label id="hello" text="%hello"/>
    <Button id="save">%save</Button>
    <ComboBox id="sizes" items="%small 'Extra large' %large"/>
    <Label id="percent" text="\%100"/>
</Column>`;

/// The same view loaded in English and in French, side by side.
void translations()
{
    Greeting english, french;
    run("strings: in a view, in code and in fields, in English and French", {
        setLanguage("en-GB");
        english = new Greeting;
        auto root = new Row().spacing(24);
        root.add(buildText!(view, "greeting.xml", Greeting)(english));
        setLanguage("fr-CA"); // there's no fr-CA, so fr
        french = new Greeting;
        root.add(buildText!(view, "greeting.xml", Greeting)(french));
        return cast(Widget) root;
    }, (Driver d) {
        d.ui({
            d.expect(english.hello.text, "Hello", "%hello in an attribute");
            d.expect(english.save.text, "Save", "%save as the text in an element");
            d.expect(english.sizes.items, ["Small", "Extra large", "Large"], "%small and %large among an array's items");
            d.expect(english.percent.text, "%100", "\\% for text that starts with a %");
            d.expect(english.farewell, "Goodbye", "a @localised field, by its name");
            d.expect(english.title, "Hello", "a @Localised field, by the name it's given");

            d.expect(french.hello.text, "Bonjour", "the view loaded in French");
            d.expect(french.save.text, "Enregistrer");
            d.expect(french.sizes.items, ["Petit", "Extra large", "Grand"]);
            d.expect(french.title, "Bonjour");
            d.expect(french.farewell, "Goodbye", "a string French doesn't have is shown in English");

            d.expect(currentLanguage, "fr", "fr-CA asked for, and fr shown");
            d.expect(tr!"welcome"("Ann"), "Bon retour, Ann", "tr! filling in {0}");
            d.expect(tr!"moved"("Documents", 3), "3 fichiers déplacés vers Documents", "a translation's {n} in its own order");
            d.check(french.hello.boundsInScene.width > 0, "the French is laid out");

            setLanguage("de"); // no German: the default
            d.expect(currentLanguage, "en-GB", "a language with no translation shows values/strings.xml's");
            d.expect(tr!"moved"("Documents", 3), "Moved 3 files to Documents");
            setLanguages(null); // back to the environment's
        });
    });
}
