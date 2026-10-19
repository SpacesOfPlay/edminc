// font_dwrite.mc - Windows font raster backend. GDI selects the font
// and provides metrics (CreateFontW, TEXTMETRICW); DirectWrite
// rasterizes the glyphs (IDWriteGlyphRunAnalysis). Default: ClearType
// 3x1 textures passed through as rgb subpixel coverage (channel
// order flipped on BGR panels). DW_SUBPIXEL = false switches to
// IDWriteFactory2 grayscale analysis (true 1-byte coverage), with
// 3x1-averaged gray as the pre-8.1 fallback. Implements
// plat_font_init and plat_glyph_raster from plat.mc.

private const i32 FONT_PX = 16;          // at DPI_BASE
private const i32 LINE_H_BASE = 22;      // round(1.35 * FONT_PX); the
                                         // reference line-height model
private const i32 UI_FONT_PX = 13;       // the reference workbench size
private const i32 DW_SCRATCH_CAP = 256 * 1024;
private const bool DW_SUBPIXEL = true;

private const i32 DWRITE_FACTORY_TYPE_SHARED = 0;
private const i32 DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC = 5;
private const i32 DWRITE_MEASURING_MODE_NATURAL = 0;
private const i32 DWRITE_TEXTURE_ALIASED_1X1 = 0;
private const i32 DWRITE_TEXTURE_CLEARTYPE_3X1 = 1;
private const i32 DWRITE_GRID_FIT_MODE_ENABLED = 2;
private const i32 DWRITE_GRID_FIT_MODE_DISABLED = 1;
private const i32 DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE = 1;
private const i32 DWRITE_FONT_FACE_TYPE_TRUETYPE = 1;
private const i32 DWRITE_FONT_SIMULATIONS_NONE = 0;

// The vendored icon fonts (see THIRD_PARTY.md), serving the private
// use area U+E000..U+F8FF. Loaded from the working directory; when
// absent, icons raster as blank advances and everything else works.
private const i32 DW_CAL_EM = 100;

private GUID IID_IDWriteFactory = GUID{ cast(u32, 0xB859EE5A), cast(u16, 0xD838), cast(u16, 0x4B5B),
    { cast(u8, 0xA2), cast(u8, 0xE8), cast(u8, 0x1A), cast(u8, 0xDC),
      cast(u8, 0x7D), cast(u8, 0x93), cast(u8, 0xDB), cast(u8, 0x48) } };

private GUID IID_IDWriteFactory2 = GUID{ cast(u32, 0x0439FC60), cast(u16, 0xCA44), cast(u16, 0x4994),
    { cast(u8, 0x8D), cast(u8, 0xEE), cast(u8, 0x3A), cast(u8, 0x9A),
      cast(u8, 0xF7), cast(u8, 0xB7), cast(u8, 0x32), cast(u8, 0xEC) } };

struct DWRITE_GLYPH_RUN {
    void* fontFace;
    f32 fontEmSize;
    u32 glyphCount;
    u16* glyphIndices;
    f32* glyphAdvances;
    void* glyphOffsets;
    i32 isSideways;
    u32 bidiLevel;
}

// COM slices, padded like the gpu backend's (slot positions follow
// the Windows SDK headers).

struct IDWriteFactoryVtbl {
    fn(void*, void*, void**): i32 QueryInterface;
    fn(void*): u32 AddRef;
    fn(void*): u32 Release;
    void* _pad3;
    void* _pad4;
    void* _pad5;
    void* _pad6;
    fn(void*, u16*, void*, void**): i32 CreateFontFileReference;
    void* _pad8;
    fn(void*, i32, u32, void**, u32, i32, void**): i32 CreateFontFace;
    void* _pad10;
    void* _pad11;
    void* _pad12;
    void* _pad13;
    void* _pad14;
    void* _pad15;
    void* _pad16;
    fn(void*, void**): i32 GetGdiInterop;
    void* _pad18;
    void* _pad19;
    void* _pad20;
    fn(void*, void**): i32 CreateTextAnalyzer;   // slot 21
    void* _pad22;
    fn(void*, DWRITE_GLYPH_RUN*, f32, void*, i32, i32, f32, f32, void**): i32 CreateGlyphRunAnalysis;
}

struct IDWriteFactory {
    IDWriteFactoryVtbl* lpVtbl;
}

// v2 (Windows 8.1+): slots 24-29 are the factory1/factory2 methods
// before its CreateGlyphRunAnalysis overload at 30.
struct IDWriteFactory2Vtbl {
    void* _pad0;
    fn(void*): u32 AddRef;
    fn(void*): u32 Release;
    void* _pad3;
    void* _pad4;
    void* _pad5;
    void* _pad6;
    void* _pad7;
    void* _pad8;
    void* _pad9;
    void* _pad10;
    void* _pad11;
    void* _pad12;
    void* _pad13;
    void* _pad14;
    void* _pad15;
    void* _pad16;
    void* _pad17;
    void* _pad18;
    void* _pad19;
    void* _pad20;
    void* _pad21;
    void* _pad22;
    void* _pad23;
    void* _pad24;
    void* _pad25;
    void* _pad26;
    void* _pad27;
    // slot 28: baselineX, baselineY, run, runDescription, measuringMode,
    // worldToDevice, paletteIndex, out colorLayers
    fn(void*, f32, f32, DWRITE_GLYPH_RUN*, void*, i32, void*, u32, void**): i32 TranslateColorGlyphRun;
    void* _pad29;
    fn(void*, DWRITE_GLYPH_RUN*, void*, i32, i32, i32, i32, f32, f32, void**): i32 CreateGlyphRunAnalysis;
}

