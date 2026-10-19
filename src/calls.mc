// calls.mc - the call graph view: the function at the caret in the
// middle, the functions that call it above, the functions it calls
// below, each joined to it by a curve. Ctrl+Shift+M opens it.
// The data is the language server's call hierarchy (lsp.mc): prepare
// at the caret, then incoming and outgoing calls for the center. A
// click or Enter on a caller or a callee makes it the center, Backspace
// goes back along the trail, Enter on the center opens it in the
// editor, and Escape returns. This file holds the state, the layout
// and the input; view.mc draws it (calls_render).

import file;

bool calls_on = false;

// what the view is waiting on or found
const i32 CALLS_FINDING = 0;    // prepare is out
const i32 CALLS_READY = 1;      // a center; its rows fill in
const i32 CALLS_NONE = 2;       // no function at the caret
const i32 CALLS_INDEXING = 3;   // the server's scan is still running
const i32 CALLS_NO_SERVER = 4;  // no server, or one without call hierarchy

private const i32 CALLS_ROW_MAX = 256;
private const i32 CALLS_TRAIL_MAX = 32;
private const i32 CALLS_CARD_MAX = 64;

// row 0 is the callers, row 1 the callees
private i32 calls_phase = CALLS_FINDING;
private CallItem calls_center;
// a caller or a callee: the function, how many call sites the reply
// named, and the first site's line (in the caller's file for a caller).
// A callee also keeps its first sites, in the center's file, for the
// center to mark: the line and the name's columns as the server counts.
private const i32 CALLS_SITE_MAX = 8;
private struct CallRow {
    CallItem it;
    i32 sites;
    i32 site_line;
    i32 nsite;
    i32[CALLS_SITE_MAX] sl;
    i32[CALLS_SITE_MAX] sc0;
    i32[CALLS_SITE_MAX] sc1;
}
private CallRow[CALLS_ROW_MAX] calls_up;
private CallRow[CALLS_ROW_MAX] calls_down;
private i32[2] calls_n;
private bool[2] calls_loading;
private bool[2] calls_indexing;
private CallItem[CALLS_TRAIL_MAX] calls_trail;
private i32 calls_ntrail = 0;

// a row with more functions than fit shows one card per file; a click
// on one opens that file's functions in the row
private i32[2] calls_group_open;   // the open group's first row index, or -1

// --- the layout, as last computed ---------------------------------------

const i32 CARD_FN = 0;      // a function: idx into its row
const i32 CARD_GROUP = 1;   // a file's functions: idx of its first
const i32 CARD_BACK = 2;    // back to all files
const i32 CARD_MORE = 3;    // what did not fit: idx is the count
const i32 CARD_CENTER = 4;
const i32 CARD_PREV = 5;    // the page before: idx is how many it held

// A row that still does not fit is shown a page at a time: "N more"
// goes to the next page, "N before" back. Each row keeps the starts of
// the pages it went through, so back returns to exactly the page before.
private const i32 CALLS_PAGES_MAX = 64;
private i32[2] calls_page;                   // the first file or function shown
private i32[2 * CALLS_PAGES_MAX] calls_page_stack;
private i32[2] calls_npages;
private i32 calls_want_row = -2;             // after a page turn: select this row's
private i32 calls_want_kind = -1;            // card of this kind, else its first

private i32 calls_ncards = 0;
private i32[CALLS_CARD_MAX] cd_x;
private i32[CALLS_CARD_MAX] cd_y;
private i32[CALLS_CARD_MAX] cd_w;
private i32[CALLS_CARD_MAX] cd_h;
private i32[CALLS_CARD_MAX] cd_kind;
private i32[CALLS_CARD_MAX] cd_row;   // 0 callers, 1 callees, -1 the center
private i32[CALLS_CARD_MAX] cd_idx;
private i32[CALLS_CARD_MAX] cd_count; // a group's functions
private i32 calls_sel = 0;           // a card index

private CallRow* calls_row(i32 row, i32 i) {
    if row == 0 { return &calls_up[i]; }
    return &calls_down[i];
}

private CallItem* calls_row_item(i32 row, i32 i) {
    return &calls_row(row, i).it;
}

