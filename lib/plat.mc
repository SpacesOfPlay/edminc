// plat.mc - platform contract. Portable code on one side, per-OS
// shells on the other.
//
// Modules resolve by name: project lib/ first, then the compiler's
// lib. Imported symbols are program-global. src/edminc.mc selects the
// platform modules with `when os()`.
//
// A port adds four modules under lib/ and a `when os(...)` block in
// src/edminc.mc:
//   1. declarations + services (win.mc): native API surface and
//      the plat_* functions below
//   2. gpu backend (gpu_d3d11.mc): the gpu_* functions below
//   3. font backend (font_gdi.mc): plat_font_init, plat_glyph_raster
//   4. driver (plat_win.mc): window, event loop, event translation,
//      plat_main()
// The browser port (web.mc, gpu_webgl.mc, font_ttf.mc shared with
// Linux, plat_web.mc) is the same four; its window and loop are the
// page's, web/edminc_host.js, which calls plat_web.mc's exports.
//
// The core provides:
//   app_init(str path, i32 dpi)   load file, set title; call last
//   app_char(u32 cp)              committed text as codepoints; the
//                                 shell pairs UTF-16 surrogates.
//                                 Enter/Tab/Backspace are cp 13/9/8.
//   app_key(i32 key, i32 mods)    K_* or ASCII 'A'..'Z', '0'..'9', '`', '-'
//   app_mouse(i32 x, i32 y, i32 btn, bool down, i32 mods)
//                                 btn: 0 left, 1 right, 2 middle
//   app_mouse_move(i32 x, i32 y)  pointer moved with the left
//                                 button down (drag selection)
//   app_scroll(f32 dx, f32 dy, i32 x, i32 y)   pixels; dx > 0 scrolls right
//   app_scroll_notch(f32 dx, f32 dy, i32 x, i32 y)
//                                 the same for a wheel's notch, which
//                                 glides under smooth scrolling; a
//                                 touchpad's fine deltas go to app_scroll
//                                 pixels; +y scrolls down; x,y =
//                                 pointer position for routing
//   app_resize(i32 w, i32 h)      client pixels
//   app_scale(i32 dpi)            DPI change; rebuilds the atlas
//   app_focus(bool on)
//   app_timer(i32 id)
//   app_close(): bool             false keeps the window open
//   app_use_window(i32 win)       select the window a following app_*
//                     targets; the core swaps that window's panes and
//                     geometry into the globals. One window needs no
//                     call. See ed_window_new/close in src/ed.mc.
//   app_wake()                    a worker posted progress
//   app_folder_picked(u8* path, i32 len)   the folder the platform's
//                     dialog returned, UTF-8; len 0 when cancelled
//   app_save_picked(u8* path, i32 len)   the path the platform's save
//                     dialog returned, absolute, UTF-8; len 0 when
//                     cancelled
//   app_hover(x, y, mods)             pointer motion with no button
//                     down, and modifier-only changes at the last
//                     position, pressed or released: the cmd+hover
//                     definition link, and the buffer cycle's chord
//                     letting go (switcher_mods). Every driver has to
//                     report the release, not only the press.
//   app_cursor_kind(i32 x, i32 y): i32   CURSOR_* for the pointer
//   app_render()                  builds and presents one frame
//   app_settle()                  waits for background work (the git
//                                 fetch) to land; a headless one-shot
//                                 render calls it before the dump
//
// Services every shell implements. UTF-8 in; convert at the native
// boundary. Wide strings stay inside the platform modules.
//   plat_damage()                 request one redraw of every window
//   plat_damage_window(i32 win)   request one redraw of that window only
//   plat_set_timer(i32 id, i32 ms)   repeating; fires app_timer(id)
//   plat_kill_timer(i32 id)
//   plat_time_us(): i64           monotonic microseconds
//   plat_set_title(str s)
//   plat_clipboard_set(u8* s, i64 n)   UTF-8 text, '\n' endings
//   plat_clipboard_get(i64* out_len): u8*
//       alloc'd UTF-8 with '\n' endings; caller frees. null = empty.
//   plat_quit()
//   plat_wake()                   thread-safe; schedules app_wake()
//                                 on the main thread (workers use it)
//   plat_child_spawn(i32 k, str* argv, i32 argc): bool
//                     a long-running child with piped stdio in slot k,
//                     0 <= k < PLAT_CHILDREN (the language servers,
//                     one per slot); plat_child_write(k, ..) feeds its
//                     stdin, plat_child_read(k, ..) blocks on its
//                     stdout (<= 0 = exited), plat_child_kill(k)
//                     terminates it. Its stderr stays out of the stdout
//                     pipe: a server logs there, and stdout carries
//                     the protocol frames.
//   plat_run_capture(str* argv, i32 argc, i64* out_len,
//                    i32* out_code): u8*
//                     runs a program to completion with no stdin and
//                     returns its stdout, alloc'd; caller frees. null
//                     when it could not be started. This one blocks,
//                     so it is for short bounded output (git plumbing),
//                     not for a build: that wants the streaming child
//                     above. Separate from plat_child_* because the
//                     language servers hold those for the session.
//   plat_cwd(u8* buf, i32 cap): i32   working directory, UTF-8;
//                                 returns the length, 0 when unknown
//   plat_chdir(str dir): bool     make `dir` the working directory,
//                     which is the project: the tree, the picker,
//                     search, git and the server's root all start
//                     there. False when it is not a directory.
//   plat_exe_dir(u8* buf, i32 cap): i32   the directory holding the
//                     running executable, UTF-8, no trailing slash;
//                     returns the length, 0 when unknown (the browser).
//                     Used to find assets/ next to a released binary.
//   plat_exe_path(u8* buf, i32 cap): i32   the running executable's own
//                     path, UTF-8; the length, 0 when unknown.
//   plat_exec_self(str exe, str* argv, i32 argc): bool
//                     start `exe` with argv in this process's place
//                     (the restart into a new build) and end this one;
//                     the driver adds the flags of its own a headless
//                     run wants forwarded. Returns only when it could
//                     not start it.
//   plat_term_export(i32 h, i64* fd, i32* pid): bool
//                     the handle's pty end and child, made to survive
//                     an exec, for the handover to the next process;
//                     false where a pty cannot cross one.
//   plat_term_adopt(i64 fd, i32 pid): i32   a handle over a pty end and
//                     child the previous process handed over; -1 where
//                     unsupported.
//   plat_window_rect(win, x*,y*,w*,h*,maxi*): bool   the native rect of
//                     window win, for the session; false if not live.
//   plat_window_open_at(x,y,w,h,maxi): i32   open a window at a rect
//                     (session restore); -1 where unsupported.
//   plat_window_set_rect(win, x,y,w,h,maxi)  move/size a window (restore)
//   plat_window_open(): i32       open another native window over the
//                     shared buffer set (ed_window_new); its index, or
//                     -1 where multi-window is not supported (Linux
//                     and the browser, for now).
//   plat_recent_folders(str* dirs, i32 n)   the recent folders,
//                     newest first, changed: the shell's list for the
//                     app follows (the Windows taskbar's jump list).
//                     Returns at once; a folder the user removes there
//                     comes back through app_recent_forget.
//   plat_pick_folder(): bool      ask the OS for a folder in its own
//                     dialog, opened after the current event has
//                     returned; the choice arrives through
//                     app_folder_picked. False when the platform has
//                     no dialog, and the caller asks its own way
//   plat_file_rename(str src, str dst): bool   move a file or folder
//                     to a new path. The caller checks that `dst` does not
//                     exist: POSIX replaces it, Windows refuses. False
//                     where it failed, or the platform cannot (browser)
//   plat_trash(str path): bool    move the file or folder at the
//                     absolute `path` to the OS trash (the recycle bin,
//                     the Finder's Trash, the freedesktop trash folder).
//                     False where it failed or the platform has none
//   plat_reveal(str path): bool   show the absolute `path` in the
//                     system file manager, selected where it can be
//                     (Explorer, Finder); Linux opens its folder with
//                     xdg-open. False where the platform has none
//   plat_open_url(str url): bool   open the http(s) `url` in the default
//                     browser (a new tab in the page). False where it
//                     failed
//   plat_pick_save(str dir, str name): bool   ask the OS for a path to
//                     save to, in its own dialog, starting in the
//                     absolute folder `dir` with `name` filled in. It
//                     opens the same way and asks before it replaces a
//                     file; the choice arrives through app_save_picked.
//                     False when the platform has no dialog
//   plat_dir_list(str dir, bool want_dirs): DirList
//                     entry names directly inside `dir`, files or
//                     directories; the stdlib's DirList, freed with
//                     dir_list_free. A service because the browser
//                     has no file system of its own: its page keeps
//                     one and answers this.
//   plat_term_spawn(i32 cols, i32 rows, str* argv, i32 argc,
//                   bool under): i32
//                     start a child behind a pseudo-terminal of that
//                     cell size, in the working directory: the user's
//                     shell with argc 0, else argv as a command, run
//                     through the login shell on POSIX (so the user's
//                     PATH applies) and as a command line on Windows.
//                     `under` says the screen already holds text the
//                     child is to come up beneath, which only Windows
//                     acts on: its console host clears the screen when
//                     it starts, unless it is told to take the cursor
//                     where it finds it. A pty has no such host.
//                     A handle >= 0, or -1 where the platform has no pty
//                     (the browser) or the OS is too old to make one.
//                     A pty is not plat_child_*: the child gets a
//                     controlling terminal, a window size and the
//                     signals that come with them, which is what every
//                     shell checks before it behaves as one.
//   plat_term_read(i32 h, u8* buf, i64 cap): i64
//                     block until the child writes; bytes read, <= 0
//                     once it has exited. That terminal's reader
//                     thread calls this and nothing else does.
//   plat_term_write(i32 h, u8* p, i64 n): i64
//                     bytes to the child's input; may block. That
//                     terminal's writer thread only.
//   plat_term_resize(i32 h, i32 cols, i32 rows)
//                     the pane's cell grid changed; the child gets
//                     whatever resize signal the platform sends
//   plat_term_code(i32 h): i32   the child's exit code, or -1 while
//                     it is still running; the pane's banner says so
//   plat_term_kill(i32 h)   end the child and the pty, so the read
//                     the reader thread is parked in comes back
//   plat_term_free(i32 h)   release the handle, once that thread has
//                     seen its end of file and gone; the two are
//                     separate because the reader is still holding
//                     what a kill would otherwise close under it
//   plat_term_palette(u32* out, i32 n): u32
//                     the colors the user gave the platform's own
//                     terminal, in term.mc's slot order (text,
//                     background, bold, cursor, selection, the ANSI
//                     sixteen); fills the slots it knows and returns
//                     a bit per filled slot, 0 where there is nothing
//                     to take. macOS reads Terminal.app's default
//                     profile when it is not the stock one, Windows
//                     the default profile of Windows Terminal's
//                     settings; Linux and the browser answer 0 and the
//                     pane keeps its own.
//   plat_watch_open(str dir): i32
//                     watch `dir` and every folder under it for changed,
//                     created, deleted and renamed entries; a handle, or
//                     -1 where the platform has no watcher (Linux and
//                     the browser, for now)
//   plat_watch_read(i32 h, u8* buf, i64 cap): i64
//                     wait until entries change, then write one record
//                     per change: a kind byte ('c' for a file's content,
//                     'm' for an entry created, deleted or renamed), the
//                     path relative to `dir` with '/' separators, and
//                     '\n'. Returns the bytes written; 0 when changes were
//                     lost (the platform's buffer overflowed, or the
//                     records do not fit `cap`); below 0 once the watch
//                     is closed. The watcher's thread calls this and
//                     nothing else does.
//   plat_watch_close(i32 h)   end the watch, so the wait in
//                     plat_watch_read returns
//   plat_watch_free(i32 h)    release the handle, after the thread that
//                     reads it has gone
//
// Gpu backend. gpu_init is called by the matching driver, so its
// window-handle argument is per-platform.
//   gpu_init(handle, i32 w, i32 h): bool
//   gpu_resize(i32 w, i32 h)
//   gpu_upload_atlas(u8* pixels)     RGBA8, ATLAS_W x ATLAS_H;
//       rgb = per-channel coverage (subpixel), a = 255
//   gpu_image_create(u8* rgba, i32 w, i32 h): i32
//       an image as a texture of its own, straight RGBA8, with its mip
//       levels; the handle draw_image takes, or -1.
//   gpu_image_free(i32 h)
//   gpu_frame_end(f32 r, f32 g, f32 b)
//       clear, draw the batch, present; at most one queued frame. The
//       batch is drawn run by run (draw.mc), each with its texture: the
//       glyph atlas, or an image drawn as its texels are, smoothed
//       through its mip levels or magnified as blocks.
//       Subpixel backends blend per channel (dual-source); grayscale
//       platforms store r=g=b, so plain alpha blending on the red
//       channel is equivalent there.
//
// Font backend.
//   plat_font_init(i32 dpi, FontMetrics* m): bool   (re)create font
//   plat_glyph_raster(u32 cp, GlyphRaster* out): bool
//       false: advance-only glyph. pixels may point into backend
//       scratch, valid until the next call.
//   plat_shape_cluster(u8* s, i32 n): u32
//       shape an emoji grapheme cluster (n utf-8 bytes) to a single
//       glyph id of the emoji face, or 0 when the platform cannot shape
//       it to one glyph. The id is drawn via FONT_GLYPHID; a 0 makes the
//       caller fall back to the cluster's base codepoint. Windows shapes
//       through DirectWrite (flags excepted), macOS through CTLine, and
//       Linux and the browser through the emoji font's own GSUB ligatures
//       (cbdt_shape); all flags included but the DirectWrite one.

