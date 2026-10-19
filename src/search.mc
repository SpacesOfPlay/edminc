// search.mc - project-wide search (the ctrl+shift+f sidebar view).
// The file list comes from the picker's scan (shared ignore rules);
// worker threads split it over a shared cursor, scan for the query
// case-insensitively, and append per-file result batches under a
// mutex. Workers signal the main thread through plat_wake; a stale
// generation makes leftover workers exit at their next file. The
// view swaps into the sidebar: query input on top, then file
// headers with their match rows; Enter/Space or a click opens the
// match and selects it.

import thread;

const i32 SEARCH_QUERY_MAX = 256;
private const i32 SEARCH_MAX_HITS = 2000;
private const i32 SEARCH_PREVIEW_MAX = 160;
private const i64 SEARCH_FILE_MAX = 4 * 1024 * 1024;
private const i32 SEARCH_MAX_WORKERS = 8;

bool search_on = false;      // the sidebar shows the search view
bool search_focus = false;   // its input owns typing
private bool sr_in_list = false;   // arrows target the results

// Typing runs the search on its own once it pauses, as the
// reference's view does; Enter runs it at once. The timer is one
// shot and restarts on every change, so a burst of typing searches
// once.
const i32 SEARCH_TIMER = 9;   // 7 is the player's, 8 the terminal probe's
private const i32 SEARCH_MS = 200;
private bool sr_timer_on = false;

u8[SEARCH_QUERY_MAX] sq;
i32 sq_len = 0;
private u8[SEARCH_QUERY_MAX] sq_low;
private UiField sq_field;

private UiField* search_field() {
    ui_field_bind(&sq_field, &sq[0], &sq_len, SEARCH_QUERY_MAX);
    return &sq_field;
}

struct SearchHit {
    i32 path_off;    // into the results arena
    i32 path_len;
    i32 line;        // 0-based
    i32 col;         // byte offset in the line
    i32 prev_off;
    i32 prev_len;
    i32 mcol;        // match byte offset within the preview
    bool ell;        // preview cropped on the left
}

private u8* sr_arena = null;
private i64 sr_alen = 0;
private i64 sr_acap = 0;
private SearchHit* sr_hits = null;
private i32 sr_nhits = 0;
private i32 sr_nfiles = 0;   // distinct files among the hits

// worker coordination
private Mutex sr_mutex;
private bool sr_mutex_ready = false;
private i32 sr_gen = 0;
private i32 sr_next_file = 0;
private i32 sr_workers = 0;
private i32 sr_workers_done = 0;
private bool sr_running = false;
private Thread[SEARCH_MAX_WORKERS] sr_threads;
private i32 sr_nthreads = 0;
private i32 sr_qlen_active = 0;
private u8[SEARCH_QUERY_MAX] sr_q_active;

// file-list snapshot, so a picker rescan cannot race the workers
private u8* sr_files = null;
private i64 sr_files_len = 0;
private i64 sr_files_cap = 0;
private i32* sr_file_off = null;
private i32* sr_file_n = null;
private i32 sr_file_count = 0;
private i32 sr_file_cap = 0;

// results list geometry/selection
private i32 sr_sel = -1;
private i32 sr_scroll = 0;
private f32 sr_scroll_accum = 0.0f;

// folded file headers, keyed by the header's arena path offset
private const i32 SEARCH_MAX_FOLDS = 256;
private const u32 SR_CHEV_RIGHT = 0xEAB6;
private const u32 SR_CHEV_DOWN = 0xEAB4;
private i32[SEARCH_MAX_FOLDS] sr_fold;
private i32 sr_nfold = 0;

private bool search_folded(i32 poff) {
    for i32 i = 0; i < sr_nfold; i++ {
        if sr_fold[i] == poff { return true; }
    }
    return false;
}

private void search_fold_set(i32 poff, bool fold) {
    for i32 i = 0; i < sr_nfold; i++ {
        if sr_fold[i] == poff {
            if !fold {
                sr_fold[i] = sr_fold[sr_nfold - 1];
                sr_nfold--;
            }
            return;
        }
    }
    if fold && sr_nfold < SEARCH_MAX_FOLDS {
        sr_fold[sr_nfold] = poff;
        sr_nfold++;
    }
}