i32 calls_row_sites(i32 row, i32 i) {
    return calls_row(row, i).sites;
}

i32 calls_row_site_line(i32 row, i32 i) {
    return calls_row(row, i).site_line;
}

private bool calls_same_path(CallItem* a, CallItem* b) {
    return a.path_len == b.path_len
        && str_equal(str_from(&a.path[0], a.path_len), str_from(&b.path[0], b.path_len));
}

// --- opening, moving, closing ---------------------------------------------

private void calls_rows_reset() {
    for i32 r = 0; r < 2; r++ {
        calls_n[r] = 0;
        calls_loading[r] = true;
        calls_indexing[r] = false;
        calls_group_open[r] = -1;
        calls_page[r] = 0;
        calls_npages[r] = 0;
    }
    calls_sel = 0;
    calls_ncards = 0;
}

// Ctrl+Shift+M: the view on the function at the caret
void calls_open() {
    if explode_on { explode_close(); }
    calls_files_drop();
    calls_on = true;
    calls_ntrail = 0;
    calls_rows_reset();
    calls_phase = CALLS_FINDING;
    if !lsp_ready || !lsp_calls_ok {
        calls_phase = CALLS_NO_SERVER;
    } else {
        str p = ed_path();
        if p.len == 0 {
            calls_phase = CALLS_NONE;
        } else {
            lsp_request_call_prepare(p, ed_cur_line(), ed_cur_lsp_col());
        }
    }
    plat_damage();
}

void calls_close() {
    if !calls_on { return; }
    calls_on = false;
    plat_damage();
}

// the center's rows go out; the view draws the center at once
private void calls_ask() {
    calls_rows_reset();
    calls_phase = CALLS_READY;
    calls_sel = 0;
    lsp_request_calls(true, &calls_center);
    lsp_request_calls(false, &calls_center);
    plat_damage();
}

// a new center; the old one goes on the trail
private void calls_go(CallItem* it) {
    if calls_ntrail == CALLS_TRAIL_MAX {
        for i32 i = 1; i < CALLS_TRAIL_MAX; i++ { calls_trail[i - 1] = calls_trail[i]; }
        calls_ntrail--;
    }
    calls_trail[calls_ntrail] = calls_center;
    calls_ntrail++;
    calls_center = *it;
    calls_ask();
}

private void calls_back() {
    if calls_ntrail == 0 { return; }
    calls_ntrail--;
    calls_center = calls_trail[calls_ntrail];
    calls_ask();
}

// Enter on the center: the function in the editor, the view gone
private void calls_open_center() {
    if calls_phase != CALLS_READY { return; }
    CallItem it = calls_center;
    calls_close();
    ed_lsp_goto(str_from(&it.path[0], it.path_len), it.sl0, it.sc0);
}

// --- the server's answers (lsp.mc) --------------------------------------

void calls_center_found(CallItem* it) {
    if !calls_on { return; }
    calls_center = *it;
    calls_ask();
}

void calls_center_missing(bool indexing) {
    if !calls_on { return; }
    calls_phase = CALLS_NONE;
    if indexing { calls_phase = CALLS_INDEXING; }
    plat_damage();
}

// new rows start with no file open and on their first page
void calls_rows_begin(bool incoming) {
    i32 r = 1;
    if incoming { r = 0; }
    calls_n[r] = 0;
    calls_group_open[r] = -1;
    calls_page_reset(r);
}

void calls_row_add(bool incoming, CallItem* it, i32 sites, i32 site_line) {
    i32 r = 1;
    if incoming { r = 0; }
    if calls_n[r] == CALLS_ROW_MAX { return; }
    CallRow* row = calls_row(r, calls_n[r]);
    row.it = *it;
    row.sites = sites;
    row.site_line = site_line;
    row.nsite = 0;
    calls_n[r] = calls_n[r] + 1;
}

// a site of the row just added
void calls_row_site(bool incoming, i32 line, i32 c0, i32 c1) {
    i32 r = 1;
    if incoming { r = 0; }
    if calls_n[r] == 0 { return; }
    CallRow* row = calls_row(r, calls_n[r] - 1);
    if row.nsite == CALLS_SITE_MAX { return; }
    row.sl[row.nsite] = line;
    row.sc0[row.nsite] = c0;
    row.sc1[row.nsite] = c1;
    row.nsite++;
}

