// harness_plat.mc - the platform stubs the two headless harnesses
// (ed_test, ed_fuzz) share: a folder switch that is recorded rather
// than entered, a directory listing that reaches the node host on the
// browser target, and the git the change gutter asks for, answered
// from the working tree with lines dropped so a diff has something to
// show. Each harness keeps the stubs whose answers are its own.

// the folder is recorded, not entered: the harness stays where it
// runs, and a name that says so is refused as a real one would be
u8[PATH_MAX] g_chdir_last;
i32 g_chdir_last_len = 0;
bool plat_chdir(str dir) {
    if dir.len > PATH_MAX { return false; }
    memcpy(&g_chdir_last[0], dir.data, dir.len);
    g_chdir_last_len = dir.len;
    for i32 i = 0; i + 7 <= dir.len; i++ {
        if str_equal(str_from(dir.data + i, 7), "nowhere") { return false; }
    }
    return true;
}

i32 plat_exe_dir(u8* out, i32 cap) { return 0; }

// directory listing: the stdlib's on a native host. A browser-target
// build of the harness runs under node (scripts/wasm_fuzz.mjs), where
// the stdlib cannot list or delete, so that host answers through an
// import.
when os(wasm) {
    extern "harness" {
        i32 harness_dir_list(u8* dir, i32 dn, i32 want_dirs, u8* buf, i32 cap);
        i32 harness_file_remove(u8* path, i32 n);
    }
}

// the stdlib cannot delete on the browser target; the node host can
void test_remove(str path) {
    when os(wasm) {
        ignore harness_file_remove(path.data, path.len);
    } else {
        ignore file_remove(path);
    }
}

DirList plat_dir_list(str dir, bool want_dirs) {
    when os(wasm) {
        DirList l;
        i32 cap = 65536;
        u8* buf = alloc<u8>(cap);
        i32 wd = 0;
        if want_dirs { wd = 1; }
        i32 n = harness_dir_list(dir.data, dir.len, wd, buf, cap);
        if n < 0 {
            free(buf);
            cap = -n;
            buf = alloc<u8>(cap);
            n = harness_dir_list(dir.data, dir.len, wd, buf, cap);
        }
        i32 count = 0;
        for i32 i = 0; i < n; i++ {
            if buf[i] == 10 { count++; }
        }
        if count > 0 {
            l.items = alloc<str>(count);
            i32 s = 0;
            for i32 i = 0; i < n; i++ {
                if buf[i] != 10 { continue; }
                i32 len = i - s;
                u8* copy = alloc<u8>(len + 1);
                memcpy(copy, buf + s, len);
                copy[len] = 0;
                l.items[l.count] = str_from(copy, len);
                l.count++;
                s = i + 1;
            }
            l._cap = count;
        }
        free(buf);
        return l;
    } else {
        return dir_list(dir, "", want_dirs);
    }
}

// The history the graph reads (hist.mc): five commits, newest first,
// in which a side branch leaves the fourth and merges back into the
// first, and the fifth is the root. The hashes are one digit repeated.
private str harness_log_reply() {
    return "1111111111111111111111111111111111111111\x1f2222222222222222222222222222222222222222 3333333333333333333333333333333333333333\x1fAda\x1f1700000500\x1fHEAD -> main\x1fmerge the side branch\x1e\n2222222222222222222222222222222222222222\x1f4444444444444444444444444444444444444444\x1fAda\x1f1700000400\x1f\x1fmain: a second change\x1e\n3333333333333333333333333333333333333333\x1f4444444444444444444444444444444444444444\x1fBob\x1f1700000300\x1fside\x1fside: a change\x1e\n4444444444444444444444444444444444444444\x1f5555555555555555555555555555555555555555\x1fAda\x1f1700000200\x1f\x1fboth start here\x1e\n5555555555555555555555555555555555555555\x1f\x1fAda\x1f1700000100\x1ftag: v0\x1fthe first commit\x1e\n";
}

private u8* harness_reply(str s, i64* out_len, i32* out_code) {
    u8* r = alloc<u8>(s.len + 1);
    memcpy(r, s.data, s.len);
    *out_len = s.len;
    *out_code = 0;
    return r;
}

// The git the gutter runs: `rev-parse` says the root is here, and
// `show HEAD:<path>` is the file as it is with every drop_mod-th line
// left out, so the baseline differs from the buffer in a known way.
// `show <hash>:<path>` leaves out every n-th line, n from the hash's
// first digit, so a commit's two sides differ too. `log` answers the
// history above in one page, and `diff-tree` a commit's files: the
// root's one added file, or one changed and one deleted file.
// Anything else is unanswered. `argv` is the command from its second
// word on; null for one not handled.
u8* harness_git(str* argv, i32 argc, i32 drop_mod, i64* out_len, i32* out_code) {
    if argc < 3 { return null; }
    if str_equal(argv[1], "rev-parse") {
        str reply = ".\n\n";
        u8* r = alloc<u8>(reply.len);
        memcpy(r, reply.data, reply.len);
        *out_len = reply.len;
        *out_code = 0;
        return r;
    }
    if str_equal(argv[1], "log") {
        for i32 a = 2; a < argc; a++ {
            if str_equal(argv[a], "--skip=0") { return harness_reply(harness_log_reply(), out_len, out_code); }
        }
        return harness_reply("", out_len, out_code);
    }
    if str_equal(argv[1], "diff-tree") {
        for i32 a = 2; a < argc; a++ {
            if str_equal(argv[a], "--root") { return harness_reply("A\0src/pick.mc\0", out_len, out_code); }
        }
        return harness_reply("M\0src/pick.mc\0D\0doc/TESTING.md\0", out_len, out_code);
    }
    if !str_equal(argv[1], "show") { return null; }
    str spec = argv[2];
    i32 colon = -1;
    for i32 k = 0; k < spec.len; k++ {
        if spec.data[k] == ':' { colon = k; break; }
    }
    if colon < 1 || colon + 1 >= spec.len { return null; }
    if !(colon == 4 && str_equal(str_from(spec.data, 4), "HEAD")) {
        u8 d = spec.data[0];
        if d >= '0' && d <= '9' { drop_mod = 3 + cast(i32, d - '0') % 5; }
    }
    FileData fd = file_read(str_from(spec.data + colon + 1, spec.len - colon - 1));
    if fd.data == null { return null; }
    u8* r = alloc<u8>(fd.len + 1);
    i64 w = 0;
    i32 line = 0;
    i64 s = 0;
    for i64 i = 0; i <= fd.len; i++ {
        if i == fd.len || fd.data[i] == '\n' {
            if line % drop_mod != drop_mod - 1 {
                i64 n = i - s;
                if i < fd.len { n++; }
                memcpy(r + w, fd.data + s, n);
                w += n;
            }
            line++;
            s = i + 1;
        }
    }
    free(fd.data);
    *out_len = w;
    *out_code = 0;
    return r;
}

// no watcher: the checks hand records to watch_feed themselves
i32 plat_watch_open(str dir) { return -1; }
i64 plat_watch_read(i32 h, u8* buf, i64 cap) { return -1; }
void plat_watch_close(i32 h) {}
void plat_watch_free(i32 h) {}