// The preview of a hit: its line [ls, le) from the first non-blank,
// cropped on the left so the match at `at` stays in view, at most
// SEARCH_PREVIEW_MAX bytes. Returns the start; `ell` says it was
// cropped, which the view marks with an ellipsis.
private const i32 SEARCH_CROP_LEFT = 12;

private i32 search_preview(u8* d, i32 ls, i32 le, i32 at, i32* pl, bool* ell) {
    i32 ps = ls;
    while ps < le && (d[ps] == ' ' || d[ps] == 9) { ps++; }
    *ell = false;
    if at - ps > SEARCH_CROP_LEFT {
        i32 c2 = at - SEARCH_CROP_LEFT;
        while c2 > ps && (d[c2] & 0xC0) == 0x80 { c2++; }
        ps = c2;
        *ell = true;
    }
    *pl = le - ps;
    if *pl > SEARCH_PREVIEW_MAX { *pl = SEARCH_PREVIEW_MAX; }
    return ps;
}

// --- results assembly (mutex-guarded) --------------------------------

private i64 sr_arena_push(u8* p, i32 n) {
    if sr_alen + n > sr_acap {
        i64 ncap = sr_acap * 2 + 65536;
        u8* na = alloc<u8>(ncap);
        if sr_arena != null {
            memcpy(na, sr_arena, sr_alen);
            free(sr_arena);
        }
        sr_arena = na;
        sr_acap = ncap;
    }
    i64 off = sr_alen;
    memcpy(sr_arena + off, p, n);
    sr_alen += n;
    return off;
}

// --- the worker ------------------------------------------------------

private void search_worker(void* arg) {
    i32 gen = cast(i32, cast(i64, arg));
    noinit SearchHit[64] batch;
    while true {
        mutex_lock(&sr_mutex);
        bool stale = gen != sr_gen;
        i32 fi = sr_next_file;
        sr_next_file++;
        i32 total = sr_file_count;
        mutex_unlock(&sr_mutex);
        if stale || fi >= total { break; }

        str path = str_from(sr_files + sr_file_off[fi], sr_file_n[fi]);
        FileData fd = file_read(path);
        if fd.data == null { continue; }
        if fd.len > SEARCH_FILE_MAX {
            free(fd.data);
            continue;
        }
        // binary sniff: NUL in the first KB
        i32 sniff = cast(i32, fd.len);
        if sniff > 1024 { sniff = 1024; }
        bool binary = false;
        for i32 i = 0; i < sniff; i++ {
            if fd.data[i] == 0 { binary = true; break; }
        }
        if binary {
            free(fd.data);
            continue;
        }

        i32 nb = 0;
        i32 line = 0;
        i32 line_start = 0;
        i32 qn = sr_qlen_active;
        i32 i = 0;
        while i < fd.len && nb < 64 {
            if fd.data[i] == 10 {
                line++;
                line_start = i + 1;
                i++;
                continue;
            }
            if ascii_lower(fd.data[i]) == sr_q_active[0] && i + qn <= fd.len {
                bool hit = true;
                for i32 k = 1; k < qn; k++ {
                    if ascii_lower(fd.data[i + k]) != sr_q_active[k] {
                        hit = false;
                        break;
                    }
                }
                if hit {
                    i32 le = i;
                    while le < fd.len && fd.data[le] != 10 { le++; }
                    i32 pl = 0;
                    bool ell = false;
                    i32 ps = search_preview(fd.data, line_start, le, i, &pl, &ell);
                    batch[nb] = SearchHit{ 0, path.len, line, i - line_start, ps, pl, i - ps, ell };
                    nb++;
                    i = i + qn;
                    continue;
                }
            }
            i++;
        }

        if nb > 0 {
            mutex_lock(&sr_mutex);
            if gen == sr_gen {
                i64 poff = sr_arena_push(path.data, path.len);
                for i32 b = 0; b < nb && sr_nhits < SEARCH_MAX_HITS; b++ {
                    i64 voff = sr_arena_push(fd.data + batch[b].prev_off, batch[b].prev_len);
                    batch[b].path_off = cast(i32, poff);
                    batch[b].prev_off = cast(i32, voff);
                    sr_hits[sr_nhits] = batch[b];
                    sr_nhits++;
                }
                sr_nfiles++;
            }
            mutex_unlock(&sr_mutex);
        }
        free(fd.data);
    }

    mutex_lock(&sr_mutex);
    bool mine = gen == sr_gen;
    if mine { sr_workers_done++; }
    mutex_unlock(&sr_mutex);
    if mine { plat_wake(); }
}

