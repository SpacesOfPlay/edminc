// palette.mc - the command palette (Ctrl+Shift+P, F1). Every command
// the editor binds to a chord is a row: its name, and the chord shown
// at the right. A row runs its chord through the key path the keyboard
// uses, so the palette and the keyboard cannot disagree on what a
// command does. The query is matched with the picker's scorer.

const i32 PAL_QUERY_MAX = 128;
private const i32 PAL_MAX = 128;
private const i32 PAL_VIS = 12;          // rows shown
private const i32 PAL_COLS = 72;         // panel width in cells, clamped
private const i32 PAL_LABEL_MAX = 48;

// A command is one key with modifiers, or the second key of the Ctrl+K
// chord (chord set). Enter is delivered as text, so a chord ending in
// it sends a character (is_char set), the way the platform does.
private struct PalCmd {
    str name;
    i32 key;
    i32 mods;
    bool chord;
    bool is_char;
    bool accept;    // the chord opens a list; Enter takes its first row
    i32 theme;      // a color theme, PAL_THEME_PICKER, or -1 for a chord
    i32 folder;     // a recent folder's place in the list, or -1
}

// A command with no chord: a color theme, which the picker lists and
// Enter writes into the settings file, or with -1 the command that opens
// the picker. The theme rows show only in the picker. PAL_REPORT_ISSUE
// opens the project's issue tracker in the browser.
private const i32 PAL_THEME_PICKER = -2;
private const i32 PAL_REPORT_ISSUE = -3;
const str EDMINC_ISSUES_URL = "https://github.com/SpacesOfPlay/edminc/issues";

private void pal_add_theme(i32 t) {
    if pal_n == PAL_MAX { return; }
    if t < 0 {
        pal_cmds[pal_n] = PalCmd{ "Preferences: Color Theme", 0, 0, false, false, false, PAL_THEME_PICKER, -1 };
    } else {
        pal_cmds[pal_n] = PalCmd{ theme_name(t), 0, 0, false, false, false, t, -1 };
    }
    pal_n++;
}

bool palette_on = false;

// The color theme picker is the palette over the theme rows alone. The
// selected row is previewed as the selection moves; Enter keeps it,
// anything else that closes the list puts back the theme it opened on.
private bool pal_themes = false;
private i32 pal_theme_was = 0;

// File: Open Recent is the palette over the recent folders, which are
// rows after the table while it is open (recent.mc). Enter opens the
// folder. The folder already open is not listed, nor one that is gone.
private bool pal_recent = false;
private i32 pal_nfixed = 0;

private PalCmd[PAL_MAX] pal_cmds;
private i32 pal_n = 0;
private u8[PAL_QUERY_MAX] pal_q;
private i32 pal_qlen = 0;
private i32[PAL_MAX] pal_hits;      // command indices, best first
private i32[PAL_MAX] pal_scores;
private i32 pal_nhits = 0;
private i32 pal_sel = 0;
private i32 pal_top = 0;
private f32 pal_scroll_accum = 0.0f;

private void pal_add(str name, i32 key, i32 mods) {
    if pal_n == PAL_MAX { return; }
    pal_cmds[pal_n] = PalCmd{ name, key, mods, false, false, false, -1, -1 };
    pal_n++;
}

// a chord that opens a list on the row wanted, then Enter: the switcher
// opens on the buffer or terminal shown before, so this is the quick
// toggle a tap of Ctrl+` makes
private void pal_add_accept(str name, i32 key, i32 mods) {
    if pal_n == PAL_MAX { return; }
    pal_cmds[pal_n] = PalCmd{ name, key, mods, false, false, true, -1, -1 };
    pal_n++;
}

// a Ctrl+K chord: `key` with `mods` follows the prefix
private void pal_add_k(str name, i32 key, i32 mods) {
    if pal_n == PAL_MAX { return; }
    pal_cmds[pal_n] = PalCmd{ name, key, mods, true, false, false, -1, -1 };
    pal_n++;
}

