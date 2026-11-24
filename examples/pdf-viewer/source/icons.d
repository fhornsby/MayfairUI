module icons;

/*
    The markup toolbar's icons that desktop themes don't have -- a highlighter, a pen, shapes, a
    crop, a signature, a note, a region -- drawn here, 16 by 16, as symbolic icons are: Icon
    colours them as the text round them.
*/

import mayfair;

Icon svgIcon(string svg) { return new Icon(Image.fromData(svg, "icon.svg")); }

private enum open = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">`;

enum highlighterIcon = open ~ `<path d="M10 1.5l4.5 4.5-6.5 6.5-4.5-4.5z" fill="none" stroke="#000" stroke-width="1.4" stroke-linejoin="round"/><path d="M3.5 8l4.5 4.5-1.5 1.5h-4.5v-1z" fill="#000"/><rect x="9" y="14.4" width="6" height="1.4" fill="#000"/></svg>`;

enum penIcon = open ~ `<path d="M11.5 1.5l3 3-9 9-4 1 1-4z" fill="none" stroke="#000" stroke-width="1.4" stroke-linejoin="round"/><path d="M9.5 3.5l3 3" stroke="#000" stroke-width="1.4"/></svg>`;

enum shapesIcon = open ~ `<rect x="1.5" y="1.5" width="8" height="8" rx="1" fill="none" stroke="#000" stroke-width="1.4"/><circle cx="10.5" cy="10.5" r="4" fill="none" stroke="#000" stroke-width="1.4"/></svg>`;

enum cropIcon = open ~ `<path d="M4 1v11h11" fill="none" stroke="#000" stroke-width="1.5"/><path d="M1 4h11v11" fill="none" stroke="#000" stroke-width="1.5"/></svg>`;

enum signatureIcon = open ~ `<path d="M1.5 11c2-5 3.5-8 4.5-7s-2 8-1 8 2.5-4 3.5-4-0.5 3 0.5 3 2-1.5 3.5-2" fill="none" stroke="#000" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/><path d="M1 14.5h14" stroke="#000" stroke-width="1.2"/></svg>`;

enum noteIcon = open ~ `<path d="M2 2h12v8l-4 4h-8z" fill="none" stroke="#000" stroke-width="1.4" stroke-linejoin="round"/><path d="M14 10h-4v4" fill="none" stroke="#000" stroke-width="1.4" stroke-linejoin="round"/><path d="M4.5 5.5h7M4.5 8h4" stroke="#000" stroke-width="1.2"/></svg>`;

enum regionIcon = open ~ `<rect x="2" y="2" width="12" height="12" fill="none" stroke="#000" stroke-width="1.4" stroke-dasharray="2.5 2"/></svg>`;

enum textBoxIcon = open ~ `<rect x="1.5" y="2.5" width="13" height="11" rx="1" fill="none" stroke="#000" stroke-width="1.3"/><path d="M5 5.5h6M8 5.5v6" stroke="#000" stroke-width="1.5"/></svg>`;

enum lineWidthIcon = open ~ `<rect x="2" y="3" width="12" height="1" fill="#000"/><rect x="2" y="6.5" width="12" height="2" fill="#000"/><rect x="2" y="11" width="12" height="3" fill="#000"/></svg>`;

enum textSizeIcon = open ~ `<path d="M1.5 13l3-9h1l3 9M2.7 10h4.6" fill="none" stroke="#000" stroke-width="1.3"/><path d="M9.5 13l2.2-6h.6l2.2 6M10.3 11h3.4" fill="none" stroke="#000" stroke-width="1.1"/></svg>`;

enum markupIcon = open ~ `<path d="M2 14l1-4 8-8 3 3-8 8z" fill="none" stroke="#000" stroke-width="1.4" stroke-linejoin="round"/><circle cx="12.5" cy="12.5" r="2.5" fill="#000"/></svg>`;

enum selectTextIcon = open ~ `<path d="M5 2.5h6M5 13.5h6M8 2.5v11" stroke="#000" stroke-width="1.4"/></svg>`;

/// A square of `colour`, for a colour button: crossed out for none.
string swatchSvg(PdfColourHex colour)
{
    if (colour.none)
        return open ~ `<rect x="1.5" y="1.5" width="13" height="13" rx="2" fill="none" stroke="#000" stroke-width="1.2"/><path d="M3 13L13 3" stroke="#000" stroke-width="1.4"/></svg>`;
    return open ~ `<rect x="1" y="1" width="14" height="14" rx="2" fill="` ~ colour.hex ~ `"/></svg>`;
}

/// A colour as an SVG has it.
struct PdfColourHex
{
    string hex;
    bool none;
}