// --- results that did not come from a scan ----------------------------
// The server answers a references request with locations. This is the
// panel that already knows how to show file-grouped hits with
// previews, so the locations become hits here rather than growing a
// second results view. Buffered first, then sorted by path, so each
// file is read once however the server ordered them.

private const i32 REF_MAX = 512;

private struct RefLoc {
    i32 poff;
    i32 plen;
    i32 line;
    i32 col;      // utf-16 units, as the wire carries it
}

private RefLoc[REF_MAX] sr_ref;
private i32 sr_nref = 0;
private u8* sr_ref_arena = null;
private i64 sr_ref_alen = 0;
private i64 sr_ref_acap = 0;

void search_refs_begin() {
    sr_nref = 0;
    sr_ref_alen = 0;
}

void search_refs_add(str path, i32 line, i32 col) {
    if sr_nref == REF_MAX || path.len == 0 || line < 0 { return; }
    if sr_ref_alen + path.len > sr_ref_acap {
        i64 ncap = sr_ref_acap * 2 + 65536;
        u8* na = alloc<u8>(ncap);
        if sr_ref_arena != null {
            memcpy(na, sr_ref_arena, sr_ref_alen);
            free(sr_ref_arena);
        }
        sr_ref_arena = na;
        sr_ref_acap = ncap;
    }
    memcpy(sr_ref_arena + sr_ref_alen, path.data, path.len);
    sr_ref[sr_nref] = RefLoc{ cast(i32, sr_ref_alen), path.len, line, col };
    sr_ref_alen += path.len;
    sr_nref++;
}

private i32 ref_cmp(RefLoc* a, RefLoc* b) {
    i32 c = str_compare(
        str_from(sr_ref_arena + a.poff, a.plen),
        str_from(sr_ref_arena + b.poff, b.plen));
    if c != 0 { return c; }
    if a.line != b.line { return a.line - b.line; }
    return a.col - b.col;
}

// utf-16 units to a byte offset inside one line of a file that is not
// the open buffer, so lsp_byte_of_col does not apply
private i32 ref_byte_of_col(u8* d, i32 s, i32 e, i32 want) {
    if want <= 0 { return 0; }
    i32 n = e - s;
    if !lsp_pos_utf16 {
        if want > n { return n; }
        return want;
    }
    i32 u = 0;
    i32 i = 0;
    while i < n && u < want {
        u32 cp = utf8_next(d + s, n, &i);
        u++;
        if cp >= SURR_BASE { u++; }
    }
    return i;
}

