// build.mc - build (and run) edminc, the minc code editor.
//
// Usage, from this folder:
//   minc run [file.mc]      build + open the editor
//   minc build              compile only
//   minc test               build + render one frame + exit (smoke check)
//   minc wasm [--no-browser]   build for the browser, serve build/web
//   minc wasm --no-serve       build the browser bundle into build/web
//                              and exit (for CI that deploys it)
//   minc clean
//
// Windows (D3D11 + Win32), macOS (Metal + AppKit), and Linux
// (OpenGL + Xlib).
//
// The minc compiler is taken from MINC, then PATH. Install minc from
// https://minc.dev.

@minc_min_version "0.9.15"

// Older minc ignores the tag above; this forces a clear error there.
when !defined(MINC_VERSION) || MINC_VERSION < 9015 {
    minc_0_9_15_or_newer_required please_update_minc;
}

import process;
import file;
import str;
import icon_edmc;

when os(windows) { str EXE_SUFFIX = ".exe"; }
when !os(windows) { str EXE_SUFFIX = ""; }

void die(str s) {
    eprint("{}\n", s);
    exit(1);
    return;
}

// "<dir>/<name><ext>", without leaking the joined name.
string join_named(str dir, str name, str ext) {
    string base = str_concat(name, ext);
    defer free(base);
    return path_join(dir, str_from(base.data, base.len));
}

// MINC first (an install dir or the binary itself), then PATH.
string find_minc() {
    string env = env_get("MINC");
    if env.len > 0 {
        str e = str_from(env.data, env.len);
        if path_is_dir(e) {
            // an install directory: the binary inside it, named per
            // platform; when it is not there, PATH decides as usual
            string cand = join_named(e, "minc", EXE_SUFFIX);
            free(env);
            if path_exists(str_from(cand.data, cand.len)) { return cand; }
            free(cand);
            return path_which("minc");
        }
        return env;
    }
    free(env);
    return path_which("minc");
}

str g_cc = "";

when os(windows) {
    private extern "kernel32.dll" {
        i32 MoveFileA(u8* src, u8* dst);
        void* BeginUpdateResourceA(u8* file, i32 delete_existing);
        i32 UpdateResourceA(void* h, void* type, void* name, u16 lang, void* data, u32 size);
        i32 EndUpdateResourceA(void* h, i32 discard);
    }
}

// The window's icon is made at run time (lib/plat_win.mc), but the shell
// reads an executable's icon from its resources: a pinned taskbar entry,
// a shortcut and Explorer show that one. So the build writes the logo's
// PNGs into the file as an icon group, which Windows reads as PNG at
// every size. The group's first entry is the one the shell takes.
private const u16 RT_ICON = 3;
private const u16 RT_GROUP_ICON = 14;
private const i32 ICON_DIR_LEN = 6;
private const i32 ICON_ENTRY_LEN = 14;
private const u16 ICON_GROUP_ID = 1;

private void put_u16(u8* p, i32 v) {
    p[0] = cast(u8, v & 0xFF);
    p[1] = cast(u8, (v >> 8) & 0xFF);
}

private bool build_icon(str exe) {
    when os(windows) {
        u8* path = str_to_cstr(exe);
        void* h = BeginUpdateResourceA(path, 0);
        free(path);
        if h == null { return false; }
        i32 n = ICON_EDMC_NSIZES;
        u8* grp = alloc<u8>(ICON_DIR_LEN + n * ICON_ENTRY_LEN);
        memset(grp, 0, ICON_DIR_LEN + n * ICON_ENTRY_LEN);
        put_u16(grp + 2, 1);   // an icon, not a cursor
        put_u16(grp + 4, n);
        bool ok = true;
        // the largest first, for the shell
        for i32 k = 0; k < n; k++ {
            i32 i = n - 1 - k;
            i32 side = 0;
            str png = icon_edmc_png_at(i, &side);
            u16 id = cast(u16, i + 1);
            if UpdateResourceA(h, cast(void*, cast(u64, RT_ICON)), cast(void*, cast(u64, id)), 0,
                    cast(void*, png.data), cast(u32, png.len)) == 0 {
                ok = false;
            }
            u8* e = grp + ICON_DIR_LEN + k * ICON_ENTRY_LEN;
            if side < 256 {   // 0 stands for 256
                e[0] = cast(u8, side);
                e[1] = cast(u8, side);
            }
            put_u16(e + 4, 1);    // planes
            put_u16(e + 6, 32);   // bits per pixel
            put_u16(e + 8, cast(i32, png.len & 0xFFFF));
            put_u16(e + 10, cast(i32, (png.len >> 16) & 0xFFFF));
            put_u16(e + 12, cast(i32, id));
        }
        if UpdateResourceA(h, cast(void*, cast(u64, RT_GROUP_ICON)), cast(void*, cast(u64, ICON_GROUP_ID)), 0,
                cast(void*, grp), cast(u32, ICON_DIR_LEN + n * ICON_ENTRY_LEN)) == 0 {
            ok = false;
        }
        free(grp);
        if EndUpdateResourceA(h, 0) == 0 { ok = false; }
        return ok;
    }
    return true;
}

