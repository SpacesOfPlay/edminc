// pick.mc - fuzzy file picker (the ctrl+p overlay). Scans the
// working tree on open, matches the query as a scored subsequence,
// opens the selection through ed_open_file. Rendering is quads and
// glyphs into the shared batch, drawn above the editor.

private const i32 PICK_MAX_FILES = 20000;
private const i32 PICK_MAX_DEPTH = 24;
private const i32 PICK_PATH_MAX = 512;
private const i32 PICK_QUERY_MAX = 128;
private const i32 PICK_TOP_MAX = 256;    // results kept after scoring
const i32 PICK_MISS = -1000000000;   // pick_score: the query does not match

private const i32 PICK_COLS = 64;        // panel width in cells, clamped
private const i32 PICK_VIS = 12;         // result rows shown

bool pick_on = false;

private u8[PICK_QUERY_MAX] pk_q;
private i32 pk_qlen = 0;

// scanned paths: byte arena + (offset, length) records
struct PickFile {
    i32 off;
    i32 len;
}

private u8* pk_arena = null;
private i64 pk_alen = 0;
private i64 pk_acap = 0;
private PickFile* pk_files = null;
private i32 pk_count = 0;
private i32 pk_fcap = 0;

struct PickHit {
    i32 file;
    i32 score;
}

private PickHit* pk_hits = null;
private i32 pk_nhits = 0;
private i32 pk_sel = 0;
private i32 pk_top = 0;
private f32 pk_scroll_accum = 0.0f;

// --- scan ------------------------------------------------------------

private void pick_push(u8* p, i32 n) {
    if pk_count == pk_fcap {
        i32 ncap = pk_fcap * 2 + 1024;
        PickFile* nf = alloc<PickFile>(ncap);
        if pk_files != null {
            memcpy(nf, pk_files, pk_count * sizeof(PickFile));
            free(pk_files);
        }
        pk_files = nf;
        pk_fcap = ncap;
    }
    if pk_alen + n > pk_acap {
        i64 ncap = pk_acap * 2 + 65536;
        u8* na = alloc<u8>(ncap);
        if pk_arena != null {
            memcpy(na, pk_arena, pk_alen);
            free(pk_arena);
        }
        pk_arena = na;
        pk_acap = ncap;
    }
    memcpy(pk_arena + pk_alen, p, n);
    pk_files[pk_count] = PickFile{ cast(i32, pk_alen), n };
    pk_alen += n;
    pk_count++;
}

// plat_dir_list hands back whatever order the file system enumerates in:
// readdir order on unix, FindFirstFile order on Windows, neither
// specified. Sorting by name makes the file list, and everything
// derived from it (the picker, project search, the fuzzer's action
// stream), the same on every machine. Directories hold tens of
// entries, so insertion sort is the right shape.
void dir_sort(DirList* l) {
    for i32 i = 1; i < l.count; i++ {
        str v = l.items[i];
        i32 j = i - 1;
        while j >= 0 && str_compare(l.items[j], v) > 0 {
            l.items[j + 1] = l.items[j];
            j--;
        }
        l.items[j + 1] = v;
    }
}

// `ign`: the folder at pb is gitignored, and so is all it holds
private void pick_walk(u8* pb, i32 plen, i32 depth, bool ign) {
    if depth >= PICK_MAX_DEPTH || pk_count >= PICK_MAX_FILES { return; }
    str d = ".";
    if plen > 0 { d = str_from(pb, plen); }

    DirList fl = plat_dir_list(d, false);
    dir_sort(&fl);
    for i32 i = 0; i < fl.count; i++ {
        if pk_count >= PICK_MAX_FILES { break; }
        str nm = fl.items[i];
        if plen + 1 + nm.len >= PICK_PATH_MAX { continue; }
        i32 n = plen;
        if n > 0 {
            pb[n] = '/';
            n++;
        }
        memcpy(pb + n, nm.data, nm.len);
        str path = str_from(pb, n + nm.len);
        if ign_lists_skip(path, ign || ign_match(path, false)) { continue; }
        pick_push(pb, n + nm.len);
    }
    dir_list_free(&fl);

    DirList dl = plat_dir_list(d, true);
    dir_sort(&dl);
    for i32 i = 0; i < dl.count; i++ {
        str nm = dl.items[i];
        if plen + 1 + nm.len >= PICK_PATH_MAX { continue; }
        i32 n = plen;
        if n > 0 {
            pb[n] = '/';
            n++;
        }
        memcpy(pb + n, nm.data, nm.len);
        str path = str_from(pb, n + nm.len);
        bool git = ign || ign_match(path, true);
        if ign_lists_skip(path, git) { continue; }
        pick_walk(pb, n + nm.len, depth + 1, git);
    }
    dir_list_free(&dl);
}