// Turn the buffered locations into hits and show them.
void search_refs_end(str label) {
    if sr_nref == 0 {
        ed_status("no references found");
        plat_damage();
        return;
    }
    // insertion sort: a reference list is tens of entries, and this
    // groups the file reads as a side effect
    for i32 i = 1; i < sr_nref; i++ {
        RefLoc v = sr_ref[i];
        i32 j = i - 1;
        while j >= 0 && ref_cmp(&sr_ref[j], &v) > 0 {
            sr_ref[j + 1] = sr_ref[j];
            j--;
        }
        sr_ref[j + 1] = v;
    }

    if sr_hits == null { sr_hits = alloc<SearchHit>(SEARCH_MAX_HITS); }
    search_reset_results();
    i32 ln = label.len;
    if ln > SEARCH_QUERY_MAX { ln = SEARCH_QUERY_MAX; }
    memcpy(&sq[0], label.data, ln);
    sq_len = ln;
    sr_qlen_active = ln;

    i32 at = 0;
    while at < sr_nref && sr_nhits < SEARCH_MAX_HITS {
        str path = str_from(sr_ref_arena + sr_ref[at].poff, sr_ref[at].plen);
        i32 end = at;
        while end < sr_nref
            && str_equal(str_from(sr_ref_arena + sr_ref[end].poff, sr_ref[end].plen), path) {
            end++;
        }
        FileData fd = file_read(path);
        if fd.data != null && fd.len <= SEARCH_FILE_MAX {
            i64 poff = sr_arena_push(path.data, path.len);
            bool any = false;
            for i32 r = at; r < end && sr_nhits < SEARCH_MAX_HITS; r++ {
                // find the line
                i32 ls = 0;
                i32 l = 0;
                i32 i = 0;
                while i < fd.len && l < sr_ref[r].line {
                    if fd.data[i] == 10 {
                        l++;
                        ls = i + 1;
                    }
                    i++;
                }
                if l != sr_ref[r].line { continue; }
                i32 le = ls;
                while le < fd.len && fd.data[le] != 10 { le++; }
                i32 col = ls + ref_byte_of_col(fd.data, ls, le, sr_ref[r].col);
                i32 pl = 0;
                bool ell = false;
                i32 ps = search_preview(fd.data, ls, le, col, &pl, &ell);
                i64 voff = sr_arena_push(fd.data + ps, pl);
                sr_hits[sr_nhits] = SearchHit{ cast(i32, poff), path.len,
                    sr_ref[r].line, col - ls, cast(i32, voff), pl, col - ps, ell };
                sr_nhits++;
                any = true;
            }
            if any { sr_nfiles++; }
        }
        if fd.data != null { free(fd.data); }
        at = end;
    }
    sr_running = false;
    search_open_view();
    sr_in_list = true;
    sr_sel = 0;
    plat_damage();
}

// --- lifecycle -------------------------------------------------------

private void search_reset_results() {
    sr_nhits = 0;
    sr_nfiles = 0;
    sr_alen = 0;
    sr_sel = -1;
    sr_scroll = 0;
    sr_nfold = 0;
}

private void search_join_workers() {
    when !os(wasm) {
        for i32 i = 0; i < sr_nthreads; i++ {
            thread_join(&sr_threads[i]);
        }
    }
    sr_nthreads = 0;
}

void search_start() {
    if sq_len == 0 { return; }
    if !sr_mutex_ready {
        mutex_init(&sr_mutex);
        sr_mutex_ready = true;
    }
    if sr_hits == null { sr_hits = alloc<SearchHit>(SEARCH_MAX_HITS); }
    mutex_lock(&sr_mutex);
    sr_gen++;
    i32 gen = sr_gen;
    mutex_unlock(&sr_mutex);
    search_join_workers();

    search_reset_results();
    for i32 i = 0; i < sq_len; i++ { sr_q_active[i] = ascii_lower(sq[i]); }
    sr_qlen_active = sq_len;
    pick_scan();
    i32 fc = pick_file_count();
    if fc > sr_file_cap {
        if sr_file_off != null { free(sr_file_off); }
        if sr_file_n != null { free(sr_file_n); }
        sr_file_off = alloc<i32>(fc);
        sr_file_n = alloc<i32>(fc);
        sr_file_cap = fc;
    }
    sr_files_len = 0;
    for i32 i = 0; i < fc; i++ {
        str p = pick_file_path(i);
        if sr_files_len + p.len > sr_files_cap {
            i64 ncap = sr_files_cap * 2 + 65536;
            u8* na = alloc<u8>(ncap);
            if sr_files != null {
                memcpy(na, sr_files, sr_files_len);
                free(sr_files);
            }
            sr_files = na;
            sr_files_cap = ncap;
        }
        memcpy(sr_files + sr_files_len, p.data, p.len);
        sr_file_off[i] = cast(i32, sr_files_len);
        sr_file_n[i] = p.len;
        sr_files_len += p.len;
    }
    sr_file_count = fc;
    sr_next_file = 0;
    sr_workers_done = 0;
    sr_running = true;

    when os(wasm) {
        // no workers in a browser: one pass on the main thread, over
        // the one project the page holds
        sr_workers = 1;
        search_worker(cast(void*, cast(i64, gen)));
    } else {
        i32 n = cpu_count();
        if n < 1 { n = 1; }
        if n > SEARCH_MAX_WORKERS { n = SEARCH_MAX_WORKERS; }
        sr_workers = n;
        for i32 i = 0; i < n; i++ {
            thread_create(&sr_threads[i], search_worker, cast(void*, cast(i64, gen)));
        }
        sr_nthreads = n;
    }
    plat_damage();
}

