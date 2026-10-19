// settings.mc - the user's settings: ~/.edminc/settings.json, one file
// for every folder and window. JSON with comments and trailing commas,
// in the reference editor's key names. It is read when the editor starts on the
// interactive path (not by the harnesses, a shot or a smoke run) and
// again when it is saved from the editor.

import file;
import json;

private u8[PATH_MAX] set_path;
private i32 set_path_len = 0;

// On once settings_load has run: on the interactive path, or in ed_test
// against its own file. The harnesses never load it, so a palette row
// that would write the file does nothing there, and a fuzz run neither
// reads nor writes the user's settings.
private bool set_on = false;

void settings_set_enabled(bool on) { set_on = on; }
bool settings_enabled() { return set_on; }

// ~/.edminc/settings.json, or "" where there is no home folder
str settings_path() {
    if set_path_len > 0 { return str_from(&set_path[0], set_path_len); }
    string home = env_get("HOME");
    when os(windows) {
        free(home);
        home = env_get("USERPROFILE");
    }
    str tail = "/.edminc/settings.json";
    if home.len > 0 && home.len + tail.len < PATH_MAX {
        memcpy(&set_path[0], home.data, home.len);
        memcpy(&set_path[home.len], tail.data, tail.len);
        set_path_len = cast(i32, home.len) + tail.len;
    }
    free(home);
    return str_from(&set_path[0], set_path_len);
}

// test seam: ed_test points the file under build/
void settings_set_path(str p) {
    if p.len >= PATH_MAX { return; }
    memcpy(&set_path[0], p.data, p.len);
    set_path_len = p.len;
}

// the folder the file lives in, which holds the recent list as well
str settings_dir() {
    str p = settings_path();
    i32 e = p.len;
    while e > 0 && p.data[e - 1] != '/' && p.data[e - 1] != 92 { e--; }
    if e <= 1 { return ""; }
    return str_from(p.data, e - 1);
}

private u8 set_fold(u8 c) {
    if c == 92 { return '/'; }
    if c >= 'A' && c <= 'Z' { return cast(u8, c + 32); }
    return c;
}

// whether a path names the settings file: separators and, since the
// home folder's case is the platform's business, letter case aside
bool settings_is_path(str p) {
    str s = settings_path();
    if s.len == 0 || p.len != s.len { return false; }
    for i32 i = 0; i < p.len; i++ {
        if set_fold(p.data[i]) != set_fold(s.data[i]) { return false; }
    }
    return true;
}

// --- reading ----------------------------------------------------------------

// The first problem found, shown once the file is read: a setting the
// file gets wrong is skipped and the rest still apply.
private u8[160] set_warn;
private i32 set_warn_len = 0;
private i32 set_warn_n = 0;

private void set_warn_add(str what, str name) {
    set_warn_n++;
    if set_warn_len > 0 { return; }
    str head = "settings.json: ";
    i32 n = 0;
    for i32 i = 0; i < head.len && n < 159; i++ { set_warn[n] = head.data[i]; n++; }
    for i32 i = 0; i < what.len && n < 159; i++ { set_warn[n] = what.data[i]; n++; }
    for i32 i = 0; i < name.len && n < 159; i++ { set_warn[n] = name.data[i]; n++; }
    set_warn_len = n;
}

private str set_key(JDoc* d, i32 v) {
    if d.nodes[v].key_off < 0 { return ""; }
    return str_from(d.src + d.nodes[v].key_off, d.nodes[v].key_len);
}

// each member of an object of colors, by slot name
// a true or false setting into *out; anything else is reported and the
// default stays
private void set_bool(JDoc* d, i32 root, str key, bool* out) {
    i32 j = jd_get(d, root, key);
    if j < 0 { return; }
    if jd_kind(d, j) == J_BOOL {
        *out = jd_bool(d, j);
    } else {
        set_warn_add("expected true or false for ", key);
    }
}

// files.exclude, the reference's shape: an object of glob patterns, each
// true to exclude it. The ones set to true go into out, one per line;
// the length.
private const i32 SET_EXCLUDE_MAX = 4096;
private i32 set_exclude(JDoc* d, i32 obj, u8* out, i32 cap) {
    i32 n = 0;
    i32 v = jd_first(d, obj);
    while v >= 0 {
        if jd_kind(d, v) != J_BOOL {
            set_warn_add("expected true or false for a pattern in ", "files.exclude");
        } else if jd_bool(d, v) {
            str key = set_key(d, v);
            if n + key.len + 1 <= cap {
                memcpy(out + n, key.data, key.len);
                n += key.len;
                out[n] = 10;
                n++;
            }
        }
        v = jd_next(d, v);
    }
    return n;
}