const i32 PLAT_CHILDREN = 2;   // plat_child_* slots

struct FontMetrics {
    i32 cell_w;
    i32 line_h;
    i32 ascent;
}

struct GlyphRaster {
    u8* pixels;   // coverage 0..255, `pitch` bytes per row
    i32 w;
    i32 h;
    i32 pitch;
    i32 channels; // 1 = grayscale, 3 = rgb subpixel coverage
    i32 xoff;     // pen x to left edge of bitmap
    i32 yoff;     // cell top to top edge of bitmap, ascent applied
    i32 adv;
    f32 advf;     // unrounded advance (== adv on the mono grid)
}

// Key codes for app_key. Printable keys pass as ASCII.
const i32 K_LEFT = 256;
const i32 K_RIGHT = 257;
const i32 K_UP = 258;
const i32 K_DOWN = 259;
const i32 K_PGUP = 260;
const i32 K_PGDN = 261;
const i32 K_HOME = 262;
const i32 K_END = 263;
const i32 K_DELETE = 264;
const i32 K_ESCAPE = 265;
const i32 K_TAB = 266;   // as a chord key only; text Tab is app_char(9)
const i32 K_F12 = 267;   // goto definition
const i32 K_F8 = 268;    // next build problem (shift: previous)
const i32 K_F5 = 269;    // run the project; with Shift, the active .mc file
const i32 K_F7 = 270;    // next change in a diff (shift: previous)
// the rest of the function keys: unbound in the editor, sent on to
// the program in a terminal pane
const i32 K_F1 = 271;
const i32 K_F2 = 272;
const i32 K_F3 = 273;
const i32 K_F4 = 274;
const i32 K_F6 = 275;
const i32 K_F9 = 276;
const i32 K_F10 = 277;
const i32 K_F11 = 278;
const i32 K_MENU = 279;   // the context-menu key (Windows and Linux keyboards)

