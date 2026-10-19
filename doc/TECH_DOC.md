# edminc — technical reference

This document describes how edminc works. edminc is a native code
editor and IDE for minc. It is written in minc, compiled by minc, and
has a UI shaped like VS Code: a file tree, splits, a command palette
and inline diagnostics. The hard constraints are performance
properties: zero work at idle, one-frame input latency,
full-refresh-rate scrolling and instant file access.

Windows, macOS, Linux and a browser build all run the same portable
core. This document covers the architecture, the platform layer and
the current behavior of each subsystem, and "Limitations" lists what
it does not do yet.
CLAUDE.md has the build commands and the rules, and TESTING.md the
tests, the headless runs and debugging.

## What the minc toolchain provides

The toolchain already provides much of an IDE. This repo builds the
native shell: the window, the renderer, the buffer and the chrome.

- `minc-lsp`: a language server over standard LSP on stdio. It
  provides definition, hover, references, completion, signatureHelp,
  documentSymbol, semantic tokens and diagnostics. The editor is an
  LSP client.
- The stdlib: threads and a thread pool, file IO, directory listing,
  poll-based file watching, process spawning and JSON.
- The minc token set defines the highlighter's keyword table.

## Architecture

### Event-driven platform layer, not a game loop

Every native driver takes the same headless flags: `--shot`, the
`--key`, `--char` and `--wait` injections, `--dump-term`, `--term-raw`,
`--dump-wait`, `--handover`, `--play`, `--smoke`, `--time`,
`--lsp-trace` and the path argument. `lib/headless.mc` parses them
(`hl_arg`). The same module holds the injection loop (`hl_inject`,
where a wait runs real wakes) and the dump-term settle loop
(`hl_dump_term`). It also holds the restart's forwarding of the dump
flags and of the injections not yet delivered (`hl_restart_arg`). A
driver parses its own flags first (`--dpi` on X11 and Windows, the
terminal probe on Windows), passes the rest to `hl_arg`, and supplies
`plat_sleep_ms`.

The editor blocks on the OS event queue. It renders one frame per
burst of events, presents it, and sleeps again. Each OS has its own
thin platform layer: a blocking event loop, rendering only on a damage
signal, and input handlers that mark damage instead of drawing.

Timers exist only while they are needed. The caret blink timer kills
itself a few seconds after the last input, so the editor makes zero
wakeups at idle. On a keypress the handler runs, the frame rebuilds (a
few thousand glyph quads in one draw call) and the frame presents.
Keypress-to-photon latency is about one refresh interval.

### Rendering: glyph atlas + one quad batch

The font rasterizes into an RGBA8 atlas. Every visible glyph and UI
rect draws as a textured quad from one dynamic vertex buffer, usually
in one draw call. The renderer does no dirty-rect tracking. A full 4K
screen of text is about 10k quads, so a full redraw is cheap and
scrolling keeps up with the refresh rate.

The atlas stores coverage per channel. A grayscale raster copies its
gray value into r, g and b, so one blend rule serves every platform.
Text blends in the style of DirectWrite. An enhanced-contrast term
applies to the coverage. The shader computes the result in a gamma
space against the background color from the constant buffer, then
converts it back to an effective coverage for the fixed-function
blend. Where the platform has subpixel rendering, the blend is
dual-source. The correction scales with the luminance of each token
color, so dim text does not over-brighten. The values are tuned per
glyph against VS Code with scripts/pixcmp, and each backend applies
the same defaults. Windows uses `TEXT_GAMMA` 1.3 for its DirectWrite
emulation. macOS, Linux and the web use 1.0 and blend coverage in
sRGB. On macOS, stem darkening supplies the weight. Full coverage is
full opacity: the conversion divides by the distance from the
background, so without that rule a solid rect in the background's own
color drew nothing over another color.

The atlas is sampled at the nearest texel, since glyphs are drawn at
their rasterized size. `draw_transform` scales and offsets every quad
while it is set, for the explode view's tiles, and `draw_clip_y` clips
in y as `draw_clip` does in x. A textured quad drawn scaled stores its
u as -u - 1. For such a quad the shader averages a 3 by 3 grid of
texels across the pixel's footprint, from the derivatives, instead of
taking the nearest one. The derivatives are taken before the branch,
and the taps use an explicit level, so every backend runs them in
uniform control flow. Quads with an ordinary u take the same path as
before, and a frame without a scaled quad renders byte for byte as it
did.

Two faces share the atlas and the cache. The mono editor face sits on
its cell grid. A proportional UI face draws chrome text with
per-glyph advances, marked by the `FONT_UI` codepoint flag. Glyphs
rasterize on first use, so Unicode works without preloading ranges.
Rounded corners antialias through quarter-disc coverage sprites packed
into the atlas. UI edges therefore blend like text on every backend.

A color glyph, such as a color emoji, stores straight RGBA in its atlas
cell (`channels == 4`). It draws with a clear vertex color
(`col == 0`), which no other draw uses. Each backend's shader branches
on that value and composites the cell directly instead of treating it
as coverage. One draw call and one blend state cover both text and
emoji.

An image is a texture of its own (`gpu_image_create`), with its full
mip chain, which each backend generates on the gpu. The batch is kept
in runs of one texture each (`draw_run_*` in lib/draw.mc): every quad
joins the run of the current texture, and `draw_image` switches to the
image's run for one quad. A backend draws each run with its texture
and a flag telling the shader which it is: the Direct3D constant
buffer's fourth background component, a uniform in the two GL
backends, and the fourth component of the fragment bytes in Metal. An
image run samples linearly through the mip levels and outputs the
texel as straight RGBA; a run marked `DRAW_RUN_NEAREST` magnifies as
blocks. A frame without an image is a single run and draws as before.

The UI is hand-written on the same quad batcher: the tree, splits, list
popup, input line, scrollbar and status bar. Retained state lives in
plain module globals. On damage, the frame draws immediately into the
shared batch. There is no retained widget tree.

Messages are notices, not status-bar text: a box at the bottom right,
above the status bar, whether the status bar shows or not (src/ed.mc,
"notice"). A line in the status bar is too easy to miss. `ed_status`
is information, with the info icon, and goes by itself after 4 s on a
one-shot timer, so idle stays without wakeups. `ed_warn` is a warning:
a refused action, a failed save or build, a file changed on disk, a
settings problem. It has the warning icon and stays until Esc, a click
on it, or the next notice. `ed_notice` is an error and stays the same
way. Esc closes a notice and still reaches what has the focus. The
Ctrl+K hint closes when the chord ends. While the input box is open
(save-as, open folder, new file), its messages show under the field,
where the eye is. The last message stays in `g_status_msg` for the
box and the tests.

The input box asks for a path. It is a panel at the top of the
window, the shape of the picker's: a title, the input, and a message
row. Enter commits, Esc or a press outside the box closes it. A
commit that fails keeps the box open with the reason under the field.

### Text engine

- Each document is a gap buffer of bytes plus a line-start index that
  is kept up to date on every edit.
- A large file loads with one alloc, one read and one newline scan.
- The loader detects CRLF, strips it internally, and restores it on
  save.
- Undo and redo use an edit journal. The journal handles multi-cursor
  undo with no extra code.
- The text is UTF-8 throughout. Cursor movement steps over
  grapheme-cluster boundaries. Rendering decodes each line into the
  mono grid. UTF-16 exists only inside the Windows platform modules,
  at the API boundary.

### Highlighting

The highlighter is an incremental lexer with resumable state per line:
a block-comment flag and the bracket nesting depth. Its classification
and colors match the minc VS Code extension under Dark+, measured per
token. Control keywords are pink. Declarations, primitive types and
constants are blue. CamelCase identifiers are teal, identifiers before
`(` are yellow, and other identifiers are light blue. String escapes
are gold. An edit invalidates the cached line states from the edited
line down. The lexer recomputes them lazily, down to the bottom of the
viewport. `.mc` files highlight as minc. `.md` files get a color-only
markdown pass, which carries a fenced-block flag as its state. Other
file types get a basic pass over the same color classes: keywords,
strings, numbers and comments, with a few per-language additions
(JS/`.mjs`, Python, shell `.ps1`/`.sh`, HTML, CSS, GameMaker `.gml`,
C and C++, JSON, YAML). C and C++ share one lexer (`.c`, `.h`, `.cpp`,
`.hpp`, `.cc`, `.cxx`, `.hh`). It colors a preprocessor directive and an
`#include <path>`, and lexes the rest of a directive's line as code. The GML lexer carries block comments and verbatim
`@"..."` strings across lines, and lexes the `{expr}` parts of a
`$"..."` template string as code. GameMaker's `.yy` and `.yyp`
resource files lex as JSON. The
HTML lexer passes the body of a `<script>` element to the JavaScript
lexer and the body of a `<style>` element to the CSS lexer, up to the
closing tag. The embedded lexer's state is carried in the upper four
bits of the HTML line state, so a comment or a CSS block in the body
spans lines. `ed.mc` maps the file extension to a language
(`lex_lang_of`) and dispatches to its lexer. Minc files use minc-lsp,
and C and C++ files use clangd when it is installed. The other
languages have highlighting but no diagnostics or completion.

### Language intelligence

On the native platforms `minc-lsp` runs as a child process over stdio.
In the browser it runs as a Web Worker (see the wasm section). The
client side is stdlib JSON plus a small JSON-RPC-over-stdio layer. The
separate process isolates crashes: a crash in the checker cannot take
the editor down.

C and C++ files go to clangd, a second child in its own
`plat_child_*` slot. It starts on the first C file opened. The
editor looks for it in `EDMINC_CLANGD`, then on PATH, then where
LLVM, Visual Studio, Homebrew and the Xcode tools install it. When it
is not found, a request on a C file says so, and the search runs again
after a folder switch. clangd takes its compile flags from
`compile_commands.json` or `compile_flags.txt` in the project. Without
either it guesses them, and on Windows it then finds the MSVC and
Windows SDK headers when Visual Studio is installed. The browser runs
minc-lsp only.

A server's stderr stays out of its stdout pipe, which carries only
protocol frames. clangd starts with `--log=error`. On Windows the
child's stderr is the NUL device. On macOS and Linux it inherits the
editor's.

### Threading

The main thread owns the UI and never blocks on work. Workers run
project-wide search, file-tree indexing, `git` jobs and build/run.
When a worker finishes, it wakes the main loop. On Windows the wake
is an auto-reset event that the message loop waits on beside the
input. A set event becomes one posted `WM_WAKE`, however many workers
set it. A worker that posted the message itself, once per read of a
program's output, kept the queue full during a flood of output.
Windows returns posted messages before input and `WM_PAINT`, so the
window took no keys and drew no frames until the program ended. On
Linux the wake is a byte on a self-pipe, and in the browser it is
`setTimeout(0)`. Nothing on the UI thread waits for a worker.

### UI system

VS Code is the design authority. Its chrome is specified as named
theme tokens with per-theme defaults in the MIT-licensed
microsoft/vscode repo. Its metrics can be measured in the running app.
This repo checks quality by measurement (pixcmp). The rules:

- Source code carries no product names. Comments say "the reference
  editor". A value copied from VS Code gets a hex comment. A table
  copied verbatim gets a THIRD_PARTY entry.
- Widget parity follows the same method as text parity: capture the
  VS Code widget and the edminc widget with Dark+ set explicitly,
  compare them, and fix the numbers.
- lib/theme.mc holds the colors and the metric helpers derived from
  line height. Every color is a named slot that a theme sets
  ("Settings and color themes"). lib/ui.mc holds the element primitives: top panel,
  floating panel, focused input, list row and list scrollbar. Each
  element's look is defined in one place. The lists that scroll (the
  file picker, the switcher, workspace symbols, completion and the
  theme picker) show a scrollbar when their rows overflow. The command
  palette does not: it is searched by name rather than browsed. Event routing stays explicit in the core,
  because each event type has a different overlay policy.

## Dependency policy

The editor is standalone. It calls the OS APIs that ship with the
target and nothing else. It never links third-party code at runtime.
When it needs third-party code, that code is vendored as minc source
and compiled in.

- Windows: user32, gdi32, kernel32, dwrite, d3d11, dxgi,
  d3dcompiler_47. All ship with Windows 10 and later.
- macOS: the Objective-C runtime, AppKit, CoreText, and Metal with
  CAMetalLayer. None of these are deprecated. Each backend can be
  replaced behind the contract.
- Linux: libX11 and libGL count as OS APIs. FreeType and fontconfig do
  not, and the editor does not use them. Fonts come from a vendored
  transpile of stb_truetype (public domain/MIT). The driver targets
  X11. Wayland runs it through XWayland.
- wasm: the Web platform is the OS. The build uses WebGL2 through the
  toolchain's GLES3 bindings, DOM events, and a map of the project's
  files that the page fetches. A browser exposes no system fonts, so
  the vendored rasterizer renders DejaVu faces from assets/.

The vendored rasterizer could render on every platform. Each OS ships
a text stack that its users are used to, so the editor uses the native
rasterizer where one exists (DirectWrite, CoreText). The vendored one
serves the platforms without a usable native stack: Linux and wasm.

## Platform layer

The core is portable, and each OS has a thin driver. lib/plat.mc
defines the contract and is the source of truth for it. The core is
driven by callbacks because on macOS the OS owns the event loop.
src/edminc.mc is the manifest. It selects the platform module set with
`when os()`.

### The boundary

- Shell: the driver owns the native event loop. It translates native
  events into `app_char` / `app_key` / `app_mouse` / `app_mouse_move`
  / `app_scroll` / `app_resize` / `app_scale` / `app_focus` /
  `app_timer` / `app_close` / `app_render`. The core calls back through
  `plat_damage` / `plat_damage_window` / `plat_set_timer` / `plat_kill_timer` /
  `plat_set_title` / `plat_clipboard_get` / `plat_clipboard_set` /
  `plat_quit`, plus `plat_dir_list`, `plat_chdir`, `plat_run_capture`,
  `plat_pick_folder` and the `plat_window_*` entries. The core defines
  the key codes and modifier bits. `MOD_CTRL` is the platform's primary
  shortcut modifier: Ctrl on Windows and Linux, Cmd on macOS. Text
  input reaches the core only as committed codepoints.
- GPU: lib/draw.mc holds the shared batch accumulation. A backend
  keeps at most one queued frame, in the idiom of its API. It keeps one
  surface per window (`gpu_win_create`/`bind`/`resize`/`destroy`) and
  a bound index that the frame path draws to.
- Font: lib/font.mc holds the shared glyph cache and atlas packing. A
  backend implements `plat_font_init`, `plat_glyph_raster` and
  `plat_shape_cluster`. There is one font context (atlas, cache,
  metrics) per distinct dpi, and `font_use(dpi)` switches between
  them. Windows on displays with different scales each render sharp
  text.

