// tree.mc - the file tree sidebar (ctrl+b). Directories list their
// children lazily on first expansion; the visible rows are a flat
// array rebuilt on every toggle. Clicking a file opens it through
// ed_open_file; the ignore rules are shared with the picker.
// Row metrics follow the measured reference (doc/TECH_DOC.md "UI system"):
// sidebar 15*lh wide, rows 5/4*lh, one lh of indent per level.

private const i32 TREE_MAX_ROWS = 4096;
private const i32 TREE_MAX_DEPTH = 24;
private const i32 TREE_PATH_MAX = 512;
private const i32 TREE_MAX_OPEN = 128;   // expanded directories

// codicon codepoints (assets/codicon.ttf; THIRD_PARTY.md)
private const u32 ICO_FILE = 0xEA7B;
private const u32 ICO_FOLDER = 0xEA83;
private const u32 ICO_FOLDER_OPEN = 0xEAF7;
private const u32 ICO_CHEV_RIGHT = 0xEAB6;
private const u32 ICO_CHEV_DOWN = 0xEAB4;

// the panel's scrollbar, mirroring the document's (view.mc), in its color
private const i32 TREE_SCROLL_W = 6;
private const i32 TREE_SCROLL_PAD = 4;
private const i32 TREE_SCROLL_MIN = 24;

bool tree_on = true;
bool tree_focus = false;   // arrows/enter navigate the tree while set

// What the sidebar lists. The rows, the scrolling, the selection and
// the renderer are the same either way; only where the rows come from
// differs, so the changes view is a second source, not a second panel.
const i32 SIDE_FILES = 0;
const i32 SIDE_CHANGES = 1;
i32 tree_mode = SIDE_FILES;

// the changes view's two groups, each collapsible like a folder
private bool tr_staged_open = true;
private bool tr_unstaged_open = true;

// per window (parked in WinCtx): the tree content is shared, but each
// window scrolls and selects its own row
i32 tr_sel = -1;
i32 tr_scroll = 0;          // pixels
f32 tr_scroll_accum = 0.0f;

struct TreeRow {
    i32 path_off;    // full relative path in the arena
    i32 path_len;
    i32 name_off;    // basename offset within the path
    i32 depth;
    bool is_dir;
    bool expanded;
    // the changes view only: a group heading rather than a file, and
    // which entry of the changed list a file row stands for
    bool hdr;
    i32 gidx;
    bool ign;        // gitignored, drawn dimmed (gitignore.mc)
    bool edit;       // the name is being typed: a new entry, or a rename
}

private u8* tr_arena = null;
private i64 tr_alen = 0;
private i64 tr_acap = 0;
private TreeRow* tr_rows = null;
private i32 tr_count = 0;

// expanded-directory set: paths in their own arena
private u8* tr_open_data = null;
private i64 tr_open_len = 0;
private i64 tr_open_cap = 0;
private i32[TREE_MAX_OPEN] tr_open_off;
private i32[TREE_MAX_OPEN] tr_open_n;
private i32 tr_nopen = 0;

private i32 tr_w_px = 0;   // 0 = the default width

// Clamped at read time, not at set time: a window narrower than the
// sidebar would otherwise leave the editor area negative (pane
// rects run right to left, and the clip window inverts). The stored
// width is kept, so widening the window restores it.
i32 tree_w() {
    i32 w = tr_w_px;
    if w <= 0 { w = font_line_h * 15; }
    i32 hi = g_w * 2 / 3;
    if hi > 0 && w > hi { w = hi; }
    return w;
}

// the dragged width as set, 0 for the default; the session keeps it
i32 tree_w_px() {
    return tr_w_px;
}

// sidebar resize (the divider drag); clamped to keep both the
// sidebar and the editor usable
void tree_set_w(i32 w) {
    i32 lo = font_line_h * 6;
    i32 hi = g_w * 2 / 3;
    if w < lo { w = lo; }
    if w > hi { w = hi; }
    tr_w_px = w;
}

// measured reference metrics: indent 0.6*lh per level, names
// 7/8*lh right of the icon column
private i32 tree_indent() {
    return font_line_h * 3 / 5;
}

private i32 tree_name_off() {
    return font_line_h * 9 / 10;
}

i32 content_left() {
    if !tree_on { return 0; }
    return tree_w();
}

private bool tree_is_open(u8* p, i32 n) {
    for i32 i = 0; i < tr_nopen; i++ {
        if tr_open_n[i] == n
            && str_equal(str_from(tr_open_data + tr_open_off[i], n), str_from(p, n)) {
            return true;
        }
    }
    return false;
}

private void tree_open_add(u8* p, i32 n) {
    if tr_nopen == TREE_MAX_OPEN { return; }
    if tr_open_len + n > tr_open_cap {
        i64 ncap = tr_open_cap * 2 + 4096;
        u8* na = alloc<u8>(ncap);
        if tr_open_data != null {
            memcpy(na, tr_open_data, tr_open_len);
            free(tr_open_data);
        }
        tr_open_data = na;
        tr_open_cap = ncap;
    }
    memcpy(tr_open_data + tr_open_len, p, n);
    tr_open_off[tr_nopen] = cast(i32, tr_open_len);
    tr_open_n[tr_nopen] = n;
    tr_open_len += n;
    tr_nopen++;
}

private void tree_open_remove(u8* p, i32 n) {
    for i32 i = 0; i < tr_nopen; i++ {
        if tr_open_n[i] == n
            && str_equal(str_from(tr_open_data + tr_open_off[i], n), str_from(p, n)) {
            for i32 j = i; j < tr_nopen - 1; j++ {
                tr_open_off[j] = tr_open_off[j + 1];
                tr_open_n[j] = tr_open_n[j + 1];
            }
            tr_nopen--;
            return;
        }
    }
}

// the expanded-directory set, for the session to persist across restarts
i32 tree_open_count() { return tr_nopen; }
str tree_open_at(i32 i) {
    if i < 0 || i >= tr_nopen { return str_from(tr_open_data, 0); }
    return str_from(tr_open_data + tr_open_off[i], tr_open_n[i]);
}
void tree_open_clear() {
    tr_nopen = 0;
    tr_open_len = 0;
}
void tree_open_add_path(str p) {
    tree_open_add(p.data, p.len);
}

private void tree_row_push(u8* path, i32 n, i32 name_off, i32 depth, bool is_dir, bool expanded) {
    tree_row_push_ign(path, n, name_off, depth, is_dir, expanded, false);
}

