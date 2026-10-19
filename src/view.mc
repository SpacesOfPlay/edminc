// view.mc - frame build: text, gutter, caret, scrollbar, and
// status bar into the quad batch, presented through the gpu backend.

// The palette lives in lib/theme.mc, where a theme sets it.

private const i32 FIND_LINE_MARKS = 64;
// Squiggles drawn per line. A server can report many overlapping
// ranges on one line and they are indistinguishable once stacked, but
// each one is a run of quads across the visible width, so without a
// bound a pathological file can outgrow the whole batch.
private const i32 DIAG_MARKS_PER_LINE = 4;

private const f32 CARET_W = 2.0f;
private const i32 SCROLL_W = 6;
private const i32 SCROLL_PAD = 4;
private const i32 SCROLL_MIN_THUMB = 24;
private const i32 STATUS_PAD = 4;
private const f32 STATUS_MARGIN = 8.0f;
private const i32 STATUS_RESERVE = 24;  // cells kept free for Ln/Col

private u32 lex_color(u8 k) {
    if k == LEX_CTRL { return C_CTRL; }
    if k == LEX_DECL { return C_DECL; }
    if k == LEX_TYPE { return C_TYPE; }
    if k == LEX_VAR { return C_VAR; }
    if k == LEX_FN { return C_FN; }
    if k == LEX_STR { return C_STRLIT; }
    if k == LEX_ESC { return C_ESC; }
    if k == LEX_NUM { return C_NUM; }
    if k == LEX_COM { return C_COM; }
    if k == LEX_PRE { return C_PRE; }
    if k == LEX_LIST { return C_MDLIST; }
    // LEX_BR0..2 fall through to C_FG: bracket pair colorization is
    // off, matching the reference setup. The lexer still
    // tracks depth for a future setting.
    return C_FG;
}

// --- the explode view (explode.mc) --------------------------------------

// below this scale a glyph is a few pixels tall: the shape reads better
private const f32 EX_TEXT_MIN_SCALE = 0.35f;
// room left in the quad batch for the chrome drawn after the tiles
private const i32 EX_BATCH_RESERVE = 60000;

// Each tile draws its buffer where the active pane would, at the
// buffer's own scroll and caret, through the quad batch's scale; a tile
// too small to read, or one that would overrun the batch, draws the
// code's shape instead.
void explode_render() {
    // the whole window between the caption and the status bar: the
    // sidebar is set aside while the view is up
    i32 x0 = 0;
    i32 y1 = g_h - status_h();
    draw_rect(cast(f32, x0), 0.0f, cast(f32, g_w - x0), cast(f32, y1), T_SIDEBAR_BG);

    // the filter across the top
    i32 pad = ui_list_pad();
    i32 ih = ui_input_h();
    i32 fw = ui_list_panel_w(60);
    if fw > g_w - x0 - 2 * pad { fw = g_w - x0 - 2 * pad; }
    i32 fx = x0 + (g_w - x0 - fw) / 2;
    ui_input(fx, pad, fw, ex_field_at(), "type to filter; Enter opens, Esc returns", caret_on);
    i32 top = pad + ih + pad;
    if explode_count() == 0 {
        ignore font_draw_ui_text("no open editors match", cast(f32, fx), cast(f32, top + pad), cast(f32, g_w), T_DIM);
        return;
    }

    // the geometry a tile draws in: the active pane's, or the first
    // document pane's when a terminal is active
    i32 p = ed_tile_pane();
    i32 px0 = 0;
    i32 px1 = 0;
    i32 vtop = 0;
    i32 vbot = 0;
    if p >= 0 {
        ed_pane_rect(p, &px0, &px1);
        vtop = pane_doc_top(p);
        vbot = ed_pane_y1(p);
    }
    i32 vw = px1 - px0;
    i32 vh = vbot - vtop;
    if vw < 1 || vh < 1 {
        vw = g_w - x0;
        vh = y1;
    }
    i32 hh = ui_list_row_h();
    i32 gap = font_line_h;
    f32 s = explode_layout(x0 + gap, top, g_w - x0 - 2 * gap, y1 - top - gap, vw, vh, hh, gap);
    if s <= 0.0f { return; }   // no room for a tile

    for i32 i = 0; i < explode_count(); i++ {
        i32 b = explode_buf(i);
        i32 t = explode_term(i);
        i32 tx = 0;
        i32 ty = 0;
        i32 tw = 0;
        i32 th = 0;
        ignore explode_tile_rect(i, &tx, &ty, &tw, &th);
        bool sel = explode_is_sel(i);
        // the ring, then the header and the ground
        if sel {
            draw_rect(cast(f32, tx - 2), cast(f32, ty - 2), cast(f32, tw + 4), cast(f32, th + 4), T_FOCUS);
        } else {
            draw_rect(cast(f32, tx - 1), cast(f32, ty - 1), cast(f32, tw + 2), cast(f32, th + 2), T_WIDGET_BORDER);
        }
        draw_rect(cast(f32, tx), cast(f32, ty), cast(f32, tw), cast(f32, hh), T_HEADER_BG);
        draw_rect(cast(f32, tx), cast(f32, ty + hh), cast(f32, tw), cast(f32, th - hh), C_BG);
        u32 tcol = T_DIM;
        if sel || (b >= 0 && b == ed_buf_active()) || (t >= 0 && t == ed_term_active()) { tcol = T_FG; }
        f32 ny = cast(f32, ty + (hh - font_ui_h) / 2);
        f32 nx = cast(f32, tx + ui_inset());
        nx = font_draw_ui_text(explode_title(i), nx, ny, cast(f32, tx + tw - ui_inset()), tcol);
        if b >= 0 && ed_buf_dirty(b) { ignore font_draw_ui_text(" \xe2\x97\x8f", nx, ny, cast(f32, tx + tw - ui_inset()), tcol); }
        if p < 0 { continue; }

        // the buffer, scaled into the tile below the header
        f32 cx = cast(f32, tx);
        f32 cy = cast(f32, ty + hh);
        i32 est = (vh / font_line_h + 2) * (vw / font_cell_w + 2) * 6 + 4000;
        bool text = s >= EX_TEXT_MIN_SCALE && draw_nverts + est < DRAW_MAX_VERTS - EX_BATCH_RESERVE;
        if t >= 0 {
            ed_tile_begin_term(p, t);
        } else {
            ed_tile_begin(p, b);
        }
        draw_transform(s, cx - cast(f32, px0) * s, cy - cast(f32, vtop) * s);
        draw_clip(cx, cx + cast(f32, tw));
        draw_clip_y(cy, cast(f32, ty + th));
        if t >= 0 && text {
            term_render(p, px0, px1, false);
        } else if t >= 0 {
            view_term_shape(p, px0, px1);
        } else if text {
            doc_render(px0, px1, false);
        } else {
            view_tile_shape(px0, px1);
        }
        draw_transform_off();
        draw_clip_off();
        draw_clip_y_off();
        if t >= 0 {
            ed_tile_end_term(p);
        } else {
            ed_tile_end(p);
        }
    }
}

// The loaded buffer as the code's shape: each run of one token class a
// bar in its color, half a line tall, spaces left out. For a tile too
// small for its glyphs to read, and one quad a run instead of one a
// character.
private void view_tile_shape(i32 px0, i32 px1) {
    i32 lh = font_line_h;
    i32 cw = font_cell_w;
    i32 dt = doc_top();
    i32 bottom = g_h - chrome_bottom_h();
    i32 gut = px0 + gutter_w();
    // the shape is drawn line by line, unwrapped, from the top row's line
    i32 first = top_line;
    i32 shift = left_vcol;
    if ed_wrap_on() {
        first = ed_line_of_row(top_line);
        shift = 0;
    }
    i32 last = first + visible_lines() + 1;
    if last > tb.nlines - 1 { last = tb.nlines - 1; }
    if last < 0 { return; }
    if g_lex_on { lex_ensure(last); }
    f32 bar = cast(f32, lh) * 0.55f;
    for i32 l = first; l <= last; l++ {
        i32 y = dt + (l - first) * lh - scroll_off;
        if y >= bottom { break; }
        i32 n = line_bytes(l);
        if g_lex_on { ignore lex_row(g_linebuf, n, cast(i32, g_lexstate[l]), g_clsbuf); }
        f32 by = cast(f32, y) + (cast(f32, lh) - bar) / 2.0f;
        i32 v = 0;
        i32 i = 0;
        while i < n {
            u8 c = g_linebuf[i];
            if c == ' ' {
                v++;
                i++;
                continue;
            }
            if c == '\t' {
                v = (v / TABW + 1) * TABW;
                i++;
                continue;
            }
            u8 k = LEX_DEF;
            if g_lex_on { k = g_clsbuf[i]; }
            i32 v0 = v;
            while i < n && g_linebuf[i] != ' ' && g_linebuf[i] != '\t' {
                u8 k2 = LEX_DEF;
                if g_lex_on { k2 = g_clsbuf[i]; }
                if k2 != k { break; }
                // a continuation byte adds no column
                if (g_linebuf[i] & 0xC0) != 0x80 { v++; }
                i++;
            }
            if v > v0 {
                draw_rect(cast(f32, gut + (v0 - shift) * cw), by, cast(f32, (v - v0) * cw), bar, lex_color(k));
            }
        }
    }
}

// Terminal pane pi's screen as its shape: the ground, then each run of
// non-blank cells in one color a bar in that color, one quad a run.
private void view_term_shape(i32 pi, i32 px0, i32 px1) {
    i32 t = ed_pane_term(pi);
    if t < 0 { return; }
    i32 lh = font_line_h;
    i32 cw = font_cell_w;
    i32 dt = doc_top();
    i32 ox = px0 + TERM_PAD_PX;
    i32 bottom = g_h - chrome_bottom_h();
    u32 pbg = term_palette(TP_BG);
    draw_rect(cast(f32, px0), cast(f32, dt), cast(f32, px1 - px0), cast(f32, bottom - dt), pbg);
    f32 bar = cast(f32, lh) * 0.55f;
    i32 rows = term_rows(t);
    i32 cols = term_cols(t);
    for i32 r = 0; r < rows; r++ {
        i32 y = dt + r * lh;
        if y >= bottom { break; }
        f32 by = cast(f32, y) + (cast(f32, lh) - bar) / 2.0f;
        i32 c = 0;
        while c < cols {
            u32 cp = term_cell_cp(t, r, c);
            if cp <= 32 {
                c++;
                continue;
            }
            i32 attr = term_cell_attr(t, r, c);
            u32 fg = term_fg_of(term_cell_fg(t, r, c), term_cell_bg(t, r, c), attr);
            i32 c0 = c;
            while c < cols && term_cell_cp(t, r, c) > 32 {
                i32 a2 = term_cell_attr(t, r, c);
                if term_fg_of(term_cell_fg(t, r, c), term_cell_bg(t, r, c), a2) != fg { break; }
                c++;
            }
            draw_rect(cast(f32, ox + c0 * cw), by, cast(f32, (c - c0) * cw), bar, fg);
        }
    }
}

// codicon window controls (assets/codicon.ttf)
private const u32 ICO_DIFF_PREV = 0xEAB7;   // chevron-up
private const u32 ICO_DIFF_NEXT = 0xEAB4;   // chevron-down
private const u32 ICO_DIFF_REVERT = 0xEA9C; // arrow-right
private const u32 ICO_CHROME_CLOSE = 0xEAB8;
private const u32 ICO_CHROME_MAX = 0xEAB9;
private const u32 ICO_CHROME_MIN = 0xEABA;
private const u32 ICO_CHROME_RESTORE = 0xEABB;
private const u32 ICO_ERROR = 0xEA87;
private const u32 ICO_INFO = 0xEA74;
private const u32 ICO_WARNING = 0xEA6C;

// an icon glyph centred on its own ink in a box, the way a button holds one
private void draw_icon_centered(u32 cp, i32 x, i32 y, i32 w, i32 h, u32 col) {
    i32 gw = 0;
    i32 gh = 0;
    i32 gx = 0;
    i32 gy = 0;
    font_glyph_box(cp, &gw, &gh, &gx, &gy);
    font_draw(cp, cast(f32, x + (w - gw) / 2 - gx), cast(f32, y + (h - gh) / 2 - gy), col);
}

// --- the image viewer (image.mc) ----------------------------------------

private const f32 IMG_CHECK_OF_LINE = 0.6f;   // a checkerboard square, of a text line

