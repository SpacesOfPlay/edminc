// font_ttf.mc - Linux font raster backend. Faces are found by name in
// the standard font directories and rasterized by the vendored
// stb_truetype (lib/stb_truetype.mc); there is no FreeType and no
// fontconfig here, per doc/TECH_DOC.md "Dependency policy". Implements
// plat_font_init and plat_glyph_raster from plat.mc.
//
// Coverage is grayscale: no hinting and no subpixel, so the atlas
// stores r=g=b and the shader's per-channel blend still applies.

import str;
import file;
import math;
import cbdt;

private const i32 FONT_PX = 16;          // at DPI_BASE
private const i32 LINE_H_BASE = 22;      // round(1.35 * FONT_PX), the
                                         // non-macOS line-box model
private const i32 UI_FONT_PX = 13;       // the reference workbench size
private const i32 TTF_SCRATCH_CAP = 256 * 1024;
private const i32 TTF_MAX_SCAN_DEPTH = 3;
// glyphs a shaped emoji cluster can hold before ligation (a long ZWJ
// sequence is under a dozen)
private const i32 CBDT_CLUSTER_MAX = 32;

// The vendored icon fonts (see THIRD_PARTY.md) serve the private use
// area U+E000..U+F8FF, seti below U+EA00 and codicons at or above.
// Loaded from the working directory; when absent, icons raster as
// blank advances and everything else works.
private const i32 TTF_CAL_PX = 100;

// Preferred faces, best first. The first name that resolves wins, so
// a machine without the front-runner still gets a sensible face.
private str[6] TTF_MONO_NAMES = {
    "DejaVuSansMono.ttf",
    "LiberationMono-Regular.ttf",
    "UbuntuMono-R.ttf",
    "NotoSansMono-Regular.ttf",
    "FreeMono.ttf",
    "Inconsolata-Regular.ttf"
};

private str[6] TTF_UI_NAMES = {
    "Ubuntu-R.ttf",
    "DejaVuSans.ttf",
    "LiberationSans-Regular.ttf",
    "NotoSans-Regular.ttf",
    "FreeSans.ttf",
    "Cantarell-Regular.otf"
};

private str[3] TTF_FONT_DIRS = {
    "/usr/share/fonts",
    "/usr/local/share/fonts",
    "/usr/share/X11/fonts"
};

private struct TtfFace {
    stbtt_fontinfo info;
    u8* data;        // owned; stbtt indexes into it for the face's life
    i64 len;         // bytes of data, for the color-bitmap reader
    f32 scale;
    i32 ascent;      // pixels, already scaled
    bool ok;
}

private TtfFace ttf_mono;
private TtfFace ttf_ui;
private TtfFace ttf_codicon;
private TtfFace ttf_seti;
private TtfFace ttf_emoji;   // color emoji face (CBLC/CBDT), cmap via stbtt
private bool ttf_emoji_tried = false;
private u8* ttf_color = null;   // RGBA scratch for a downscaled emoji
private const i32 TTF_COLOR_CAP = 160 * 160 * 4;
private bool ttf_icons_tried = false;

// color emoji faces to try; on the web the page stages one by this name
private str[6] TTF_EMOJI_NAMES = {
    "NotoColorEmoji.ttf",
    "NotoColorEmoji-Regular.ttf",
    "AppleColorEmoji.ttf",
    "seguiemj.ttf",
    "TwitterColorEmoji-SVGinOT.ttf",
    "EmojiOneColor.otf"
};
private f32 ttf_codicon_mul = 1.0f;
private f32 ttf_caption_scale = 0.0f;   // the codicon face at CAPTION_ICON_PX
private f32 ttf_seti_mul = 1.0f;
private u8* ttf_scratch = null;
private i32 ttf_cell_w = 0;
private i32 ttf_ascent = 0;

// Depth-limited search for a file by exact name. The standard
// directories nest by foundry, so a flat listing is not enough.
private bool ttf_find(str dir, str name, u8* out, i32* out_len, i32 depth) {
    DirList fl = dir_list(dir, "", false);
    for i32 i = 0; i < fl.count; i++ {
        if str_equal(fl.items[i], name) {
            string p = path_join(dir, name);
            if p.len < PATH_MAX {
                memcpy(out, p.data, p.len);
                *out_len = p.len;
            }
            free(p);
            dir_list_free(&fl);
            return true;
        }
    }
    dir_list_free(&fl);
    if depth <= 0 { return false; }
    DirList dl = dir_list(dir, "", true);
    bool found = false;
    for i32 i = 0; i < dl.count; i++ {
        if found { break; }
        string sub = path_join(dir, dl.items[i]);
        found = ttf_find(str_from(sub.data, sub.len), name, out, out_len, depth - 1);
        free(sub);
    }
    dir_list_free(&dl);
    return found;
}