private void tree_row_push_ign(u8* path, i32 n, i32 name_off, i32 depth, bool is_dir, bool expanded, bool ign) {
    if tr_count == TREE_MAX_ROWS { return; }
    if tr_alen + n > tr_acap {
        i64 ncap = tr_acap * 2 + 65536;
        u8* na = alloc<u8>(ncap);
        if tr_arena != null {
            memcpy(na, tr_arena, tr_alen);
            free(tr_arena);
        }
        tr_arena = na;
        tr_acap = ncap;
    }
    memcpy(tr_arena + tr_alen, path, n);
    tr_rows[tr_count] = TreeRow{ cast(i32, tr_alen), n, name_off, depth, is_dir, expanded,
        false, -1, ign, tr_edit == TREE_EDIT_RENAME && tree_edit_is(path, n) };
    tr_alen += n;
    tr_count++;
}

// case-insensitive name order, matching the reference
private bool tree_name_lt(str a, str b) {
    i32 n = a.len;
    if b.len < n { n = b.len; }
    for i32 i = 0; i < n; i++ {
        u8 ca = ascii_lower(a.data[i]);
        u8 cb = ascii_lower(b.data[i]);
        if ca != cb { return ca < cb; }
    }
    return a.len < b.len;
}

private void tree_sort(DirList* l) {
    for i32 i = 1; i < l.count; i++ {
        str v = l.items[i];
        i32 j = i;
        while j > 0 && tree_name_lt(v, l.items[j - 1]) {
            l.items[j] = l.items[j - 1];
            j--;
        }
        l.items[j] = v;
    }
}

// `ign`: the folder at pb is gitignored, and so is all it holds
private void tree_walk(u8* pb, i32 plen, i32 depth, bool ign) {
    if depth >= TREE_MAX_DEPTH { return; }
    str d = ".";
    if plen > 0 { d = str_from(pb, plen); }

    // a new entry being named in this folder: its row comes first
    if (tr_edit == TREE_EDIT_FILE || tr_edit == TREE_EDIT_FOLDER) && tree_edit_is(pb, plen) {
        tree_row_push_ign(pb, plen, plen, depth, tr_edit == TREE_EDIT_FOLDER, false, ign);
        tr_rows[tr_count - 1].edit = true;
    }
    DirList dl = plat_dir_list(d, true);
    dir_sort(&dl);
    tree_sort(&dl);
    for i32 i = 0; i < dl.count; i++ {
        str nm = dl.items[i];
        if plen + 1 + nm.len >= TREE_PATH_MAX { continue; }
        i32 n = plen;
        if n > 0 {
            pb[n] = '/';
            n++;
        }
        memcpy(pb + n, nm.data, nm.len);
        str path = str_from(pb, n + nm.len);
        bool git = ign || ign_match(path, true);
        if ign_tree_hidden(path, git) { continue; }
        bool open = tree_is_open(pb, n + nm.len);
        tree_row_push_ign(pb, n + nm.len, n, depth, true, open, git);
        if open { tree_walk(pb, n + nm.len, depth + 1, git); }
    }
    dir_list_free(&dl);

    DirList fl = plat_dir_list(d, false);
    dir_sort(&fl);
    tree_sort(&fl);
    for i32 i = 0; i < fl.count; i++ {
        str nm = fl.items[i];
        if plen + 1 + nm.len >= TREE_PATH_MAX { continue; }
        i32 n = plen;
        if n > 0 {
            pb[n] = '/';
            n++;
        }
        memcpy(pb + n, nm.data, nm.len);
        str path = str_from(pb, n + nm.len);
        bool git = ign || ign_match(path, false);
        if ign_tree_hidden(path, git) { continue; }
        tree_row_push_ign(pb, n + nm.len, n, depth, false, false, git);
    }
    dir_list_free(&fl);
}

// the changed files, flat: every row a file, nothing to expand. The
// order is git's, which the list keeps rather than imposing its own.
// one group: its heading, then its files while it is open. The heading
// is a row like a folder's, so the arrow keys fold it the same way.
// A heading stands whether or not the column has anything under it: a
// view with neither says the working tree is clean, where an empty
// panel only says the view has nothing to tell.
private void tree_build_group(str label, bool staged, bool open) {
    i32 n = git_changed_count();
    tree_row_push(label.data, label.len, 0, 0, true, open);
    tr_rows[tr_count - 1].hdr = true;
    if !open { return; }
    for i32 i = 0; i < n; i++ {
        if git_changed_staged(i) != staged { continue; }
        str p = git_changed_path(i);
        if p.len == 0 || p.len > TREE_PATH_MAX { continue; }
        tree_row_push(p.data, p.len, path_base_off(p.data, p.len), 1, false, false);
        tr_rows[tr_count - 1].gidx = i;
    }
}

private void tree_build_changes() {
    tree_build_group("Staged Changes", true, tr_staged_open);
    tree_build_group("Changes", false, tr_unstaged_open);
}

void tree_build() {
    if tr_rows == null { tr_rows = alloc<TreeRow>(TREE_MAX_ROWS); }
    tr_count = 0;
    tr_alen = 0;
    if tree_mode == SIDE_CHANGES {
        tree_build_changes();
        if tr_sel >= tr_count { tr_sel = tr_count - 1; }
        tree_scroll_clamp();
        plat_damage();
        return;
    }
    ign_reset();
    noinit u8[TREE_PATH_MAX] pb;
    tree_walk(&pb[0], 0, 0, false);
    tree_scroll_clamp();
    plat_damage();
}

// the viewport changed size (a resize, the status bar, the dpi): the
// same staleness as a rebuild, from the other side
void tree_viewport_changed() {
    tree_scroll_clamp();
}

// the first row that is a file: where the keyboard lands in the
// changes view, since the top row there is a group heading and Enter
// on it would fold the group rather than open anything
private i32 tree_first_file() {
    for i32 i = 0; i < tr_count; i++ {
        if !tr_rows[i].hdr { return i; }
    }
    return 0;
}

// keyboard focus into the tree; first use selects the top row
void tree_take_focus() {
    tree_focus = true;
    if tr_sel < 0 && tr_count > 0 { tree_select(tree_first_file()); }
    plat_damage();
}

i32 tree_sel_row() {
    return tr_sel;
}

void tree_toggle() {
    tree_on = !tree_on;
    if tree_on { tree_build(); }
    plat_damage();
}

// Ctrl+Shift+G, the way the reference's shortcut behaves: show the
// changes and put the keyboard in them, and give the focus back when
// they are already showing.
void tree_show_changes() {
    if tree_mode == SIDE_CHANGES && tr_count > 0 { return; }
    tree_mode = SIDE_CHANGES;
    tr_sel = -1;
    hist_focus = false;
    git_status_touch();   // the list is only as fresh as the last run
    if !hist_folded { hist_ensure(); }
    tree_build();
}