private void set_colors(JDoc* d, i32 obj, bool tokens) {
    if jd_kind(d, obj) != J_OBJ {
        set_warn_add("expected an object of colors for ", "a customization");
        return;
    }
    i32 c = jd_first(d, obj);
    while c >= 0 {
        str name = set_key(d, c);
        // the reference's rule lists and scope tables have no counterpart here
        bool skip = tokens && (str_equal(name, "textMateRules") || str_equal(name, "semanticTokenColors"));
        if !skip {
            u32 col = 0;
            if jd_kind(d, c) != J_STR || !theme_parse_color(jd_str(d, c), &col) {
                set_warn_add("not a color (#RRGGBB or #RRGGBBAA): ", name);
            } else if !theme_override(name, col) {
                set_warn_add("no color by the name ", name);
            }
        }
        c = jd_next(d, c);
    }
}

// Read the file and apply it over the defaults: Dark Modern, and smooth
// scrolling on. A missing file is the defaults. Called on the
// interactive path at start and after the file is saved.
void settings_load() {
    set_on = true;
    settings_apply(-1, true);
}

// The theme picker's preview: theme t with the file's overrides on top,
// so the preview is what choosing it gives. The file's own theme is
// passed over and nothing is reported. With the settings off (a harness
// run) the picker lists the themes but draws none of them, so a fuzz
// run stays in Dark+.
void settings_preview_theme(i32 t) {
    if t < 0 || t >= theme_count() || !set_on { return; }
    settings_apply(t, false);
}

// the theme a missing file or a missing workbench.colorTheme gives; a
// harness run, with the settings off, stays in Dark+
private const str THEME_DEFAULT = "Dark Modern";

// the file over the defaults; `force` is a theme that takes the file's
// place, or -1; `report` puts the first problem in the status bar
private void settings_apply(i32 force, bool report) {
    set_warn_len = 0;
    set_warn_n = 0;
    theme_load(theme_find(THEME_DEFAULT));
    g_smooth_scroll = true;
    // the defaults the reference has: ignored entries dimmed in the tree
    // and left out of the picker and search, nothing else excluded
    bool tree_hides = false;
    bool lists_use = true;
    bool wrap = false;
    bool squig = true;
    i32 zoom = 0;
    noinit u8[SET_EXCLUDE_MAX] ex;
    i32 ex_len = 0;
    str p = settings_path();
    FileData fd = file_read(p);
    if p.len > 0 && fd.data != null {
        JDoc d;
        i32 root = json_parse_lenient(&d, fd.data, cast(i64, fd.len));
        if root < 0 || jd_kind(&d, root) != J_OBJ {
            noinit u8[24] num;
            i32 nn = fmt_i32(&num[0], json_fail_line(&d));
            set_warn_add("not valid JSON at line ", str_from(&num[0], nn));
        } else {
            // the theme first: the overrides go on top of its table
            i32 jt = jd_get(&d, root, "workbench.colorTheme");
            if force >= 0 { jt = -1; }
            if jt >= 0 {
                i32 t = -1;
                if jd_kind(&d, jt) == J_STR { t = theme_find(jd_str(&d, jt)); }
                if t < 0 {
                    set_warn_add("no theme by the name ", jd_str(&d, jt));
                } else {
                    theme_load(t);
                }
            }
            i32 jc = jd_get(&d, root, "workbench.colorCustomizations");
            if jc >= 0 { set_colors(&d, jc, false); }
            i32 jk = jd_get(&d, root, "editor.tokenColorCustomizations");
            if jk >= 0 { set_colors(&d, jk, true); }
            i32 js = jd_get(&d, root, "editor.smoothScrolling");
            if js >= 0 {
                if jd_kind(&d, js) == J_BOOL {
                    g_smooth_scroll = jd_bool(&d, js);
                } else {
                    set_warn_add("expected true or false for ", "editor.smoothScrolling");
                }
            }
            i32 jw = jd_get(&d, root, "editor.wordWrap");
            if jw >= 0 {
                if jd_kind(&d, jw) == J_STR && (str_equal(jd_str(&d, jw), "on") || str_equal(jd_str(&d, jw), "off")) {
                    wrap = str_equal(jd_str(&d, jw), "on");
                } else {
                    set_warn_add("expected \"on\" or \"off\" for ", "editor.wordWrap");
                }
            }
            // VS Code's values; "editable" is "on" for a document here
            i32 jv = jd_get(&d, root, "editor.renderValidationDecorations");
            if jv >= 0 {
                str vv = "";
                if jd_kind(&d, jv) == J_STR { vv = jd_str(&d, jv); }
                if str_equal(vv, "off") {
                    squig = false;
                } else if !str_equal(vv, "on") && !str_equal(vv, "editable") {
                    set_warn_add("expected \"on\" or \"off\" for ", "editor.renderValidationDecorations");
                }
            }
            // the reference's levels, 20% a step; a fraction rounds
            i32 jz = jd_get(&d, root, "window.zoomLevel");
            if jz >= 0 {
                if jd_kind(&d, jz) == J_NUM {
                    f64 zf = jd_num(&d, jz);
                    if zf < 0.0 { zoom = cast(i32, zf - 0.5); } else { zoom = cast(i32, zf + 0.5); }
                } else {
                    set_warn_add("expected a number for ", "window.zoomLevel");
                }
            }
            set_bool(&d, root, "explorer.excludeGitIgnore", &tree_hides);
            set_bool(&d, root, "search.useIgnoreFiles", &lists_use);
            i32 jx = jd_get(&d, root, "files.exclude");
            if jx >= 0 {
                if jd_kind(&d, jx) == J_OBJ {
                    ex_len = set_exclude(&d, jx, &ex[0], SET_EXCLUDE_MAX);
                } else {
                    set_warn_add("expected an object of patterns for ", "files.exclude");
                }
            }
        }
        json_free(&d);
    }
    // what the tree, the picker and search leave out (gitignore.mc); the
    // tree is built again when that changed
    if ign_settings(tree_hides, lists_use, str_from(&ex[0], ex_len)) { tree_build(); }
    if fd.data != null { free(fd.data); }
    // the file's word wrap; a preview leaves the view as it is
    if force < 0 {
        ed_wrap_set(wrap);
        g_squiggles = squig;
        ed_zoom_set(zoom);
    }
    if force >= 0 {
        // the forced theme under the file's overrides: load it, then
        // read the file again for them alone
        theme_load(force);
        settings_overrides(p);
    }
    theme_commit();
    term_palette_theme();
    if report && set_warn_len > 0 { ed_warn(str_from(&set_warn[0], set_warn_len)); }
    plat_damage();
}