// The table, in the order an empty query shows. The chords are the
// ones app_key binds (ed.mc, build.mc); a command bound there and
// missing here is reachable only from the keyboard.
private void pal_build() {
    if pal_n > 0 { return; }
    pal_add("Go to File...", 'P', MOD_CTRL);
    pal_add("Go to Symbol in Workspace...", 'T', MOD_CTRL);
    pal_add("Go to Definition", K_F12, 0);
    pal_add("Go to References", K_F12, MOD_SHIFT);
    pal_add("Go Back", NAV_BACK_KEY, NAV_BACK_MODS);
    pal_add("Go Forward", NAV_FWD_KEY, NAV_FWD_MODS);
    pal_add("Go to Next Problem", K_F8, 0);
    pal_add("Go to Previous Problem", K_F8, MOD_SHIFT);
    pal_add("Go to Next Change", K_F7, 0);
    pal_add("Go to Previous Change", K_F7, MOD_SHIFT);
    pal_add("Go to Beginning of File", K_HOME, MOD_CTRL);
    pal_add("Go to End of File", K_END, MOD_CTRL);
    pal_add("Edit: Find", 'F', MOD_CTRL);
    pal_add("Edit: Replace", 'H', MOD_CTRL);
    pal_add("Search: Find in Files", 'F', MOD_CTRL | MOD_SHIFT);
    pal_add("Edit: Undo", 'Z', MOD_CTRL);
    pal_add("Edit: Redo", 'Z', MOD_CTRL | MOD_SHIFT);
    pal_add("Edit: Cut", 'X', MOD_CTRL);
    pal_add("Edit: Copy", 'C', MOD_CTRL);
    pal_add("Edit: Paste", 'V', MOD_CTRL);
    pal_add("Edit: Select All", 'A', MOD_CTRL);
    pal_add("Edit: Delete Line", 'K', MOD_CTRL | MOD_SHIFT);
    pal_add("Edit: Toggle Line Comment", '/', MOD_CTRL);
    pal_add("Edit: Add Selection to Next Find Match", 'D', MOD_CTRL);
    pal_add("Edit: Add Cursor Above", K_UP, MOD_CTRL | MOD_ALT);
    pal_add("Edit: Add Cursor Below", K_DOWN, MOD_CTRL | MOD_ALT);
    pal_add("Edit: Move Line Up", K_UP, MOD_ALT);
    pal_add("Edit: Move Line Down", K_DOWN, MOD_ALT);
    pal_add("Edit: Copy Line Up", K_UP, MOD_ALT | MOD_SHIFT);
    pal_add("Edit: Copy Line Down", K_DOWN, MOD_ALT | MOD_SHIFT);
    pal_add("Edit: Trigger Suggest", ' ', MOD_CTRL);
    pal_add("File: New Text File", 'N', MOD_CTRL);
    pal_add_k("File: New File...", 'F', 0);
    pal_add("File: Save", 'S', MOD_CTRL);
    pal_add_k("File: Open Recent...", 'R', 0);
    pal_add_k("File: Keep Editor", 13, 0);
    pal_add_k("File: Open Folder...", 'O', 0);
    pal_add_k("File: New Window", 'N', 0);
    pal_add("File: Quit", 'Q', MOD_CTRL);
    pal_add("View: Toggle Sidebar", 'B', MOD_CTRL);
    pal_add("View: Show Explorer", 'E', MOD_CTRL);
    pal_add("View: Show Source Control", 'G', MOD_CTRL | MOD_SHIFT);
    pal_add("View: Toggle Build Panel", 'J', MOD_CTRL);
    pal_add_k("View: Toggle Status Bar", 'S', 0);
    pal_add_k("View: Toggle Smooth Scrolling", 'M', 0);
    pal_add_k("View: Toggle Problem Underlines", 'D', 0);
    pal_add("View: Toggle Word Wrap", 'Z', MOD_ALT);
    pal_add("View: Zoom In", '=', MOD_CTRL);
    pal_add("View: Zoom Out", '-', MOD_CTRL);
    pal_add("View: Reset Zoom", '0', MOD_CTRL);
    pal_add("View: Split Editor", 92, MOD_CTRL);
    pal_add("View: Focus First Editor Group", '1', MOD_CTRL);
    pal_add("View: Focus Second Editor Group", '2', MOD_CTRL);
    pal_add("View: Focus Third Editor Group", '3', MOD_CTRL);
    pal_add("View: Close Editor", 'W', MOD_CTRL);
    pal_add("View: Close Editor Group", 'W', MOD_CTRL | MOD_SHIFT);
    pal_add_k("View: Show All Editors", 'W', 0);
    pal_add("View: Explode Open Editors", 'M', MOD_CTRL);
    pal_add("View: Call Graph", 'M', MOD_CTRL | MOD_SHIFT);
    pal_add_accept("View: Switch to Previous Editor or Terminal", 96, MOD_CTRL);
    pal_add("View: Move Editor into Left Group", K_LEFT, MOD_CTRL | MOD_ALT);
    pal_add("View: Move Editor into Right Group", K_RIGHT, MOD_CTRL | MOD_ALT);
    pal_add_k("View: Restart Editor", 'X', 0);
    pal_add_k("Terminal: Create New Terminal", 'T', 0);
    pal_add_k("Terminal: Toggle Colors", 'P', 0);
    pal_add("Build: Run Build Task", 'B', MOD_CTRL | MOD_SHIFT);
    pal_add("Build: Run Project", K_F5, 0);
    pal_add("Build: Run Active File", K_F5, MOD_SHIFT);
    pal_add("Build: Stop", '.', MOD_CTRL);
    pal_add("Preferences: Open Settings (JSON)", ',', MOD_CTRL);
    if pal_n < PAL_MAX {
        pal_cmds[pal_n] = PalCmd{ "Help: Report Issue", 0, 0, false, false, false, PAL_REPORT_ISSUE, -1 };
        pal_n++;
    }
    pal_add_theme(-1);
    for i32 t = 0; t < theme_count(); t++ { pal_add_theme(t); }
    pal_nfixed = pal_n;
    // Enter is text: the chord's second key goes through app_char
    for i32 i = 0; i < pal_n; i++ {
        if pal_cmds[i].chord && pal_cmds[i].key == 13 { pal_cmds[i].is_char = true; }
    }
}