// back to the file tree, on the sidebar's own shortcut
void tree_show_files() {
    if tree_mode == SIDE_FILES { return; }
    tree_mode = SIDE_FILES;
    tr_sel = -1;
    hist_focus = false;
    tree_build();
}

// the status came back: the list is built from it, so it follows
void tree_note_status() {
    if !tree_on || tree_mode != SIDE_CHANGES { return; }
    tree_build();
    // the view is opened before the status has run, so the rows land
    // after the focus does and there was nothing to select then
    if tree_focus && tr_sel < 0 && tr_count > 0 { tree_select(tree_first_file()); }
}

// test hooks + click handling share row addressing
i32 tree_row_count() {
    return tr_count;
}

str tree_row_path(i32 i) {
    return str_from(tr_arena + tr_rows[i].path_off, tr_rows[i].path_len);
}

// whether row i is gitignored, and so dimmed
bool tree_row_ign(i32 i) {
    if i < 0 || i >= tr_count { return false; }
    return tr_rows[i].ign;
}

bool tree_row_is_dir(i32 i) {
    return tr_rows[i].is_dir;
}

// a group heading in the changes view, rather than a file
bool tree_row_is_hdr(i32 i) {
    if i < 0 || i >= tr_count { return false; }
    return tr_rows[i].hdr;
}

// a directory row toggles expansion; a file row opens. The
// selection follows the row across the rebuild.
void tree_row_activate(i32 i) {
    if i < 0 || i >= tr_count { return; }
    TreeRow* r = &tr_rows[i];
    if r.edit { return; }
    if r.hdr {
        // a group heading folds what is under it; the selection stays
        // on the heading, which does not move
        if str_equal(tree_row_path(i), "Staged Changes") {
            tr_staged_open = !tr_staged_open;
        } else {
            tr_unstaged_open = !tr_unstaged_open;
        }
        tree_build();
        if tr_sel >= tr_count { tr_sel = tr_count - 1; }
        return;
    }
    if r.is_dir {
        noinit u8[TREE_PATH_MAX] p;
        i32 n = r.path_len;
        memcpy(&p[0], tr_arena + r.path_off, n);
        if r.expanded {
            tree_open_remove(&p[0], n);
        } else {
            tree_open_add(&p[0], n);
        }
        tree_build();
        tr_sel = tree_find_path(&p[0], n);
        return;
    }
    if tree_mode == SIDE_CHANGES {
        ed_diff_open(tree_row_path(i));
        return;
    }
    ignore ed_view_file(tree_row_path(i));
}

// keys while the tree has focus; only unmodified keys are claimed
bool tree_key(i32 key, i32 mods) {
    // the menu key, and Shift+F10, the system's other key for it
    if tree_mode == SIDE_FILES
        && ((key == K_MENU && mods == 0) || (key == K_F10 && mods == MOD_SHIFT)) {
        tree_menu_key();
        return true;
    }
    if mods != 0 { return false; }
    if key == K_ESCAPE {
        tree_focus = false;
        plat_damage();
        return true;
    }
    if tree_mode == SIDE_CHANGES && hist_focus && !hist_folded {
        if key == K_UP && hist_sel_row() <= 0 {
            // up out of the graph, into the changes above it
            hist_focus = false;
            if tr_count > 0 { tree_select(tr_count - 1); }
            plat_damage();
            return true;
        }
        if hist_key(key, mods) { return true; }
        return true;
    }
    if key == K_DOWN && tree_mode == SIDE_CHANGES && !hist_folded
        && tr_sel >= tr_count - 1 && hist_row_count() > 0 {
        // down past the last change, into the graph
        hist_focus = true;
        if hist_sel_row() < 0 { hist_select(0); }
        plat_damage();
        return true;
    }
    if key == K_UP || key == K_DOWN {
        if tr_count == 0 { return true; }
        i32 d = 1;
        if key == K_UP { d = -1; }
        i32 ns = tr_sel + d;
        if ns < 0 { ns = 0; }
        if ns >= tr_count { ns = tr_count - 1; }
        tree_select(ns);
        return true;
    }
    if key == K_PGUP || key == K_PGDN {
        f32 d = cast(f32, tree_view_h());
        if key == K_PGUP { d = -d; }
        tree_scroll_by(d);
        return true;
    }
    if key == K_F2 && tree_mode == SIDE_FILES {
        tree_rename_row(tr_sel);
        return true;
    }
    if key == K_DELETE && tree_mode == SIDE_FILES {
        tree_delete_row(tr_sel);
        return true;
    }
    if key == K_HOME { tree_select(0); return true; }
    if key == K_END { tree_select(tr_count - 1); return true; }
    if key == K_RIGHT {
        if tr_sel >= 0 && tr_sel < tr_count && tr_rows[tr_sel].is_dir {
            if !tr_rows[tr_sel].expanded {
                tree_row_activate(tr_sel);
            } else if tr_sel + 1 < tr_count
                && tr_rows[tr_sel + 1].depth > tr_rows[tr_sel].depth {
                tree_select(tr_sel + 1);
            }
        }
        plat_damage();
        return true;
    }
    if key == K_LEFT {
        if tr_sel >= 0 && tr_sel < tr_count {
            if tr_rows[tr_sel].is_dir && tr_rows[tr_sel].expanded {
                tree_row_activate(tr_sel);
            } else {
                // to the parent row
                for i32 j = tr_sel - 1; j >= 0; j-- {
                    if tr_rows[j].depth < tr_rows[tr_sel].depth {
                        tree_select(j);
                        break;
                    }
                }
            }
        }
        plat_damage();
        return true;
    }
    return false;
}

// text input while the tree has focus: Space opens a file and keeps
// the focus here, Enter opens it and passes the focus to the editor
// (the reference's two explorer keys on Windows and Linux); either
// toggles a directory. Everything else is swallowed so stray typing
// never edits the buffer invisibly
bool tree_char(u32 cp) {
    // Tab hands focus back to the editor; eating the char here keeps
    // it out of the buffer (the chord key K_TAB is a separate event)
    if cp == 9 {
        tree_focus = false;
        plat_damage();
        return true;
    }
    if tree_mode == SIDE_CHANGES && hist_focus && !hist_folded {
        ignore hist_char(cp);
        return true;
    }
    if cp == 32 {
        tree_row_activate(tr_sel);
        return true;
    }
    if cp == 13 {
        if tr_sel >= 0 && tr_sel < tr_count {
            bool is_dir = tr_rows[tr_sel].is_dir;   // the rows move on a toggle
            tree_row_activate(tr_sel);
            if !is_dir {
                tree_focus = false;
                plat_damage();
            }
        }
        return true;
    }
    return true;
}

