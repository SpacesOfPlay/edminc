// ui.mc - element primitives for the workbench chrome. Each
// element's look is encoded here exactly once, from theme
// tokens and metrics; widgets do layout and call. Everything draws
// into the shared quad batch.

// Top-attached panel: 2px border, rounded bottom corners. The rects
// extend past the window top so their top rounding clips away.
void ui_panel_top(i32 x, i32 w, i32 h) {
    i32 rad = ui_rad();
    draw_rect_rounded(cast(f32, x - 2), cast(f32, 0 - rad - 2),
        cast(f32, w + 4), cast(f32, h + 4 + rad), rad + 1, T_WIDGET_BORDER);
    draw_rect_rounded(cast(f32, x), cast(f32, 0 - rad),
        cast(f32, w), cast(f32, h + rad), rad, T_WIDGET_BG);
}

// Floating panel: 2px border.
void ui_panel(i32 x, i32 y, i32 w, i32 h) {
    draw_rect(cast(f32, x - 2), cast(f32, y - 2), cast(f32, w + 4), cast(f32, h + 4), T_WIDGET_BORDER);
    draw_rect(cast(f32, x), cast(f32, y), cast(f32, w), cast(f32, h), T_WIDGET_BG);
}

// Focused input box: 2px focus ring, fill, the field's text or a dim
// placeholder in the UI face, the caret where the field has it. w is
// the full outer width; the text scrolls under the box to keep the
// caret in it.
void ui_input(i32 x, i32 y, i32 w, UiField* f, str placeholder, bool caret) {
    ui_input_ex(x, y, w, f, placeholder, caret, true);
}

// The same box with or without the keyboard: an unfocused one has no
// ring, only its fill, as the reference draws a second input.
void ui_input_ex(i32 x, i32 y, i32 w, UiField* f, str placeholder, bool caret, bool focused) {
    i32 rad = ui_rad();
    i32 ih = ui_input_h();
    if focused {
        draw_rect_rounded(cast(f32, x), cast(f32, y), cast(f32, w), cast(f32, ih), rad + 1, T_FOCUS);
        draw_rect_rounded(cast(f32, x + 2), cast(f32, y + 2), cast(f32, w - 4), cast(f32, ih - 4), rad - 1, T_INPUT_BG);
    } else {
        draw_rect_rounded(cast(f32, x), cast(f32, y), cast(f32, w), cast(f32, ih), rad + 1, T_INPUT_BG);
    }
    f32 tx = cast(f32, x + 2 + ui_inset());
    f32 ty = cast(f32, ui_input_text_y(y));
    f32 max_x = cast(f32, x + w - 2 - ui_inset());
    if *f.len > 0 {
        ignore ui_field_draw(f, tx, ty, max_x, T_FG, caret);
    } else {
        ignore font_draw_ui_text(placeholder, tx, ty, max_x, T_DIM);
        if caret {
            draw_rect(tx, ty, UI_CARET_W, cast(f32, font_ui_h), T_FG);
        }
    }
}

// y of the text row inside an input at y (the UI face centered in
// the box), for content aligned to it
i32 ui_input_text_y(i32 y) {
    return y + (ui_input_h() - font_ui_h) / 2;
}

// list row background; only the selected row draws
void ui_list_row(i32 x, i32 y, i32 w, i32 h, bool selected) {
    if selected {
        draw_rect(cast(f32, x), cast(f32, y), cast(f32, w), cast(f32, h), T_LIST_SEL);
    }
}

// the offset of the longest tail of `s` that fits in `budget` pixels of
// UI text: a long path keeps its end, the way an input keeps its caret
i32 ui_text_tail_off(str s, i32 budget) {
    i32 o = 0;
    while o < s.len && font_ui_text_w(str_from(s.data + o, s.len - o)) > budget {
        o++;
        while o < s.len && (s.data[o] & 0xC0) == 0x80 { o++; }
    }
    return o;
}

// --- the overlay lists ----------------------------------------------
// The picker, the symbol search and the switcher share one shape: a
// panel at the top of the window with an input line and rows under it.

i32 ui_list_pad() {
    return font_line_h / 4;
}

i32 ui_list_row_h() {
    // reference list rows; the mono-derived fallback covers stubs
    if font_ui_row > 0 { return font_ui_row; }
    return font_line_h + 2;
}