// MOD_CTRL is the primary shortcut modifier: Ctrl on Windows/Linux,
// Cmd on macOS. MOD_SUPER is the leftover key (Win; Ctrl on macOS).
const i32 MOD_CTRL = 1;
const i32 MOD_SHIFT = 2;
const i32 MOD_ALT = 4;
const i32 MOD_SUPER = 8;
// The word-movement modifier follows the platform's own convention:
// Option+arrows on macOS, Ctrl+arrows elsewhere.
when os(macos) {
    const i32 MOD_WORD = MOD_ALT;
}
when !os(macos) {
    const i32 MOD_WORD = MOD_CTRL;
}

const i32 DPI_BASE = 96;
const i32 PATH_MAX = 2048;

// Pseudo-terminals live at most one per pane, so this is PANE_MAX.
const i32 TERM_MAX = 8;

// The proportional UI face, for chrome text (tree, lists), matching
// the reference workbench font (Segoe UI on Windows, the system
// font on macOS). OR FONT_UI into a codepoint and the backend
// rasterizes it with the UI face; the glyph's adv then carries the
// real advance instead of the mono cell. Metrics are set by
// plat_font_init alongside the mono metrics.
const u32 FONT_UI = 0x40000000;
// Icon glyphs for the window buttons: OR FONT_CAPTION into an icon
// codepoint and the backend rasterizes it at a CAPTION_ICON_PX em
// (css px, scaled by DPI) instead of the text em. The reference draws
// its caption at these sizes: a 30 px bar, 46 px per button, the
// icon font at 16 px, whose close glyph inks about 10 px like the
// native caption.
const u32 FONT_CAPTION = 0x20000000;
const i32 CAPTION_H_PX = 30;
const i32 CAPTION_BTN_PX = 46;
const i32 CAPTION_ICON_PX = 16;
// UI glyphs rasterize at 4 horizontal subpixel phases: OR the phase
// (0..3, frac(x) quantized to quarters) into the codepoint and the
// backend draws the outline shifted right by phase/4 px. The mono
// grid stays single-phase.
const i32 FONT_PHASE_SHIFT = 24;
const u32 FONT_PHASE_MASK = 0x03000000;
// Shapes the portable code rasterizes itself, through the same cache
// and atlas as glyphs: OR FONT_SHAPE into a shape id. SHAPE_SQUIGGLE
// is the reference's diagnostic underline tile, 6 by 3 css px scaled
// by DPI, anti-aliased, repeated along a range. SHAPE_WEDGE is its
// mark for lines deleted at a boundary: a triangle pointing right,
// 4 by 8 css px scaled by DPI.
const u32 FONT_SHAPE = 0x10000000;
const u32 SHAPE_SQUIGGLE = 1;
const u32 SHAPE_WEDGE = 2;
const u32 SHAPE_HATCH = 3;   // the diff's filler rule, a seamless tile
i32 font_ui_h = 0;
i32 font_ui_ascent = 0;
i32 font_ui_row = 0;   // reference list row height (22 css px scaled)
// the reference's list row is 22 css px at its 13 px workbench font
const i32 UI_ROW_BASE = 22;
const i32 UI_REF_PX = 13;
// the private-use range the icon fonts live in: seti file icons below
// ICON_CP_CODICON, codicons at and above it
const u32 ICON_CP_MIN = 0xE000;
const u32 ICON_CP_MAX = 0xF8FF;
const u32 ICON_CP_CODICON = 0xEA00;

