# mayfair-code

Code editing for Mayfair. Mayfair's own [`TextView`](../mayfair/source/mayfair/widgets/textview.d)
is the editor widget, like GTK's `GtkTextView` with a `GtkTextBuffer`. This package adds what
makes it a code editor:

- **`SyntaxHighlighter`** colours a `TextBuffer` by its language as it's edited.
- **`LanguageServer`**, **`LspDocument`** and **`LspEditor`** connect it to a language server, the
  kind VS Code, Zed and Neovim use. That gives errors underlined as you type, completions, hovers,
  and going to a definition.

It has no libraries of its own: just Mayfair, and the language servers installed on the machine,
which it runs as separate programs. It's MIT licensed, like Mayfair.

```d
import mayfair;
import mayfair.code;

auto buffer = new TextBuffer(readText("app.py"));
auto view = new TextView(buffer).showLineNumbers(true);

// Highlighted by its language; and the view told the language's comment and indentation
auto highlighter = new SyntaxHighlighter(buffer, languageFor("app.py"));
highlighter.follow(view);

// Checked by a language server, if one for Python is installed
if (auto server = LanguageServer.forLanguage(languageFor("app.py"), projectFolder))
{
    auto document = new LspDocument(server, buffer, "app.py");
    auto editor = new LspEditor(document, view);
    editor.onGoToDefinition((Location l) { /* open l.path, and put the caret at l.position */ });
}
```

[`examples/code-editor`](../examples/code-editor) is a whole editor built this way.

## TextBuffer and TextView (in Mayfair itself)

These are in Mayfair, as GTK's are, so any app can use them without this package.

**`TextBuffer`** holds the text, a line at a time, so a long file is cheap to edit.

- **Undo and redo:** typing is merged into words. `beginUserAction` and `endUserAction` group
  edits into one step.
- **Modified state:** `modified` says whether it differs from what was last saved.
- **Change events:** each says what was replaced and with what.
- **Marks:** `TextMark`s keep their place as text is inserted before them.
- **Tags:** `TextTag`s colour, embolden, strike through or underline a range (`squiggle` for
  errors). Highlights are tags kept apart from the app's own, so rehighlighting never touches
  those.
- **Search:** finding by case and whole word.
- **Line endings:** a file's CRLF line endings are kept when it's saved.

**`TextView`** edits a buffer.

- **Drawing:** only the lines on screen are drawn, so a 100,000-line file scrolls and types as
  quickly as a short one.
- **Gutter:** line numbers, and marks beside lines.
- **Current line and brackets:** the caret's line is highlighted, and its bracket's partner is
  matched.
- **Indentation:** a new line is auto-indented. Tab and Shift+Tab indent and outdent a selection,
  and Backspace takes away a whole indent.
- **Line editing:** Alt+Up and Alt+Down move lines, Ctrl+Shift+K deletes them, and Ctrl+/
  comments them out.
- **Word editing:** Ctrl+arrows move by words, and Ctrl+Backspace deletes them.
- **Mouse:** a double click selects a word and a triple click a line. On Linux, selecting sets
  the primary selection and the middle button pastes it.
- **Find and replace,** with every match highlighted.
- **Input methods:** composing in place, for Chinese, Japanese and Korean, say.
- **Hooks:** key filters and hover handlers let packages like this one add to it.

## Highlighting

Each language is described by data in `language.d`: its keywords, types, constants and built-ins,
its comments, its strings and their escapes, and a few flags. Examples of the flags are "a word
starting with a capital is a type", "`key:` is a property" and "`#` starts a preprocessor line".

A line is scanned with the state the line before left it in: inside a block comment (nested, for
D's `/+ +/` and Rust's), a multi-line string, a Markdown code fence, or an HTML tag. An edit
rescans from the line it's on until a line ends in the same state as before. Typing usually costs
one line. Opening a `/*` costs the lines down to where it's closed. A file opened is highlighted
in slices between frames, so a large one shows at once and fills in its colours as it goes.

There are 25 languages:

- **Programming languages:** D, C, C++, C#, Java, JavaScript, TypeScript, Python, Rust, Go, Ruby
  and Lua.
- **Shell and build files:** shell scripts, Makefiles and Dockerfiles.
- **Data and configuration:** JSON, YAML, TOML and INI.
- **Markup and styles:** CSS, HTML, XML, Markdown and LaTeX.
- **Queries:** SQL.

For another language, fill in a `Language` of your own and give it to `SyntaxHighlighter`.

`SyntaxPalette.light` and `.dark` give the colours. `follow(view)` picks whichever suits the
view's text colour, and switches when the desktop goes light or dark.

This is a scanner, not a parser. It colours what it sees, without knowing the grammar: it can't
tell a type from a variable where only a parser could. [Tree-sitter](https://tree-sitter.github.io)
grammars would be the next step, in a package of their own. Tree-sitter is MIT licensed, but it
and its grammars are C to build.

## Language servers

`LanguageServer` runs a server as a separate process and speaks the
[Language Server Protocol](https://microsoft.github.io/language-server-protocol/) to it. That's
JSON-RPC over its standard input and output. The server's messages are read on a thread of
their own and handled on the UI thread, so a slow server never holds up typing.

`LanguageServer.forLanguage` looks on `PATH` for a server for each language:

| Language | Servers looked for, in order |
|---|---|
| Python | `pyright-langserver`, `basedpyright-langserver`, `pylsp`, `jedi-language-server` |
| C, C++ | `clangd` |
| Rust | `rust-analyzer` |
| Go | `gopls` |
| D | `serve-d` |
| JavaScript, TypeScript | `typescript-language-server` |
| Lua | `lua-language-server` |
| Shell | `bash-language-server` |
| C# | `csharp-ls`, `OmniSharp` |
| Java | `jdtls` |
| Ruby | `solargraph`, `ruby-lsp` |
| HTML, CSS, JSON | `vscode-html-language-server`, `-css-`, `-json-` |
| YAML | `yaml-language-server` |
| LaTeX | `texlab` |

Or start any server with `new LanguageServer(command, rootFolder)`.

**`LspDocument`** opens a buffer in a server.

- **Edits:** it sends each edit as the range that changed, not the whole text. It converts the
  buffer's byte columns to the UTF-16 columns the protocol counts in.
- **Diagnostics:** it keeps the server's diagnostics in buffer positions.
- **Requests:** it asks for completions, hovers and definitions.

**`LspEditor`** shows all of that in a `TextView`.

- **Problems:** errors and warnings are underlined with squiggles and marked in the gutter.
- **Completions:** they appear after a trigger character (`.`, `::`) or Ctrl+Space, and narrow as
  you type. Up and Down choose one, Enter or Tab puts it in, and Escape closes the list.
- **Hovers:** a hover shows the problem there, and what the server says the thing is.
- **Definitions:** F12 or a Ctrl+click goes to a definition. One in another file is handed to the
  app.

What it doesn't do yet: renaming, formatting, code actions (quick fixes), signature help, finding
references, semantic highlighting, and snippets in completions.

## Tests

`tests/` drives a real window. It checks that highlighting follows edits (a comment opened and
closed, and a 30,000-line file highlighted to its end). It also checks the language-server
features against `tests/fake-server.py`, a small server that answers predictably and keeps its
copy of the text from the edits it's sent. That way a test can check the server sees the text as
the buffer has it, including after an emoji, where bytes and UTF-16 units differ.

```bash
cd tests && dub run
```

The unit tests (`dub test`) cover the line scanner and the languages. It has also been tried by
hand with pyright.