// Windows will not let the compiler write an executable while a process
// runs it, but it does allow renaming one, and the running image keeps
// going under the new name. So the editor rebuilt from inside itself
// puts the old binary aside and the new build takes the real name; the
// one put aside goes at the next build, when nothing holds it any more.
// Everywhere else this is nothing: a write over a running binary is
// allowed and the rename never happens.
// A free name to put the running image under. The plain one is taken
// while a process still runs what was put there by an earlier build, so
// the numbered ones follow: building twice before restarting leaves two
// images behind, and each goes as soon as nothing holds it.
private u8[64] g_aside_buf;
private str build_aside(str exe) {
    when os(windows) {
        if !str_equal(exe, "build/edmc.exe") { return ""; }
        for i32 i = 0; i < 9; i++ {
            str head = "build/edmc.old";
            i32 n = head.len;
            memcpy(&g_aside_buf[0], head.data, head.len);
            if i > 0 {
                g_aside_buf[n] = cast(u8, '0' + i);
                n++;
            }
            str tail = ".exe";
            memcpy(&g_aside_buf[n], tail.data, tail.len);
            n += tail.len;
            str cand = str_from(&g_aside_buf[0], n);
            ignore file_remove(cand);   // a previous one, when it is free
            if !path_exists(cand) { return cand; }
        }
    }
    return "";
}

private bool build_move(str src, str dst) {
    when os(windows) {
        u8* a = str_to_cstr(src);
        u8* b = str_to_cstr(dst);
        i32 ok = MoveFileA(a, b);
        free(a);
        free(b);
        return ok != 0;
    }
    return false;
}

// --- the browser build -------------------------------------------------
// build/web holds the module, the page and its script (staged by the
// compiler from the tags in lib/plat_web.mc), the project's files
// under fs/ for the page's file system, and files.json naming them.
// The compiler serves that directory; from inside a project every
// verb comes back here, so it runs from build/ with the paths adjusted.

private u8* wm_buf = null;     // files.json under construction
private i64 wm_len = 0;
private i64 wm_cap = 0;

private void wm_put(str s) {
    if wm_len + s.len > wm_cap {
        i64 ncap = wm_cap * 2 + s.len + 4096;
        u8* nb = alloc<u8>(ncap);
        if wm_buf != null {
            memcpy(nb, wm_buf, wm_len);
            free(wm_buf);
        }
        wm_buf = nb;
        wm_cap = ncap;
    }
    memcpy(wm_buf + wm_len, s.data, s.len);
    wm_len += s.len;
}

// names the root .gitignore lists as plain entries, plus the two the
// page never needs
private bool web_skip(str name) {
    if str_equal(name, ".git") || str_equal(name, "build") { return true; }
    FileData ig = file_read(".gitignore");
    if ig.data == null { return false; }
    defer free(ig.data);
    i32 s = 0;
    for i32 i = 0; i <= ig.len; i++ {
        if i < ig.len && ig.data[i] != 10 { continue; }
        i32 e = i;
        while e > s && (ig.data[e - 1] == 13 || ig.data[e - 1] == '/' || ig.data[e - 1] == ' ') { e--; }
        i32 b = s;
        while b < e && ig.data[b] == '/' { b++; }
        if e > b && str_equal(str_from(ig.data + b, e - b), name) { return true; }
        s = i + 1;
    }
    return false;
}

