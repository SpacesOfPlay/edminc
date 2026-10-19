// complete.mc - the completion popup. The server answers with a list
// once; typing on narrows it here rather than asking again, which is
// what keeps it responsive between keystrokes. The list is anchored to
// the word it was asked for, so a reply that arrives after the caret
// has moved off that word is dropped.

const i32 CMP_MAX_ITEMS = 512;
private const i32 CMP_LABEL_MAX = 160;
private const i32 CMP_VIS = 10;          // rows shown
private const i32 CMP_COLS = 44;         // panel width in cells, clamped

private struct CmpItem {
    i32 off;      // label, into the arena: what is matched and inserted
    i32 len;
    i32 soff;     // what the row shows instead, when slen > 0
    i32 slen;
    i32 doff;     // detail
    i32 dlen;
    i32 prio;     // the server's sortText prefix; builtins CMP_PRIO_TYPE
    i32 idx;      // arrival order, the last tiebreak
}

// The server labels scope in sortText: 000 for the innermost, 100 for
// this file, 200 for another. It does not order by it; that is the
// client's job, and it is what puts a local function ahead of a
// distant one.
const i32 CMP_PRIO_TYPE = -1;
const i32 CMP_PRIO_NONE = 500;

bool cmp_on = false;
// the server cut the list short; the editor asks again as the word grows
bool cmp_incomplete = false;

private CmpItem[CMP_MAX_ITEMS] cmp_items;
private i32 cmp_n = 0;
private u8* cmp_arena = null;
private i64 cmp_alen = 0;
private i64 cmp_acap = 0;

// the subset matching what has been typed since the word started
private i32[CMP_MAX_ITEMS] cmp_hits;
private i32 cmp_nhits = 0;
private i32 cmp_sel = 0;
private i32 cmp_top = 0;

// the word the list belongs to
private i32 cmp_line = 0;
private i32 cmp_word0 = 0;

// Rows that fit above the status bar. A short window would otherwise
// get a panel taller than itself: flipping it above the word only
// moves the overflow to the top edge.
private i32 cmp_vis() {
    i32 room = g_h - chrome_bottom_h() - 2 * ui_list_pad() - font_line_h;
    i32 rh = ui_list_row_h();
    i32 n = 0;
    if rh > 0 && room > 0 { n = room / rh; }
    if n > CMP_VIS { n = CMP_VIS; }
    if n < 1 { n = 1; }
    return n;
}

private i64 cmp_arena_push(u8* p, i32 n) {
    if cmp_alen + n > cmp_acap {
        i64 ncap = cmp_acap * 2 + 65536;
        u8* na = alloc<u8>(ncap);
        if cmp_arena != null {
            memcpy(na, cmp_arena, cmp_alen);
            free(cmp_arena);
        }
        cmp_arena = na;
        cmp_acap = ncap;
    }
    i64 off = cmp_alen;
    memcpy(cmp_arena + off, p, n);
    cmp_alen += n;
    return off;
}

// --- building the list from a reply ----------------------------------

// builtins: minc's builtin types go ahead of the server's symbols
void cmp_begin(i32 line, i32 word0, bool builtins) {
    cmp_n = 0;
    cmp_alen = 0;
    cmp_line = line;
    cmp_word0 = word0;
    cmp_incomplete = false;
    if !builtins { return; }
    // in the lexer's table order
    for i32 i = 0; i < LEX_NTYPES; i++ { cmp_add(lex_types[i], "type", CMP_PRIO_TYPE); }
}

void cmp_add(str label, str detail, i32 prio) {
    cmp_add_shown(label, "", detail, prio);
}

// an item whose row shows `shown` rather than the text it inserts
void cmp_add_shown(str label, str shown, str detail, i32 prio) {
    if cmp_n == CMP_MAX_ITEMS || label.len == 0 { return; }
    i32 ln = label.len;
    if ln > CMP_LABEL_MAX { ln = CMP_LABEL_MAX; }
    i32 sn = shown.len;
    if sn > CMP_LABEL_MAX { sn = CMP_LABEL_MAX; }
    i32 dn = detail.len;
    if dn > CMP_LABEL_MAX { dn = CMP_LABEL_MAX; }
    i64 lo = cmp_arena_push(label.data, ln);
    i64 so = 0;
    if sn > 0 { so = cmp_arena_push(shown.data, sn); }
    i64 doff = 0;
    if dn > 0 { doff = cmp_arena_push(detail.data, dn); }
    cmp_items[cmp_n] = CmpItem{ cast(i32, lo), ln, cast(i32, so), sn, cast(i32, doff), dn, prio, cmp_n };
    cmp_n++;
}

