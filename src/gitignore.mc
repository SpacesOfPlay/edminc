// gitignore.mc - which entries of the project the tree, the picker, search
// and the watcher leave out or show dimmed.
// Two sources. The gitignore rules: .git/info/exclude and the root
// .gitignore, then the .gitignore of each folder on the way down, read
// the first time a walk asks for that folder. And the settings:
// explorer.excludeGitIgnore hides ignored entries in the tree instead of
// dimming them, search.useIgnoreFiles (on by default) keeps them out of
// the picker and search, and files.exclude hides its patterns
// everywhere, as .git and .edminc always are.
// Paths are relative to the project, '/'-separated, without "./".

import file;

private const i32 IGN_FILES_MAX = 1024;
private const i32 IGN_RULES_MAX = 16384;
private const i32 IGN_EXCLUDE_MAX = 128;

// one pattern line of an ignore file
private struct IgnRule {
    i32 off;         // the pattern in the arena, without "!", a leading "/" or a trailing "/"
    i32 len;
    bool neg;        // "!": a match un-ignores
    bool dir_only;   // "name/": folders only
    bool anchored;   // a "/" before the end: matched against the path from the file's folder
}

// the rules one folder's .gitignore holds (the root's also holds
// .git/info/exclude, first)
private struct IgnFile {
    i32 dir_off;     // the folder, in the arena; "" for the root
    i32 dir_len;
    i32 first;       // its rules
    i32 n;
}

private u8* ign_arena = null;
private i64 ign_alen = 0;
private i64 ign_acap = 0;
private IgnFile[IGN_FILES_MAX] ign_files;
private i32 ign_nfiles = 0;
private IgnRule[IGN_RULES_MAX] ign_rules;
private i32 ign_nrules = 0;

// the settings
private bool ign_tree_hides = false;
private bool ign_lists_use = true;
private i32[IGN_EXCLUDE_MAX] ign_ex_off;
private i32[IGN_EXCLUDE_MAX] ign_ex_len;
private i32 ign_nex = 0;

private i32 ign_put(u8* p, i32 n) {
    if ign_alen + n > ign_acap {
        i64 ncap = ign_acap * 2 + 65536;
        while ncap < ign_alen + n { ncap *= 2; }
        u8* na = alloc<u8>(ncap);
        if ign_arena != null {
            memcpy(na, ign_arena, ign_alen);
            free(ign_arena);
        }
        ign_arena = na;
        ign_acap = ncap;
    }
    i32 off = cast(i32, ign_alen);
    memcpy(ign_arena + ign_alen, p, n);
    ign_alen += n;
    return off;
}

// --- the patterns -------------------------------------------------------

// Git compares names without case where the file system does
private u8 ign_fold(u8 c) {
    when os(windows) {
        if c >= 'A' && c <= 'Z' { return cast(u8, c + 32); }
    }
    when os(macos) {
        if c >= 'A' && c <= 'Z' { return cast(u8, c + 32); }
    }
    return c;
}

// "[...]" at p[0] against c; the length of the class, or 0 when it is
// not closed (a literal "[" then)
private i32 ign_class(u8* p, i32 pn, u8 c, bool* hit) {
    i32 i = 1;
    bool neg = false;
    if i < pn && (p[i] == '!' || p[i] == '^') {
        neg = true;
        i++;
    }
    bool any = false;
    bool first = true;
    while i < pn && (p[i] != ']' || first) {
        first = false;
        u8 lo = p[i];
        if lo == 92 && i + 1 < pn {
            i++;
            lo = p[i];
        }
        u8 hi = lo;
        if i + 2 < pn && p[i + 1] == '-' && p[i + 2] != ']' {
            hi = p[i + 2];
            i += 2;
        }
        u8 fc = ign_fold(c);
        if (c >= lo && c <= hi) || (fc >= ign_fold(lo) && fc <= ign_fold(hi)) { any = true; }
        i++;
    }
    if i >= pn { return 0; }
    *hit = any != neg && c != '/';
    return i + 1;
}