// the file's color overrides over the palette as it stands
private void settings_overrides(str p) {
    FileData fd = file_read(p);
    if p.len == 0 || fd.data == null { return; }
    JDoc d;
    i32 root = json_parse_lenient(&d, fd.data, cast(i64, fd.len));
    if root >= 0 && jd_kind(&d, root) == J_OBJ {
        i32 jc = jd_get(&d, root, "workbench.colorCustomizations");
        if jc >= 0 { set_colors(&d, jc, false); }
        i32 jk = jd_get(&d, root, "editor.tokenColorCustomizations");
        if jk >= 0 { set_colors(&d, jk, true); }
    }
    json_free(&d);
    free(fd.data);
}

// --theme: a built-in theme for this run, with no overrides and no
// write to the file, so a shot can be taken in any theme
void settings_use_theme(str name) {
    i32 t = theme_find(name);
    if t < 0 {
        print("no theme by the name {}\n", name);
        return;
    }
    theme_load(t);
    theme_commit();
    term_palette_theme();
    plat_damage();
}

// The default theme without the file, for a platform that has no
// settings file (the browser)
void settings_use_default() {
    settings_use_theme(THEME_DEFAULT);
}

// --- writing --------------------------------------------------------------

// What a new settings file holds: the keys this editor reads, set to
// their defaults, and the names an override can use.
private str SETTINGS_TEMPLATE = "// edminc settings. This file is JSON; comments and trailing commas are\n// fine. It applies to every folder and window, and saving it applies it.\n//\n// workbench.colorTheme: one of the built-in themes:\n//   \"Dark+\", \"Dark Modern\", \"Light+\", \"Light Modern\", \"Abyss\",\n//   \"Ayu Dark\", \"Ayu Light\", \"Ayu Mirage\", \"Cobalt2\",\n//   \"Dracula\", \"Kimbie Dark\", \"Monokai\", \"Monokai Dimmed\",\n//   \"Night Owl\", \"Night Owl Light\", \"Nord\", \"One Dark Pro\",\n//   \"Quiet Light\", \"Red\", \"Solarized Dark\", \"Solarized Light\",\n//   \"Tokyo Night\", \"Tokyo Night Light\", \"Tomorrow Night Blue\".\n//\n// workbench.colorCustomizations: any color by its name, over\n// the theme, as \"#RRGGBB\" or \"#RRGGBBAA\". The names:\n//   editor.background editor.foreground editor.lineHighlightBackground\n//   editor.selectionBackground editor.findMatchHighlightBackground\n//   editorCursor.foreground editorLineNumber.foreground\n//   editorLineNumber.activeForeground editorLink.activeForeground\n//   scrollbarSlider.background statusBar.background statusBar.foreground\n//   sideBar.background editorGroupHeader.tabsBackground\n//   editorGroupHeader.tabsBorder editorGroup.border editorWidget.background\n//   editorWidget.border input.background focusBorder foreground\n//   descriptionForeground list.activeSelectionBackground\n//   list.inactiveSelectionBackground list.highlightForeground\n//   searchEditor.findMatchBackground titleBar.activeBackground\n//   titleBar.activeForeground editorError.foreground\n//   editorWarning.foreground editorInfo.foreground editorHint.foreground\n//   editorGutter.addedBackground editorGutter.modifiedBackground\n//   editorGutter.deletedBackground diffEditor.insertedLineBackground\n//   diffEditor.removedLineBackground diffEditor.unchangedRegionBackground\n//   diffEditor.diagonalFill gitDecoration.modifiedResourceForeground\n//   gitDecoration.addedResourceForeground\n//   gitDecoration.untrackedResourceForeground\n//   gitDecoration.deletedResourceForeground\n//   gitDecoration.conflictingResourceForeground terminal.foreground\n//   terminal.background terminal.boldForeground terminalCursor.foreground\n//   terminal.selectionBackground terminal.ansiBlack terminal.ansiRed ...\n//   terminal.ansiBrightWhite (the sixteen ANSI colors)\n//\n// editor.tokenColorCustomizations: the syntax colors, by class:\n//   keywords controlKeywords types variables functions strings escapes\n//   numbers comments directives markdownLists\n//\n// editor.smoothScrolling: a held arrow key and a mouse wheel glide.\n// editor.wordWrap: \"on\" wraps long lines at the pane's width;\n//   Alt+Z toggles it.\n// editor.renderValidationDecorations: \"off\" hides the problem\n//   underlines in the text; Ctrl+K D toggles them.\n//\n// explorer.excludeGitIgnore: hide gitignored files in the tree; false\n//   shows them dimmed.\n// search.useIgnoreFiles: leave gitignored files out of Ctrl+P and search.\n// files.exclude: glob patterns hidden everywhere, each set to true, such\n//   as \"**/*.bak\": true.\n{\n    \"workbench.colorTheme\": \"Dark Modern\",\n    \"workbench.colorCustomizations\": {\n    },\n    \"editor.tokenColorCustomizations\": {\n    },\n    \"editor.smoothScrolling\": true,\n    \"editor.wordWrap\": \"off\",\n    \"editor.renderValidationDecorations\": \"on\",\n    \"explorer.excludeGitIgnore\": false,\n    \"search.useIgnoreFiles\": true,\n    \"files.exclude\": {\n    },\n}\n";

