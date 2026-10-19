// switcher.mc - Ctrl+K W: what is open. One list of the buffers and
// the terminals, each with where it shows, narrowed by what is typed;
// Enter puts the chosen one in the active pane, in place of what that
// pane showed. A terminal put aside this way keeps running in the
// background and stays in the list until its pane is closed with
// Ctrl+W, so a long command can be checked on later. While the chord
// that opened it is held, the pane shows the row the list is on as it
// is walked, so the result is seen before the chord is let go; Esc
// puts back what the pane showed. The preview does not count as a
// look, so the list's order is the same as without it.

private const i32 SW_QUERY_MAX = 128;
private const i32 SW_MAX = BUF_MAX + TERM_MAX;
private const i32 SW_VIS = 12;           // rows shown
private const i32 SW_COLS = 60;          // panel width in cells, clamped
const i32 SW_BUF = 0;
const i32 SW_TERM = 1;

private struct SwItem {
    i32 kind;     // SW_BUF: a buffer index; SW_TERM: a terminal handle
    i32 id;
}

bool switcher_on = false;
// The modifier the chord that opened it is held with, or 0 when it was
// opened to type at (Ctrl+K W). While it is held the list is a chord in
// progress: letting it go accepts the row, the way a window switcher
// does, so Enter is not needed. See switcher_mods.
private i32 sw_hold = 0;

private u8[SW_QUERY_MAX] sw_q;
private i32 sw_qlen = 0;
private SwItem[SW_MAX] sw_items;
private i32 sw_n = 0;
private i32 sw_sel = 0;
private i32 sw_top = 0;
private f32 sw_scroll_accum = 0.0f;
// what the active pane showed at open, for Esc after a preview
private SwItem sw_orig;
private bool sw_peeked = false;

private i32 sw_rows() {
    i32 nr = sw_n - sw_top;
    i32 vis = ui_list_vis(SW_VIS);
    if nr > vis { nr = vis; }
    if nr < 1 { nr = 1; }   // the "nothing" row
    return nr;
}

private str sw_name(SwItem it) {
    if it.kind == SW_BUF { return ed_buf_title(it.id); }
    return term_label(it.id);
}

// `q` inside `s`, letters compared without case
private bool sw_match(str s, str q) {
    if q.len == 0 { return true; }
    if q.len > s.len { return false; }
    for i32 i = 0; i + q.len <= s.len; i++ {
        bool ok = true;
        for i32 k = 0; k < q.len && ok; k++ {
            if ascii_lower(s.data[i + k]) != ascii_lower(q.data[k]) { ok = false; }
        }
        if ok { return true; }
    }
    return false;
}

// the active pane's own item, so the list can start on its neighbor
private bool sw_is_current(SwItem it) {
    i32 p = ed_pane_active();
    if ed_pane_kind(p) == PANE_TERM { return it.kind == SW_TERM && it.id == ed_pane_term(p); }
    return it.kind == SW_BUF && it.id == ed_buf_active();
}

private void sw_build() {
    str q = str_from(&sw_q[0], sw_qlen);
    sw_n = 0;
    for i32 b = 0; b < ed_buf_count() && sw_n < SW_MAX; b++ {
        SwItem it = SwItem{ SW_BUF, b };
        if sw_match(sw_name(it), q) {
            sw_items[sw_n] = it;
            sw_n++;
        }
    }
    // the buffers in the order they were last seen, the way a window
    // switcher lists windows: the next row is where the eye just was
    for i32 i = 1; i < sw_n; i++ {
        SwItem it = sw_items[i];
        i32 j = i;
        while j > 0 && ed_buf_used(sw_items[j - 1].id) < ed_buf_used(it.id) {
            sw_items[j] = sw_items[j - 1];
            j--;
        }
        sw_items[j] = it;
    }
    for i32 t = 0; t < TERM_MAX && sw_n < SW_MAX; t++ {
        if !term_has_child(t) { continue; }
        SwItem it = SwItem{ SW_TERM, t };
        if sw_match(sw_name(it), q) {
            sw_items[sw_n] = it;
            sw_n++;
        }
    }
    if sw_sel >= sw_n { sw_sel = sw_n - 1; }
    if sw_sel < 0 { sw_sel = 0; }
    if sw_top > sw_sel { sw_top = sw_sel; }
    if sw_top < 0 { sw_top = 0; }
}