### The launch

`edmc .` from a shell returns the prompt at once on every platform.
On Windows the binary is a windowed program (`@gui` on plat_win.mc),
which the shell does not wait for. On macOS and Linux the shell waits
for any child, so the driver detaches itself: `hl_detach_launch`
(lib/headless.mc) scans the raw arguments, and a plain launch forks,
the child calls `setsid` and execs the same executable with
`--no-detach` in front of the arguments, and the parent exits
(`mac_detach`, `x11_detach`). The editor is then in a session of its
own: the terminal's Ctrl+C and its close do not reach it. The
descriptors are left as they are, so output still goes where the
shell sent it, as on Windows. `--no-detach` keeps the editor in the
foreground, for a debugger or for its output. A headless run stays in
the foreground too, since the script that started it waits for its
exit code and its output, and so does a restart, which the launch it
came from already placed.

### Windows: win.mc, gpu_d3d11.mc, font_dwrite.mc, plat_win.mc

The loop blocks in `MsgWaitForMultipleObjectsEx`. Rendering happens
only in `WM_PAINT`, and damage goes through `InvalidateRect`. The
swapchain is a D3D11 flip-model swapchain with a frame latency
waitable object and maximum frame latency 1. Its scaling is
`DXGI_SCALING_NONE`. During a live resize the compositor can show a
frame of the previous size. Unscaled, that frame sits at the top left.
Stretched, its content would shift with every step of the drag.

A frame is built when the swapchain can take it. While the object is
unsignalled, `WM_PAINT` defers the frame, and the loop waits on the
object together with the message queue. Input that arrives in the
meantime goes into that frame. Without the object, `Present` blocks
for up to a refresh after the frame is built, and every frame of a
continuous scroll shows input one refresh older. A `WM_PAINT` nested
in another handler runs outside the loop: in a modal loop (moving or
sizing the window, the folder picker, a menu) or in a resize's
synchronous paint. It waits up to two refreshes for the object's
signal and then renders. Without the wait, a drag that also wakes the
loop (a terminal that redraws on every size change) presents several
frames per refresh. The compositor then shows them one per refresh,
and the content falls behind the window frame. A nested message also invalidates the windows with a deferred
frame, so a modal loop paints them.

An unsignalled object means the compositor has not taken the previous
frame. A `Present` made then blocks the UI thread until it does, so
the loop never forces one: the deferred frame waits while input goes
on, and goes out with everything that arrived. Only an object that
stays unsignalled for 200 ms, a lost signal, gets a frame forced.
Forcing earlier stalled the UI thread: a 100 ms wait on a laptop on
battery, and 200 ms `Present` calls in a Remote Desktop session, whose
compositor takes about 30 frames a second. If the swapchain cannot
be created with the object, `Present` blocks under the device's
maximum frame latency instead. `EDMINC_WAITABLE=0` creates the swapchains
without the object, to compare the two.

The driver pairs `WM_CHAR` surrogate halves before it calls `app_char`. Wheel
deltas become pixel floats that the core accumulates, scaled by the
user's wheel settings (`SPI_GETWHEELSCROLLLINES` and `...CHARS`, read
again on `WM_SETTINGCHANGE`; "a screen at a time" scrolls the client
height). A precision touchpad arrives as `WM_MOUSEWHEEL` with small
deltas and goes to `app_scroll`; a delta that is a whole multiple of
`WHEEL_DELTA` is a mouse wheel's notch and goes to `app_scroll_notch`.
`WM_MOUSEHWHEEL` and Shift with the wheel scroll sideways. `WM_DPICHANGED`
triggers app_scale, which rebuilds the font and the atlas, and the
driver adopts the suggested rect. GDI selects the font and provides
the metrics. DirectWrite rasterizes ClearType subpixel coverage at the
window DPI, and the GPU blends it per channel with dual-source
blending. UTF-8 to UTF-16 conversion happens only at the API boundary.

The editor draws its own caption, as VS Code does. `WM_NCCALCSIZE`
reclaims the caption band into the client area. `WM_NCHITTEST` returns
a resize band along the top and HTCAPTION for dragging. The exception
is the window-button zone, which stays client area so its clicks reach
the driver. A button acts when the mouse is released over it. The
driver tracks the hover and pressed states, and the view draws them.
The driver reports a client height reduced by the caption. The vertex
shader shifts its output down by the caption height, and the view
renders the bar at negative y. The core coordinate space stays
unchanged, and the driver translates input y. The window launches
maximized. The class icon is the app logo, built at runtime. The shell
reads an executable's icon from its resources instead: a pinned taskbar
entry, a shortcut and Explorer show that one. So build.mc writes the
logo's seven PNGs into build/edmc.exe as an icon group after the
compiler links it (`build_icon`, through `UpdateResource`). A build
that bypasses build.mc has no file icon.

Text input goes through `WM_IME` and `WM_CHAR` at the committed-text
level. `ImmSetCompositionWindow` anchors the composition at the caret.
Color emoji fall back to the Segoe UI Emoji face. Its COLR layers are
composited to straight RGBA
(`IDWriteFactory2::TranslateColorGlyphRun`). Neither Consolas nor
Segoe UI has the dingbats, arrows and technical symbols that terminal
programs use for prompts and rules. The text face and the UI face
therefore also fall back to Segoe UI Symbol. The fallback order follows
the codepoint's default presentation (`cp_emoji_presentation`): the
color face comes first for codepoints that are emoji by default, and
the symbol face comes first for the rest. The order matters because
Segoe UI Symbol also has monochrome versions of the emoji. A single
fixed order would either draw the emoji flat or draw the dingbats in
color. The symbol face is not monospaced. A glyph wider than its cells
is scaled to fit them so it does not overflow into its neighbors
(`dw_sym_raster`). A multi-codepoint emoji cluster is shaped to one
glyph id (`IDWriteTextAnalyzer::GetGlyphs`, `plat_shape_cluster`) and
drawn through `FONT_GLYPHID`. Regional-indicator flags do not ligate
this way. They fall back to the glyph of their base indicator.

The folder dialog is `IFileOpenDialog` in pick-folders mode. The
driver opens it from a posted message, so no editor entry point is on
the stack under the dialog's message loop. For multiple windows the
driver keeps a `WinRec` per native window and a shared device with
one swapchain per window. Each wndproc routes the event to its window
before the core receives it.

### macOS: mac.mc, gpu_metal.mc, font_coretext.mc, plat_mac.mc

The driver calls Cocoa through the C ABI of the Objective-C runtime,
casting `objc_msgSend` per signature. No Objective-C compiler is
involved. It sets up NSApplication with activation policy Regular.
Each NSWindow's content view is a class built at runtime
(`objc_allocateClassPair`) and backed by a CAMetalLayer. `[NSApp
run]` owns the loop.

On-demand rendering follows the Core Animation contract, not the
AppKit one. The view is the layer's delegate. `plat_damage` marks the
layer as needing display, and the CA commit calls `displayLayer:`,
which renders. AppKit's updateLayer and drawRect never fire for a
custom backing layer. CA coalesces the damage marks per commit, so the
editor still renders once per burst of events. A mark made inside
`displayLayer:` is the core asking for the next glide frame. Marking
at once made CA display again immediately, and `nextDrawable` then
blocked the main thread until the layer vended a drawable, one per
refresh with display sync on, so a held key's repeats arrived three to
four times late. Such a mark is held instead, and a fetch thread per
window takes the wait: it blocks in `nextDrawable`
(`gpu_fetch_drawable`), and when the layer vends the drawable it posts
to the main thread, which renders into it at once (`gpu_pending_set`,
consumed by `gpu_frame_end`). The layer's own pacing gives one frame
per refresh at the vsync, so nothing tears, and the main thread is
free between frames for the key repeats. While a fetch is out, every
mark for the window waits for it, so a key between frames adds none
the compositor would drop. A vended drawable that no frame wants goes
back unpresented and the pacing stops; the thread then waits on its
semaphore, so idle stays at zero wakeups. Display sync off would free
the main thread too, and tears, since the present is then not held to
the vsync. An unbundled binary
posts a synthesized activation event after `makeKeyAndOrderFront`,
which makes activation reliable. At launch the driver sets the Dock
icon from the embedded logo (`setApplicationIconImage:`). It draws the
logo into the macOS icon grid instead of to the full canvas. On the
1024 grid the rounded square is 824 wide with a corner radius of
185.4. A full-canvas image looks visibly larger than every other icon
in the Dock. The favicon's own corners are tighter, so the driver cuts
the corners to that radius, with one pixel of coverage anti-aliasing.

Cmd chords arrive through `performKeyEquivalent:`. The view claims
only the chords the editor binds. Text input uses NSTextInputClient at
the committed-text level. Committed text arrives through
`insertText:`, and editing keys through `doCommandBySelector:`. The
driver tracks marked text as a flag. The composition shows in the
IME's own window, anchored through `firstRectForCharacterRange`. Metal
alternates between two MTLBuffers per frame, with
`maximumDrawableCount` 2. During a live resize the frame presents
inside the CA transaction, so the drawable and the new bounds apply
together. `--smoke` renders one frame without entering `[NSApp run]`,
so it is safe to run headless.

font_coretext rasterizes CoreText glyphs into an alpha-only
CGBitmapContext, which gives grayscale coverage. A glyph missing from
the text face or the UI face goes through the system cascade
(`CTFontCreateForString`). Each lookup starts from its own base face,
so the substitute has that face's size. Stem darkening supplies the
native weight, so `TEXT_GAMMA` is 1.0. Color emoji rasterize through
the cascade's color face into an RGBA context. The driver
un-premultiplies the result into the straight RGBA the contract
expects. `plat_shape_cluster` lays out one CTLine over the cluster.
When the line holds one run of a color face, it takes that run's
single glyph id. This ligates skin tones, ZWJ families, keycaps, VS16,
and the flags that DirectWrite cannot ligate.

The folder dialog is an app-modal NSOpenPanel behind
`plat_pick_folder`. The driver defers it to the next turn of the run
loop. For multiple windows the driver keeps a `GpuSurf` per window
behind `gpu_bind` and a `MacWin` per window. Every view and delegate
method routes to its window first. `plat_damage` marks every layer,
`plat_damage_window` one, and each timer carries the window that armed it. `app_render` skips a
window whose `occlusionState` lacks Visible, or that is miniaturized,
and repaints it when it returns. This is necessary because
`nextDrawable` blocks while a drawable is unconsumed.

### Linux: x11.mc, gpu_gl.mc, font_ttf.mc, plat_x11.mc

x11.mc declares the Xlib and GLX functions itself instead of importing
them. The loop drains `XPending`, renders once if there is damage,
then calls `poll()` on the connection fd. The timer table gives the
timeout, which is -1 at idle, so idle makes zero wakeups. The loop
must drain the queue before it blocks. Workers wake the loop through a
self-pipe in the same poll set. WM_DELETE_WINDOW maps to `app_close`,
Expose to damage, ConfigureNotify to resize, and FocusIn/Out to focus.
The window manager draws no caption on the native path.

Text arrives as committed UTF-8 from `Xutf8LookupString` through an
XIC. Dead keys compose, and IME commits arrive as codepoints.
XFilterEvent runs before dispatch. The input style is preedit-nothing,
so the composition draws in the input method's own window, with no
anchoring at the caret. Ctrl and Alt chords drop the C0 control byte.
Buttons 4 and 5 are the wheel.

X11 has no per-window scale. The driver reads the scale from the
desktop's `Xft.dpi`. The precedence is the `--dpi`/`EDMINC_DPI`
override spec, then `Xft.dpi`, then 96. A value is a DPI (`144`) or a
scale of the 96 base (`1.5x`). `XRRGetMonitors` gives each output's
rectangle. On every ConfigureNotify the driver translates the window
origin to root coordinates and finds the output that holds the
window's centre. When the window moves to an output with a different
scale, the driver calls app_scale. The override spec can therefore
name each output (`--dpi DP-1=144,HDMI-1=192`). The driver never uses
the physical size, because identical panels can report sizes either
pre-scaled or raw.

The editor draws its own caption, as on Windows. `_MOTIF_WM_HINTS`
asks the window manager not to decorate the window. Dragging and
resizing go to the window manager through `_NET_WM_MOVERESIZE`, so
snapping and tiling work. The outer few pixels form a resize border
with the eight direction cursors. The maximize and close buttons act
on release. Minimize calls `XIconifyWindow`, which does nothing under
compositors that ignore it for XWayland windows.

Under Weston's window manager (WSLg), a maximized undecorated window
keeps its shadow margin. WSLg then shows the window offset by that
margin, so the pointer misses what is drawn. On Weston the driver
maximizes by itself. It lets the manager compute the maximized
rectangle, drops the manager's maximized state, and places a normal
window on that rectangle. A caption drag on a maximized window
restores it first, because the manager does not move a maximized
window.

gpu_gl uses a GLX 3.3 core context with one program, one streamed VBO
and one `glDrawArrays`. It blends dual-source through the GLSL 330
`index=` layout qualifier. `--shot` reads the frame with
`glReadPixels`. `--smoke` runs with no display. A failing
`XOpenDisplay` is not an error, and the frame builds with no GL
context, so `minc test` works over ssh and in CI.

font_ttf serves the mono face, the UI face and two icon faces on the
vendored stb_truetype. It finds faces by filename under the standard
font directories, searching to depth 3 and taking the first match.
Rasters are grayscale with no hinting. Color emoji render from a
CBLC/CBDT bitmap font (see Color emoji below). A character that the
bundled faces lack renders as an advance-only glyph. There is no
system face to fall back to here, so the coverage is DejaVu's.

Clipboard: a copy takes ownership of the CLIPBOARD selection, and the
loop responds to SelectionRequest. A paste returns the text directly when
the editor owns the selection, because asking the X server would
deadlock the single loop. Otherwise the paste requests a conversion
and waits up to a second, reassembling INCR transfers. The clipboard
content is lost when the process exits unless a clipboard manager
saves it.

### wasm: web.mc, gpu_webgl.mc, plat_web.mc

This platform differs most from the others. It is single-threaded,
has no processes and no file system, and the page owns the loop. The
page holds the project's files in a map fetched from files.json.
`minc wasm` stages that file from the tree and honours the root
.gitignore. `plat_dir_list` reads from that map. On the other three
platforms the same service wraps the stdlib. The page opens README.md
unless the URL names another file with `?file=<path>`. The GitHub
Pages demo is this page, so a visitor sees the project's own
introduction first.