private i32 web_copy_tree(str rel) {
    str src = ".";
    if rel.len > 0 { src = rel; }
    string dst = path_join("build/web/fs", rel);
    defer free(dst);
    if rel.len > 0 { ignore dir_create(str_from(dst.data, dst.len)); }

    DirList fl = dir_list(src, "", false);
    for i32 i = 0; i < fl.count; i++ {
        str nm = fl.items[i];
        if rel.len == 0 && web_skip(nm) { continue; }
        string sp = path_join(src, nm);
        defer free(sp);
        string dp = path_join(str_from(dst.data, dst.len), nm);
        defer free(dp);
        FileData fd = file_read(str_from(sp.data, sp.len));
        if fd.data == null { continue; }
        bool ok = file_write(str_from(dp.data, dp.len), fd);
        free(fd.data);
        if !ok {
            print("could not write into build/web/fs\n");
            return 1;
        }
        // the color emoji font is staged but left out of the manifest, so
        // the page's eager seed does not stall on ~10 MB; the page fetches
        // it in the background after start (edminc_host.js).
        if str_equal(rel, "assets") && str_equal(nm, "NotoColorEmoji.ttf") { continue; }
        if wm_len > 1 { wm_put(","); }
        wm_put("\"");
        if rel.len > 0 {
            wm_put(rel);
            wm_put("/");
        }
        wm_put(nm);
        wm_put("\"");
    }
    dir_list_free(&fl);

    DirList dl = dir_list(src, "", true);
    for i32 i = 0; i < dl.count; i++ {
        str nm = dl.items[i];
        if web_skip(nm) { continue; }
        string sub = path_join(rel, nm);
        defer free(sub);
        if rel.len == 0 {
            if web_copy_tree(nm) != 0 { return 1; }
        } else if web_copy_tree(str_from(sub.data, sub.len)) != 0 {
            return 1;
        }
    }
    dir_list_free(&dl);
    return 0;
}

// --- the language server for the page ------------------------------------
// The page's language server is a browser build of minc-lsp. The
// installed toolchain ships one beside the compiler as minc-lsp.wasm;
// MINC_LSP_WASM overrides it, and an older playground build under the
// name minc_lsp_web.wasm still works. The page's worker resolves imports against stdlib sources,
// so the import closure of the project's stdlib modules is staged
// under build/web/lsplib with lsplib.json naming them (the worker maps
// them to lib/; the editor's own tree never sees them).

private const i32 CL_CAP = 4096;
private u8[CL_CAP] cl_names;    // staged stdlib module names, newline joined
private i32 cl_len = 0;

private bool cl_has(str name) {
    i32 s = 0;
    for i32 i = 0; i <= cl_len; i++ {
        if i < cl_len && cl_names[i] != 10 { continue; }
        if str_equal(str_from(&cl_names[s], i - s), name) { return true; }
        s = i + 1;
    }
    return false;
}

// every `import x;` in `text`, resolved: a project module is skipped,
// a stdlib one is staged and walked in turn
private i32 cl_walk(u8* text, i64 n, str libdir, i32 depth) {
    if depth > 16 { return 0; }
    i64 i = 0;
    while i < n {
        i64 ls = i;
        while i < n && text[i] != 10 { i++; }
        i64 le = i;
        i++;
        while ls < le && text[ls] == ' ' { ls++; }   // imports inside a when block
        str kw = "import ";
        if le - ls <= kw.len || !str_equal(str_from(text + ls, kw.len), kw) { continue; }
        i64 b = ls + kw.len;
        while b < le && text[b] == ' ' { b++; }
        i64 e = b;
        while e < le && text[e] != ';' && text[e] != ' ' && text[e] != 13 { e++; }
        if e <= b { continue; }
        str name = str_from(text + b, cast(i32, e - b));
        if cl_has(name) { continue; }
        string pl = join_named("lib", name, ".mc");
        defer free(pl);
        string ps = join_named("src", name, ".mc");
        defer free(ps);
        if path_exists(str_from(pl.data, pl.len)) || path_exists(str_from(ps.data, ps.len)) { continue; }
        string sl = join_named(libdir, name, ".mc");
        defer free(sl);
        FileData fd = file_read(str_from(sl.data, sl.len));
        if fd.data == null { continue; }
        if cl_len + name.len + 1 < CL_CAP {
            memcpy(&cl_names[cl_len], name.data, name.len);
            cl_len += name.len;
            cl_names[cl_len] = 10;
            cl_len++;
        }
        string dst = join_named("build/web/lsplib", name, ".mc");
        defer free(dst);
        ignore file_write(str_from(dst.data, dst.len), fd);
        ignore cl_walk(fd.data, cast(i64, fd.len), libdir, depth + 1);
        free(fd.data);
    }
    return 0;
}