struct IDWriteFactory2 {
    IDWriteFactory2Vtbl* lpVtbl;
}

struct IDWriteGdiInteropVtbl {
    void* _pad0;
    fn(void*): u32 AddRef;
    fn(void*): u32 Release;
    void* _pad3;
    void* _pad4;
    void* _pad5;
    fn(void*, void*, void**): i32 CreateFontFaceFromHdc;
}

struct IDWriteGdiInterop {
    IDWriteGdiInteropVtbl* lpVtbl;
}

struct IDWriteFontFaceVtbl {
    void* _pad0;
    fn(void*): u32 AddRef;
    fn(void*): u32 Release;
    void* _pad3;
    void* _pad4;
    void* _pad5;
    void* _pad6;
    void* _pad7;
    // void in the SDK; the register return is ignored
    fn(void*, void*): i32 GetMetrics;
    void* _pad9;
    fn(void*, u16*, u32, void*, i32): i32 GetDesignGlyphMetrics;
    fn(void*, u32*, u32, u16*): i32 GetGlyphIndices;
}

struct DWRITE_FONT_METRICS {
    u16 designUnitsPerEm;
    u16 ascent;
    u16 descent;
    i16 lineGap;
    u16 capHeight;
    u16 xHeight;
    i16 underlinePosition;
    u16 underlineThickness;
    i16 strikethroughPosition;
    u16 strikethroughThickness;
}

struct DWRITE_GLYPH_METRICS {
    i32 leftSideBearing;
    u32 advanceWidth;
    i32 rightSideBearing;
    i32 topSideBearing;
    u32 advanceHeight;
    i32 bottomSideBearing;
    i32 verticalOriginY;
}

struct IDWriteFontFace {
    IDWriteFontFaceVtbl* lpVtbl;
}

struct IDWriteGlyphRunAnalysisVtbl {
    void* _pad0;
    fn(void*): u32 AddRef;
    fn(void*): u32 Release;
    fn(void*, i32, RECT*): i32 GetAlphaTextureBounds;
    fn(void*, i32, RECT*, u8*, u32): i32 CreateAlphaTexture;
}

struct IDWriteGlyphRunAnalysis {
    IDWriteGlyphRunAnalysisVtbl* lpVtbl;
}

struct IDWriteFontFileVtbl {
    void* _pad0;
    fn(void*): u32 AddRef;
    fn(void*): u32 Release;
}

struct IDWriteFontFile {
    IDWriteFontFileVtbl* lpVtbl;
}

// color glyph layers (Windows 8.1+): TranslateColorGlyphRun returns an
// enumerator over per-layer glyph runs, each with its own palette color.
struct DWRITE_COLOR_F {
    f32 r;
    f32 g;
    f32 b;
    f32 a;
}

struct DWRITE_COLOR_GLYPH_RUN {
    DWRITE_GLYPH_RUN glyphRun;
    void* glyphRunDescription;
    f32 baselineOriginX;
    f32 baselineOriginY;
    DWRITE_COLOR_F runColor;
    u16 paletteIndex;
}

struct IDWriteColorGlyphRunEnumeratorVtbl {
    void* _pad0;
    fn(void*): u32 AddRef;
    fn(void*): u32 Release;
    fn(void*, i32*): i32 MoveNext;   // out BOOL hasRun
    fn(void*, DWRITE_COLOR_GLYPH_RUN**): i32 GetCurrentRun;
}

struct IDWriteColorGlyphRunEnumerator {
    IDWriteColorGlyphRunEnumeratorVtbl* lpVtbl;
}

// Text shaping, for emoji sequences (skin tone, ZWJ, flags): GetGlyphs
// maps a run of UTF-16 to glyph ids, applying the font's substitutions.
struct DWRITE_SCRIPT_ANALYSIS {
    u16 script;
    i32 shapes;
}

struct IDWriteTextAnalyzerVtbl {
    void* _pad0;
    fn(void*): u32 AddRef;
    fn(void*): u32 Release;
    void* _pad3;   // AnalyzeScript
    void* _pad4;   // AnalyzeBidi
    void* _pad5;   // AnalyzeNumberSubstitution
    void* _pad6;   // AnalyzeLineBreakpoints
    // GetGlyphs (slot 7): text, len, face, sideways, rtl, scriptAnalysis,
    // locale, numberSub, features, featureRangeLengths, featureRanges,
    // maxGlyphCount, out clusterMap, out textProps, out glyphIndices,
    // out glyphProps, out actualGlyphCount
    fn(void*, u16*, u32, void*, i32, i32, void*, void*, void*, void*, void*, u32, u32, u16*, void*, u16*, void*, u32*): i32 GetGlyphs;
}

struct IDWriteTextAnalyzer {
    IDWriteTextAnalyzerVtbl* lpVtbl;
}

extern "dwrite.dll" i32 DWriteCreateFactory(i32 factoryType, void* iid, void** factory);

