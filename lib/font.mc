// font.mc - portable glyph cache + atlas packing. The platform
// backend rasterizes (plat_glyph_raster); this side owns the RGBA8
// atlas (rgb = per-channel coverage; grayscale rasters replicate),
// the glyph table, and row packing. Glyphs land on first use. A color
// glyph (channels == 4, color emoji) stores straight RGBA in its cell
// and is drawn with a clear vertex color so the shader composites it
// directly (see Glyph.color and font_glyph_quad).

struct Glyph {
    u32 cp;
    bool used;
    bool color;   // the atlas cell is straight RGBA, not coverage (color emoji)
    i16 x;
    i16 y;
    i16 w;
    i16 h;
    i16 xoff;
    i16 yoff;
    i16 adv;
    f32 advf;
}

private const i32 GLYPH_CAP = 2048;      // power of two, open addressing
private const i32 GLYPH_HEADROOM = 128;  // free slots kept so probing terminates
private const u32 GLYPH_HASH = 2654435761;
private const i32 PACK_START = 2;        // row 0 holds the white pixel
private const i32 PACK_GAP = 1;

// corners live in the atlas, so they belong to a dpi's context
private struct CornerSprite {
    i32 r;
    i16 x;
    i16 y;
}

// One font context per distinct dpi: its own atlas, glyph cache and
// metrics. The live globals below are the current context; another
// dpi's parks in font_ctx and swaps in through font_use (like a window
// or a pane). A switch marks the atlas dirty so the gpu re-uploads it;
// new glyphs re-point the native font lazily, so a switch with a warm
// cache costs only the one texture upload. Windows on same-dpi displays
// share a context and pay nothing.
private const i32 FONT_CTX_MAX = 4;
private const i32 CORNER_SLOTS = 8;   // rounded-corner radii cached per context

private struct FontCtx {
    bool used;
    i32 dpi;
    u8* atlas;
    Glyph* glyphs;
    i32 nglyphs;
    i32 pack_x;
    i32 pack_y;
    i32 pack_row_h;
    i32 ncorners;
    CornerSprite[CORNER_SLOTS] corners;
    i32 cell_w;
    i32 line_h;
    i32 ascent;
    i32 ui_h;
    i32 ui_row;
    i32 ui_ascent;
}
private FontCtx[FONT_CTX_MAX] font_ctx;
private i32 font_cur = 0;
private i32 font_backend_dpi = 0;   // the dpi the native font is set to

i32 font_cell_w = 0;
i32 font_line_h = 0;
i32 font_ascent = 0;
u8* font_atlas = null;
bool font_atlas_dirty = false;

private i32 font_pack_x = PACK_START;
private i32 font_pack_y = PACK_START;
private i32 font_pack_row_h = 0;
private Glyph* font_glyphs = null;
private i32 font_nglyphs = 0;
private Glyph font_fallback;  // advance only; returned when the table is full

// The assets directory (fonts, icons). Resolved once: next to the
// executable for a released build, its parent for the repo layout (the
// binary sits in build/), else the working directory. The browser
// serves the files from its file-system map at "assets".
private u8[PATH_MAX] g_assets;
private i32 g_assets_len = -1;

private void asset_dir_resolve() {
    when os(wasm) {
        str a = "assets";
        memcpy(&g_assets[0], a.data, a.len);
        g_assets_len = a.len;
    } else {
        noinit u8[PATH_MAX] e;
        i32 le = plat_exe_dir(&e[0], PATH_MAX);
        i32 chosen = -1;
        // the exe's directory, then its parent (a dev build sits in
        // build/). The parent is formed by dropping the last path
        // segment, not by appending "..": a path with ".." in it is
        // rejected by some OS font loaders (DirectWrite).
        i32 pe = le;
        while pe > 0 && e[pe - 1] != '/' && e[pe - 1] != '\\' { pe--; }
        if pe > 0 { pe--; }
        for i32 k = 0; k < 2 && chosen < 0; k++ {
            i32 bl = le;
            if k == 1 { bl = pe; }
            str sfx = "/assets";
            if bl > 0 && bl + sfx.len < PATH_MAX {
                noinit u8[PATH_MAX] p;
                memcpy(&p[0], &e[0], bl);
                memcpy(&p[bl], sfx.data, sfx.len);
                i32 pn = bl + sfx.len;
                if path_is_dir(str_from(&p[0], pn)) {
                    memcpy(&g_assets[0], &p[0], pn);
                    g_assets_len = pn;
                    chosen = k;
                }
            }
        }
        if chosen < 0 {
            str a = "assets";
            memcpy(&g_assets[0], a.data, a.len);
            g_assets_len = a.len;
        }
    }
}