// what the pointer should look like, from app_cursor_kind(x, y)
const i32 CURSOR_ARROW = 0;
const i32 CURSOR_IBEAM = 1;
const i32 CURSOR_RESIZE_H = 2;   // horizontal resize (pane dividers)
const i32 CURSOR_HAND = 3;       // the cmd+hover definition link
const i32 CURSOR_RESIZE_V = 4;   // vertical resize (a horizontal edge under drag)

// A platform that draws its own window caption (Windows: the native
// one cannot center its title) sets g_caption_h before the first
// app_resize and keeps g_win_zoomed current. The view renders the
// bar into y in [-g_caption_h, 0); the gpu backend shifts all output
// down by the same amount, so the core's coordinate space is
// untouched. Zero = the OS draws the caption (macOS).
i32 g_caption_h = 0;
bool g_win_zoomed = false;
// The window button under the pointer and the one held down, 0 min 1
// max 2 close, -1 none. The driver keeps them current; the caption
// draws the hover and pressed looks from them. A button acts on
// release over itself, as every caption button does.
i32 g_caption_hover = -1;
i32 g_caption_press = -1;

// UTF-16 surrogate range, for the shells that receive UTF-16 input.
const u32 SURR_HI = 0xD800;
const u32 SURR_LO = 0xDC00;
const u32 SURR_END = 0xDFFF;
const u32 SURR_BASE = 0x10000;