The runtime's imports (write/open/read/close/clock) serve the map. A
save writes to the map, not to a disk. The title, timers
(`setInterval`, only while a timer is held), damage (one
`requestAnimationFrame`), the wake (`setTimeout(0)`), DPI from
`devicePixelRatio`, focus, resize and the cursor kind all map directly
to browser APIs. Copy and paste use the async Clipboard API. The
synchronous `plat_clipboard_get` returns the text of the last paste
event. Idle is zero work.

The language server is the toolchain's browser build of minc-lsp,
`minc_lsp_web.wasm`. It runs in a Web Worker over its own copy of the
files plus the project's stdlib import closure, with one `lsp_frame`
call per message. Its replies reach the editor in the same form as the
native reader's bytes. build.mc stages it from `MINC_LSP_WASM` or from
next to the compiler, along with the import closure under
build/web/lsplib. Without the module the page runs with no server.
Project search scans on the main thread in one pass. Git capture
reports that it is unavailable, so the change gutter is off. There is
no pty, so there is no build pane. Session persistence is disabled.

Color emoji font: the CBLC/CBDT bitmap font is large, so it is not
staged into files.json and the initial file load starts fast. The page
fetches the font in the background after start and calls
`web_emoji_loaded`. That function reloads the emoji face and drops the
cached glyphs, so glyphs drawn as missing-glyph boxes rasterize again
in color.

gpu_webgl uses WebGL2 through the GLES3 bindings, with one program,
one streamed VBO and one draw call. A small probe module determined
the marshalling across the boundary: i32 values and pointers cross as
numbers, i64 and u32 as BigInt, and f32 as numbers. The runtime's file
imports and allocator take i64.

## Subsystems and features

### Buffers, panes, splits

Buffers are held in a 128-slot table, and a switch swaps the full
buffer state. Ctrl+P opens a file or activates it. Ctrl+Tab and
primary+backtick (and Alt+backtick, except on macOS, where Cmd sits
where Alt does and Option+backtick types an accent) cycle through the
switcher's list, and Shift reverses the direction. The backtick is the
key left of 1: the Windows driver takes it by scan code (0x29), since
its virtual key depends on the layout (a section sign on a Nordic
board). The list is in the order the buffers were last shown. Ctrl+W
closes the buffer and the pane moves to the next buffer
(`ed_close_shown`). A buffer another pane or window also shows stays
open: Ctrl+W then closes this pane's view of it, the pane showing the
buffer seen before it (`buf_shown_elsewhere`). On a dirty buffer the
first press is refused and arms the next one. Ctrl+Shift+W closes the pane and keeps the buffer
(`ed_pane_hide`). Ctrl+Alt with an arrow moves what the pane shows to
the neighbouring pane, and the focus follows it
(`ed_pane_move_shown`). The pane it left shows the buffer last seen
apart from the moved one.

A buffer opened by a look (`ed_view_file`: the tree, a search hit, a
definition, a build problem, the history) is a preview. Only the last
`PREVIEW_MAX` (4) looks stay. A look past that drops the preview shown
longest ago that no pane shows (`buf_trim_previews`). Nothing on screen
marks a preview. The flag only decides which buffers go first. An edit,
a save, a double-click in the tree or Ctrl+K Enter keeps a buffer
(`ed_buf_keep`). The picker opens files as kept (`ed_open_file`).

The table keeps at most `BUF_SOFT_MAX` (12) buffers. An open past that
evicts the least recently shown clean buffer that no window's pane
shows, previews first (`buf_soft_evict`). Unsaved buffers do not count
toward the cap, so it bounds only the buffers that were opened to look
at. `EDMINC_BUFFERS` raises it. A session restore skips both limits and
brings a saved set back complete. When the table is full, an open
evicts the least recently shown buffer that is saved and on no pane.
An open fails only when every slot is unsaved or on screen, and a
notice box reports it.

There is no tab bar. The title lists the open files and stars each
dirty one. In a split, each pane draws a one-line file banner at its
top (the `doc_top` band, zero when there is no split). Every mapping
from a line to a y adds this band. A click in a banner focuses the
pane.

### Multiple windows

Several native windows share one buffer set. `WinCtx` stores a
window's pane layout, geometry and sidebar visibility. The live
globals hold the current window, and `app_use_window` swaps between
windows (`ed_window_new`/`close`). g_bufs, the server, git, the build
and the session are shared. Ctrl+K N opens a new window that shows the
active file and leaves the source window unchanged. Closing the main
window (the one the app opened with, index 0) or the last window quits
the app through the dirty gate, which saves the session with every
window present. A minimized window saves the rect it restores to
(on Windows, from its placement). A saved rect under 320x200 is not
restored: the first window opens maximized and any other at the
default size. Closing a secondary window drops that view only. The overlays (the picker, the palette, find, the switcher and the popups) are one set of globals that every window's frame is built from; they draw only in the window the platform last reported focused (`ed_overlay_here`), which is the one the keys reach, and a closed key window hands that to the survivor.

`font.mc` keeps one context per distinct dpi, so each window renders
sharp text on displays with different scales. Switching to a context
with a warm cache takes one texture upload and no re-rasterization.

A redraw request covers every window unless it comes from navigation.
While a scroll, a caret or list key (the arrows, Home, End, Page Up
and Page Down, without Alt), a drag in a document or a hover is
handled, `ed_damage` redraws only the window the input went to:
scroll positions, carets, selections, the tree and the overlays are
per window. A text change redraws every window from `after_edit`,
since another window may show the buffer. The caret blink redraws the
key window, the only one whose caret blinks. Everything else, the
background work included, redraws every window.
Multi-window is available on Windows and macOS. Linux and the browser
have a single window.

### The restart

Ctrl+K X, or `edmc --restart` in a terminal pane, replaces the running
editor with the executable at its own path after the build has
rewritten it. `ed_restart` writes a handover through the session
writer in handover mode. The handover holds the session's records,
then `htext` blocks with each dirty buffer's bytes, then `hterm`
records. Each `hterm` record holds a terminal's pty end and child
(`term_export`, which clears close-on-exec on the master), where the
terminal shows (window ordinal and pane, or the background), its size
and cursor, and its lines from the oldest one held.

The editor stops the LSP server and closes the build pane's run. Then
`plat_exec_self` starts the new binary with the folder and
`--handover <file>`, and ends this process. On macOS and Linux this is
a fork and exec. A plain exec keeps the task, and AppKit logs a
task-policy failure when the new image sets itself up as an
application again. The ptys pass into the child and the shells are
reparented. After this the editor does not see a handed-over
terminal's exit code. On Windows the editor starts a new process and
exits, and the ConPTY handles are not passed on yet. Only the
foreground process can give the foreground to another, so the old
process calls `AllowSetForegroundWindow` for the new one. It then
waits in `WaitForInputIdle` until the new window is up before it
exits. The new process calls `SetForegroundWindow` after its restore.
Without these steps the new window opens behind the other windows.

The new process loads the handover instead of the session.
`session_load_v2` in handover mode puts the unsaved text over each
opened file, clears its undo and sets it dirty. A pane marked `term`
adopts the handed-over terminal (`term_adopt` over
`plat_term_adopt`). The adoption re-feeds the lines, places the
cursor, and then sends a size change so a full-screen child repaints.
Terminals that no pane showed come back in the background.

When a pty cannot be passed on, the record carries the text and no
handle. The terminal then comes back as a new shell under that text.
`term_open_under` passes `under` to `plat_term_spawn`. On Windows this
makes the pseudoconsole inherit the cursor instead of clearing the
screen. The lines are fed with a CRLF instead of the cursor move, so
the host queries the cursor position (DSR, answered from the pump) and
prints its first prompt on the line under the history.

A handover with no file in it also restores. The load does not stop
at the empty buffer list, which would lose the terminals. The panes
fall back to the live buffer, which is first stored into its slot so
that no pane loads a stale copy. `restart_poll` reads the request file
from `app_wake`, one stat per wake. The prompt returning in the pane
after the command is such a wake.

### Settings and color themes

The user's settings are one global file, `~/.edminc/settings.json`
(`%USERPROFILE%\.edminc` on Windows), for every folder and window.
It is JSON with comments and trailing commas (`json_parse_lenient`),
and its keys have the reference editor's names:

- `workbench.colorTheme`: one of the 24 built-in themes by name, "Dark
  Modern" by default. The names are in lib/theme.mc and the settings template.
- `workbench.colorCustomizations`: any color by its slot name, over the
  theme, as `#RRGGBB` or `#RRGGBBAA`.
- `editor.tokenColorCustomizations`: the syntax colors by class:
  keywords, controlKeywords, types, variables, functions, strings,
  escapes, numbers, comments, directives, markdownLists.
- `editor.smoothScrolling`: true or false.
- `window.zoomLevel`: the zoom, a whole number of steps of 20% from -5
  to 8, 0 by default. A fraction rounds.
- `explorer.excludeGitIgnore`: true hides gitignored entries in the
  tree; false, the default, shows them dimmed.
- `search.useIgnoreFiles`: true, the default, leaves gitignored entries
  out of Ctrl+P and search in files.
- `files.exclude`: an object of glob patterns, each true to hide what
  it matches everywhere, as `.git` and `.edminc` always are. A pattern
  is matched against the path from the project's top: `**/*.bak`
  anywhere, `doc` only at the top.

The file is read on the interactive path only. The drivers call
`app_session_restore`, or `app_handover_restore` after a restart, and
both call `settings_load` first, so a file argument gets the settings
as a folder does. The browser has no settings file and starts in the
default theme (`settings_use_default`). A shot, a smoke run, playback and the harnesses never
take that path, so they draw in Dark+, the palette's compiled-in
values, and never read or write the user's file. Saving the file from the editor reads it again. A setting
the file gets wrong is skipped, the rest apply, and a warning notice
names the first problem: invalid JSON with its line, an unknown theme
or color name, or a value that is not a color. A missing file is the
defaults.

Every color the editor draws with is a variable in lib/theme.mc, one
per slot, 76 in all: the editor, the chrome, the diff and git colors,
the terminal's built-in scheme and ANSI sixteen, and the eleven token
classes. The drawing code reads the variables, as it read constants
before. A slot's name is the reference editor's color id where one
exists. A theme is a table of all 76 values, compiled in. `theme_load`
copies a table into the palette, `theme_override` sets one slot by
name, and `theme_commit` copies the palette into the variables. The
variables start with Dark+'s values, which a harness run keeps. The other tables come from theme files in the reference's
format: its own themes and a set of widely used MIT-licensed ones
(THIRD_PARTY.md). A color a theme leaves out takes the reference's
default for a dark or a light theme, and the token classes take the
color of their TextMate scope. A translucent background color is
blended over the editor background, since those slots are drawn
opaque. The terminal's built-in scheme follows the theme. When the pane
shows the user's own terminal colors (Ctrl+K P), those stay.

Ctrl+= and Ctrl+- zoom the window by a step, and Ctrl+0 resets it, as
in the reference. Every size the editor draws derives from the dpi:
the two faces, the line height, the widgets and the icons. The zoom is
therefore a factor on the dpi the fonts are made at (`zoom_dpi`), and
the window's own dpi stays as the platform reports it, so the title
bar's buttons do not change. A step writes the level
into the file and the file is read again, as the theme picker does, so
the zoom outlives the session and a hand edit of the file applies it.
The fonts keep a context per dpi, so going back to a level is a lookup.
A scroll kept in pixels (the other panes', the other buffers') is
converted to keep its top line.

Ctrl+, (Preferences: Open Settings (JSON)) opens the file, and creates
it from a template that lists the names when there is none.

Preferences: Color Theme opens the theme picker: the command palette
over the theme rows alone, on the theme in use. The selected row is
drawn as the selection moves or the filter changes. The preview is the
file read again with that theme in place of its own
(`settings_preview_theme`), so the overrides show on it. Enter keeps
the selection: it writes the theme's name into the file's
`workbench.colorTheme` and reads the file again. The edit replaces the
value where it is and keeps the rest of the file, comments included; a
file without the key gets it as its first member. Escape, a click
outside or any other close puts back the theme the picker opened on.
With the settings off, as in a harness, the picker lists the themes
but previews and writes nothing, so a fuzz run stays in Dark+.

Light Modern draws as the others do, but text rendering was tuned
against dark backgrounds (TEXT_CONTRAST and TEXT_GAMMA in the D3D
shader, stem darkening on macOS). Light backgrounds are not tuned
yet. `--theme <name>` draws a run in a built-in theme with no
overrides, for a shot.

### Explode view

Ctrl+M (View: Explode Open Editors) shows every open buffer and every
live terminal at once, zoomed out in a grid over the window. The
buffers come first in slot order, then the terminals, as the switcher
lists them. The sidebar is set aside while it is up. A buffer's tile
has a header with its name and a dot when it has unsaved changes, and
shows the buffer where it was last left: its scroll, highlighting,
selection and change marks. A terminal's tile has its label and shows
its screen at its scrollback position. The view opens on what the
active pane shows. The arrows, Home and
End move over the grid, and so does the pointer: a tile under it is
selected. The wheel or the touchpad scrolls the buffer of the tile
under the pointer, or the selected tile's between the tiles, by the
lines it would scroll in the editor whatever the tile's scale; the
buffer then opens where it was scrolled to (`ed_buf_scroll`). The
loaded buffer scrolls its live view, which the tiles copy from; any
other scrolls the view its slot keeps. Over a terminal's tile it moves
the scrollback by whole lines. Typing filters the tiles by name,
ignoring case. Enter or a click on a tile opens the buffer or the
terminal in the active pane.
Escape, Ctrl+M or a click elsewhere returns to the editor as it was.
The view draws in the window that has the keys.

explode.mc holds the state, the input and the layout. The layout tries
every column count and keeps the one that gives the tiles the largest
scale. Each tile has the shape of the pane a tile draws in, which is
the active pane. view.mc draws it (`explode_render`). For a buffer's
tile, `ed_tile_begin` loads the buffer into the globals in that pane's
place and marks the pane a document pane, `doc_render` draws it
through `draw_transform` and the tile's clips, and `ed_tile_end` puts
the pane back. For a terminal's tile, `ed_tile_begin_term` points the
pane at the terminal, `term_render` draws it, and `ed_tile_end_term`
restores the pane. The diff is off while a
tile draws, since its pairing is one file's. A tile below a scale of
0.35 draws the code's shape instead of its glyphs: each run of one
token class is a bar in its color, one quad per run. A terminal's
small tile has one bar per run of non-blank cells with one foreground
color (`view_term_shape`). So does a tile that would take the quad
batch past its limit. A window too small for
any tile shows only the filter.

### Call graph