// the resolved assets directory (no trailing slash), written into out
// and null-terminated: some platform font loaders take a C string
i32 asset_dir(u8* out, i32 cap) {
    if g_assets_len < 0 { asset_dir_resolve(); }
    i32 n = g_assets_len;
    if n > cap { n = cap; }
    memcpy(out, &g_assets[0], n);
    if n < cap { out[n] = 0; }
    return n;
}

// "<assets dir>/<name>" written into out and null-terminated, its
// length (without the terminator) returned
i32 asset_file(str name, u8* out, i32 cap) {
    i32 n = asset_dir(out, cap);
    if n + 1 + name.len < cap {
        out[n] = '/';
        n++;
        memcpy(&out[n], name.data, name.len);
        n += name.len;
        out[n] = 0;
    }
    return n;
}

private void font_apply_metrics(FontMetrics* m) {
    font_cell_w = m.cell_w;
    font_line_h = m.line_h;
    font_ascent = m.ascent;
    font_fallback.adv = cast(i16, font_cell_w);
    font_fallback.advf = cast(f32, font_cell_w);
}

private void font_clear_atlas() {
    memset(font_atlas, 0, ATLAS_W * ATLAS_H * 4);
    // reserved white pixel at (0,0) for solid rects
    font_atlas[0] = 255;
    font_atlas[1] = 255;
    font_atlas[2] = 255;
    font_atlas[3] = 255;
    memset(font_glyphs, 0, GLYPH_CAP * sizeof(Glyph));
    font_nglyphs = 0;
    font_ncorners = 0;
    font_pack_x = PACK_START;
    font_pack_y = PACK_START;
    font_pack_row_h = 0;
    font_atlas_dirty = true;
}

// drop every cached glyph in the current context so they re-raster. Used
// when a font arrives after start (the browser build fetches the color
// emoji font in the background): glyphs cached as tofu must be redrawn.
void font_reset_cache() {
    font_clear_atlas();
}

private i32 font_dpi = DPI_BASE;

bool font_init(i32 dpi) {
    return font_ctx_create(0, dpi);
}

// context `slot` made current for dpi: its atlas and glyph table, the
// backend at that dpi, the metrics applied; false when the backend has
// no font, which leaves the metrics at zero
private bool font_ctx_create(i32 slot, i32 dpi) {
    FontCtx* c = &font_ctx[slot];
    if c.atlas == null { c.atlas = alloc<u8>(ATLAS_W * ATLAS_H * 4); }
    if c.glyphs == null { c.glyphs = alloc<Glyph>(GLYPH_CAP); }
    c.used = true;
    c.dpi = dpi;
    font_cur = slot;
    font_dpi = dpi;
    font_atlas = c.atlas;
    font_glyphs = c.glyphs;
    FontMetrics m;
    bool ok = plat_font_init(dpi, &m);
    font_backend_dpi = dpi;
    font_apply_metrics(&m);
    font_clear_atlas();
    return ok;
}

// select the atlas, glyph cache and metrics for dpi, creating them on
// first use. A no-op when dpi is already current.
void font_use(i32 dpi) {
    if dpi <= 0 || dpi == font_dpi { return; }
    FontCtx* cur = &font_ctx[font_cur];
    cur.atlas = font_atlas;
    cur.glyphs = font_glyphs;
    cur.nglyphs = font_nglyphs;
    cur.pack_x = font_pack_x;
    cur.pack_y = font_pack_y;
    cur.pack_row_h = font_pack_row_h;
    cur.ncorners = font_ncorners;
    memcpy(&cur.corners[0], &font_corners[0], CORNER_SLOTS * sizeof(CornerSprite));
    cur.cell_w = font_cell_w;
    cur.line_h = font_line_h;
    cur.ascent = font_ascent;
    cur.ui_h = font_ui_h;
    cur.ui_row = font_ui_row;
    cur.ui_ascent = font_ui_ascent;
    i32 di = -1;
    for i32 i = 0; i < FONT_CTX_MAX; i++ {
        if font_ctx[i].used && font_ctx[i].dpi == dpi { di = i; break; }
    }
    if di < 0 {
        for i32 i = 0; i < FONT_CTX_MAX; i++ {
            if !font_ctx[i].used { di = i; break; }
        }
        if di < 0 { di = font_cur; }   // table full: reuse the current one
        ignore font_ctx_create(di, dpi);
        return;
    }
    FontCtx* c = &font_ctx[di];
    font_cur = di;
    font_dpi = dpi;
    font_atlas = c.atlas;
    font_glyphs = c.glyphs;
    font_nglyphs = c.nglyphs;
    font_pack_x = c.pack_x;
    font_pack_y = c.pack_y;
    font_pack_row_h = c.pack_row_h;
    font_ncorners = c.ncorners;
    memcpy(&font_corners[0], &c.corners[0], CORNER_SLOTS * sizeof(CornerSprite));
    font_cell_w = c.cell_w;
    font_line_h = c.line_h;
    font_ascent = c.ascent;
    font_ui_h = c.ui_h;
    font_ui_row = c.ui_row;
    font_ui_ascent = c.ui_ascent;
    font_fallback.adv = cast(i16, font_cell_w);
    font_fallback.advf = cast(f32, font_cell_w);
    font_atlas_dirty = true;
}