private void* gdi_hdc = null;
private void* gdi_font = null;
private i32 gdi_ascent = 0;
private i32 gdi_cell_w = 0;
private u8* dw_scratch = null;
private IDWriteFactory* dw_factory = null;
private IDWriteFactory2* dw_factory2 = null;  // null = 3x1 fallback
private IDWriteFontFace* dw_face = null;
private f32 dw_em = 0.0f;
private bool dw_bgr = false;
private IDWriteFontFace* dw_codicon = null;
private IDWriteFontFace* dw_seti = null;
private bool dw_icon_tried = false;
private f32 dw_codicon_mul = 1.0f;
private f32 dw_seti_mul = 1.0f;
private void* gdi_ui_font = null;
private IDWriteFontFace* dw_ui_face = null;
private f32 dw_ui_em = 0.0f;
private f32 dw_ui_adv = 0.0f;   // px per design unit, for advances
// the UI fallback face (Segoe UI Symbol): dingbats, arrows and the rest
// of the symbol blocks Segoe UI itself does not carry. A program's title
// puts them in chrome text, and without this they draw as a blank gap.
private void* gdi_ui_fb_font = null;
private IDWriteFontFace* dw_ui_fb_face = null;
private f32 dw_ui_fb_em = 0.0f;
private f32 dw_ui_fb_adv = 0.0f;
private f32 dw_ui_fb_upem = 0.0f;   // design units per em, to size it to a cell
// the color emoji face (Segoe UI Emoji), used only for codepoints the
// text face has no glyph for; its color layers composite into dw_color_acc
private void* gdi_emoji_font = null;
private IDWriteFontFace* dw_emoji_face = null;
private f32 dw_emoji_em = 0.0f;
private u8* dw_color_acc = null;
private i32 dw_color_accn = 0;   // side of the square accumulator, px
private IDWriteTextAnalyzer* dw_analyzer = null;

// cluster -> shaped glyph id, so a visible emoji cluster is shaped once,
// not every frame. Keyed by a hash of the cluster's utf-8 bytes.
private const i32 SHAPE_CACHE = 256;
private struct ShapeEnt {
    u64 h;
    i32 len;
    u16 gid;
    bool used;
}
private ShapeEnt[SHAPE_CACHE] dw_shape_cache;

// a GDI font by face name at a pixel size, for CreateFontFaceFromHdc;
// plat_font_init runs on every dpi switch, so the wide name is freed
private void* dw_gdi_font(u8* name, i32 px) {
    u16* wname = win_wide(name);
    void* f = CreateFontW(-px, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, ANTIALIASED_QUALITY, 0, wname);
    free(cast(void*, wname));
    return f;
}

// the glyph index of cp in face, 0 when the face lacks it or the
// lookup fails
private u16 dw_gid(IDWriteFontFace* face, u32 cp) {
    u32 c = cp;
    u16 g = 0;
    if face.lpVtbl.GetGlyphIndices(face, &c, 1, &g) < 0 { return 0; }
    return g;
}

private IDWriteFontFace* dw_load_face(u8* path) {
    u16* wpath = win_wide(path);
    void* file = null;
    i32 hr = dw_factory.lpVtbl.CreateFontFileReference(dw_factory, wpath, null, &file);
    free(cast(void*, wpath));
    if hr < 0 { return null; }
    void* face = null;
    hr = dw_factory.lpVtbl.CreateFontFace(dw_factory, DWRITE_FONT_FACE_TYPE_TRUETYPE,
        1, &file, 0, DWRITE_FONT_SIMULATIONS_NONE, &face);
    IDWriteFontFile* ff = cast(IDWriteFontFile*, file);
    ignore ff.lpVtbl.Release(ff);
    if hr < 0 { return null; }
    return cast(IDWriteFontFace*, face);
}

// Grayscale coverage for one glyph at em size, into dw_scratch:
// factory2's true grayscale when present, else 3x1 averaged down.
private bool dw_gray_texture(IDWriteFontFace* face, u16 gidx, f32 em, i32* ow, i32* oh) {
    u16 gi = gidx;
    DWRITE_GLYPH_RUN run;
    run.fontFace = cast(void*, face);
    run.fontEmSize = em;
    run.glyphCount = 1;
    run.glyphIndices = &gi;
    void* a = null;
    i32 tex = DWRITE_TEXTURE_CLEARTYPE_3X1;
    i32 bpp = 3;
    i32 hr = 0;
    if dw_factory2 != null {
        tex = DWRITE_TEXTURE_ALIASED_1X1;
        bpp = 1;
        hr = dw_factory2.lpVtbl.CreateGlyphRunAnalysis(dw_factory2, &run, null,
            DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_MEASURING_MODE_NATURAL,
            DWRITE_GRID_FIT_MODE_ENABLED, DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE,
            0.0f, 0.0f, &a);
    } else {
        hr = dw_factory.lpVtbl.CreateGlyphRunAnalysis(dw_factory, &run, 1.0f, null,
            DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_MEASURING_MODE_NATURAL,
            0.0f, 0.0f, &a);
    }
    if hr < 0 { return false; }
    IDWriteGlyphRunAnalysis* an = cast(IDWriteGlyphRunAnalysis*, a);
    RECT r;
    if !dw_take_texture(an, tex, bpp, &r, ow, oh) { return false; }
    if bpp == 3 { dw_average_3x1(*ow * *oh); }
    return true;
}

// The analysis's coverage into dw_scratch: its bounds, then the
// texture, the analysis released either way. False for a blank glyph
// (a space) or one too big for the scratch.
private bool dw_take_texture(IDWriteGlyphRunAnalysis* an, i32 tex, i32 bpp, RECT* r, i32* ow, i32* oh) {
    i32 hr = an.lpVtbl.GetAlphaTextureBounds(an, tex, r);
    i32 w = r.right - r.left;
    i32 h = r.bottom - r.top;
    if hr < 0 || w <= 0 || h <= 0 || w * h * bpp > DW_SCRATCH_CAP {
        ignore an.lpVtbl.Release(an);
        return false;
    }
    hr = an.lpVtbl.CreateAlphaTexture(an, tex, r, dw_scratch, cast(u32, w * h * bpp));
    ignore an.lpVtbl.Release(an);
    if hr < 0 { return false; }
    *ow = w;
    *oh = h;
    return true;
}

