import mayfair;
import gallery;

/*
    Shows Mayfair's gallery: see gallery.d.

        dub run                   the first page
        dub run -- Layout         a page by name, to start on
*/
void main(string[] args)
{
    auto app = new App("Mayfair gallery");
    auto gallery = buildGallery(args.length > 1 ? args[1] : null);
    app.scene = new Scene(gallery).titleBar(buildTitleBar(gallery));
    app.run();
}