i32 tree_row_h() {
    // reference list rows; the mono-derived fallback covers stubs
    if font_ui_row > 0 { return font_ui_row; }
    return font_line_h * 5 / 4;
}

private i32 tree_pad() {
    return font_line_h / 4;
}

private i32 tree_view_h() {
    if tree_mode == SIDE_CHANGES { return tree_changes_h(); }
    return sidebar_bottom();
}

// The changes view splits the sidebar: the changes on top, then the
// graph's heading and its rows (hist.mc). The changes take what their
// rows need, up to two fifths of the height while the graph is open,
// and everything above the heading while it is folded.
private const i32 TREE_CHANGES_SHARE = 2;   // fifths of the height
private const i32 TREE_SHARE_DIV = 5;

private i32 tree_changes_h() {
    i32 h = sidebar_bottom();
    i32 hh = tree_row_h();
    i32 most = h - hh;
    if most < 0 { most = 0; }
    if hist_folded { return most; }
    i32 want = 2 * tree_pad() + tr_count * tree_row_h();
    i32 share = h * TREE_CHANGES_SHARE / TREE_SHARE_DIV;
    if want > share { want = share; }
    if want > most { want = most; }
    return want;
}

// the graph's heading: its top, and the top of its rows under it
i32 tree_graph_head() {
    return tree_changes_h();
}

private i32 tree_graph_rows() {
    return tree_changes_h() + tree_row_h();
}

// the keyboard is in the changes list, not the graph under it
private bool tree_changes_focus() {
    return tree_focus && !(tree_mode == SIDE_CHANGES && hist_focus && !hist_folded);
}

// the graph opened or folded from its heading
private void tree_graph_fold(bool folded) {
    hist_folded = folded;
    if folded {
        hist_focus = false;
    } else {
        hist_ensure();
    }
    tree_scroll_clamp();
    plat_damage();
}

// keep the selected row inside the viewport
private void tree_sel_visible() {
    if tr_sel < 0 { return; }
    i32 rh = tree_row_h();
    i32 top = tree_pad() + tr_sel * rh - tr_scroll;
    if top < 0 { tr_scroll += top; }
    i32 bot = top + rh - tree_view_h();
    if bot > 0 { tr_scroll += bot; }
    if tr_scroll < 0 { tr_scroll = 0; }
}

// The scroll is a pixel offset into the rows, so it goes stale
// whenever the rows or the viewport change under it: a rebuild that
// drops rows, a fold, a window that grows. Every such change ends here,
// or the render draws rows and the scrollbar thumb from an offset past
// the content, which the fuzzer found as a thumb below the window.
private void tree_scroll_clamp() {
    i32 maxs = 2 * tree_pad() + tr_count * tree_row_h() - tree_view_h();
    if maxs < 0 { maxs = 0; }
    if tr_scroll > maxs { tr_scroll = maxs; }
    if tr_scroll < 0 { tr_scroll = 0; }
}

// the wheel at height y: the graph's rows under the changes, or the list
void tree_scroll_at(f32 dy, i32 y) {
    if tree_mode == SIDE_CHANGES && !hist_folded && y >= tree_graph_rows() {
        hist_scroll_by(dy);
        return;
    }
    tree_scroll_by(dy);
}

void tree_scroll_by(f32 dy) {
    tr_scroll_accum += dy;
    i32 step = cast(i32, tr_scroll_accum);
    if step == 0 { return; }
    tr_scroll_accum -= cast(f32, step);
    tr_scroll += step;
    tree_scroll_clamp();
    ed_damage();
}

private i32 tree_find_path(u8* p, i32 n) {
    for i32 i = 0; i < tr_count; i++ {
        if tr_rows[i].path_len == n
            && str_equal(tree_row_path(i), str_from(p, n)) {
            return i;
        }
    }
    return -1;
}

// The folder a new file goes in, written to out with a trailing '/':
// the selected directory, or the selected file's directory. Returns
// the length, 0 for the root (no selection, or the changes view).
i32 tree_sel_folder(u8* out, i32 cap) {
    if tree_mode != SIDE_FILES || tr_sel < 0 || tr_sel >= tr_count { return 0; }
    TreeRow* r = &tr_rows[tr_sel];
    i32 n = r.path_len;
    if !r.is_dir { n = r.name_off; }   // the parent with its '/', or 0 at the root
    if n + 1 >= cap { return 0; }
    memcpy(out, tr_arena + r.path_off, n);
    if r.is_dir {
        out[n] = '/';
        n++;
    }
    return n;
}

// --- names typed in the tree -------------------------------------------
// New File and New Folder add a row at the top of the folder with an
// input in place of the name; Rename (F2) puts the input over the row's
// own name. The state outlives a rebuild (the watcher's, a fold): the
// walk adds the row again. Enter commits, Esc cancels, and a press
// anywhere else commits, or cancels when the name is refused.

const i32 TREE_EDIT_NONE = 0;
const i32 TREE_EDIT_FILE = 1;
const i32 TREE_EDIT_FOLDER = 2;
const i32 TREE_EDIT_RENAME = 3;

private i32 tr_edit = TREE_EDIT_NONE;
// the folder a new entry goes in ("" at the root), or the renamed path
private u8[TREE_PATH_MAX] tr_edit_path;
private i32 tr_edit_path_len = 0;
private bool tr_edit_dir = false;   // a rename's target is a folder
private u8[TREE_PATH_MAX] tr_edit_buf;
private i32 tr_edit_len = 0;
private UiField tr_edit_field;

private UiField* tree_edit_field() {
    ui_field_bind(&tr_edit_field, &tr_edit_buf[0], &tr_edit_len, TREE_PATH_MAX - 1);
    return &tr_edit_field;
}

private bool tree_edit_is(u8* p, i32 n) {
    return n == tr_edit_path_len && str_equal(str_from(p, n), str_from(&tr_edit_path[0], n));
}

bool tree_edit_on() {
    return tr_edit != TREE_EDIT_NONE;
}

// what is being named, TREE_EDIT_*
i32 tree_edit_kind() {
    return tr_edit;
}

// the typed name, for the tests
str tree_edit_text() {
    return str_from(&tr_edit_buf[0], tr_edit_len);
}