// n 3x1 coverage triplets averaged to one gray byte each, in place
// (safe: write index i never passes read index 3i)
private void dw_average_3x1(i32 n) {
    for i32 i = 0; i < n; i++ {
        i32 s = cast(i32, dw_scratch[i * 3]) + cast(i32, dw_scratch[i * 3 + 1]) + cast(i32, dw_scratch[i * 3 + 2]);
        dw_scratch[i] = cast(u8, s / 3);
    }
}

// Mirrors the CoreText backend: nothing from the converted icon
// fonts' metrics is trusted. Draw a known glyph at a nominal size,
// scan its ink height, scale so drawn ink lands on the target em
// fraction.
private f32 dw_icon_calibrate(IDWriteFontFace* face, u32 ref_cp, f32 target_em) {
    u16 g = dw_gid(face, ref_cp);
    if g == 0 { return target_em; }
    i32 w = 0;
    i32 h = 0;
    if !dw_gray_texture(face, g, cast(f32, DW_CAL_EM), &w, &h) { return target_em; }
    i32 lo = -1;
    i32 hi = -1;
    for i32 y = 0; y < h; y++ {
        bool ink = false;
        for i32 x = 0; x < w; x++ {
            if dw_scratch[y * w + x] > 16 { ink = true; break; }
        }
        if ink {
            if lo < 0 { lo = y; }
            hi = y;
        }
    }
    if hi <= lo { return target_em; }
    return target_em * cast(f32, DW_CAL_EM) / cast(f32, hi - lo + 1);
}

// Icon raster rebased to its scanned ink box, bottom anchored at
// baseline+1, exactly like the CoreText backend.
private f32 dw_caption_em = 10.0f;   // CAPTION_ICON_PX at the current dpi

private bool dw_icon_raster(u32 cp, GlyphRaster* out, bool caption) {
    IDWriteFontFace* face = dw_codicon;
    f32 mul = dw_codicon_mul;
    if cp < ICON_CP_CODICON {
        face = dw_seti;
        mul = dw_seti_mul;
    }
    if face == null { return false; }
    u16 g = dw_gid(face, cp);
    if g == 0 { return false; }
    i32 w = 0;
    i32 h = 0;
    // the window buttons draw their icons at the caption em, not the
    // text em the tree icons follow
    f32 em = dw_em * mul;
    if caption { em = dw_caption_em; }
    if !dw_gray_texture(face, g, em, &w, &h) { return false; }
    return font_icon_rebase(dw_scratch, w, h, gdi_ascent, gdi_cell_w, out);
}

