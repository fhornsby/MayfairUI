# OverBrief

A LaTeX editor in the manner of [Overleaf](https://www.overleaf.com), on the desktop. A
project's files down the left, the file being edited in the middle, and the PDF it makes on the
right, side by side in a `SplitPane` whose dividers are dragged to share out the room.

- **Projects:** a project is a folder. To open another in its place, use any of these:
  - Open Folder (the folder button in the title bar, or Ctrl+O);
  - a project from Recent, at the end of the menu;
  - a folder dropped on the window.

  The project open is closed first, after asking about unsaved files. The one open last is
  opened again at start-up. Where the desktop has no folder chooser to show (no
  xdg-desktop-portal and no zenity), it asks for the folder's path instead.
- **Files:** the project's folder, in a tree, with buttons to make a file or a folder.
- **Editor:** a tab for each file open, highlighted as LaTeX by mayfair-code. Errors and warnings
  from the last compile are underlined at their lines, with a dot beside each.
- **Compiling:** with the TeX that's installed: latexmk where it is, which runs BibTeX or Biber
  and reruns as references need, or else pdfLaTeX twice. XeLaTeX and LuaLaTeX can be chosen in
  the logs.
  - Ctrl+S saves and compiles, as in Overleaf, and so do Ctrl+Enter and Recompile.
  - With Auto on, it compiles once typing pauses.
- **PDF:** each compile's PDF is shown where you were reading, at the same page and zoom.
  - Logs lists the errors and warnings, and choosing one goes to it.
  - When a compile fails, the last PDF that worked stays.
- **SyncTeX:** double-click the PDF to go to the line that made it. Show in PDF (Ctrl+., or the
  arrow in the title bar) scrolls the PDF to the line the caret's on.
- **Language server:** where [texlab](https://github.com/latex-lsp/texlab) is installed, it gives
  completions, hovers and going to a `\label` from a `\ref`.

```bash
dub run
```

```bash
dub run -- ~/thesis
```

```bash
dub run -- ~/thesis/chapters/results.tex
```

With no argument it opens the project open last time, or the first time the sample project in
`sample/`. Given a folder, it opens that project;
given a file, the project it's in, with the file open. The main file, the one compiled, is
`main.tex` if there is one, or else the first `.tex` file with a `\documentclass`. What compiling
makes goes in `.build/` in the project, out of the tree.

## Needs

- **TeX Live,** or another TeX with latexmk, pdflatex and synctex. On Debian and Ubuntu that's
  `texlive-latex-recommended` and `latexmk`; `texlive-full` has everything.
- **texlab,** optionally, for completions and checking as you type.

## How it's made

The window's laid out in XML, each part with a view of its own, and each part's code is in a
module of its own. To see how a part works, read its view, then its module:

| View | Module | What it is |
|---|---|---|
| `resources/views/main.xml` | `source/workspace.d` | The window's content: the three panes in a SplitPane, and the status line. `Workspace` controls it and connects everything. |
| `resources/views/files.xml` | `source/files.d` | `FilesPane`: the project's files, with its buttons. |
| `resources/views/preview.xml` | `source/preview.d` | `PreviewPane`: the toolbar, the PDF, and the logs. |
| `resources/views/header.xml` | `source/header.d` | `Header`: the title bar, a TitleBar of the app's own. |

And three modules with no view, the app's logic:

| Module | What it does |
|---|---|
| `source/project.d` | The project's folder: which file's the main one, and the files for the tree. |
| `source/compiler.d` | Runs latexmk on a thread of its own, and reads its log for errors and warnings. |
| `source/synctex.d` | Asks SyncTeX where a line is in the PDF, and which line made a place in it. |
| `source/documents.d` | A file open in the editor: its buffer, view, tab, highlighting and problems. |
| `source/recent.d` | The projects opened lately, kept in `~/.config/overbrief/recent`. |

`source/app.d` is `main`. It makes the window, loads `main.xml` with a `Workspace`, gives it the
title bar, and opens the project. `resources/strings.xml` has the app's text, which the views
use as `%id` and the code as `tr!"id"`, and `resources/latex.css` its look, over the Oriel theme.

The parts talk through delegates, which `Workspace.initialise` connects once `main.xml` is built.
For example, `FilesPane.onOpen` opens a file in a tab, `PreviewPane.onCompile` compiles, and
`PreviewPane.onSourceWanted` goes from the PDF to the source. So each pane knows nothing of the
others, and reads on its own.

## Not done yet

- **Long lines aren't wrapped:** Mayfair's TextView scrolls sideways instead, and LaTeX's
  paragraphs are long lines. Overleaf wraps them.
- **Showing the PDF's place:** Show in PDF scrolls to the place, but doesn't flash it.
- **The engine choice:** it isn't remembered, and nor is which file's the main one; there's no
  way to choose another main file yet.
- **Files:** no renaming, moving or deleting in the tree, and no images shown.
- **Tests:** none of its own yet. It was tried by hand on Xvfb with TeX Live 2023:
  - compiling, including the errors in a second file;
  - SyncTeX both ways;
  - the logs;
  - the split pane.