void switcher_open() {
    sw_open(1, 0);
}

// The switcher's chord: Ctrl+Tab, Ctrl+`, and Alt+` for the hand that
// knows Cmd+` from macOS, where Cmd sits where Alt does. The modifier it
// returns is the one the list waits on: letting it go accepts the row.
// 0 when the key is not the chord. Not Option+` on macOS, which types a
// dead-key accent there; Cmd+` is the chord on that keyboard.
i32 switcher_chord_hold(i32 key, i32 mods) {
    if key == K_TAB && (mods & (MOD_CTRL | MOD_SUPER)) != 0 { return mods & (MOD_CTRL | MOD_SUPER); }
    if key == 96 && (mods & MOD_CTRL) != 0 { return mods & (MOD_CTRL | MOD_SUPER); }
    when !os(macos) {
        if key == 96 && (mods & MOD_ALT) != 0 { return MOD_ALT; }
    }
    return 0;
}

// `dir` steps from what the active pane shows: 1 is the next thing, the
// way a window switcher opens on the previous window, so Enter alone
// accepts it. Ctrl+Tab opens it this way and steps again on every
// repeat, which is the buffer cycle with its state on screen. `hold` is
// the modifier that chord is held with: released, it accepts.
void switcher_open_at(i32 dir, i32 hold) {
    sw_open(dir, hold);
}

private void sw_open(i32 dir, i32 hold) {
    find_close();
    sw_hold = hold;
    sw_qlen = 0;
    sw_sel = 0;
    sw_top = 0;
    sw_scroll_accum = 0.0f;
    sw_peeked = false;
    i32 p = ed_pane_active();
    if ed_pane_kind(p) == PANE_TERM {
        sw_orig = SwItem{ SW_TERM, ed_pane_term(p) };
    } else {
        sw_orig = SwItem{ SW_BUF, ed_buf_active() };
    }
    switcher_on = true;
    sw_build();
    for i32 i = 0; i < sw_n; i++ {
        if sw_is_current(sw_items[i]) {
            sw_sel = i;
            sw_step(dir);
            return;
        }
    }
    // nothing on screen is in the list: the first row is as good a start
    sw_show_sel();
}

void switcher_close() {
    switcher_on = false;
    sw_hold = 0;
    sw_peeked = false;
    ed_damage();
}

// the row the list is on, into the pane, while the chord is held
private void sw_peek() {
    if sw_hold == 0 || sw_n == 0 { return; }
    SwItem it = sw_items[sw_sel];
    if it.kind == SW_BUF { ed_show_buf_peek(it.id); } else { ed_show_term(it.id); }
    sw_peeked = true;
}

// the list left without a choice: the pane shows what it showed
private void sw_cancel() {
    if sw_peeked {
        if sw_orig.kind == SW_BUF { ed_show_buf_peek(sw_orig.id); } else { ed_show_term(sw_orig.id); }
    }
    switcher_close();
}

// The modifiers now held, from the platform's own report of a change.
// The chord's modifier going away accepts what the list is on; a list
// opened to type at has no hold and ignores this.
void switcher_mods(i32 mods) {
    if !switcher_on || sw_hold == 0 { return; }
    if (mods & sw_hold) != 0 { return; }
    sw_accept();
}

private void sw_accept() {
    if sw_n > 0 {
        SwItem it = sw_items[sw_sel];
        switcher_close();
        if it.kind == SW_BUF {
            ed_show_buf(it.id);
            ed_buf_seen();   // a previewed buffer is on screen already, and seen now
        } else {
            ed_show_term(it.id);
        }
        return;
    }
    switcher_close();
}

