# code-editor

A code editor, built with Mayfair's `TextView` and [`mayfair-code`](../../mayfair-code), in the
Oriel theme.

- **Files:** a folder's files are listed down the side, on frosted glass where the compositor
  blurs behind the window. Each file opened gets a tab.
- **Highlighting:** each file is coloured by its language.
- **Language servers:** where a server for the language is installed, errors are underlined as
  you type, and you get completions, hovers, and going to a definition, in this file or another.
- **Find and go to:** find and replace, and go to a line.
- **Status line:** shows the problems, the language server, the caret's line and column, the
  indentation, and the language.
- **Unsaved changes:** a tab with unsaved changes shows a dot, and asks before it closes.

```bash
dub run
```

```bash
dub run -- ~/project
```

```bash
dub run -- ~/project/app.py
```

With no argument it opens the working directory. Given a folder, it opens that folder. Given a
file, it opens the file and the folder it's in.

| Keys | |
|---|---|
| Ctrl+S, Ctrl+Shift+S | Save, Save As |
| Ctrl+N, Ctrl+O, Ctrl+Shift+O | New file, open a file, open a folder |
| Ctrl+W | Close the tab |
| Ctrl+F, Ctrl+H, F3 | Find, replace, find again (Shift+F3 back) |
| Ctrl+G | Go to a line |
| Ctrl+Space | Complete |
| F12, Ctrl+click | Go to the definition |
| F9 | Show or hide the files |
| Alt+Up, Alt+Down | Move lines |
| Ctrl+/ | Comment lines out, or back in |
| Ctrl+Shift+K | Delete lines |

For a language server, install one for the language: `pyright` for Python (`npm install -g
pyright`), `clangd` for C and C++, `rust-analyzer`, `gopls`, `serve-d` for D, and so on. The
mayfair-code README lists them all. Each server is started once, for the folder, and shared by
the files in that language.