// A face at an exact path, for the vendored icon fonts.
private bool ttf_open(TtfFace* f, str path) {
    FileData fd = file_read(path);
    if fd.data == null || fd.len == 0 { return false; }
    if stbtt_InitFont(&f.info, fd.data, 0) == 0 {
        free(fd.data);
        return false;
    }
    f.data = fd.data;
    f.ok = true;
    return true;
}

// Nothing from an icon font's metrics is trusted: svg2ttf writes
// glyf entries with zeroed xMin/yMin, so any bounds-derived box is
// stretched to the glyph origin while rasterization follows the true
// contours. The vendored files have their boxes recalculated, and
// this calibrates independently anyway, exactly as the CoreText and
// DirectWrite backends do: rasterize a known glyph at a nominal
// size, scan its ink, and scale so drawn ink lands on the target
// fraction of the text em.
private f32 ttf_icon_calibrate(TtfFace* f, u32 ref_cp, f32 target_em) {
    i32 g = stbtt_FindGlyphIndex(&f.info, cast(i32, ref_cp));
    if g == 0 { return target_em; }
    f32 s = stbtt_ScaleForPixelHeight(&f.info, cast(f32, TTF_CAL_PX));
    i32 x0 = 0;
    i32 y0 = 0;
    i32 x1 = 0;
    i32 y1 = 0;
    stbtt_GetGlyphBitmapBox(&f.info, g, s, s, &x0, &y0, &x1, &y1);
    i32 w = x1 - x0;
    i32 h = y1 - y0;
    if w <= 0 || h <= 0 || w * h > TTF_SCRATCH_CAP { return target_em; }
    memset(ttf_scratch, 0, w * h);
    stbtt_MakeGlyphBitmap(&f.info, ttf_scratch, w, h, w, s, s, g);
    i32 lo = -1;
    i32 hi = -1;
    for i32 y = 0; y < h; y++ {
        for i32 x = 0; x < w; x++ {
            if ttf_scratch[y * w + x] > 16 {
                if lo < 0 { lo = y; }
                hi = y;
                break;
            }
        }
    }
    if hi <= lo { return target_em; }
    return target_em * cast(f32, TTF_CAL_PX) / cast(f32, hi - lo + 1);
}

// The first name in `names` that exists under any standard directory.
// The first of `names` that is there, into `path`: a bundled copy under
// the assets dir wins on every target (the web page stages the faces
// there, and a release ships them beside the binary), then native
// falls back to the system font directories. The path's length, 0 when
// none is found.
private i32 ttf_locate(str[6]* names, u8* path) {
    i32 plen = 0;
    for i32 n = 0; n < 6 && plen == 0; n++ {
        i32 cand = asset_file((*names)[n], path, PATH_MAX);
        if file_size(str_from(path, cand)) > 0 { plen = cand; }
    }
    when !os(wasm) {
        for i32 n = 0; n < 6 && plen == 0; n++ {
            for i32 d = 0; d < 3; d++ {
                if !path_is_dir(TTF_FONT_DIRS[d]) { continue; }
                if ttf_find(TTF_FONT_DIRS[d], (*names)[n], path, &plen, TTF_MAX_SCAN_DEPTH) { break; }
            }
        }
    }
    return plen;
}

private bool ttf_load(TtfFace* f, str[6]* names, i32 px) {
    if f.ok {
        // same face, new size: only the scale changes
        f.scale = stbtt_ScaleForPixelHeight(&f.info, cast(f32, px));
        return true;
    }
    noinit u8[PATH_MAX] path;
    i32 plen = ttf_locate(names, &path[0]);
    if plen == 0 { return false; }
    FileData fd = file_read(str_from(&path[0], plen));
    if fd.data == null || fd.len == 0 { return false; }
    if stbtt_InitFont(&f.info, fd.data, 0) == 0 {
        free(fd.data);
        return false;
    }
    f.data = fd.data;   // stbtt reads from it on every call
    f.len = fd.len;
    f.scale = stbtt_ScaleForPixelHeight(&f.info, cast(f32, px));
    f.ok = true;
    return true;
}