u32 utf8_next(u8* s, i32 n, i32* ip) {
    i32 i = *ip;
    u32 c = s[i];
    if c < 0x80 {
        *ip = i + 1;
        return c;
    }
    if (c & 0xE0) == 0xC0 && i + 1 < n {
        *ip = i + 2;
        return ((c & 0x1F) << 6) | (cast(u32, s[i + 1]) & 0x3F);
    }
    if (c & 0xF0) == 0xE0 && i + 2 < n {
        *ip = i + 3;
        return ((c & 0x0F) << 12) | ((cast(u32, s[i + 1]) & 0x3F) << 6) | (cast(u32, s[i + 2]) & 0x3F);
    }
    if (c & 0xF8) == 0xF0 && i + 3 < n {
        *ip = i + 4;
        return ((c & 0x07) << 18) | ((cast(u32, s[i + 1]) & 0x3F) << 12) | ((cast(u32, s[i + 2]) & 0x3F) << 6) | (cast(u32, s[i + 3]) & 0x3F);
    }
    *ip = i + 1;
    return 0xFFFD;
}

// ASCII upper case folded to lower; every other byte as it is
u8 ascii_lower(u8 c) {
    if c >= 'A' && c <= 'Z' { return cast(u8, c + 32); }
    return c;
}

// the offset of a path's last component, past its last separator
i32 path_base_off(u8* p, i32 n) {
    i32 base = 0;
    for i32 i = 0; i < n; i++ {
        if p[i] == '/' || p[i] == 92 { base = i + 1; }
    }
    return base;
}