i32 calls_row_nsite(i32 row, i32 i) { return calls_row(row, i).nsite; }

void calls_row_site_at(i32 row, i32 i, i32 k, i32* line, i32* c0, i32* c1) {
    CallRow* rw = calls_row(row, i);
    *line = rw.sl[k];
    *c0 = rw.sc0[k];
    *c1 = rw.sc1[k];
}

// whether the selected card stands for callee i: the callee's own card,
// or its file's
bool calls_callee_selected(i32 i) {
    if calls_sel < 0 || calls_sel >= calls_ncards || cd_row[calls_sel] != 1 { return false; }
    if cd_kind[calls_sel] == CARD_FN { return cd_idx[calls_sel] == i; }
    if cd_kind[calls_sel] == CARD_GROUP {
        return i >= cd_idx[calls_sel] && i < cd_idx[calls_sel] + cd_count[calls_sel];
    }
    return false;
}

// Rows are kept grouped by file, in the order each file first appears,
// so a group is one run of the row.
private void calls_row_sort(i32 r) {
    i32 n = calls_n[r];
    for i32 i = 1; i < n; i++ {
        // the run for item i's file ends after the last earlier item with it
        i32 last = -1;
        for i32 j = 0; j < i; j++ {
            if calls_same_path(calls_row_item(r, j), calls_row_item(r, i)) { last = j; }
        }
        if last < 0 || last == i - 1 { continue; }
        CallRow keep = *calls_row(r, i);
        for i32 j = i; j > last + 1; j-- { *calls_row(r, j) = *calls_row(r, j - 1); }
        *calls_row(r, last + 1) = keep;
    }
}

void calls_rows_done(bool incoming) {
    i32 r = 1;
    if incoming { r = 0; }
    calls_loading[r] = false;
    calls_row_sort(r);
    plat_damage();
}

void calls_rows_failed(bool incoming, bool indexing) {
    i32 r = 1;
    if incoming { r = 0; }
    calls_n[r] = 0;
    calls_loading[r] = false;
    calls_indexing[r] = indexing;
    plat_damage();
}

// --- the layout -----------------------------------------------------------

// the run of row r that shares item i's file: its length
private i32 calls_run_len(i32 r, i32 i) {
    i32 k = i + 1;
    while k < calls_n[r] && calls_same_path(calls_row_item(r, k), calls_row_item(r, i)) { k++; }
    return k - i;
}

private i32 calls_group_count(i32 r) {
    i32 g = 0;
    i32 i = 0;
    while i < calls_n[r] {
        g++;
        i += calls_run_len(r, i);
    }
    return g;
}

private void calls_card(i32 kind, i32 row, i32 idx, i32 count) {
    if calls_ncards == CALLS_CARD_MAX { return; }
    cd_kind[calls_ncards] = kind;
    cd_row[calls_ncards] = row;
    cd_idx[calls_ncards] = idx;
    cd_count[calls_ncards] = count;
    calls_ncards++;
}