// Load the color emoji face once: its cmap resolves a codepoint to a
// glyph id (stbtt), and lib/cbdt reads that glyph's color bitmap. On the
// web the page stages the font under assets/ (build.mc); on Linux it is
// found by name in the font directories, or left absent (tofu).
private void ttf_load_emoji() {
    if ttf_emoji_tried { return; }
    ttf_emoji_tried = true;
    noinit u8[PATH_MAX] path;
    i32 plen = ttf_locate(&TTF_EMOJI_NAMES, &path[0]);
    if plen == 0 { return; }
    FileData fd = file_read(str_from(&path[0], plen));
    if fd.data == null || fd.len == 0 { return; }
    // A color-bitmap font has no outlines, so stb's font init rejects it;
    // cbdt reads the cmap and the CBDT bitmaps directly from the bytes.
    if !cbdt_present(fd.data, fd.len) {
        free(fd.data);   // a color face we cannot read (COLR/sbix/SVG)
        return;
    }
    ttf_emoji.data = fd.data;
    ttf_emoji.len = fd.len;
    ttf_emoji.ok = true;
}

// Load the color emoji face now, whether or not a prior attempt ran. The
// browser build fetches the font in the background after start
// (edminc_host.js) and calls this once it lands in the page's file
// system; the metrics ttf_emoji_raster needs are already set by
// plat_font_init, so only the face bytes are (re)read here.
void ttf_emoji_reload() {
    if ttf_emoji.ok && ttf_emoji.data != null { free(ttf_emoji.data); }
    ttf_emoji.data = null;
    ttf_emoji.len = 0;
    ttf_emoji.ok = false;
    ttf_emoji_tried = false;
    ttf_load_emoji();
}

// Render an emoji glyph id as a color raster: decode its CBDT bitmap and
// box-downsample to about two cells, positioned from the strike metrics.
private bool ttf_emoji_raster(i32 gid, GlyphRaster* out) {
    if !ttf_emoji.ok { return false; }
    CbdtGlyph cg = cbdt_decode(ttf_emoji.data, ttf_emoji.len, gid);
    if cg.rgba == null || cg.w <= 0 || cg.h <= 0 || cg.ppem <= 0 { return false; }
    if ttf_color == null { ttf_color = alloc<u8>(TTF_COLOR_CAP); }
    // two cells wide, height by the bitmap's aspect
    i32 dw = 2 * ttf_cell_w;
    if dw < 2 { dw = 2; }
    i32 dh = dw * cg.h / cg.w;
    if dh < 1 { dh = 1; }
    while dw * dh * 4 > TTF_COLOR_CAP { dw = dw * 3 / 4; dh = dh * 3 / 4; }
    if dw < 1 || dh < 1 { free(cg.rgba); return false; }
    // box downsample, straight RGBA
    for i32 y = 0; y < dh; y++ {
        i32 sy0 = y * cg.h / dh;
        i32 sy1 = (y + 1) * cg.h / dh;
        if sy1 <= sy0 { sy1 = sy0 + 1; }
        for i32 x = 0; x < dw; x++ {
            i32 sx0 = x * cg.w / dw;
            i32 sx1 = (x + 1) * cg.w / dw;
            if sx1 <= sx0 { sx1 = sx0 + 1; }
            i32 ar = 0;
            i32 ag = 0;
            i32 ab = 0;
            i32 aa = 0;
            i32 cnt = 0;
            for i32 sy = sy0; sy < sy1; sy++ {
                for i32 sx = sx0; sx < sx1; sx++ {
                    i32 o = (sy * cg.w + sx) * 4;
                    ar += cast(i32, cg.rgba[o]);
                    ag += cast(i32, cg.rgba[o + 1]);
                    ab += cast(i32, cg.rgba[o + 2]);
                    aa += cast(i32, cg.rgba[o + 3]);
                    cnt++;
                }
            }
            if cnt < 1 { cnt = 1; }
            i32 o = (y * dw + x) * 4;
            ttf_color[o] = cast(u8, ar / cnt);
            ttf_color[o + 1] = cast(u8, ag / cnt);
            ttf_color[o + 2] = cast(u8, ab / cnt);
            ttf_color[o + 3] = cast(u8, aa / cnt);
        }
    }
    f32 sf = cast(f32, dw) / cast(f32, cg.w);
    out.pixels = ttf_color;
    out.w = dw;
    out.h = dh;
    out.pitch = dw * 4;
    out.channels = 4;
    out.xoff = cast(i32, cast(f32, cg.bx) * sf);
    out.yoff = ttf_ascent - cast(i32, cast(f32, cg.by) * sf);
    out.adv = ttf_cell_w;
    out.advf = cast(f32, ttf_cell_w);
    free(cg.rgba);
    return true;
}