void pick_scan() {
    pk_alen = 0;
    pk_count = 0;
    ign_reset();
    noinit u8[PICK_PATH_MAX] pb;
    pick_walk(&pb[0], 0, 0, false);
}

i32 pick_file_count() {
    return pk_count;
}

// the list as filtered, for the harness
i32 pick_hit_count() {
    return pk_nhits;
}

str pick_hit_path(i32 i) {
    if i < 0 || i >= pk_nhits { return ""; }
    return pick_file_path(pk_hits[i].file);
}

str pick_file_path(i32 i) {
    return str_from(pk_arena + pk_files[i].off, pk_files[i].len);
}

// --- matching --------------------------------------------------------

private bool pick_is_sep(u8 c) {
    return c == '/' || c == '_' || c == '-' || c == '.' || c == ' ';
}

// a word starts at i: the path's start, after a separator, or a capital
// after a lowercase letter
private bool pick_word_start(u8* p, i32 i) {
    if i == 0 || pick_is_sep(p[i - 1]) { return true; }
    return p[i] >= 'A' && p[i] <= 'Z' && p[i - 1] >= 'a' && p[i - 1] <= 'z';
}

// One match attempt with the first character at `start`: every later
// character either continues the run or begins a word, the way the
// reference's matcher takes a query, so a query's letters scattered
// through a path are no match. Greedy leftmost over the positions
// that qualify. Bonuses: word starts, consecutive runs, a match
// confined to the basename; longer paths score lower on ties. Fills
// pos[0..qn) with match byte offsets. PICK_MISS when it does not carry.
private i32 pick_match_from(u8* p, i32 n, u8* q, i32 qn, i32 start, i32* pos) {
    i32 score = 0;
    i32 i = start;
    i32 prev = -2;
    for i32 k = 0; k < qn; k++ {
        u8 qc = ascii_lower(q[k]);
        while i < n {
            if ascii_lower(p[i]) == qc && (k == 0 || i == prev + 1 || pick_word_start(p, i)) { break; }
            i++;
        }
        if i >= n { return PICK_MISS; }
        score += 1;
        if i == prev + 1 { score += 6; }
        if i == 0 || pick_is_sep(p[i - 1]) {
            score += 8;
        } else if p[i] >= 'A' && p[i] <= 'Z' && p[i - 1] >= 'a' && p[i - 1] <= 'z' {
            score += 6;
        }
        pos[k] = i;
        prev = i;
        i++;
    }
    if pos[0] >= path_base_off(p, n) { score += 10; }
    return score * 64 - n;
}

// The query against a path: the first character is tried at each of
// its word-start occurrences first, then at the others, and the first
// start that carries the whole query wins. So `ed` lands on the `ed`
// of lexer/ed.mc rather than dying in `lexer`, and `xer` still finds
// the run inside it.
i32 pick_score(u8* p, i32 n, u8* q, i32 qn, i32* pos) {
    if qn == 0 { return 0 - n; }
    u8 q0 = ascii_lower(q[0]);
    for i32 round = 0; round < 2; round++ {
        for i32 s = 0; s < n; s++ {
            if ascii_lower(p[s]) != q0 { continue; }
            if pick_word_start(p, s) != (round == 0) { continue; }
            i32 sc = pick_match_from(p, n, q, qn, s, pos);
            if sc != PICK_MISS { return sc; }
        }
    }
    return PICK_MISS;
}