private Glyph* font_glyph(u32 cp) {
    i32 mask = GLYPH_CAP - 1;
    i32 idx = cast(i32, (cp * GLYPH_HASH) & cast(u32, mask));
    while true {
        Glyph* g = font_glyphs + idx;
        if g.used && g.cp == cp { return g; }
        if !g.used { break; }
        idx = (idx + 1) & mask;
    }
    if font_nglyphs >= GLYPH_CAP - GLYPH_HEADROOM { return &font_fallback; }
    Glyph* g = font_glyphs + idx;
    g.used = true;
    g.cp = cp;
    g.adv = cast(i16, font_cell_w);
    g.advf = cast(f32, font_cell_w);
    font_nglyphs++;

    if font_backend_dpi != font_dpi {
        // a glyph wanted at a dpi the native font is not set to; re-point
        // it (rare: only the first miss after a dpi switch)
        FontMetrics fm;
        ignore plat_font_init(font_dpi, &fm);
        font_backend_dpi = font_dpi;
    }
    GlyphRaster r;
    bool rok = false;
    if cp == ICON_MC {
        rok = font_icon_mc(&r);
    } else if cp == ICON_EDMC {
        rok = font_icon_edmc(&r);
    } else if (cp & FONT_SHAPE) != 0 {
        rok = font_shape_raster(cp & 0xFF, &r);
    } else {
        rok = plat_glyph_raster(cp, &r);
    }
    if !rok {
        return g;  // advance only
    }
    if !font_pack_fit(r.w, r.h) {
        return g;  // atlas full; glyph renders blank
    }
    for i32 row = 0; row < r.h; row++ {
        u8* src = r.pixels + row * r.pitch;
        u8* dst = font_atlas + ((font_pack_y + row) * ATLAS_W + font_pack_x) * 4;
        if r.channels == 4 {
            // color emoji: straight (non-premultiplied) RGBA, copied as is;
            // the shader composites it directly rather than as coverage
            for i32 c = 0; c < r.w; c++ {
                dst[c * 4] = src[c * 4];
                dst[c * 4 + 1] = src[c * 4 + 1];
                dst[c * 4 + 2] = src[c * 4 + 2];
                dst[c * 4 + 3] = src[c * 4 + 3];
            }
        } else if r.channels == 3 {
            for i32 c = 0; c < r.w; c++ {
                dst[c * 4] = src[c * 3];
                dst[c * 4 + 1] = src[c * 3 + 1];
                dst[c * 4 + 2] = src[c * 3 + 2];
                dst[c * 4 + 3] = 255;
            }
        } else {
            for i32 c = 0; c < r.w; c++ {
                u8 v = src[c];
                dst[c * 4] = v;
                dst[c * 4 + 1] = v;
                dst[c * 4 + 2] = v;
                dst[c * 4 + 3] = 255;
            }
        }
    }
    g.x = cast(i16, font_pack_x);
    g.y = cast(i16, font_pack_y);
    g.w = cast(i16, r.w);
    g.h = cast(i16, r.h);
    g.xoff = cast(i16, r.xoff);
    g.yoff = cast(i16, r.yoff);
    g.adv = cast(i16, r.adv);
    g.advf = r.advf;
    g.color = r.channels == 4;
    font_pack_take(r.w, r.h);
    font_atlas_dirty = true;
    return g;
}

// room at the pen for a w by h raster, the pen wrapped to the next
// row when this one is full; false once the atlas is
private bool font_pack_fit(i32 w, i32 h) {
    if font_pack_x + w + PACK_GAP > ATLAS_W {
        font_pack_x = PACK_START;
        font_pack_y += font_pack_row_h + PACK_GAP;
        font_pack_row_h = 0;
    }
    return font_pack_y + h + PACK_GAP <= ATLAS_H;
}