private i32 tree_edit_row() {
    for i32 i = 0; i < tr_count; i++ {
        if tr_rows[i].edit { return i; }
    }
    return -1;
}

// the rows again, with the selection on the row being named
private void tree_edit_show() {
    tree_build();
    tree_select(tree_edit_row());
}

// Starts naming a new file or folder in `dir` ("" for the root): the
// folder opens and the input row is at the top of it.
void tree_new_entry(str dir, bool folder) {
    if dir.len >= TREE_PATH_MAX { return; }
    tree_edit_cancel();
    if !tree_on { tree_on = true; }
    if tree_mode != SIDE_FILES {
        tree_mode = SIDE_FILES;
        hist_focus = false;
    }
    for i32 k = 1; k <= dir.len; k++ {
        if (k == dir.len || dir.data[k] == '/') && !tree_is_open(dir.data, k) { tree_open_add(dir.data, k); }
    }
    memcpy(&tr_edit_path[0], dir.data, dir.len);
    tr_edit_path_len = dir.len;
    tr_edit = TREE_EDIT_FILE;
    if folder { tr_edit = TREE_EDIT_FOLDER; }
    tr_edit_len = 0;
    ui_field_end(tree_edit_field());
    tree_focus = true;
    tree_edit_show();
}

// Starts renaming row i: the input holds its name, with the part before
// the extension selected.
void tree_rename_row(i32 i) {
    if tree_mode != SIDE_FILES || i < 0 || i >= tr_count || tr_rows[i].hdr || tr_rows[i].edit { return; }
    TreeRow* r = &tr_rows[i];
    tree_edit_cancel();
    memcpy(&tr_edit_path[0], tr_arena + r.path_off, r.path_len);
    tr_edit_path_len = r.path_len;
    tr_edit_dir = r.is_dir;
    i32 nn = r.path_len - r.name_off;
    memcpy(&tr_edit_buf[0], tr_arena + r.path_off + r.name_off, nn);
    tr_edit_len = nn;
    tr_edit = TREE_EDIT_RENAME;
    i32 stem = nn;
    if !r.is_dir {
        for i32 k = nn - 1; k > 0; k-- {
            if tr_edit_buf[k] == '.' {
                stem = k;
                break;
            }
        }
    }
    UiField* f = tree_edit_field();
    f.anchor = 0;
    f.caret = stem;
    if stem == 0 { f.anchor = -1; }
    tree_focus = true;
    tree_edit_show();
}

void tree_edit_cancel() {
    if tr_edit == TREE_EDIT_NONE { return; }
    tr_edit = TREE_EDIT_NONE;
    i32 keep = tr_sel;
    tree_build();
    if keep >= tr_count { keep = tr_count - 1; }
    tr_sel = keep;
    ed_damage();
}

// a name the file systems refuse, or one that is not a single name for
// a rename; the reason, or "" when it is fine
private str tree_name_problem(str name, bool slash_ok) {
    if str_equal(name, ".") || str_equal(name, "..") { return "that name is reserved"; }
    for i32 i = 0; i < name.len; i++ {
        u8 c = name.data[i];
        if c == '/' && !slash_ok { return "a name cannot contain /"; }
        if c == '\\' || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|' || c < 32 {
            return "a name cannot contain \\ : * ? \" < > | or control characters";
        }
    }
    return "";
}

// Enter: makes the file or folder, or renames. False keeps the input
// open, with the reason in a notice.
bool tree_edit_commit() {
    if tr_edit == TREE_EDIT_NONE { return true; }
    // the name without the spaces around it
    i32 a = 0;
    i32 b = tr_edit_len;
    while a < b && tr_edit_buf[a] == ' ' { a++; }
    while b > a && tr_edit_buf[b - 1] == ' ' { b--; }
    while b > a && tr_edit_buf[b - 1] == '/' { b--; }
    str name = str_from(&tr_edit_buf[a], b - a);
    if name.len == 0 {
        tree_edit_cancel();
        return true;
    }
    str bad = tree_name_problem(name, tr_edit != TREE_EDIT_RENAME);
    if bad.len > 0 {
        ed_warn(bad);
        return false;
    }
    // the folder the name goes in, with its '/'
    noinit u8[TREE_PATH_MAX] p;
    i32 pn = 0;
    if tr_edit == TREE_EDIT_RENAME {
        pn = path_base_off(&tr_edit_path[0], tr_edit_path_len);
        memcpy(&p[0], &tr_edit_path[0], pn);
    } else if tr_edit_path_len > 0 {
        memcpy(&p[0], &tr_edit_path[0], tr_edit_path_len);
        pn = tr_edit_path_len;
        p[pn] = '/';
        pn++;
    }
    if pn + name.len >= TREE_PATH_MAX {
        ed_warn("the path is too long");
        return false;
    }
    memcpy(&p[pn], name.data, name.len);
    str path = str_from(&p[0], pn + name.len);
    str old = str_from(&tr_edit_path[0], tr_edit_path_len);
    if tr_edit == TREE_EDIT_RENAME && str_equal(path, old) {
        tree_edit_cancel();
        return true;
    }
    // a rename that only changes the case is the same entry on a file
    // system that ignores case, and is allowed
    bool case_only = tr_edit == TREE_EDIT_RENAME && path.len == old.len;
    for i32 i = 0; case_only && i < path.len; i++ {
        if ascii_lower(path.data[i]) != ascii_lower(old.data[i]) { case_only = false; }
    }
    if !case_only && ed_path_exists(path) {
        ed_warn("a file or folder with that name exists");
        return false;
    }
    i32 kind = tr_edit;
    tr_edit = TREE_EDIT_NONE;
    if kind == TREE_EDIT_FILE {
        if !ed_new_file(path) {
            tr_edit = kind;
            return false;
        }
        return true;
    }
    if kind == TREE_EDIT_FOLDER {
        if !dir_create(path) {
            tr_edit = kind;
            ed_warn("cannot create the folder");
            return false;
        }
        tree_open_add(path.data, path.len);
        tree_reveal(path);
        return true;
    }
    if !plat_file_rename(old, path) {
        tr_edit = kind;
        ed_warn("cannot rename it");
        return false;
    }
    if tr_edit_dir { tree_open_moved(old, path); }
    ed_paths_moved(old, path, tr_edit_dir);
    tree_reveal(path);
    return true;
}

// the input lost the pointer's attention: a commit, and when the name
// is refused, a cancel
void tree_edit_blur() {
    if tr_edit == TREE_EDIT_NONE { return; }
    if !tree_edit_commit() { tree_edit_cancel(); }
}