i32 utf8_encode(u32 cp, u8* dst) {
    if cp < 0x80 {
        dst[0] = cast(u8, cp);
        return 1;
    }
    if cp < 0x800 {
        dst[0] = cast(u8, 0xC0 | (cp >> 6));
        dst[1] = cast(u8, 0x80 | (cp & 0x3F));
        return 2;
    }
    if cp < 0x10000 {
        dst[0] = cast(u8, 0xE0 | (cp >> 12));
        dst[1] = cast(u8, 0x80 | ((cp >> 6) & 0x3F));
        dst[2] = cast(u8, 0x80 | (cp & 0x3F));
        return 3;
    }
    dst[0] = cast(u8, 0xF0 | (cp >> 18));
    dst[1] = cast(u8, 0x80 | ((cp >> 12) & 0x3F));
    dst[2] = cast(u8, 0x80 | ((cp >> 6) & 0x3F));
    dst[3] = cast(u8, 0x80 | (cp & 0x3F));
    return 4;
}

// Codepoints that default to emoji presentation (Emoji_Presentation =
// Yes) outside 0x1F300..0x1FAFF: these render as a color emoji and so
// take two cells, like terminals count them. Text-presentation symbols
// in the same blocks (a lone ✔, ☑) stay one cell unless a VS16 clusters
// them into an emoji.
private bool cp_emoji_wide(u32 c) {
    if c < 0x1F000 { return cp_emoji_presentation(c); }   // the BMP part is the same list
    if cp_ri(c) { return true; }   // regional indicators
    return c == 0x1F004 || c == 0x1F0CF
        || c == 0x1F18E || (c >= 0x1F191 && c <= 0x1F19A)
        || c == 0x1F201 || c == 0x1F21A || c == 0x1F22F
        || (c >= 0x1F232 && c <= 0x1F236) || (c >= 0x1F238 && c <= 0x1F23A)
        || (c >= 0x1F250 && c <= 0x1F251);
}