// The cards of row r, before they are placed: every function when they
// fit, else a card per file; files, or an open file's functions, that
// still do not fit are shown a page at a time.
private void calls_row_cards(i32 r, i32 fit) {
    i32 n = calls_n[r];
    i32 go = calls_group_open[r];
    i32 page = calls_page[r];
    if go >= 0 {
        calls_card(CARD_BACK, r, 0, 0);
        i32 len = calls_run_len(r, go);
        i32 slots = fit - 1;
        if page > 0 {
            calls_card(CARD_PREV, r, page, 0);
            slots--;
        }
        if slots < 1 { slots = 1; }
        i32 rem = len - page;
        i32 show = rem;
        if rem > slots { show = slots - 1; }
        if show < 1 && rem > 0 { show = 1; }
        for i32 i = 0; i < show; i++ { calls_card(CARD_FN, r, go + page + i, 0); }
        if show < rem { calls_card(CARD_MORE, r, rem - show, show); }
        return;
    }
    if n <= fit {
        for i32 i = 0; i < n; i++ { calls_card(CARD_FN, r, i, 0); }
        return;
    }
    i32 ng = calls_group_count(r);
    i32 slots = fit;
    if page > 0 {
        calls_card(CARD_PREV, r, page, 0);
        slots--;
    }
    if slots < 1 { slots = 1; }
    i32 rem = ng - page;
    i32 show = rem;
    if rem > slots { show = slots - 1; }
    if show < 1 && rem > 0 { show = 1; }
    // skip to the page's first file
    i32 i = 0;
    for i32 g = 0; g < page && i < n; g++ { i += calls_run_len(r, i); }
    for i32 g = 0; g < show && i < n; g++ {
        i32 len = calls_run_len(r, i);
        // a file with one function shows the function itself
        if len == 1 {
            calls_card(CARD_FN, r, i, 0);
        } else {
            calls_card(CARD_GROUP, r, i, len);
        }
        i += len;
    }
    if show < rem { calls_card(CARD_MORE, r, rem - show, show); }
}

// the next page of row r, which held `shown` files or functions
private void calls_page_next(i32 r, i32 shown) {
    if calls_npages[r] < CALLS_PAGES_MAX {
        calls_page_stack[r * CALLS_PAGES_MAX + calls_npages[r]] = calls_page[r];
        calls_npages[r] = calls_npages[r] + 1;
    }
    calls_page[r] = calls_page[r] + shown;
    calls_want_row = r;
    calls_want_kind = CARD_MORE;
}

private void calls_page_prev(i32 r) {
    if calls_npages[r] > 0 {
        calls_npages[r] = calls_npages[r] - 1;
        calls_page[r] = calls_page_stack[r * CALLS_PAGES_MAX + calls_npages[r]];
    } else {
        calls_page[r] = 0;
    }
    calls_want_row = r;
    calls_want_kind = CARD_PREV;
}

// a file opened or closed: its row starts at the first page
private void calls_page_reset(i32 r) {
    calls_page[r] = 0;
    calls_npages[r] = 0;
}

private void calls_place_row(i32 first, i32 x0, i32 w, i32 y, i32 cw, i32 ch, i32 gap) {
    i32 k = calls_ncards - first;
    if k <= 0 { return; }
    // a narrow window shrinks the cards, and the gaps with them, so
    // every card stays inside the area
    if (k - 1) * gap >= w { gap = 0; }
    i32 cw_fit = (w - (k - 1) * gap) / k;
    if cw_fit < cw { cw = cw_fit; }
    if cw < 1 { cw = 1; }
    i32 rw = k * cw + (k - 1) * gap;
    i32 x = x0 + (w - rw) / 2;
    for i32 i = first; i < calls_ncards; i++ {
        cd_x[i] = x;
        cd_y[i] = y;
        cd_w[i] = cw;
        cd_h[i] = ch;
        x += cw + gap;
    }
}

// The center card is sized to its function: as wide as its widest
// line, as tall as its lines. When they do not fit the band between the
// rows, the first of these that fits is taken: one column scaled down
// to CALLS_CENTER_MIN_SCALE, then two columns no smaller than that.
// Else the lines are cut at that scale, in two columns when two fit
// across, and the rest are counted on a last line.
private const i32 CALLS_CENTER_MIN_COLS = 40;   // room for the header
private const f32 CALLS_CENTER_MIN_SCALE = 0.8f;
private i32 calls_ccols = 1;      // the center's columns of code
private i32 calls_cper = 0;       // lines in each
private i32 calls_cmore = 0;      // lines that did not fit
private f32 calls_cscale = 1.0f;  // the code's scale

