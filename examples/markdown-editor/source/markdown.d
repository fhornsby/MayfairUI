module markdown;

/*
    A small Markdown to HTML converter, enough for the editor's preview: headings, paragraphs,
    emphasis, code spans and fenced blocks, links, pictures, lists, quotes and rules.
*/

import std.algorithm : startsWith, all;
import std.array : appender, Appender;
import std.ascii : isDigit;
import std.string : strip, stripLeft, splitLines, indexOf;

string toHtml(string markdown)
{
    auto html = appender!string;
    string[] paragraph;
    string list; // "ul", "ol" or null
    bool quote, fenced;

    void closeParagraph()
    {
        if (!paragraph.length)
            return;
        html ~= "<p>";
        foreach (i, line; paragraph)
        {
            if (i)
                html ~= "\n";
            html ~= inline(line);
        }
        html ~= "</p>\n";
        paragraph = null;
    }

    void closeList()
    {
        if (list)
            html ~= "</" ~ list ~ ">\n";
        list = null;
    }

    void closeQuote()
    {
        if (quote)
            html ~= "</blockquote>\n";
        quote = false;
    }

    void closeAll()
    {
        closeParagraph();
        closeList();
        closeQuote();
    }

    foreach (raw; markdown.splitLines)
    {
        if (fenced)
        {
            if (raw.strip.startsWith("```"))
            {
                html ~= "</code></pre>\n";
                fenced = false;
            }
            else
                html ~= escape(raw) ~ "\n";
            continue;
        }

        auto line = raw.stripLeft;
        if (line.startsWith("```"))
        {
            closeAll();
            html ~= "<pre><code>";
            fenced = true;
            continue;
        }
        if (!line.length)
        {
            closeAll();
            continue;
        }

        if (line.startsWith(">"))
        {
            closeParagraph();
            closeList();
            if (!quote)
                html ~= "<blockquote>\n";
            quote = true;
            line = line[1 .. $].stripLeft;
            if (!line.length)
                continue;
        }
        else if (quote && !paragraph.length)
            closeQuote();

        int level;
        while (level < line.length && level < 6 && line[level] == '#')
            level++;
        if (level && (line.length == level || line[level] == ' '))
        {
            closeParagraph();
            closeList();
            const tag = "h" ~ cast(char)('0' + level);
            html ~= "<" ~ tag ~ ">" ~ inline(line[level .. $].strip) ~ "</" ~ tag ~ ">\n";
            continue;
        }

        if (line.length >= 3 && (line.all!(c => c == '-' || c == ' ') || line.all!(c => c == '*' || c == ' '))
            && !paragraph.length)
        {
            closeList();
            html ~= "<hr>\n";
            continue;
        }

        string item, kind;
        if (line.length > 1 && (line[0] == '-' || line[0] == '*' || line[0] == '+') && line[1] == ' ')
        {
            kind = "ul";
            item = line[2 .. $];
        }
        else
        {
            size_t d;
            while (d < line.length && line[d].isDigit)
                d++;
            if (d && d + 1 < line.length && (line[d] == '.' || line[d] == ')') && line[d + 1] == ' ')
            {
                kind = "ol";
                item = line[d + 2 .. $];
            }
        }
        if (kind)
        {
            closeParagraph();
            if (list != kind)
            {
                closeList();
                html ~= "<" ~ kind ~ ">\n";
                list = kind;
            }
            html ~= "<li>" ~ inline(item.strip) ~ "</li>\n";
            continue;
        }

        closeList();
        paragraph ~= line;
    }
    if (fenced)
        html ~= "</code></pre>\n";
    closeAll();
    return html[];
}

private:

string escape(string text)
{
    auto result = appender!string;
    foreach (c; text)
    {
        switch (c)
        {
        case '&': result ~= "&amp;"; break;
        case '<': result ~= "&lt;"; break;
        case '>': result ~= "&gt;"; break;
        case '"': result ~= "&quot;"; break;
        default: result ~= c;
        }
    }
    return result[];
}

/// Code spans, pictures, links, strong and emphasis, within one line.
string inline(string text)
{
    auto result = appender!string;
    size_t i;
    while (i < text.length)
    {
        const c = text[i];
        const rest = text[i .. $];

        if (c == '\\' && i + 1 < text.length)
        {
            result ~= escape(text[i + 1 .. i + 2]);
            i += 2;
            continue;
        }
        if (c == '`')
        {
            const end = text[i + 1 .. $].indexOf('`');
            if (end >= 0)
            {
                result ~= "<code>" ~ escape(text[i + 1 .. i + 1 + end]) ~ "</code>";
                i += end + 2;
                continue;
            }
        }
        if (c == '[' || (c == '!' && rest.startsWith("![")))
        {
            const picture = c == '!';
            const open = i + (picture ? 1 : 0);
            const close = text[open .. $].indexOf("](");
            if (close >= 0)
            {
                const labelEnd = open + close;
                const urlEnd = text[labelEnd + 2 .. $].indexOf(')');
                if (urlEnd >= 0)
                {
                    const label = text[open + 1 .. labelEnd];
                    const url = escape(text[labelEnd + 2 .. labelEnd + 2 + urlEnd]);
                    if (picture)
                        result ~= `<img src="` ~ url ~ `" alt="` ~ escape(label) ~ `">`;
                    else
                        result ~= `<a href="` ~ url ~ `">` ~ inline(label) ~ "</a>";
                    i = labelEnd + 2 + urlEnd + 1;
                    continue;
                }
            }
        }
        if (c == '*' || c == '_')
        {
            const marker = rest.length > 1 && rest[1] == c ? text[i .. i + 2] : text[i .. i + 1];
            const end = text[i + marker.length .. $].indexOf(marker);
            if (end > 0)
            {
                const tag = marker.length == 2 ? "strong" : "em";
                result ~= "<" ~ tag ~ ">" ~ inline(text[i + marker.length .. i + marker.length + end])
                    ~ "</" ~ tag ~ ">";
                i += marker.length * 2 + end;
                continue;
            }
        }
        result ~= escape(text[i .. i + 1]);
        i++;
    }
    return result[];
}

unittest
{
    assert(toHtml("# Hi") == "<h1>Hi</h1>\n");
    assert(toHtml("a **b** *c* `d`") == "<p>a <strong>b</strong> <em>c</em> <code>d</code></p>\n");
    assert(toHtml("- one\n- two") == "<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n");
    assert(toHtml("1. one") == "<ol>\n<li>one</li>\n</ol>\n");
    assert(toHtml("[x](y)") == `<p><a href="y">x</a></p>` ~ "\n");
    assert(toHtml("```\n<a>\n```") == "<pre><code>&lt;a&gt;\n</code></pre>\n");
    assert(toHtml("> q") == "<blockquote>\n<p>q</p>\n</blockquote>\n");
}