private void stage_lsp() {
    string lsp = env_get("MINC_LSP_WASM");
    if lsp.len == 0 {
        free(lsp);
        // The installed toolchain ships the browser build beside the
        // compiler as minc-lsp.wasm, and that copy is built from the
        // same sources as the stdlib staged under lsplib. A playground
        // build carries the older name; take it only when the installed
        // one is absent, or the page gets a server from one compiler
        // and sources from another.
        lsp = path_join(path_dirname(g_cc), "minc-lsp.wasm");
        if !path_exists(str_from(lsp.data, lsp.len)) {
            free(lsp);
            lsp = path_join(path_dirname(g_cc), "minc_lsp_web.wasm");
        }
    }
    defer free(lsp);
    FileData fd = file_read(str_from(lsp.data, lsp.len));
    if fd.data == null {
        print("no minc-lsp.wasm beside the compiler (set MINC_LSP_WASM): the page runs without a language server\n");
        return;
    }
    bool ok = file_write("build/web/minc_lsp_web.wasm", fd);
    free(fd.data);
    if !ok { return; }

    ignore dir_create("build/web/lsplib");
    string libdir = path_join(path_dirname(g_cc), "lib");
    defer free(libdir);
    cl_len = 0;
    // the project's own modules, walked for their stdlib imports
    str[2] roots = { "src", "lib" };
    for i32 r = 0; r < 2; r++ {
        DirList fl = dir_list(roots[r], ".mc", false);
        for i32 i = 0; i < fl.count; i++ {
            string p = path_join(roots[r], fl.items[i]);
            defer free(p);
            FileData src = file_read(str_from(p.data, p.len));
            if src.data == null { continue; }
            ignore cl_walk(src.data, cast(i64, src.len), str_from(libdir.data, libdir.len), 0);
            free(src.data);
        }
        dir_list_free(&fl);
    }
    wm_len = 0;
    wm_put("[");
    i32 s = 0;
    bool first = true;
    for i32 i = 0; i < cl_len; i++ {
        if cl_names[i] != 10 { continue; }
        if !first { wm_put(","); }
        first = false;
        wm_put("\"");
        wm_put(str_from(&cl_names[s], i - s));
        wm_put(".mc\"");
        s = i + 1;
    }
    wm_put("]");
    FileData mf = FileData{ wm_buf, cast(i32, wm_len) };
    ignore file_write("build/web/lsplib.json", mf);
    print("staged the language server and its stdlib sources\n");
}

// --- the color emoji font ------------------------------------------------
// A CBLC/CBDT bitmap font (Noto Color Emoji) is large and not committed
// (see .gitignore). The page needs it under assets/ to stage into the
// browser build; absent, emoji show as tofu. Fetch it once on the first
// wasm build, cache it under build/, and copy it into assets/. Best
// effort: a build with no font and no network still succeeds.

private bool emoji_stage_from_cache() {
    FileData fd = file_read("build/NotoColorEmoji.ttf");
    if fd.data == null { return false; }
    bool ok = file_write("assets/NotoColorEmoji.ttf", fd);
    free(fd.data);
    return ok;
}

private void ensure_emoji_font() {
    if path_exists("assets/NotoColorEmoji.ttf") { return; }
    if path_exists("build/NotoColorEmoji.ttf") && emoji_stage_from_cache() {
        print("staged the color emoji font from build/\n");
        return;
    }
    string curl = path_which("curl");
    defer free(curl);
    if curl.len == 0 {
        print("no color emoji font and no curl to fetch it; emoji show as tofu (THIRD_PARTY.md)\n");
        return;
    }
    print("fetching the color emoji font once (Noto Color Emoji, ~10 MB)...\n");
    ProcCmd c;
    proc_init(&c, str_from(curl.data, curl.len));
    proc_arg(&c, "-fsSL");
    proc_arg(&c, "-o");
    proc_arg(&c, "build/NotoColorEmoji.ttf");
    proc_arg(&c, "https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf");
    if run_cmd(&c) != 0 || !emoji_stage_from_cache() {
        print("could not fetch the color emoji font; emoji show as tofu (THIRD_PARTY.md)\n");
        return;
    }
    print("fetched and staged the color emoji font\n");
}