private i32 cmp_case_miss(CmpItem* it, u8* pre, i32 pn) {
    u8* lab = cmp_arena + it.off;
    for i32 k = 0; k < pn; k++ {
        if lab[k] != pre[k] { return 1; }
    }
    return 0;
}

// true when item a belongs after item b: scope first, then a prefix
// that matches as typed ahead of one that matches case-folded, then
// the order they arrived in
private bool cmp_after(i32 a, i32 b, u8* pre, i32 pn) {
    CmpItem* x = &cmp_items[a];
    CmpItem* y = &cmp_items[b];
    if x.prio != y.prio { return x.prio > y.prio; }
    i32 cx = cmp_case_miss(x, pre, pn);
    i32 cy = cmp_case_miss(y, pre, pn);
    if cx != cy { return cx > cy; }
    return x.idx > y.idx;
}

// the bytes typed since the word started, which is what the list is
// narrowed against
private i32 cmp_prefix(u8* out, i32 cap) {
    if cur_line != cmp_line { return -1; }
    i64 c = cur_col;
    if c < cast(i64, cmp_word0) { return -1; }
    i32 n = cast(i32, c) - cmp_word0;
    if n > cap { n = cap; }
    i32 len = line_bytes(cmp_line);
    if cmp_word0 + n > len { return -1; }
    memcpy(out, g_linebuf + cmp_word0, n);
    return n;
}

private void cmp_filter() {
    noinit u8[CMP_LABEL_MAX] pre;
    i32 pn = cmp_prefix(&pre[0], CMP_LABEL_MAX);
    cmp_nhits = 0;
    if pn < 0 {
        cmp_close();
        return;
    }
    for i32 i = 0; i < cmp_n; i++ {
        u8* lab = cmp_arena + cmp_items[i].off;
        if cmp_items[i].len < pn { continue; }
        bool m = true;
        for i32 k = 0; k < pn; k++ {
            if ascii_lower(lab[k]) != ascii_lower(pre[k]) { m = false; break; }
        }
        if !m { continue; }
        cmp_hits[cmp_nhits] = i;
        cmp_nhits++;
    }
    for i32 i = 1; i < cmp_nhits; i++ {
        i32 h = cmp_hits[i];
        i32 j = i - 1;
        while j >= 0 && cmp_after(cmp_hits[j], h, &pre[0], pn) {
            cmp_hits[j + 1] = cmp_hits[j];
            j--;
        }
        cmp_hits[j + 1] = h;
    }
    // the best match is on top after every keystroke, so the selection
    // starts there, as the reference does
    cmp_sel = 0;
    cmp_top = 0;
    if cmp_nhits == 0 { cmp_close(); }
}

// the reply landed: open if anything survives the prefix. Filtered
// before it opens, so a reply that matches nothing leaves the frame as
// it was.
void cmp_end() {
    if cmp_n == 0 {
        cmp_close();
        return;
    }
    cmp_filter();
    if cmp_nhits == 0 { return; }
    cmp_on = true;
    plat_damage();
}

void cmp_close() {
    if !cmp_on { return; }
    cmp_on = false;
    cmp_nhits = 0;
    plat_damage();
}

// how many items survive the typed prefix; the tests assert on it
i32 cmp_hit_count() {
    return cmp_nhits;
}

str cmp_hit_label(i32 i) {
    if i < 0 || i >= cmp_nhits { return ""; }
    CmpItem it = cmp_items[cmp_hits[i]];
    return str_from(cmp_arena + it.off, it.len);
}

// --- input -----------------------------------------------------------

private void cmp_move(i32 d) {
    cmp_sel += d;
    if cmp_sel >= cmp_nhits { cmp_sel = cmp_nhits - 1; }
    if cmp_sel < 0 { cmp_sel = 0; }
    if cmp_sel < cmp_top { cmp_top = cmp_sel; }
    i32 vis = cmp_vis();
    if cmp_sel >= cmp_top + vis { cmp_top = cmp_sel - vis + 1; }
    plat_damage();
}