// the two squares behind a transparent image, from the background's
// lightness so the board shows in a light theme and a dark one
private void img_checker_colors(u32* a, u32* b) {
    u32 c = C_BG;
    i32 lum = cast(i32, c & 0xFF) + cast(i32, (c >> 8) & 0xFF) + cast(i32, (c >> 16) & 0xFF);
    if lum > 3 * 128 {
        *a = 0xFFFFFFFF;
        *b = 0xFFD8D8D8;
    } else {
        *a = 0xFF3A3A3A;
        *b = 0xFF2A2A2A;
    }
}

// Image im in the pane x0, y0, x1, y1: fitted or at its zoom, a
// checkerboard behind a transparent one, or what is there instead while
// it loads or when it cannot be shown. In the explode view's tiles the
// transform is on and the tile's clips stay.
private void image_render(i32 im, i32 x0, i32 y0, i32 x1, i32 y1) {
    if x1 <= x0 || y1 <= y0 { return; }
    bool tile = draw_transformed();
    i32 st = image_state(im);
    if st != IMG_READY {
        noinit u8[320] mb;
        i32 mn = 0;
        str m = "loading";
        if st == IMG_FAILED {
            str a = "cannot show this image: ";
            str e = image_error(im);
            memcpy(&mb[0], a.data, a.len);
            mn = a.len;
            i32 en = e.len;
            if mn + en > 320 { en = 320 - mn; }
            memcpy(&mb[mn], e.data, en);
            mn += en;
            m = str_from(&mb[0], mn);
        }
        i32 tx = (x0 + x1 - font_ui_text_w(m)) / 2;
        if tx < x0 { tx = x0; }
        ignore font_draw_ui_text(m, cast(f32, tx), cast(f32, (y0 + y1 - font_ui_h) / 2), cast(f32, x1), T_DIM);
        return;
    }
    f32 s = image_scale(im, x1 - x0, y1 - y0);
    f32 ox = 0.0f;
    f32 oy = 0.0f;
    image_place(im, x0, y0, x1, y1, s, &ox, &oy);
    f32 w = cast(f32, image_w(im)) * s;
    f32 h = cast(f32, image_h(im)) * s;
    if !tile {
        draw_clip(cast(f32, x0), cast(f32, x1));
        draw_clip_y(cast(f32, y0), cast(f32, y1));
    }
    if image_alpha(im) {
        // the board over the part of the image inside the pane only
        u32 ca = 0;
        u32 cb = 0;
        img_checker_colors(&ca, &cb);
        f32 q = cast(f32, font_line_h) * IMG_CHECK_OF_LINE;
        if q < 4.0f { q = 4.0f; }
        f32 bx0 = ox;
        f32 by0 = oy;
        f32 bx1 = ox + w;
        f32 by1 = oy + h;
        if bx0 < cast(f32, x0) { bx0 = cast(f32, x0); }
        if by0 < cast(f32, y0) { by0 = cast(f32, y0); }
        if bx1 > cast(f32, x1) { bx1 = cast(f32, x1); }
        if by1 > cast(f32, y1) { by1 = cast(f32, y1); }
        draw_rect(bx0, by0, bx1 - bx0, by1 - by0, ca);
        // the squares counted from the image's corner, so they move with it
        i32 r0 = cast(i32, (by0 - oy) / q);
        i32 c0 = cast(i32, (bx0 - ox) / q);
        for i32 r = r0; oy + cast(f32, r) * q < by1; r++ {
            for i32 c = c0; ox + cast(f32, c) * q < bx1; c++ {
                if ((r + c) & 1) == 0 { continue; }
                f32 sx = ox + cast(f32, c) * q;
                f32 sy = oy + cast(f32, r) * q;
                f32 sx1 = sx + q;
                f32 sy1 = sy + q;
                if sx < bx0 { sx = bx0; }
                if sy < by0 { sy = by0; }
                if sx1 > bx1 { sx1 = bx1; }
                if sy1 > by1 { sy1 = by1; }
                if sx1 > sx && sy1 > sy { draw_rect(sx, sy, sx1 - sx, sy1 - sy, cb); }
            }
        }
    }
    draw_image(image_gpu(im), ox, oy, w, h, 0.0f, 0.0f, 1.0f, 1.0f, image_blocks(s), 0xFFFFFFFF);
    if !tile {
        draw_clip_y_off();
        draw_clip_off();
    }
}

// --- the call graph (calls.mc) ----------------------------------------

private const i32 CALLS_CURVE_STEPS = 24;   // segments per curve
private const i32 CALLS_LINE_MAX = 512;     // bytes of a code line drawn

// A vertical S from (x0, y0) to (x1, y1): a cubic with its tangents
// straight down at both ends, in short segments.
private void calls_curve(f32 x0, f32 y0, f32 x1, f32 y1, f32 w, u32 col) {
    f32 my = (y0 + y1) * 0.5f;
    f32 px = x0;
    f32 py = y0;
    for i32 i = 1; i <= CALLS_CURVE_STEPS; i++ {
        f32 t = cast(f32, i) / cast(f32, CALLS_CURVE_STEPS);
        f32 u = 1.0f - t;
        // control points (x0, my) and (x1, my)
        f32 x = u * u * u * x0 + 3.0f * u * u * t * x0 + 3.0f * u * t * t * x1 + t * t * t * x1;
        f32 y = u * u * u * y0 + 3.0f * u * u * t * my + 3.0f * u * t * t * my + t * t * t * y1;
        draw_segment(px, py, x, y, w, col);
        px = x;
        py = y;
    }
}

// the file part of a path
private str calls_base(str p) {
    i32 s = p.len;
    while s > 0 && p.data[s - 1] != '/' && p.data[s - 1] != 92 { s--; }
    return str_from(p.data + s, p.len - s);
}

// "file.mc:123"
private str calls_where(CallItem* it, u8* buf) {
    str b = calls_base(str_from(&it.path[0], it.path_len));
    i32 n = b.len;
    if n > 200 { n = 200; }
    memcpy(buf, b.data, n);
    buf[n] = ':';
    n++;
    n += fmt_i32(buf + n, it.sl0 + 1);
    return str_from(buf, n);
}

// The lines [first, first + n) of `path`, lexed first `state`, at scale s
// with their top-left at (x, y), clipped to the box x0..x1 by y0..y1.
// Line `hl` gets the caret line's band. Returns the lexer's state after
// the last line, for a column that continues them.
private i32 calls_draw_lines(str path, i32 first, i32 n, f32 x, f32 y, f32 s,
        f32 x0, f32 y0, f32 x1, f32 y1, i32 hl, i32 state) {
    f32 lh = cast(f32, font_line_h) * s;
    if hl >= first && hl < first + n {
        f32 by = y + cast(f32, hl - first) * lh;
        if by < y1 { draw_rect(x0, by, x1 - x0, lh, C_CURLINE); }
    }
    draw_clip(x0, x1);
    draw_clip_y(y0, y1);
    draw_transform(s, x, y);
    noinit u8[CALLS_LINE_MAX] cls;
    noinit u8[CALLS_LINE_MAX] exp;
    noinit u8[CALLS_LINE_MAX] ecls;
    for i32 k = 0; k < n; k++ {
        if y + cast(f32, k) * lh > y1 { break; }
        str ln = calls_file_line(path, first + k);
        i32 len = ln.len;
        if len > CALLS_LINE_MAX { len = CALLS_LINE_MAX; }
        state = lex_line(ln.data, len, state, &cls[0]);
        // tabs to spaces, the classes along
        i32 e = 0;
        i32 vc = 0;
        for i32 b = 0; b < len && e < CALLS_LINE_MAX; b++ {
            if ln.data[b] == 9 {
                i32 to = (vc / CALLS_TAB + 1) * CALLS_TAB;
                while vc < to && e < CALLS_LINE_MAX {
                    exp[e] = ' ';
                    ecls[e] = LEX_DEF;
                    e++;
                    vc++;
                }
            } else {
                exp[e] = ln.data[b];
                ecls[e] = cls[b];
                e++;
                if (ln.data[b] & 0xC0) != 0x80 { vc++; }
            }
        }
        // runs of one class in one color
        f32 gx = 0.0f;
        f32 gy = cast(f32, k * font_line_h);
        i32 a = 0;
        while a < e {
            i32 b = a + 1;
            while b < e && ecls[b] == ecls[a] { b++; }
            gx = font_draw_text(str_from(&exp[a], b - a), gx, gy, lex_color(ecls[a]));
            a = b;
        }
    }
    draw_transform_off();
    draw_clip_y_off();
    draw_clip_off();
    return state;
}

// a small card: its box, a line of text and, for a function, a snippet:
// a caller's lines around its first call, a callee's first lines
private void calls_card_draw(i32 i, bool sel) {
    i32 x = 0;
    i32 y = 0;
    i32 w = 0;
    i32 h = 0;
    calls_card_rect(i, &x, &y, &w, &h);
    u32 border = T_WIDGET_BORDER;
    if sel { border = T_FOCUS; }
    draw_rect(cast(f32, x - 1), cast(f32, y - 1), cast(f32, w + 2), cast(f32, h + 2), border);
    draw_rect(cast(f32, x), cast(f32, y), cast(f32, w), cast(f32, h), T_WIDGET_BG);
    i32 pad = ui_inset();
    f32 tx = cast(f32, x + pad);
    f32 mx = cast(f32, x + w - pad);
    i32 rh = ui_list_row_h();
    f32 y0 = cast(f32, y + pad / 2 + (rh - font_ui_h) / 2);
    f32 y1 = y0 + cast(f32, rh);
    i32 kind = calls_card_kind(i);
    i32 row = calls_card_row(i);
    noinit u8[256] wb;
    noinit u8[64] nb;
    if kind == CARD_FN {
        i32 idx = calls_card_idx(i);
        CallItem* it = calls_item(row, idx);
        // the name, then where it is and how often it is called, dim
        f32 nx = font_draw_ui_text(str_from(&it.name[0], it.name_len), tx, y0, mx, T_FG);
        f32 wx = font_draw_ui_text(calls_where(it, &wb[0]), nx + cast(f32, font_cell_w), y0, mx, T_DIM);
        i32 sites = calls_row_sites(row, idx);
        i32 n = fmt_i32(&nb[0], sites);
        str tail = " calls";
        if sites == 1 { tail = " call"; }
        memcpy(&nb[n], tail.data, tail.len);
        ignore font_draw_ui_text(str_from(&nb[0], n + tail.len), wx + cast(f32, font_cell_w), y0, mx, T_DIM);
        // the snippet, in the editor's colors
        i32 sy = y + pad + rh;
        i32 sh = h - (sy - y) - pad / 2;
        if sh <= 0 { return; }
        draw_rect(cast(f32, x + pad / 2), cast(f32, sy), cast(f32, w - pad), cast(f32, sh), C_BG);
        str path = str_from(&it.path[0], it.path_len);
        i32 first = it.l0;
        i32 hl = -1;
        if row == 0 && calls_row_site_line(row, idx) >= 0 {
            hl = calls_row_site_line(row, idx);
            first = hl - 1;
            if first < 0 { first = 0; }
        }
        // the indentation the snippet's lines share is left out
        f32 shift = cast(f32, calls_common_indent(path, first, CALLS_SNIP_LINES) * font_cell_w) * CALLS_SNIP_SCALE;
        ignore calls_draw_lines(path, first, CALLS_SNIP_LINES, cast(f32, x + pad) - shift, cast(f32, sy),
            CALLS_SNIP_SCALE, cast(f32, x + pad / 2), cast(f32, sy), cast(f32, x + w - pad / 2),
            cast(f32, sy + sh), hl, 0);
    } else if kind == CARD_GROUP {
        CallItem* it = calls_item(row, calls_card_idx(i));
        f32 nx = font_draw_ui_text(calls_base(str_from(&it.path[0], it.path_len)), tx, y0, mx, T_FG);
        i32 n = fmt_i32(&nb[0], calls_card_count_of(i));
        str tail = " functions";
        memcpy(&nb[n], tail.data, tail.len);
        ignore font_draw_ui_text(str_from(&nb[0], n + tail.len), nx + cast(f32, font_cell_w), y0, mx, T_DIM);
        ignore font_draw_ui_text("select to show file", tx, y1, mx, T_DIM);
    } else if kind == CARD_BACK {
        ignore font_draw_ui_text("all files", tx, y0, mx, T_FG);
        ignore font_draw_ui_text("select to show all files", tx, y1, mx, T_DIM);
    } else if kind == CARD_MORE || kind == CARD_PREV {
        i32 n = fmt_i32(&nb[0], calls_card_idx(i));
        str tail = " more";
        str hint = "select to show next";
        if kind == CARD_PREV {
            tail = " before";
            hint = "select to show previous";
        }
        memcpy(&nb[n], tail.data, tail.len);
        ignore font_draw_ui_text(str_from(&nb[0], n + tail.len), tx, y0, mx, T_FG);
        ignore font_draw_ui_text(hint, tx, y1, mx, T_DIM);
    }
}