// the file, created from the template when there is none; false when
// there is no home folder or it cannot be written
private bool settings_ensure() {
    str p = settings_path();
    if p.len == 0 { return false; }
    if path_exists(p) { return true; }
    ignore dir_create(settings_dir());
    str t = SETTINGS_TEMPLATE;
    FileData fd = FileData{ t.data, cast(i32, t.len) };
    return file_write(p, fd);
}

// Preferences: Open Settings (JSON), Ctrl+,
void settings_open() {
    if !set_on {
        ed_status("settings are off in this run");
        return;
    }
    if !settings_ensure() {
        ed_warn("settings: no home folder to keep ~/.edminc/settings.json in");
        return;
    }
    ignore ed_open_file(settings_path());
}

// Preferences: Color Theme: the theme into the file's
// "workbench.colorTheme", then the file read again.
void settings_set_theme(i32 t) {
    if t < 0 || t >= theme_count() { return; }
    if !set_on {
        ed_status("settings are off in this run");
        return;
    }
    if !settings_ensure() {
        theme_load(t);
        theme_commit();
        term_palette_theme();
        plat_damage();
        return;
    }
    str name = theme_name(t);
    u8* q = alloc<u8>(name.len + 2);
    q[0] = '"';
    memcpy(q + 1, name.data, name.len);
    q[name.len + 1] = '"';
    settings_write("workbench.colorTheme", str_from(q, name.len + 2));
    free(q);
}