// --- the chord's label ---------------------------------------------------

private i32 pal_put(u8* buf, i32 n, str s) {
    if n + s.len > PAL_LABEL_MAX { return n; }
    memcpy(buf + n, s.data, s.len);
    return n + s.len;
}

private str pal_key_name(i32 key) {
    if key == K_LEFT { return "Left"; }
    if key == K_RIGHT { return "Right"; }
    if key == K_UP { return "Up"; }
    if key == K_DOWN { return "Down"; }
    if key == K_HOME { return "Home"; }
    if key == K_END { return "End"; }
    if key == K_PGUP { return "PageUp"; }
    if key == K_PGDN { return "PageDown"; }
    if key == K_DELETE { return "Delete"; }
    if key == K_TAB { return "Tab"; }
    if key == K_F5 { return "F5"; }
    if key == K_F7 { return "F7"; }
    if key == K_F8 { return "F8"; }
    if key == K_F12 { return "F12"; }
    if key == 13 { return "Enter"; }
    if key == 96 { return "`"; }
    if key == ' ' { return "Space"; }
    if key == 92 { return "\\"; }
    return "";
}

// the modifiers by the platform's names, then the key
private i32 pal_chord_label(u8* buf, i32 n, i32 key, i32 mods) {
    str prim = "Ctrl";
    str sup = "Win";
    str alt = "Alt";
    when os(macos) {
        prim = "Cmd";
        sup = "Ctrl";
        alt = "Option";
    }
    if (mods & MOD_SUPER) != 0 { n = pal_put(buf, n, sup); n = pal_put(buf, n, "+"); }
    if (mods & MOD_CTRL) != 0 { n = pal_put(buf, n, prim); n = pal_put(buf, n, "+"); }
    if (mods & MOD_ALT) != 0 { n = pal_put(buf, n, alt); n = pal_put(buf, n, "+"); }
    if (mods & MOD_SHIFT) != 0 { n = pal_put(buf, n, "Shift+"); }
    str kn = pal_key_name(key);
    if kn.len > 0 { return pal_put(buf, n, kn); }
    if n < PAL_LABEL_MAX {
        buf[n] = cast(u8, key);
        n++;
    }
    return n;
}