// the indentation the lines [first, first + n) share, in cells; a blank
// line does not count
private i32 calls_common_indent(str path, i32 first, i32 n) {
    i32 least = -1;
    for i32 k = 0; k < n; k++ {
        str ln = calls_file_line(path, first + k);
        i32 vc = 0;
        i32 b = 0;
        while b < ln.len && (ln.data[b] == ' ' || ln.data[b] == 9) {
            if ln.data[b] == 9 { vc = (vc / CALLS_TAB + 1) * CALLS_TAB; } else { vc++; }
            b++;
        }
        if b == ln.len { continue; }
        if least < 0 || vc < least { least = vc; }
    }
    if least < 0 { least = 0; }
    return least;
}

// the visual column of a server column on a line: UTF-16 units unless
// the server agreed to bytes, tabs to the next stop
private i32 calls_vcol_of(str ln, i32 ch) {
    i32 vc = 0;
    i32 units = 0;
    i32 b = 0;
    while b < ln.len && units < ch {
        i32 at = b;
        u32 cp = utf8_next(ln.data, ln.len, &b);
        if ln.data[at] == 9 { vc = (vc / CALLS_TAB + 1) * CALLS_TAB; } else { vc++; }
        if lsp_pos_utf16 {
            units++;
            if cp >= 0x10000 { units++; }
        } else {
            units += b - at;
        }
    }
    return vc;
}

// The selection's color behind the center's calls to the callee (or
// the file of callees) the selection stands for. Lines
// [first, first + n) are in the column at (cx, cy0).
private void calls_center_marks(str path, i32 first, i32 n, i32 cx, i32 cy0, f32 s, i32 cx1, i32 cy1) {
    f32 sl = cast(f32, font_line_h) * s;
    f32 cw = cast(f32, font_cell_w) * s;
    draw_clip(cast(f32, cx), cast(f32, cx1));
    draw_clip_y(cast(f32, cy0), cast(f32, cy1));
    for i32 i = 0; i < calls_row_count(1); i++ {
        if !calls_callee_selected(i) { continue; }
        for i32 k = 0; k < calls_row_nsite(1, i); k++ {
            i32 line = 0;
            i32 c0 = 0;
            i32 c1 = 0;
            calls_row_site_at(1, i, k, &line, &c0, &c1);
            if line < first || line >= first + n { continue; }
            str ln = calls_file_line(path, line);
            i32 v0 = calls_vcol_of(ln, c0);
            i32 v1 = calls_vcol_of(ln, c1);
            if v1 <= v0 { v1 = v0 + 1; }
            f32 rx = cast(f32, cx) + cast(f32, v0) * cw;
            f32 ry = cast(f32, cy0) + cast(f32, line - first) * sl;
            f32 rw = cast(f32, v1 - v0) * cw;
            draw_rect(rx, ry, rw, sl, C_SEL);
        }
    }
    draw_clip_y_off();
    draw_clip_off();
}

// the center: a header with the name and where it is, then the
// function's lines at full size, in one or two columns, the lines that
// did not fit counted last (calls_center_fit)
private void calls_center_draw(i32 i, bool sel) {
    i32 x = 0;
    i32 y = 0;
    i32 w = 0;
    i32 h = 0;
    calls_card_rect(i, &x, &y, &w, &h);
    u32 border = T_WIDGET_BORDER;
    if sel { border = T_FOCUS; }
    draw_rect(cast(f32, x - 1), cast(f32, y - 1), cast(f32, w + 2), cast(f32, h + 2), border);
    draw_rect(cast(f32, x), cast(f32, y), cast(f32, w), cast(f32, h), C_BG);
    i32 pad = ui_inset();
    i32 rh = ui_list_row_h();
    draw_rect(cast(f32, x), cast(f32, y), cast(f32, w), cast(f32, rh), T_HEADER_BG);
    CallItem* c = calls_center_item();
    f32 hy = cast(f32, y + (rh - font_ui_h) / 2);
    f32 hx = font_draw_ui_text(str_from(&c.name[0], c.name_len), cast(f32, x + pad), hy, cast(f32, x + w - pad), T_FG);
    noinit u8[256] wb;
    ignore font_draw_ui_text(calls_where(c, &wb[0]), hx + cast(f32, 2 * font_cell_w), hy, cast(f32, x + w - pad), T_DIM);

    str path = str_from(&c.path[0], c.path_len);
    i32 cols = calls_center_cols();
    i32 per = calls_center_per();
    i32 more = calls_center_more();
    f32 s = calls_center_scale();
    f32 sl = cast(f32, font_line_h) * s;
    i32 cy0 = y + rh + pad;
    i32 cy1 = y + h - pad;
    // each column is as wide as the card's inner width shared out
    i32 colgap = 2 * font_cell_w;
    i32 colw = (w - 2 * pad - (cols - 1) * colgap) / cols;
    // A cut function shows its first lines, or, while a callee is
    // selected whose first call is further down, the lines around that
    // call: the call a third of the way down.
    i32 total = per * cols + more;
    i32 vis = per * cols;
    i32 off = 0;
    if more > 0 {
        i32 at = -1;
        for i32 i = 0; i < calls_row_count(1); i++ {
            if !calls_callee_selected(i) { continue; }
            for i32 k = 0; k < calls_row_nsite(1, i); k++ {
                i32 line = 0;
                i32 c0 = 0;
                i32 c1 = 0;
                calls_row_site_at(1, i, k, &line, &c0, &c1);
                if line >= c.l0 && (at < 0 || line < at) { at = line; }
            }
        }
        if at >= c.l0 + vis {
            off = at - c.l0 - per / 3;
            if off > total - vis { off = total - vis; }
            if off < 0 { off = 0; }
        }
    }
    i32 state = 0;
    i32 shown = 0;
    for i32 k = 0; k < cols; k++ {
        i32 n = per;
        if shown + n > vis { n = vis - shown; }
        if n <= 0 { break; }
        i32 cx = x + pad + k * (colw + colgap);
        i32 first = c.l0 + off + shown;
        calls_center_marks(path, first, n, cx, cy0, s, cx + colw, cy1);
        state = calls_draw_lines(path, first, n, cast(f32, cx), cast(f32, cy0), s,
            cast(f32, cx), cast(f32, cy0), cast(f32, cx + colw), cast(f32, cy1), -1, state);
        shown += n;
        if k + 1 < cols {
            f32 rx = cast(f32, cx + colw + colgap / 2);
            draw_rect(rx, cast(f32, cy0), 1.0f, cast(f32, per) * sl, T_DIVIDER);
        }
    }
    if more > 0 {
        // "12 more lines", or "lines 9-17 of 21" when the window moved
        noinit u8[96] mb;
        i32 mn = 0;
        if off == 0 {
            mn = fmt_i32(&mb[0], more);
            str t0 = " more lines";
            memcpy(&mb[mn], t0.data, t0.len);
            mn += t0.len;
        } else {
            str t1 = "lines ";
            memcpy(&mb[0], t1.data, t1.len);
            mn = t1.len;
            mn += fmt_i32(&mb[mn], off + 1);
            mb[mn] = '-';
            mn++;
            mn += fmt_i32(&mb[mn], off + vis);
            str t2 = " of ";
            memcpy(&mb[mn], t2.data, t2.len);
            mn += t2.len;
            mn += fmt_i32(&mb[mn], total);
        }
        str tail = "; select to open the function";
        memcpy(&mb[mn], tail.data, tail.len);
        f32 my = cast(f32, cy0) + cast(f32, per) * sl + (sl - cast(f32, font_ui_h)) * 0.5f;
        ignore font_draw_ui_text(str_from(&mb[0], mn + tail.len), cast(f32, x + pad), my, cast(f32, x + w - pad), T_DIM);
    }
}

// a row that is empty, or still coming, says so in its band
private void calls_row_note(i32 row) {
    if calls_row_count(row) > 0 { return; }
    i32 x0 = 0;
    i32 y = 0;
    i32 w = 0;
    i32 ch = 0;
    calls_band(row, &x0, &y, &w, &ch);
    str m = "no callers";
    if row == 1 { m = "no calls"; }
    if calls_row_loading(row) { m = "asking the language server..."; }
    if calls_row_indexing(row) { m = "the language server is still indexing; Ctrl+Shift+M again in a moment"; }
    // centered, or from the left edge when it is wider than the band
    i32 tx = x0 + (w - font_ui_text_w(m)) / 2;
    if tx < x0 { tx = x0; }
    ignore font_draw_ui_text(m, cast(f32, tx), cast(f32, y + (ch - font_ui_h) / 2), cast(f32, x0 + w), T_DIM);
}

void calls_render() {
    i32 y1 = g_h - status_h();
    draw_rect(0.0f, 0.0f, cast(f32, g_w), cast(f32, y1), T_SIDEBAR_BG);
    i32 phase = calls_phase_now();
    if phase != CALLS_READY {
        str m = "finding the function at the caret...";
        if phase == CALLS_NONE { m = "no function at the caret"; }
        if phase == CALLS_INDEXING { m = "the language server is still indexing; Ctrl+Shift+M again in a moment"; }
        if phase == CALLS_NO_SERVER { m = "the call graph needs a language server with call hierarchy: update minc"; }
        i32 tx = (g_w - font_ui_text_w(m)) / 2;
        if tx < 0 { tx = 0; }
        ignore font_draw_ui_text(m, cast(f32, tx), cast(f32, y1 / 2), cast(f32, g_w), T_DIM);
        return;
    }
    calls_relayout();

    // the curves first, under the cards; the selected card's on top
    i32 cx = 0;
    i32 cy = 0;
    i32 cw = 0;
    i32 chh = 0;
    calls_card_rect(0, &cx, &cy, &cw, &chh);
    i32 nc = calls_card_count();
    i32[2] nrow;
    for i32 i = 1; i < nc; i++ {
        i32 r = calls_card_row(i);
        nrow[r] = nrow[r] + 1;
    }
    i32[2] at;
    u32 lc = T_DIM;
    for i32 pass = 0; pass < 2; pass++ {
        at[0] = 0;
        at[1] = 0;
        for i32 i = 1; i < nc; i++ {
            i32 r = calls_card_row(i);
            i32 k = at[r];
            at[r]++;
            bool sel = i == calls_selected();
            if (pass == 1) != sel { continue; }
            i32 x = 0;
            i32 y = 0;
            i32 w2 = 0;
            i32 h2 = 0;
            calls_card_rect(i, &x, &y, &w2, &h2);
            // each card meets its own point along the center's edge
            f32 ex = cast(f32, cx) + cast(f32, cw) * cast(f32, k + 1) / cast(f32, nrow[r] + 1);
            f32 wd = 1.5f;
            u32 col = lc;
            if sel {
                wd = 2.5f;
                col = T_FOCUS;
            }
            if r == 0 {
                calls_curve(cast(f32, x + w2 / 2), cast(f32, y + h2), ex, cast(f32, cy), wd, col);
            } else {
                calls_curve(ex, cast(f32, cy + chh), cast(f32, x + w2 / 2), cast(f32, y), wd, col);
            }
        }
    }
    calls_center_draw(0, calls_selected() == 0);
    for i32 i = 1; i < nc; i++ { calls_card_draw(i, i == calls_selected()); }
    calls_row_note(0);
    calls_row_note(1);
}