bool plat_font_init(i32 dpi, FontMetrics* m) {
    dw_caption_em = cast(f32, CAPTION_ICON_PX * dpi) / cast(f32, DPI_BASE);
    if gdi_hdc == null {
        gdi_hdc = CreateCompatibleDC(null);
        if gdi_hdc == null { return false; }
        dw_scratch = alloc<u8>(DW_SCRATCH_CAP);
        void* f = null;
        if DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory, &f) < 0 {
            return false;
        }
        dw_factory = cast(IDWriteFactory*, f);
        void* f2 = null;
        if dw_factory.lpVtbl.QueryInterface(dw_factory, &IID_IDWriteFactory2, &f2) >= 0 {
            dw_factory2 = cast(IDWriteFactory2*, f2);
        }
        void* ta = null;
        if dw_factory.lpVtbl.CreateTextAnalyzer(dw_factory, &ta) >= 0 {
            dw_analyzer = cast(IDWriteTextAnalyzer*, ta);
        }
        u32 orient = 1;
        if SystemParametersInfoW(SPI_GETFONTSMOOTHINGORIENTATION, 0, &orient, 0) != 0 {
            dw_bgr = orient == FE_FONTSMOOTHINGORIENTATIONBGR;
        }
    }
    i32 px = FONT_PX * dpi / DPI_BASE;
    void* nf = dw_gdi_font("Consolas", px);
    if nf == null { return false; }
    ignore SelectObject(gdi_hdc, nf);
    if gdi_font != null { ignore DeleteObject(gdi_font); }
    gdi_font = nf;
    TEXTMETRICW tm;
    if GetTextMetricsW(gdi_hdc, &tm) == 0 { return false; }
    // line box per the reference model, glyphs centered inside it
    i32 lh = LINE_H_BASE * dpi / DPI_BASE;
    if lh < tm.tmHeight { lh = tm.tmHeight; }
    i32 pad = (lh - tm.tmHeight) / 2;
    m.cell_w = tm.tmAveCharWidth;
    m.ascent = tm.tmAscent + pad;
    m.line_h = lh;
    gdi_ascent = tm.tmAscent + pad;
    gdi_cell_w = tm.tmAveCharWidth;

    if dw_face != null {
        ignore dw_face.lpVtbl.Release(dw_face);
        dw_face = null;
    }
    void* interop = null;
    if dw_factory.lpVtbl.GetGdiInterop(dw_factory, &interop) < 0 { return false; }
    IDWriteGdiInterop* gi = cast(IDWriteGdiInterop*, interop);
    void* face = null;
    i32 hr = gi.lpVtbl.CreateFontFaceFromHdc(gi, gdi_hdc, &face);
    if hr < 0 {
        ignore gi.lpVtbl.Release(gi);
        return false;
    }
    dw_face = cast(IDWriteFontFace*, face);
    dw_em = cast(f32, px);

    // the UI face (chrome text); its absence only blanks UI labels
    i32 upx = UI_FONT_PX * dpi / DPI_BASE;
    void* uf = dw_gdi_font("Segoe UI", upx);
    if uf != null {
        ignore SelectObject(gdi_hdc, uf);
        if gdi_ui_font != null { ignore DeleteObject(gdi_ui_font); }
        gdi_ui_font = uf;
        TEXTMETRICW utm;
        if GetTextMetricsW(gdi_hdc, &utm) != 0 {
            font_ui_h = utm.tmHeight;
            font_ui_ascent = utm.tmAscent;
        }
        font_ui_row = UI_ROW_BASE * dpi / DPI_BASE;
        if dw_ui_face != null {
            ignore dw_ui_face.lpVtbl.Release(dw_ui_face);
            dw_ui_face = null;
        }
        void* uface = null;
        if gi.lpVtbl.CreateFontFaceFromHdc(gi, gdi_hdc, &uface) >= 0 {
            dw_ui_face = cast(IDWriteFontFace*, uface);
            dw_ui_em = cast(f32, upx);
            DWRITE_FONT_METRICS fm;
            ignore dw_ui_face.lpVtbl.GetMetrics(dw_ui_face, &fm);
            if fm.designUnitsPerEm > 0 {
                dw_ui_adv = cast(f32, upx) / cast(f32, fm.designUnitsPerEm);
            }
        }
    }

    // the UI face's own fallback, at the UI em so it sits on the same
    // line; its absence only leaves the blank this was added to fill
    void* sf = dw_gdi_font("Segoe UI Symbol", upx);
    if sf != null {
        ignore SelectObject(gdi_hdc, sf);
        if gdi_ui_fb_font != null { ignore DeleteObject(gdi_ui_fb_font); }
        gdi_ui_fb_font = sf;
        if dw_ui_fb_face != null {
            ignore dw_ui_fb_face.lpVtbl.Release(dw_ui_fb_face);
            dw_ui_fb_face = null;
        }
        void* sface = null;
        if gi.lpVtbl.CreateFontFaceFromHdc(gi, gdi_hdc, &sface) >= 0 {
            dw_ui_fb_face = cast(IDWriteFontFace*, sface);
            dw_ui_fb_em = cast(f32, upx);
            DWRITE_FONT_METRICS sm;
            ignore dw_ui_fb_face.lpVtbl.GetMetrics(dw_ui_fb_face, &sm);
            if sm.designUnitsPerEm > 0 {
                dw_ui_fb_upem = cast(f32, sm.designUnitsPerEm);
                dw_ui_fb_adv = cast(f32, upx) / dw_ui_fb_upem;
            }
        }
    }

    // the color emoji face: codepoints the text face lacks fall back to
    // it, and its color layers composite into an RGBA cell (see
    // dw_color_texture). Needs factory2 (Windows 8.1+) for the color API.
    void* ef = dw_gdi_font("Segoe UI Emoji", px);
    if ef != null {
        ignore SelectObject(gdi_hdc, ef);
        if gdi_emoji_font != null { ignore DeleteObject(gdi_emoji_font); }
        gdi_emoji_font = ef;
        if dw_emoji_face != null {
            ignore dw_emoji_face.lpVtbl.Release(dw_emoji_face);
            dw_emoji_face = null;
        }
        void* eface = null;
        if gi.lpVtbl.CreateFontFaceFromHdc(gi, gdi_hdc, &eface) >= 0 {
            dw_emoji_face = cast(IDWriteFontFace*, eface);
            dw_emoji_em = cast(f32, px);
        }
    }
    // a square RGBA accumulator generous enough for an emoji at this em
    i32 accn = px * 5 / 2;
    if accn < 32 { accn = 32; }
    if accn > 256 { accn = 256; }
    if dw_color_acc == null || accn != dw_color_accn {
        if dw_color_acc != null { free(dw_color_acc); }
        dw_color_acc = alloc<u8>(accn * accn * 4);
        dw_color_accn = accn;
    }

    ignore gi.lpVtbl.Release(gi);

    if !dw_icon_tried {
        dw_icon_tried = true;
        noinit u8[PATH_MAX] ap;
        asset_file("codicon.ttf", &ap[0], PATH_MAX);
        dw_codicon = dw_load_face(&ap[0]);
        asset_file("seti.ttf", &ap[0], PATH_MAX);
        dw_seti = dw_load_face(&ap[0]);
        // drawn-ink targets shared with the CoreText backend:
        // chevrons 0.71 text-em (EAB6), file icons 0.75 (E060)
        if dw_codicon != null {
            dw_codicon_mul = dw_icon_calibrate(dw_codicon, 0xEAB6, 0.71f);
        }
        if dw_seti != null {
            dw_seti_mul = dw_icon_calibrate(dw_seti, 0xE060, 0.75f);
        }
    }
    return true;
}