// Cells a codepoint occupies on the mono grid: 2 for East Asian
// Wide/Fullwidth and most emoji, else 1 — the same convention as
// terminals and mainstream editors, so column-aligned files
// agree. Ambiguous-
// width characters count as narrow, also the convention.
i32 cp_width(u32 cp) {
    if cp < 0x1100 { return 1; }
    if cp_emoji_wide(cp) { return 2; }
    if (cp >= 0x1100 && cp <= 0x115F)      // Hangul Jamo leads
        || (cp >= 0x2E80 && cp <= 0x303E)  // CJK radicals..symbols
        || (cp >= 0x3041 && cp <= 0x33FF)  // kana, CJK compat
        || (cp >= 0x3400 && cp <= 0x4DBF)  // CJK ext A
        || (cp >= 0x4E00 && cp <= 0x9FFF)  // CJK unified
        || (cp >= 0xA000 && cp <= 0xA4CF)  // Yi
        || (cp >= 0xAC00 && cp <= 0xD7A3)  // Hangul syllables
        || (cp >= 0xF900 && cp <= 0xFAFF)  // CJK compat ideographs
        || (cp >= 0xFE30 && cp <= 0xFE4F)  // CJK compat forms
        || (cp >= 0xFF00 && cp <= 0xFF60)  // fullwidth forms
        || (cp >= 0xFFE0 && cp <= 0xFFE6)
        || (cp >= 0x1F300 && cp <= 0x1FAFF)   // emoji blocks
        || (cp >= 0x20000 && cp <= 0x3FFFD) { // CJK ext B and up
        return 2;
    }
    return 1;
}

// --- grapheme clusters (emoji sequences) ------------------------------
// The mono grid's edit/display unit is a grapheme cluster, not a
// codepoint, so a multi-codepoint emoji (skin tone, ZWJ family, flag,
// keycap, VS16) is one cell pair and the caret, column math and editing
// treat it as one. Only emoji clusters are grouped; other text steps a
// codepoint at a time as before. The rules follow UTS #51 emoji
// sequences; the base set is an approximation of Extended_Pictographic.
const u32 CP_ZWJ = 0x200D;
const u32 CP_VS16 = 0xFE0F;
const u32 CP_VS15 = 0xFE0E;
const u32 CP_KEYCAP = 0x20E3;
// OR a shaped emoji glyph id into a codepoint: the backend renders that
// glyph of the emoji face (a whole cluster shaped to one glyph).
const u32 FONT_GLYPHID = 0x80000000;

bool cp_emoji_base(u32 c) {
    if c == 0xA9 || c == 0xAE || c == 0x203C || c == 0x2049 { return true; }
    if c == 0x2122 || c == 0x2139 { return true; }
    if c >= 0x2190 && c <= 0x21FF { return true; }   // arrows (approx)
    if c >= 0x2300 && c <= 0x23FF { return true; }   // misc technical
    if c >= 0x2460 && c <= 0x24FF { return false; }
    if c >= 0x25A0 && c <= 0x27BF { return true; }   // shapes, misc symbols, dingbats
    if c >= 0x2900 && c <= 0x297F { return true; }
    if c >= 0x2B00 && c <= 0x2BFF { return true; }
    if c == 0x3030 || c == 0x303D || c == 0x3297 || c == 0x3299 { return true; }
    if c >= 0x1F000 && c <= 0x1FAFF { return true; }  // the emoji blocks
    return false;
}
// Emoji_Presentation: a codepoint that is drawn in color by default,
// with no variation selector asked for. Everything else in the symbol
// blocks is text by default and wants a monochrome face, which is what
// decides the order a backend tries its fallback faces in: a color
// font carries a monochrome twin for most of these (Segoe UI Symbol
// has the emoji too), so trying one first unconditionally either
// flattens the emoji or paints the dingbats.
bool cp_emoji_presentation(u32 c) {
    if c >= 0x1F000 && c <= 0x1FAFF { return true; }   // the emoji planes
    if c < 0x231A { return false; }
    if c <= 0x231B { return true; }
    if c >= 0x23E9 && c <= 0x23EC { return true; }
    if c == 0x23F0 || c == 0x23F3 { return true; }
    if c >= 0x25FD && c <= 0x25FE { return true; }
    if c >= 0x2614 && c <= 0x2615 { return true; }
    if c >= 0x2648 && c <= 0x2653 { return true; }
    if c == 0x267F || c == 0x2693 || c == 0x26A1 { return true; }
    if c >= 0x26AA && c <= 0x26AB { return true; }
    if c >= 0x26BD && c <= 0x26BE { return true; }
    if c >= 0x26C4 && c <= 0x26C5 { return true; }
    if c == 0x26CE || c == 0x26D4 || c == 0x26EA { return true; }
    if c >= 0x26F2 && c <= 0x26F3 { return true; }
    if c == 0x26F5 || c == 0x26FA || c == 0x26FD { return true; }
    if c == 0x2705 { return true; }
    if c >= 0x270A && c <= 0x270B { return true; }
    if c == 0x2728 || c == 0x274C || c == 0x274E { return true; }
    if c >= 0x2753 && c <= 0x2755 { return true; }
    if c == 0x2757 { return true; }
    if c >= 0x2795 && c <= 0x2797 { return true; }
    if c == 0x27B0 || c == 0x27BF { return true; }
    if c >= 0x2B1B && c <= 0x2B1C { return true; }
    if c == 0x2B50 || c == 0x2B55 { return true; }
    return false;
}
bool cp_ri(u32 c) { return c >= 0x1F1E6 && c <= 0x1F1FF; }
bool cp_emoji_mod(u32 c) { return c >= 0x1F3FB && c <= 0x1F3FF; }
bool cp_keycap_base(u32 c) { return c == 0x23 || c == 0x2A || (c >= 0x30 && c <= 0x39); }
bool cp_tag(u32 c) { return c >= 0xE0020 && c <= 0xE007F; }