private i32 pal_label(i32 i, u8* buf) {
    i32 n = 0;
    if pal_cmds[i].theme != -1 || pal_cmds[i].folder >= 0 { return 0; }   // no chord
    if pal_cmds[i].chord {
        n = pal_chord_label(buf, n, 'K', MOD_CTRL);
        n = pal_put(buf, n, " ");
    }
    return pal_chord_label(buf, n, pal_cmds[i].key, pal_cmds[i].mods);
}

// --- the list --------------------------------------------------------------

private void pal_filter() {
    pal_nhits = 0;
    noinit i32[PAL_QUERY_MAX] pos;
    for i32 c = 0; c < pal_n; c++ {
        if (pal_cmds[c].theme >= 0) != pal_themes { continue; }
        if (pal_cmds[c].folder >= 0) != pal_recent { continue; }
        i32 sc = 0;   // an empty query keeps the table's order
        if pal_qlen > 0 {
            sc = pick_score(pal_cmds[c].name.data, pal_cmds[c].name.len, &pal_q[0], pal_qlen, &pos[0]);
            if sc == PICK_MISS { continue; }
        }
        i32 j = pal_nhits;
        while j > 0 && pal_scores[j - 1] < sc {
            pal_hits[j] = pal_hits[j - 1];
            pal_scores[j] = pal_scores[j - 1];
            j--;
        }
        pal_hits[j] = c;
        pal_scores[j] = sc;
        pal_nhits++;
    }
    pal_sel = 0;
    pal_top = 0;
    pal_preview();
}

// the picker's selection on screen
private void pal_preview() {
    if !pal_themes || pal_nhits == 0 { return; }
    i32 t = pal_cmds[pal_hits[pal_sel]].theme;
    if t >= 0 && t != theme_current() { settings_preview_theme(t); }
}

private i32 pal_rows() {
    i32 nr = pal_nhits - pal_top;
    i32 vis = ui_list_vis(PAL_VIS);
    if nr > vis { nr = vis; }
    if nr < 1 { nr = 1; }   // the "no commands matched" row
    return nr;
}

void palette_open() {
    pal_build();
    find_close();
    pal_themes = false;
    pal_recent = false;
    pal_qlen = 0;
    pal_scroll_accum = 0.0f;
    pal_filter();
    palette_on = true;
    ed_damage();
}

// Preferences: Color Theme: the list of themes, on the one in use
void palette_open_themes() {
    pal_build();
    find_close();
    pal_themes = true;
    pal_recent = false;
    pal_theme_was = theme_current();
    pal_qlen = 0;
    pal_scroll_accum = 0.0f;
    pal_filter();
    for i32 h = 0; h < pal_nhits; h++ {
        if pal_cmds[pal_hits[h]].theme == pal_theme_was { pal_move_to(h); }
    }
    palette_on = true;
    ed_damage();
}

// File: Open Recent: the recent folders, newest first
void palette_open_recent() {
    pal_build();
    find_close();
    pal_themes = false;
    pal_recent = true;
    pal_n = pal_nfixed;
    recent_load();
    noinit u8[PATH_MAX] cwd;
    str here = str_from(&cwd[0], plat_cwd(&cwd[0], PATH_MAX));
    for i32 i = 0; i < recent_count() && pal_n < PAL_MAX; i++ {
        str d = recent_at(i);
        if recent_same(d, here) || !path_is_dir(d) { continue; }
        pal_cmds[pal_n] = PalCmd{ d, 0, 0, false, false, false, -1, i };
        pal_n++;
    }
    pal_qlen = 0;
    pal_scroll_accum = 0.0f;
    pal_filter();
    palette_on = true;
    ed_damage();
}

void palette_close() {
    pal_recent = false;
    pal_n = pal_nfixed;
    // a picker closed without Enter puts back the theme it opened on
    if pal_themes {
        pal_themes = false;
        if theme_current() != pal_theme_was { settings_preview_theme(pal_theme_was); }
    }
    palette_on = false;
    ed_damage();
}