// Text-quality raster (ClearType per DW_SUBPIXEL) for one glyph of
// any face at em size, into dw_scratch. Fills the texture box and
// channel count; false = blank glyph or failure.
// xsub shifts the baseline origin for subpixel phase variants; a
// phased raster also disables grid fitting, so the quarter-pixel
// offsets are not re-snapped by hinting
private bool dw_text_texture(IDWriteFontFace* face, u16 gidx, f32 em, f32 xsub, RECT* orc, i32* ow, i32* oh, i32* och) {
    u16 gi = gidx;
    DWRITE_GLYPH_RUN run;
    run.fontFace = cast(void*, face);
    run.fontEmSize = em;
    run.glyphCount = 1;
    run.glyphIndices = &gi;
    void* a = null;
    i32 tex = DWRITE_TEXTURE_CLEARTYPE_3X1;
    i32 bpp = 3;
    i32 hr = 0;
    if !DW_SUBPIXEL && dw_factory2 != null {
        // true grayscale coverage; no LCD filter softening the edges
        tex = DWRITE_TEXTURE_ALIASED_1X1;
        bpp = 1;
        i32 gfit = DWRITE_GRID_FIT_MODE_ENABLED;
        if xsub > 0.0f { gfit = DWRITE_GRID_FIT_MODE_DISABLED; }
        hr = dw_factory2.lpVtbl.CreateGlyphRunAnalysis(dw_factory2, &run, null,
            DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_MEASURING_MODE_NATURAL,
            gfit, DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE,
            xsub, 0.0f, &a);
    } else {
        hr = dw_factory.lpVtbl.CreateGlyphRunAnalysis(dw_factory, &run, 1.0f, null,
            DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_MEASURING_MODE_NATURAL,
            xsub, 0.0f, &a);
    }
    if hr < 0 { return false; }
    IDWriteGlyphRunAnalysis* an = cast(IDWriteGlyphRunAnalysis*, a);
    RECT r;
    i32 w = 0;
    i32 h = 0;
    if !dw_take_texture(an, tex, bpp, &r, &w, &h) { return false; }

    i32 channels = bpp;
    if bpp == 3 && !DW_SUBPIXEL {
        dw_average_3x1(w * h);
        channels = 1;
    } else if bpp == 3 && dw_bgr {
        for i32 i = 0; i < w * h; i++ {
            u8 t = dw_scratch[i * 3];
            dw_scratch[i * 3] = dw_scratch[i * 3 + 2];
            dw_scratch[i * 3 + 2] = t;
        }
    }
    *orc = r;
    *ow = w;
    *oh = h;
    *och = channels;
    return true;
}

// One chrome glyph out of `face`: real advance from the design metrics,
// baseline against the UI ascent. A blank glyph (space) still succeeds
// so the advance is kept; false means the face has no glyph for it.
private bool dw_ui_face_raster(IDWriteFontFace* face, f32 em, f32 advmul,
    u32 cp, f32 xsub, GlyphRaster* out) {
    if face == null { return false; }
    u16 gidx = dw_gid(face, cp);
    if gidx == 0 { return false; }
    i32 adv = 0;
    f32 advf = 0.0f;
    DWRITE_GLYPH_METRICS gm;
    if face.lpVtbl.GetDesignGlyphMetrics(face, &gidx, 1, &gm, 0) >= 0 {
        advf = cast(f32, gm.advanceWidth) * advmul;
        adv = cast(i32, advf + 0.5f);
    }
    RECT r;
    i32 w = 0;
    i32 h = 0;
    i32 channels = 1;
    if !dw_text_texture(face, gidx, em, xsub, &r, &w, &h, &channels) {
        if adv <= 0 { return false; }
        out.pixels = dw_scratch;
        out.w = 0;
        out.h = 0;
        out.pitch = 0;
        out.channels = 1;
        out.xoff = 0;
        out.yoff = 0;
        out.adv = adv;
        out.advf = advf;
        return true;
    }
    out.pixels = dw_scratch;
    out.w = w;
    out.h = h;
    out.pitch = w * channels;
    out.channels = channels;
    out.xoff = r.left;
    out.yoff = font_ui_ascent + r.top;  // bounds are baseline-relative
    out.adv = adv;
    out.advf = advf;
    return true;
}

// The color emoji face's glyph for `cp`, composited; false when that
// face has none or it has no color layers.
private bool dw_emoji_fallback(u32 cp, GlyphRaster* out) {
    if dw_emoji_face == null { return false; }
    u16 egi = dw_gid(dw_emoji_face, cp);
    if egi == 0 { return false; }
    return dw_color_texture(egi, out);
}

// UI-face glyph, with the fallback the text face has. Order by the
// codepoint's default presentation: Segoe UI Symbol carries monochrome
// twins of the emoji as well, so taking it first for everything would
// flatten them, and taking the color face first would paint the
// dingbats a title is full of.
private bool dw_ui_raster(u32 cp, GlyphRaster* out) {
    f32 xsub = cast(f32, (cp & FONT_PHASE_MASK) >> FONT_PHASE_SHIFT) * 0.25f;
    cp = cp & ~FONT_PHASE_MASK;
    if dw_ui_face_raster(dw_ui_face, dw_ui_em, dw_ui_adv, cp, xsub, out) { return true; }
    if cp_emoji_presentation(cp) {
        if dw_emoji_fallback(cp, out) { return true; }
        return dw_ui_face_raster(dw_ui_fb_face, dw_ui_fb_em, dw_ui_fb_adv, cp, xsub, out);
    }
    if dw_ui_face_raster(dw_ui_fb_face, dw_ui_fb_em, dw_ui_fb_adv, cp, xsub, out) { return true; }
    return dw_emoji_fallback(cp, out);
}