// The line box follows the reference model with the glyphs centered
// inside it, as font_dwrite and font_coretext do.
private void ttf_metrics(TtfFace* f, i32* lh, i32* out_ascent, i32* out_natural) {
    i32 asc = 0;
    i32 desc = 0;
    i32 gap = 0;
    stbtt_GetFontVMetrics(&f.info, &asc, &desc, &gap);
    f32 a = cast(f32, asc) * f.scale;
    f32 d = cast(f32, -desc) * f.scale;
    f32 g = cast(f32, gap) * f.scale;
    i32 natural = cast(i32, ceil(cast(f64, a + d + g)));
    *out_natural = natural;
    // a face taller than the reference line box widens it; the
    // glyphs stay centered in whichever box wins
    if *lh < natural { *lh = natural; }
    i32 pad = (*lh - natural) / 2;
    *out_ascent = cast(i32, ceil(cast(f64, a))) + pad;
}

bool plat_font_init(i32 dpi, FontMetrics* m) {
    if ttf_scratch == null {
        ttf_scratch = alloc<u8>(TTF_SCRATCH_CAP);
    }
    i32 px = FONT_PX * dpi / DPI_BASE;
    if !ttf_load(&ttf_mono, &TTF_MONO_NAMES, px) {
        print("no monospace font found\n");
        return false;
    }

    i32 lh = LINE_H_BASE * dpi / DPI_BASE;
    i32 asc = 0;
    i32 natural = 0;
    ttf_metrics(&ttf_mono, &lh, &asc, &natural);
    m.line_h = lh;
    m.ascent = asc;
    ttf_mono.ascent = asc;

    // the cell is the advance of 'M'; the face is monospace, so every
    // advance matches it
    i32 adv = 0;
    i32 lsb = 0;
    stbtt_GetCodepointHMetrics(&ttf_mono.info, 'M', &adv, &lsb);
    m.cell_w = cast(i32, round(cast(f64, cast(f32, adv) * ttf_mono.scale)));
    if m.cell_w <= 0 { return false; }
    ttf_cell_w = m.cell_w;
    ttf_ascent = m.ascent;

    // the UI face (chrome text); its absence only blanks UI labels
    i32 ui_px = UI_FONT_PX * dpi / DPI_BASE;
    if ttf_load(&ttf_ui, &TTF_UI_NAMES, ui_px) {
        i32 uasc = 0;
        i32 udesc = 0;
        i32 ugap = 0;
        stbtt_GetFontVMetrics(&ttf_ui.info, &uasc, &udesc, &ugap);
        font_ui_ascent = cast(i32, ceil(cast(f64, cast(f32, uasc) * ttf_ui.scale)));
        font_ui_h = cast(i32, ceil(cast(f64,
            cast(f32, uasc - udesc + ugap) * ttf_ui.scale)));
        ttf_ui.ascent = font_ui_ascent;
    }
    font_ui_row = UI_ROW_BASE * UI_FONT_PX * dpi / (UI_REF_PX * DPI_BASE);

    ttf_load_emoji();
    if !ttf_icons_tried {
        ttf_icons_tried = true;
        // drawn-ink targets shared with the other backends: chevrons
        // 0.71 text-em (EAB6), file icons 0.75 (the E060 arrow)
        noinit u8[PATH_MAX] ap;
        i32 an = asset_file("codicon.ttf", &ap[0], PATH_MAX);
        if ttf_open(&ttf_codicon, str_from(&ap[0], an)) {
            ttf_codicon_mul = ttf_icon_calibrate(&ttf_codicon, 0xEAB6, 0.71f);
        }
        an = asset_file("seti.ttf", &ap[0], PATH_MAX);
        if ttf_open(&ttf_seti, str_from(&ap[0], an)) {
            ttf_seti_mul = ttf_icon_calibrate(&ttf_seti, 0xE060, 0.75f);
        }
    }
    if ttf_codicon.ok {
        ttf_codicon.scale = stbtt_ScaleForPixelHeight(&ttf_codicon.info, cast(f32, px) * ttf_codicon_mul);
        // the window buttons draw their icons at the caption em
        ttf_caption_scale = stbtt_ScaleForPixelHeight(&ttf_codicon.info,
            cast(f32, CAPTION_ICON_PX * dpi) / cast(f32, DPI_BASE));
    }
    if ttf_seti.ok {
        ttf_seti.scale = stbtt_ScaleForPixelHeight(&ttf_seti.info, cast(f32, px) * ttf_seti_mul);
    }
    return true;
}