Ctrl+Shift+M (View: Call Graph) shows the function at the caret in the
middle, the functions that call it in a row above, and the functions
it calls in a row below. A curve joins each card to the center, and
each card meets its own point along the center's edge. The data is the
language server's call hierarchy: `textDocument/prepareCallHierarchy`
at the caret, then `callHierarchy/incomingCalls` and
`callHierarchy/outgoingCalls` for the item it names (src/lsp.mc). The
view opens at once, and the rows fill in as the replies arrive; only
the newest reply to each request is taken. A server without
`callHierarchyProvider` gets a message in the view instead.

The cards draw the functions' lines themselves (src/view.mc,
`calls_draw_lines`), each line through the editor's lexer. The text
comes from the active buffer when it holds the file, else from the
file on disk; up to 16 files are kept, each read once while the view
is open, with the start of every line indexed. No file is opened in
the editor.

The center card is sized to its function: as wide as its widest line,
as tall as its lines, in the middle of the band between the rows.
When the lines do not fit the band, the first of these that fits is
taken: one column scaled down to 0.8, then two columns no smaller than
0.8. Else the lines are cut at 0.8, in two columns when two fit across,
and a last line counts the rest (`calls_center_fit`).

The callee the selection stands for, its own card or its file's, gets
the selection color behind its calls in the center, so the pointer
over a callee shows where it is called. The sites are the callee's
`fromRanges`, which are in the center's file; a row keeps up to eight. When the function is
cut and that callee's first call is below the lines shown, the center
shows the lines around it instead, the call a third of the way down,
and the last line says which lines these are.

A small card shows the function's name, its file and line and how many
call sites there are, then three lines of code at 0.8: for a caller
the lines around its first call, the call's line marked with the caret
line's band; for a callee the start of its definition.

A row with more functions than fit shows one card per file, and a file
with a single function shows the function. Enter or a click on a file's
card shows its functions in the row, with an "all files" card that
goes back. Files, or an open file's functions, that still do not fit
are shown a page at a time: an "N more" card shows the next page and
keeps the selection, so repeated presses page on, and an "N before"
card goes back to the page before.
The rows are grouped by file in the order each file first appears.

Enter or a click on a caller or a callee makes it the center. The old
center goes on a trail, and Backspace goes back along it. Enter or a
click on the center opens the function in the editor and closes the
view. The arrows move between the cards: Up and Down between the rows
and the center, Left and Right along a row. The pointer over a card
selects it. Escape or Ctrl+Shift+M again returns to the editor.

The layout is computed from the window's size by the frame and by
every input (`calls_relayout`), so a key finds the cards without a
frame drawn first. The curves are cubic curves in short straight
segments, each a quad along its direction (`draw_segment`, lib/draw.mc).

### Image viewer

A .png, .jpg or .jpeg file opens as a buffer that shows the image
instead of text (src/image.mc). The buffer slot keeps the image's
index plus one in `EdBuffer.img1`, so a zeroed slot is a text buffer;
`g_img` is the loaded buffer's index, -1 for text. An image buffer
holds an empty text buffer and has no lexer, no git baseline and no
language server document. Typing, pasting and saving do nothing:
`ed_replace` and `ed_insert` return, and `ed_save` says the image is
read-only.

The decode runs on a worker thread with the stdlib's `png` and `jpeg`
modules. The decoder is chosen by the file's first bytes, not its
extension. A JPEG is turned upright by its EXIF orientation. An image
wider or taller than 8192 pixels is halved until it fits a texture.
The worker posts the pixels and wakes the UI thread; `image_pump`, on
that wake, makes the texture with `gpu_image_create` and frees the
pixels. Each entry has a generation number, and a result for an older
generation or a closed buffer is dropped. The harnesses and the wasm
build decode inline.

`image_render` (src/view.mc) draws the image through `draw_image`, in
a run of its own (see "Rendering"). An image opens fitted to the pane,
and one smaller than the pane opens at its own size. A transparent image
has a checkerboard behind it, with colors taken from the background's
lightness. From three times its size up, the texels are drawn as
blocks instead of smoothed. The status bar shows the image's size,
the file's size and the zoom in place of the line and column.

`+` and `-` zoom, `0` fits the image to the pane and scales a small
one up to fill it, `1` shows the image at its own size, and
the arrows pan by an eighth of the pane. A wheel notch zooms around the
pointer. A touchpad's scroll and a drag with the left button pan. An
image smaller than the pane stays centered on that axis. The file
watcher's change calls `image_disk_check`, which decodes the file
again when its stamp moved; the old picture shows until the new one
is ready. Closing the buffer frees the texture.

### Session persistence

A folder launched without a file argument restores its last session
from `.edminc/session`. The session holds:

- the open files, where a `preview` line names the record of a file
  that was a preview
- the pane layout
- each caret and scroll
- which panes are terminal panes, as a `term` line after the pane's
  record. The restore opens a fresh shell there. The build pane and
  background terminals are not kept.
- the sidebar's dragged width, as a `sidebar` line. The pane dividers
  are fractions of the width right of the sidebar, so without this
  line a restart moves every pane.

The version-2 format also records every window's position and size,
and keeps the active window by ordinal. A restart places each window
where it was, across displays. Drivers without multi-window restore
only the first window. The editor writes the state on quit, on
focus-out, on a file open or close, and on a folder switch. The native
drivers enable the feature only on an interactive flag, so the harness
and the --shot/--play/--smoke paths never touch a session file. The
tree and the picker hide the `.edminc` folder, and it is gitignored.
The browser build does not persist sessions.

### File tree, picker, search, find

`edmc <folder>` opens that folder as the project. The editor changes
its working directory to the folder before anything scans it, so the
tree, the picker, search, git and the server's root all start there.
A file argument after the folder is relative to it. Ctrl+K Ctrl+O
switches the folder: Windows and macOS open the system folder dialog,
and Linux and the browser ask in the input box that save-as uses. The switch closes the buffers (an unsaved buffer blocks
it), stops the server so that it restarts in the new root, and
rescans the tree. The browser build has one folder and refuses the
switch.

Ctrl+N opens an untitled buffer in a new tab, unless the active buffer
is already untitled, clean and empty. Ctrl+S on an untitled buffer
asks the platform for a path (`plat_pick_save`): the shell's
IFileSaveDialog on Windows and NSSavePanel on macOS, starting in the
project folder. The dialog asks before it replaces a file. It opens
after the key's event has returned, and the path arrives through
`app_save_picked`. A path inside the project folder becomes relative
to it, with '/' separators. Linux and the browser have no dialog and
open the input box instead.

