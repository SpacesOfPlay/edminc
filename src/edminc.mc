// edminc.mc - program manifest: the portable editor plus one platform
// module set selected with `when os()`. A port adds its block here
// and new modules under lib/. The contract is lib/plat.mc.
//
// Build: `minc run [file.mc]` (see build.mc) or
// `minc src/edminc.mc -o build/edmc.exe`. `--smoke` renders one frame,
// prints stats, exits 0.

import file;
// before the platform modules: one of them guards process spawning
// with a Mutex, and a type has to be declared before it is used
import thread;

// portable substrate (lib/): contract, quad batch, glyph cache
import plat;
import json;
import draw;
import font;
import theme;
import icon_mc;
import icon_edmc;
import ui;

// platform modules (lib/): native surface + services, gpu backend,
// font raster backend, driver
when os(windows) {
    import win;
    import gpu_d3d11;
    import font_dwrite;
    import headless;
    import plat_win;
}

when os(macos) {
    import mac;
    import gpu_metal;
    import font_coretext;
    import headless;
    import plat_mac;
}

when os(linux) {
    import x11;
    import stb_truetype;
    import gpu_gl;
    import font_ttf;
    import headless;
    import plat_x11;
}

when os(wasm) {
    import ext_wasm_gl;
    import web;
    import stb_truetype;
    import gpu_webgl;
    import font_ttf;
    import plat_web;
}

// the editor (src/): buffer, highlighter, core, overlays, frame build
import text_buf;
import git;
import lexer;
import lsp;
import sem;
import build;
import term;
import watch;
import wrap;
import ed;
import gitignore;
import pick;
import tree;
import menu;
import search;
import find;
import complete;
import symbols;
import switcher;
import palette;
import settings;
import recent;
import explode;
import calls;
import image;
import hist;
import view;
import evscript;
import play;

// The released version. Cutting a release checks this against the tag
// (.github/workflows/release.yml), and the installer reads it back out
// of `edmc --version` to tell an up-to-date copy from a stale one.
const str EDMINC_VERSION = "0.1.0";

i32 main() {
    // Answered before the platform starts, so it costs no window and no
    // display connection: the installer runs it on a headless machine.
    i32 argc = get_argc();
    for i32 i = 1; i < argc; i++ {
        if str_equal(str_from_cstr(get_arg(i)), "--version") {
            print("edminc {}\n", EDMINC_VERSION);
            return 0;
        }
        if str_equal(str_from_cstr(get_arg(i)), "--restart") {
            // Asks the editor running in this folder to restart into this
            // executable: the request is a file it reads on its next wake,
            // which the prompt's return in the pane this was typed in is.
            noinit u8[PATH_MAX] ep;
            i32 en = plat_exe_path(&ep[0], PATH_MAX);
            if en == 0 {
                print("edminc: the executable's path is unknown here\n");
                return 1;
            }
            ignore dir_create(".edminc");
            if !file_write_str(".edminc/restart", str_from(&ep[0], en)) {
                print("edminc: could not write .edminc/restart\n");
                return 1;
            }
            print("edminc: restart requested\n");
            return 0;
        }
    }
    return plat_main();
}