// Copy the page files (index.html and its scripts) into build/web. The
// compiler's run stages these next to the module; a --no-serve build does
// it here instead. They are copied verbatim, so the bundle is complete.
private i32 web_stage_page() {
    DirList fl = dir_list("web", "", false);
    for i32 i = 0; i < fl.count; i++ {
        str nm = fl.items[i];
        string sp = path_join("web", nm);
        defer free(sp);
        string dp = path_join("build/web", nm);
        defer free(dp);
        FileData fd = file_read(str_from(sp.data, sp.len));
        if fd.data == null { continue; }
        bool ok = file_write(str_from(dp.data, dp.len), fd);
        free(fd.data);
        if !ok {
            print("could not stage the page into build/web\n");
            dir_list_free(&fl);
            return 1;
        }
    }
    dir_list_free(&fl);
    return 0;
}

private i32 build_wasm(str* rest, i32 nrest) {
    ignore dir_create("build/web");
    ignore dir_create("build/web/fs");
    ensure_emoji_font();
    wm_len = 0;
    wm_put("[");
    if web_copy_tree("") != 0 { return 1; }
    wm_put("]");
    FileData mf = FileData{ wm_buf, cast(i32, wm_len) };
    if !file_write("build/web/files.json", mf) {
        print("could not write build/web/files.json\n");
        return 1;
    }
    print("staged the project under build/web/fs\n");
    stage_lsp();

    // --no-serve builds the bundle into build/web and exits, for CI that
    // deploys the directory; without it the compiler's run stages the page
    // and serves build/web on a local port.
    bool serve = true;
    for i32 i = 0; i < nrest; i++ {
        if str_equal(rest[i], "--no-serve") { serve = false; }
    }

    ProcCmd c;
    proc_init(&c, g_cc);
    proc_cwd(&c, "build");
    if serve { proc_arg(&c, "run"); } else { proc_arg(&c, "build"); }
    proc_arg(&c, "--target");
    proc_arg(&c, "wasm");
    proc_arg(&c, "../src/edminc.mc");
    proc_arg(&c, "-o");
    proc_arg(&c, "web/edminc.wasm");
    for i32 i = 0; i < nrest; i++ {
        if str_equal(rest[i], "--no-serve") { continue; }
        proc_arg(&c, rest[i]);
    }
    i32 rc = run_cmd(&c);
    if rc != 0 || serve { return rc; }
    rc = web_stage_page();
    if rc == 0 { print("built the browser bundle in build/web\n"); }
    return rc;
}

i32 run_cmd(ProcCmd* c) {
    ProcResult r = proc_run(c);
    i32 rc = r.exit_code;
    proc_result_free(&r);
    if rc < 0 {
        // a program that could not be started, as opposed to one that
        // ran and failed; the exit code alone (255) says nothing
        eprint("could not start a command; check MINC and PATH for the compiler\n");
    }
    return rc;
}

// --- local install ---------------------------------------------------
// `minc build install` puts the freshly built editor where a downloaded
// one goes. It stages the same layout the release archive has and hands
// it to the same install script, so a local build lands on PATH exactly
// as an installed one does rather than by a second, drifting recipe.

private bool copy_file(str src, str dst) {
    FileData fd = file_read(src);
    if fd.data == null { return false; }
    bool ok = file_write(dst, fd);
    free(fd.data);
    return ok;
}

