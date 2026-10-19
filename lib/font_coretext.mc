// font_coretext.mc - macOS font raster backend. CoreText selects the
// font (CTFontCreateWithName) and rasterizes glyphs
// (CTFontDrawGlyphs) into an alpha-only 8-bit CGBitmapContext, so
// rows are already 0..255 grayscale coverage (macOS has no subpixel
// text). Implements plat_font_init and plat_glyph_raster from
// plat.mc.

import math;

// 14 matches the reference editor's effective size on this
// machine; Windows stays at 16 (see font_dwrite.mc).
private const i32 FONT_PX = 14;          // at DPI_BASE
private const i32 LINE_H_BASE = 21;      // round(1.5 * FONT_PX); the
                                         // macOS line-box model
private const i32 CT_SCRATCH_CAP = 256 * 1024;
private const i32 CT_PAD = 1;           // margin for AA bleed past the reported bounds

// Font smoothing is macOS stem darkening. Alpha-only contexts may
// ignore it (it needs a color context); judged against native apps
// per doc/TECH_DOC.md before the switch grows a real second path.
private const bool CT_FONT_SMOOTHING = true;

private const u32 kCFStringEncodingUTF8 = 0x08000100;
private const u32 kCGImageAlphaOnly = 7;
private const u32 kCGImageAlphaPremultipliedLast = 1;
private const u32 kCTFontTraitColorGlyphs = 0x2000;   // 1 << 13
private const u32 kCTFontOrientationDefault = 0;
private const u32 kCTFontUIFontSystem = 2;

// the reference workbench font size is 13 at its default zoom; this
// machine's window zoom puts the editor at 14/12, so the UI face
// scales the same way (validate against the reference on this
// machine, like FONT_PX was)
private const i32 CT_UI_PX = 15;

private struct CFRange {
    i64 location;
    i64 length;
}

private extern "CoreFoundation" {
    void* CFStringCreateWithCString(void* allocator, u8* cstr, u32 encoding);
    void* CFStringCreateWithCharacters(void* allocator, u16* chars, i64 count);
    void* CFStringCreateWithBytes(void* allocator, u8* bytes, i64 n, u32 encoding, bool ext);
    void* CFDataCreate(void* allocator, void* bytes, i64 length);
    void* CFAttributedStringCreate(void* allocator, void* string, void* attrs);
    void* CFDictionaryCreate(void* allocator, void** keys, void** values, i64 n, void* kcb, void* vcb);
    void* CFDictionaryGetValue(void* d, void* key);
    i64 CFArrayGetCount(void* a);
    void* CFArrayGetValueAtIndex(void* a, i64 i);
    void CFRelease(void* cf);
}
extern "CoreText" void* kCTFontAttributeName;

private extern "CoreGraphics" {
    void* CGDataProviderCreateWithCFData(void* data);
    void CGDataProviderRelease(void* provider);
    void* CGFontCreateWithDataProvider(void* provider);
    void* CGBitmapContextCreate(void* data, u64 w, u64 h, u64 bits_per_component,
                                u64 bytes_per_row, void* space, u32 bitmap_info);
    void CGContextRelease(void* ctx);
    void CGContextSetAllowsFontSmoothing(void* ctx, bool v);
    void CGContextSetShouldSmoothFonts(void* ctx, bool v);
    void* CGColorSpaceCreateDeviceRGB();
}

private extern "CoreText" {
    void* CTFontCreateWithName(void* name, f64 size, void* matrix);
    f64 CTFontGetAscent(void* font);
    f64 CTFontGetDescent(void* font);
    f64 CTFontGetLeading(void* font);
    bool CTFontGetGlyphsForCharacters(void* font, u16* chars, u16* glyphs, i64 count);
    f64 CTFontGetAdvancesForGlyphs(void* font, u32 orientation, u16* glyphs, void* advances, i64 count);
    CGRect CTFontGetBoundingRectsForGlyphs(void* font, u32 orientation, u16* glyphs, CGRect* rects, i64 count);
    void CTFontDrawGlyphs(void* font, u16* glyphs, CGPoint* positions, i64 count, void* ctx);
    void* CTFontCreateForString(void* font, void* string, CFRange range);
    void* CTFontCreateWithGraphicsFont(void* cgfont, f64 size, void* matrix, void* attrs);
    void* CTFontCreateUIFontForLanguage(u32 uiType, f64 size, void* language);
    u32 CTFontGetSymbolicTraits(void* font);
    void* CTLineCreateWithAttributedString(void* attr);
    void* CTLineGetGlyphRuns(void* line);
    i64 CTRunGetGlyphCount(void* run);
    void CTRunGetGlyphs(void* run, CFRange range, u16* buffer);
    void* CTRunGetAttributes(void* run);
}