// Advance *ip over one grapheme cluster from a codepoint boundary and
// return its cell width. A lone codepoint keeps cp_width; a genuine
// multi-codepoint emoji cluster is two cells.
i32 grapheme_next_w(u8* s, i32 n, i32* ip) {
    i32 i = *ip;
    u32 c0 = utf8_next(s, n, &i);
    i32 first_end = i;

    if cp_ri(c0) {
        if i < n {
            i32 j = i;
            if cp_ri(utf8_next(s, n, &j)) { *ip = j; return 2; }
        }
        *ip = first_end;
        return cp_width(c0);
    }
    if cp_keycap_base(c0) {
        if i < n {
            i32 j = i;
            u32 c1 = utf8_next(s, n, &j);
            if c1 == CP_VS16 && j < n {
                i32 j2 = j;
                if utf8_next(s, n, &j2) == CP_KEYCAP { *ip = j2; return 2; }
            } else if c1 == CP_KEYCAP {
                *ip = j;
                return 2;
            }
        }
        *ip = first_end;
        return cp_width(c0);
    }

    bool emoji = cp_emoji_base(c0);
    i32 end = first_end;
    if end < n {
        i32 j = end;
        u32 vs = utf8_next(s, n, &j);
        if vs == CP_VS16 { emoji = true; end = j; }
        else if vs == CP_VS15 { *ip = j; return cp_width(c0); }
    }
    if !emoji { *ip = first_end; return cp_width(c0); }

    if end < n {
        i32 j = end;
        if cp_emoji_mod(utf8_next(s, n, &j)) { end = j; }
    }
    while end < n {
        i32 j = end;
        if cp_tag(utf8_next(s, n, &j)) { end = j; } else { break; }
    }
    while end < n {
        i32 j = end;
        if utf8_next(s, n, &j) != CP_ZWJ || j >= n { break; }
        i32 k = j;
        u32 nb = utf8_next(s, n, &k);
        if !cp_emoji_base(nb) && !cp_ri(nb) { break; }
        end = k;
        if end < n { i32 v = end; if utf8_next(s, n, &v) == CP_VS16 { end = v; } }
        if end < n { i32 m = end; if cp_emoji_mod(utf8_next(s, n, &m)) { end = m; } }
    }
    *ip = end;
    if end > first_end { return 2; }   // a real multi-codepoint cluster
    return cp_width(c0);
}

// The start of the grapheme cluster that ends at (or contains) `pos`.
i32 grapheme_prev(u8* s, i32 n, i32 pos) {
    if pos <= 0 { return 0; }
    i32 i = 0;
    i32 last = 0;
    while i < pos {
        last = i;
        ignore grapheme_next_w(s, n, &i);
    }
    return last;
}