private void calls_center_fit(i32 w, i32 band) {
    i32 n = 0;
    i32 cols = 0;
    calls_center_size(&n, &cols);
    f32 lh = cast(f32, font_line_h);
    i32 cw = font_cell_w;
    i32 rh = ui_list_row_h();
    i32 pad = ui_inset();
    f32 code_w = cast(f32, cols * cw);
    i32 colgap = 2 * cw;
    f32 room = cast(f32, band - rh - 2 * pad);
    if room < lh * CALLS_CENTER_MIN_SCALE { room = lh * CALLS_CENTER_MIN_SCALE; }
    calls_ccols = 1;
    calls_cper = n;
    calls_cmore = 0;
    calls_cscale = 1.0f;
    f32 full = cast(f32, n) * lh;
    if full > room {
        f32 s1 = room / full;
        i32 per2 = (n + 1) / 2;
        f32 s2 = room / (cast(f32, per2) * lh);
        if s2 > 1.0f { s2 = 1.0f; }
        bool two_fit = 2.0f * code_w * s2 + cast(f32, colgap + 2 * pad) <= cast(f32, w);
        if s1 >= CALLS_CENTER_MIN_SCALE {
            calls_cscale = s1;
        } else if s2 >= CALLS_CENTER_MIN_SCALE && two_fit {
            calls_cscale = s2;
            calls_ccols = 2;
            calls_cper = per2;
        } else {
            calls_cscale = CALLS_CENTER_MIN_SCALE;
            f32 sl = lh * CALLS_CENTER_MIN_SCALE;
            if 2.0f * code_w * CALLS_CENTER_MIN_SCALE + cast(f32, colgap + 2 * pad) <= cast(f32, w) {
                calls_ccols = 2;
            }
            // a line kept back for the count
            i32 per = cast(i32, (room - sl) / sl);
            if per < 1 { per = 1; }
            calls_cper = per;
            calls_cmore = n - per * calls_ccols;
            if calls_cmore < 0 { calls_cmore = 0; }
        }
    }
    f32 sl = lh * calls_cscale;
    i32 cw_card = cast(i32, cast(f32, calls_ccols) * code_w * calls_cscale) + (calls_ccols - 1) * colgap + 2 * pad;
    if cw_card < CALLS_CENTER_MIN_COLS * cw { cw_card = CALLS_CENTER_MIN_COLS * cw; }
    if cw_card > w { cw_card = w; }
    if cw_card < 1 { cw_card = 1; }
    i32 lines = calls_cper;
    if calls_cmore > 0 { lines++; }
    i32 ch = rh + 2 * pad + cast(i32, cast(f32, lines) * sl) + 1;
    if ch > band { ch = band; }
    if ch < 1 { ch = 1; }
    cd_w[0] = cw_card;
    cd_h[0] = ch;
}

f32 calls_center_scale() { return calls_cscale; }
i32 calls_center_cols() { return calls_ccols; }
i32 calls_center_per() { return calls_cper; }
i32 calls_center_more() { return calls_cmore; }

// The cards over the area x0, y0, w, h: the callers' row at the top,
// the center, the callees' row at the bottom. A small card is card_h
// tall and card_w wide, narrower down to min_w when more fit that way;
// gap is the space between cards and bands.
void calls_layout(i32 x0, i32 y0, i32 w, i32 h, i32 card_w, i32 min_w, i32 card_h, i32 gap) {
    i32 keep_kind = -1;
    i32 keep_row = -2;
    i32 keep_idx = -1;
    if calls_sel >= 0 && calls_sel < calls_ncards {
        keep_kind = cd_kind[calls_sel];
        keep_row = cd_row[calls_sel];
        keep_idx = cd_idx[calls_sel];
    }
    calls_ncards = 0;
    i32 fit = (w + gap) / (min_w + gap);
    if fit < 2 { fit = 2; }
    // the center first, so a selection on it survives an empty row
    calls_card(CARD_CENTER, -1, 0, 0);
    // the center in the middle of the band the two rows leave
    i32 vgap = gap * 3 / 2;
    i32 cy = y0 + card_h + vgap;
    i32 band = h - 2 * card_h - 2 * vgap;
    if band < 1 { band = 1; }
    calls_center_fit(w, band);
    cd_x[0] = x0 + (w - cd_w[0]) / 2;
    cd_y[0] = cy + (band - cd_h[0]) / 2;
    i32 first = calls_ncards;
    calls_row_cards(0, fit);
    calls_place_row(first, x0, w, y0, card_w, card_h, gap);
    first = calls_ncards;
    calls_row_cards(1, fit);
    calls_place_row(first, x0, w, y0 + h - card_h, card_w, card_h, gap);
    // the selection stays on the same card when it is still there;
    // after a page turn it goes to the card that turns it again, else to
    // the row's first
    calls_sel = 0;
    for i32 i = 0; i < calls_ncards; i++ {
        if cd_kind[i] == keep_kind && cd_row[i] == keep_row && cd_idx[i] == keep_idx { calls_sel = i; }
    }
    if calls_want_row != -2 {
        i32 first = -1;
        i32 want = -1;
        for i32 i = 0; i < calls_ncards; i++ {
            if cd_row[i] != calls_want_row { continue; }
            if first < 0 { first = i; }
            if want < 0 && cd_kind[i] == calls_want_kind { want = i; }
        }
        if want >= 0 { calls_sel = want; } else if first >= 0 { calls_sel = first; }
        calls_want_row = -2;
    }
}