// the pen past a w by h raster written at it
private void font_pack_take(i32 w, i32 h) {
    font_pack_x += w + PACK_GAP;
    if h > font_pack_row_h { font_pack_row_h = h; }
}

// --- UI corner sprites -----------------------------------------------
// Quarter-disc coverage bitmaps packed like glyphs, so rounded UI
// corners antialias exactly like text on every backend. The sprite
// is the top-left corner; the other three sample it mirrored.

private const i32 CORNER_MAX = 16;

private CornerSprite[CORNER_SLOTS] font_corners;
private i32 font_ncorners = 0;

// atlas position of the quarter disc for radius r; packs on first use
private bool font_corner(i32 r, i16* ox, i16* oy) {
    for i32 i = 0; i < font_ncorners; i++ {
        if font_corners[i].r == r {
            *ox = font_corners[i].x;
            *oy = font_corners[i].y;
            return true;
        }
    }
    if font_ncorners == CORNER_SLOTS { return false; }
    // 4x4 supersampled coverage of a disc centered on the sprite's
    // bottom-right corner
    noinit u8[CORNER_MAX * CORNER_MAX] cov;
    for i32 iy = 0; iy < r; iy++ {
        for i32 ix = 0; ix < r; ix++ {
            i32 hits = 0;
            for i32 sub = 0; sub < 16; sub++ {
                f32 px = cast(f32, ix) + (cast(f32, sub % 4) + 0.5f) / 4.0f;
                f32 py = cast(f32, iy) + (cast(f32, sub / 4) + 0.5f) / 4.0f;
                f32 dx = cast(f32, r) - px;
                f32 dy = cast(f32, r) - py;
                if dx * dx + dy * dy <= cast(f32, r * r) { hits++; }
            }
            cov[iy * r + ix] = cast(u8, hits * 255 / 16);
        }
    }
    if !font_pack_fit(r, r) { return false; }
    for i32 row = 0; row < r; row++ {
        u8* dst = font_atlas + ((font_pack_y + row) * ATLAS_W + font_pack_x) * 4;
        for i32 c = 0; c < r; c++ {
            u8 v = cov[row * r + c];
            dst[c * 4] = v;
            dst[c * 4 + 1] = v;
            dst[c * 4 + 2] = v;
            dst[c * 4 + 3] = 255;
        }
    }
    font_corners[font_ncorners] = CornerSprite{ r, cast(i16, font_pack_x), cast(i16, font_pack_y) };
    *ox = cast(i16, font_pack_x);
    *oy = cast(i16, font_pack_y);
    font_ncorners++;
    font_pack_take(r, r);
    font_atlas_dirty = true;
    return true;
}

// Rounded rect with antialiased corners.
void draw_rect_rounded(f32 x, f32 y, f32 w, f32 h, i32 r, u32 col) {
    if r * 2 > cast(i32, h) { r = cast(i32, h) / 2; }
    if r * 2 > cast(i32, w) { r = cast(i32, w) / 2; }
    if r > CORNER_MAX { r = CORNER_MAX; }
    i16 sx = 0;
    i16 sy = 0;
    if r <= 0 || !font_corner(r, &sx, &sy) {
        draw_rect(x, y, w, h, col);
        return;
    }
    f32 fr = cast(f32, r);
    draw_rect(x, y + fr, w, h - 2.0f * fr, col);
    draw_rect(x + fr, y, w - 2.0f * fr, fr, col);
    draw_rect(x + fr, y + h - fr, w - 2.0f * fr, fr, col);
    f32 u0 = cast(f32, sx) / cast(f32, ATLAS_W);
    f32 v0 = cast(f32, sy) / cast(f32, ATLAS_H);
    f32 u1 = cast(f32, sx + r) / cast(f32, ATLAS_W);
    f32 v1 = cast(f32, sy + r) / cast(f32, ATLAS_H);
    draw_quad(x, y, fr, fr, u0, v0, u1, v1, col);
    draw_quad(x + w - fr, y, fr, fr, u1, v0, u0, v1, col);
    draw_quad(x, y + h - fr, fr, fr, u0, v1, u1, v0, col);
    draw_quad(x + w - fr, y + h - fr, fr, fr, u1, v1, u0, v0, col);
}