// scroll the selection into view
private void sw_show_sel() {
    if sw_sel < sw_top { sw_top = sw_sel; }
    i32 vis = ui_list_vis(SW_VIS);
    if sw_sel >= sw_top + vis { sw_top = sw_sel - vis + 1; }
    if sw_top < 0 { sw_top = 0; }
    ed_damage();
}

// the arrows and the wheel walk the list and stop at its ends
private void sw_move(i32 delta) {
    sw_sel += delta;
    if sw_sel >= sw_n { sw_sel = sw_n - 1; }
    if sw_sel < 0 { sw_sel = 0; }
    sw_show_sel();
    sw_peek();
}

// the chord wraps instead: a cycle has no ends
private void sw_step(i32 dir) {
    if sw_n > 0 { sw_sel = ((sw_sel + dir) % sw_n + sw_n) % sw_n; }
    sw_show_sel();
    sw_peek();
}

private UiField sw_field;

private UiField* switcher_field() {
    ui_field_bind(&sw_field, &sw_q[0], &sw_qlen, SW_QUERY_MAX);
    return &sw_field;
}

// the query changed: the list is rebuilt from its top
private void sw_query_changed() {
    sw_sel = 0;
    sw_top = 0;
    sw_build();
    ed_damage();
}

void switcher_char(u32 cp) {
    if cp == 13 { sw_accept(); return; }
    if ui_field_char(switcher_field(), cp) { sw_query_changed(); }
}

void switcher_key(i32 key, i32 mods) {
    // the chord that opened it steps on, held down: Ctrl+Tab again is
    // the next row, with shift the previous one
    i32 hold = switcher_chord_hold(key, mods);
    if hold != 0 {
        i32 d = 1;
        if (mods & MOD_SHIFT) != 0 { d = -1; }
        // a repeat re-arms the hold: the chord may have opened the list
        // with one modifier and be stepped with the other
        sw_hold = hold;
        sw_step(d);
        return;
    }
    bool changed = false;
    if ui_field_key(switcher_field(), key, mods, &changed) {
        if changed { sw_query_changed(); } else { ed_damage(); }
        return;
    }
    if (mods & MOD_CTRL) != 0 { return; }
    if key == K_ESCAPE { sw_cancel(); return; }
    if key == K_UP { sw_move(-1); return; }
    if key == K_DOWN { sw_move(1); return; }
    if key == K_PGUP { sw_move(0 - ui_list_vis(SW_VIS)); return; }
    if key == K_PGDN { sw_move(ui_list_vis(SW_VIS)); return; }
}

// tests read these back
i32 switcher_count() {
    return sw_n;
}

i32 switcher_item_kind(i32 i) {
    if i < 0 || i >= sw_n { return -1; }
    return sw_items[i].kind;
}

i32 switcher_item_id(i32 i) {
    if i < 0 || i >= sw_n { return -1; }
    return sw_items[i].id;
}

i32 switcher_sel() {
    return sw_sel;
}

// --- mouse, scroll, render -------------------------------------------------

// left-button press: a row takes it, anywhere outside closes
void switcher_mouse(i32 x, i32 y) {
    i32 pw = ui_list_panel_w(SW_COLS);
    i32 px = (g_w - pw) / 2;
    i32 pad = ui_list_pad();
    i32 ih = ui_input_h();
    i32 rh = ui_list_row_h();
    i32 py = pad;
    i32 ry = py + pad + ih + 4;
    if x >= px && x < px + pw && y >= ry && y < ry + sw_rows() * rh {
        i32 r = sw_top + (y - ry) / rh;
        if r < sw_n {
            sw_sel = r;
            sw_accept();
            return;
        }
    }
    i32 ph = pad + ih + 4 + sw_rows() * rh + pad;
    if x < px || x >= px + pw || y < py || y >= py + ph {
        sw_cancel();
    }
}