// Workers take files off a shared cursor and append each file's hits
// as one batch, so the list comes out in completion order: the same
// search twice can list the files in a different order. Sorted once
// the last worker is in, which is late enough not to reorder rows
// under the reader while results are still streaming.
private i32 hit_cmp(i32 a, i32 b) {
    i32 c = str_compare(
        str_from(sr_arena + sr_hits[a].path_off, sr_hits[a].path_len),
        str_from(sr_arena + sr_hits[b].path_off, sr_hits[b].path_len));
    if c != 0 { return c; }
    if sr_hits[a].line != sr_hits[b].line {
        return sr_hits[a].line - sr_hits[b].line;
    }
    return sr_hits[a].col - sr_hits[b].col;
}

private void hit_sift(i32 root, i32 n) {
    while true {
        i32 big = root;
        i32 l = root * 2 + 1;
        i32 r = l + 1;
        if l < n && hit_cmp(l, big) > 0 { big = l; }
        if r < n && hit_cmp(r, big) > 0 { big = r; }
        if big == root { return; }
        SearchHit t = sr_hits[root];
        sr_hits[root] = sr_hits[big];
        sr_hits[big] = t;
        root = big;
    }
}

// heapsort: in place, and n log n at the 2000-hit cap
private void search_sort_hits() {
    i32 n = sr_nhits;
    for i32 i = n / 2 - 1; i >= 0; i-- { hit_sift(i, n); }
    for i32 e = n - 1; e > 0; e-- {
        SearchHit t = sr_hits[0];
        sr_hits[0] = sr_hits[e];
        sr_hits[e] = t;
        hit_sift(0, e);
    }
}

private void search_touch() {
    if sr_timer_on { plat_kill_timer(SEARCH_TIMER); }
    plat_set_timer(SEARCH_TIMER, SEARCH_MS);
    sr_timer_on = true;
}

private void search_untouch() {
    if !sr_timer_on { return; }
    plat_kill_timer(SEARCH_TIMER);
    sr_timer_on = false;
}

// a search is due once typing pauses (tests read it)
bool search_pending() {
    return sr_timer_on;
}

// an emptied query empties the list: a search in flight is dropped
// (its workers exit at their next file) and nothing replaces it
private void search_clear() {
    if sr_mutex_ready {
        mutex_lock(&sr_mutex);
        sr_gen++;
        mutex_unlock(&sr_mutex);
    }
    search_join_workers();
    sr_running = false;
    search_reset_results();
    plat_damage();
}

void search_timer() {
    search_untouch();
    if !search_on { return; }
    if sq_len == 0 {
        search_clear();
        return;
    }
    search_start();
}

// synchronous variant for headless tests
void search_run_blocking() {
    search_start();
    search_join_workers();
    sr_running = false;
    search_sort_hits();
}

// Wait for a search already in flight, without starting another. A
// headless caller needs this to reach a settled view: while workers
// are running the hit count and the "searching" line move on their
// own, so two runs of the same input do not agree.
void search_settle() {
    if !sr_running { return; }
    search_join_workers();
    sr_running = false;
    search_sort_hits();
}

// main-thread wake from the workers. Any thread can post a wake now
// (the LSP reader does), so this runs before the first search too:
// sr_mutex is only live once search_start has initialized it.
void search_wake() {
    if !sr_mutex_ready { return; }
    mutex_lock(&sr_mutex);
    bool done = sr_workers_done == sr_workers;
    mutex_unlock(&sr_mutex);
    if done && sr_running {
        sr_running = false;
        search_sort_hits();
    }
    plat_damage();
}

i32 search_hit_count() {
    return sr_nhits;
}