// the panel width for `cols` cells of content, clamped to the window
i32 ui_list_panel_w(i32 cols) {
    i32 pw = cols * font_cell_w + 2 * ui_list_pad();
    if pw > g_w - 16 { pw = g_w - 16; }
    return pw;
}

// A list's scrollbar: a thumb over the right edge x1 of the rows, which
// span y to y + h, when `total` rows overflow the `vis` shown from
// `top`. Its length and place are the shown rows' share and offset, as
// in a pane.
private const i32 UI_SCROLL_W = 6;
private const i32 UI_SCROLL_PAD = 2;
private const i32 UI_SCROLL_MIN = 16;

void ui_list_scrollbar(i32 x1, i32 y, i32 h, i32 top, i32 vis, i32 total) {
    if total <= vis || vis <= 0 || h <= 0 { return; }
    i32 th = h * vis / total;
    if th < UI_SCROLL_MIN { th = UI_SCROLL_MIN; }
    if th > h { th = h; }
    i32 t = top;
    if t > total - vis { t = total - vis; }
    if t < 0 { t = 0; }
    i32 ty = y + (h - th) * t / (total - vis);
    draw_rect_rounded(cast(f32, x1 - UI_SCROLL_W - UI_SCROLL_PAD), cast(f32, ty),
        cast(f32, UI_SCROLL_W), cast(f32, th), UI_SCROLL_W / 2, C_SCROLL);
}

// the rows that fit under the input, at most vis_max: a short window
// would otherwise get a panel taller than itself
i32 ui_list_vis(i32 vis_max) {
    i32 room = g_h - 3 * ui_list_pad() - ui_input_h() - 6;
    i32 rh = ui_list_row_h();
    i32 n = 0;
    if rh > 0 && room > 0 { n = room / rh; }
    if n > vis_max { n = vis_max; }
    if n < 1 { n = 1; }
    return n;
}

// --- the input line's editing -----------------------------------------
// Every query line is one of these: the widget owns the bytes and their
// length (it reads them as before), the field the caret and the
// selection over them. Offsets are bytes on character boundaries; the
// caret is the moving end of the selection and anchor the fixed one,
// -1 when there is none. The keys are the editor's own for one line:
// arrows, Home/End, MOD_WORD arrows (Cmd+arrows is Home/End on macOS),
// Shift extends, Delete, Ctrl+Backspace (char 127) and the primary's
// Delete take a word, and the primary's A, C, X and V are the
// selection chords; a paste takes the clipboard's first line.

private const f32 UI_CARET_W = 2.0f;

struct UiField {
    u8* buf;
    i32* len;
    i32 cap;
    i32 caret;
    i32 anchor;
    i32 scroll;   // px the text is shifted left so the caret is in view
}

// Binds the field to its bytes. Called at every use rather than once,
// since the widget's open path may reset the length behind the field's
// back; the caret is kept and clamped, the selection dropped when it
// no longer fits.
void ui_field_bind(UiField* f, u8* buf, i32* len, i32 cap) {
    f.buf = buf;
    f.len = len;
    f.cap = cap;
    if f.caret > *len { f.caret = *len; }
    if f.caret < 0 { f.caret = 0; }
    if f.anchor > *len || f.anchor == f.caret { f.anchor = -1; }
}

// the caret to the end with no selection: for a widget that put its
// own text in the buffer
void ui_field_end(UiField* f) {
    f.caret = *f.len;
    f.anchor = -1;
}

// the selection as [a, b), false when there is none
bool ui_field_sel(UiField* f, i32* a, i32* b) {
    if f.anchor < 0 || f.anchor == f.caret { return false; }
    if f.anchor < f.caret {
        *a = f.anchor;
        *b = f.caret;
    } else {
        *a = f.caret;
        *b = f.anchor;
    }
    return true;
}

private i32 ui_field_prev(UiField* f, i32 i) {
    if i <= 0 { return 0; }
    i--;
    while i > 0 && (f.buf[i] & 0xC0) == 0x80 { i--; }
    return i;
}

private i32 ui_field_next(UiField* f, i32 i) {
    i32 n = *f.len;
    if i >= n { return n; }
    i++;
    while i < n && (f.buf[i] & 0xC0) == 0x80 { i++; }
    return i;
}

private bool ui_word_byte(u8 c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_' || c >= 0x80;
}

private bool ui_space_byte(u8 c) {
    return c == ' ' || c == '\t';
}