private const i32 CALLS_CARD_COLS = 30;     // a small card's width in cells
private const i32 CALLS_CARD_MIN_COLS = 18; // and the narrowest it gets
private i32 calls_ax = 0;   // the area as last laid out
private i32 calls_ay = 0;
private i32 calls_aw = 0;
private i32 calls_ah = 0;
private i32 calls_card_h = 0;
// a small card's snippet: this many lines of code at this scale
const i32 CALLS_SNIP_LINES = 3;
const f32 CALLS_SNIP_SCALE = 0.8f;

// The layout for the window as it is. The frame and every input call
// it, so a key needs no frame drawn before it to find the cards.
void calls_relayout() {
    i32 gap = font_line_h;
    // a line of text, then the snippet
    i32 snip = cast(i32, cast(f32, CALLS_SNIP_LINES * font_line_h) * CALLS_SNIP_SCALE) + 1;
    calls_card_h = ui_list_row_h() + 2 * ui_inset() + snip;
    calls_ax = gap;
    calls_ay = gap;
    calls_aw = g_w - 2 * gap;
    calls_ah = g_h - status_h() - 2 * gap;
    calls_layout(calls_ax, calls_ay, calls_aw, calls_ah, CALLS_CARD_COLS * font_cell_w,
        CALLS_CARD_MIN_COLS * font_cell_w, calls_card_h, gap);
}

// row r's band: where its cards sit, for the note an empty row shows
void calls_band(i32 r, i32* x, i32* y, i32* w, i32* h) {
    *x = calls_ax;
    *w = calls_aw;
    *h = calls_card_h;
    *y = calls_ay;
    if r == 1 { *y = calls_ay + calls_ah - calls_card_h; }
}

// --- input ------------------------------------------------------------------

// Enter or a click on card i
private void calls_activate(i32 i) {
    if i < 0 || i >= calls_ncards { return; }
    i32 k = cd_kind[i];
    i32 r = cd_row[i];
    if k == CARD_CENTER {
        calls_open_center();
    } else if k == CARD_FN {
        CallItem it = *calls_row_item(r, cd_idx[i]);
        calls_go(&it);
    } else if k == CARD_GROUP {
        calls_group_open[r] = cd_idx[i];
        calls_page_reset(r);
        calls_want_row = r;
        calls_want_kind = CARD_FN;
        plat_damage();
    } else if k == CARD_BACK {
        calls_group_open[r] = -1;
        calls_page_reset(r);
        calls_want_row = r;
        calls_want_kind = CARD_GROUP;
        plat_damage();
    } else if k == CARD_MORE {
        calls_page_next(r, cd_count[i]);
        plat_damage();
    } else if k == CARD_PREV {
        calls_page_prev(r);
        plat_damage();
    }
}

// the card of row `row` (-1 the center) nearest to x, or -1
private i32 calls_nearest(i32 row, i32 x) {
    i32 best = -1;
    i32 bd = 0;
    for i32 i = 0; i < calls_ncards; i++ {
        if cd_row[i] != row { continue; }
        i32 d = cd_x[i] + cd_w[i] / 2 - x;
        if d < 0 { d = 0 - d; }
        if best < 0 || d < bd {
            best = i;
            bd = d;
        }
    }
    return best;
}