private void cmp_accept() {
    if cmp_nhits == 0 {
        cmp_close();
        return;
    }
    CmpItem it = cmp_items[cmp_hits[cmp_sel]];
    // the typed prefix is replaced wholesale, so the label's own case
    // wins over what was typed
    ed_replace_word(cmp_line, cmp_word0,
        str_from(cmp_arena + it.off, it.len));
    cmp_close();
}

// true when the popup consumed the key
bool cmp_key(i32 key, i32 mods) {
    if !cmp_on { return false; }
    if key == K_ESCAPE {
        cmp_close();
        return true;
    }
    if key == K_UP {
        cmp_move(-1);
        return true;
    }
    if key == K_DOWN {
        cmp_move(1);
        return true;
    }
    if key == K_PGUP {
        cmp_move(0 - cmp_vis());
        return true;
    }
    if key == K_PGDN {
        cmp_move(cmp_vis());
        return true;
    }
    // anything else moves the caret or edits: let it through, and let
    // the caret check below decide whether the list still applies
    cmp_close();
    return false;
}

bool cmp_char(u32 cp) {
    if !cmp_on { return false; }
    if cp == 13 || cp == 9 {
        cmp_accept();
        return true;
    }
    return false;
}

// after a character went into the buffer: narrow, or give up if the
// caret has left the word the list was asked for
void cmp_after_type() {
    if !cmp_on { return; }
    cmp_filter();
    plat_damage();
}

// --- render ----------------------------------------------------------

void cmp_render() {
    if !cmp_on || cmp_nhits == 0 { return; }
    // The list is anchored to a line of the buffer it was asked for. A
    // switch to a shorter buffer leaves that line past the end, and the
    // anchor below indexes the line table with it.
    if cmp_line < 0 || cmp_line >= tb.nlines { return; }
    i32 cw = font_cell_w;
    i32 lh = font_line_h;
    i32 pad = ui_list_pad();
    i32 rh = ui_list_row_h();
    i32 nr = cmp_nhits - cmp_top;
    i32 vis = cmp_vis();
    if nr > vis { nr = vis; }
    if nr < 1 { return; }

    i32 pw = CMP_COLS * cw;
    if pw > g_w - 2 * cw { pw = g_w - 2 * cw; }
    i32 ph = nr * rh + 2 * pad;

    // anchored under the word it is completing
    i32 wx = 0;
    i32 wy = 0;
    ed_pos_xy(cmp_line, cast(i64, cmp_word0), &wx, &wy);
    i32 px = wx;
    if px + pw > g_w - cw { px = g_w - cw - pw; }
    if px < 0 { px = 0; }
    // Below the word, flipped above it when the bottom is close. Then
    // clamped into the window regardless: the word can be far outside
    // the viewport (the caret scrolled away while the reply was in
    // flight), and the flip alone leaves the panel where the word is,
    // not where the window is.
    i32 bottom = g_h - chrome_bottom_h();
    i32 py = wy + lh;
    if py + ph > bottom { py = wy - ph; }
    if py + ph > bottom { py = bottom - ph; }
    if py < 0 { py = 0; }

    ui_panel(px, py, pw, ph);
    // The label is drawn in the code typeface, so it reads as it will in
    // the buffer; the detail (its type) follows in the smaller UI face.
    // Clipped to the panel so a long label cannot run past its edge.
    draw_clip(cast(f32, px + 1), cast(f32, px + pw - 1));
    for i32 r = 0; r < nr; r++ {
        i32 h = cmp_top + r;
        CmpItem it = cmp_items[cmp_hits[h]];
        i32 y = py + pad + r * rh;
        ui_list_row(px + 1, y, pw - 2, rh, h == cmp_sel);
        f32 lty = cast(f32, y + (rh - font_line_h) / 2);
        str row = str_from(cmp_arena + it.off, it.len);
        if it.slen > 0 { row = str_from(cmp_arena + it.soff, it.slen); }
        f32 x = font_draw_text(row, cast(f32, px + pad), lty, T_FG);
        if it.dlen > 0 {
            f32 dty = cast(f32, y + (rh - font_ui_h) / 2);
            ignore font_draw_ui_text(str_from(cmp_arena + it.doff, it.dlen),
                x + cast(f32, cw), dty, cast(f32, px + pw - pad), T_DIM);
        }
    }
    draw_clip_off();
    ui_list_scrollbar(px + pw - 1, py + pad, nr * rh, cmp_top, nr, cmp_nhits);
}
