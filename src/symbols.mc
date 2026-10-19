// symbols.mc - ctrl+t: workspace symbol search. The query goes to the
// server as typed and the list is what it answers; nothing is narrowed
// here, since a new query is a new question. F12 stays program-scoped;
// this is the way to reach a symbol from a file whose program cannot
// see it.

const i32 SYM_QUERY_MAX = 128;
private const i32 SYM_MAX = 512;
private const i32 SYM_VIS = 12;          // result rows shown
private const i32 SYM_COLS = 80;         // panel width in cells, clamped

private struct SymHit {
    i32 noff;     // name, into the arena
    i32 nlen;
    i32 poff;     // path
    i32 plen;
    i32 line;
    i32 col;
}

bool sym_on = false;

private u8[SYM_QUERY_MAX] sy_q;
private i32 sy_qlen = 0;
private SymHit[SYM_MAX] sy_hits;
private i32 sy_n = 0;
private i32 sy_sel = 0;
private i32 sy_top = 0;
private bool sy_waiting = false;     // a request is out
// Enter while a request is out waits for the reply: the list on
// screen belongs to an earlier, shorter query, and taking its top hit
// would jump somewhere the user did not ask for.
private bool sy_accept_on_reply = false;
private f32 sy_scroll_accum = 0.0f;
private u8* sy_arena = null;
private i64 sy_alen = 0;
private i64 sy_acap = 0;

private i32 sym_rows() {
    i32 nr = sy_n - sy_top;
    i32 vis = ui_list_vis(SYM_VIS);
    if nr > vis { nr = vis; }
    if nr < 1 { nr = 1; }   // the "nothing" row
    return nr;
}

private i64 sym_arena_push(u8* p, i32 n) {
    if sy_alen + n > sy_acap {
        i64 ncap = sy_acap * 2 + 65536;
        u8* na = alloc<u8>(ncap);
        if sy_arena != null {
            memcpy(na, sy_arena, sy_alen);
            free(sy_arena);
        }
        sy_arena = na;
        sy_acap = ncap;
    }
    i64 off = sy_alen;
    memcpy(sy_arena + off, p, n);
    sy_alen += n;
    return off;
}

private void sym_ask() {
    if !lsp_ready {
        ed_status(ed_lsp_not_ready());
        return;
    }
    sy_waiting = true;
    lsp_request_symbols(str_from(&sy_q[0], sy_qlen));
}

void sym_open() {
    find_close();
    sy_accept_on_reply = false;
    sy_qlen = 0;
    sy_n = 0;
    sy_sel = 0;
    sy_top = 0;
    sy_scroll_accum = 0.0f;
    sym_on = true;
    ed_damage();
    sym_ask();
}

void sym_close() {
    sym_on = false;
    sy_accept_on_reply = false;
    ed_damage();
}

private void sym_accept() {
    if sy_n > 0 {
        SymHit h = sy_hits[sy_sel];
        // ed_lsp_goto records the nav history itself
        ed_lsp_goto(str_from(sy_arena + h.poff, h.plen), h.line, h.col);
    }
    sym_close();
}

private void sym_move(i32 delta) {
    sy_sel += delta;
    if sy_sel >= sy_n { sy_sel = sy_n - 1; }
    if sy_sel < 0 { sy_sel = 0; }
    if sy_sel < sy_top { sy_top = sy_sel; }
    i32 vis = ui_list_vis(SYM_VIS);
    if sy_sel >= sy_top + vis { sy_top = sy_sel - vis + 1; }
    ed_damage();
}

private UiField sy_field;

private UiField* sym_field() {
    ui_field_bind(&sy_field, &sy_q[0], &sy_qlen, SYM_QUERY_MAX);
    return &sy_field;
}

void sym_char(u32 cp) {
    if cp == 13 {
        if sy_waiting {
            sy_accept_on_reply = true;
        } else {
            sym_accept();
        }
        return;
    }
    if !ui_field_char(sym_field(), cp) { return; }
    sym_ask();
    ed_damage();
}

void sym_key(i32 key, i32 mods) {
    bool changed = false;
    if ui_field_key(sym_field(), key, mods, &changed) {
        if changed { sym_ask(); }
        ed_damage();
        return;
    }
    if (mods & MOD_CTRL) != 0 {
        if key == 'T' { sym_close(); }
        return;
    }
    if key == K_ESCAPE { sym_close(); return; }
    if key == K_UP { sym_move(-1); return; }
    if key == K_DOWN { sym_move(1); return; }
    if key == K_PGUP { sym_move(0 - ui_list_vis(SYM_VIS)); return; }
    if key == K_PGDN { sym_move(ui_list_vis(SYM_VIS)); return; }
}

// --- the reply -----------------------------------------------------------
// Only the newest request's reply reaches here: the client drops the
// id of a superseded one, so a slow answer to an old query cannot
// overwrite the list for the current one.

void sym_begin() {
    sy_n = 0;
    sy_alen = 0;
}