// The embedded .mc icon (lib/icon_mc.mc), box-downsampled from its
// 64x64 coverage to the current icon size and centered in the line.
private u8* icon_mc_scratch = null;
private u8* icon_edmc_scratch = null;   // the app logo, same box-downsample

// --- shapes ---------------------------------------------------------------
// The reference's squiggle is a 6 by 3 css-px tile of three convex
// polygons (its editor stylesheet's background image), repeated along
// the range. Sampled 4 by 4 per device pixel for coverage, at the
// current dpi, so the diagonals stay anti-aliased at any scale.
private const i32 SHAPE_SS = 4;
private const i32 SHAPE_MAX_W = 96;
private const i32 SHAPE_MAX_H = 96;
private u8[SHAPE_MAX_W * SHAPE_MAX_H] shape_scratch;

// inside a convex polygon given as x,y pairs, either winding
private bool shape_inside(f32* p, i32 n, f32 x, f32 y) {
    bool pos = false;
    bool neg = false;
    for i32 i = 0; i < n; i++ {
        i32 j = (i + 1) % n;
        f32 cr = (p[j * 2] - p[i * 2]) * (y - p[i * 2 + 1]) - (p[j * 2 + 1] - p[i * 2 + 1]) * (x - p[i * 2]);
        if cr > 0.0f { pos = true; }
        if cr < 0.0f { neg = true; }
    }
    return !(pos && neg);
}

// the deleted-lines mark: a triangle with its base at the left, its
// point on the right, 4 css px wide and 8 tall, anti-aliased like the
// squiggle
private bool font_shape_wedge(GlyphRaster* out) {
    f32 s = cast(f32, font_dpi) / cast(f32, DPI_BASE);
    i32 w = cast(i32, floor(cast(f64, 4.0f * s + 0.5f)));
    i32 h = cast(i32, floor(cast(f64, 8.0f * s + 0.5f)));
    if w < 1 { w = 1; }
    if h < 2 { h = 2; }
    if w > SHAPE_MAX_W { w = SHAPE_MAX_W; }
    if h > SHAPE_MAX_H { h = SHAPE_MAX_H; }
    // in the tile's own units, so the point lands on its right edge
    f32 fw = cast(f32, w);
    f32 fh = cast(f32, h);
    f32[6] tri = { 0.0f, 0.0f, fw, fh * 0.5f, 0.0f, fh };
    for i32 py = 0; py < h; py++ {
        for i32 px = 0; px < w; px++ {
            i32 hit = 0;
            for i32 j = 0; j < SHAPE_SS; j++ {
                f32 v = cast(f32, py) + (cast(f32, j) + 0.5f) / cast(f32, SHAPE_SS);
                for i32 i = 0; i < SHAPE_SS; i++ {
                    f32 u = cast(f32, px) + (cast(f32, i) + 0.5f) / cast(f32, SHAPE_SS);
                    if shape_inside(&tri[0], 3, u, v) { hit++; }
                }
            }
            shape_scratch[py * w + px] = cast(u8, hit * 255 / (SHAPE_SS * SHAPE_SS));
        }
    }
    shape_out(out, w, h);
    return true;
}

// The diff's filler rule: parallel 45-degree lines, as a tile that
// repeats with no seam in either direction. Its side is the line
// height, so one tile covers one row and the next row's tile continues
// the same lines; the stripes are spaced by a third of that, so the
// spacing follows the dpi with the text. A pixel is under a line when
// (x + y) falls near a multiple of the spacing, which is what makes the
// tile seamless: shifting by the side is a whole number of spacings.
private bool font_shape_hatch(GlyphRaster* out) {
    i32 side = font_line_h;
    if side < 4 { side = 4; }
    if side > SHAPE_MAX_W { side = SHAPE_MAX_W; }
    f32 gap = cast(f32, side) / 3.0f;
    f32 thick = cast(f32, font_dpi) / cast(f32, DPI_BASE);
    if thick < 1.0f { thick = 1.0f; }
    for i32 py = 0; py < side; py++ {
        for i32 px = 0; px < side; px++ {
            i32 hit = 0;
            for i32 j = 0; j < SHAPE_SS; j++ {
                f32 v = cast(f32, py) + (cast(f32, j) + 0.5f) / cast(f32, SHAPE_SS);
                for i32 i = 0; i < SHAPE_SS; i++ {
                    f32 u = cast(f32, px) + (cast(f32, i) + 0.5f) / cast(f32, SHAPE_SS);
                    // distance along the diagonal, folded into one spacing
                    f32 d = u + v;
                    f32 m = d - cast(f32, floor(cast(f64, d / gap))) * gap;
                    if m < thick { hit++; }
                }
            }
            shape_scratch[py * side + px] = cast(u8, hit * 255 / (SHAPE_SS * SHAPE_SS));
        }
    }
    shape_out(out, side, side);
    return true;
}