private void ct_release(void* f) {
    if f != null { CFRelease(f); }
}

private void* ct_font = null;
private void* ct_ui = null;    // the system UI face, for chrome text
// the color emoji face the cascade hands back at the text size (Apple
// Color Emoji), for cluster glyph ids; single emoji go through the
// cascade as before and take the color path by their face's trait
private void* ct_emoji = null;
private void* ct_rgb_cs = null;   // DeviceRGB, for the color contexts

// cluster -> shaped glyph id, so a visible emoji cluster is shaped once,
// not every frame. Keyed by a hash of the cluster's utf-8 bytes.
private const i32 SHAPE_CACHE = 256;
private struct ShapeEnt {
    u64 h;
    i32 len;
    u16 gid;
    bool used;
}
private ShapeEnt[SHAPE_CACHE] ct_shape_cache;
private u8* ct_scratch = null;
private i32 ct_ascent = 0;
private i32 ct_cell_w = 0;
private i32 ct_line_h = 0;
private i32 ct_px = 0;

// The vendored icon font (see THIRD_PARTY.md), serving the private
// use area U+E000..U+F8FF. Loaded from the working directory; when
// absent, icons raster as blank advances and everything else works.
private void* ct_icon_cg = null;    // CGFont, loaded once
private void* ct_icon = null;       // CTFont at the current size
private void* ct_icon_cap = null;   // the same face at the caption's icon size
private void* ct_seti_cg = null;
private void* ct_seti = null;
private bool ct_icon_tried = false;

// CoreText misparses these icon fonts: its bounds API inflates by
// a font-dependent factor while drawing uses the true outline
// scale. Nothing from the metrics APIs is trusted; calibration
// DRAWS a known glyph at a nominal size and scans the ink, and the
// raster path rebases every icon to its scanned ink box.
private const i32 CT_CAL_SIZE = 100;
private const i32 CT_CAL_DIM = 200;

private f64 ct_icon_calibrate(void* cg, u32 ref_cp, f64 target_em) {
    void* probe = CTFontCreateWithGraphicsFont(cg, cast(f64, CT_CAL_SIZE), null, null);
    if probe == null { return target_em; }
    f64 m = target_em;
    u16 ch = cast(u16, ref_cp);
    u16 g = 0;
    if CTFontGetGlyphsForCharacters(probe, &ch, &g, 1) && g != 0 {
        u8* buf = alloc<u8>(CT_CAL_DIM * CT_CAL_DIM);
        memset(buf, 0, CT_CAL_DIM * CT_CAL_DIM);
        void* ctx = CGBitmapContextCreate(buf, cast(u64, CT_CAL_DIM), cast(u64, CT_CAL_DIM),
            8, cast(u64, CT_CAL_DIM), null, kCGImageAlphaOnly);
        if ctx != null {
            CGPoint pos = CGPoint{ 40.0, 40.0 };
            CTFontDrawGlyphs(probe, &g, &pos, 1, ctx);
            CGContextRelease(ctx);
            i32 lo = -1;
            i32 hi = -1;
            for i32 y = 0; y < CT_CAL_DIM; y++ {
                bool ink = false;
                for i32 x = 0; x < CT_CAL_DIM; x++ {
                    if buf[y * CT_CAL_DIM + x] > 16 { ink = true; break; }
                }
                if ink {
                    if lo < 0 { lo = y; }
                    hi = y;
                }
            }
            if hi > lo {
                m = target_em * cast(f64, CT_CAL_SIZE) / cast(f64, hi - lo + 1);
            }
        }
        free(buf);
    }
    CFRelease(probe);
    return m;
}

private f64 ct_icon_mul = 1.0;
private f64 ct_seti_mul = 1.0;