// Ctrl+= / Ctrl+- / Ctrl+0: the level into "window.zoomLevel". With the
// settings off (a harness run) or no file to keep it in, it applies for
// the run alone.
void settings_set_zoom(i32 z) {
    if !set_on || !settings_ensure() {
        ed_zoom_set(z);
        return;
    }
    noinit u8[16] v;
    i32 n = 0;
    if z < 0 {
        v[0] = '-';
        n = 1;
        z = -z;
    }
    n += fmt_i32(&v[n], z);
    settings_write("window.zoomLevel", str_from(&v[0], n));
}

// One member of the file set to `val`, JSON text as it is to be
// written, the rest of the file as it was; then the file is read again.
// A value is replaced where it is; a file without the key gets it as
// the first member.
private void settings_write(str key_name, str val) {
    str p = settings_path();
    FileData fd = file_read(p);
    if fd.data == null { return; }
    str src = str_from(fd.data, cast(i32, fd.len));
    noinit u8[64] kb;
    kb[0] = '"';
    memcpy(&kb[1], key_name.data, key_name.len);
    kb[key_name.len + 1] = '"';
    str key = str_from(&kb[0], key_name.len + 2);
    i32 at = -1;
    for i32 i = 0; i + key.len <= src.len; i++ {
        if str_equal(str_from(src.data + i, key.len), key) {
            at = i;
            break;
        }
    }
    // the value's span after the key and its colon: a string to its
    // closing quote, anything else to the comma, brace or line end
    i32 v0 = -1;
    i32 v1 = -1;
    if at >= 0 {
        i32 i = at + key.len;
        while i < src.len && (src.data[i] == ' ' || src.data[i] == 9 || src.data[i] == ':') { i++; }
        if i < src.len && src.data[i] == '"' {
            i32 k = i + 1;
            while k < src.len && src.data[k] != '"' { k++; }
            if k < src.len {
                v0 = i;
                v1 = k + 1;
            }
        } else if i < src.len {
            i32 k = i;
            while k < src.len && src.data[k] != ',' && src.data[k] != '}'
                && src.data[k] != 10 && src.data[k] != 13 { k++; }
            while k > i && (src.data[k - 1] == ' ' || src.data[k - 1] == 9) { k--; }
            v0 = i;
            v1 = k;
        }
    }
    i32 cap = src.len + key.len + val.len + 64;
    u8* out = alloc<u8>(cap);
    i32 n = 0;
    if v0 >= 0 && v1 >= 0 {
        memcpy(out, src.data, v0);
        n = v0;
        memcpy(out + n, val.data, val.len);
        n += val.len;
        memcpy(out + n, src.data + v1, src.len - v1);
        n += src.len - v1;
    } else {
        // after the first brace outside a comment line
        i32 brace = -1;
        i32 i = 0;
        while i < src.len {
            if src.data[i] == '/' && i + 1 < src.len && src.data[i + 1] == '/' {
                while i < src.len && src.data[i] != 10 { i++; }
                continue;
            }
            if src.data[i] == '{' {
                brace = i;
                break;
            }
            i++;
        }
        if brace < 0 {
            free(out);
            free(fd.data);
            ed_warn("settings.json: no object to put the setting in");
            return;
        }
        memcpy(out, src.data, brace + 1);
        n = brace + 1;
        str pre = "\n    ";
        memcpy(out + n, pre.data, pre.len);
        n += pre.len;
        memcpy(out + n, key.data, key.len);
        n += key.len;
        str colon = ": ";
        memcpy(out + n, colon.data, colon.len);
        n += colon.len;
        memcpy(out + n, val.data, val.len);
        n += val.len;
        out[n] = ',';
        n++;
        memcpy(out + n, src.data + brace + 1, src.len - brace - 1);
        n += src.len - brace - 1;
    }
    FileData w = FileData{ out, n };
    bool ok = file_write(p, w);
    free(out);
    free(fd.data);
    if !ok {
        ed_warn("settings.json could not be written");
        return;
    }
    settings_load();
    // an open copy of the file follows it
    ed_disk_check_all();
}