private void calls_move_row(i32 dir) {
    if calls_ncards == 0 { return; }
    i32 row = cd_row[calls_sel];
    i32 x = cd_x[calls_sel] + cd_w[calls_sel] / 2;
    // up from the center is the callers, down the callees
    i32 want = -1;
    if row == -1 {
        if dir < 0 { want = 0; } else { want = 1; }
    } else if (row == 0 && dir > 0) || (row == 1 && dir < 0) {
        want = -1;
    } else {
        return;
    }
    i32 j = calls_nearest(want, x);
    if j >= 0 {
        calls_sel = j;
        plat_damage();
    }
}

private void calls_move_col(i32 dir) {
    if calls_ncards == 0 { return; }
    i32 row = cd_row[calls_sel];
    i32 j = calls_sel + dir;
    if j >= 0 && j < calls_ncards && cd_row[j] == row {
        calls_sel = j;
        plat_damage();
    }
}

void calls_key(i32 key, i32 mods) {
    if key == K_ESCAPE { calls_close(); return; }
    if calls_phase == CALLS_READY { calls_relayout(); }
    if mods != 0 { return; }
    if key == K_UP { calls_move_row(-1); return; }
    if key == K_DOWN { calls_move_row(1); return; }
    if key == K_LEFT { calls_move_col(-1); return; }
    if key == K_RIGHT { calls_move_col(1); return; }
}

// Enter activates the selection; Backspace goes back along the trail
void calls_char(u32 cp) {
    if calls_phase == CALLS_READY { calls_relayout(); }
    if cp == 13 { calls_activate(calls_sel); return; }
    if cp == 8 { calls_back(); return; }
}

private i32 calls_card_at(i32 x, i32 y) {
    for i32 i = 0; i < calls_ncards; i++ {
        if x >= cd_x[i] && x < cd_x[i] + cd_w[i] && y >= cd_y[i] && y < cd_y[i] + cd_h[i] { return i; }
    }
    return -1;
}

void calls_mouse(i32 x, i32 y) {
    if calls_phase == CALLS_READY { calls_relayout(); }
    i32 i = calls_card_at(x, y);
    if i >= 0 {
        calls_sel = i;
        calls_activate(i);
    }
}

void calls_hover(i32 x, i32 y) {
    if calls_phase == CALLS_READY { calls_relayout(); }
    i32 i = calls_card_at(x, y);
    if i >= 0 && i != calls_sel {
        calls_sel = i;
        plat_damage();
    }
}

// --- what view.mc and the tests read --------------------------------------

i32 calls_phase_now() { return calls_phase; }
CallItem* calls_center_item() { return &calls_center; }
i32 calls_row_count(i32 row) { return calls_n[row]; }
bool calls_row_loading(i32 row) { return calls_loading[row]; }
bool calls_row_indexing(i32 row) { return calls_indexing[row]; }
CallItem* calls_item(i32 row, i32 i) { return calls_row_item(row, i); }
i32 calls_trail_len() { return calls_ntrail; }
i32 calls_card_count() { return calls_ncards; }
i32 calls_selected() { return calls_sel; }
void calls_card_rect(i32 i, i32* x, i32* y, i32* w, i32* h) {
    *x = cd_x[i];
    *y = cd_y[i];
    *w = cd_w[i];
    *h = cd_h[i];
}
i32 calls_card_kind(i32 i) { return cd_kind[i]; }
i32 calls_card_row(i32 i) { return cd_row[i]; }
i32 calls_card_idx(i32 i) { return cd_idx[i]; }
i32 calls_card_count_of(i32 i) { return cd_count[i]; }

// a test opens the view without a server
void calls_show_for_test() {
    calls_on = true;
    calls_ntrail = 0;
    calls_rows_reset();
    calls_phase = CALLS_FINDING;
}

// --- the text the cards show ------------------------------------------------
// The center card and the snippets draw lines of the functions' files
// themselves: from the active buffer when it holds the file, else from
// the file on disk. A few files are kept, each read once while the view
// is open, with the start of every line indexed.