private void* ct_load_cgfont(str path) {
    FileData fd = file_read(path);
    if fd.data == null { return null; }
    void* cfd = CFDataCreate(null, cast(void*, fd.data), fd.len);
    free(fd.data);
    if cfd == null { return null; }
    void* prov = CGDataProviderCreateWithCFData(cfd);
    CFRelease(cfd);
    if prov == null { return null; }
    void* cg = CGFontCreateWithDataProvider(prov);
    CGDataProviderRelease(prov);
    return cg;
}

bool plat_font_init(i32 dpi, FontMetrics* m) {
    if ct_scratch == null {
        ct_scratch = alloc<u8>(CT_SCRATCH_CAP);
    }
    i32 px = FONT_PX * dpi / DPI_BASE;
    ct_px = px;
    void* name = CFStringCreateWithCString(null, "Menlo", kCFStringEncodingUTF8);
    if name == null { return false; }
    void* nf = CTFontCreateWithName(name, cast(f64, px), null);
    CFRelease(name);
    if nf == null { return false; }
    if ct_font != null { CFRelease(ct_font); }
    ct_font = nf;

    f64 asc = CTFontGetAscent(nf);
    f64 desc = CTFontGetDescent(nf);
    f64 lead = CTFontGetLeading(nf);
    // line box per the reference model, glyphs centered inside it
    i32 natural = cast(i32, ceil(asc + desc + lead));
    i32 lh = LINE_H_BASE * dpi / DPI_BASE;
    if lh < natural { lh = natural; }
    i32 pad = (lh - natural) / 2;
    m.ascent = cast(i32, ceil(asc)) + pad;
    m.line_h = lh;

    u16 mch = 77;  // 'M'
    u16 mg = 0;
    if !CTFontGetGlyphsForCharacters(nf, &mch, &mg, 1) { return false; }
    f64 madv = CTFontGetAdvancesForGlyphs(nf, kCTFontOrientationDefault, &mg, null, 1);
    m.cell_w = cast(i32, round(madv));
    if m.cell_w <= 0 { return false; }

    ct_ascent = m.ascent;
    ct_cell_w = m.cell_w;
    ct_line_h = m.line_h;

    if !ct_icon_tried {
        ct_icon_tried = true;
        noinit u8[PATH_MAX] ap;
        i32 an = asset_file("codicon.ttf", &ap[0], PATH_MAX);
        ct_icon_cg = ct_load_cgfont(str_from(&ap[0], an));
        an = asset_file("seti.ttf", &ap[0], PATH_MAX);
        ct_seti_cg = ct_load_cgfont(str_from(&ap[0], an));
        // drawn-ink targets from the same-scale side-by-side
        // capture: chevrons 0.71 text-em (EAB6), file icons 0.75
        // (the E060 arrow)
        if ct_icon_cg != null {
            ct_icon_mul = ct_icon_calibrate(ct_icon_cg, 0xEAB6, 0.71);
        }
        if ct_seti_cg != null {
            ct_seti_mul = ct_icon_calibrate(ct_seti_cg, 0xE060, 0.75);
        }
    }
    ct_release(ct_icon);
    ct_icon = null;
    ct_release(ct_icon_cap);
    ct_icon_cap = null;
    ct_release(ct_seti);
    ct_seti = null;
    if ct_icon_cg != null {
        ct_icon = CTFontCreateWithGraphicsFont(ct_icon_cg, cast(f64, px) * ct_icon_mul, null, null);
        // the window buttons draw their icons at the caption em
        ct_icon_cap = CTFontCreateWithGraphicsFont(ct_icon_cg,
            cast(f64, CAPTION_ICON_PX * dpi) / cast(f64, DPI_BASE), null, null);
    }
    if ct_seti_cg != null {
        ct_seti = CTFontCreateWithGraphicsFont(ct_seti_cg, cast(f64, px) * ct_seti_mul, null, null);
    }

    // the UI face (chrome text); its absence only blanks UI labels
    ct_release(ct_ui);
    ct_ui = null;
    ct_ui = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem,
        cast(f64, CT_UI_PX * dpi / DPI_BASE), null);
    if ct_ui != null {
        f64 ua = CTFontGetAscent(ct_ui);
        font_ui_ascent = cast(i32, ceil(ua));
        font_ui_h = cast(i32, ceil(ua + CTFontGetDescent(ct_ui) + CTFontGetLeading(ct_ui)));
    }
    // CT_UI_PX carries this machine's window zoom
    font_ui_row = UI_ROW_BASE * CT_UI_PX * dpi / (UI_REF_PX * DPI_BASE);
    // the color emoji face: whatever the cascade would use for an emoji
    // the mono face lacks, at the same size
    if ct_rgb_cs == null { ct_rgb_cs = CGColorSpaceCreateDeviceRGB(); }
    ct_release(ct_emoji);
    ct_emoji = null;
    noinit u16[2] eu;
    eu[0] = 0xD83D;   // U+1F600 as a surrogate pair
    eu[1] = 0xDE00;
    void* estr = CFStringCreateWithCharacters(null, &eu[0], 2);
    if estr != null {
        void* ef = CTFontCreateForString(ct_font, estr, CFRange{ 0, 2 });
        CFRelease(estr);
        if ef != null && (CTFontGetSymbolicTraits(ef) & kCTFontTraitColorGlyphs) != 0 { ct_emoji = ef; }
        else { ct_release(ef); }
    }
    memset(&ct_shape_cache[0], 0, SHAPE_CACHE * sizeof(ShapeEnt));
    return true;
}