// The row runs its chord as the keyboard would send it. The palette
// closes first, so the keys reach the editor and not the palette.
private void pal_run(i32 c) {
    PalCmd cmd = pal_cmds[c];
    if cmd.folder >= 0 {
        // the name is in the recent list, which opening the folder rewrites
        noinit u8[PATH_MAX] dir;
        memcpy(&dir[0], cmd.name.data, cmd.name.len);
        palette_close();
        ignore ed_open_folder(str_from(&dir[0], cmd.name.len));
        return;
    }
    if cmd.theme >= 0 {
        // kept: the picker closes without putting the old theme back
        pal_themes = false;
        palette_close();
        settings_set_theme(cmd.theme);
        return;
    }
    palette_close();
    if cmd.theme == PAL_THEME_PICKER {
        palette_open_themes();
        return;
    }
    if cmd.theme == PAL_REPORT_ISSUE {
        if !plat_open_url(EDMINC_ISSUES_URL) { ed_warn("cannot open the browser"); }
        return;
    }
    if cmd.chord { ed_key_synth('K', MOD_CTRL); }
    if cmd.is_char {
        app_char(cast(u32, cmd.key));
    } else {
        ed_key_synth(cmd.key, cmd.mods);
    }
    if cmd.accept { app_char(13); }
}

private void pal_accept() {
    if pal_nhits == 0 {
        palette_close();
        return;
    }
    pal_run(pal_hits[pal_sel]);
}

private void pal_move(i32 delta) {
    pal_move_to(pal_sel + delta);
}

private void pal_move_to(i32 h) {
    pal_sel = h;
    if pal_sel >= pal_nhits { pal_sel = pal_nhits - 1; }
    if pal_sel < 0 { pal_sel = 0; }
    if pal_sel < pal_top { pal_top = pal_sel; }
    i32 vis = ui_list_vis(PAL_VIS);
    if pal_sel >= pal_top + vis { pal_top = pal_sel - vis + 1; }
    pal_preview();
    ed_damage();
}

private UiField pal_field;

private UiField* palette_field() {
    ui_field_bind(&pal_field, &pal_q[0], &pal_qlen, PAL_QUERY_MAX);
    return &pal_field;
}

void palette_char(u32 cp) {
    if cp == 13 { pal_accept(); return; }
    if !ui_field_char(palette_field(), cp) { return; }
    pal_filter();
    ed_damage();
}

void palette_key(i32 key, i32 mods) {
    bool changed = false;
    if ui_field_key(palette_field(), key, mods, &changed) {
        if changed { pal_filter(); }
        ed_damage();
        return;
    }
    // Ctrl+Shift+P again closes the palette; Ctrl+P goes straight to the
    // file picker, as it does in VS Code
    if (mods & MOD_CTRL) != 0 {
        if key == 'P' {
            palette_close();
            if (mods & MOD_SHIFT) == 0 { pick_open(); }
        }
        return;
    }
    if key == K_ESCAPE || key == K_F1 { palette_close(); return; }
    if key == K_UP { pal_move(-1); return; }
    if key == K_DOWN { pal_move(1); return; }
    if key == K_PGUP { pal_move(0 - ui_list_vis(PAL_VIS)); return; }
    if key == K_PGDN { pal_move(ui_list_vis(PAL_VIS)); return; }
}

// tests read these back
i32 palette_hit_count() {
    return pal_nhits;
}

str palette_hit_name(i32 i) {
    if i < 0 || i >= pal_nhits { return ""; }
    return pal_cmds[pal_hits[i]].name;
}

i32 palette_count() {
    pal_build();
    return pal_n;
}

str palette_name(i32 i) {
    pal_build();
    if i < 0 || i >= pal_n { return ""; }
    return pal_cmds[i].name;
}

// --- mouse, scroll, render -------------------------------------------------

// left-button press: a row runs it, anywhere outside closes
void palette_mouse(i32 x, i32 y) {
    i32 pw = ui_list_panel_w(PAL_COLS);
    i32 px = (g_w - pw) / 2;
    i32 pad = ui_list_pad();
    i32 ih = ui_input_h();
    i32 rh = ui_list_row_h();
    i32 py = pad;
    i32 ry = py + pad + ih + 4;
    if x >= px && x < px + pw && y >= ry && y < ry + pal_rows() * rh {
        i32 r = pal_top + (y - ry) / rh;
        if r < pal_nhits {
            pal_sel = r;
            pal_accept();
            return;
        }
    }
    i32 ph = pad + ih + 4 + pal_rows() * rh + pad;
    if x < px || x >= px + pw || y < py || y >= py + ph {
        palette_close();
    }
}