// the word boundaries the editor's own word movement uses: spaces are
// skipped, then one run of word bytes or one of punctuation
private i32 ui_field_word_left(UiField* f, i32 p) {
    u8* q = f.buf;
    while p > 0 && ui_space_byte(q[p - 1]) { p--; }
    if p > 0 {
        if ui_word_byte(q[p - 1]) {
            while p > 0 && ui_word_byte(q[p - 1]) { p--; }
        } else {
            while p > 0 && !ui_word_byte(q[p - 1]) && !ui_space_byte(q[p - 1]) { p--; }
        }
    }
    return p;
}

private i32 ui_field_word_right(UiField* f, i32 p) {
    u8* q = f.buf;
    i32 n = *f.len;
    while p < n && ui_space_byte(q[p]) { p++; }
    if p < n {
        if ui_word_byte(q[p]) {
            while p < n && ui_word_byte(q[p]) { p++; }
        } else {
            while p < n && !ui_word_byte(q[p]) && !ui_space_byte(q[p]) { p++; }
        }
    }
    return p;
}

// the bytes [i, n) moved to `to`, in the order an overlap needs
private void ui_field_shift(UiField* f, i32 i, i32 to) {
    i32 n = *f.len;
    u8* q = f.buf;
    if to < i {
        for i32 k = i; k < n; k++ { q[to + k - i] = q[k]; }
    } else if to > i {
        for i32 k = n - 1; k >= i; k-- { q[to + k - i] = q[k]; }
    }
}

// removes [a, b); the caret lands at a
private void ui_field_cut_range(UiField* f, i32 a, i32 b) {
    i32 n = *f.len;
    ui_field_shift(f, b, a);
    *f.len = n - (b - a);
    f.caret = a;
    f.anchor = -1;
}

private bool ui_field_delete_sel(UiField* f) {
    i32 a = 0;
    i32 b = 0;
    if !ui_field_sel(f, &a, &b) { return false; }
    ui_field_cut_range(f, a, b);
    return true;
}

// puts s in at the caret, over the selection when there is one; what
// does not fit is dropped whole rather than cut inside a character
private bool ui_field_insert(UiField* f, u8* s, i32 n) {
    bool changed = ui_field_delete_sel(f);
    if n <= 0 { return changed; }
    i32 room = f.cap - *f.len;
    if n > room {
        n = room;
        while n > 0 && (s[n] & 0xC0) == 0x80 { n--; }
    }
    if n <= 0 { return changed; }
    i32 at = f.caret;
    ui_field_shift(f, at, at + n);
    memcpy(f.buf + at, s, n);
    *f.len = *f.len + n;
    f.caret = at + n;
    return true;
}

// moves the caret to p, extending the selection when shift is held
// and dropping it otherwise
private void ui_field_go(UiField* f, i32 p, bool shift) {
    if shift {
        if f.anchor < 0 { f.anchor = f.caret; }
    } else {
        f.anchor = -1;
    }
    f.caret = p;
    if f.anchor == f.caret { f.anchor = -1; }
}

// a typed character: text goes in at the caret, 8 is backspace and
// 127 the word backspace; true when the text changed. Enter and Tab
// are the widget's own and change nothing here.
bool ui_field_char(UiField* f, u32 cp) {
    if cp == 8 {
        if ui_field_delete_sel(f) { return true; }
        if f.caret == 0 { return false; }
        ui_field_cut_range(f, ui_field_prev(f, f.caret), f.caret);
        return true;
    }
    if cp == 127 {
        if ui_field_delete_sel(f) { return true; }
        if f.caret == 0 { return false; }
        ui_field_cut_range(f, ui_field_word_left(f, f.caret), f.caret);
        return true;
    }
    if cp < 32 { return false; }
    noinit u8[8] enc;
    i32 n = utf8_encode(cp, &enc[0]);
    return ui_field_insert(f, &enc[0], n);
}

private void ui_field_copy(UiField* f) {
    i32 a = 0;
    i32 b = 0;
    if !ui_field_sel(f, &a, &b) { return; }
    plat_clipboard_set(f.buf + a, b - a);
}

// the clipboard's first line goes in
private bool ui_field_paste(UiField* f) {
    i64 n = 0;
    u8* s = plat_clipboard_get(&n);
    if s == null { return false; }
    i32 k = 0;
    while cast(i64, k) < n && s[k] != '\n' && s[k] != '\r' { k++; }
    bool changed = ui_field_insert(f, s, k);
    free(s);
    return changed;
}