// Map the cluster's codepoints to emoji-face glyphs and ligate them with
// the font's GSUB type-4 lookups (cbdt_shape): skin tone, ZWJ sequences,
// keycaps and flags collapse to one color glyph. Codepoints the cmap
// lacks (VS16) are dropped, as a full shaper drops default-ignorables.
// When a cluster does not fully combine, the first glyph still draws, so
// an emoji-presentation dingbat (❤️, ☑️) renders in color rather than the
// text face's black-and-white glyph.
u32 plat_shape_cluster(u8* s, i32 n) {
    if !ttf_emoji.ok || n <= 0 { return 0; }
    i32[CBDT_CLUSTER_MAX] gids;
    i32 cnt = 0;
    i32 i = 0;
    while i < n && cnt < CBDT_CLUSTER_MAX {
        u32 cp = utf8_next(s, n, &i);
        i32 g = cbdt_cmap(ttf_emoji.data, ttf_emoji.len, cp);
        if g != 0 { gids[cnt] = g; cnt++; }
    }
    if cnt == 0 { return 0; }
    ignore cbdt_shape(ttf_emoji.data, ttf_emoji.len, &gids[0], cnt);
    return cast(u32, gids[0]);
}

bool plat_glyph_raster(u32 cp, GlyphRaster* out) {
    if (cp & FONT_GLYPHID) != 0 {
        return ttf_emoji_raster(cast(i32, cp & 0xFFFF), out);
    }
    bool is_ui = (cp & FONT_UI) != 0;
    // chrome text carries a quarter-pixel phase in the codepoint;
    // the outline is drawn shifted right by phase/4 px so fractional
    // advances land on real subpixel positions
    f32 phase = cast(f32, cast(i32, (cp & FONT_PHASE_MASK) >> FONT_PHASE_SHIFT)) / 4.0f;
    bool caption = (cp & FONT_CAPTION) != 0;
    cp = cp & ~(FONT_UI | FONT_PHASE_MASK | FONT_CAPTION);
    TtfFace* f = &ttf_mono;
    bool is_icon = false;
    if is_ui {
        f = &ttf_ui;
    } else if cp >= ICON_CP_MIN && cp <= ICON_CP_MAX {
        is_icon = true;
        f = &ttf_codicon;
        if cp < ICON_CP_CODICON { f = &ttf_seti; }
    }
    if !f.ok { return false; }
    f32 sc = f.scale;
    if caption && is_icon && f == &ttf_codicon { sc = ttf_caption_scale; }

    i32 g = stbtt_FindGlyphIndex(&f.info, cast(i32, cp));
    if g == 0 {
        // not in the text face: try the color emoji face (single glyph)
        if !is_icon && ttf_emoji.ok {
            i32 eg = cbdt_cmap(ttf_emoji.data, ttf_emoji.len, cp);
            if eg != 0 && ttf_emoji_raster(eg, out) { return true; }
        }
        return false;   // advance only; fallback is open
    }

    i32 adv = 0;
    i32 lsb = 0;
    stbtt_GetGlyphHMetrics(&f.info, g, &adv, &lsb);
    i32 x0 = 0;
    i32 y0 = 0;
    i32 x1 = 0;
    i32 y1 = 0;
    stbtt_GetGlyphBitmapBoxSubpixel(&f.info, g, sc, sc, phase, 0.0f, &x0, &y0, &x1, &y1);
    i32 w = x1 - x0;
    i32 h = y1 - y0;

    out.pixels = ttf_scratch;
    out.w = w;
    out.h = h;
    out.pitch = w;
    out.channels = 1;
    out.xoff = x0;
    // stbtt's bitmap box is y-down from the baseline, so y0 is
    // negative for the part above it
    out.yoff = f.ascent + y0;
    out.adv = ttf_cell_w;
    out.advf = cast(f32, ttf_cell_w);
    if is_ui {
        out.advf = cast(f32, adv) * sc;
        out.adv = cast(i32, round(cast(f64, out.advf)));
    }
    if w <= 0 || h <= 0 {
        // a blank glyph (space) still carries its advance
        out.w = 0;
        out.h = 0;
        return true;
    }
    if w * h > TTF_SCRATCH_CAP { return false; }
    memset(ttf_scratch, 0, w * h);
    stbtt_MakeGlyphBitmapSubpixel(&f.info, ttf_scratch, w, h, w, sc, sc, phase, 0.0f, g);
    if is_icon { return font_icon_rebase(ttf_scratch, w, h, ttf_ascent, ttf_cell_w, out); }
    return true;
}