// the notice box: the kind's icon and the message, bottom right above
// the status bar, in the reference's notification look
// the input box (ed.mc "the input box"): the title, the input, and the
// last message in the warning color
private void ask_render() {
    if !ask_on { return; }
    i32 x = 0;
    i32 y = 0;
    i32 w = 0;
    i32 h = 0;
    ask_box(&x, &y, &w, &h);
    i32 pad = ui_list_pad();
    i32 rh = ui_list_row_h();
    ui_panel(x, y, w, h);
    f32 tx = cast(f32, x + pad + 2 + ui_inset());
    f32 max_x = cast(f32, x + w - pad - ui_inset());
    i32 ty = y + pad;
    ignore font_draw_ui_text(ask_label(), tx, cast(f32, ty + (rh - font_ui_h) / 2), max_x, T_FG);
    ui_input(x + pad, ty + rh, w - 2 * pad, ask_field(), ask_hint(), caret_on);
    str m = ask_message();
    if m.len > 0 {
        i32 my = ty + rh + ui_input_h();
        ignore font_draw_ui_text(m, tx, cast(f32, my + (rh - font_ui_h) / 2), max_x, T_DIAG_WARN);
    }
}

private void notice_render() {
    if !notice_on { return; }
    i32 x0 = 0;
    i32 y0 = 0;
    i32 x1 = 0;
    i32 y1 = 0;
    ed_notice_rect(&x0, &y0, &x1, &y1);
    f32 fx = cast(f32, x0);
    f32 fy = cast(f32, y0);
    f32 fw = cast(f32, x1 - x0);
    f32 fh = cast(f32, y1 - y0);
    draw_rect(fx - 1.0f, fy - 1.0f, fw + 2.0f, fh + 2.0f, T_WIDGET_BORDER);
    draw_rect(fx, fy, fw, fh, T_WIDGET_BG);
    i32 pad = font_ui_h / 2;
    if notice_kind == NOTICE_INFO {
        draw_icon_centered(ICO_INFO, x0 + pad, y0, font_ui_h, y1 - y0, T_DIAG_INFO);
    } else if notice_kind == NOTICE_WARN {
        draw_icon_centered(ICO_WARNING, x0 + pad, y0, font_ui_h, y1 - y0, T_DIAG_WARN);
    } else {
        draw_icon_centered(ICO_ERROR, x0 + pad, y0, font_ui_h, y1 - y0, T_DIAG_ERROR);
    }
    // the width is rounded; a bound at the text's own width would drop
    // the last glyph
    ignore font_draw_ui_text(str_from(&notice_msg[0], notice_len),
        cast(f32, x0 + 2 * pad + font_ui_h), cast(f32, y0 + pad), cast(f32, x1 - pad) + 2.0f, T_FG);
}

// The self-drawn caption (Windows). Drawn into y in [-g_caption_h, 0);
// the gpu backend shifts all output down by the caption height, so
// the rest of the frame keeps its 0-origin coordinate space.
private void caption_render() {
    if g_caption_h <= 0 { return; }
    i32 chh = g_caption_h;
    i32 cw = font_cell_w;
    f32 cy = 0.0f - cast(f32, chh);
    // the logo glyph is font_ascent tall (font_icon_edmc), so center it
    // in the band by that, not by the full line height
    f32 ly = cy + cast(f32, (chh - font_ascent) / 2);
    draw_rect(0.0f, cy, cast(f32, g_w), cast(f32, chh), T_TITLEBAR);
    font_draw(ICON_EDMC, cast(f32, cw), ly, T_BRAND);

    // centered title in the UI face, kept clear of the buttons
    i32 bw = caption_btn_w();
    str title = str_from(&g_title[0], g_title_len);
    f32 tty = cy + cast(f32, (chh - font_ui_h) / 2);
    f32 left = cast(f32, 3 * bw + 2 * cw);
    f32 right = cast(f32, g_w - 3 * bw - 2 * cw);
    f32 tx = cast(f32, (g_w - font_ui_text_w(title)) / 2);
    if tx < left { tx = left; }
    ignore font_draw_ui_text(title, tx, tty, right, T_TITLEBAR_FG);

    u32 mid = ICO_CHROME_MAX;
    if g_win_zoomed { mid = ICO_CHROME_RESTORE; }
    u32[3] btns = { ICO_CHROME_MIN, mid, ICO_CHROME_CLOSE };
    for i32 b = 0; b < 3; b++ {
        i32 bx0 = g_w - (3 - b) * bw;
        // the reference's looks: a tenth of white under the pointer, a
        // fifth while held; the close button goes red, its glyph white
        u32 fg = T_TITLEBAR_FG;
        if g_caption_press == b && g_caption_hover == b {
            u32 bg = theme_alpha(T_TITLEBAR_FG, 0x33);
            if b == 2 {
                bg = 0xFF7A70F1;   // #F1707A
                fg = 0xFFFFFFFF;
            }
            draw_rect(cast(f32, bx0), cy, cast(f32, bw), cast(f32, chh), bg);
        } else if g_caption_hover == b && g_caption_press < 0 {
            u32 bg = theme_alpha(T_TITLEBAR_FG, 0x1A);
            if b == 2 {
                bg = 0xFF2311E8;   // #E81123
                fg = 0xFFFFFFFF;
            }
            draw_rect(cast(f32, bx0), cy, cast(f32, bw), cast(f32, chh), bg);
        }
        // the icon at the caption's own size, centered in its button
        u32 icp = btns[b] | FONT_CAPTION;
        draw_icon_centered(icp, bx0, cast(i32, cy), bw, chh, fg);
    }
}

// Wavy underline across [x0, x1).
// The reference's squiggle: its 6 by 3 css-px zigzag tile, rasterized
// once per dpi as a shape glyph (font.mc, SHAPE_SQUIGGLE), repeated
// from the range's start along it at the bottom of the line box and
// clipped to the range, the way its tiled background is. The clip is
// kept inside the pane, whose own clip is put back after.
// A frame's squiggle tiles are budgeted: a diagnostic spanning a whole
// file puts one on every visible line, a 4K pane is 600 tiles wide, and
// the quad batch is not, so past the budget a span is a plain underline.
private const i32 SQUIGGLE_TILE_BUDGET = 20000;
private i32 squiggle_tiles = 0;

private void draw_squiggle(i32 px0, i32 px1, i32 x0, i32 x1, i32 line_top, u32 col) {
    u32 cp = FONT_SHAPE | SHAPE_SQUIGGLE;
    i32 gw = 0;
    i32 gh = 0;
    i32 gx = 0;
    i32 gy = 0;
    font_glyph_box(cp, &gw, &gh, &gx, &gy);
    if gw <= 0 { return; }
    i32 c0 = x0;
    i32 c1 = x1;
    if c0 < px0 { c0 = px0; }
    if c1 > px1 { c1 = px1; }
    if c1 <= c0 { return; }
    f32 y = cast(f32, line_top + font_line_h - gh);
    i32 tiles = (c1 - c0) / gw + 2;
    if squiggle_tiles + tiles > SQUIGGLE_TILE_BUDGET {
        draw_rect(cast(f32, c0), cast(f32, line_top + font_line_h - 1), cast(f32, c1 - c0), 1.0f, col);
        return;
    }
    squiggle_tiles += tiles;
    draw_clip(cast(f32, c0), cast(f32, c1));
    for i32 x = x0; x < c1; x += gw {
        if x + gw <= c0 { continue; }
        font_draw(cp, cast(f32, x), y, col);
    }
    draw_clip(cast(f32, px0), cast(f32, px1));
}

// A cell's glyph: a cluster shaped to one glyph where the platform can
// (a text-presentation cluster, VS15, keeps the base's own glyph), else
// the codepoint. Bold is the glyph drawn twice one pixel apart and
// italic the glyph sheared, since the atlas has one face: the reference
// has both weights, and a terminal with neither reads flat.
private void term_glyph(i32 t, i32 r, i32 c, u32 cp, i32 x, i32 y, u32 fg, i32 attr) {
    noinit u8[64] cb;
    i32 cn = term_cell_cluster(t, r, c, &cb[0]);
    if cn > 0 {
        bool text = cn >= 3 && cb[cn - 3] == 0xEF && cb[cn - 2] == 0xB8 && cb[cn - 1] == 0x8E;   // ends in VS15
        if !text {
            u32 gid = plat_shape_cluster(&cb[0], cn);
            if gid != 0 {
                font_draw(FONT_GLYPHID | gid, cast(f32, x), cast(f32, y), fg);
                return;
            }
        }
    }
    bool bold = (attr & cast(i32, TA_BOLD)) != 0;
    bool italic = (attr & cast(i32, TA_ITALIC)) != 0;
    if italic {
        font_draw_italic(cp, cast(f32, x), cast(f32, y), fg);
        if bold { font_draw_italic(cp, cast(f32, x + 1), cast(f32, y), fg); }
        return;
    }
    font_draw(cp, cast(f32, x), cast(f32, y), fg);
    if bold { font_draw(cp, cast(f32, x + 1), cast(f32, y), fg); }
}

// c over ground by a in 256ths: the shaded blocks
private u32 term_mix(u32 c, u32 ground, i32 a) {
    u32 r = ((c & 0xFF) * cast(u32, a) + (ground & 0xFF) * cast(u32, 256 - a)) / 256;
    u32 g = (((c >> 8) & 0xFF) * cast(u32, a) + ((ground >> 8) & 0xFF) * cast(u32, 256 - a)) / 256;
    u32 b = (((c >> 16) & 0xFF) * cast(u32, a) + ((ground >> 16) & 0xFF) * cast(u32, 256 - a)) / 256;
    return 0xFF000000 | r | (g << 8) | (b << 16);
}

// the arms of a box-drawing cell: up 1, down 2, left 4, right 8
private const i32 BOX_UP = 1;
private const i32 BOX_DOWN = 2;
private const i32 BOX_LEFT = 4;
private const i32 BOX_RIGHT = 8;

private void term_box_arms(i32 x, i32 y, i32 w, i32 h, i32 arms, i32 t, u32 col) {
    i32 cx = x + w / 2;
    i32 cy = y + h / 2;
    i32 half = t / 2;
    if (arms & BOX_UP) != 0 { draw_rect(cast(f32, cx - half), cast(f32, y), cast(f32, t), cast(f32, cy + t - half - y), col); }
    if (arms & BOX_DOWN) != 0 { draw_rect(cast(f32, cx - half), cast(f32, cy - half), cast(f32, t), cast(f32, y + h - (cy - half)), col); }
    if (arms & BOX_LEFT) != 0 { draw_rect(cast(f32, x), cast(f32, cy - half), cast(f32, cx + t - half - x), cast(f32, t), col); }
    if (arms & BOX_RIGHT) != 0 { draw_rect(cast(f32, cx - half), cast(f32, cy - half), cast(f32, x + w - (cx - half)), cast(f32, t), col); }
}

// A rounded corner: the vertical arm from the cell's edge to where the
// arc begins, the horizontal one the same, and the arc as t-sized dots
// on a quarter circle of radius r about the corner's inner point.
private void term_box_round(i32 x, i32 y, i32 w, i32 h, i32 dirs, i32 t, u32 col) {
    i32 cx = x + w / 2;
    i32 cy = y + h / 2;
    i32 half = t / 2;
    i32 r = w / 2;
    if h / 2 < r { r = h / 2; }
    if r < 2 { term_box_arms(x, y, w, h, dirs, t, col); return; }
    // the arc's centre: inside the corner, r away from both arms
    i32 ax = cx + r;
    if (dirs & BOX_LEFT) != 0 { ax = cx - r; }
    i32 ay = cy + r;
    if (dirs & BOX_UP) != 0 { ay = cy - r; }
    // the arms, stopped where the arc takes over
    if (dirs & BOX_DOWN) != 0 { draw_rect(cast(f32, cx - half), cast(f32, ay), cast(f32, t), cast(f32, y + h - ay), col); }
    if (dirs & BOX_UP) != 0 { draw_rect(cast(f32, cx - half), cast(f32, y), cast(f32, t), cast(f32, ay - y), col); }
    if (dirs & BOX_RIGHT) != 0 { draw_rect(cast(f32, ax), cast(f32, cy - half), cast(f32, x + w - ax), cast(f32, t), col); }
    if (dirs & BOX_LEFT) != 0 { draw_rect(cast(f32, x), cast(f32, cy - half), cast(f32, ax - x), cast(f32, t), col); }
    // the arc: for each step along one axis, the point on the circle
    f64 fr = cast(f64, r);
    for i32 i = 0; i <= r; i++ {
        f64 fi = cast(f64, i);
        f64 fj = sqrt(fr * fr - fi * fi);
        i32 j = cast(i32, fj + 0.5);
        i32 sx = -1;
        if (dirs & BOX_LEFT) != 0 { sx = 1; }
        i32 sy = -1;
        if (dirs & BOX_UP) != 0 { sy = 1; }
        // both orderings of (i, j) so the arc has no holes
        draw_rect(cast(f32, ax + sx * i - half), cast(f32, ay + sy * j - half), cast(f32, t), cast(f32, t), col);
        draw_rect(cast(f32, ax + sx * j - half), cast(f32, ay + sy * i - half), cast(f32, t), cast(f32, t), col);
    }
}