// the scratch as a w by h coverage tile, drawn at the pen
private void shape_out(GlyphRaster* out, i32 w, i32 h) {
    out.pixels = &shape_scratch[0];
    out.w = w;
    out.h = h;
    out.pitch = w;
    out.channels = 1;
    out.xoff = 0;
    out.yoff = 0;
    out.adv = w;
    out.advf = cast(f32, w);
}

// An icon glyph rebased to its scanned ink box: the rows and columns of
// the raster with coverage above a threshold, the ink bottom landed on
// the baseline + 1, where the reference puts its icons. Every backend
// draws the icon fonts this way. False for a blank raster.
bool font_icon_rebase(u8* px, i32 w, i32 h, i32 ascent, i32 cell_w, GlyphRaster* out) {
    i32 iy0 = -1;
    i32 iy1 = -1;
    i32 ix0 = w;
    i32 ix1 = -1;
    for i32 sy = 0; sy < h; sy++ {
        for i32 sx = 0; sx < w; sx++ {
            if px[sy * w + sx] > 8 {
                if iy0 < 0 { iy0 = sy; }
                iy1 = sy;
                if sx < ix0 { ix0 = sx; }
                if sx > ix1 { ix1 = sx; }
            }
        }
    }
    if iy1 < 0 { return false; }
    out.pixels = px + iy0 * w + ix0;
    out.w = ix1 - ix0 + 1;
    out.h = iy1 - iy0 + 1;
    out.pitch = w;
    out.channels = 1;
    out.xoff = 0;
    out.yoff = ascent + 1 - out.h;
    out.adv = cell_w;
    out.advf = cast(f32, cell_w);
    return true;
}

private bool font_shape_raster(u32 id, GlyphRaster* out) {
    if id == SHAPE_WEDGE { return font_shape_wedge(out); }
    if id == SHAPE_HATCH { return font_shape_hatch(out); }
    if id != SHAPE_SQUIGGLE { return false; }
    f32 s = cast(f32, font_dpi) / cast(f32, DPI_BASE);
    i32 w = cast(i32, floor(cast(f64, 6.0f * s + 0.5f)));
    i32 h = cast(i32, ceil(cast(f64, 3.0f * s - 0.01f)));
    if w < 1 { w = 1; }
    if h < 1 { h = 1; }
    if w > SHAPE_MAX_W { w = SHAPE_MAX_W; }
    if h > SHAPE_MAX_H { h = SHAPE_MAX_H; }
    f32[8] pa = { 5.5f, 0.0f, 2.5f, 3.0f, 1.1f, 3.0f, 4.1f, 0.0f };
    f32[8] pb = { 4.0f, 0.0f, 6.0f, 2.0f, 6.0f, 0.6f, 5.4f, 0.0f };
    f32[8] pc = { 0.0f, 2.0f, 1.0f, 3.0f, 2.4f, 3.0f, 0.0f, 0.6f };
    f32 period = cast(f32, w) / s;   // the tile's own width in css px, so the repeat has no seam
    for i32 py = 0; py < h; py++ {
        for i32 px = 0; px < w; px++ {
            i32 hit = 0;
            for i32 j = 0; j < SHAPE_SS; j++ {
                f32 v = (cast(f32, py) + (cast(f32, j) + 0.5f) / cast(f32, SHAPE_SS)) / s;
                for i32 i = 0; i < SHAPE_SS; i++ {
                    f32 u = (cast(f32, px) + (cast(f32, i) + 0.5f) / cast(f32, SHAPE_SS)) / s;
                    u = u * 6.0f / period;
                    if shape_inside(&pa[0], 4, u, v) || shape_inside(&pb[0], 4, u, v)
                        || shape_inside(&pc[0], 4, u, v) {
                        hit++;
                    }
                }
            }
            shape_scratch[py * w + px] = cast(u8, hit * 255 / (SHAPE_SS * SHAPE_SS));
        }
    }
    shape_out(out, w, h);
    return true;
}