void sym_add(str name, str path, i32 line, i32 col) {
    if sy_n == SYM_MAX || name.len == 0 || path.len == 0 { return; }
    i64 no = sym_arena_push(name.data, name.len);
    i64 po = sym_arena_push(path.data, path.len);
    sy_hits[sy_n] = SymHit{ cast(i32, no), name.len, cast(i32, po),
        path.len, line, col };
    sy_n++;
}

void sym_end() {
    sy_waiting = false;
    if sy_sel >= sy_n { sy_sel = sy_n - 1; }
    if sy_sel < 0 { sy_sel = 0; }
    sy_top = 0;
    ed_damage();
    if sy_accept_on_reply {
        sy_accept_on_reply = false;
        sym_accept();
    }
}

// tests read these back
i32 sym_hit_count() {
    return sy_n;
}

str sym_hit_path(i32 i) {
    if i < 0 || i >= sy_n { return ""; }
    return str_from(sy_arena + sy_hits[i].poff, sy_hits[i].plen);
}

i32 sym_hit_line(i32 i) {
    if i < 0 || i >= sy_n { return -1; }
    return sy_hits[i].line;
}

str sym_query() {
    return str_from(&sy_q[0], sy_qlen);
}

// --- mouse, scroll, render -------------------------------------------------

// left-button press: a result row opens it, anywhere outside closes
void sym_mouse(i32 x, i32 y) {
    i32 pw = ui_list_panel_w(SYM_COLS);
    i32 px = (g_w - pw) / 2;
    i32 pad = ui_list_pad();
    i32 ih = ui_input_h();
    i32 rh = ui_list_row_h();
    i32 py = pad;
    i32 ry = py + pad + ih + 4;
    if x >= px && x < px + pw && y >= ry && y < ry + sym_rows() * rh {
        i32 r = sy_top + (y - ry) / rh;
        if r < sy_n {
            sy_sel = r;
            sym_accept();
            return;
        }
    }
    i32 ph = pad + ih + 4 + sym_rows() * rh + pad;
    if x < px || x >= px + pw || y < py || y >= py + ph {
        sym_close();
    }
}

void sym_scroll(f32 dy) {
    sy_scroll_accum += dy;
    i32 rh = ui_list_row_h();
    i32 rows = cast(i32, sy_scroll_accum / cast(f32, rh));
    if rows == 0 { return; }
    sy_scroll_accum -= cast(f32, rows * rh);
    sy_top += rows;
    if sy_top > sy_n - ui_list_vis(SYM_VIS) { sy_top = sy_n - ui_list_vis(SYM_VIS); }
    if sy_top < 0 { sy_top = 0; }
    ed_damage();
}

void sym_render() {
    if !sym_on { return; }
    i32 pw = ui_list_panel_w(SYM_COLS);
    i32 px = (g_w - pw) / 2;
    i32 pad = ui_list_pad();
    i32 py = pad;
    i32 ih = ui_input_h();
    i32 rh = ui_list_row_h();
    i32 nr = sym_rows();
    i32 ph = pad + ih + 4 + nr * rh + pad;

    ui_panel(px, py, pw, ph);
    ui_input(px + pad, py + pad, pw - 2 * pad,
        sym_field(), "search symbols in workspace", caret_on);

    i32 tx = px + pad + 2 + ui_inset();
    i32 ty = py + pad + ih + 4;
    f32 max_px = cast(f32, px + pw - pad - ui_inset());
    if sy_n == 0 {
        str msg = "no symbols matched";
        if sy_waiting { msg = "searching"; }
        if !lsp_ready { msg = ed_lsp_not_ready(); }
        ignore font_draw_ui_text(msg, cast(f32, tx),
            cast(f32, ty + (rh - font_ui_h) / 2), max_px, T_DIM);
    }
    noinit u8[16] numbuf;
    for i32 r = 0; r < nr && sy_top + r < sy_n; r++ {
        i32 h = sy_top + r;
        SymHit s = sy_hits[h];
        i32 y = ty + r * rh;
        ui_list_row(px + 1, y, pw - 2, rh, h == sy_sel);
        f32 ny = cast(f32, y + (rh - font_ui_h) / 2);
        f32 x = font_draw_ui_text(str_from(sy_arena + s.noff, s.nlen),
            cast(f32, tx), ny, max_px, T_FG);
        // where it lives, dim, after the name
        x += cast(f32, 2 * font_cell_w);
        x = font_draw_ui_text(str_from(sy_arena + s.poff, s.plen), x, ny, max_px, T_DIM);
        i32 nd = 1;
        numbuf[0] = ':';
        nd += fmt_i32(&numbuf[1], s.line + 1);
        ignore font_draw_ui_text(str_from(&numbuf[0], nd), x, ny, max_px, T_DIM);
    }
    ui_list_scrollbar(px + pw - 1, ty, nr * rh, sy_top, nr, sy_n);
}