const i32 CALLS_TAB = 4;
private const i32 CALLS_FILES = 16;

private struct CallsFile {
    u8[PATH_MAX] path;
    i32 path_len;
    u8* data;
    i64 len;
    i64* starts;   // the start of each line, and one past the last
    i32 nlines;
    i64 used;      // for the eviction: the clock at the last use
}
private CallsFile[CALLS_FILES] calls_files;
private i64 calls_file_clock = 0;

private void calls_file_free(CallsFile* f) {
    if f.data != null { free(f.data); }
    if f.starts != null { free(f.starts); }
    f.data = null;
    f.starts = null;
    f.len = 0;
    f.nlines = 0;
    f.path_len = 0;
}

// the files go when the view opens, so an edit since the last time shows
void calls_files_drop() {
    for i32 i = 0; i < CALLS_FILES; i++ { calls_file_free(&calls_files[i]); }
}

// the file at `path`, read on first use; null when it cannot be read
private CallsFile* calls_file(str path) {
    if path.len == 0 || path.len > PATH_MAX { return null; }
    calls_file_clock++;
    i32 old = 0;
    for i32 i = 0; i < CALLS_FILES; i++ {
        CallsFile* f = &calls_files[i];
        if f.path_len == path.len && str_equal(str_from(&f.path[0], f.path_len), path) {
            f.used = calls_file_clock;
            if f.data == null { return null; }
            return f;
        }
        if f.used < calls_files[old].used { old = i; }
    }
    CallsFile* f = &calls_files[old];
    calls_file_free(f);
    memcpy(&f.path[0], path.data, path.len);
    f.path_len = path.len;
    f.used = calls_file_clock;
    str act = ed_path();
    if act.len > 0 && str_equal(act, path) {
        f.len = tb_len();
        f.data = alloc<u8>(f.len + 1);
        tb_copy(0, f.data, f.len);
    } else {
        FileData fd = file_read(path);
        if fd.data == null { return null; }
        f.data = fd.data;
        f.len = cast(i64, fd.len);
    }
    i32 n = 1;
    for i64 i = 0; i < f.len; i++ {
        if f.data[i] == 10 { n++; }
    }
    f.starts = alloc<i64>(n + 1);
    i32 k = 0;
    f.starts[0] = 0;
    for i64 i = 0; i < f.len; i++ {
        if f.data[i] == 10 {
            k++;
            f.starts[k] = i + 1;
        }
    }
    f.nlines = n;
    f.starts[n] = f.len + 1;
    return f;
}

i32 calls_file_nlines(str path) {
    CallsFile* f = calls_file(path);
    if f == null { return 0; }
    return f.nlines;
}

// line l (0-based) of the file, without its line break
str calls_file_line(str path, i32 l) {
    CallsFile* f = calls_file(path);
    if f == null || l < 0 || l >= f.nlines { return ""; }
    i64 st = f.starts[l];
    i64 e = f.starts[l + 1] - 1;
    if e > f.len { e = f.len; }
    if e > st && f.data[e - 1] == 13 { e--; }
    if e < st { e = st; }
    return str_from(f.data + st, cast(i32, e - st));
}

// a line's width in cells, tabs to the next stop
i32 calls_vcols(str ln) {
    i32 vc = 0;
    for i32 b = 0; b < ln.len; b++ {
        if ln.data[b] == 9 { vc = (vc / CALLS_TAB + 1) * CALLS_TAB; }
        else if (ln.data[b] & 0xC0) != 0x80 { vc++; }
    }
    return vc;
}

// the center function's lines: how many, and the widest in cells
private void calls_center_size(i32* nlines, i32* cols) {
    str p = str_from(&calls_center.path[0], calls_center.path_len);
    i32 total = calls_file_nlines(p);
    i32 n = calls_center.l1 - calls_center.l0 + 1;
    if calls_center.l0 + n > total { n = total - calls_center.l0; }
    if n < 0 { n = 0; }
    i32 w = 1;
    for i32 k = 0; k < n; k++ {
        i32 c = calls_vcols(calls_file_line(p, calls_center.l0 + k));
        if c > w { w = c; }
    }
    *nlines = n;
    *cols = w;
}