// keys while a name is typed; every key is the input's
void tree_edit_key(i32 key, i32 mods) {
    if key == K_ESCAPE {
        tree_edit_cancel();
        return;
    }
    bool changed = false;
    if ui_field_key(tree_edit_field(), key, mods, &changed) { ed_damage(); }
}

void tree_edit_char(u32 cp) {
    if cp == 13 {
        ignore tree_edit_commit();
        return;
    }
    if cp == 9 { return; }
    if ui_field_char(tree_edit_field(), cp) { ed_damage(); }
}

// whether window point (x, y) is on the row being named
bool tree_edit_hit(i32 x, i32 y) {
    i32 er = tree_edit_row();
    if er < 0 || x >= tree_w() || y >= tree_view_h() { return false; }
    i32 top = tree_pad() + er * tree_row_h() - tr_scroll;
    return y >= top && y < top + tree_row_h();
}

// the expanded folders under a renamed folder follow it
private void tree_open_moved(str old, str now) {
    noinit u8[TREE_PATH_MAX] np;
    i32 i = 0;
    while i < tr_nopen {
        i32 n = tr_open_n[i];
        u8* e = tr_open_data + tr_open_off[i];
        bool under = n == old.len || (n > old.len && e[old.len] == '/');
        if n < old.len || !under || !str_equal(str_from(e, old.len), old)
            || now.len + n - old.len >= TREE_PATH_MAX {
            i++;
            continue;
        }
        memcpy(&np[0], now.data, now.len);
        memcpy(&np[now.len], e + old.len, n - old.len);
        i32 nn = now.len + n - old.len;
        tree_open_remove(e, n);
        tree_open_add(&np[0], nn);
    }
}

// --- the context menu ----------------------------------------------------

private const i32 TM_NEW_FILE = 1;
private const i32 TM_NEW_FOLDER = 2;
private const i32 TM_RENAME = 3;
private const i32 TM_COPY_PATH = 4;
private const i32 TM_COPY_REL = 5;
private const i32 TM_OPEN_SIDE = 6;
private const i32 TM_DELETE = 7;
private const i32 TM_REVEAL = 8;

// the file manager's name in "Reveal in ...", "" where there is none to
// select a file in
private str tree_reveal_name() {
    when os(windows) { return "Reveal in File Explorer"; }
    when os(macos) { return "Reveal in Finder"; }
    when os(linux) { return "Open Containing Folder"; }
    return "";
}

// Delete: the row's file or folder to the system's trash, which keeps it
// to restore. Its buffers close, except one with unsaved changes.
void tree_delete_row(i32 i) {
    if tree_mode != SIDE_FILES || i < 0 || i >= tr_count || tr_rows[i].hdr || tr_rows[i].edit { return; }
    TreeRow* r = &tr_rows[i];
    bool dir = r.is_dir;
    noinit u8[TREE_PATH_MAX] rel;
    i32 rn = r.path_len;
    memcpy(&rel[0], tr_arena + r.path_off, rn);
    noinit u8[PATH_MAX] abs;
    i32 n = ed_abs_path(str_from(&rel[0], rn), &abs[0]);
    i32 no = r.name_off;
    if !plat_trash(str_from(&abs[0], n)) {
        ed_warn("cannot move it to the trash");
        return;
    }
    i32 keep = tr_sel;
    bool focus = tree_focus;
    i32 stayed = ed_paths_deleted(str_from(&rel[0], rn), dir);
    tree_focus = focus;
    noinit u8[TREE_PATH_MAX + 64] m;
    str pre = "moved to the trash: ";
    if stayed > 0 { pre = "moved to the trash, its unsaved buffer kept open: "; }
    memcpy(&m[0], pre.data, pre.len);
    memcpy(&m[pre.len], &rel[no], rn - no);
    ed_status(str_from(&m[0], pre.len + rn - no));
    tree_build();
    if keep >= tr_count { keep = tr_count - 1; }
    tree_select(keep);
}

// what the menu was opened on, held while it is up: the watcher can
// rebuild the rows under it
private u8[TREE_PATH_MAX] tm_path;
private i32 tm_len = 0;
private bool tm_dir = true;

// The right button at window point (x, y) in the file tree: the row
// under it is selected and its menu opens, or the root's below the
// rows. False in the changes view and past the rows.
bool tree_right_click(i32 x, i32 y) {
    if tree_mode != SIDE_FILES || y >= tree_view_h() { return false; }
    tree_edit_blur();
    tree_focus = true;
    // the padding is above the first row, so it scrolls away with it
    i32 off = y - tree_pad() + tr_scroll;
    i32 i = off / tree_row_h();
    if off < 0 || i >= tr_count { i = -1; }
    tree_menu_open(i, x, y);
    return true;
}

// The menu key, or Shift+F10, in the tree: the selected row's menu,
// under the row's name, with its first entry selected.
private void tree_menu_key() {
    i32 i = tr_sel;
    if i >= tr_count || (i >= 0 && (tr_rows[i].hdr || tr_rows[i].edit)) { i = -1; }
    i32 y = tree_pad();
    i32 x = font_line_h / 2 + tree_name_off();
    if i >= 0 {
        tree_sel_visible();
        y = tree_pad() + (i + 1) * tree_row_h() - tr_scroll;
        x = font_line_h / 2 + tr_rows[i].depth * tree_indent() + tree_name_off();
    }
    tree_menu_open(i, x, y);
    menu_select_first();
}

// row i's menu, or the root's for -1, opened at window point (x, y)
private void tree_menu_open(i32 i, i32 x, i32 y) {
    tree_select(i);
    tm_len = 0;
    tm_dir = true;
    if i >= 0 {
        memcpy(&tm_path[0], tr_arena + tr_rows[i].path_off, tr_rows[i].path_len);
        tm_len = tr_rows[i].path_len;
        tm_dir = tr_rows[i].is_dir;
    }
    menu_clear();
    if tm_dir {
        menu_add("New File...", "", TM_NEW_FILE);
        menu_add("New Folder...", "", TM_NEW_FOLDER);
    } else {
        menu_add("Open to the Side", "", TM_OPEN_SIDE);
    }
    if i >= 0 {
        if tree_reveal_name().len > 0 {
            menu_sep();
            menu_add(tree_reveal_name(), "", TM_REVEAL);
        }
        menu_sep();
        menu_add("Copy Path", "", TM_COPY_PATH);
        menu_add("Copy Relative Path", "", TM_COPY_REL);
        menu_sep();
        menu_add("Rename...", "F2", TM_RENAME);
        menu_add("Delete", "Delete", TM_DELETE);
    }
    menu_open(x, y);
}