private void pick_filter() {
    if pk_hits == null { pk_hits = alloc<PickHit>(PICK_TOP_MAX); }
    pk_nhits = 0;
    noinit i32[PICK_QUERY_MAX] pos;
    for i32 f = 0; f < pk_count; f++ {
        i32 sc = pick_score(pk_arena + pk_files[f].off, pk_files[f].len,
            &pk_q[0], pk_qlen, &pos[0]);
        if sc == PICK_MISS { continue; }
        if pk_nhits == PICK_TOP_MAX && sc <= pk_hits[PICK_TOP_MAX - 1].score { continue; }
        i32 j = pk_nhits;
        if j == PICK_TOP_MAX { j--; }
        while j > 0 && pk_hits[j - 1].score < sc {
            pk_hits[j] = pk_hits[j - 1];
            j--;
        }
        pk_hits[j] = PickHit{ f, sc };
        if pk_nhits < PICK_TOP_MAX { pk_nhits++; }
    }
    pk_sel = 0;
    pk_top = 0;
}

// --- open/close + input ----------------------------------------------

void pick_open() {
    find_close();
    pick_scan();
    pk_qlen = 0;
    pk_scroll_accum = 0.0f;
    pick_filter();
    pick_on = true;
    ed_damage();
}

private void pick_close() {
    pick_on = false;
    ed_damage();
}

private void pick_accept() {
    if pk_nhits > 0 {
        PickFile f = pk_files[pk_hits[pk_sel].file];
        ed_nav_mark();   // primary+Left walks back out of a quick open
        ignore ed_open_file(str_from(pk_arena + f.off, f.len));
    }
    pick_close();
}

private void pick_move(i32 delta) {
    pk_sel += delta;
    if pk_sel < 0 { pk_sel = 0; }
    if pk_sel >= pk_nhits { pk_sel = pk_nhits - 1; }
    if pk_sel < 0 { pk_sel = 0; }
    if pk_sel < pk_top { pk_top = pk_sel; }
    i32 vis = ui_list_vis(PICK_VIS);
    if pk_sel >= pk_top + vis { pk_top = pk_sel - vis + 1; }
    ed_damage();
}

private UiField pk_field;

private UiField* pick_field() {
    ui_field_bind(&pk_field, &pk_q[0], &pk_qlen, PICK_QUERY_MAX);
    return &pk_field;
}

void pick_char(u32 cp) {
    if cp == 13 { pick_accept(); return; }
    if !ui_field_char(pick_field(), cp) { return; }
    pick_filter();
    ed_damage();
}

void pick_key(i32 key, i32 mods) {
    bool changed = false;
    if ui_field_key(pick_field(), key, mods, &changed) {
        if changed { pick_filter(); }
        ed_damage();
        return;
    }
    // Ctrl+P again closes the picker; Ctrl+Shift+P goes straight to the
    // command palette, as it does in VS Code
    if (mods & MOD_CTRL) != 0 {
        if key == 'P' {
            pick_close();
            if (mods & MOD_SHIFT) != 0 { palette_open(); }
        }
        return;
    }
    if key == K_ESCAPE { pick_close(); return; }
    if key == K_UP { pick_move(-1); return; }
    if key == K_DOWN { pick_move(1); return; }
    if key == K_PGUP { pick_move(0 - ui_list_vis(PICK_VIS)); return; }
    if key == K_PGDN { pick_move(ui_list_vis(PICK_VIS)); return; }
}

// --- geometry + render -----------------------------------------------

private i32 pick_rows() {
    i32 nr = pk_nhits - pk_top;
    i32 vis = ui_list_vis(PICK_VIS);
    if nr > vis { nr = vis; }
    if nr < 1 { nr = 1; }   // the "no matches" row
    return nr;
}