str search_hit_path(i32 i) {
    return str_from(sr_arena + sr_hits[i].path_off, sr_hits[i].path_len);
}

str search_hit_preview(i32 i) {
    return str_from(sr_arena + sr_hits[i].prev_off, sr_hits[i].prev_len);
}

i32 search_hit_mcol(i32 i) {
    return sr_hits[i].mcol;
}

bool search_hit_ell(i32 i) {
    return sr_hits[i].ell;
}

i32 search_hit_line(i32 i) {
    return sr_hits[i].line;
}

// Ctrl+Shift+F with a selection: the selection is the query and the
// search runs at once, as the find widget already does for Ctrl+F.
void search_open_with(str q) {
    search_open_view();
    i32 n = q.len;
    if n > SEARCH_QUERY_MAX { n = SEARCH_QUERY_MAX; }
    memcpy(&sq[0], q.data, n);
    sq_len = n;
    ui_field_end(search_field());
    search_untouch();
    search_start();
}

void search_open_view() {
    tree_on = true;
    search_on = true;
    search_focus = true;
    sr_in_list = false;
    tree_focus = false;
    find_close();
    plat_damage();
}

void search_close_view() {
    search_untouch();
    search_on = false;
    search_focus = false;
    plat_damage();
}

// --- result rows: file headers + their hits --------------------------
// row layout is derived on the fly: a header before every hit whose
// file differs from the previous hit's

i32 search_row_count() {
    i32 rows = 0;
    for i32 i = 0; i < sr_nhits; i++ {
        if i == 0 || sr_hits[i].path_off != sr_hits[i - 1].path_off {
            rows++;
        }
        if !search_folded(sr_hits[i].path_off) { rows++; }
    }
    return rows;
}

// a row lookup's answer for "no such row", below every folded-header
// encoding (-1 - i)
private const i32 SR_NO_ROW = -1073741824;

// hit index for a row, or -1 for a header row
private i32 search_row_hit(i32 row) {
    i32 r = 0;
    for i32 i = 0; i < sr_nhits; i++ {
        if i == 0 || sr_hits[i].path_off != sr_hits[i - 1].path_off {
            if r == row { return -1 - i; }   // header of hit i's file
            r++;
        }
        if search_folded(sr_hits[i].path_off) { continue; }
        if r == row { return i; }
        r++;
    }
    return SR_NO_ROW;
}

// take_focus moves typing to the editor (enter/click); arrow
// navigation previews the hit and keeps the list focused
private void search_open_hit(i32 i, bool take_focus) {
    if i < 0 || i >= sr_nhits { return; }
    SearchHit* h = &sr_hits[i];
    // taking focus is the committed jump; previewing with the arrows
    // would otherwise fill the history with every row passed over
    if take_focus { ed_nav_mark(); }
    if !ed_view_file(str_from(sr_arena + h.path_off, h.path_len)) { return; }
    i64 a = tb_line_start(h.line) + h.col;
    ed_set_sel(a, a + sr_qlen_active);
    ed_center_caret();
    if take_focus { search_focus = false; }
}

// selection moved onto a row: open hits, leave headers alone
private void search_preview_row(i32 row) {
    i32 v = search_row_hit(row);
    if v >= 0 { search_open_hit(v, false); }
}

private void search_activate_row(i32 row, bool take_focus) {
    i32 v = search_row_hit(row);
    if v >= 0 {
        search_open_hit(v, take_focus);
    } else if v > SR_NO_ROW {
        i32 poff = sr_hits[-1 - v].path_off;
        search_fold_set(poff, !search_folded(poff));
        plat_damage();
    }
}

// --- input -----------------------------------------------------------

bool search_char(u32 cp) {
    if !search_focus { return false; }
    if sr_in_list {
        if cp == 13 || cp == 32 {
            search_activate_row(sr_sel, true);
        }
        return true;
    }
    if cp == 13 {
        search_untouch();
        search_start();
        return true;
    }
    if ui_field_char(search_field(), cp) {
        search_touch();
        plat_damage();
    }
    return true;
}

private i32 search_row_h() {
    // reference list rows; the mono-derived fallback covers stubs
    if font_ui_row > 0 { return font_ui_row; }
    return font_line_h * 5 / 4;
}

