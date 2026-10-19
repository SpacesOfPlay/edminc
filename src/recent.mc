// recent.mc - the folders opened most recently, newest first: the list
// File: Open Recent shows, and the folder a launch that names none
// opens. One file for every window and process,
// `recent` next to settings.json, one absolute path per line. It is
// read and written only while the settings are on, so a harness run
// never touches the user's list.

import file;

private const i32 RECENT_MAX = 20;
private u8[RECENT_MAX * PATH_MAX] rc_arena;
private i32[RECENT_MAX] rc_off;
private i32[RECENT_MAX] rc_len;
private i32 rc_n = 0;
private u8[PATH_MAX] rc_path;

// set by the argument parser when the command line names a folder
private bool rc_folder_arg = false;

void app_folder_arg() { rc_folder_arg = true; }

private str recent_file() {
    str d = settings_dir();
    str tail = "/recent";
    if d.len == 0 || d.len + tail.len >= PATH_MAX { return ""; }
    memcpy(&rc_path[0], d.data, d.len);
    memcpy(&rc_path[d.len], tail.data, tail.len);
    return str_from(&rc_path[0], d.len + tail.len);
}

// Paths compare with either separator; on Windows and macOS, whose
// file systems ignore case by default, without case as well.
private u8 rc_fold(u8 c) {
    if c == 92 { return '/'; }
    when os(windows) {
        if c >= 'A' && c <= 'Z' { return cast(u8, c + 32); }
    }
    when os(macos) {
        if c >= 'A' && c <= 'Z' { return cast(u8, c + 32); }
    }
    return c;
}

bool recent_same(str a, str b) {
    while a.len > 1 && (a.data[a.len - 1] == '/' || a.data[a.len - 1] == 92) { a.len--; }
    while b.len > 1 && (b.data[b.len - 1] == '/' || b.data[b.len - 1] == 92) { b.len--; }
    if a.len != b.len { return false; }
    for i32 i = 0; i < a.len; i++ {
        if rc_fold(a.data[i]) != rc_fold(b.data[i]) { return false; }
    }
    return true;
}

private void rc_push(str p) {
    if rc_n == RECENT_MAX || p.len == 0 || p.len >= PATH_MAX { return; }
    for i32 i = 0; i < rc_n; i++ {
        if recent_same(recent_at(i), p) { return; }
    }
    i32 off = rc_n * PATH_MAX;
    memcpy(&rc_arena[off], p.data, p.len);
    rc_off[rc_n] = off;
    rc_len[rc_n] = p.len;
    rc_n++;
}

// the file into the list; an unreadable or missing file is an empty list
void recent_load() {
    rc_n = 0;
    if !settings_enabled() { return; }
    str f = recent_file();
    if f.len == 0 { return; }
    FileData fd = file_read(f);
    if fd.data == null { return; }
    i32 len = cast(i32, fd.len);
    i32 s = 0;
    for i32 i = 0; i <= len; i++ {
        if i == len || fd.data[i] == 10 {
            i32 e = i;
            if e > s && fd.data[e - 1] == 13 { e--; }
            if e > s { rc_push(str_from(fd.data + s, e - s)); }
            s = i + 1;
        }
    }
    free(fd.data);
}

private void recent_save() {
    str f = recent_file();
    if f.len == 0 { return; }
    ignore dir_create(settings_dir());
    i32 total = 0;
    for i32 i = 0; i < rc_n; i++ { total += rc_len[i] + 1; }
    u8* out = alloc<u8>(total + 1);
    i32 o = 0;
    for i32 i = 0; i < rc_n; i++ {
        memcpy(out + o, &rc_arena[rc_off[i]], rc_len[i]);
        o += rc_len[i];
        out[o] = 10;
        o++;
    }
    ignore file_write(f, FileData{ out, o });
    free(out);
    noinit str[RECENT_MAX] dirs;
    for i32 i = 0; i < rc_n; i++ { dirs[i] = recent_at(i); }
    plat_recent_folders(&dirs[0], rc_n);
}

i32 recent_count() { return rc_n; }

str recent_at(i32 i) {
    if i < 0 || i >= rc_n { return ""; }
    return str_from(&rc_arena[rc_off[i]], rc_len[i]);
}

// `dir` to the front of the list and the file. The file is read again
// first, so what other editors wrote since is kept.
void recent_add(str dir) {
    if !settings_enabled() || dir.len == 0 || dir.len >= PATH_MAX { return; }
    noinit u8[PATH_MAX] keep;
    memcpy(&keep[0], dir.data, dir.len);
    str d = str_from(&keep[0], dir.len);
    recent_load();
    // the list rebuilt with d first; the old entries are copied out of
    // the arena before it is overwritten
    i32 n = rc_n;
    u8* old = alloc<u8>(RECENT_MAX * PATH_MAX);
    memcpy(old, &rc_arena[0], RECENT_MAX * PATH_MAX);
    noinit i32[RECENT_MAX] ooff;
    noinit i32[RECENT_MAX] olen;
    for i32 i = 0; i < n; i++ {
        ooff[i] = rc_off[i];
        olen[i] = rc_len[i];
    }
    rc_n = 0;
    rc_push(d);
    for i32 i = 0; i < n; i++ { rc_push(str_from(old + ooff[i], olen[i])); }
    free(old);
    recent_save();
}

// A folder the user removed from the shell's list leaves this one too.
// The file is written only when the folder was on it, so a shell that
// reports it again does not start another round.
void app_recent_forget(str dir) {
    if !settings_enabled() { return; }
    recent_load();
    i32 w = 0;
    for i32 i = 0; i < rc_n; i++ {
        if recent_same(recent_at(i), dir) { continue; }
        // into slot w, where the next push expects the entries to end
        if w != i { memcpy(&rc_arena[w * PATH_MAX], &rc_arena[rc_off[i]], rc_len[i]); }
        rc_off[w] = w * PATH_MAX;
        rc_len[w] = rc_len[i];
        w++;
    }
    if w == rc_n { return; }
    rc_n = w;
    recent_save();
}

// the working directory to the front
void recent_note() {
    noinit u8[PATH_MAX] cwd;
    i32 n = plat_cwd(&cwd[0], PATH_MAX);
    if n > 0 { recent_add(str_from(&cwd[0], n)); }
}

// At startup, before the session loads: a launch that names no folder
// opens the newest one on the list that still exists, wherever it
// started, as the reference editor does; `edmc .` opens the working
// directory. With an empty list it stays where it started. False when
// it stays.
bool recent_launch() {
    if rc_folder_arg { return false; }
    recent_load();
    noinit u8[PATH_MAX] cwd;
    str here = str_from(&cwd[0], plat_cwd(&cwd[0], PATH_MAX));
    for i32 i = 0; i < rc_n; i++ {
        str d = recent_at(i);
        if recent_same(d, here) { return false; }
        if !path_is_dir(d) { continue; }
        noinit u8[PATH_MAX] keep;
        memcpy(&keep[0], d.data, d.len);
        return ed_open_folder(str_from(&keep[0], d.len));
    }
    return false;
}