// A color glyph of `font`, drawn by CoreText itself into an RGBA
// context (it paints the emoji's bitmap in color) and handed over as
// the contract's straight RGBA. Bounds, padding and offsets as the
// alpha path computes them; the mono grid ignores the advance.
private bool ct_color_raster(void* font, u16 g, GlyphRaster* out) {
    if ct_rgb_cs == null { return false; }
    CGRect box;
    ignore CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationDefault, &g, &box, 1);
    if box.size.width <= 0.0 || box.size.height <= 0.0 { return false; }
    i32 x0 = cast(i32, floor(box.origin.x)) - CT_PAD;
    i32 y0 = cast(i32, floor(box.origin.y)) - CT_PAD;
    i32 x1 = cast(i32, ceil(box.origin.x + box.size.width)) + CT_PAD;
    i32 y1 = cast(i32, ceil(box.origin.y + box.size.height)) + CT_PAD;
    i32 w = x1 - x0;
    i32 h = y1 - y0;
    if w * h * 4 > CT_SCRATCH_CAP { return false; }
    memset(ct_scratch, 0, w * h * 4);
    void* ctx = CGBitmapContextCreate(ct_scratch, cast(u64, w), cast(u64, h),
        8, cast(u64, w * 4), ct_rgb_cs, kCGImageAlphaPremultipliedLast);
    if ctx == null { return false; }
    CGPoint pos = CGPoint{ cast(f64, -x0), cast(f64, -y0) };
    CTFontDrawGlyphs(font, &g, &pos, 1, ctx);
    CGContextRelease(ctx);
    // premultiplied out of the context; the atlas holds straight RGBA
    for i32 i = 0; i < w * h; i++ {
        i32 a = cast(i32, ct_scratch[i * 4 + 3]);
        if a > 0 && a < 255 {
            ct_scratch[i * 4] = cast(u8, cast(i32, ct_scratch[i * 4]) * 255 / a);
            ct_scratch[i * 4 + 1] = cast(u8, cast(i32, ct_scratch[i * 4 + 1]) * 255 / a);
            ct_scratch[i * 4 + 2] = cast(u8, cast(i32, ct_scratch[i * 4 + 2]) * 255 / a);
        }
    }
    out.pixels = ct_scratch;
    out.w = w;
    out.h = h;
    out.pitch = w * 4;
    out.channels = 4;
    out.xoff = x0;
    out.yoff = ct_ascent - y1;
    out.adv = ct_cell_w;
    out.advf = cast(f32, ct_cell_w);
    return true;
}