private i32 copy_tree(str src, str dst) {
    ignore dir_create(dst);
    DirList fl = dir_list(src, "", false);
    for i32 i = 0; i < fl.count; i++ {
        str nm = fl.items[i];
        string sp = path_join(src, nm);
        defer free(sp);
        string dp = path_join(dst, nm);
        defer free(dp);
        if !copy_file(str_from(sp.data, sp.len), str_from(dp.data, dp.len)) {
            dir_list_free(&fl);
            return 1;
        }
    }
    dir_list_free(&fl);
    DirList dl = dir_list(src, "", true);
    for i32 i = 0; i < dl.count; i++ {
        str nm = dl.items[i];
        string sp = path_join(src, nm);
        defer free(sp);
        string dp = path_join(dst, nm);
        defer free(dp);
        if copy_tree(str_from(sp.data, sp.len), str_from(dp.data, dp.len)) != 0 {
            dir_list_free(&dl);
            return 1;
        }
    }
    dir_list_free(&dl);
    return 0;
}

// copies only when the source is there; the extras are not all required
private void copy_optional(str src, str dst) {
    if !path_exists(src) { return; }
    ignore copy_file(src, dst);
}

private i32 do_install(str exe) {
    str payload = "build/install";
    ignore dir_remove(payload);
    ignore dir_create(payload);

    string dexe = join_named(payload, "edmc", EXE_SUFFIX);
    defer free(dexe);
    if !copy_file(exe, str_from(dexe.data, dexe.len)) {
        die("could not stage the editor binary");
    }

    string dassets = path_join(payload, "assets");
    defer free(dassets);
    if copy_tree("assets", str_from(dassets.data, dassets.len)) != 0 {
        die("could not stage assets/");
    }

    string dlic = path_join(payload, "LICENSE");
    defer free(dlic);
    copy_optional("LICENSE", str_from(dlic.data, dlic.len));
    string dthird = path_join(payload, "THIRD_PARTY.md");
    defer free(dthird);
    copy_optional("THIRD_PARTY.md", str_from(dthird.data, dthird.len));
    string dread = path_join(payload, "README.md");
    defer free(dread);
    copy_optional("dist/README.md", str_from(dread.data, dread.len));

    ProcCmd c;
    when os(windows) {
        string dup = path_join(payload, "edmc_update.ps1");
        defer free(dup);
        copy_optional("install/edmc_update.ps1", str_from(dup.data, dup.len));
        proc_init(&c, "powershell");
        proc_arg(&c, "-NoProfile");
        proc_arg(&c, "-ExecutionPolicy");
        proc_arg(&c, "Bypass");
        proc_arg(&c, "-File");
        proc_arg(&c, "install/install.ps1");
        proc_arg(&c, "-From");
        proc_arg(&c, payload);
    } else {
        string dup = path_join(payload, "edmc_update");
        defer free(dup);
        copy_optional("install/edmc_update", str_from(dup.data, dup.len));
        proc_init(&c, "sh");
        proc_arg(&c, "install/install");
        proc_arg(&c, "--from");
        proc_arg(&c, payload);
    }
    return run_cmd(&c);
}