// Git's wildmatch with pathnames: "*" and "?" stop at "/", "**" as a
// whole segment spans folders, "[...]" is a class, "\" escapes.
bool ign_wild(u8* p, i32 pn, u8* s, i32 sn) {
    i32 pi = 0;
    i32 si = 0;
    while pi < pn {
        u8 c = p[pi];
        if c == '*' {
            i32 q = pi;
            while q < pn && p[q] == '*' { q++; }
            bool seg = q - pi >= 2 && (pi == 0 || p[pi - 1] == '/') && (q == pn || p[q] == '/');
            if seg {
                // "a/**": everything inside; "**/b" and "a/**/b": any
                // number of folders, none included
                if q == pn { return true; }
                i32 rest = q + 1;
                i32 k = si;
                while true {
                    if ign_wild(p + rest, pn - rest, s + k, sn - k) { return true; }
                    while k < sn && s[k] != '/' { k++; }
                    if k >= sn { return false; }
                    k++;
                }
            }
            i32 k = si;
            while true {
                if ign_wild(p + q, pn - q, s + k, sn - k) { return true; }
                if k >= sn || s[k] == '/' { return false; }
                k++;
            }
        }
        if si >= sn { return false; }
        if c == '?' {
            if s[si] == '/' { return false; }
            pi++;
            si++;
            continue;
        }
        if c == '[' {
            bool hit = false;
            i32 cl = ign_class(p + pi, pn - pi, s[si], &hit);
            if cl > 0 {
                if !hit { return false; }
                pi += cl;
                si++;
                continue;
            }
        }
        if c == 92 && pi + 1 < pn {
            pi++;
            c = p[pi];
        }
        if ign_fold(s[si]) != ign_fold(c) { return false; }
        pi++;
        si++;
    }
    return si == sn;
}

// the lines of an ignore file into rules
private void ign_parse(u8* d, i64 len) {
    i64 i = 0;
    while i < len {
        i64 s = i;
        while i < len && d[i] != 10 { i++; }
        i64 e = i;
        i++;
        if e > s && d[e - 1] == 13 { e--; }
        // trailing spaces go unless escaped
        while e > s && d[e - 1] == ' ' && !(e - 2 >= s && d[e - 2] == 92) { e--; }
        if e == s || d[s] == '#' { continue; }
        bool neg = false;
        if d[s] == '!' {
            neg = true;
            s++;
        } else if d[s] == 92 && s + 1 < e && (d[s + 1] == '#' || d[s + 1] == '!') {
            s++;
        }
        bool dir_only = false;
        if e > s && d[e - 1] == '/' {
            dir_only = true;
            e--;
        }
        bool anchored = false;
        if e > s && d[s] == '/' {
            anchored = true;
            s++;
        }
        for i64 k = s; k < e; k++ {
            if d[k] == '/' { anchored = true; }
        }
        if e <= s || ign_nrules == IGN_RULES_MAX { continue; }
        i32 off = ign_put(d + s, cast(i32, e - s));
        ign_rules[ign_nrules] = IgnRule{ off, cast(i32, e - s), neg, dir_only, anchored };
        ign_nrules++;
    }
}

private void ign_read_into(str path) {
    FileData fd = file_read(path);
    if fd.data == null { return; }
    ign_parse(fd.data, cast(i64, fd.len));
    free(fd.data);
}

// the folder's rules, read on first use; -1 when the table is full
private i32 ign_file(str dir) {
    for i32 i = 0; i < ign_nfiles; i++ {
        IgnFile* f = &ign_files[i];
        if f.dir_len == dir.len && str_equal(str_from(ign_arena + f.dir_off, f.dir_len), dir) { return i; }
    }
    if ign_nfiles == IGN_FILES_MAX { return -1; }
    i32 off = ign_put(dir.data, dir.len);
    i32 first = ign_nrules;
    if dir.len == 0 {
        ign_read_into(".git/info/exclude");
        ign_read_into(".gitignore");
    } else {
        noinit u8[PATH_MAX] pb;
        str tail = "/.gitignore";
        if dir.len + tail.len < PATH_MAX {
            memcpy(&pb[0], dir.data, dir.len);
            memcpy(&pb[dir.len], tail.data, tail.len);
            ign_read_into(str_from(&pb[0], dir.len + tail.len));
        }
    }
    ign_files[ign_nfiles] = IgnFile{ off, dir.len, first, ign_nrules - first };
    ign_nfiles++;
    return ign_nfiles - 1;
}

// --- the answers --------------------------------------------------------

// Every ignore file is read again when next asked: a .gitignore
// changed, or the folder did.
void ign_reset() {
    ign_nfiles = 0;
    ign_nrules = 0;
    ign_alen = 0;
    // the patterns of files.exclude live in the same arena
    ign_nex = 0;
    ign_exclude_reload();
}