// Shape an emoji grapheme cluster (utf-8) to a single glyph id of the
// emoji face, or 0. One CTLine over the cluster with the mono face as
// its attribute; the cascade takes it to the emoji face, which ligates
// skin tones, ZWJ sequences, keycaps, VS16 and flags to one glyph.
// Cached by cluster bytes, since the render loop asks per frame.
u32 plat_shape_cluster(u8* s, i32 n) {
    if ct_emoji == null || ct_font == null || n <= 0 { return 0; }
    u64 h = cast(u64, 1469598103934665603);
    for i32 bi = 0; bi < n; bi++ { h = (h ^ cast(u64, s[bi])) * cast(u64, 1099511628211); }
    i32 slot = cast(i32, h % cast(u64, SHAPE_CACHE));
    for i32 k = 0; k < 8; k++ {
        ShapeEnt* e = &ct_shape_cache[(slot + k) % SHAPE_CACHE];
        if e.used && e.h == h && e.len == n { return cast(u32, e.gid); }
        if !e.used { break; }
    }
    u16 gid = 0;
    void* cs = CFStringCreateWithBytes(null, s, cast(i64, n), kCFStringEncodingUTF8, false);
    if cs != null {
        // null callbacks: the one key is CoreText's own constant, which it
        // looks up by pointer, and the value outlives the dictionary
        void*[1] keys = { kCTFontAttributeName };
        void*[1] vals = { ct_font };
        void* attrs = CFDictionaryCreate(null, &keys[0], &vals[0], 1, null, null);
        void* as = null;
        if attrs != null { as = CFAttributedStringCreate(null, cs, attrs); }
        void* line = null;
        if as != null { line = CTLineCreateWithAttributedString(as); }
        if line != null {
            void* runs = CTLineGetGlyphRuns(line);
            if runs != null && CFArrayGetCount(runs) == 1 {
                void* run = CFArrayGetValueAtIndex(runs, 0);
                if CTRunGetGlyphCount(run) == 1 {
                    void* ra = CTRunGetAttributes(run);
                    void* rf = null;
                    if ra != null { rf = CFDictionaryGetValue(ra, kCTFontAttributeName); }
                    if rf != null && (CTFontGetSymbolicTraits(rf) & kCTFontTraitColorGlyphs) != 0 {
                        u16 one = 0;
                        CTRunGetGlyphs(run, CFRange{ 0, 1 }, &one);
                        gid = one;
                    }
                }
            }
            CFRelease(line);
        }
        ct_release(as);
        ct_release(attrs);
        CFRelease(cs);
    }
    for i32 k = 0; k < 8; k++ {
        ShapeEnt* e = &ct_shape_cache[(slot + k) % SHAPE_CACHE];
        if !e.used {
            e.h = h;
            e.len = n;
            e.gid = gid;
            e.used = true;
            break;
        }
    }
    return cast(u32, gid);
}
bool plat_glyph_raster(u32 cp, GlyphRaster* out) {
    if (cp & FONT_GLYPHID) != 0 {
        if ct_emoji == null { return false; }
        return ct_color_raster(ct_emoji, cast(u16, cp & 0xFFFF), out);
    }
    bool is_ui = (cp & FONT_UI) != 0;
    bool caption = (cp & FONT_CAPTION) != 0;
    cp = cp & ~FONT_CAPTION;
    f32 xsub = 0.0f;
    if is_ui {
        xsub = cast(f32, (cp & FONT_PHASE_MASK) >> FONT_PHASE_SHIFT) * 0.25f;
        cp = cp & ~(FONT_UI | FONT_PHASE_MASK);
    }
    noinit u16[2] units;
    i64 nunits = 1;
    if cp >= SURR_BASE {
        units[0] = cast(u16, SURR_HI + ((cp - SURR_BASE) >> 10));
        units[1] = cast(u16, SURR_LO + ((cp - SURR_BASE) & 0x3FF));
        nunits = 2;
    } else {
        units[0] = cast(u16, cp);
    }
    noinit u16[2] glyphs;
    void* font = ct_font;
    bool is_icon = false;
    if is_ui {
        font = ct_ui;
        if font == null { return false; }
    } else if cp >= ICON_CP_MIN && cp <= ICON_CP_MAX {
        is_icon = true;
        // icon codepoints resolve only against the icon fonts:
        // seti file icons sit below U+EA00, codicons above
        font = ct_icon;
        if caption && ct_icon_cap != null { font = ct_icon_cap; }
        if cp < ICON_CP_CODICON { font = ct_seti; }
        if font == null { return false; }
        if !CTFontGetGlyphsForCharacters(font, &units[0], &glyphs[0], nunits) || glyphs[0] == 0 {
            return false;
        }
    }
    void* fb = null;
    defer ct_release(fb);
    // The icon fonts answer for themselves; the text and UI faces both
    // fall back, each off its own base so the substitute comes back at
    // that face's size. Without it for the UI face a codepoint the
    // system UI font lacks kept its advance and drew nothing.
    if !is_icon
        && (!CTFontGetGlyphsForCharacters(font, &units[0], &glyphs[0], nunits) || glyphs[0] == 0) {
        // not in the primary face: ask the system cascade for the
        // face it would fall back to (Hiragino for CJK, ...) and
        // rasterize with that, on the same baseline and grid
        void* str = CFStringCreateWithCharacters(null, &units[0], nunits);
        if str == null { return false; }
        fb = CTFontCreateForString(font, str, CFRange{ 0, nunits });
        CFRelease(str);
        if fb == null { return false; }
        if !CTFontGetGlyphsForCharacters(fb, &units[0], &glyphs[0], nunits) || glyphs[0] == 0 {
            return false;  // nothing in the cascade either: advance only
        }
        font = fb;
        if (CTFontGetSymbolicTraits(fb) & kCTFontTraitColorGlyphs) != 0 {
            if !ct_color_raster(fb, glyphs[0], out) { return false; }
            if is_ui {
                // the color cell is laid out for the mono grid; chrome
                // text wants the UI baseline and the glyph's own advance
                u16 cg = glyphs[0];
                f64 ca = CTFontGetAdvancesForGlyphs(fb, kCTFontOrientationDefault, &cg, null, 1);
                out.yoff += font_ui_ascent - ct_ascent;
                out.adv = cast(i32, round(ca));
                out.advf = cast(f32, ca);
            }
            return true;
        }
    }
    u16 g = glyphs[0];

    // the UI face carries real advances; the mono grid ignores them
    i32 ui_adv = 0;
    f64 ui_advf = 0.0;
    if is_ui {
        // the return value is the summed advance; no buffer needed
        ui_advf = CTFontGetAdvancesForGlyphs(font, kCTFontOrientationDefault, &g, null, 1);
        ui_adv = cast(i32, round(ui_advf));
    }

    // Bounds are baseline-relative, y up.
    CGRect box;
    ignore CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationDefault, &g, &box, 1);
    if box.size.width <= 0.0 || box.size.height <= 0.0 {
        if is_ui && ui_adv > 0 {
            // blank UI glyph (space): keep the advance
            out.pixels = ct_scratch;
            out.w = 0;
            out.h = 0;
            out.pitch = 0;
            out.channels = 1;
            out.xoff = 0;
            out.yoff = 0;
            out.adv = ui_adv;
            out.advf = cast(f32, ui_advf);
            return true;
        }
        return false;  // blank glyph (space)
    }
    i32 x0 = cast(i32, floor(box.origin.x)) - CT_PAD;
    i32 y0 = cast(i32, floor(box.origin.y)) - CT_PAD;
    i32 x1 = cast(i32, ceil(box.origin.x + box.size.width)) + CT_PAD;
    i32 y1 = cast(i32, ceil(box.origin.y + box.size.height)) + CT_PAD;
    i32 w = x1 - x0;
    i32 h = y1 - y0;
    if w * h > CT_SCRATCH_CAP { return false; }

    memset(ct_scratch, 0, w * h);
    void* ctx = CGBitmapContextCreate(ct_scratch, cast(u64, w), cast(u64, h),
        8, cast(u64, w), null, kCGImageAlphaOnly);
    if ctx == null { return false; }
    CGContextSetAllowsFontSmoothing(ctx, CT_FONT_SMOOTHING);
    CGContextSetShouldSmoothFonts(ctx, CT_FONT_SMOOTHING);
    // Draw with the baseline origin at (-x0, -y0); the context is
    // y-up, the buffer rows come out top-down.
    CGPoint pos = CGPoint{ cast(f64, -x0) + cast(f64, xsub), cast(f64, -y0) };
    CTFontDrawGlyphs(font, &g, &pos, 1, ctx);
    CGContextRelease(ctx);

    out.pixels = ct_scratch;
    out.w = w;
    out.h = h;
    out.pitch = w;
    out.channels = 1;
    out.xoff = x0;
    out.yoff = ct_ascent - y1;  // y1 = bitmap top above the baseline
    if is_ui {
        out.yoff = font_ui_ascent - y1;
        out.adv = ui_adv;
        out.advf = cast(f32, ui_advf);
        return true;
    }
    if is_icon {
        // the bounds were inflated: rebase to the scanned ink box
        return font_icon_rebase(ct_scratch, w, h, ct_ascent, ct_cell_w, out);
    }
    out.adv = ct_cell_w;
    out.advf = cast(f32, ct_cell_w);
    return true;
}