// the folder of what the menu was opened on: itself, or a file's own
private str tm_folder() {
    if tm_dir { return str_from(&tm_path[0], tm_len); }
    i32 b = path_base_off(&tm_path[0], tm_len);
    if b > 0 { b--; }   // without its '/'
    return str_from(&tm_path[0], b);
}

void tree_menu_run(i32 id) {
    str p = str_from(&tm_path[0], tm_len);
    if id == TM_NEW_FILE { tree_new_entry(tm_folder(), false); return; }
    if id == TM_NEW_FOLDER { tree_new_entry(tm_folder(), true); return; }
    if id == TM_RENAME {
        tree_rename_row(tree_find_path(&tm_path[0], tm_len));
        return;
    }
    if id == TM_COPY_REL {
        plat_clipboard_set(p.data, p.len);
        return;
    }
    if id == TM_COPY_PATH {
        noinit u8[PATH_MAX] abs;
        i32 n = ed_abs_path(p, &abs[0]);
        plat_clipboard_set(&abs[0], n);
        return;
    }
    if id == TM_OPEN_SIDE {
        ed_open_to_side(p);
        return;
    }
    if id == TM_DELETE {
        tree_delete_row(tree_find_path(&tm_path[0], tm_len));
        return;
    }
    if id == TM_REVEAL {
        noinit u8[PATH_MAX] abs;
        i32 n = ed_abs_path(p, &abs[0]);
        if !plat_reveal(str_from(&abs[0], n)) { ed_warn("cannot open the file manager"); }
    }
}

// Shows path in the tree: its parent directories expand, and its row is
// selected after the rebuild.
void tree_reveal(str path) {
    for i32 k = 1; k < path.len; k++ {
        if path.data[k] == '/' && !tree_is_open(path.data, k) { tree_open_add(path.data, k); }
    }
    tree_mode = SIDE_FILES;
    hist_focus = false;
    tree_build();
    tree_select(tree_find_path(path.data, path.len));
}

void tree_select(i32 i) {
    if i < 0 || i >= tr_count {
        tr_sel = -1;
    } else {
        tr_sel = i;
        tree_sel_visible();
    }
    ed_damage();
}

i32 tree_sel() {
    return tr_sel;
}

// a click opens a row for a look; a second click on the same row within
// the double-click time keeps what it opened
private i32 tr_click_row = -1;
private i64 tr_click_us = 0;

void tree_mouse(i32 x, i32 y) {
    tree_focus = true;
    if tree_mode == SIDE_CHANGES {
        if y >= tree_graph_head() && y < tree_graph_rows() {
            tree_graph_fold(!hist_folded);
            return;
        }
        if y >= tree_graph_rows() {
            hist_mouse(x, y - tree_graph_rows());
            return;
        }
        hist_focus = false;
    }
    if y >= tree_view_h() { return; }
    i32 i = (y - tree_pad() + tr_scroll) / tree_row_h();
    if i < 0 || i >= tr_count {
        tree_select(-1);
        return;
    }
    i64 now = plat_time_us();
    bool dbl = i == tr_click_row && now - tr_click_us < DBLCLICK_US;
    tr_click_row = i;
    tr_click_us = now;
    tree_select(i);
    tree_row_activate(i);
    if dbl && !tr_rows[i].is_dir { ed_buf_keep(); }
}

private u32 tree_dec_color(i32 st) {
    if st == DEC_MOD { return T_DEC_MOD; }
    if st == DEC_ADD { return T_DEC_ADD; }
    if st == DEC_UNTRACKED || st == DEC_RENAME { return T_DEC_UNTRACKED; }
    if st == DEC_DEL { return T_DEC_DEL; }
    if st == DEC_CONFLICT { return T_DEC_CONFLICT; }
    return T_FG;
}

