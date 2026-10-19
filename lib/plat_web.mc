// plat_web.mc - browser driver. The page owns the window and the
// loop: it calls these exported entries for input, and one web_frame
// per animation frame after a plat_damage, so idle is zero work here
// as everywhere else. plat_main only satisfies the manifest's main();
// the page calls web_start once the module is up and the fonts and
// project files are in its file system. The tags name the page and
// its script, which the toolchain stages next to the module.

@wasm_host "../web/edminc_host.js"
@wasm_html "../web/index.html"
@wasm_file "../web/edminc_lsp_worker.js"

private bool web_up = false;

i32 plat_main() {
    return 0;
}

// window size in device pixels, dpi from the device pixel ratio, and
// the file to open
export void web_start(i32 w, i32 h, i32 dpi, u8* path, i32 n) {
    if web_up { return; }
    if !font_init(dpi) {
        print("font init failed\n");
        return;
    }
    if !gpu_init(0, w, h) {
        print("gpu init failed\n");
        return;
    }
    draw_init();
    app_resize(w, h);
    app_init(str_from(path, n), dpi);
    settings_use_default();
    web_up = true;
    plat_damage();
}

export void web_resize(i32 w, i32 h) {
    if !web_up { return; }
    gpu_resize(w, h);
    app_resize(w, h);
}

export void web_scale(i32 dpi) {
    if !web_up { return; }
    app_scale(dpi);
}

export void web_char(i32 cp) {
    if !web_up { return; }
    app_char(cast(u32, cp));
}

export void web_key(i32 key, i32 mods) {
    if !web_up { return; }
    app_key(key, mods);
}

export void web_mouse(i32 x, i32 y, i32 btn, i32 down, i32 mods) {
    if !web_up { return; }
    app_mouse(x, y, btn, down != 0, mods);
}

export void web_mouse_move(i32 x, i32 y) {
    if !web_up { return; }
    app_mouse_move(x, y);
}

export void web_hover(i32 x, i32 y, i32 mods) {
    if !web_up { return; }
    app_hover(x, y, mods);
}

export void web_scroll(f32 dx, f32 dy, i32 x, i32 y) {
    if !web_up { return; }
    app_scroll(dx, dy, x, y);
}

export void web_scroll_notch(f32 dx, f32 dy, i32 x, i32 y) {
    if !web_up { return; }
    app_scroll_notch(dx, dy, x, y);
}

export void web_focus(i32 on) {
    if !web_up { return; }
    app_focus(on != 0);
}

export void web_timer(i32 id) {
    if !web_up { return; }
    app_timer(id);
}

export void web_wake() {
    if !web_up { return; }
    app_wake();
}

export void web_frame() {
    if !web_up { return; }
    app_render();
}

// 1 when the page may go; 0 asks it to stay (unsaved buffers)
export i32 web_close() {
    if !web_up { return 1; }
    if app_close() { return 1; }
    return 0;
}

export i32 web_cursor(i32 x, i32 y) {
    if !web_up { return CURSOR_ARROW; }
    return app_cursor_kind(x, y);
}

// bytes from the page's language server, framed as on a pipe
export void web_lsp_recv(u8* p, i32 n) {
    lsp_feed(p, cast(i64, n));
}

// the page fetched the color emoji font into its file system after start;
// retry the emoji face and drop cached tofu glyphs so emoji re-raster
export void web_emoji_loaded() {
    if !web_up { return; }
    ttf_emoji_reload();
    font_reset_cache();
    plat_damage();
}

// scratch the page fills before a call that takes bytes
export u8* web_alloc(i32 n) {
    return alloc<u8>(n);
}

export void web_free(u8* p) {
    free(p);
}