// One color layer's coverage, into dw_scratch as 1 byte per pixel; the
// run is already positioned by TranslateColorGlyphRun, so it rasters at
// origin (0,0) and the bounds are baseline-relative like the text path.
private bool dw_glyphrun_gray(DWRITE_GLYPH_RUN* run, RECT* orc, i32* ow, i32* oh) {
    void* a = null;
    i32 hr = dw_factory2.lpVtbl.CreateGlyphRunAnalysis(dw_factory2, run, null,
        DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_MEASURING_MODE_NATURAL,
        DWRITE_GRID_FIT_MODE_ENABLED, DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE, 0.0f, 0.0f, &a);
    if hr < 0 { return false; }
    IDWriteGlyphRunAnalysis* an = cast(IDWriteGlyphRunAnalysis*, a);
    return dw_take_texture(an, DWRITE_TEXTURE_ALIASED_1X1, 1, orc, ow, oh);
}

// A color emoji glyph: composite its COLR layers into dw_color_acc as
// straight (non-premultiplied) RGBA and point `out` at the tight crop.
// Each layer is a monochrome coverage run tinted by its palette color,
// drawn over the accumulator. False when the glyph has no color layers
// (DWRITE_E_NOCOLOR) or the accumulator ends up empty.
private bool dw_color_texture(u16 gidx, GlyphRaster* out) {
    if dw_factory2 == null || dw_emoji_face == null || dw_color_acc == null { return false; }
    u16 gi = gidx;
    f32 adv = dw_emoji_em;
    DWRITE_GLYPH_RUN run;
    run.fontFace = cast(void*, dw_emoji_face);
    run.fontEmSize = dw_emoji_em;
    run.glyphCount = 1;
    run.glyphIndices = &gi;
    run.glyphAdvances = &adv;
    run.glyphOffsets = null;
    run.isSideways = 0;
    run.bidiLevel = 0;
    void* en = null;
    i32 hr = dw_factory2.lpVtbl.TranslateColorGlyphRun(dw_factory2, 0.0f, 0.0f, &run, null,
        DWRITE_MEASURING_MODE_NATURAL, null, 0, &en);
    if hr < 0 || en == null { return false; }   // no color layers, or failure
    IDWriteColorGlyphRunEnumerator* e = cast(IDWriteColorGlyphRunEnumerator*, en);

    i32 accn = dw_color_accn;
    memset(dw_color_acc, 0, accn * accn * 4);
    i32 ax0 = accn / 6;         // baseline origin inside the accumulator
    i32 ay0 = accn * 4 / 5;
    i32 minx = accn;
    i32 miny = accn;
    i32 maxx = -1;
    i32 maxy = -1;

    while true {
        i32 has = 0;
        if e.lpVtbl.MoveNext(e, &has) < 0 || has == 0 { break; }
        DWRITE_COLOR_GLYPH_RUN* cgr = null;
        if e.lpVtbl.GetCurrentRun(e, &cgr) < 0 || cgr == null { break; }
        f32 la = cgr.runColor.a;
        if la <= 0.0f { continue; }   // an invisible or foreground-color layer
        f32 lr = cgr.runColor.r;
        f32 lg = cgr.runColor.g;
        f32 lb = cgr.runColor.b;
        RECT r;
        i32 lw = 0;
        i32 lh = 0;
        if !dw_glyphrun_gray(&cgr.glyphRun, &r, &lw, &lh) { continue; }
        for i32 py = 0; py < lh; py++ {
            i32 ay = r.top + ay0 + py;
            if ay < 0 || ay >= accn { continue; }
            for i32 px = 0; px < lw; px++ {
                i32 ax = r.left + ax0 + px;
                if ax < 0 || ax >= accn { continue; }
                f32 cov = cast(f32, dw_scratch[py * lw + px]) / 255.0f;
                f32 sa = cov * la;
                if sa <= 0.0f { continue; }
                i32 o = (ay * accn + ax) * 4;
                f32 da = cast(f32, dw_color_acc[o + 3]) / 255.0f;
                f32 oa = sa + da * (1.0f - sa);
                if oa <= 0.0f { continue; }
                f32 inv = 1.0f / oa;
                f32 dr = cast(f32, dw_color_acc[o]) / 255.0f;
                f32 dg = cast(f32, dw_color_acc[o + 1]) / 255.0f;
                f32 db = cast(f32, dw_color_acc[o + 2]) / 255.0f;
                dw_color_acc[o] = cast(u8, (lr * sa + dr * da * (1.0f - sa)) * inv * 255.0f + 0.5f);
                dw_color_acc[o + 1] = cast(u8, (lg * sa + dg * da * (1.0f - sa)) * inv * 255.0f + 0.5f);
                dw_color_acc[o + 2] = cast(u8, (lb * sa + db * da * (1.0f - sa)) * inv * 255.0f + 0.5f);
                dw_color_acc[o + 3] = cast(u8, oa * 255.0f + 0.5f);
                if ax < minx { minx = ax; }
                if ax > maxx { maxx = ax; }
                if ay < miny { miny = ay; }
                if ay > maxy { maxy = ay; }
            }
        }
    }
    ignore e.lpVtbl.Release(e);
    if maxx < minx || maxy < miny { return false; }
    out.pixels = dw_color_acc + (miny * accn + minx) * 4;
    out.w = maxx - minx + 1;
    out.h = maxy - miny + 1;
    out.pitch = accn * 4;
    out.channels = 4;
    out.xoff = minx - ax0;
    out.yoff = gdi_ascent + (miny - ay0);   // bounds are baseline-relative
    out.adv = gdi_cell_w;
    out.advf = cast(f32, gdi_cell_w);
    return true;
}