// Box drawing (U+2500 to U+257F) and block elements (U+2580 to U+259F)
// as geometry filling the cell, the way every terminal draws them: a
// font's glyphs leave gaps between cells and rows, and a logo or a
// frame made of these is meant to join. Mixed light-and-heavy joints
// and the double-line joints are drawn as their light or heavy shape;
// the diagonals stay with the font. True when the cell was drawn.
private bool term_box(u32 cp, i32 x, i32 y, i32 w, i32 h, u32 fg, u32 bg) {
    if cp < 0x2500 || cp > 0x259F { return false; }
    i32 light = h / 16;
    if light < 1 { light = 1; }
    i32 heavy = light * 2;
    if cp >= 0x2580 {
        i32 k = cast(i32, cp - 0x2580);
        if k == 0 { draw_rect(cast(f32, x), cast(f32, y), cast(f32, w), cast(f32, h / 2), fg); return true; }
        if k >= 1 && k <= 8 {
            i32 bh = h * k / 8;
            draw_rect(cast(f32, x), cast(f32, y + h - bh), cast(f32, w), cast(f32, bh), fg);
            return true;
        }
        if k >= 9 && k <= 15 {
            i32 bw = w * (16 - k) / 8;
            draw_rect(cast(f32, x), cast(f32, y), cast(f32, bw), cast(f32, h), fg);
            return true;
        }
        if k == 16 { draw_rect(cast(f32, x + w / 2), cast(f32, y), cast(f32, w - w / 2), cast(f32, h), fg); return true; }
        if k >= 17 && k <= 19 {
            i32 a = 64;
            if k == 18 { a = 128; }
            if k == 19 { a = 192; }
            draw_rect(cast(f32, x), cast(f32, y), cast(f32, w), cast(f32, h), term_mix(fg, bg, a));
            return true;
        }
        if k == 20 { draw_rect(cast(f32, x), cast(f32, y), cast(f32, w), cast(f32, h / 8 > 0 ? h / 8 : 1), fg); return true; }
        if k == 21 { draw_rect(cast(f32, x + w - (w / 8 > 0 ? w / 8 : 1)), cast(f32, y), cast(f32, w / 8 > 0 ? w / 8 : 1), cast(f32, h), fg); return true; }
        // the quadrants: bits upper-left 1, upper-right 2, lower-left 4, lower-right 8
        i32[10] quads = { 4, 8, 1, 13, 9, 7, 11, 2, 6, 14 };
        i32 q = quads[k - 22];
        i32 hw = w / 2;
        i32 hh = h / 2;
        if (q & 1) != 0 { draw_rect(cast(f32, x), cast(f32, y), cast(f32, hw), cast(f32, hh), fg); }
        if (q & 2) != 0 { draw_rect(cast(f32, x + hw), cast(f32, y), cast(f32, w - hw), cast(f32, hh), fg); }
        if (q & 4) != 0 { draw_rect(cast(f32, x), cast(f32, y + hh), cast(f32, hw), cast(f32, h - hh), fg); }
        if (q & 8) != 0 { draw_rect(cast(f32, x + hw), cast(f32, y + hh), cast(f32, w - hw), cast(f32, h - hh), fg); }
        return true;
    }
    i32 c = cast(i32, cp - 0x2500);
    i32 arms = 0;
    i32 t = light;
    if c <= 11 || (c >= 0x4C && c <= 0x4F) {
        // the lines: bit 1 vertical, bit 0 heavy; 4 to 7 triple dashed,
        // 8 to 11 quadruple, 4C to 4F double
        i32 v = c;
        if c >= 0x4C { v = c - 0x4C; }
        if (v & 1) != 0 { t = heavy; }
        i32 dashes = 0;
        if c >= 4 && c <= 7 { dashes = 3; }
        if c >= 8 && c <= 11 { dashes = 4; }
        if c >= 0x4C { dashes = 2; }
        if dashes == 0 {
            if (v & 2) == 0 { arms = BOX_LEFT | BOX_RIGHT; } else { arms = BOX_UP | BOX_DOWN; }
        } else {
            // dash and gap near equal, the way the fonts cut them (a
            // two-to-one cut read as nearly solid), the run of dashes
            // filling the cell so the pattern continues into the next;
            // each end rounded to the pixel, a gap never under one
            i32 cx = x + w / 2;
            i32 cy = y + h / 2;
            i32 half = t / 2;
            i32 len = w;
            if (v & 2) != 0 { len = h; }
            f64 period = cast(f64, len) / cast(f64, dashes);
            for i32 k = 0; k < dashes; k++ {
                i32 a = cast(i32, period * cast(f64, k) + 0.5);
                i32 b = cast(i32, period * (cast(f64, k) + 0.55) + 0.5);
                i32 next = cast(i32, period * cast(f64, k + 1) + 0.5);
                if b >= next { b = next - 1; }
                if b <= a { b = a + 1; }
                if (v & 2) == 0 {
                    draw_rect(cast(f32, x + a), cast(f32, cy - half), cast(f32, b - a), cast(f32, t), fg);
                } else {
                    draw_rect(cast(f32, cx - half), cast(f32, y + a), cast(f32, t), cast(f32, b - a), fg);
                }
            }
            return true;
        }
    } else if c >= 0x0C && c <= 0x1B {
        // the four corners, four weights each
        i32 g = (c - 0x0C) / 4;
        i32 v = (c - 0x0C) % 4;
        if g == 0 { arms = BOX_DOWN | BOX_RIGHT; }
        if g == 1 { arms = BOX_DOWN | BOX_LEFT; }
        if g == 2 { arms = BOX_UP | BOX_RIGHT; }
        if g == 3 { arms = BOX_UP | BOX_LEFT; }
        if v == 3 { t = heavy; }
    } else if c >= 0x1C && c <= 0x3B {
        // the four tees, eight weights each
        i32 g = (c - 0x1C) / 8;
        i32 v = (c - 0x1C) % 8;
        if g == 0 { arms = BOX_UP | BOX_DOWN | BOX_RIGHT; }
        if g == 1 { arms = BOX_UP | BOX_DOWN | BOX_LEFT; }
        if g == 2 { arms = BOX_DOWN | BOX_LEFT | BOX_RIGHT; }
        if g == 3 { arms = BOX_UP | BOX_LEFT | BOX_RIGHT; }
        if v == 7 { t = heavy; }
    } else if c >= 0x3C && c <= 0x4B {
        arms = BOX_UP | BOX_DOWN | BOX_LEFT | BOX_RIGHT;
        if c == 0x4B { t = heavy; }
    } else if c == 0x50 { arms = BOX_LEFT | BOX_RIGHT; t = heavy;
    } else if c == 0x51 { arms = BOX_UP | BOX_DOWN; t = heavy;
    } else if c >= 0x52 && c <= 0x6C {
        // the double-line joints, as heavy single lines
        i32[27] dj = {
            BOX_DOWN | BOX_RIGHT, BOX_DOWN | BOX_RIGHT, BOX_DOWN | BOX_RIGHT,
            BOX_DOWN | BOX_LEFT, BOX_DOWN | BOX_LEFT, BOX_DOWN | BOX_LEFT,
            BOX_UP | BOX_RIGHT, BOX_UP | BOX_RIGHT, BOX_UP | BOX_RIGHT,
            BOX_UP | BOX_LEFT, BOX_UP | BOX_LEFT, BOX_UP | BOX_LEFT,
            BOX_UP | BOX_DOWN | BOX_RIGHT, BOX_UP | BOX_DOWN | BOX_RIGHT, BOX_UP | BOX_DOWN | BOX_RIGHT,
            BOX_UP | BOX_DOWN | BOX_LEFT, BOX_UP | BOX_DOWN | BOX_LEFT, BOX_UP | BOX_DOWN | BOX_LEFT,
            BOX_DOWN | BOX_LEFT | BOX_RIGHT, BOX_DOWN | BOX_LEFT | BOX_RIGHT, BOX_DOWN | BOX_LEFT | BOX_RIGHT,
            BOX_UP | BOX_LEFT | BOX_RIGHT, BOX_UP | BOX_LEFT | BOX_RIGHT, BOX_UP | BOX_LEFT | BOX_RIGHT,
            15, 15, 15 };
        arms = dj[c - 0x52];
        t = heavy;
    } else if c >= 0x6D && c <= 0x70 {
        // the rounded corners: two arms shortened by the radius, and a
        // quarter arc between them
        i32 dirs = 0;
        if c == 0x6D { dirs = BOX_DOWN | BOX_RIGHT; }
        if c == 0x6E { dirs = BOX_DOWN | BOX_LEFT; }
        if c == 0x6F { dirs = BOX_UP | BOX_LEFT; }
        if c == 0x70 { dirs = BOX_UP | BOX_RIGHT; }
        term_box_round(x, y, w, h, dirs, light, fg);
        return true;
    } else if c >= 0x74 && c <= 0x7F {
        // the half lines: left, up, right, down; light, heavy, then mixed
        i32 v = (c - 0x74) % 4;
        if v == 0 { arms = BOX_LEFT; }
        if v == 1 { arms = BOX_UP; }
        if v == 2 { arms = BOX_RIGHT; }
        if v == 3 { arms = BOX_DOWN; }
        if c >= 0x78 && c <= 0x7B { t = heavy; }
    } else {
        return false;   // the diagonals
    }
    term_box_arms(x, y, w, h, arms, t, fg);
    return true;
}

// A cell's colors: the child's, or the palette's text and background
// where it named none (TERM_DEFAULT is alpha zero, which no palette
// entry produces). Bold is the palette's bold color on default text
// and the bright entry on an ANSI one, since the atlas has one weight;
// dim is the foreground halfway to the background; inverse swaps.
private u32 term_fg_of(u32 fg, u32 bg, i32 attr) {
    u32 f = fg;
    u32 b = bg;
    bool bold = (attr & cast(i32, TA_BOLD)) != 0;
    if f == TERM_DEFAULT {
        f = term_palette(TP_FG);
        if bold { f = term_palette(TP_BOLD); }
    }
    if b == TERM_DEFAULT { b = term_palette(TP_BG); }
    if (attr & cast(i32, TA_INVERSE)) != 0 { return b; }
    if bold {
        for i32 i = 0; i < 8; i++ {
            if f == term_palette(TP_ANSI + i) { f = term_palette(TP_ANSI + i + 8); break; }
        }
    }
    if (attr & cast(i32, TA_DIM)) != 0 { f = term_mix(f, b, 128); }
    return f;
}

private u32 term_bg_of(u32 fg, u32 bg, i32 attr) {
    u32 f = fg;
    u32 b = bg;
    if f == TERM_DEFAULT { f = term_palette(TP_FG); }
    if b == TERM_DEFAULT { b = term_palette(TP_BG); }
    if (attr & cast(i32, TA_INVERSE)) != 0 { return f; }
    return b;
}