i32 main() {
    str exe = "build/edmc.exe";
    when !os(windows) {
        exe = "build/edmc";
    }

    i32 argc = get_argc();
    str verb = "run";
    str[8] rest;
    i32 nrest = 0;
    for i32 i = 1; i < argc; i++ {
        str a = str_from_cstr(get_arg(i));
        if i == 1 { verb = a; }
        else if nrest < 8 {
            rest[nrest] = a;
            nrest++;
        }
    }

    if str_equal(verb, "clean") {
        ignore dir_remove("build");
        print("clean.\n");
        return 0;
    }

    if !path_exists("src/edminc.mc") {
        die("run this from the edminc folder (src/edminc.mc not found)");
    }

    string minc = find_minc();
    defer free(minc);
    if minc.len == 0 {
        die("minc compiler not found; set MINC or add it to PATH (https://minc.dev)");
    }
    g_cc = str_from(minc.data, minc.len);

    ignore dir_create("build");

    if str_equal(verb, "wasm") {
        return build_wasm(&rest[0], nrest);
    }

    bool is_run = str_equal(verb, "run");
    bool is_smoke = str_equal(verb, "test");
    if !is_run && !is_smoke && !str_equal(verb, "build") {
        print("verbs: run [file.mc] | build [install] | test [fuzz ...] | wasm [--no-browser] | clean\n");
        return 1;
    }

    // `minc test fuzz [args]`: the long soaks. scripts/fuzz.mc builds the
    // fuzzer itself and takes the arguments as given (--count, --steps,
    // --seeds, --twice, --strict, --coverage, --hashes).
    if is_smoke && nrest > 0 && str_equal(rest[0], "fuzz") {
        str soak = "build/fuzz.exe";
        when !os(windows) {
            soak = "build/fuzz";
        }
        ProcCmd sc;
        proc_init(&sc, g_cc);
        proc_arg(&sc, "scripts/fuzz.mc");
        proc_arg(&sc, "-o");
        proc_arg(&sc, soak);
        i32 src = run_cmd(&sc);
        if src != 0 { return src; }
        ProcCmd sr;
        proc_init(&sr, soak);
        for i32 i = 1; i < nrest; i++ { proc_arg(&sr, rest[i]); }
        return run_cmd(&sr);
    }

    // `minc build install`: build, then place it the way the installer does
    bool want_install = false;
    for i32 i = 0; i < nrest; i++ {
        if str_equal(rest[i], "install") { want_install = true; }
    }

    ProcCmd c;
    proc_init(&c, g_cc);
    proc_arg(&c, "src/edminc.mc");
    proc_arg(&c, "-o");
    proc_arg(&c, exe);
    str aside = build_aside(exe);
    bool moved = false;
    if aside.len > 0 && path_exists(exe) {
        ignore file_remove(aside);   // the last one, when nothing holds it
        moved = build_move(exe, aside);
    }
    i32 rc = run_cmd(&c);
    if rc != 0 {
        // nothing was built, so the binary that was there comes back
        if moved && !path_exists(exe) { ignore build_move(aside, exe); }
        return rc;
    }
    if !build_icon(exe) { eprint("warning: the icon was not written into {}\n", exe); }
    print("built.\n");

    if want_install { return do_install(exe); }

    if is_smoke {
        // headless editor-core checks first; they need no window
        str tst = "build/ed_test.exe";
        when !os(windows) {
            tst = "build/ed_test";
        }
        ProcCmd tc;
        proc_init(&tc, g_cc);
        // alloc_live/alloc_total read 0 without this, and the leak
        // check skips itself when they do
        proc_arg(&tc, "--track-alloc");
        proc_arg(&tc, "src/ed_test.mc");
        proc_arg(&tc, "-o");
        proc_arg(&tc, tst);
        i32 trc = run_cmd(&tc);
        if trc != 0 { return trc; }
        ProcCmd tr;
        proc_init(&tr, tst);
        trc = run_cmd(&tr);
        if trc != 0 { return trc; }

        // generated action sequences against the same core, with the
        // language server answering badly on purpose. A few short
        // fixed seeds here; scripts/fuzz.mc runs the long soaks.
        str fz = "build/ed_fuzz.exe";
        when !os(windows) {
            fz = "build/ed_fuzz";
        }
        ProcCmd fc;
        proc_init(&fc, g_cc);
        proc_arg(&fc, "src/ed_fuzz.mc");
        proc_arg(&fc, "-o");
        proc_arg(&fc, fz);
        trc = run_cmd(&fc);
        if trc != 0 { return trc; }
        str[4] seeds = { "1", "2", "3", "4" };
        for i32 i = 0; i < 4; i++ {
            ProcCmd fr;
            proc_init(&fr, fz);
            proc_arg(&fr, "--seed");
            proc_arg(&fr, seeds[i]);
            proc_arg(&fr, "--steps");
            proc_arg(&fr, "400");
            // the first seed also replays its own script and must end
            // on the same frame: the script carries every input
            if i == 0 { proc_arg(&fr, "--replay-check"); }
            trc = run_cmd(&fr);
            if trc != 0 {
                print("ed_fuzz failed; scripts/fuzz.mc shrinks it to a minimal seed\n");
                return trc;
            }
        }
    }

    if is_run || is_smoke {
        ProcCmd r;
        proc_init(&r, exe);
        for i32 i = 0; i < nrest; i++ { proc_arg(&r, rest[i]); }
        // with no arguments the editor opens the most recent folder;
        // `minc run` means this one
        if is_run && nrest == 0 { proc_arg(&r, "."); }
        if is_smoke {
            if nrest == 0 { proc_arg(&r, "src/edminc.mc"); }
            proc_arg(&r, "--smoke");
        }
        return run_cmd(&r);
    }
    return 0;
}