private bool font_icon_mc(GlyphRaster* out) {
    i32 w = font_line_h * 3 / 5;   // reference icons are ~0.7 text-em wide
    if w > ICON_MC_W { w = ICON_MC_W; }
    if w <= 0 { return false; }
    i32 h = w * ICON_MC_H / ICON_MC_W;
    if h < 1 { h = 1; }
    if icon_mc_scratch == null { icon_mc_scratch = alloc<u8>(ICON_MC_W * ICON_MC_H); }
    for i32 y = 0; y < h; y++ {
        i32 sy0 = y * ICON_MC_H / h;
        i32 sy1 = (y + 1) * ICON_MC_H / h;
        for i32 x = 0; x < w; x++ {
            i32 sx0 = x * ICON_MC_W / w;
            i32 sx1 = (x + 1) * ICON_MC_W / w;
            i32 sum = 0;
            for i32 sy = sy0; sy < sy1; sy++ {
                for i32 sx = sx0; sx < sx1; sx++ {
                    sum += cast(i32, icon_mc_cov[sy * ICON_MC_W + sx]);
                }
            }
            i32 n = (sy1 - sy0) * (sx1 - sx0);
            if n < 1 { n = 1; }
            icon_mc_scratch[y * w + x] = cast(u8, sum / n);
        }
    }
    out.pixels = icon_mc_scratch;
    out.w = w;
    out.h = h;
    out.pitch = w;
    out.channels = 1;
    out.xoff = 0;
    // the lettering has no descenders: its bottom is the baseline
    out.yoff = font_ascent - h;
    out.adv = cast(i32, font_cell_w);
    out.advf = cast(f32, font_cell_w);
    return true;
}

// The app logo (lib/icon_edmc.mc), a straight-RGBA color glyph sized to
// the cap height so it sits in the caption's line box. icon_edmc_rgba
// hands back the nearest embedded size (never smaller); this box-averages
// it down to the exact height. The favicon's colors are straight over
// transparent, so averaging leaves no halo.
private const i32 ICON_EDMC_MAX = 128;
private bool font_icon_edmc(GlyphRaster* out) {
    i32 s = font_ascent;
    if s > ICON_EDMC_MAX { s = ICON_EDMC_MAX; }
    if s <= 0 { return false; }
    i32 sz = 0;
    u8* src = icon_edmc_rgba(s, &sz);
    if src == null { return false; }
    if icon_edmc_scratch == null { icon_edmc_scratch = alloc<u8>(ICON_EDMC_MAX * ICON_EDMC_MAX * 4); }
    for i32 y = 0; y < s; y++ {
        i32 sy0 = y * sz / s;
        i32 sy1 = (y + 1) * sz / s;
        for i32 x = 0; x < s; x++ {
            i32 sx0 = x * sz / s;
            i32 sx1 = (x + 1) * sz / s;
            i32 ar = 0;
            i32 ag = 0;
            i32 ab = 0;
            i32 aa = 0;
            i32 cnt = 0;
            for i32 sy = sy0; sy < sy1; sy++ {
                for i32 sx = sx0; sx < sx1; sx++ {
                    i32 o = (sy * sz + sx) * 4;
                    ar += cast(i32, src[o]);
                    ag += cast(i32, src[o + 1]);
                    ab += cast(i32, src[o + 2]);
                    aa += cast(i32, src[o + 3]);
                    cnt++;
                }
            }
            if cnt < 1 { cnt = 1; }
            i32 o = (y * s + x) * 4;
            icon_edmc_scratch[o] = cast(u8, ar / cnt);
            icon_edmc_scratch[o + 1] = cast(u8, ag / cnt);
            icon_edmc_scratch[o + 2] = cast(u8, ab / cnt);
            icon_edmc_scratch[o + 3] = cast(u8, aa / cnt);
        }
    }
    out.pixels = icon_edmc_scratch;
    out.w = s;
    out.h = s;
    out.pitch = s * 4;
    out.channels = 4;
    out.xoff = 0;
    out.yoff = font_ascent - s;
    out.adv = cast(i32, font_cell_w);
    out.advf = cast(f32, font_cell_w);
    return true;
}

private void font_glyph_quad(Glyph* g, f32 x, f32 y, u32 col) {
    if g.w == 0 { return; }
    // a color glyph carries its own color in the atlas; col == 0 is the
    // signal the shader composites the cell straight instead of as
    // coverage tinted by col (no draw ever passes a fully clear color)
    if g.color { col = 0; }
    f32 aw = cast(f32, ATLAS_W);
    f32 ah = cast(f32, ATLAS_H);
    f32 u0 = cast(f32, g.x) / aw;
    f32 v0 = cast(f32, g.y) / ah;
    f32 u1 = cast(f32, g.x + g.w) / aw;
    f32 v1 = cast(f32, g.y + g.h) / ah;
    draw_quad(x + cast(f32, g.xoff), y + cast(f32, g.yoff), cast(f32, g.w), cast(f32, g.h), u0, v0, u1, v1, col);
}