// A terminal pane: the grid at cell positions, a background rect where
// a cell's is not the editor's own, underline and strike as rects, the
// cursor as a block, bar or underline in the active pane. No blink:
// the editor's caret timer stays the editor's, and a cursor that
// blinked would wake the idle editor while a prompt sits there.
private void term_render(i32 pi, i32 px0, i32 px1, bool active) {
    i32 t = ed_pane_term(pi);
    i32 lh = font_line_h;
    i32 cw = font_cell_w;
    i32 dt = doc_top();
    i32 ox = px0 + TERM_PAD_PX;
    i32 rows = term_rows(t);
    i32 cols = term_cols(t);
    i32 bottom = g_h - chrome_bottom_h();
    // the pane's ground is the palette's background, not the editor's
    // (a rect in C_BG would draw nothing, and need not)
    u32 pbg = term_palette(TP_BG);
    if pbg != C_BG {
        draw_rect(cast(f32, px0), cast(f32, dt), cast(f32, px1 - px0), cast(f32, bottom - dt), pbg);
    }
    i64 sl0 = 0;
    i64 sl1 = 0;
    i32 sc0 = 0;
    i32 sc1 = 0;
    bool sel = ed_term_sel_get(t, &sl0, &sc0, &sl1, &sc1);
    i64 abs_top = term_abs_top(t);
    for i32 r = 0; r < rows; r++ {
        i32 y = dt + r * lh;
        if y >= bottom { break; }
        // the selected columns of this row, both ends included
        i32 rs0 = 0;
        i32 rs1 = -1;
        if sel {
            i64 abs = abs_top + cast(i64, r);
            if abs >= sl0 && abs <= sl1 {
                rs1 = cols - 1;
                if abs == sl0 { rs0 = sc0; }
                if abs == sl1 { rs1 = sc1; }
            }
        }
        for i32 c = 0; c < cols; c++ {
            i32 x = ox + c * cw;
            if x >= px1 { break; }
            i32 attr = term_cell_attr(t, r, c);
            if (attr & cast(i32, TA_TAIL)) != 0 { continue; }
            u32 cfg = term_cell_fg(t, r, c);
            u32 cbg = term_cell_bg(t, r, c);
            u32 bg = term_bg_of(cfg, cbg, attr);
            if c >= rs0 && c <= rs1 { bg = term_palette(TP_SEL); }
            i32 w = 1;
            if (attr & cast(i32, TA_WIDE)) != 0 { w = 2; }
            if bg != pbg {
                draw_rect(cast(f32, x), cast(f32, y), cast(f32, cw * w), cast(f32, lh), bg);
            }
            u32 cp = term_cell_cp(t, r, c);
            if (attr & cast(i32, TA_HIDDEN)) != 0 { continue; }
            u32 fg = term_fg_of(cfg, cbg, attr);
            if cp > 32 && !term_box(cp, x, y, cw * w, lh, fg, bg) {
                term_glyph(t, r, c, cp, x, y, fg, attr);
            }
            if (attr & cast(i32, TA_UNDER)) != 0 {
                draw_rect(cast(f32, x), cast(f32, y + font_ascent + 1), cast(f32, cw * w), 1.0f, fg);
            }
            if (attr & cast(i32, TA_STRIKE)) != 0 {
                draw_rect(cast(f32, x), cast(f32, y + font_ascent * 2 / 3), cast(f32, cw * w), 1.0f, fg);
            }
        }
    }

    // the cursor: only in the active pane, only while the child shows
    // it and the view is live; the shape is the child's
    if active && g_focused && term_cursor_vis(t) && !overlay_active() {
        i32 cx = ox + term_cx(t) * cw;
        i32 cy = dt + term_cy(t) * lh;
        if cy < bottom && cx < px1 {
            i32 shape = term_cursor_shape(t);
            u32 ccol = term_palette(TP_CURSOR);
            if shape == TERM_CUR_BAR {
                draw_rect(cast(f32, cx), cast(f32, cy), CARET_W, cast(f32, lh), ccol);
            } else if shape == TERM_CUR_UNDER {
                draw_rect(cast(f32, cx), cast(f32, cy + lh - 2), cast(f32, cw), 2.0f, ccol);
            } else {
                // a block: the cell's glyph in the background color over it
                draw_rect(cast(f32, cx), cast(f32, cy), cast(f32, cw), cast(f32, lh), ccol);
                u32 ucp = term_cell_cp(t, term_cy(t), term_cx(t));
                if ucp > 32 { font_draw(ucp, cast(f32, cx), cast(f32, cy), pbg); }
            }
        }
    }

    // the scrollbar: the view's place in the history, when there is one
    i32 hist = term_scrollback(t);
    if hist > 0 {
        i32 track = bottom - dt;
        i32 total = hist + rows;
        i32 th = track * rows / total;
        if th < SCROLL_MIN_THUMB { th = SCROLL_MIN_THUMB; }
        if th > track { th = track; }
        i32 off = hist - term_view(t);   // lines above the view's top
        i32 ty = dt + (track - th) * off / hist;
        draw_rect_rounded(cast(f32, px1 - SCROLL_W - SCROLL_PAD), cast(f32, ty),
            cast(f32, SCROLL_W), cast(f32, th), SCROLL_W / 2, C_SCROLL);
    }

    // the banner, as a document pane's: the shell's title, else its
    // exit; brighter when active
    i32 btop = ed_pane_top();   // the banner's top: 0, or the bottom pane's edge
    if dt > btop {
        draw_rect(cast(f32, px0), cast(f32, btop), cast(f32, px1 - px0), cast(f32, dt - btop), T_HEADER_BG);
        draw_rect(cast(f32, px0), cast(f32, dt - 1), cast(f32, px1 - px0), 1.0f, T_HEADER_BORDER);
        u32 bcol = C_LINENO;
        if active { bcol = C_FG; }
        f32 bx = cast(f32, px0) + STATUS_MARGIN;
        f32 by = cast(f32, btop + (dt - btop - font_ui_h) / 2);
        bx = font_draw_ui_text(term_label(t), bx, by, cast(f32, px1), bcol);
        if t == build_term() && build_header().len > 0 {
            // the build pane: the run's state and its counts
            bx = font_draw_ui_text("  ", bx, by, cast(f32, px1), C_LINENO);
            ignore font_draw_ui_text(build_header(), bx, by, cast(f32, px1), C_LINENO);
        } else if term_exited(t) {
            noinit u8[32] eb;
            i32 en = 0;
            str pre = "  exited ";
            memcpy(&eb[0], pre.data, pre.len);
            en = pre.len;
            en += fmt_i32(&eb[en], term_code(t));
            ignore font_draw_ui_text(str_from(&eb[0], en), bx, by, cast(f32, px1), C_LINENO);
        }
    }
}