private i32 search_list_top() {
    return font_line_h / 5 + ui_input_h() + font_line_h + font_line_h / 4;
}

private void search_sel_visible() {
    if sr_sel < 0 { return; }
    i32 rh = search_row_h();
    i32 top = search_list_top() + sr_sel * rh - sr_scroll;
    if top < search_list_top() { sr_scroll += top - search_list_top(); }
    i32 view_h = sidebar_bottom();
    i32 bot = top + rh - view_h;
    if bot > 0 { sr_scroll += bot; }
    if sr_scroll < 0 { sr_scroll = 0; }
}

bool search_key(i32 key, i32 mods) {
    if !search_focus { return false; }
    if !sr_in_list {
        bool changed = false;
        if ui_field_key(search_field(), key, mods, &changed) {
            if changed { search_touch(); }
            plat_damage();
            return true;
        }
    }
    if mods != 0 { return false; }
    if key == K_ESCAPE {
        search_close_view();
        return true;
    }
    i32 rows = search_row_count();
    if key == K_DOWN {
        if !sr_in_list {
            if rows > 0 {
                sr_in_list = true;
                sr_sel = 0;
                search_sel_visible();
                search_preview_row(sr_sel);
                plat_damage();
            }
        } else if sr_sel + 1 < rows {
            sr_sel++;
            search_sel_visible();
            search_preview_row(sr_sel);
            plat_damage();
        }
        return true;
    }
    if key == K_UP {
        if sr_in_list {
            if sr_sel == 0 {
                sr_in_list = false;
            } else {
                sr_sel--;
                search_sel_visible();
                search_preview_row(sr_sel);
            }
            plat_damage();
        }
        return true;
    }
    if (key == K_LEFT || key == K_RIGHT) && sr_in_list {
        i32 v = search_row_hit(sr_sel);
        if v >= 0 && key == K_LEFT {
            // from a hit row to its file header
            while sr_sel > 0 && search_row_hit(sr_sel) >= 0 { sr_sel--; }
            search_sel_visible();
            plat_damage();
        } else if v < 0 && v > SR_NO_ROW {
            i32 poff = sr_hits[-1 - v].path_off;
            search_fold_set(poff, key == K_LEFT);
            search_sel_visible();
            plat_damage();
        }
        return true;
    }
    return true;
}

void search_scroll_by(f32 dy) {
    sr_scroll_accum += dy;
    i32 step = cast(i32, sr_scroll_accum);
    if step == 0 { return; }
    sr_scroll_accum -= cast(f32, step);
    sr_scroll += step;
    i32 maxs = search_list_top() + search_row_count() * search_row_h() - (sidebar_bottom());
    if maxs < 0 { maxs = 0; }
    if sr_scroll > maxs { sr_scroll = maxs; }
    if sr_scroll < 0 { sr_scroll = 0; }
    plat_damage();
}

void search_mouse(i32 x, i32 y) {
    search_focus = true;
    find_close();
    i32 lt = search_list_top();
    if y < lt {
        sr_in_list = false;
        plat_damage();
        return;
    }
    i32 row = (y - lt + sr_scroll) / search_row_h();
    if row >= 0 && row < search_row_count() {
        sr_in_list = true;
        sr_sel = row;
        search_activate_row(row, false);
    }
    plat_damage();
}

// --- render ----------------------------------------------------------