// Draw one codepoint with its top-left cell corner at (x, y).
void font_draw(u32 cp, f32 x, f32 y, u32 col) {
    font_glyph_quad(font_glyph(cp), x, y, col);
}

// The same sheared about the baseline, one in five (about eleven
// degrees): the italic the atlas's single face does not have. A color
// glyph stays upright.
private const f32 FONT_ITALIC_SHEAR = 0.2f;

void font_draw_italic(u32 cp, f32 x, f32 y, u32 col) {
    Glyph* g = font_glyph(cp);
    if g.w == 0 { return; }
    if g.color {
        font_glyph_quad(g, x, y, col);
        return;
    }
    font_glyph_quad_sheared(g, x, y, col, font_ascent);
}

// a glyph's quad sheared about the baseline `ascent` below the pen
private void font_glyph_quad_sheared(Glyph* g, f32 x, f32 y, u32 col, i32 ascent) {
    f32 aw = cast(f32, ATLAS_W);
    f32 ah = cast(f32, ATLAS_H);
    f32 u0 = cast(f32, g.x) / aw;
    f32 v0 = cast(f32, g.y) / ah;
    f32 u1 = cast(f32, g.x + g.w) / aw;
    f32 v1 = cast(f32, g.y + g.h) / ah;
    f32 top = y + cast(f32, g.yoff);
    f32 bot = top + cast(f32, g.h);
    f32 base = y + cast(f32, ascent);
    draw_quad_sheared(x + cast(f32, g.xoff), top, cast(f32, g.w), cast(f32, g.h), u0, v0, u1, v1, col,
        (base - top) * FONT_ITALIC_SHEAR, (base - bot) * FONT_ITALIC_SHEAR);
}

// the raster box a draw of cp would cover, relative to the pen; the
// caption centers its icons in their buttons with it
void font_glyph_box(u32 cp, i32* w, i32* h, i32* xoff, i32* yoff) {
    Glyph* g = font_glyph(cp);
    *w = g.w;
    *h = g.h;
    *xoff = g.xoff;
    *yoff = g.yoff;
}

// UI glyph at fractional x: integer draw position plus the closest
// quarter-pixel phase variant
private Glyph* font_ui_glyph(u32 cp, f32 x, i32* xi) {
    i32 fx = cast(i32, x);
    if cast(f32, fx) > x { fx--; }   // floor for negative x
    i32 ph = cast(i32, (x - cast(f32, fx)) * 4.0f + 0.5f);
    if ph >= 4 {
        fx++;
        ph = 0;
    }
    *xi = fx;
    return font_glyph(cp | FONT_UI | cast(u32, ph << FONT_PHASE_SHIFT));
}

// one UI-face codepoint; returns x advanced by its width
f32 font_draw_ui_cp(u32 cp, f32 x, f32 y, u32 col) {
    i32 xi = 0;
    Glyph* g = font_ui_glyph(cp, x, &xi);
    font_glyph_quad(g, cast(f32, xi), y, col);
    return x + g.advf;
}

// pixel width of a UI-face string
i32 font_ui_text_w(str s) {
    f32 w = 0.0f;
    i32 i = 0;
    while i < s.len {
        u32 cp = utf8_next(s.data, s.len, &i);
        Glyph* g = font_glyph(cp | FONT_UI);
        w += g.advf;
    }
    return cast(i32, w + 0.5f);
}

// Proportional UI text (the FONT_UI face): fractional advances,
// quarter-pixel phase variants. Stops before max_x; returns the
// end x.
f32 font_draw_ui_text(str s, f32 x, f32 y, f32 max_x, u32 col) {
    i32 i = 0;
    while i < s.len {
        u32 cp = utf8_next(s.data, s.len, &i);
        i32 xi = 0;
        Glyph* g = font_ui_glyph(cp, x, &xi);
        if x + g.advf > max_x { break; }
        font_glyph_quad(g, cast(f32, xi), y, col);
        x += g.advf;
    }
    return x;
}

// UTF-8 string on the mono grid; returns end x.
f32 font_draw_text(str s, f32 x, f32 y, u32 col) {
    i32 i = 0;
    while i < s.len {
        u32 cp = utf8_next(s.data, s.len, &i);
        font_draw(cp, x, y, col);
        x += cast(f32, font_cell_w);
    }
    return x;
}