void switcher_scroll(f32 dy) {
    sw_scroll_accum += dy;
    i32 rh = ui_list_row_h();
    i32 rows = cast(i32, sw_scroll_accum / cast(f32, rh));
    if rows == 0 { return; }
    sw_scroll_accum -= cast(f32, rows * rh);
    sw_top += rows;
    if sw_top > sw_n - ui_list_vis(SW_VIS) { sw_top = sw_n - ui_list_vis(SW_VIS); }
    if sw_top < 0 { sw_top = 0; }
    ed_damage();
}

// what an item is and where it shows, after its name: "pane 2" for one
// on screen, "modified" for a dirty buffer, "background" or "exited N"
// for a terminal, "build" for the build's
private i32 sw_tag(SwItem it, u8* out, i32 cap) {
    i32 o = 0;
    i32 p = -1;
    if it.kind == SW_BUF { p = ed_pane_of_buf(it.id); } else { p = ed_pane_of_term(it.id); }
    if it.kind == SW_TERM && it.id == build_term() {
        str s = "build  ";
        memcpy(out + o, s.data, s.len);
        o += s.len;
    }
    if p >= 0 {
        str s = "pane ";
        memcpy(out + o, s.data, s.len);
        o += s.len;
        o += fmt_i32(out + o, p + 1);
    } else if it.kind == SW_TERM {
        if term_exited(it.id) {
            str s = "exited ";
            memcpy(out + o, s.data, s.len);
            o += s.len;
            o += fmt_i32(out + o, term_code(it.id));
        } else {
            str s = "background";
            memcpy(out + o, s.data, s.len);
            o += s.len;
        }
    }
    if it.kind == SW_BUF && ed_buf_dirty(it.id) {
        if o > 0 { out[o] = ','; out[o + 1] = ' '; o += 2; }
        str s = "modified";
        memcpy(out + o, s.data, s.len);
        o += s.len;
    }
    if o > cap { o = cap; }
    return o;
}

void switcher_render() {
    if !switcher_on { return; }
    i32 pw = ui_list_panel_w(SW_COLS);
    i32 px = (g_w - pw) / 2;
    i32 pad = ui_list_pad();
    i32 py = pad;
    i32 ih = ui_input_h();
    i32 rh = ui_list_row_h();
    i32 nr = sw_rows();
    i32 ph = pad + ih + 4 + nr * rh + pad;

    ui_panel(px, py, pw, ph);
    ui_input(px + pad, py + pad, pw - 2 * pad,
        switcher_field(), "open buffers and terminals", caret_on);

    i32 tx = px + pad + 2 + ui_inset();
    i32 ty = py + pad + ih + 4;
    f32 max_px = cast(f32, px + pw - pad - ui_inset());
    if sw_n == 0 {
        ignore font_draw_ui_text("nothing matched", cast(f32, tx),
            cast(f32, ty + (rh - font_ui_h) / 2), max_px, T_DIM);
    }
    noinit u8[64] tag;
    for i32 r = 0; r < nr && sw_top + r < sw_n; r++ {
        i32 h = sw_top + r;
        SwItem it = sw_items[h];
        i32 y = ty + r * rh;
        ui_list_row(px + 1, y, pw - 2, rh, h == sw_sel);
        f32 ny = cast(f32, y + (rh - font_ui_h) / 2);
        f32 x = font_draw_ui_text(sw_name(it), cast(f32, tx), ny, max_px, T_FG);
        i32 tn = sw_tag(it, &tag[0], 64);
        if tn > 0 {
            x += cast(f32, 2 * font_cell_w);
            ignore font_draw_ui_text(str_from(&tag[0], tn), x, ny, max_px, T_DIM);
        }
    }
    ui_list_scrollbar(px + pw - 1, ty, nr * rh, sw_top, nr, sw_n);
}
