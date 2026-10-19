# edminc

A native code editor and IDE for the minc language: file tree, splits,
fuzzy open, project search, a language server, a git gutter, a terminal
pane, and build and run. Zero work at idle, one-frame input latency,
full-refresh-rate scrolling.

This archive contains the editor and its fonts and icons. The editor
looks for the `assets` folder next to its binary.

## Install

Install with the online install script. It puts the editor in
`~/.edminc`, adds it to your PATH, marks the binary executable and, on
macOS, clears the quarantine flag.

macOS and Linux, with the script at <https://minc.dev/edminc/install>:

```
curl -fsSL https://minc.dev/edminc/install | sh
```

Windows, in PowerShell, with the script at
<https://minc.dev/edminc/install.ps1>:

```
irm minc.dev/edminc/install.ps1 | iex
```

`edmc_update` updates an installed copy.

## Running it

```
edmc [file-or-folder]
```

Pass a folder to open it as a project, a file to edit it, or nothing for
an empty buffer. A folder opened without a file restores its last
session: the open files, the panes and the caret positions.

Color emoji use the system font on Windows and macOS. On Linux, install 
with:

```
sudo apt install fonts-noto-color-emoji
```
Or copy `NotoColorEmoji.ttf` into `assets/`. Without it, emoji show as
empty boxes.

C and C++ files get completion, diagnostics, hover and go to definition
from clangd when it is installed. The editor finds it on PATH, in an
LLVM or Visual Studio install, or through the Xcode tools or Homebrew;
`EDMINC_CLANGD` names another binary. clangd reads the compile flags
from a `compile_commands.json` or `compile_flags.txt` in the project.

## Keyboard shortcuts

The primary modifier is `Ctrl` on Windows and Linux, `Cmd` on macOS; the
list uses `Ctrl`. The macOS differences are noted at the end.

- `F1` or `Ctrl+Shift+P` — the command palette: every command by name,
  with its shortcut. In a browser, Firefox and Edge open a private
  window on `Ctrl+Shift+P` before the page sees the key; `F1` works there

Files, buffers and windows:

- `Ctrl+P` — open a file (fuzzy); `Ctrl+Shift+P` from there switches to
  the command palette, and `Ctrl+P` in the palette back
- `Ctrl+B` — toggle the file tree
- `Ctrl+E` or `Ctrl+Shift+E` — focus the file tree; after the changes
  view or the project search, show the tree again
- `Ctrl+S` — save; an untitled buffer opens the system's save dialog
  (Windows, macOS), or a box that asks for the path (Linux, browser)
- `Ctrl+N` — a new untitled buffer
- `Ctrl+K` `F` — a new file, named in the file tree in the selected
  folder; `Enter` creates it, and any folders in the name, and opens it
- `Ctrl+Tab`, or `Ctrl` or `Alt` with the backtick key — list the open
  buffers and terminals, most recent first; press the key again to move
  down (`Shift` moves up), and release the modifier to open the selected
  row
- `Ctrl+K` `W` — the same list, with a filter to type into
- `Ctrl+M` — every open file and terminal at once, zoomed out; pick
  one with the arrows or the mouse and `Enter` or a click, or type to
  filter. The wheel or the touchpad scrolls the tile under the pointer
- `Ctrl+Shift+M` — the call graph: the function at the caret in the
  middle, its callers above and the functions it calls below. `Enter`
  or a click on one makes it the center, `Backspace` goes back, and
  `Enter` on the center opens it
- In an image (.png, .jpg): `+` and `-` zoom, `0` scales it to fill the pane,
  `1` shows it at its own size, and the arrows pan. The wheel zooms
  around the pointer; the touchpad or a drag pans
- `Ctrl+W` — close the buffer or shell in the pane; the pane stays
  open. A buffer another pane or window also shows stays open there
- `Ctrl+Shift+W` — close the pane; its buffer stays open
- `Ctrl+K` `Enter` — keep a preview buffer open. A file opened from the
  tree, a search hit or a definition is a preview, and the editor keeps
  only the last four previews. An edit or a save also keeps a buffer
- `Ctrl+K` `O` — open a folder as the project
- `Ctrl+K` `R` — open a recent folder: the folders you opened last,
  newest first. `edmc` with no arguments opens the last one; `edmc .`
  opens the folder you are in. On Windows, a right click on the
  taskbar entry lists them too