// one pane's document: text, gutter, selection, caret, scrollbar
// into [px0, px1). The caller has swapped this pane's state into the
// globals; the caret and find marks draw only in the active pane.
private void doc_render(i32 px0, i32 px1, bool active) {
    if g_img >= 0 {
        image_render(g_img, px0, doc_top(), px1, g_h - chrome_bottom_h());
        return;
    }
    i32 lh = font_line_h;
    i32 cw = font_cell_w;
    i32 sh = chrome_bottom_h();   // the document ends above the panel too
    i32 dt = doc_top();           // ...and below the pane's file banner
    // +2: a partial line can peek in at both edges when scroll_off > 0
    i32 vis = visible_lines() + 2;
    i32 digits = gutter_digits();
    i32 x0 = px0;
    i32 gut = x0 + gutter_w();
    i32 nx0 = x0 + ed_diff_margin_w();   // the numbers' column, past a diff's arrows
    i32 cols = (px1 - px0 - gutter_w()) / cw;
    if cols < 1 { cols = 1; }
    cols += 2;

    // the caret's line is banded, every row of it when it wraps
    bool wrap = ed_wrap_on();
    i32 curr = ed_row_of_line(cur_line);
    i32 curn = 1;
    if wrap { curn = wrap_line(cur_line); }
    for i32 ck = 0; active && ck < curn; ck++ {
        i32 cr = curr + ck;
        if cr >= top_line && cr < top_line + vis {
            draw_rect(cast(f32, x0), cast(f32, dt + (cr - top_line) * lh - scroll_off), cast(f32, px1 - x0), cast(f32, lh), C_CURLINE);
        }
    }

    // top_line is a row, which is a line unless a diff is open
    i32 rlast = top_line + vis - 1;
    if rlast > ed_row_count() - 1 { rlast = ed_row_count() - 1; }
    i32 last = ed_line_of_row(rlast);
    i32 rl = rlast;
    while last < 0 && rl > top_line {
        rl--;
        last = ed_line_of_row(rl);
    }
    if last > tb.nlines - 1 { last = tb.nlines - 1; }
    if g_lex_on && last >= 0 { lex_ensure(last); }

    i32 ncur = ed_cur_count();

    noinit u8[16] numbuf;
    for i32 rr = top_line; rr <= rlast; rr++ {
        i32 l = ed_line_of_row(rr);
        i32 y = dt + (rr - top_line) * lh - scroll_off;
        if y >= g_h - sh { break; }
        if ed_diff_here() {
            // the row's own band: what changed here, and on which side.
            // A row with no line on this side is a hole against what the
            // other side has, drawn as nothing rather than left blank,
            // so the two columns read as one picture.
            i32 dk = git_row_kind(rr);
            u32 bg = 0;
            if l < 0 {
                bg = T_DIFF_FILL;
            } else if dk == GIT_ADD || (dk == GIT_MOD && !ed_diff_base_side()) {
                bg = T_DIFF_ADD;
            } else if dk == GIT_DEL || (dk == GIT_MOD && ed_diff_base_side()) {
                bg = T_DIFF_DEL;
            }
            if bg != 0 {
                draw_rect(cast(f32, x0), cast(f32, y), cast(f32, px1 - x0), cast(f32, lh), bg);
            }
            if l < 0 {
                // Ruled, not merely empty: this side has no line here at
                // all, which a blank band would read as a blank line.
                // The tile's side is the line height and its lines are
                // continuous across its edges, so a run of these rows
                // reads as one ruled field rather than a stack of rows.
                u32 hcp = FONT_SHAPE | SHAPE_HATCH;
                i32 hw = 0;
                i32 hh = 0;
                i32 hgx = 0;
                i32 hgy = 0;
                font_glyph_box(hcp, &hw, &hh, &hgx, &hgy);
                if hw > 0 {
                    i32 hx = x0;
                    while hx < px1 {
                        font_draw(hcp, cast(f32, hx), cast(f32, y), T_DIFF_HATCH);
                        hx += hw;
                    }
                }
            }
            if ed_diff_margin_w() > 0 && ed_diff_revert_row(rr) {
                // the block's revert arrow, lit under the pointer the
                // way the banner's arrows are
                i32 rw = ed_diff_margin_w();
                u32 rfg = C_LINENO;
                if ed_diff_revert_hover() == rr {
                    draw_rect(cast(f32, x0), cast(f32, y), cast(f32, rw), cast(f32, lh),
                        theme_alpha(C_FG, 0x1A));
                    rfg = C_FG;
                }
                draw_icon_centered(ICO_DIFF_REVERT, x0, y, rw, lh, rfg);
            }
        }
        if l < 0 { continue; }

        // The part of line l this row shows: row k of it from byte b0,
        // its columns [vlo, vhi), and lv, the column at the text's left
        // edge. Without wrap a row is the whole line, scrolled sideways.
        i32 k = 0;
        i32 b0 = 0;
        i32 lv = left_vcol;
        i32 vlo = left_vcol;
        i32 vhi = left_vcol + cols;
        bool lastrow = true;
        if wrap {
            i32 rows = wrap_line(l);
            k = rr - ed_row_of_line(l);
            b0 = wrap_row_start(k);
            vlo = wrap_row_v0(k);
            lv = vlo - wrap_row_lead(k);
            vhi = lv + cols;
            lastrow = k + 1 >= rows;
            if !lastrow && wrap_row_v0(k + 1) < vhi { vhi = wrap_row_v0(k + 1); }
        }
        i32 b1 = LINEBUF_CAP;
        if wrap && !lastrow { b1 = wrap_row_start(k + 1); }

        // every cursor's selection, not only the primary's
        for i32 ci = 0; ci < ncur; ci++ {
            i64 cc = 0;
            i64 sel_a = 0;
            i64 sel_b = 0;
            ed_cur_get(ci, &cc, &sel_a, &sel_b);
            if sel_b == sel_a { continue; }
            i64 ls = tb_line_start(l);
            i64 le = tb_line_end(l);
            if sel_b > ls && sel_a <= le {
                i64 s = sel_a;
                if s < ls { s = ls; }
                i64 e = sel_b;
                if e > le { e = le; }
                i32 v0 = vcol_of_col(l, s - ls);
                i32 v1 = vcol_of_col(l, e - ls);
                if sel_b > le && lastrow { v1++; }  // the selected newline
                if v0 < vlo { v0 = vlo; }
                if v1 > vhi { v1 = vhi; }
                if v1 > v0 {
                    draw_rect(cast(f32, gut + (v0 - lv) * cw), cast(f32, y),
                        cast(f32, (v1 - v0) * cw), cast(f32, lh), C_SEL);
                }
            }
        }

        if find_on && active {
            noinit i32[FIND_LINE_MARKS] fm;
            i32 flen = line_bytes(l);
            i32 nm = find_marks(g_linebuf, flen, &fm[0], FIND_LINE_MARKS);
            for i32 m = 0; m < nm; m++ {
                i32 v0 = vcol_of_col(l, fm[m]);
                i32 v1 = vcol_of_col(l, fm[m] + find_qlen());
                if v0 < vlo { v0 = vlo; }
                if v1 > vhi { v1 = vhi; }
                if v1 > v0 {
                    draw_rect(cast(f32, gut + (v0 - lv) * cw), cast(f32, y),
                        cast(f32, (v1 - v0) * cw), cast(f32, lh), C_FINDMARK);
                }
            }
        }

        // the bracket a typed closer matched: its glyph in the accent
        // (below), on a cell in the text color at first
        i64 brace_col = -1;
        bool brace_fill = false;
        if active && ed_brace_mark(l, &brace_col, &brace_fill) {
            i32 v0 = vcol_of_col(l, brace_col);
            i32 v1 = vcol_of_col(l, brace_col + 1);
            if v0 < vlo || v1 > vhi || v1 <= v0 {
                brace_col = -1;
            } else if brace_fill {
                draw_rect(cast(f32, gut + (v0 - lv) * cw), cast(f32, y),
                    cast(f32, (v1 - v0) * cw), cast(f32, lh), C_FG);
            }
        }

        // gutter mark for a line carrying a diagnostic, in the cell
        // the line numbers leave free on the left
        i32 dl = -1;
        if k == 0 { dl = ed_diag_on_line(l); }
        if dl >= 0 {
            LspDiag* dg = ed_diag(dl);
            if dg != null {
                i32 m = cw / 2;
                if m < 3 { m = 3; }
                draw_rect_rounded(cast(f32, nx0 + (cw - m) / 2),
                    cast(f32, y + (lh - m) / 2), cast(f32, m), cast(f32, m),
                    m / 2, theme_diag_color(dg.severity));
            }
        }

        // the change bar, between the line number and the text, where
        // the reference puts it. A deletion has no line of its own, so
        // it is the reference's triangle on the boundary, pointing
        // into the text from where the bars stand, rather than a bar.
        i32 gm = git_mark(l);
        if gm != GIT_NONE {
            i32 bw = cw / 3;
            if bw < 2 { bw = 2; }
            f32 bx = cast(f32, gut - bw - cw / 2);
            if gm == GIT_DEL && k > 0 {
                // the triangle marks the line's top edge, on its first row
            } else if gm == GIT_DEL {
                u32 wedge = FONT_SHAPE | SHAPE_WEDGE;
                i32 gw = 0;
                i32 gh = 0;
                i32 gx = 0;
                i32 gy = 0;
                font_glyph_box(wedge, &gw, &gh, &gx, &gy);
                if gh > 0 { font_draw(wedge, bx, cast(f32, y - gh / 2), T_GIT_DEL); }
            } else {
                u32 gc = T_GIT_ADD;
                if gm == GIT_MOD { gc = T_GIT_MOD; }
                draw_rect(bx, cast(f32, y), cast(f32, bw), cast(f32, lh), gc);
            }
        }

        // the number on a line's first row only
        if k == 0 {
            i32 nd = fmt_i32(&numbuf[0], l + 1);
            u32 ncol = C_LINENO;
            if l == cur_line { ncol = C_LINENO_CUR; }
            f32 nx = cast(f32, nx0 + (digits + 1 - nd) * cw);
            ignore font_draw_text(str_from(&numbuf[0], nd), nx, cast(f32, y), ncol);
        }

        i32 n = line_bytes(l);
        if g_lex_on {
            i32 st = cast(i32, g_lexstate[l]);
            ignore lex_row(g_linebuf, n, st, g_clsbuf);
            // the server's tokens refine the lexer where they cover
            if sem_is_for(ed_path()) { sem_overlay(l, g_clsbuf, n); }
        }
        bool link = active && hover_link_on && hover_link_ok && l == hover_link_line;
        if link {
            i32 lv0 = vcol_of_col(l, hover_link_c0);
            i32 lv1 = vcol_of_col(l, hover_link_c1);
            if lv0 < vlo { lv0 = vlo; }
            if lv1 > vhi { lv1 = vhi; }
            if lv1 > lv0 {
                draw_rect(cast(f32, gut + (lv0 - lv) * cw), cast(f32, y + font_ascent + 2),
                    cast(f32, (lv1 - lv0) * cw), 2.0f, C_LINK);
            }
        }
        i32 v = 0;
        i32 i = 0;
        if wrap {
            v = vlo;
            i = b0;
        }
        if b1 > n { b1 = n; }
        while i < b1 {
            u8 c = g_linebuf[i];
            if c == '\t' {
                v = (v / TABW + 1) * TABW;
                i++;
                continue;
            }
            u8 kc = LEX_DEF;
            if g_lex_on { kc = g_clsbuf[i]; }
            u32 col = lex_color(kc);
            if link && i >= hover_link_c0 && i < hover_link_c1 { col = C_LINK; }
            if cast(i64, i) == brace_col { col = T_MATCH; }
            i32 st = i;
            i32 w = grapheme_next_w(g_linebuf, n, &i);   // i steps past the cluster
            if v >= vlo && v < vhi {
                f32 gx = cast(f32, gut + (v - lv) * cw);
                i32 fp = st;
                u32 cp = utf8_next(g_linebuf, n, &fp);
                if i > fp {
                    // a multi-codepoint emoji cluster: shape it to one glyph
                    // where the platform can, else draw the base codepoint
                    u32 gid = plat_shape_cluster(g_linebuf + st, i - st);
                    if gid != 0 { font_draw(FONT_GLYPHID | gid, gx, cast(f32, y), col); }
                    else { font_draw(cp, gx, cast(f32, y), col); }
                } else {
                    font_draw(cp, gx, cast(f32, y), col);
                }
            }
            v += w;
            if v >= vhi { break; }
        }

        // squiggles last, so they sit over descenders rather than
        // under them
        i32 ndg = ed_diag_count();
        if !g_squiggles { ndg = 0; }
        i32 drawn = 0;
        for i32 di = 0; di < ndg && drawn < DIAG_MARKS_PER_LINE; di++ {
            LspDiag* dg = ed_diag(di);
            if dg == null || l < dg.line || l > dg.line1 { continue; }
            i32 dn = line_bytes(l);
            i32 dc0 = 0;
            i32 dc1 = 0;
            ed_diag_span(dg, l, dn, &dc0, &dc1);
            i32 dv0 = vcol_of_col(l, dc0);
            i32 dv1 = vcol_of_col(l, dc1);
            if dc1 > dn { dv1 = dv0 + 1; }   // past the end: one cell
            if dv0 < vlo { dv0 = vlo; }
            if dv1 > vhi { dv1 = vhi; }
            if dv1 <= dv0 { continue; }
            draw_squiggle(px0, px1, gut + (dv0 - lv) * cw,
                gut + (dv1 - lv) * cw, y,
                theme_diag_color(dg.severity));
            drawn++;
        }
    }

    // the document caret hides while an overlay input owns typing; the
    // extra cursors blink with it, so the set reads as one caret
    if active && caret_on && g_focused && !overlay_active() && !tree_focus && !search_focus {
        for i32 ci = 0; ci < ncur; ci++ {
            i64 cc = 0;
            i64 ca = 0;
            i64 cb = 0;
            ed_cur_get(ci, &cc, &ca, &cb);
            i32 cl = tb_line_of(cc);
            i64 ccol = cc - tb_line_start(cl);
            i32 crow = ed_row_of_pos(cl, ccol);
            if crow < top_line || crow >= top_line + vis { continue; }
            i32 clv = ed_row_left_vcol(cl, crow - ed_row_of_line(cl));
            i32 cv = vcol_of_col(cl, ccol);
            if cv < clv { continue; }
            f32 cx = cast(f32, gut + (cv - clv) * cw);
            draw_rect(cx, cast(f32, dt + (crow - top_line) * lh - scroll_off), CARET_W, cast(f32, lh), C_CARET);
        }
    }

    // The overview ruler: the same marks over the whole file rather
    // than the visible part, in the scrollbar column, with the thumb
    // drawn over them. The reference shows both this and the gutter by
    // default (scm.diffDecorations = all).
    i32 track = g_h - sh - dt;
    i32 marks = git_mark_count();
    if git_on() && track > 0 && marks > 0 {
        i32 ow = SCROLL_W;
        f32 ox = cast(f32, px1 - ow - SCROLL_PAD);
        // Scaled by the line count the marks were built for, not the
        // buffer's: a recompute can lag an edit, so between an edit and
        // the next one the marks can outnumber the lines. A run of
        // consecutive lines with one mark is one quad, both of its
        // edges on the same continuous mapping of lines to rows, so
        // neighboring runs tile with no gap and no double cover; an
        // integer height per line left gaps wherever the ratio was not
        // whole. A single line still shows two rows. At most one quad
        // per row, so a file that alternates marks on every line stays
        // bounded.
        f32 scale = cast(f32, track) / cast(f32, marks);
        i32 l = 0;
        i32 drawn = 0;
        while l < marks && drawn < track {
            i32 m = git_mark(l);
            if m == GIT_NONE {
                l++;
                continue;
            }
            i32 e = l + 1;
            while e < marks && git_mark(e) == m { e++; }
            f32 y0 = cast(f32, dt) + cast(f32, l) * scale;
            f32 y1 = cast(f32, dt) + cast(f32, e) * scale;
            if y1 - y0 < 2.0f { y1 = y0 + 2.0f; }
            if y1 > cast(f32, dt + track) { y1 = cast(f32, dt + track); }
            u32 mc = T_GIT_ADD;
            if m == GIT_MOD { mc = T_GIT_MOD; }
            if m == GIT_DEL { mc = T_GIT_DEL; }
            if y1 > y0 { draw_rect(ox, y0, cast(f32, ow), y1 - y0, mc); }
            drawn++;
            l = e;
        }
    }
    // the thumb counts what the view scrolls through: rows in a diff's
    // pane, where fillers stand opposite the other side's lines, and
    // lines anywhere else
    i32 nrows = ed_row_count();
    if nrows > visible_lines() && track > 0 {
        i32 th = track * visible_lines() / nrows;
        if th < SCROLL_MIN_THUMB { th = SCROLL_MIN_THUMB; }
        if th > track { th = track; }
        i32 maxs = (nrows - 1) * lh;
        i32 ty = dt;
        if maxs > 0 { ty = dt + cast(i32, cast(i64, track - th) * (top_line * lh + scroll_off) / maxs); }
        if ty > dt + track - th { ty = dt + track - th; }
        draw_rect_rounded(cast(f32, px1 - SCROLL_W - SCROLL_PAD), cast(f32, ty), cast(f32, SCROLL_W), cast(f32, th), SCROLL_W / 2, C_SCROLL);
    }

    // the pane's file banner, painted last so the top partial line does
    // not bleed into it. Left-aligned name in the UI face, dirty starred;
    // the active pane's name is brighter.
    i32 btop = ed_pane_top();   // the banner's top: 0, or the bottom pane's edge
    if dt > btop {
        draw_rect(cast(f32, px0), cast(f32, btop), cast(f32, px1 - px0), cast(f32, dt - btop), T_HEADER_BG);
        draw_rect(cast(f32, px0), cast(f32, dt - 1), cast(f32, px1 - px0), 1.0f, T_HEADER_BORDER);
        u32 bcol = C_LINENO;
        if active { bcol = C_FG; }
        f32 bx = cast(f32, px0) + STATUS_MARGIN;
        f32 by = cast(f32, btop + (dt - btop - font_ui_h) / 2);
        if ed_diff_on() && ed_diff_base_side() {
            // that side is a document with no path of its own
            bx = font_draw_ui_text(ed_diff_name(), bx, by, cast(f32, px1), bcol);
            // a commit's diff names its revision in the label itself
            if !ed_diff_rev() { ignore font_draw_ui_text(" at HEAD", bx, by, cast(f32, px1), C_LINENO); }
        } else {
            if tb.dirty { bx = font_draw_ui_text("*", bx, by, cast(f32, px1), bcol); }
            ignore font_draw_ui_text(ed_buf_title(ed_buf_active()), bx, by, cast(f32, px1), bcol);
            if ed_diff_here() {
                // walking the changes, for a hand on the mouse. Centred
                // on the glyph's own ink and lit under the pointer, the
                // way the caption's buttons are.
                u32[2] acp = { ICO_DIFF_PREV, ICO_DIFF_NEXT };
                i32 aw = ed_diff_arrow_w();
                for i32 ai = 0; ai < 2; ai++ {
                    i32 ax = ed_diff_arrow_x(ai);
                    u32 afg = C_LINENO;
                    if ed_diff_arrow_hover() == ai {
                        draw_rect(cast(f32, ax), 0.0f, cast(f32, aw), cast(f32, dt - 1),
                            theme_alpha(C_FG, 0x1A));
                        afg = C_FG;
                    }
                    draw_icon_centered(acp[ai], ax, 0, aw, dt, afg);
                }
            }
        }
    }
}