void tree_render() {
    if !tree_on { return; }
    i32 lh = font_line_h;
    i32 tw = tree_w();
    i32 rh = tree_row_h();
    i32 pad = tree_pad();
    bool cfocus = tree_changes_focus();
    draw_rect(0.0f, 0.0f, cast(f32, tw), cast(f32, sidebar_bottom()), T_SIDEBAR_BG);
    // the rows stop at the graph's heading
    draw_clip_y(0.0f, cast(f32, tree_view_h()));
    for i32 i = 0; i < tr_count; i++ {
        TreeRow* r = &tr_rows[i];
        i32 y = pad + i * rh - tr_scroll;
        if y + rh <= 0 { continue; }
        if y >= tree_view_h() { break; }
        i32 ty = y + (rh - lh) / 2;
        // the open file's row carries the blue selection background;
        // the keyboard-focus row gets the focus outline (same blue
        // as the input focus rings), muted background when the tree
        // is not focused
        bool active_row = !r.is_dir && g_has_path
            && str_equal(tree_row_path(i), str_from(&g_path[0], g_path_len));
        if active_row {
            draw_rect(0.0f, cast(f32, y), cast(f32, tw), cast(f32, rh), T_LIST_SEL);
        } else if i == tr_sel && !cfocus {
            draw_rect(0.0f, cast(f32, y), cast(f32, tw), cast(f32, rh), T_LIST_SEL_INACTIVE);
        }
        if i == tr_sel && cfocus {
            f32 ow = cast(f32, lh) / 20.0f;
            if ow < 1.0f { ow = 1.0f; }
            draw_rect(0.0f, cast(f32, y), cast(f32, tw), ow, T_FOCUS);
            draw_rect(0.0f, cast(f32, y + rh) - ow, cast(f32, tw), ow, T_FOCUS);
            draw_rect(0.0f, cast(f32, y), ow, cast(f32, rh), T_FOCUS);
            draw_rect(cast(f32, tw) - ow, cast(f32, y), ow, cast(f32, rh), T_FOCUS);
        }
        i32 x = lh / 2 + r.depth * tree_indent();
        if r.edit {
            tree_edit_row_render(r, x, y, ty);
            continue;
        }
        if r.hdr {
            u32 chev = ICO_CHEV_RIGHT;
            if r.expanded { chev = ICO_CHEV_DOWN; }
            font_draw(chev, cast(f32, x), cast(f32, ty), T_DIM);
            f32 hy = cast(f32, ty + font_ascent + 1 - font_ui_ascent);
            ignore font_draw_ui_text(tree_row_path(i),
                cast(f32, x + tree_name_off()), hy, cast(f32, tw - pad), T_DIM);
            // how many are under it, whether or not it is open
            i32 cnt = 0;
            for i32 k = 0; k < git_changed_count(); k++ {
                if git_changed_staged(k) == str_equal(tree_row_path(i), "Staged Changes") { cnt++; }
            }
            noinit u8[16] cb;
            str cs = str_from(&cb[0], fmt_i32(&cb[0], cnt));
            i32 cw2 = font_ui_text_w(cs);
            ignore font_draw_ui_text(cs, cast(f32, tw - pad - cw2), hy, cast(f32, tw), T_DIM);
            continue;
        }
        if r.is_dir {
            // folders: chevron only, like the reference icon theme
            u32 chev = ICO_CHEV_RIGHT;
            if r.expanded { chev = ICO_CHEV_DOWN; }
            font_draw(chev, cast(f32, x), cast(f32, ty), T_FG);
        } else {
            u32 icol = 0;
            i32 name_n = r.path_len - r.name_off;
            u32 ico = theme_file_icon(str_from(tr_arena + r.path_off + r.name_off, name_n), &icol);
            font_draw(ico, cast(f32, x), cast(f32, ty), icol);
        }
        // names in the UI face, baseline-aligned with the icons
        // (icon ink bottoms sit on the mono baseline + 1); a changed
        // path takes its git color, with the state's letter at the
        // right, a dot for a folder holding changes
        i32 name_len = r.path_len - r.name_off;
        f32 ny = cast(f32, ty + font_ascent + 1 - font_ui_ascent);
        i32 dst = git_dec_state(tree_row_path(i));
        // in the changes view a row is one column of one record, so it
        // carries that column's state rather than the two collapsed
        if tree_mode == SIDE_CHANGES && r.gidx >= 0 { dst = git_changed_state(r.gidx); }
        u32 ncol = tree_dec_color(dst);
        // a gitignored entry is dimmed, as the reference draws it
        if r.ign && dst == DEC_NONE { ncol = T_DIM; }
        i32 name_max = tw - pad;
        if dst != DEC_NONE {
            str badge = git_dec_badge(dst);
            if r.is_dir { badge = "\xE2\x80\xA2"; }
            i32 bw = font_ui_text_w(badge);
            i32 bx = tw - pad - bw;
            ignore font_draw_ui_text(badge, cast(f32, bx), ny, cast(f32, tw), ncol);
            name_max = bx - pad / 2;
        }
        i32 nx = x + tree_name_off();
        ignore font_draw_ui_text(str_from(tr_arena + r.path_off + r.name_off, name_len),
            cast(f32, nx), ny, cast(f32, name_max), ncol);
        // in the changes view the rows are flat, so the folder a file
        // sits in is what tells two same-named files apart: it follows
        // the name, dimmed, in the space the name leaves
        if tree_mode == SIDE_CHANGES && r.name_off > 1 {
            i32 fx = nx + font_ui_text_w(str_from(tr_arena + r.path_off + r.name_off, name_len))
                + tree_pad();
            if fx < name_max {
                ignore font_draw_ui_text(str_from(tr_arena + r.path_off, r.name_off - 1),
                    cast(f32, fx), ny, cast(f32, name_max), T_DIM);
            }
        }
    }
    // a scrollbar when the rows overflow the panel, like the document's
    i32 vh = tree_view_h();
    i32 content = 2 * pad + tr_count * rh;
    if content > vh && vh > 0 {
        i32 th = vh * vh / content;
        if th < TREE_SCROLL_MIN { th = TREE_SCROLL_MIN; }
        if th > vh { th = vh; }
        i32 maxs = content - vh;
        i32 ty = 0;
        if maxs > 0 { ty = (vh - th) * tr_scroll / maxs; }
        draw_rect_rounded(cast(f32, tw - TREE_SCROLL_W - TREE_SCROLL_PAD),
            cast(f32, ty), cast(f32, TREE_SCROLL_W), cast(f32, th),
            TREE_SCROLL_W / 2, C_SCROLL);
    }
    draw_clip_y_off();
    if tree_mode == SIDE_CHANGES { tree_graph_render(); }
}

// The row being named: its icon, then an input over the name's place, a
// one-pixel focus border inside the row. A new entry's file icon follows
// the name as it is typed.
private void tree_edit_row_render(TreeRow* r, i32 x, i32 y, i32 ty) {
    i32 tw = tree_w();
    i32 rh = tree_row_h();
    i32 pad = tree_pad();
    if r.is_dir {
        font_draw(ICO_CHEV_RIGHT, cast(f32, x), cast(f32, ty), T_FG);
    } else {
        u32 icol = 0;
        u32 ico = theme_file_icon(str_from(&tr_edit_buf[0], tr_edit_len), &icol);
        font_draw(ico, cast(f32, x), cast(f32, ty), icol);
    }
    i32 bx = x + tree_name_off() - 3;
    i32 bw = tw - pad - bx;
    if bw < font_cell_w { bw = font_cell_w; }
    draw_rect(cast(f32, bx), cast(f32, y), cast(f32, bw), cast(f32, rh), T_FOCUS);
    draw_rect(cast(f32, bx + 1), cast(f32, y + 1), cast(f32, bw - 2), cast(f32, rh - 2), T_INPUT_BG);
    f32 ny = cast(f32, ty + font_ascent + 1 - font_ui_ascent);
    ignore ui_field_draw(tree_edit_field(), cast(f32, bx + 3), ny, cast(f32, bx + bw - 3), T_FG, caret_on);
}

// the graph's heading, a rule above it, and its rows (hist.mc)
private void tree_graph_render() {
    i32 lh = font_line_h;
    i32 tw = tree_w();
    i32 rh = tree_row_h();
    i32 pad = tree_pad();
    i32 hy = tree_graph_head();
    draw_rect(0.0f, cast(f32, hy), cast(f32, tw), cast(f32, rh), T_SIDEBAR_BG);
    draw_rect(0.0f, cast(f32, hy), cast(f32, tw), 1.0f, T_DIVIDER);
    i32 ty = hy + (rh - lh) / 2;
    u32 chev = ICO_CHEV_DOWN;
    if hist_folded { chev = ICO_CHEV_RIGHT; }
    i32 x = lh / 2;
    font_draw(chev, cast(f32, x), cast(f32, ty), T_DIM);
    f32 ny = cast(f32, ty + font_ascent + 1 - font_ui_ascent);
    ignore font_draw_ui_text("Graph", cast(f32, x + tree_name_off()), ny, cast(f32, tw - pad), T_DIM);
    if hist_folded { return; }
    hist_render(tw, tree_graph_rows(), sidebar_bottom(), tree_focus && hist_focus);
}