// What the rules say about `path` itself, the folders above it aside: the
// rules of each folder from the root down, the last match deciding. A
// caller walking the tree carries a folder's answer down to what is in
// it; ign_git asks for every folder on the way.
bool ign_match(str path, bool is_dir) {
    bool ign = false;
    i32 start = 0;   // where the part relative to the current folder begins
    i32 i = 0;
    while true {
        str dir = str_from(path.data, 0);
        if start > 0 { dir = str_from(path.data, start - 1); }
        i32 fi = ign_file(dir);
        if fi >= 0 {
            IgnFile* f = &ign_files[fi];
            str rel = str_from(path.data + start, path.len - start);
            i32 b = rel.len;
            while b > 0 && rel.data[b - 1] != '/' { b--; }
            for i32 r = f.first; r < f.first + f.n; r++ {
                IgnRule* ru = &ign_rules[r];
                if ru.dir_only && !is_dir { continue; }
                bool hit = false;
                if ru.anchored {
                    hit = ign_wild(ign_arena + ru.off, ru.len, rel.data, rel.len);
                } else {
                    hit = ign_wild(ign_arena + ru.off, ru.len, rel.data + b, rel.len - b);
                }
                if hit { ign = !ru.neg; }
            }
        }
        // the next folder down, while there is one above the entry
        while i < path.len && path.data[i] != '/' { i++; }
        if i >= path.len { break; }
        i++;
        start = i;
    }
    return ign;
}

// gitignored, or inside a gitignored folder
bool ign_git(str path, bool is_dir) {
    for i32 i = 0; i < path.len; i++ {
        if path.data[i] == '/' && ign_match(str_from(path.data, i), true) { return true; }
    }
    return ign_match(path, is_dir);
}

// hidden everywhere: .git, .edminc and the files.exclude patterns
bool ign_excluded(str path) {
    i32 b = path.len;
    while b > 0 && path.data[b - 1] != '/' { b--; }
    str name = str_from(path.data + b, path.len - b);
    if str_equal(name, ".git") || str_equal(name, ".edminc") { return true; }
    for i32 k = 0; k < ign_nex; k++ {
        if ign_wild(ign_arena + ign_ex_off[k], ign_ex_len[k], path.data, path.len) { return true; }
    }
    return false;
}

// the tree leaves the entry out; `git` is what the walk knows of it
bool ign_tree_hidden(str path, bool git) {
    return ign_excluded(path) || (git && ign_tree_hides);
}

// the tree hides gitignored entries rather than dimming them
bool ign_tree_hides_now() { return ign_tree_hides; }

// the picker, search and the watcher leave it out
bool ign_lists_skip(str path, bool git) {
    return ign_excluded(path) || (git && ign_lists_use);
}

// --- the settings (settings.mc) -------------------------------------------

private u8[4096] ign_ex_text;   // the patterns as the settings gave them
private i32 ign_ex_text_len = 0;

private void ign_exclude_reload() {
    ign_nex = 0;
    i32 i = 0;
    while i < ign_ex_text_len && ign_nex < IGN_EXCLUDE_MAX {
        i32 s = i;
        while i < ign_ex_text_len && ign_ex_text[i] != 10 { i++; }
        if i > s {
            // a leading "./" or "/" means the project's top
            i32 a = s;
            if i - a >= 2 && ign_ex_text[a] == '.' && ign_ex_text[a + 1] == '/' { a += 2; }
            if i - a >= 1 && ign_ex_text[a] == '/' { a++; }
            i32 e = i;
            if e > a && ign_ex_text[e - 1] == '/' { e--; }
            if e > a {
                ign_ex_off[ign_nex] = ign_put(&ign_ex_text[a], e - a);
                ign_ex_len[ign_nex] = e - a;
                ign_nex++;
            }
        }
        i++;
    }
}

// The settings' three keys: whether the tree hides ignored entries,
// whether the picker and search do, and the files.exclude patterns, one
// per line. True when anything changed, so the tree is built again.
bool ign_settings(bool tree_hides, bool lists_use, str exclude) {
    bool same = tree_hides == ign_tree_hides && lists_use == ign_lists_use
        && exclude.len == ign_ex_text_len
        && str_equal(exclude, str_from(&ign_ex_text[0], ign_ex_text_len));
    ign_tree_hides = tree_hides;
    ign_lists_use = lists_use;
    i32 n = exclude.len;
    if n > 4096 { n = 4096; }
    memcpy(&ign_ex_text[0], exclude.data, n);
    ign_ex_text_len = n;
    ign_exclude_reload();
    return !same;
}