// Shape an emoji grapheme cluster (utf-8) to a single glyph id of the
// emoji face, or 0 when the font does not ligate it to one glyph. Cached
// by cluster bytes so a visible cluster shapes once, not per frame.
u32 plat_shape_cluster(u8* s, i32 n) {
    if dw_analyzer == null || dw_emoji_face == null || n <= 0 { return 0; }
    u64 h = (cast(u64, 0xCBF29CE4) << 32) | cast(u64, 0x84222325);   // FNV-1a
    for i32 bi = 0; bi < n; bi++ { h = (h ^ cast(u64, s[bi])) * cast(u64, 1099511628211); }
    i32 slot = cast(i32, h % cast(u64, SHAPE_CACHE));
    for i32 k = 0; k < 8; k++ {
        ShapeEnt* e = &dw_shape_cache[(slot + k) % SHAPE_CACHE];
        if e.used && e.h == h && e.len == n { return cast(u32, e.gid); }
        if !e.used { break; }
    }
    // a cluster longer than the buffer is no emoji; it shapes to nothing
    noinit u16[64] w16;
    i32 wn = win_utf16(str_from(s, n), &w16[0], 64);
    if wn <= 0 { return 0; }
    if wn == 0 { return 0; }
    DWRITE_SCRIPT_ANALYSIS sa;
    sa.script = 0;
    sa.shapes = 0;
    noinit u16[32] cmap;
    noinit u16[32] tprops;
    noinit u16[32] gids;
    noinit u16[32] gprops;
    u32 ng = 0;
    i32 hr = dw_analyzer.lpVtbl.GetGlyphs(dw_analyzer, &w16[0], cast(u32, wn),
        cast(void*, dw_emoji_face), 0, 0, cast(void*, &sa), null, null, null, null, 0,
        32, &cmap[0], cast(void*, &tprops[0]), &gids[0], cast(void*, &gprops[0]), &ng);
    u16 gid = 0;
    if hr >= 0 && ng == 1 && gids[0] != 0 { gid = gids[0]; }
    for i32 k = 0; k < 8; k++ {
        ShapeEnt* e = &dw_shape_cache[(slot + k) % SHAPE_CACHE];
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

// A symbol-face glyph for the text grid: the same face the UI falls back
// to, rastered at the text em on the grid's baseline and cell. The face
// is not monospaced, so a glyph wider than the cells it occupies is
// scaled down to them rather than left to bleed into the next one.
private bool dw_sym_raster(u32 cp, GlyphRaster* out) {
    if dw_ui_fb_face == null || dw_ui_fb_upem <= 0.0f { return false; }
    u16 gidx = dw_gid(dw_ui_fb_face, cp);
    if gidx == 0 { return false; }
    f32 em = dw_em;
    i32 cells = cp_width(cp);
    if cells < 1 { cells = 1; }
    f32 room = cast(f32, gdi_cell_w * cells);
    DWRITE_GLYPH_METRICS gm;
    if dw_ui_fb_face.lpVtbl.GetDesignGlyphMetrics(dw_ui_fb_face, &gidx, 1, &gm, 0) >= 0 {
        f32 advf = cast(f32, gm.advanceWidth) * (dw_em / dw_ui_fb_upem);
        if advf > room && advf > 0.0f { em = dw_em * room / advf; }
    }
    RECT r;
    i32 w = 0;
    i32 h = 0;
    i32 channels = 1;
    if !dw_text_texture(dw_ui_fb_face, gidx, em, 0.0f, &r, &w, &h, &channels) { return false; }
    out.pixels = dw_scratch;
    out.w = w;
    out.h = h;
    out.pitch = w * channels;
    out.channels = channels;
    out.xoff = r.left;
    out.yoff = gdi_ascent + r.top;
    out.adv = gdi_cell_w;
    out.advf = cast(f32, gdi_cell_w);
    return true;
}

bool plat_glyph_raster(u32 cp, GlyphRaster* out) {
    if (cp & FONT_GLYPHID) != 0 {
        return dw_color_texture(cast(u16, cp & 0xFFFF), out);
    }
    if (cp & FONT_UI) != 0 {
        return dw_ui_raster(cp & ~FONT_UI, out);
    }
    bool caption = (cp & FONT_CAPTION) != 0;
    cp = cp & ~FONT_CAPTION;
    if cp >= ICON_CP_MIN && cp <= ICON_CP_MAX {
        // icon codepoints resolve only against the icon fonts
        return dw_icon_raster(cp, out, caption);
    }
    u16 gidx = dw_gid(dw_face, cp);
    if gidx == 0 {
        // Not in the text face. A dingbat, arrow or box-drawing
        // character wants the symbol face: monochrome, so it takes the
        // cell's own color, which is what a terminal's prompt marker
        // and rules are. What is emoji by default wants the color face.
        if cp_emoji_presentation(cp) {
            if dw_emoji_fallback(cp, out) { return true; }
            return dw_sym_raster(cp, out);
        }
        if dw_sym_raster(cp, out) { return true; }
        return dw_emoji_fallback(cp, out);   // advance only when it has none
    }

    RECT r;
    i32 w = 0;
    i32 h = 0;
    i32 channels = 1;
    if !dw_text_texture(dw_face, gidx, dw_em, 0.0f, &r, &w, &h, &channels) {
        return false;  // blank glyph (space): advance only
    }
    out.pixels = dw_scratch;
    out.w = w;
    out.h = h;
    out.pitch = w * channels;
    out.channels = channels;
    out.xoff = r.left;
    out.yoff = gdi_ascent + r.top;  // bounds are baseline-relative
    out.adv = gdi_cell_w;
    out.advf = cast(f32, gdi_cell_w);
    return true;
}