- `Ctrl+K` `N` — open a new window
- `Ctrl+K` `S` — toggle the status bar
- `Ctrl+K` `D` — hide or show the problem underlines in the text
  (errors, warnings and hints); the gutter marks stay.
  `"editor.renderValidationDecorations": "off"` in the settings hides
  them from the start
- `Ctrl+K` `X` — restart the editor with a new build of itself; the
  open files and shells stay open
- `Ctrl+Q` — quit

Panes:

- `Ctrl+\` — split the active pane
- `Ctrl+1`..`Ctrl+3` — focus a pane
- `Ctrl+Alt+Left` / `Ctrl+Alt+Right` — move the pane's buffer or shell
  to the pane on that side

Terminal:

- `Ctrl+K` `T` or `Ctrl+K` `Shift+T` — open a new shell in the active
  pane; the previous shell keeps running and stays in the list
- A focused shell receives every key except the editor's own chords.
  `Ctrl+C` interrupts, or copies when there is a selection.
  `Ctrl+Shift+C` always copies. `Ctrl+V` pastes.
- Drag to select cells. The right button copies the selection, or
  pastes when there is none.
- `Ctrl+K` `P` — switch the pane between your terminal's colours and the
  built-in colours
- `Ctrl+,` — open your settings file

Search and code intelligence:

- `Ctrl+F` — find in the file
- `Ctrl+H` — replace in the file (`Cmd+Option+F` on macOS). `Tab`
  moves between the query and the replacement; `Enter` in the
  replacement replaces the match and selects the next one, and
  `Ctrl+Enter` replaces every match. The buttons right of the
  replacement do the same, and one `Ctrl+Z` undoes a replace-all
- `Ctrl+Shift+F` — search the project
- `Ctrl+T` — go to a symbol
- `F12` — go to definition (also `Ctrl+click`); `Shift+F12` — references
- `Ctrl+Space` — trigger completion (`Tab` or `Enter` accepts)
- `Alt+Left` / `Alt+Right` — navigation history back / forward
- `Ctrl+Shift+G` — the changes view lists the files git reports as
  changed; select a row to compare the file with HEAD side by side.
  `F7` / `Shift+F7` move to the next / previous change, and the arrow
  left of a change's line numbers puts HEAD's lines back. The Graph
  under the list shows the history of HEAD: select a commit to list
  the files it changed, and a file to see its diff in that commit.
  `Down` past the last change moves into the graph, `Right` / `Left`
  open and close a commit, and a click on the Graph heading folds it

Editing:

- `Ctrl+Z` / `Ctrl+Y` — undo / redo (`Ctrl+Shift+Z` also redoes)
- `Ctrl+X` / `Ctrl+C` / `Ctrl+V` — cut / copy / paste
- `Ctrl+A` — select all
- `Ctrl+/` — toggle a line comment
- `Ctrl+Shift+K` — delete the line
- `Alt+Up` / `Alt+Down` — move the line (`Shift+Alt` copies it)
- `Ctrl+Left` / `Ctrl+Right` — by word; `Ctrl+Backspace` / `Ctrl+Delete`
  — delete a word

Multiple cursors:

- `Ctrl+D` — add the next match
- `Ctrl+Alt+Up` / `Ctrl+Alt+Down` — add a cursor above / below
- `Alt+click` — add a cursor at the click
- `Esc` — drop the extra cursors, then the selection

Build and run:

- `Ctrl+Shift+B` — build the project, in a pane of its own
- `F5` or `Ctrl+R` — run the project (`minc run`); without a build.mc,
  the active file
- `Shift+F5` or `Ctrl+Shift+R` — run the active `.mc` file. Pressed
  again while a run is going, either key waits 10 s after the start (a
  notice says how long is left), then stops the run and everything it
  started, and runs again
- `Ctrl+.` — stop the build or run now, with everything it started;
  the output stays
- `F8` / `Shift+F8` — next / previous problem
- `Ctrl+J` — hide and show the build pane under the editors; the build
  keeps running. Drag its top edge to size it
- In a `.c` or `.cpp` file, the same keys compile the file alone into
  the project's `build/` folder: `Ctrl+Shift+B` builds it, and `F5`,
  `Ctrl+R`, `Shift+F5` or `Ctrl+Shift+R` builds and runs it. A file
  without a `main` compiles to an object file only. On Windows the
  compiler is MSVC (found through the Visual Studio installer), else
  clang, else gcc; on macOS and Linux it is `cc`, else clang, else gcc

Movement: the arrows move and `Shift` extends; `Home` / `End` go to the
line ends and `Ctrl+Home` / `Ctrl+End` to the file ends; `PgUp` / `PgDn`
move by a page. `Tab` with a selection across lines indents them, and
`Shift+Tab` takes an indent off them, or off the caret's line.

`Alt+Z` turns word wrap on and off: a line wider than its pane goes on
in the rows under it, broken after a space, and a continued row keeps
the line's indent. Up and Down then move by row, and `Home` / `End` go
to the row's edge first and to the line's on a second press. The diff
view does not wrap. `"editor.wordWrap": "on"` in the settings turns it
on at start.

`Ctrl+=` and `Ctrl+-` zoom the whole window in and out by 20% a step,
and `Ctrl+0` resets it. The level is kept as `"window.zoomLevel"` in the
settings.

In the file tree (`Ctrl+E`), the arrows move, `Right` / `Left` expand and
collapse, `Enter` opens the file and returns to the editor, `Space`
opens the file and keeps the focus, `F2` renames the selected file or
folder in place, `Delete` moves it to the system's trash and closes its
buffers, and `Esc` returns to the editor. A right click on a row, or
the menu key or `Shift+F10` on the selected row, opens its menu: New File
and New Folder (a folder), Open to the Side (a file), Reveal in File
Explorer or Finder (Open Containing Folder on Linux), Copy Path, Copy
Relative Path, Rename and Delete. A new name is typed in the tree;
`Enter` takes it, `Esc` cancels. In
a popup (open, symbols, find), type to filter, move with the arrows,
choose with `Enter` and close with `Esc`.

On macOS, `Cmd` is the primary modifier. `Option` moves by word, and
`Cmd+Left` / `Cmd+Right` go to the line ends. The navigation history is
`Ctrl+-` / `Ctrl+Shift+-`, and the pane move is `Cmd+Option` with an
arrow. A shell receives the `Ctrl` key: `Ctrl+C` interrupts it and
`Cmd+C` copies.

## Settings and colour themes

Your settings are in `~/.edminc/settings.json` (`%USERPROFILE%\.edminc`
on Windows). `Ctrl+,` opens the file and creates it the first time.
Saving it applies it. The file is JSON; comments and trailing commas
are fine. It uses the same keys and colour names as VS Code:

```jsonc
{
  "workbench.colorTheme": "Dark Modern",
  "workbench.colorCustomizations": {
    "editor.background": "#181818",
    "editorCursor.foreground": "#ffcc00"
  },
  "editor.tokenColorCustomizations": {
    "comments": "#7f8c8d"
  },
  "editor.smoothScrolling": true,
  "editor.wordWrap": "off"
}
```

The built-in themes are Dark Modern (the default), Dark+, Light+, Light
Modern, Abyss, Ayu Dark, Ayu Light, Ayu Mirage, Cobalt2, Dracula,
Kimbie Dark, Monokai, Monokai Dimmed, Night Owl, Night Owl Light, Nord,
One Dark Pro, Quiet Light, Red, Solarized Dark, Solarized Light, Tokyo
Night, Tokyo Night Light and Tomorrow Night Blue. They are adapted from
the original themes, whose authors are credited in THIRD_PARTY.md;
edminc is not affiliated with or endorsed by them. "Preferences: Color
Theme" in the command palette lists
them and shows each one as you move through the list. `Enter` keeps the
theme and writes it into the file; `Esc` goes back to the one you had.
A new settings file lists every colour name you can override.

Files your `.gitignore` files ignore show dimmed in the file tree and
stay out of `Ctrl+P` and search. `"explorer.excludeGitIgnore": true`
hides them in the tree too, `"search.useIgnoreFiles": false` lets
`Ctrl+P` and search find them, and `"files.exclude"` hides patterns
everywhere, for example `{ "**/*.bak": true }`.

## Where things are

- The source, the documentation and the issue tracker:
  <https://github.com/SpacesOfPlay/edminc>
- A page that runs the editor in the browser through the wasm build:
  <https://spacesofplay.github.io/edminc/>

`LICENSE` is the MIT licence. `THIRD_PARTY.md` contains the notices for
the fonts and other third-party code in the editor.