void palette_scroll(f32 dy) {
    pal_scroll_accum += dy;
    i32 rh = ui_list_row_h();
    i32 rows = cast(i32, pal_scroll_accum / cast(f32, rh));
    if rows == 0 { return; }
    pal_scroll_accum -= cast(f32, rows * rh);
    pal_top += rows;
    if pal_top > pal_nhits - ui_list_vis(PAL_VIS) { pal_top = pal_nhits - ui_list_vis(PAL_VIS); }
    if pal_top < 0 { pal_top = 0; }
    ed_damage();
}

void palette_render() {
    if !palette_on { return; }
    i32 pw = ui_list_panel_w(PAL_COLS);
    i32 px = (g_w - pw) / 2;
    i32 pad = ui_list_pad();
    i32 py = pad;
    i32 ih = ui_input_h();
    i32 rh = ui_list_row_h();
    i32 nr = pal_rows();
    i32 ph = pad + ih + 4 + nr * rh + pad;

    ui_panel(px, py, pw, ph);
    str hint = "type a command name";
    if pal_themes { hint = "select a color theme (the list previews it)"; }
    if pal_recent { hint = "open a recent folder"; }
    ui_input(px + pad, py + pad, pw - 2 * pad, palette_field(), hint, caret_on);

    i32 tx = px + pad + 2 + ui_inset();
    i32 ty = py + pad + ih + 4;
    f32 max_px = cast(f32, px + pw - pad - ui_inset());
    if pal_nhits == 0 {
        str none = "no commands matched";
        if pal_themes { none = "no themes matched"; }
        if pal_recent { none = "no recent folders"; }
        ignore font_draw_ui_text(none, cast(f32, tx),
            cast(f32, ty + (rh - font_ui_h) / 2), max_px, T_DIM);
    }
    noinit i32[PAL_QUERY_MAX] pos;
    noinit u8[PAL_LABEL_MAX] label;
    for i32 r = 0; r < nr && pal_top + r < pal_nhits; r++ {
        i32 h = pal_top + r;
        i32 c = pal_hits[h];
        str name = pal_cmds[c].name;
        i32 y = ty + r * rh;
        ui_list_row(px + 1, y, pw - 2, rh, h == pal_sel);
        f32 ny = cast(f32, y + (rh - font_ui_h) / 2);
        // the chord at the right, dim
        i32 ln = pal_label(c, &label[0]);
        i32 lw = font_ui_text_w(str_from(&label[0], ln));
        f32 lx = max_px - cast(f32, lw);
        // the width is rounded; a bound at max_px would drop the last glyph
        ignore font_draw_ui_text(str_from(&label[0], ln), lx, ny, max_px + 2.0f, T_DIM);
        // the name, with the query's characters marked
        i32 hi_n = 0;
        if pal_qlen > 0
            && pick_score(name.data, name.len, &pal_q[0], pal_qlen, &pos[0]) != PICK_MISS {
            hi_n = pal_qlen;
        }
        f32 x = cast(f32, tx);
        f32 name_max = lx - cast(f32, font_cell_w);
        i32 i = 0;
        i32 k = 0;
        while i < name.len {
            i32 ci = i;
            u32 cp = utf8_next(name.data, name.len, &i);
            u32 col = T_FG;
            if k < hi_n && pos[k] == ci {
                col = T_MATCH;
                k++;
            }
            if x + cast(f32, font_cell_w) > name_max { break; }
            x = font_draw_ui_cp(cp, x, ny, col);
        }
    }
    // the theme picker and the recent folders are lists to move through;
    // the command list is searched by name, so it has no scrollbar
    if pal_themes || pal_recent { ui_list_scrollbar(px + pw - 1, ty, nr * rh, pal_top, nr, pal_nhits); }
}