A right click on a tree row selects it and opens its context menu
(src/menu.mc), and below the last row the project root's. With the
tree focused, the menu key (`K_MENU`: VK_APPS on Windows, XK_Menu on
X11, ContextMenu in the browser) or Shift+F10 opens the selected row's
menu under its name, on the first entry. The menu is
an overlay drawn like the others. It takes the keys while it is up,
and the entry under the pointer is its selection. A press on an entry
runs it, and a press anywhere else, Esc, a scroll or the window
losing the focus closes it. A folder's menu has New File and New
Folder, a file's has Open to the Side, and both have Reveal, Copy Path
(absolute, with the platform's separators), Copy Relative Path, Rename
and Delete. Open to the Side opens the file in another document column
than the active pane's: the nearest to the right, else the nearest to
the left. Only a layout with no other document column is split, so two
columns stay two whichever has the focus.

Delete (the menu, or the Delete key in the tree) moves the entry to
the system's trash through `plat_trash`, with no question asked, since
the trash keeps it to restore: SHFileOperationW with FOF_ALLOWUNDO on
Windows, NSFileManager's trashItemAtURL on macOS, and the freedesktop
trash under $XDG_DATA_HOME on Linux. The Linux trash writes the
`.trashinfo` record, then renames the file into `Trash/files`, so an
entry on another file system than the home trash is refused. The
buffers of a deleted file, or of the files under a deleted folder,
close (`ed_paths_deleted`). One with unsaved changes stays open, so
they can still be saved elsewhere, and the notice says so. Reveal (`plat_reveal`) opens
Explorer or the Finder with the entry selected. Linux has no call to
select a file, so it opens the folder with xdg-open, from a child that
forks again and exits, so the editor waits only for that child.

New File, New Folder, Ctrl+K F (a new file in the selected folder)
and F2 (rename the selected row) type the name in the tree. The tree
holds what is being named (`tr_edit`), and the walk adds a row with an
input at the top of the target folder, or marks the renamed row, so
the input survives a rebuild by the watcher. Enter commits and Esc
cancels; a press anywhere else commits, or cancels when the name is
refused. A refused name (one that exists, or has a character the file
systems reject) keeps the input open with a warning. A new file's name
may name folders, which are made with it; the file opens in a kept
tab. A rename goes through `plat_file_rename` and moves the open
buffers at the path, or under the folder, to the new path
(`ed_paths_moved`); the server hears the old name close. The expanded
folders under a renamed folder follow it.

What the tree, the picker, search and the watcher leave out is decided
in src/gitignore.mc. The gitignore rules are git's: `.git/info/exclude`
and the root `.gitignore`, then the `.gitignore` of each folder on the
way down, read the first time a walk reaches that folder, the last
matching rule deciding. A pattern with a slash before its end is tied
to its file's folder, one without matches a name at any depth. `*`,
`?` and `[...]` stop at a slash, `**` as a whole segment spans
folders, `!` un-ignores, a trailing `/` matches folders only, and `\`
escapes. Names compare without case on Windows and macOS, as git does
there. What an ignored folder holds is ignored, and the walks carry a
folder's answer down rather than asking for every folder again.
Every walk of the tree reads the rules again. By default the tree
shows ignored entries dimmed and the picker and search leave them out;
the settings `explorer.excludeGitIgnore`, `search.useIgnoreFiles` and
`files.exclude` change that ("Settings and color themes"). `.git` and
`.edminc` are always hidden.

### Recent folders

The folders opened most recently are one list for every window and
process, `recent` next to settings.json, one absolute path per line,
newest first, at most twenty (src/recent.mc). A folder goes to the
front when the editor starts in it and when a switch opens it. The
file is read again before each write, so what other editors wrote is
kept. It is read and written only while the settings are on, so the
harnesses never touch the user's list. Paths compare with either
separator, and without case on Windows and macOS.

File: Open Recent... (Ctrl+K R) lists the folders that
still exist, without the one open, and Enter switches to one as
Ctrl+K Ctrl+O does. The list is the palette in a third mode beside the
commands and the theme picker: the folders are rows after the table
while it is open.

A launch that names no folder opens the newest folder on the list that
still exists, wherever it starts, as the reference editor does: from a
pinned taskbar entry, a shortcut, the Dock or a shell. `edmc .` or
`edmc <folder>` opens that folder; a file argument opens the file
where the editor starts. With an empty list the editor stays where it
started. The switch happens in `app_session_restore` before the
session is on, so the folder left behind gets no `.edminc`. `minc run`
passes `.`, so it opens the repository.

Every write of the list goes to `plat_recent_folders`. On Windows it
fills the taskbar entry's jump list, the menu a right click opens,
with a "Recent" category (lib/win.mc). Each entry is a shell link that
starts the running executable with the folder as its argument, titled
with the folder's name, the full path as its tooltip. The app sets no
AppUserModelID, so the shell derives one from the executable's path
and a pinned entry, the running window and the list match. Building
the list loads shell objects and writes to disk, so a worker thread
does it through `ICustomDestinationList`: the call copies the paths,
signals a semaphore and returns, and the worker takes only the newest
request. The worker waits on the semaphore between requests, so it
adds no wakeups. A folder the user removes from the jump list is never
added back, which the shell requires. It returns to the UI thread
through a posted `WM_RECENT_REMOVED`, and `app_recent_forget` takes it
off the recent list too. The other platforms do nothing yet; on macOS
the Dock menu is the counterpart.

The Ctrl+B file tree expands directories lazily, draws codicon glyphs,
opens a file on click and supports keyboard navigation. Ctrl+E focuses
it, and so does Ctrl+Shift+E, the VS Code chord. Space opens a row and
keeps the focus. Enter opens a row and passes the focus to the editor.
Ctrl+1..3 and Ctrl+\ take the keyboard back. Names take their git
color, with the state letter at the right and a dot on a folder that
holds changes. Visibility is per window and the content is shared.

Ctrl+P is a fuzzy file picker over a tree scan. After the first character, each query
character must continue a run or start a word, as in VS Code's
matcher. Letters scattered through a path therefore do not match.

Ctrl+F is a find widget. It runs a chunked case-insensitive scan and
shows a match count and highlights in the viewport. Ctrl+H (Cmd+Option+F
on macOS, where Cmd+H hides the application) adds the replace row, as
does a click on the chevron. Enter in the replacement replaces the
selected match and selects the next one. A selection that is not a
match only moves to the next one, so the first press shows what the
second replaces. The replace buttons do the same by pointer. Replace
all writes one edit from the first match to the end of the last, so
one undo restores every match. Ctrl+Enter replaces all, as Cmd+Enter
does in the reference on macOS; Windows delivers no character for the
reference's Ctrl+Alt+Enter. Enter arrives as text with no modifiers,
so the widget reads the modifiers held as of the last key or pointer
report (`ed_mods_held`), which the platforms send on a modifier-only
change. Windows sends Ctrl+Enter as a line feed, which the widget
takes the same way. Undo and redo with the widget open act on the
buffer and keep the widget, and the count follows the text. The
renderer and the click test read one layout (`find_layout`). The Ctrl+Shift+F
sidebar view runs a threaded project search. The search starts when
typing pauses (SEARCH_TIMER, 200 ms, restarted on every change) or at
once on Enter. An emptied query empties the list. The same view shows
Shift+F12 references.

Ctrl+Shift+P, or F1, is the command palette (src/palette.mc): every
command bound to a chord is a row, with its chord shown at the right
in the platform's names. The query is matched with the picker's scorer
and an empty query shows the table's order. A row runs its chord
through the key path the keyboard uses (ed_key_synth, which clears the
chord's wait for a following character), so the palette and the
keyboard cannot disagree on what a command does. A Ctrl+K chord is
sent as its prefix and its second key, Enter as the character it is.
Help: Report Issue has no chord: it opens the project's GitHub issues
in the browser through `plat_open_url`.

Every query line (the picker, the symbol search, the switcher, find,
search, the palette, and the input box) is a UiField in lib/ui.mc. The
widget owns the bytes, and the field owns the caret and the selection.
The keys are the editor's own single-line keys: arrows, Home/End, the
word chords, Shift to extend, Delete, and the primary's A, C, X and V.
A paste takes the clipboard's first line. The text scrolls inside the
box to keep the caret in view.

### LSP features

The client supports diagnostics, goto-definition, hover, references,
completion, signature help, workspace symbols, semantic tokens and call
hierarchy over its JSON-RPC. `EDMINC_LSP` names another server binary
than the `minc-lsp` on the PATH, such as a development build.

Two servers run side by side. `lsp_on`, `lsp_ready`, the position
encoding, the sync mode, the capabilities and the table of opened
documents describe the current server. `lsp_use` saves them and loads
another server's. The editor makes the current server the one for the
buffer in its globals, at every place that loads a buffer's language.
`lsp_pump` makes it the server whose message it handles, then returns
to the buffer's. Request ids come from one counter, so a reply matches
its request whichever server sent it. The reader and writer threads,
the frame accumulator and the writer queue run beside the main thread,
so they are indexed by slot. The queue to the main thread tags each
payload with its slot. A didClose goes to every server, since the
closing buffer need not be the current one. Semantic tokens come from
minc-lsp only: the legend is one for the editor, and C keeps the
lexer's colors.

Text sync is incremental when the server grants it with
utf-8 positions. text_buf reports every insert and delete in byte
columns, and the next push sends those ranges as one didChange. A
buffer switch, a fresh didOpen, an overflow, or a utf-16 server makes
the push send the full text.

A diagnostic is drawn as a wavy underline in its severity's color, a
mark in the gutter, and a mark on the scrollbar. Ctrl+K D, or
`"editor.renderValidationDecorations": "off"`, leaves the underlines
out of the text for every severity (`g_squiggles`). The gutter mark,
the hover message and the status bar line stay.

Completion asks the server once per word and narrows the list as more
is typed. It ranks entries by the server's sortText scope prefix, with
the builtin types first. clangd ranks its own list, so its entries keep
the order they arrive in. Its rows show the label, which holds the
declaration (`atomic_load(object)`), and accepting one inserts the
item's edit text, which is the name. clangd starts without snippets,
header insertion or the label's insertion marker, so the name is all
there is to insert. A list it marks `isIncomplete` is asked for again
once typing pauses, and the reply replaces it. The popup draws the label in the mono code
face, as it will read once inserted, and its type detail in the
smaller UI face, clipped to the panel. The automatic trigger reads the
lexer's per-byte class and does not fire in a comment, string, or
escape. Ctrl+Space asks anywhere.

Typing `(` after a name shows signature help above the line (the hover
text for the name), so it never covers the call. It stays open while
arguments are typed and closes on Escape or when the caret leaves the
call. Ctrl+T is workspace symbol search. Each keystroke sends a query,
and the editor uses only the newest reply.

Semantic tokens lay the server's classes over the lexer's for the
visible lines. The editor requests the full list on a debounce that
resets on each edit, so the request fires once after typing pauses.
The full list is O(file) to parse. The editor keeps the list for the
active buffer and shifts it by line as edits arrive. An edited line
uses the lexer's classes until the next reply, and a buffer switch
drops the list. The lexer remains the immediate first pass.

### Git gutter and tree decorations

A worker fetches HEAD's bytes (`git show`). A Myers line diff then
compares them to the buffer and is recomputed on each edit. text_buf
reports each insert and delete, the buffer's line hashes follow, and
the diff walks only the edited span. A wide span falls back to a
timer. Deleted lines are marked with a triangle wedge, a second shape
glyph beside the change squiggle.

The same worker runs `git status --porcelain` for the tree
decorations, one job at a time: at start, after a save, and after a
folder switch. The states live in a hashed path table, and a folder
holds the strongest state under it. The baseline fetch keeps one job
in flight and one queued. `app_wake` requests the active buffer's
baseline again once the worker is free and the buffer still has none.
This covers a file left active by a session restore.

The change gutter belongs to the shared buffer and survives a second
view of a file. The live git state moves in and out of the slot with
the buffer. When a fetch completes, the handover finds the requesting
buffer by path wherever it is shown.

### Changes view and diff

Ctrl+Shift+G puts the sidebar on the files git reports as changed,
instead of the file tree. The rows, scrolling, selection and renderer
are the tree's. Only the source differs. A changed file is a row with
its folder dimmed beside the name and the state's letter at the right.
The paths come from the same `git status --porcelain` run the
decorations use. The decorations look up a path's state by its hash,
and a hash table cannot be enumerated, so the run also keeps the paths
as a list. Paths outside the open folder are left out, as they are in
the tree.

The list is under two headings, Staged Changes and Changes, because
porcelain's two columns record different things: the index against
HEAD, and the working tree against the index. A file that is staged
and then changed again is under both, each with its own column's
letter. One combined state could not express that. A heading is a row
like a folder's, so the arrow keys fold it the same way. It shows the
count of the rows under it whether it is open or folded. A heading
with nothing under it is not drawn.

Opening a row shows the file against HEAD in two panes: the HEAD
version on the left, the live buffer on the right. The left side is a
document built from the bytes the gutter's worker already fetched. It
is held outside the buffer table (`BUF_DIFF_BASE`). The editor builds
it with `tb_quiet` set. text_buf reports every insert to the change
gutter and the token list, and those belong to the buffer on screen.
Without the flag, filling the baseline with a file moved that file's
tokens down by its own length and shifted its colors. None of the
other rules for a document apply to the baseline. It is never picked,
evicted, saved, restored into a session, or named to the server. It
never takes the focus, so `g_buf_active` stays a slot. The right side
is the buffer itself, with its cursors, undo and language server.
Typing into a diff works as in any other view, and the diff re-pairs
as the text changes.

The alignment comes from the diff git.mc already runs. The Myers pass
marks the matched lines on both sides. The gutter collapses that onto
the buffer's lines, and the same walk, kept as pairs, gives the diff's
rows. A row names a line of the baseline, a line of the buffer, or
both. A -1 is a filler where one side has no line to set against the
other. In a diff a screen line holds a row instead of a line.
`ed_row_of_line`/`ed_line_of_row` convert between the two,
`scroll_set` clamps in rows, and both panes use the file pane's
scroll, so the columns cannot drift apart. For the same reason,
everything outside the renderer that places something beside a line
(the caret, popups, a click) goes through `ed_line_y`/`ed_line_at_y`.
The editor builds the rows only while a diff is open. They belong to
the view and not to either buffer, so the per-buffer git handover in a
pane swap does not touch them.

A change band colors each row by what happened to it on that side. A
filler is ruled with 45-degree lines, so it reads as no line at all
and not as a blank line. The rule is a shape glyph (font.mc,
SHAPE_HATCH) like the squiggle. It is a tile rasterized once per dpi.
Its side is the line height and its stripes are a third of that. The
stripes are spaced so that a pixel is under a line when x + y is near
a multiple of the spacing. This makes the tile seamless in both
directions. One tile per row therefore draws a run of filler rows as
one ruled field instead of a stack of rows, at about half a row of
text in quads.

The diff opens on the first change. F7/Shift+F7, the primary modifier
with the up and down arrows, or the two arrows at the right of the
banner walk the rest. The arrow chord is bound only while a diff is
open, where no other command uses it. The banner arrows' rect is
stored in ed.mc with the rest of the pane geometry, so the drawn and
the clickable areas cannot drift apart, and a headless run can press
the arrows. They highlight under the pointer like the caption's
buttons. The pointer stays the plain arrow over the banner, since the
banner is chrome and not text. app_hover handles the highlight,
because a pointer with no button held never reaches app_mouse_move,
which is the drag path.

Each changed block has a revert arrow at its first row, in a column
left of the file pane's line numbers (`ed_diff_margin_w`, which
`gutter_w` adds). A click replaces the block's buffer lines with its
baseline lines in one `ed_replace`, so one undo brings the block back.
A block with no lines on one side takes or gives one newline: removed
lines take the newline after them, or the one before them at the end
of the file. The arrow is drawn on the divider's grab band, and on its
rows the arrow takes the click and the pointer shape. A commit's diff
has no arrows, since its right side is read-only. When the rows wait
on the gutter's timer, a click recomputes them and reverts nothing,
because the arrow was drawn from rows that may not match the text.

The walk puts a change in the middle of the view, not only on screen,
because a change is read with its context. When the caret is not in
the view, the walk starts from the view. A scroll moves the reading
position without moving the caret. The wheel over either side scrolls
the view, since the baseline has no scroll of its own. Opening another
file on screen ends the diff, because the pairing belongs to one file.

The left side never takes the focus, since it has no buffer slot, but
its text selects and copies. A drag, a double click (a word) or a
triple click (a line) there loads it the way the frame build does,
sets its own selection in its pane record, and puts the file's pane
back; the view draws that selection as it draws any pane's. The copy
chord takes it while it is the last selection made (`g_bsel`), and a
key or a click anywhere else clears it.

A pane right of the diff's two is not part of it. It shows its own
buffer line by line: the row helpers (`ed_row_of_line`,
`ed_line_of_row`, `ed_row_count`, `ed_line_at_y`), the change walk and
the view's row bands use the diff's rows only while one of the diff's
panes is loaded (`diff_here`). Closing ends the diff first, while the
file's buffer is still loaded. Ctrl+W on the file, from its pane or
from another pane that shows it, ends the diff and then closes the
buffer. Ctrl+Shift+W on one of the diff's panes ends the diff: a pane
the diff made goes with it, and of borrowed panes the left one gets
back what it showed and the right one closes as asked. `ed_diff_close`
keeps the panes right of the two and the focus where it is.

The rows live in git.mc, not in a buffer's `GitState`, because both of
the diff's panes read them. They belong to the diff's file: each
`git_rows_enable(true)` starts a generation, the loaded buffer's
`GitState` keeps the one it had, and a recompute rebuilds the rows only
for the buffer that holds the current generation. A baseline reply for
another buffer, or an edit in a pane beside the diff, recomputes that
buffer's gutter and leaves the rows alone. A new baseline for the
diff's file itself, after HEAD moved, rebuilds the left side from it
(`diff_rebase`); a reply with no baseline ends the diff.

An edit whose diff spans more than `GIT_SYNC_SPAN` lines recomputes
the rows on the gutter's timer. Until it fires, a row can name a line
the edit removed, and `ed_line_of_row` treats that row as a filler. The
scrollbar's thumb counts rows in the diff's panes, where the scroll
position is in rows.

### History graph

The changes view's lower panel shows HEAD's history (src/hist.mc), as
the reference's Source Control Graph does. The sidebar is split: the
changes take the height their rows need, up to two fifths of it, and
the Graph heading and its rows take the rest (`tree_changes_h` in
tree.mc). A click on the heading folds the panel, and the changes then
take the whole height. Each part scrolls on its own. Down past the
last change moves the keyboard into the graph, and Up from its first
row moves it back.

`git log --topo-order` fills the panel 200 commits at a time, with the
hash, the parents, the author, the time, the decoration and the
subject of each, separated by control characters. The next page is
asked for when the view comes within 40 rows of the end. The lanes are
laid out as the commits arrive, in log order (`hist_lay`). A lane
holds the hash of the commit it is waiting for. The lanes waiting for
a commit join its dot from above, and the others pass by. Below the
dot, its lane continues to the first parent. A further parent takes
the lane already waiting for it, or a free one. Each row keeps its
segments, from lane to lane between the row's top, the dot's height
and the row's bottom. A segment that changes lane is drawn as a curve.
A lane keeps its color from the commit that opened it, in the
reference's five colors. The decoration's names are drawn as pills in
the commit's color before the subject.

A commit opens to the files it changed, one commit at a time, with
`git diff-tree -r -M --name-status -z` against its first parent, or
`--root` for a commit with none. The lanes run on past its file rows.
A file opens the diff of that file in that commit. Two `git show
<hash>:<path>` runs fetch the file in the commit and in the parent.
The parent side uses the old path for a rename. A file the commit
added has no parent side, and a file it deleted has no commit side. A
file with a NUL in its first 8000 bytes is binary, and only a notice
is shown.

The diff reuses the HEAD diff (see "Changes view and diff"). The
commit's version goes into a new buffer, and the parent's version
becomes that buffer's baseline (`ed_rev_diff` in ed.mc). The rows,
the bands, the filler hatching and the change walk are then the same
as for HEAD. The buffer has no path, so the disk check, the session,
git's fetches and the language server leave it alone, as they do an
untitled buffer. It is named "file @ hash" (`g_rev_name`), takes no
edits and is never saved. It is a preview, so looking through the
files of a commit leaves no trail of buffers. For a diff of this kind,
`diff_rev` is set and `diff_path` holds the left side's label.

git runs on a worker, one job at a time, with one pending job per
kind: a diff before a commit's files before the next page of the log.
The UI thread takes each result at a wake (`hist_pump`). A folder
switch or HEAD moving (the watcher's HEAD record) resets the panel.
Each reset starts a generation, and a job from an earlier one is
dropped when it lands. The harnesses and the browser run the jobs
inline. The harnesses' git answers a fixed history of five commits,
with a side branch and a merge (src/harness_plat.mc).

### Files changed on disk

The editor watches the project folder and every folder under it. On
Windows, `plat_watch_open` opens the folder handle and issues an
overlapped `ReadDirectoryChangesW` with the subtree flag, so one handle
covers the whole tree, `.git` included. A thread in src/watch.mc waits
in `plat_watch_read`, which waits on the read's completion event and a
stop event together. It appends the records to a queue and posts the
wake. A record is a kind byte (`c` for a file's content, `m` for an
entry created, deleted or renamed), a path relative to the folder, and
a newline. A read of zero bytes means the system's buffer overflowed
and changes were lost.

On macOS, `plat_watch_open` creates one FSEvents stream over the
folder with file-level events and no deferral, on a dispatch queue of
its own, so the main run loop takes no part. The stream's callback
turns each event into the same record: created, removed and renamed
flags are `m`, modified and inode-metadata flags are `c`, and the path
is made relative to the folder's real path. A write that makes the
file anew carries the created flag, and the stdlib's `file_write`,
which the editor's own saves use, writes that way; `m` wins over `c`,
so such a save rebuilds the tree too. A missed new file would show, an
extra rebuild does not. A write in place reports `c`. It writes the records into
a pipe, and `plat_watch_read` blocks in `read()` on the pipe. A read
returns whole records only; the tail a read cut off waits for the next
call. `plat_watch_close` writes a stop record, which the read answers
with -1, and `plat_watch_free` stops the stream and closes the pipe.
The stream's own drops (its buffer overflowed, a subtree must be
scanned, the root moved) become a lost record, and so does a record
the full pipe could not take: the write end does not block, so the
queue's thread is never held. The read answers those with 0.

Linux and the browser have no watcher yet: `plat_watch_open` returns
-1 there.

`watch_pump` drains the queue on the UI thread. `watch_feed` drops the
paths no view depends on: `.edminc/`, what `files.exclude` hides, and
everything under `.git/` except `HEAD`, `packed-refs`, `refs/`,
`index` and `info/exclude`. A gitignored path changes neither git's
status nor a buffer; it refreshes the tree only while the tree shows
ignored entries. A change to any `.gitignore` or to
`.git/info/exclude` makes the rules be read again. Any other record arms `WATCH_TIMER`, and the
refresh runs `WATCH_MS` (200 ms) after the first record of a burst, so
a checkout or a build is one refresh. The timer is set only while
records arrive, so idle stays at zero wakeups.

The refresh does what the records call for:

- The index or a tracked file changed: `git_status_touch` fetches the
  tree's git status again.
- HEAD, a ref or packed-refs changed: `ed_git_refetch_all` marks every
  open buffer's baseline stale. The fetches run one at a time from the
  wake, the loaded buffer first, then the buffers on a pane. Each
  buffer keeps its old baseline on screen until its reply replaces it.
  A reply with no baseline clears it.
- An entry was created, deleted or renamed: the tree rebuilds.
- A tracked file changed: `ed_disk_check_all` compares each open
  buffer with its file.
- Changes were lost: all of the above.

Each text buffer records the FNV-1a hash and length of its file's
bytes when it loads or saves (`disk_hash`, `disk_len` in `TextBuf`).
The check reads the file and compares:

- The same bytes: nothing to do. The editor's own saves end here.
- Different bytes and a clean buffer: `ed_reload_text` replaces the
  span that differs with one `ed_replace`. Undo, the server's
  incremental sync and the gutter treat it as a normal edit. The
  buffer is clean after it, and an undo makes it dirty again. The
  caret, the extra cursors, the scroll position and the preview flag
  stay as they were. A buffer that no pane has loaded is loaded for
  the reload and pushed to the server, the way a baseline reply
  reaches a background buffer.
- Different bytes and unsaved changes: the buffer keeps its text, and
  a warning notice says the file changed on disk, once per version of
  the file.
- No file: the buffer stays as it is, and a warning notice says the
  file was deleted.

A save checks the file first on every platform, with or without a
watcher. When the bytes on disk differ from the ones the buffer loaded
or last saved, the first save refuses and says so, and the second one
overwrites (`g_save_armed`).

`watch_settle` runs a refresh that is due at once. `app_settle` calls
it after `watch_pump`, so a headless run can show a reload in a dump:
the platform's timer never fires there.

### Terminal

A shell runs in a pane. Ctrl+K T opens one in the active pane, and the
shell replaces what the pane showed. The shell is pwsh 7 behind ConPTY
on Windows and `$SHELL -l` behind a pty on macOS and Linux.
`EDMINC_SHELL` overrides the choice. The browser build has no
terminal. The terminal has three layers. The middle one is portable,
and it is the only part the harness runs:

    child (pwsh / zsh / bash)
        |  pseudo-terminal: bytes both ways
    platform: plat_term_* in win.mc / mac.mc / x11.mc
        |  reader thread -> queue -> plat_wake; writer thread <- queue
    src/term.mc: the plumbing, the VT emulator and the screen grid
        |  cells, scrollback, cursor, modes
    the pane kind in ed.mc and view.mc
        |  draws the grid, encodes keys, resizes the pty

The contract in lib/plat.mc uses one handle per terminal.
`plat_term_spawn` takes the cell size, an argv and `under`. An empty
argv starts the user's shell. On POSIX a command runs through the
login shell's `-c`, so the user's PATH applies. On Windows it runs as
a command line. `under` says the screen already holds text and the
child starts below it. `plat_term_read` blocks until the child writes.
It returns 0 or less once the child has exited. `plat_term_write`
writes to the child, `plat_term_resize` resizes the pty, and
`plat_term_code` returns the child's exit code. `plat_term_kill` ends
the child and the pty. This makes the reader thread's blocked read
return. `plat_term_free` releases the handle after that thread has
exited. The two calls are separate because the reader thread still
uses the resources a kill would otherwise close. `plat_term_export`
and `plat_term_adopt` carry a pty across the restart's exec ("The
restart"). `plat_term_palette` returns the colors the user set in the
platform's own terminal.

A pty is not `plat_child_*`. The child gets a controlling terminal, a
window size and the signals that come with them. Every shell checks
for these before it behaves as an interactive shell. The child gets
`TERM=xterm-256color`, `COLORTERM=truecolor` and
`TERM_PROGRAM=edminc`. The layer removes the launching terminal's
`TERM_SESSION_ID`. Without that, a shell started from Terminal.app
restores that session into the pane.

Windows: the layer calls `CreatePseudoConsole` over two pipes, then
`CreateProcessW` with a `STARTUPINFOEX` whose attribute list carries
the pseudoconsole. The layer resolves the three ConPTY entry points at
spawn. The binary therefore loads on a Windows version without them,
and spawn returns -1 there. The console host sits between the child
and the pipes and translates in both directions. The emulator
therefore receives the same byte protocol on every platform.
PSReadLine's history, completion and recall arrive as painted cells.
The prototype (`--term-probe`, which dumps the raw stream) found three
ways the host differs from a pty:

- It clears the screen when it starts, unless it is told to keep the
  cursor where it finds it. The `under` flag does this after a
  restart.
- It resizes by reporting the new size as `CSI 8 ; rows ; cols t` and
  repainting the full buffer.
- It sends sequences of its own (win32 input mode, and that size
  report). The emulator drops them.

The startup block sets the child's standard handles to empty.
Otherwise a shell spawned from an editor whose own output is
redirected writes to that redirect, and the pane stays empty. A kill
ends the pty before it closes the read handle. Closing a handle does
not end a read that is blocked on it. Ending the pty does.

The host does not always exit when the child does: a process the child
started on the same console keeps it alive, and so, at times, does
nothing visible. The output pipe ends only when the host exits, so a
pane waiting for end of file waited for good, and the build pane
reported "a build is already running". A thread per terminal waits on
its own copy of the child's process handle and closes the pty when the
child exits. The host writes what it holds and exits, the reader gets
its end of file, and processes left on the console get the close
event. Windows Terminal ends a session the same way. The kill and the
waiter take the pty handle under a lock, so it is closed once.

A command, as opposed to a shell, starts suspended, goes into a job
object of its own and then resumes, so every process it starts is in
the job. A kill terminates the job before it ends the pty.

macOS and Linux: the layer calls `posix_openpt`, `grantpt` and
`unlockpt`, then forks. The child calls `setsid`, opens the slave as
its controlling terminal, sets its size, closes every other descriptor
and execs the shell. The parent reads and writes the master. A resize
is `TIOCSWINSZ` on the master. A kill sends `SIGHUP` and then closes
the master. The reader's blocked read then fails with EIO, and the
layer reports that as end of file. `plat_term_code` reaps with
`WNOHANG`, and `plat_term_free` reaps with a blocking wait. The two
arms share their code and differ only in the library name and a few
constants.

The threads follow the structure of src/lsp.mc, one set per handle. A
reader thread blocks in `plat_term_read`, appends the bytes to a queue
under a mutex and posts the wake. `app_wake` drains every terminal's
queue into its emulator (`term_pump`, `term_feed`). It marks damage
once, and only when the terminal is on screen in some window or the
switcher is open, since the switcher lists terminals. A build put
aside or a shell the user switched away from therefore draws no frames
while it runs. The main thread drains the queue once per loop
iteration, not once per read. A burst of many reads therefore produces
one frame. A writer thread per handle drains an outbound queue into
`plat_term_write`. A key press therefore never waits on a full pipe.
The UI thread never waits for either thread. A kill ends the reader's
read, and the editor joins the thread at quit. The harnesses set
`term_threaded` to false, as they do `lsp_threaded`. The terminal adds
no timers. A quiet shell runs no code in the editor, and idle stays at
zero wakeups while a prompt waits.

The emulator is a screen grid. It is not a text buffer. A cell holds:

- a grapheme cluster. Joiners attach to the cell before them, and the
  cluster bytes live in a slot table per terminal. An emoji
  presentation makes the cell wide and the next cell its tail.
- a foreground and a background, already resolved to colors.
- attribute bits: bold, dim, italic, underline, inverse, strike. Blink
  is stored and never drawn, since a blinking cell would wake the idle
  editor twice a second.
- `TA_WRAP` on a row's last cell when the line continues in the next
  row.

The screen is rows by cols. The scrollback is a ring of
`TERM_SCROLLBACK` (2000) lines, allocated when the first line scrolls
off. The alternate screen is a second grid with no scrollback. Mode
1049 swaps it in. Leaving it swaps it out and restores the primary
screen's cursor. The cursor has a position, a visibility, a shape
(DECSCUSR) and a saved copy. The modes are application cursor keys,
origin, auto-wrap, cursor visibility, mouse reporting (1000/1002 with
the SGR encoding), focus events, the alternate screen and bracketed
paste. The emulator also keeps scroll regions and tab stops. The
parser is the DEC state machine over the bytes. A sequence split
across two reads therefore parses the same as one that arrives in a
single read. The ground state decodes UTF-8 with the editor's own
decoder, and an invalid byte becomes U+FFFD. The sequence set covers
what current shells, vim, less, git's pager and Claude Code emit:

    cursor    CUU CUD CUF CUB CNL CPL CHA CUP HVP VPA  DECSC/DECRC
    erase     ED (0-3, 3 clears the scrollback)  EL (0-2)  ECH
    edit      ICH DCH IL DL  SU SD  DECSTBM
    attrs     SGR 0-9 22-29 30-37 39 40-47 49 90-97 100-107
              38;5;n 48;5;n 38;2;r;g;b 48;2;r;g;b, and the colon forms
    modes     DECSET/DECRST 1 6 7 12 25 1000 1002 1004 1006 1049 2004
    reports   DSR 6 (and the private form)  DA (one fixed string)
    osc       0/2 (the title)  52 (clipboard set)  the rest discarded,
              ending in BEL or ST
    misc      RI IND NEL HTS TBC  DECSCUSR  the C0 controls  ESC c

A private marker (`?`, `<`, `=`, `>`) is part of a sequence's name.
`CSI > 4 m` is xterm's modifyOtherKeys setting, not SGR 4. The kitty
keyboard protocol's push and pop are not a cursor restore. Parsing
them as one moves the cursor to the corner. A parameter after a colon
is a sub-parameter and never an attribute by itself: `4:3` is a curly
underline, `4:0` clears it, and the parser skips `58`. The parser reads
every unrecognized sequence to its end and drops it. It never leaves
one half-consumed. This makes the subset safe: a program that uses a
sequence outside it loses a feature but does not corrupt the screen.
The set is kept small on purpose. A sequence is added when a program
needs it, together with an ed_test case. The legacy paths stay out:
DEC charsets, 8-bit C1 controls, VT52, the X10 and normal mouse
encodings, DECCOLM and the printer.

The emulator resolves colors into the cell as the bytes arrive. It
uses a palette of slots: text, background, bold, cursor, selection and
the ANSI sixteen. It computes the 256-color cube and grays, and takes
truecolor values as given. The grid therefore holds colors, and a test
can assert them. The emulator replies to DSR with the cursor position
and to DA with its identity, and to nothing else. A title from OSC 0/2
goes to the pane banner. The emulator encodes keys in the modes the
child requested: Enter as CR, Backspace as DEL, arrows as CSI or SS3
with the modifier suffix, and the xterm forms for Home, End, the page
keys, Delete and F1 to F12. Ctrl with a letter becomes the control
code, and Alt adds an ESC prefix. A paste is bracketed when the child
requested it, and the mouse uses the SGR encoding when a mouse mode is
on. With no mouse mode the wheel scrolls the history.

The pane has a kind (`PANE_DOC`, `PANE_TERM`) and a terminal handle.
It also keeps a valid buffer index, the one it showed before, so the
pane-swap code and the title need no special cases. A focused terminal
takes every key except the editor's own chords (`term_editor_key`):
pane focus and split, the chord prefix and its second key, the new
window, the picker, the sidebar, the switcher, Ctrl+W, Ctrl+J, quit,
F5 and F8, and the pane move. Ctrl+C and Ctrl+D go to the shell. The
editor's paste chord pastes into the shell, bracketed when the child
requested it. The pane's `app_char` accepts only text, Enter and
Backspace. On a physical keyboard a chord's own control character
follows the key, and the key path has already encoded it. Passing the
character on as well pasted twice, interrupted the shell during a
copy, and sent the second key of a chord to the shell. On macOS the
physical Ctrl key maps to the encoder's control, so Ctrl+C is 0x03 on
every platform and Cmd stays with the editor.

The frame build keeps the grid at the pane's size. `term_resize` does
nothing when the size is unchanged, so one call at the top of the
render handles dividers, the sidebar, the window and the dpi, and no
setter has to call it. The view draws each cell at its cell position:

- the cell's background as a rect behind it
- bold as a second draw one pixel over
- italic as a shear about the baseline
- underline and strike as rects
- inverse with the colors swapped
- dim as the midpoint of the two colors

A cluster shapes to one glyph through `plat_shape_cluster`, as the
document's clusters do. The view draws box drawing (U+2500 to U+257F)
and block elements (U+2580 to U+259F, shades as a blend) as geometry
that fills the cell. Rounded corners are arcs and dashed lines are
dashes, so a logo or a frame joins across cells. Mixed light-and-heavy
joints and double-line joints are drawn as their light or heavy shape,
and the diagonals come from the font. The cursor has the shape the
child set, and the view draws it without the blink timer. The banner
shows "terminal N", numbered in the order opened, with the program's
title after a colon. After the child exits it shows the exit code. The
hover popup does not open over a terminal pane. The selection, the
scrollback view, the reflow on resize, the switcher, the background
terminals, the build pane and the problems walk are under "Build and
run" below. The session and the handover have their own headings.

The palette defaults to green on black, the look of Terminal.app's
Homebrew profile, with the theme's ANSI sixteen. `plat_term_palette`
lays the colors the user set in their own terminal over that. On
macOS the source is Terminal.app's default profile when it is not the
stock Basic profile. The layer reads it from the preferences domain.
The profile stores only what differs from the defaults, as archived
NSColor objects, which the layer decodes and converts to sRGB.

On Windows the source is Windows Terminal's settings.json:

- The layer reads the preview, the stable and the unpackaged copy,
  newest first, and keeps the first that names any colour. Opening
  either app rewrites its file, so the file times show which app was
  launched last.
- It strips comments and resolves the default profile by guid over the
  profiles' shared defaults. It reads the profile's scheme from the
  same file.
- The two schemes the installer assigns (Campbell and Campbell
  Powershell) are built in. The package's defaults.json sits under a
  path that cannot be found from outside the package. Any other
  built-in scheme leaves the ANSI sixteen as the theme's.

Ctrl+K P switches the pane between those colours and the built-in
ones. Only the default text and background change, since the cells
hold resolved colors.

The harness stubs the platform. Spawn returns a handle. Read returns
nothing, and there is no reader thread (`term_threaded` is false).
Write captures the bytes, so a test asserts the exact escape a key
produced. ed_test has a table of cases per sequence family, written as
bytes in and the screen as text out (`^` for escape, a backtick for
the bell, `|` for backspace). The table includes the recorded pwsh
streams, the check that splits input at every offset, the key encoder
under every mode, resize, the alternate screen, the ring's wrap, and
the focus rules driven through `app_key`.

The fuzzer's terminal family feeds generated control sequences with
junk mixed in, in chunks of random size. It runs `term_check` after
every step, which requires:

- the cursor inside the screen
- the scroll region inside the screen
- the scrollback inside the ring
- the parser in a valid state
- no half of a two-cell glyph without the other half

Every operation that moves or clears cells ends in `term_row_fix` to
keep the last condition. For live runs, `--term-grid` runs a shell
through the parser and prints the screen, and `--term-probe` dumps the
raw stream. `--dump-term` and `--term-raw` read a pane headless
(TESTING.md). scripts/macpty_probe.mc runs the macOS pty layer against
a shell with no window.

Cost, measured 2026-09-14: the parser alone processes 45 MB/s at 80x24
and 18 MB/s at 200x60. End to end through a shell the rate is about
2 MB/s, so the console host sets the rate. A frame with a pane full of
terminal text takes the same time as one that shows only the document
(3971 us against 4123 us). The drain is unbounded: one wake parses
everything that has arrived. A scroll moves the screen and pushes a
row into the ring, so its cost scales with the width.

### Build and run

Ctrl+Shift+B runs `minc build` when the project has a build.mc, and
`minc` on the active file otherwise. F5, and the primary modifier with R
(Ctrl+R, Cmd+R on macOS), runs the project: `minc run`, which is the
build.mc's run, or the active file when there is no build.mc. With
Shift (Shift+F5, Ctrl+Shift+R) it runs the active `.mc` file with
`minc run <file>` whether or not there is a build.mc, which runs one
sample in a folder of samples. All four work with a terminal pane
focused: Ctrl+R is the editor's there, not the shell's history search.

A build or a run asked for while one is going is dropped for the first
10 s after that one started, which takes a double press. The refusal
is a notice with the info icon (`ed_notice_info`), which shows with the
status bar hidden too, and it names the seconds left. The build pane
comes back if Ctrl+J hid it. The notice closes when the run ends or a
new one starts. After the 10 s a request stops the run and starts
again, so a run that hangs never blocks the keys.

Ctrl+. (Cmd+. on macOS, Build: Stop) stops the build or run at once.
It kills the terminal's child (`term_stop`) and leaves the terminal:
the pane and its output stay, and the banner reads "run stopped" or
"build stopped". A focused terminal passes the key on to the editor. Stopping closes the run's terminal, which ends everything the
run started: on Windows each build pane command runs in a job object,
so a program with a window of its own, which the console's close event
does not reach, goes too. A shell pane has no job, so closing it
leaves what was launched from it running, as a terminal window does. The compiler is `$MINC/minc` when MINC
names the install, and otherwise the `minc` the shell finds.

A `.c` or `.cpp` buffer takes the same keys for itself, whatever the
build.mc (`build_c_start`). The file alone compiles into the
project's `build/` folder: `build/<name>.exe` (`build/<name>` on macOS
and Linux) when it defines `main`, which a scan of the buffer decides
(`build_c_has_main`), and `build/<name>.obj` (`.o`) when it does not.
A run starts the program after the compile, in the same pane. A
header is refused. The compiler lookup runs in the build pane, not on
the UI thread, as a script. On Windows it is `build/edminc_cc.cmd`,
run with `cmd /d /c`: a command line cannot carry it, because cmd does
not read the C runtime's quote escapes. The script asks vswhere for
the newest Visual Studio with the C++ tools and calls its
vcvars64.bat, which sets up `cl`; without one it takes clang from the
PATH or from `Program Files\LLVM`, then gcc. It sets the console
title to the compile command, which the banner shows. On macOS and
Linux the script runs under `sh -c` and takes `cc`, `clang` or `gcc`
(`c++`, `clang++` or `g++` for C++). A C file compiles with
`/std:c17 /experimental:c11atomics` under `cl`, so `<stdatomic.h>`
works. `cl` runs with `/FC` and
`/diagnostics:column`, so its problems name a full path and a column:
`path(line,col): error C2065: ...`, which the parser reads beside the
`path:line:col:` form.

Either command runs in a terminal pane of its own, the build pane.
`term_open_cmd` passes the words to `plat_term_spawn`. The POSIX layers
run them under the user's login shell with `-c`, so the user's PATH
applies. The Windows layer runs them as a command line. Both use the
same pty a shell pane gets. The first run opens the pane below the
columns, and later runs reuse it. The focus stays with the work. The
output streams into the grid with its colors and goes into the
scrollback, and the program can read what is typed into the pane. The
pane's banner shows the command and the run's state.

The build pane is the bottom pane: a pane like any other, so a terminal
pane's keys, selection and mouse are its own, kept last in the list and
laid out under the columns across the editor's width, the way VS
Code's panel is (`g_bottom`, `pane_cols`). Its top edge drags to size
it (`DIV_BOTTOM`), as a share of the height above the status bar, with
a few lines kept for it and for the columns. `doc_top` and
`chrome_bottom_h` are the loaded pane's bounds (`ed_pane_y0`,
`ed_pane_y1`, `pane_doc_top`), so the columns and the frame build end
above it with no code of their own. The columns are what the splits,
Ctrl+1..3, Ctrl+Alt with an arrow and the diff count; three at most
(`COL_MAX`). A file, a buffer from the switcher or a new shell asked
for while the bottom pane has the focus goes to the column used last
(`bottom_leave`). The session and the restart keep the columns only.

`term_tap` also keeps a raw copy of the bytes. build.mc drains it after
each pump on the UI thread. It strips colors and drops carriage
returns. It carries a color sequence split by a read boundary into the
next read. It indexes each line when the line completes and parses it
for `path:line:col: error|warning:` from the right, so a Windows drive
colon is kept. F8/Shift+F8 walk the problems and open each one's file.
A click on such a row in the pane reads the row from the grid
(`term_row_text`), parses it the same way and opens its location.
Ctrl+J hides the build pane and brings it back under the columns.
While the pane is hidden, the run continues in the background. The
parsed problems stay available to the walk in both cases. A new run
clears the previous output before the child starts. Ctrl+W on the pane
ends the build, and the pane goes with it. Ctrl+Shift+W on the last
column closes the build pane under it, the column staying. A folder
switch also ends the build.

A drag in a terminal pane makes a cell selection (`term_sel_begin`,
`term_sel_drag`, `term_sel_end` in ed.mc). A pane has one selection at
a time. The selection is anchored to absolute lines: term.mc numbers
lines from the first line ever pushed into the scrollback
(`term_abs_top`, `term_abs_text`). The selection therefore stays on its
text while output scrolls under it. The view paints the selected
cells' background in the palette's selection color. The primary
modifier's copy chord joins the lines and puts them on the clipboard.
When the child has asked for the mouse, it gets the drag unless Shift
is held. A drag above the grid scrolls the view into the history, and
below it back toward the screen, as a drag in a document does (see
"Editing operations"). A selection ends with its terminal: the core
closes terminals through `ed_term_close`, which drops a selection on
the one closing, since the next terminal opened reuses the slot.

Output does not move a view that is scrolled back. The view is an
offset into the ring, and the offset moves with the ring as lines are
pushed. The text in view stays in place while the child prints. A key
or a paste sent to the child returns the view to the live screen
(`term_key`, `term_char`, `term_paste`). The wheel moves a terminal
pane by whole lines and keeps its own accumulator for a trackpad's
fractional steps.

A resize of the primary screen reflows it (`term_reflow`). When the
cursor wraps out of a row, the row's last cell carries `TA_WRAP`. The
reflow uses this to join the history and the screen back into the
lines the child wrote, then cuts them again at the new width. It never
splits a wide glyph, and the cursor follows the cell it was on. A
resize also returns a scrolled-back view to the live screen. A
full-screen program repaints on the size change, and the reflow pushes
rows of its previous frame into the history. Without the return, those
wrapped rows would stay in view while the repaint happens below them.
The reflow leaves the screen's empty bottom rows out of the joined
lines and restores them as far as the screen has room, so a prompt
near the top stays there. Lines that do not fit go to the ring, and a
taller screen takes lines back out of it. The alternate screen holds a
program's own layout, which the program repaints on the size change.
The reflow therefore cuts or pads it in place instead, together with
the primary screen behind it.

A terminal is not tied to its pane. The pane holds a handle. Ctrl+W
ends the shell and returns the pane to its document
(`ed_close_shown`). Ctrl+Shift+W closes the pane and keeps the shell
running in the background (`ed_pane_hide`). The switcher
(src/switcher.mc, Ctrl+Tab to walk it, Ctrl+K W to type into it) puts
any open buffer or terminal into the active pane instead of what it
showed (`ed_show_buf`, `ed_show_term`). While the chord is held, each
step shows its row in the pane at once (`ed_show_buf_peek`, which does
not count as a look, so the list's recency order stays as it was), and
letting go keeps it and marks it seen (`ed_buf_seen`); Esc puts back
what the pane showed. A document pane becomes a
terminal pane and keeps its buffer. A terminal pane's terminal moves
to the background, where `term_pump` keeps feeding its screen. Ctrl+K T
does the same in-place replacement with a new shell (`ed_term_open`).
It takes the active pane whatever the pane showed, a terminal
included. Terminals open and are walked the way buffers are, and the
chord never switches to an existing one. No terminal action splits a
pane, so only the user changes the pane layout. The build pane is the
exception: it opens under the columns. Every terminal ends on quit and
on a folder switch.

`build_settle` is the headless wait. It blocks on the terminal's read
semaphore (`term_wait`) until the child exits, for a `--shot` taken
after a build. It never runs on the UI thread. The harnesses run the
terminal synchronously. Their spawn stubs return a canned compiler
output for a command, in CR LF form, as a pty's line discipline
delivers it.

### Grapheme clusters and color emoji

The mono grid edits and displays text in grapheme clusters. A
multi-codepoint emoji is one unit two cells wide: the caret moves over
it in one step, backspace deletes all of it, and column math counts it
as two cells (`grapheme_next_w`/`grapheme_prev`, following the UTS #51
rules). `cp_width` returns 2 for Emoji_Presentation codepoints. The
render loop calls `plat_shape_cluster` to shape a multi-codepoint
cluster to one glyph. When the platform returns 0, it draws the base
codepoint. Color emoji work on all four platforms. Each backend
rasterizes a `channels == 4` cell into the shared color-glyph path. On
Linux and the web, the CBLC/CBDT reader (lib/cbdt.mc) walks the CBLC
index to a glyph's CBDT PNG, decodes it with the stdlib png module, and
reads the cmap. `cbdt_shape` applies the font's GSUB type-4 ligatures,
so skin tones, ZWJ sequences, keycaps and flags each become one glyph,
as on Windows and macOS.

### Editing operations

A typed `)`, `]` or `}` marks the bracket it closes in the theme's
accent, `list.highlightForeground` (`brace_after_type`), for a second.
For the first 150 ms its cell is filled with the text color, an
inverted background under the accent glyph. The scan runs back from the closer over
the lexer's classes, so brackets in strings and comments do not count,
and a bracket of the wrong kind on the way means no match. It follows
the primary caret, in every file the lexer colors except markdown, and
looks back at most 5000 lines. An edit at or before the closer ends
the mark. Otherwise the timer ends the flash, then the mark, and stops.

Word movement and deletion (Ctrl+Left/Right, Ctrl+Backspace/Delete),
line move and copy (Alt+Up/Down, Shift+Alt+Up/Down), line delete
(Ctrl+Shift+K), comment toggle (Ctrl+/ and Ctrl+7). Tab over a
selection whose ends are on different lines indents every line it
touches by four spaces, empty lines excepted; Shift+Tab takes a tab or
up to four spaces off the start of each, or of the caret's line. Both
are one edit and one undo step, and the selection keeps its lines.
Windows sends a Tab character after Shift+Tab, which is dropped. Multiple cursors:
the primary cursor is cur_line/cur_col. The extra cursors are stored
beside it, and the editor installs each one into that slot in turn.
One key press is one undo step across the group. Selections, the
clipboard and undo/redo are portable.

A left drag that selects scrolls the view while the pointer is near or
past the top or bottom of the text (`drag_scroll_*` in ed.mc). The
zone reaches half a line into the text, so the drag also scrolls in a
maximized window with no room below the text. The speed is 8 lines a
second at the zone's inner edge and rises by 16 lines a second per
line past it, up to 240. A document moves by pixels and a terminal by
whole lines. Each frame advances the view by the time since the last
step and asks for the next frame, so the motion is paced to the
display. A repeating timer keeps it going with the pointer at rest. The
timer runs only while the pointer is in the zone, and it stops on the
release or when the window loses focus. The selection's head follows
to the edge row that shows whole, so following the caret does not
snap the view to a line. A move during the drag does not scroll by
itself: the head stays on the rows in view, and only the autoscroll
moves the view, at a steady rate. Scrolling is in pixels: the
scroll position is a pixel offset, and the wheel and trackpad move it
by pixels. Scrolling that follows the caret, and paging, snap to whole
lines. Sideways scrolling (`app_scroll`'s dx) moves a document pane by
whole columns, the fraction carried to the next event, up to the
widest line in view; the two sides of a diff move together.

Smooth scrolling (on by default, Ctrl+K M) applies to a held caret key
at the edge of the view, which scrolls a line per key repeat, and to a
mouse wheel's notches, which the platforms send to `app_scroll_notch`
(Windows: a multiple of `WHEEL_DELTA`; macOS: no precise deltas;
Linux: the scroll buttons; the browser: a delta in lines or pages).
The logical scroll moves at once, so the caret, hit-testing and the
next input see the new position immediately. Only the frame build
draws the view trailing it (`ed_glide_begin`), and the trail shrinks
at a steady rate, so the text moves every refresh instead of a step at
a time. For a held key the rate is a line per repeat period, a running
mean of the gaps between repeats. The view keeps half a line of trail
in reserve when the next repeat is due, so a repeat up to half a
period late finds it still moving. A repeat that comes early adds to
the trail, and the rate rises to restore the reserve. The trail is
between half a line and a line and a half during a hold, two lines at
most, and runs out at the same rate when the key is released. A notch
keeps no reserve: its trail runs out over the time since the previous
notch, clamped to 8-50 ms, or over 30 ms for a lone notch. While the
view moves, each frame asks for the next one, and the platform paces
them to the display. The glide reads the clock when the frame is
built, so the motion per frame varies with where in the refresh the
build lands: at 240 Hz the frame intervals spread from 3 to 5 ms, at
60 Hz by a tenth of the refresh. A lone caret step, a caret jump of
more than a line and a notch of more than 20 lines snap, and a
touchpad's deltas never glide. In a diff the file's pane owns the
shared scroll and glides; the base side draws the same trail, from
the same clock reading (`ed_glide_frame`). An input that
arrives while a glide frame is queued waits for that frame to be
taken, up to one refresh.

### Word wrap

Alt+Z, or `"editor.wordWrap": "on"`, wraps a line wider than its pane
into the rows under it (src/wrap.mc). A row breaks after the last
space or tab that fits, or inside a word that is wider than a row. The
width is the pane's text columns less one, for the caret after a
row's last character. A continuation row is indented as far as its
line, unless that indent is more than half the width. A space at a
break stays at the end of its row and may run past the edge. The
diff's two panes do not wrap, since their rows pair line against line.
An image does not wrap either.

The view already counted rows rather than lines for the diff
(`ed_row_of_line`, `ed_line_of_row`, `ed_row_count`), and wrap is a
third source of rows behind the same calls. With wrap on, the scroll
position, `top_line` and the scrollbar count wrapped rows. Every
place that puts a position on screen or reads one from a point goes
through `ed_pos_xy` and `ed_pos_at`, which know a row's first byte and
its indent. The renderer draws each row's slice of its line: the line
number, the diagnostic mark and a deletion's triangle on the first row
only, the change bar on every row, and the current line's band over
all of its rows.

Each buffer keeps a row count per line and the running sum of rows
above each line (`WrapCache`), for two widths, so one buffer in two
panes of different widths does not count again on every frame. A
third width replaces the older of the two. Counting a line scans its
graphemes, but a line no longer than the width with no tab and no
byte above 0x7F is one row without a scan. An edit reports the line
it started on and the lines it removed and added (`wrap_note_edit`,
the same report the git gutter and the token list get). The counts
after the edit move with their lines, and only the edited lines are
counted again. The sums are made again from the first edited line, on
the next question. A text loaded or replaced as a whole is counted
again from the start. The rows of one line, their first bytes and
columns, are kept for the line drawn last, which is where the renderer
and the caret ask for them.

A pane's scroll is kept with the width it counts rows at (0 for
lines). A pane that is wider or narrower now, through a resize, the
sidebar, a split or a switch of wrap, converts the scroll through the
line at its top and the row of that line (`wrap_refit`), so the line
stays at the top. The conversion runs when the pane is loaded, before
a frame draws it, and before the rows are counted.

With wrap on, Up and Down move by row and keep a goal column counted
from the row's left edge. PgUp and PgDn move by a page of rows. Home
goes to the start of the caret's row, and from there to the line's
start; End goes to the row's end, then the line's. A column at a break
is drawn at the start of the next row, so the end of a row is the
position before its last character. A click past a row's end lands
there too. Sideways scrolling is off while the view wraps.

## Limitations

What the editor does not do yet, by area. The sections named in
parentheses have the detail.

Platform:

- Linux and the browser have no file watcher ("Files changed on
  disk"). A save still checks the file on disk.
- Linux and the browser have one window ("Multiple windows").
- A glyph missing from the primary face has no fallback font on
  Windows other than the emoji and symbol faces, and none on Linux.
  macOS uses the system cascade.
- IME input is committed text only, with no inline composition
  underline. The browser receives it through `compositionend`.
- A save in the browser writes only to the page's file map.
- The vendored rasterizer on Linux and in the browser does no
  hinting, so small sizes at 96 DPI render softer than hinted output.
- Text contrast and gamma are tuned against dark backgrounds
  ("Settings and color themes").
- The macOS window follows the system appearance, so a light-mode
  system draws a light title bar over a dark theme.
- The macOS driver has no `--dpi` flag, so its `--shot` dumps differ
  from the Linux driver's at the same settings.
- macOS and Linux build a frame and then wait for a free buffer
  ("Core constraints the platform layer holds").
- The POSIX process and pty code exists twice, in lib/mac.mc and
  lib/x11.mc. The copies differ in the library name and a few
  constants. The Linux pty arm is type-checked against the macOS arm,
  and scripts/macpty_probe.mc runs only on macOS.

Terminal:

- On Windows the restart does not carry the shells across ("The
  restart").
- Ctrl+K P changes the default text and background only. A cell
  stores the color resolved when its bytes arrived.
- A resize during a full-screen program cuts the primary screen
  behind it instead of reflowing it.
- The selection has no double or triple click, no copy on select and
  no middle-button paste. With Shift held over a child that holds the
  mouse, only the press is kept from the child.
- The switcher cannot close a buffer or end a terminal, so a
  terminal that exited in the background stays in the list.
- The buffer limits (`BUF_SOFT_MAX`, `PREVIEW_MAX`) are constants and
  an environment variable, not settings.

## Performance

Measured with scripts/perf.ps1 on Windows (60Hz 4K) and with `--time`
plus a synthetic-scroll driver on macOS (Retina 2x, 60Hz, M-series).
Phase 1 is closed on both.

- Idle: zero timer wakeups after the blink timeout. CPU time is flat
  over 10s with a 100MB file open.
- Input: keypress to present within one refresh. Windows 0.6 ms median,
  1.5 ms p95; macOS 1.2 ms median, 1.3 ms p95, over real keystrokes.
- Scrolling: sustained full refresh rate at 4K / Retina through a
  1.5M+ line file, with no dropped frames.
- Input to display on Windows, measured with scripts/latency.ps1 at
  59 Hz 4K, the window composed by DWM. Keys: about 29 ms median, the
  same with and without the waitable object; most of it is the
  compositor. A continuous scroll: 31 ms median, 48 ms p95, from the
  oldest input in a frame. Without the waitable object it was 45 ms
  and 63 ms, one refresh more.
- Open: a typical source file opens in ~0.2–0.6 ms, too fast to
  perceive. A 100MB file takes ~114–280 ms. Most of that is the
  stdlib's chunked file_read; the editor's own line-index sweep is
  ~40 ms.
- Memory: file size + gap + line index, nothing per line.

Verified headless: scripts/web_probe.py drives the browser build
through Playwright (render, type, picker, idle). The harness also runs
as a browser-target module under node. Every ed_test check passes
there, and the four fuzz seeds' frame hashes are byte-identical to the
native runs.

## The fuzzer's frame hash

The fuzzer hashes every frame of a run into one number. The number
depends on three things: the seed, the editor's code, and the files
the fuzzer reads. It reads the repository it runs in. It opens
src/ed.mc, lists the tree, and takes the git baselines from the files
on disk. The tree hides gitignored entries in its runs, so the
contents of build/ do not reach the frames.

For one commit the hash is the same on every run, in a replay of the
run's script, and on every platform. `.gitattributes` keeps the files'
bytes the same in every checkout, including their line endings. A
change to the code or to the files changes the hash, so the hashes of
two commits cannot be compared.

A pinned fixture would separate the files from the code. It is a small
tree that is checked in once and not edited afterwards: a few source
files, a Markdown file, nested folders, long lines, tabs, emoji and
CRLF line endings. The fuzzer would change into that tree at startup
instead of reading the repository. The hash would then change only
when the editor's behavior or drawing changes.

That turns the hash into a check for refactoring:

1. Before the change, record the hashes for a set of seeds with
   `build/fuzz --hashes`.
2. Make the change.
3. Run the same seeds again and compare the lines.

If every hash matches, the change did not alter what the editor does
or draws in those runs. If one differs, `--trace` on that seed shows
the first step where the frames differ, and `--show <step>` prints the
state and the frame at that step in both builds. A change that is
meant to alter behavior changes the hashes, and the new values replace
the old ones.

A matching hash covers only what the seeds reach. `build/fuzz
--coverage` shows which actions and states that is. The fixture does
not exist yet, and nothing enforces the check.

## Portability

### Core constraints the platform layer holds

- The core is callback-only. No core code pumps or blocks on events.
- Text arrives only as committed codepoints. Keys are for chords and
  navigation. Platforms ask the core for the caret's pixel position to
  place the composition UI. Full IME (composition underlines,
  candidate windows) needs rendering in the core, which is not yet
  designed.
- DPI can change during a session (app_scale rebuilds the atlas).
  Coordinates are always pixels, never points.
- The core takes scroll amounts as float pixels and does the
  accumulation. Platforms convert their wheel and trackpad units.
- The core uses UTF-8 and `\n`. Platforms convert clipboard formats and
  line endings, and paths and titles at each API boundary.
- Present pacing (at most one queued frame) is an invariant tested per
  backend. It is not part of the API. On Windows the frame is built
  when the swapchain can take it; macOS and Linux build it and then
  block for a free buffer. The browser renders in
  `requestAnimationFrame`, which has the same effect as Windows.

### The reusable shell

Everything below the editor is a reusable event-driven application
shell: the contract (plat), the drivers, the gpu backends, the quad
batch, and the glyph cache with its raster backends. It is not a
separate library yet. Extraction waits for a second consumer, because a
library with one consumer fixes the wrong API. The contract stays
frozen while behavior settles. Until then, two rules hold. src/ never
calls OS APIs; ed_test enforces this by compiling the core against
stubs. lib/ contains no editor symbols. Two places cross the boundary: the
drivers' smoke print reads `tb.nlines`, and the IME anchor calls
`ed_caret_px` directly.

## Source map

Portable editor in `src/`, platform and substrate modules in `lib/`.

- src/edminc.mc — program manifest + `main()`; `when os()` selects the
  platform module set.
- src/ed.mc — portable core: editor state, editing, movement, multiple
  cursors, the `app_*` entries, the WinCtx multi-window code.
- src/view.mc — portable frame build (text, gutter, caret, scrollbar,
  status bar, pane banner, caption) into the shared quad batch.
- src/text_buf.mc — gap buffer + line-start index, load/save with CRLF
  handling.
- src/wrap.mc — word wrap: where a line's rows break, and the rows per
  line kept per buffer and width, following edits.
- src/lexer.mc — per-line incremental highlighter: minc and markdown,
  plus a basic pass for JS, Python, shell, HTML, JSON and YAML.
- src/gitignore.mc — the gitignore rules and the settings that decide
  what the tree, the picker, search and the watcher leave out.
- src/pick.mc — Ctrl+P fuzzy file picker; dir_sort sorts listings so a
  fuzz seed means the same thing on every platform.
- src/find.mc — the Ctrl+F / Ctrl+H find and replace widget.
- src/tree.mc — file tree sidebar with git decorations; names typed
  in the tree (new file, new folder, rename) and its context menu's
  commands.
- src/menu.mc — the context menu overlay.
- src/search.mc — project search view; also holds references results.
- src/complete.mc — completion popup.
- src/symbols.mc — Ctrl+T workspace symbol search.
- src/palette.mc — Ctrl+Shift+P / F1 command palette over the bound chords.
- src/git.mc — the change gutter and the tree's status job.
- src/watch.mc — the file watcher's thread and queue, the filter, and
  the refresh after a burst of changes.
- src/build.mc — build (Ctrl+Shift+B) and run (F5, Shift+F5) in the build pane,
  the problems walk.
- src/term.mc — the terminal: the VT emulator and the screen grid, over
  the pty byte transport (a reader and a writer thread per handle).
- src/switcher.mc — Ctrl+Tab (walk) and Ctrl+K W (type): the open
  buffers and terminals in one list, a terminal as "terminal N" with
  its program's title (`term_label`); a terminal moved aside keeps
  running.
- src/sem.mc — semantic tokens laid over the lexer.
- src/lsp.mc — the language server client: the children over stdio
  (minc-lsp and clangd), the writer threads, the requests and their
  replies.
- src/lsp_shadow.mc — harness-only shadow document for sync checking.
- src/harness_plat.mc — the platform stubs both harnesses share.
- src/ed_test.mc — headless editor-core test entry (run by `minc test`).
- src/ed_fuzz.mc — headless fuzzer with a mock language server.
- src/evscript.mc, src/play.mc — the fuzzer's event kinds and the live
  player (`--play`).
- lib/plat.mc — the platform contract: `app_*`/`plat_*`/`gpu_*` spec,
  key codes, FontMetrics/GlyphRaster, shared UTF-8 and grapheme helpers.
- lib/headless.mc — the headless flags (`--shot`, `--key`, `--char`,
  `--dump-term`...), the injection and dump loops, and the forwarding
  of arguments across a restart, shared by the three native drivers.
- lib/draw.mc — portable quad batch.
- lib/theme.mc — the color slots, the built-in themes' tables, and the
  DPI-derived UI metrics.
- src/settings.mc — ~/.edminc/settings.json: reading it, the template,
  and the theme picker's edit of the file.
- src/recent.mc — the recent folders: the list, its file, and the
  folder a launch that names none opens.
- src/hist.mc — the history graph: the log's pages and lanes, a
  commit's files, a file's diff in a commit, and the panel's rows,
  keys and drawing; tree.mc places it in the changes view.
- src/calls.mc — the call graph's state, trail, layout and input;
  view.mc draws it.
- src/image.mc — the image viewer: the decode worker, the image
  table, zoom and pan, and the keys; view.mc draws it.
- src/explode.mc — the explode view's state, input and grid layout,
  over buffers and terminals;
  view.mc draws it.
- lib/ui.mc — element primitives (panels, input box, list row) and
  UiField, the editable query line.
- lib/font.mc — portable glyph cache + atlas packing; mono and UI
  faces; the per-dpi contexts; the color-glyph cell.
- lib/win.mc, lib/gpu_d3d11.mc, lib/font_dwrite.mc, lib/plat_win.mc —
  the Windows layer.
- lib/mac.mc, lib/gpu_metal.mc, lib/font_coretext.mc, lib/plat_mac.mc —
  the macOS layer.
- lib/x11.mc, lib/gpu_gl.mc, lib/font_ttf.mc, lib/plat_x11.mc — the
  Linux layer (font_ttf also serves the web).
- lib/web.mc, lib/gpu_webgl.mc, lib/plat_web.mc — the browser layer.
- lib/stb_truetype.mc — vendored TrueType/CFF rasterizer (generated).
- lib/cbdt.mc — color bitmap glyphs from a CBLC/CBDT font + the GSUB
  ligature shaper.
- lib/icon_mc.mc, lib/icon_edmc.mc — the tree's `.mc` file icon and the
  app logo.
- assets/ — DejaVu text/UI faces, codicon and seti icon fonts (see
  THIRD_PARTY.md); the color emoji font is not committed.
- web/index.html, web/edminc_host.js, web/edminc_lsp_worker.js — the
  browser page, its host script, and the LSP worker.

`minc build` compiles the program from the manifest. `import` resolves
module names against the project's lib/ first, then the compiler's
installed lib.
