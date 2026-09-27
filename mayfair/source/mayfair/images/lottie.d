module mayfair.images.lottie;

/*
    What Mayfair needs to know about a Lottie file that ThorVG doesn't say: which of its slots are
    colours.

    A slot is a property the file's author has given an id -- `"sid": "ring"` -- so a player can
    set it from outside. ThorVG applies them, but has no way to list them, and a colour has to be
    handed over as a colour: so the file is scanned for them here, once. A colour slot is one on a
    fill's or a stroke's colour, which Lottie keys "c":

        {"ty": "fl", "c": {"a": 0, "k": [0.2, 0.4, 0.8, 1], "sid": "ring"}, ...}

    The scan is a JSON tokenizer and nothing more -- it doesn't build the document, which for a
    big animation would be megabytes of objects to find a handful of strings -- tracking only the
    key each object is under.
*/

/// The ids of the colour slots in `json`, a Lottie file, each once, in the order they're first found.
string[] lottieColourSlots(const(char)[] json) pure @safe
{
    string[] found;
    // The key each open object or array is the value of: "c" for a colour property
    const(char)[][] under;
    const(char)[] pendingKey; // the key just read, waiting for its value
    size_t i;

    // Reads the string starting at json[i], which is a quote; leaves i after the closing quote
    const(char)[] readString()
    {
        const start = ++i;
        bool escaped;
        while (i < json.length && (json[i] != '"' || escaped))
        {
            escaped = !escaped && json[i] == '\\';
            i++;
        }
        const s = json[start .. i < json.length ? i : $];
        i++;
        return s;
    }

    bool expectingKey; // inside an object, before a colon
    bool[] inObject;
    while (i < json.length)
    {
        const ch = json[i];
        switch (ch)
        {
            case '{':
            case '[':
                under ~= pendingKey;
                inObject ~= ch == '{';
                pendingKey = null;
                expectingKey = ch == '{';
                i++;
                break;
            case '}':
            case ']':
                if (under.length)
                {
                    under = under[0 .. $ - 1];
                    inObject = inObject[0 .. $ - 1];
                }
                expectingKey = false;
                i++;
                break;
            case ',':
                expectingKey = inObject.length && inObject[$ - 1];
                pendingKey = null;
                i++;
                break;
            case ':':
                expectingKey = false;
                i++;
                break;
            case '"':
                const s = readString();
                if (expectingKey)
                    pendingKey = s;
                else if (pendingKey == "sid" && under.length && under[$ - 1] == "c")
                {
                    bool seen;
                    foreach (f; found)
                        seen = seen || f == s;
                    if (!seen)
                        found ~= s.idup;
                }
                break;
            default:
                i++; // a number, true, false, null, or white space
        }
    }
    return found;
}

unittest
{
    // The fill's and the stroke's colours are slots; the position's isn't a colour, and a string
    // value that happens to be "sid" isn't a key
    const json = `{"v":"5.7","nm":"sid","layers":[{"ty":4,"ks":{"p":{"a":0,"k":[1,2],"sid":"where"}},
        "shapes":[{"ty":"gr","it":[{"ty":"fl","c":{"a":0,"k":[0.1,0.2,0.3,1],"sid":"ring"}},
                                   {"ty":"st","c":{"a":1,"k":[{"t":0,"s":[1,0,0,1]}],"sid":"edge \"x\""}},
                                   {"ty":"fl","c":{"sid":"ring","a":0,"k":[0,0,0,1]}}]}]}]}`;
    assert(lottieColourSlots(json) == ["ring", `edge \"x\"`], "each colour slot once, escapes left as they are");
    assert(lottieColourSlots(`{"layers":[]}`).length == 0);
    assert(lottieColourSlots(`{"c":{"sid":`).length == 0, "cut short: nothing, and no crash");
}