// left-button press: a result row opens it, anywhere else closes
void pick_mouse(i32 x, i32 y) {
    i32 pw = ui_list_panel_w(PICK_COLS);
    i32 px = (g_w - pw) / 2;
    i32 pad = ui_list_pad();
    i32 ih = ui_input_h();
    i32 rh = ui_list_row_h();
    i32 py = pad;
    i32 ry = py + pad + ih + 4;
    if x >= px && x < px + pw && y >= ry && y < ry + pick_rows() * rh {
        i32 r = pk_top + (y - ry) / rh;
        if r < pk_nhits {
            pk_sel = r;
            pick_accept();
            return;
        }
    }
    i32 ph = pad + ih + 4 + pick_rows() * rh + pad;
    if x < px || x >= px + pw || y < py || y >= py + ph {
        pick_close();
    }
}

void pick_scroll(f32 dy) {
    pk_scroll_accum += dy;
    i32 rh = ui_list_row_h();
    i32 rows = cast(i32, pk_scroll_accum / cast(f32, rh));
    if rows == 0 { return; }
    pk_scroll_accum -= cast(f32, rows * rh);
    pk_top += rows;
    if pk_top > pk_nhits - ui_list_vis(PICK_VIS) { pk_top = pk_nhits - ui_list_vis(PICK_VIS); }
    if pk_top < 0 { pk_top = 0; }
    ed_damage();
}

void pick_render() {
    if !pick_on { return; }
    i32 pw = ui_list_panel_w(PICK_COLS);
    i32 px = (g_w - pw) / 2;
    i32 pad = ui_list_pad();
    i32 py = pad;
    i32 ih = ui_input_h();
    i32 rh = ui_list_row_h();
    i32 nr = pick_rows();
    i32 ph = pad + ih + 4 + nr * rh + pad;

    ui_panel(px, py, pw, ph);
    ui_input(px + pad, py + pad, pw - 2 * pad,
        pick_field(), "search files by name", caret_on);

    i32 tx = px + pad + 2 + ui_inset();
    i32 ty = py + pad + ih + 4;
    f32 max_px = cast(f32, px + pw - pad - ui_inset());
    if pk_nhits == 0 {
        ignore font_draw_ui_text("no files matched", cast(f32, tx),
            cast(f32, ty + (rh - font_ui_h) / 2), max_px, T_DIM);
    }
    noinit i32[PICK_QUERY_MAX] pos;
    noinit u8[PICK_PATH_MAX] hi;
    for i32 r = 0; r < nr && pk_top + r < pk_nhits; r++ {
        i32 h = pk_top + r;
        PickFile f = pk_files[pk_hits[h].file];
        u8* p = pk_arena + f.off;
        i32 y = ty + r * rh;
        ui_list_row(px + 1, y, pw - 2, rh, h == pk_sel);
        memset(&hi[0], 0, f.len);
        i32 sc = pick_score(p, f.len, &pk_q[0], pk_qlen, &pos[0]);
        if sc != PICK_MISS && pk_qlen > 0 {
            for i32 k = 0; k < pk_qlen; k++ { hi[pos[k]] = 1; }
        }
        // long paths keep their tail: skip leading bytes, draw one …
        f32 ny = cast(f32, y + (rh - font_ui_h) / 2);
        f32 x = cast(f32, tx);
        i32 avail = cast(i32, max_px) - tx;
        i32 s = 0;
        if font_ui_text_w(str_from(p, f.len)) > avail {
            u8[3] ell = { 0xE2, 0x80, 0xA6 };
            x = font_draw_ui_text(str_from(&ell[0], 3), x, ny, max_px, T_DIM);
            s = ui_text_tail_off(str_from(p, f.len), cast(i32, max_px - x));
        }
        i32 i = s;
        while i < f.len {
            i32 ci = i;
            u32 cp = utf8_next(p, f.len, &i);
            u32 c = T_FG;
            if hi[ci] != 0 { c = T_MATCH; }
            x = font_draw_ui_cp(cp, x, ny, c);
            if x >= max_px { break; }
        }
    }
    ui_list_scrollbar(px + pw - 1, ty, nr * rh, pk_top, nr, pk_nhits);
}