// A key on the field: true when it was the field's, with *changed set
// when the text is different after it (a move or a copy leaves it
// alone). Everything else is the widget's, and the chords that carry
// both the primary and Alt are the editor's pane moves.
bool ui_field_key(UiField* f, i32 key, i32 mods, bool* changed) {
    *changed = false;
    bool shift = (mods & MOD_SHIFT) != 0;
    bool prim = (mods & MOD_CTRL) != 0;
    bool word = (mods & MOD_WORD) != 0;
    if (mods & MOD_ALT) != 0 && (mods & (MOD_CTRL | MOD_SUPER)) != 0 { return false; }
    i32 a = 0;
    i32 b = 0;
    bool sel = ui_field_sel(f, &a, &b);
    if key == K_LEFT || key == K_RIGHT {
        bool left = key == K_LEFT;
        bool home = false;
        when os(macos) {
            home = prim;
        }
        i32 p = f.caret;
        if home {
            p = 0;
            if !left { p = *f.len; }
        } else if word {
            if left { p = ui_field_word_left(f, p); } else { p = ui_field_word_right(f, p); }
        } else if prim {
            return false;
        } else if sel && !shift {
            // a plain arrow leaves a selection at the end it names
            p = a;
            if !left { p = b; }
        } else {
            if left { p = ui_field_prev(f, p); } else { p = ui_field_next(f, p); }
        }
        ui_field_go(f, p, shift);
        return true;
    }
    if key == K_HOME || key == K_END {
        if prim { return false; }   // the editor's document start and end
        i32 p = 0;
        if key == K_END { p = *f.len; }
        ui_field_go(f, p, shift);
        return true;
    }
    if key == K_DELETE {
        if ui_field_delete_sel(f) {
            *changed = true;
            return true;
        }
        if f.caret >= *f.len { return true; }
        i32 e = ui_field_next(f, f.caret);
        if prim { e = ui_field_word_right(f, f.caret); }
        ui_field_cut_range(f, f.caret, e);
        *changed = true;
        return true;
    }
    if !prim || (mods & MOD_ALT) != 0 { return false; }
    if key == 'A' {
        f.anchor = 0;
        f.caret = *f.len;
        if f.caret == 0 { f.anchor = -1; }
        return true;
    }
    if key == 'C' {
        ui_field_copy(f);
        return true;
    }
    if key == 'X' {
        ui_field_copy(f);
        *changed = ui_field_delete_sel(f);
        return true;
    }
    if key == 'V' {
        *changed = ui_field_paste(f);
        return true;
    }
    return false;
}

// Draws the field's text on the UI face from x to max_x, the selection
// under it and the caret in it, the text shifted left as far as
// keeping the caret in view needs; returns the x after the text, at
// most max_x. Clipped to the span, and the clip is off afterwards.
f32 ui_field_draw(UiField* f, f32 x, f32 y, f32 max_x, u32 fg, bool caret) {
    i32 n = *f.len;
    u8* q = f.buf;
    // the caret at the far end stays inside the clip
    i32 budget = cast(i32, max_x - x - UI_CARET_W);
    if budget < 0 { budget = 0; }
    i32 total = font_ui_text_w(str_from(q, n));
    i32 cx = font_ui_text_w(str_from(q, f.caret));
    if cx - f.scroll > budget { f.scroll = cx - budget; }
    if cx < f.scroll { f.scroll = cx; }
    if total - f.scroll < budget { f.scroll = total - budget; }
    if f.scroll < 0 { f.scroll = 0; }
    f32 tx = x - cast(f32, f.scroll);
    draw_clip(x, max_x);
    i32 a = 0;
    i32 b = 0;
    if ui_field_sel(f, &a, &b) {
        f32 sx0 = tx + cast(f32, font_ui_text_w(str_from(q, a)));
        f32 sx1 = tx + cast(f32, font_ui_text_w(str_from(q, b)));
        draw_rect(sx0, y, sx1 - sx0, cast(f32, font_ui_h), T_LIST_SEL);
    }
    // the clip cuts the glyph at the edge; the drawer would drop it whole
    f32 end = font_draw_ui_text(str_from(q, n), tx, y, max_x + cast(f32, total), fg);
    if caret {
        draw_rect(tx + cast(f32, cx), y, UI_CARET_W, cast(f32, font_ui_h), fg);
    }
    draw_clip_off();
    if end > max_x { end = max_x; }
    return end;
}