// The hover popup: a floating panel anchored under the word, flipped
// above it when there is no room below, and clamped into the window on
// both axes. Lines are the reply's own, clipped to what fits. It is
// set in the editor's face, as the reference sets a hover over editor
// text: what it describes is code, and it sits on the code.
private const i32 HOVER_MAX_LINES = 12;

// a fenced line of the panel: the editor's lexer classes it from a
// fresh state and the editor's colors draw it, so a signature in the
// panel reads as it does in the text
private void hover_draw_code(str s, f32 x, f32 y) {
    i32 n = s.len;
    if n > LINEBUF_CAP { n = LINEBUF_CAP; }
    ignore lex_row(s.data, n, 0, g_clsbuf);
    i32 i = 0;
    while i < n {
        i32 b = i;
        u32 cp = utf8_next(s.data, n, &i);
        font_draw(cp, x, y, lex_color(g_clsbuf[b]));
        x += cast(f32, font_cell_w);
    }
}

// cells a line of the panel takes in the mono face
private i32 hover_cells(str s) {
    i32 cells = 0;
    i32 i = 0;
    while i < s.len {
        ignore utf8_next(s.data, s.len, &i);
        cells++;
    }
    return cells;
}

// Signature help: one line above the call being typed, starting at the
// caret and running right, so it sits where the argument is going. The
// argument being typed is drawn bright against the rest.
private void sig_render() {
    if !sig_on || sig_len == 0 { return; }
    i32 lh = font_line_h;
    i32 cw = font_cell_w;
    i32 pad = lh / 3;
    str all = str_from(&sig_text[0], sig_len);
    i32 pw = hover_cells(all) * cw + 2 * pad;
    i32 max_w = g_w - 2 * cw;
    if pw > max_w { pw = max_w; }
    i32 ph = lh + 2 * pad;

    i32 px = sig_x;
    if px + pw > g_w - cw { px = g_w - cw - pw; }
    if px < cw { px = cw; }
    // above the line, and below it only when there is no room above
    i32 py = sig_y - ph - lh / 4;
    if py < 0 { py = sig_y + lh + lh / 4; }

    ui_panel(px, py, pw, ph);
    draw_clip(cast(f32, px + pad), cast(f32, px + pw - pad));
    f32 ty = cast(f32, py + pad);
    i32 p0 = sig_p0;
    i32 p1 = sig_p1;
    if p0 > sig_len { p0 = sig_len; }
    if p1 > sig_len { p1 = sig_len; }
    if p1 > p0 {
        f32 x = cast(f32, px + pad);
        x = font_draw_text(str_from(&sig_text[0], p0), x, ty, T_DIM);
        x = font_draw_text(str_from(&sig_text[p0], p1 - p0), x, ty, T_FG);
        ignore font_draw_text(str_from(&sig_text[p1], sig_len - p1), x, ty, T_DIM);
    } else {
        ignore font_draw_text(all, cast(f32, px + pad), ty, T_FG);
    }
    draw_clip_off();
}

private void hover_render() {
    if !hover_pop_on || hover_pop_len == 0 { return; }
    i32 lh = font_line_h;
    i32 cw = font_cell_w;
    i32 pad = lh / 3;
    i32 row = lh;

    // Lines that fit above the status bar. Flipping the panel above the
    // word only moves the overflow to the top edge, so the count has to
    // be bounded by the window, not just by taste.
    i32 room = g_h - chrome_bottom_h() - 2 * pad - lh;
    i32 maxl = 1;
    if row > 0 && room > 0 { maxl = room / row; }
    if maxl > HOVER_MAX_LINES { maxl = HOVER_MAX_LINES; }
    if maxl < 1 { maxl = 1; }

    // measure: the widest line, and how many there are
    i32 nlines = 0;
    i32 widest = 0;
    i32 at = 0;
    while at < hover_pop_len && nlines < maxl {
        i32 e = at;
        while e < hover_pop_len && hover_pop_text[e] != '\n' { e++; }
        i32 w = hover_cells(str_from(&hover_pop_text[at], e - at)) * cw;
        if w > widest { widest = w; }
        nlines++;
        at = e + 1;
    }
    if nlines == 0 { return; }

    i32 pw = widest + 2 * pad;
    i32 max_w = g_w - 2 * cw;
    if pw > max_w { pw = max_w; }
    if pw < 4 * cw { pw = 4 * cw; }
    i32 ph = nlines * row + 2 * pad;

    i32 px = hover_pop_x;
    if px + pw > g_w - cw { px = g_w - cw - pw; }
    if px < cw { px = cw; }
    // below the word, or above it when the bottom is too close, then
    // clamped into the window either way
    i32 bottom = g_h - chrome_bottom_h();
    i32 py = hover_pop_y + lh + lh / 4;
    // signature help sits above the line so it never covers the call
    // being typed below it; a plain hover flips up only when crowded
    if hover_sig || py + ph > bottom {
        py = hover_pop_y - ph - lh / 4;
    }
    if !hover_sig && py + ph > bottom { py = bottom - ph; }
    if py < 0 { py = 0; }

    ui_panel(px, py, pw, ph);
    i32 ty = py + pad;
    at = 0;
    i32 drawn = 0;
    draw_clip(cast(f32, px + pad), cast(f32, px + pw - pad));
    while at < hover_pop_len && drawn < nlines {
        i32 e = at;
        while e < hover_pop_len && hover_pop_text[e] != '\n' { e++; }
        str hl = str_from(&hover_pop_text[at], e - at);
        if drawn < HOVER_LINES_MAX && hover_pop_code[drawn] != 0 {
            hover_draw_code(hl, cast(f32, px + pad), cast(f32, ty));
        } else {
            ignore font_draw_text(hl, cast(f32, px + pad), cast(f32, ty), T_FG);
        }
        ty += row;
        drawn++;
        at = e + 1;
    }
    draw_clip_off();
}

void app_render() {
    ed_drag_scroll_frame();
    draw_begin();
    i32 cw = font_cell_w;
    i32 sh = status_h();
    // terminal grids follow the geometry of this frame
    ed_term_fit();
    squiggle_tiles = 0;

    // the explode view takes the editor area in the window with the keys
    bool exploded = (explode_on || calls_on) && ed_overlay_here();
    i32 np = ed_pane_count();
    if exploded { np = 0; }
    ed_glide_frame();
    for i32 pi = 0; pi < np; pi++ {
        i32 px0 = 0;
        i32 px1 = 0;
        ed_pane_rect(pi, &px0, &px1);
        ed_pane_swap_view(pi);
        // clip at the pane edges: the +2 column slack means edge
        // glyphs render partially, cut mid-glyph like the reference
        draw_clip(cast(f32, px0), cast(f32, px1));
        if ed_pane_kind(pi) == PANE_TERM {
            term_render(pi, px0, px1, pi == ed_pane_active());
        } else {
            ed_view_refit();   // a width that changed wraps into other rows
            ed_glide_begin(pi);
            doc_render(px0, px1, pi == ed_pane_active());
            ed_glide_end();
        }
        draw_clip_off();
        if pane_is_bottom(pi) {
            draw_rect(cast(f32, px0), cast(f32, ed_pane_y0(pi)), cast(f32, px1 - px0), 1.0f, T_DIVIDER);
        } else if pi > 0 {
            draw_rect(cast(f32, px0), 0.0f, 1.0f, cast(f32, ed_pane_y1(pi)), T_DIVIDER);
        }
    }
    if exploded && explode_on { explode_render(); }
    if exploded && calls_on { calls_render(); }
    ed_pane_swap_view(ed_pane_active());

    if exploded {
        // the explode view has the whole width
    } else if search_on {
        search_render();
    } else {
        tree_render();
    }
    // the status bar; the toggle (Ctrl+K S) makes status_h 0, so sh
    // gates the whole band
    if sh > 0 {
    draw_rect(0.0f, cast(f32, g_h - sh), cast(f32, g_w), cast(f32, sh), C_STATUS);
    f32 sy = cast(f32, g_h - sh + (sh - font_ui_h) / 2);
    f32 sx = STATUS_MARGIN;
    f32 smax = cast(f32, g_w);
    if ed_diag_on_line(cur_line) >= 0 {
        // the caret's diagnostic, until hover has somewhere better to
        // put it. The status bar is the one place already reserved for
        // a transient line about the current state.
        i32 di = ed_diag_on_line(cur_line);
        sx = font_draw_ui_text(ed_diag_msg(di), sx, sy,
            cast(f32, g_w - STATUS_RESERVE * cw), C_STATUS_FG);
    } else if g_has_path {
        // keep the tail when the path outgrows the space left of
        // the Ln/Col block
        str fp = str_from(&g_path[0], g_path_len);
        i32 budget = g_w - STATUS_RESERVE * cw;
        if budget < 8 * cw { budget = 8 * cw; }
        if font_ui_text_w(fp) > budget {
            u8[3] ell = { 0xE2, 0x80, 0xA6 };
            sx = font_draw_ui_text(str_from(&ell[0], 3), sx, sy, smax, C_STATUS_FG);
            i32 s = ui_text_tail_off(fp, budget);
            fp = str_from(fp.data + s, fp.len - s);
        }
        sx = font_draw_ui_text(fp, sx, sy, smax, C_STATUS_FG);
    } else if ed_rev_on() {
        sx = font_draw_ui_text(ed_rev_name(), sx, sy, smax, C_STATUS_FG);
    } else {
        sx = font_draw_ui_text("untitled", sx, sy, smax, C_STATUS_FG);
    }
    if tb.dirty {
        sx = font_draw_ui_text(" *", sx, sy, smax, C_STATUS_FG);
    }
    noinit u8[64] sb;
    i32 sn = 0;
    if g_img >= 0 {
        // an image: its size, the file's size and the zoom
        str st = image_status(g_img, &sb[0]);
        sn = st.len;
        if st.data != &sb[0] {
            memcpy(&sb[0], st.data, st.len);
        }
    } else {
    str pre = "Ln ";
    for i32 i = 0; i < pre.len; i++ { sb[sn] = pre.data[i]; sn++; }
    sn += fmt_i32(&sb[sn], cur_line + 1);
    str mid = ", Col ";
    for i32 i = 0; i < mid.len; i++ { sb[sn] = mid.data[i]; sn++; }
    sn += fmt_i32(&sb[sn], vcol_of_col(cur_line, cur_col) + 1);
    }
    if g_img < 0 && ed_cur_count() > 1 {
        str cnt = " (";
        for i32 i = 0; i < cnt.len; i++ { sb[sn] = cnt.data[i]; sn++; }
        sn += fmt_i32(&sb[sn], ed_cur_count());
        str tail = " cursors)";
        for i32 i = 0; i < tail.len; i++ { sb[sn] = tail.data[i]; sn++; }
    }
    f32 rx = cast(f32, g_w - font_ui_text_w(str_from(&sb[0], sn)) - 2 * cw - 8);
    // a window narrower than the block would start it left of the
    // edge; the drawer only clips on the right, so floor it instead
    if rx < STATUS_MARGIN { rx = STATUS_MARGIN; }
    ignore font_draw_ui_text(str_from(&sb[0], sn), rx, sy, smax, C_STATUS_FG);
    }

    // the overlays are one set: they draw in the window with the keyboard
    if ed_overlay_here() {
        hover_render();
        sig_render();
        cmp_render();
        find_render();
        pick_render();
        sym_render();
        palette_render();
        switcher_render();
        ask_render();
        menu_render();
        notice_render();
    }
    caption_render();

    if font_atlas_dirty {
        gpu_upload_atlas(font_atlas);
        font_atlas_dirty = false;
    }
    // a gliding view or a drag's autoscroll asks for the next frame;
    // the platform paces it to the display, and the request stops when
    // the view arrives or the drag leaves the edge
    if ed_glide_running() || ed_drag_scroll_running() { plat_damage_window(ed_window_active()); }
    f32 inv = 1.0f / 255.0f;
    gpu_frame_end(cast(f32, C_BG & 0xFF) * inv, cast(f32, (C_BG >> 8) & 0xFF) * inv, cast(f32, (C_BG >> 16) & 0xFF) * inv);
}