void search_render() {
    i32 lh = font_line_h;
    i32 tw = tree_w();
    i32 pad = lh / 2;
    draw_rect(0.0f, 0.0f, cast(f32, tw), cast(f32, sidebar_bottom()), T_SIDEBAR_BG);

    i32 iy = lh / 5;
    ui_input(pad / 2, iy, tw - pad, search_field(), "search", search_focus && !sr_in_list && caret_on);

    // status line under the input
    noinit u8[96] sb;
    i32 sn = 0;
    if sr_running {
        str m = "searching...";
        memcpy(&sb[0], m.data, m.len);
        sn = m.len;
    } else if sq_len > 0 && sr_qlen_active > 0 {
        sn = fmt_i32(&sb[0], sr_nhits);
        str m1 = " results in ";
        memcpy(&sb[sn], m1.data, m1.len);
        sn += m1.len;
        sn += fmt_i32(&sb[sn], sr_nfiles);
        str m2 = " files";
        memcpy(&sb[sn], m2.data, m2.len);
        sn += m2.len;
    }

    i32 rh = search_row_h();
    i32 lt = search_list_top();
    i32 view_h = sidebar_bottom();
    i32 row = 0;
    for i32 i = 0; i < sr_nhits; i++ {
        bool header = i == 0 || sr_hits[i].path_off != sr_hits[i - 1].path_off;
        if header {
            i32 y = lt + row * rh - sr_scroll;
            if y >= view_h { break; }
            if y + rh > lt {
                // basename, dim path style
                str p = search_hit_path(i);
                i32 base = path_base_off(p.data, p.len);
                i32 ty = y + (rh - lh) / 2;
                if row == sr_sel && sr_in_list {
                    draw_rect(0.0f, cast(f32, y), cast(f32, tw), cast(f32, rh), T_LIST_SEL_INACTIVE);
                }
                u32 chev = SR_CHEV_DOWN;
                if search_folded(sr_hits[i].path_off) { chev = SR_CHEV_RIGHT; }
                font_draw(chev, cast(f32, pad / 2), cast(f32, ty), T_FG);
                u32 icol = 0;
                u32 ico = theme_file_icon(str_from(p.data + base, p.len - base), &icol);
                font_draw(ico, cast(f32, pad / 2 + lh * 3 / 5), cast(f32, ty), icol);
                // the UI face, baseline-aligned with the icons
                f32 hy = cast(f32, ty + font_ascent + 1 - font_ui_ascent);
                ignore font_draw_ui_text(str_from(p.data + base, p.len - base),
                    cast(f32, pad / 2 + lh * 3 / 5 + lh * 9 / 10), hy, cast(f32, tw - pad), T_FG);
            }
            row++;
        }
        if search_folded(sr_hits[i].path_off) { continue; }
        i32 y = lt + row * rh - sr_scroll;
        if y >= view_h { break; }
        if y + rh > lt {
            if row == sr_sel && sr_in_list {
                draw_rect(0.0f, cast(f32, y), cast(f32, tw), cast(f32, rh), T_LIST_SEL);
            }
            // preview in the UI face: the match boxed by measured
            // pixel widths, a leading ellipsis when cropped left
            i32 hx = pad / 2 + lh * 3 / 5 + lh * 9 / 10;
            f32 px = cast(f32, hx);
            f32 max_px = cast(f32, tw - pad);
            f32 ny = cast(f32, y + (rh - font_ui_h) / 2);
            if sr_hits[i].ell {
                u8[3] ell = { 0xE2, 0x80, 0xA6 };
                px = font_draw_ui_text(str_from(&ell[0], 3), px, ny, max_px, T_DIM);
            }
            u8* pv = sr_arena + sr_hits[i].prev_off;
            i32 pn = sr_hits[i].prev_len;
            i32 mc = sr_hits[i].mcol;
            if mc > pn { mc = pn; }
            i32 me = mc + sr_qlen_active;
            if me > pn { me = pn; }
            f32 pre_w = cast(f32, font_ui_text_w(str_from(pv, mc)));
            f32 m_w = cast(f32, font_ui_text_w(str_from(pv + mc, me - mc)));
            if px + pre_w < max_px && m_w > 0.0f {
                f32 hw = m_w;
                if px + pre_w + hw > max_px { hw = max_px - px - pre_w; }
                draw_rect(px + pre_w, ny, hw, cast(f32, font_ui_h), T_MATCH_BG);
            }
            ignore font_draw_ui_text(str_from(pv, pn), px, ny, max_px, T_FG);
        }
        row++;
    }

    if sn > 0 {
        i32 sy = iy + ui_input_h() + 2;
        if lt - sy >= lh {
            ignore font_draw_ui_text(str_from(&sb[0], sn), cast(f32, pad / 2), cast(f32, sy),
                cast(f32, tw - pad), T_DIM);
        }
    }
}
