// cbdt.mc - color bitmap glyphs from an OpenType CBLC/CBDT font (Noto
// Color Emoji and the like). The bitmaps are PNG, decoded by the stdlib
// png module; this side walks the CBLC index to a glyph's CBDT entry and
// hands back its RGBA plus the strike's metrics. Portable: no platform
// services, so it serves the stb/font_ttf backend on Linux and the web.
// sbix and COLR are different tables and not handled here.

import png;

struct CbdtGlyph {
    u8* rgba;   // png_decode output (RGBA8, w*h*4); caller frees. null = miss
    i32 w;
    i32 h;
    i32 adv;    // advance, in pixels at the strike's ppem
    i32 bx;     // left side bearing, px at ppem
    i32 by;     // top above the baseline, px at ppem
    i32 ppem;   // the strike's pixels-per-em, for scaling to the cell
}

private u32 cb_be16(u8* p) {
    return (cast(u32, p[0]) << 8) | cast(u32, p[1]);
}

private u32 cb_be32(u8* p) {
    return (cast(u32, p[0]) << 24) | (cast(u32, p[1]) << 16)
        | (cast(u32, p[2]) << 8) | cast(u32, p[3]);
}

private i32 cb_s8(u8 b) {
    if b >= 128 { return cast(i32, b) - 256; }
    return cast(i32, b);
}

// offset of a table in the sfnt directory, or -1
private i64 cb_table(u8* d, i64 n, u8 a, u8 b, u8 c, u8 e) {
    if n < 12 { return -1; }
    u32 num = cb_be16(d + 4);
    for u32 i = 0; i < num; i++ {
        i64 o = 12 + cast(i64, i) * 16;
        if o + 16 > n { break; }
        if d[o] == a && d[o + 1] == b && d[o + 2] == c && d[o + 3] == e {
            return cast(i64, cb_be32(d + o + 8));
        }
    }
    return -1;
}

// True if the font has a color bitmap table this module can read.
bool cbdt_present(u8* d, i64 n) {
    return cb_table(d, n, 'C', 'B', 'L', 'C') >= 0
        && cb_table(d, n, 'C', 'B', 'D', 'T') >= 0;
}

// Glyph id for a codepoint through the font's cmap (formats 4 and 12), or
// 0. A color-bitmap font has no outlines, so stb's font init rejects it;
// this reads the cmap directly instead. Prefers a format-12 subtable so
// astral emoji resolve.
i32 cbdt_cmap(u8* d, i64 n, u32 cp) {
    i64 cmap = cb_table(d, n, 'c', 'm', 'a', 'p');
    if cmap < 0 || cmap + 4 > n { return 0; }
    u32 ntab = cb_be16(d + cmap + 2);
    i64 best = -1;
    u32 best_fmt = 0;
    for u32 i = 0; i < ntab; i++ {
        i64 rec = cmap + 4 + cast(i64, i) * 8;
        if rec + 8 > n { break; }
        u32 plat = cb_be16(d + rec);
        u32 enc = cb_be16(d + rec + 2);
        bool uni = plat == 0 || (plat == 3 && (enc == 1 || enc == 10));
        if !uni { continue; }
        i64 sub = cmap + cast(i64, cb_be32(d + rec + 4));
        if sub + 2 > n { continue; }
        u32 fmt = cb_be16(d + sub);
        if fmt == 12 { best = sub; best_fmt = 12; break; }
        if fmt == 4 && best < 0 { best = sub; best_fmt = 4; }
    }
    if best < 0 { return 0; }
    if best_fmt == 12 {
        u32 ng = cb_be32(d + best + 12);
        for u32 i = 0; i < ng; i++ {
            i64 e = best + 16 + cast(i64, i) * 12;
            if e + 12 > n { break; }
            u32 sc = cb_be32(d + e);
            u32 ec = cb_be32(d + e + 4);
            if cp >= sc && cp <= ec { return cast(i32, cb_be32(d + e + 8) + (cp - sc)); }
        }
        return 0;
    }
    if cp > 0xFFFF { return 0; }
    u32 seg_x2 = cb_be16(d + best + 6);
    i64 end_o = best + 14;
    i64 start_o = end_o + cast(i64, seg_x2) + 2;   // +2 reservedPad
    i64 delta_o = start_o + cast(i64, seg_x2);
    i64 range_o = delta_o + cast(i64, seg_x2);
    u32 segc = seg_x2 / 2;
    for u32 s = 0; s < segc; s++ {
        u32 end = cb_be16(d + end_o + cast(i64, s) * 2);
        if cp <= end {
            u32 start = cb_be16(d + start_o + cast(i64, s) * 2);
            if cp < start { return 0; }
            u32 delta = cb_be16(d + delta_o + cast(i64, s) * 2);
            u32 ro = cb_be16(d + range_o + cast(i64, s) * 2);
            if ro == 0 { return cast(i32, (cp + delta) & 0xFFFF); }
            i64 gi = range_o + cast(i64, s) * 2 + cast(i64, ro) + cast(i64, cp - start) * 2;
            if gi + 2 > n { return 0; }
            u32 gv = cb_be16(d + gi);
            if gv == 0 { return 0; }
            return cast(i32, (gv + delta) & 0xFFFF);
        }
    }
    return 0;
}

// --- GSUB ligature shaping -------------------------------------------
// An emoji sequence (skin tone, ZWJ family, flag, keycap) is a GSUB
// LookupType-4 ligature: a run of glyphs maps to one. This reads only
// the type-4 lookups and applies them greedily, longest match first, to
// a fixpoint over one grapheme cluster's glyphs. That reproduces the
// font's own shaping for these sequences (the ligatures are unconditional
// ccmp), without the general engine (single/multiple/context lookups),
// which the emoji sequences do not need. VS16 carries no cmap glyph and
// is dropped by the caller, as a full shaper's default-ignorable pass would.

// Absolute offset of the GSUB LookupList, or -1. Only the lookup list is
// needed: every type-4 lookup is applied, script and feature selection
// left aside (an emoji font's ligatures are all in one ccmp feature).
private i64 cb_gsub_lookups(u8* d, i64 n) {
    i64 g = cb_table(d, n, 'G', 'S', 'U', 'B');
    if g < 0 || g + 10 > n { return -1; }
    i64 ll = g + cast(i64, cb_be16(d + g + 8));
    if ll + 2 > n { return -1; }
    return ll;
}

// Coverage index of `gid` in a coverage table (formats 1 and 2), or -1.
private i32 cb_coverage_index(u8* d, i64 n, i64 cov, i32 gid) {
    if cov < 0 || cov + 4 > n { return -1; }
    u32 fmt = cb_be16(d + cov);
    u32 g = cast(u32, gid);
    if fmt == 1 {
        i32 cnt = cast(i32, cb_be16(d + cov + 2));
        i64 arr = cov + 4;
        i32 lo = 0;
        i32 hi = cnt - 1;
        while lo <= hi {
            i32 mid = (lo + hi) / 2;
            i64 e = arr + cast(i64, mid) * 2;
            if e + 2 > n { return -1; }
            u32 gv = cb_be16(d + e);
            if g == gv { return mid; }
            if g < gv { hi = mid - 1; } else { lo = mid + 1; }
        }
        return -1;
    }
    if fmt == 2 {
        u32 nr = cb_be16(d + cov + 2);
        i64 arr = cov + 4;
        for u32 r = 0; r < nr; r++ {
            i64 e = arr + cast(i64, r) * 6;
            if e + 6 > n { break; }
            u32 start = cb_be16(d + e);
            u32 end = cb_be16(d + e + 2);
            u32 sci = cb_be16(d + e + 4);
            if g >= start && g <= end { return cast(i32, sci + (g - start)); }
        }
        return -1;
    }
    return -1;
}

// The longest ligature starting at gids[pos], over every type-4 lookup.
// Returns the ligature glyph and sets *out_len to the glyphs it consumes,
// or 0 with *out_len 0 when none matches.
private i32 cb_lig_at(u8* d, i64 n, i64 ll, i32* gids, i32 count, i32 pos, i32* out_len) {
    *out_len = 0;
    i32 best_g = 0;
    i32 best_len = 0;
    u32 nlk = cb_be16(d + ll);
    for u32 li = 0; li < nlk; li++ {
        i64 lo = ll + 2 + cast(i64, li) * 2;
        if lo + 2 > n { break; }
        i64 lk = ll + cast(i64, cb_be16(d + lo));
        if lk + 6 > n { continue; }
        if cb_be16(d + lk) != 4 { continue; }        // ligature lookups only
        u32 nsub = cb_be16(d + lk + 4);
        for u32 si = 0; si < nsub; si++ {
            i64 so = lk + 6 + cast(i64, si) * 2;
            if so + 2 > n { break; }
            i64 sub = lk + cast(i64, cb_be16(d + so));
            if sub + 6 > n { continue; }
            if cb_be16(d + sub) != 1 { continue; }    // LigatureSubstFormat1
            i64 cov = sub + cast(i64, cb_be16(d + sub + 2));
            i32 ci = cb_coverage_index(d, n, cov, gids[pos]);
            if ci < 0 { continue; }
            if cast(u32, ci) >= cb_be16(d + sub + 4) { continue; }
            i64 lso = sub + 6 + cast(i64, ci) * 2;
            if lso + 2 > n { continue; }
            i64 ligset = sub + cast(i64, cb_be16(d + lso));
            if ligset + 2 > n { continue; }
            u32 nlig = cb_be16(d + ligset);
            for u32 gi = 0; gi < nlig; gi++ {
                i64 go = ligset + 2 + cast(i64, gi) * 2;
                if go + 2 > n { break; }
                i64 lig = ligset + cast(i64, cb_be16(d + go));
                if lig + 4 > n { continue; }
                u32 lig_g = cb_be16(d + lig);
                i32 need = cast(i32, cb_be16(d + lig + 2));   // total, incl. first
                if need < 2 || pos + need > count { continue; }
                bool ok = true;
                for i32 c = 1; c < need; c++ {
                    i64 co = lig + 4 + cast(i64, c - 1) * 2;
                    if co + 2 > n || cast(u32, gids[pos + c]) != cb_be16(d + co) {
                        ok = false;
                        break;
                    }
                }
                if ok && need > best_len {
                    best_len = need;
                    best_g = cast(i32, lig_g);
                }
            }
        }
    }
    *out_len = best_len;
    return best_g;
}

// Ligate a cluster's glyph run in place: greedy longest-match type-4
// substitution to a fixpoint. Returns the new glyph count. For a valid
// emoji sequence this collapses to one glyph; other runs are left as far
// as they ligate, so the caller can still draw the base glyph.
i32 cbdt_shape(u8* d, i64 n, i32* gids, i32 count) {
    i64 ll = cb_gsub_lookups(d, n);
    if ll < 0 || count < 2 { return count; }
    bool changed = true;
    while changed {
        changed = false;
        i32 w = 0;
        i32 i = 0;
        while i < count {
            i32 mlen = 0;
            i32 lig = cb_lig_at(d, n, ll, gids, count, i, &mlen);
            if lig != 0 && mlen >= 2 {
                gids[w] = lig;
                i += mlen;
                changed = true;
            } else {
                gids[w] = gids[i];
                i++;
            }
            w++;
        }
        count = w;
    }
    return count;
}

// Decode glyph `gid`'s color bitmap. r.rgba is null on any miss.
CbdtGlyph cbdt_decode(u8* d, i64 n, i32 gid) {
    CbdtGlyph r;
    r.rgba = null;
    r.w = 0;
    r.h = 0;
    i64 cblc = cb_table(d, n, 'C', 'B', 'L', 'C');
    i64 cbdt = cb_table(d, n, 'C', 'B', 'D', 'T');
    if cblc < 0 || cbdt < 0 || cblc + 8 > n { return r; }
    u32 num_sizes = cb_be32(d + cblc + 4);
    i64 st = cblc + 8;
    for u32 s = 0; s < num_sizes; s++ {
        i64 bt = st + cast(i64, s) * 48;
        if bt + 48 > n { break; }
        u32 isa_off = cb_be32(d + bt);
        u32 num_is = cb_be32(d + bt + 8);
        u32 start_g = cb_be16(d + bt + 40);
        u32 end_g = cb_be16(d + bt + 42);
        u32 ppem = cast(u32, d[bt + 45]);    // ppemY
        u32 bit_depth = cast(u32, d[bt + 46]);
        if bit_depth != 32 { continue; }     // color strikes only
        if cast(u32, gid) < start_g || cast(u32, gid) > end_g { continue; }
        i64 isa = cblc + cast(i64, isa_off);
        for u32 k = 0; k < num_is; k++ {
            i64 rec = isa + cast(i64, k) * 8;
            if rec + 8 > n { break; }
            u32 first = cb_be16(d + rec);
            u32 last = cb_be16(d + rec + 2);
            u32 add_off = cb_be32(d + rec + 4);
            if cast(u32, gid) < first || cast(u32, gid) > last { continue; }
            i64 ist = isa + cast(i64, add_off);
            if ist + 8 > n { return r; }
            u32 idx_fmt = cb_be16(d + ist);
            u32 img_fmt = cb_be16(d + ist + 2);
            u32 img_data_off = cb_be32(d + ist + 4);
            i32 gi = gid - cast(i32, first);
            i64 data_off = -1;
            i64 data_len = 0;
            if idx_fmt == 1 {
                i64 arr = ist + 8;
                if arr + cast(i64, gi + 1) * 4 + 4 > n { return r; }
                u32 o0 = cb_be32(d + arr + cast(i64, gi) * 4);
                u32 o1 = cb_be32(d + arr + cast(i64, gi + 1) * 4);
                data_off = cbdt + cast(i64, img_data_off) + cast(i64, o0);
                data_len = cast(i64, o1) - cast(i64, o0);
            } else if idx_fmt == 3 {
                i64 arr = ist + 8;
                if arr + cast(i64, gi + 1) * 2 + 2 > n { return r; }
                u32 o0 = cb_be16(d + arr + cast(i64, gi) * 2);
                u32 o1 = cb_be16(d + arr + cast(i64, gi + 1) * 2);
                data_off = cbdt + cast(i64, img_data_off) + cast(i64, o0);
                data_len = cast(i64, o1) - cast(i64, o0);
            } else {
                return r;   // proportional formats 2/4/5 not seen in emoji fonts
            }
            if data_off < 0 || data_off + data_len > n || data_len < 9 { return r; }
            i64 p = data_off;
            i32 gh = 0;
            i32 gw = 0;
            i32 bx = 0;
            i32 by = 0;
            i32 adv = 0;
            i64 png_len = 0;
            if img_fmt == 17 || img_fmt == 18 {   // small or big metrics, then png
                gh = cast(i32, d[p]);
                gw = cast(i32, d[p + 1]);
                bx = cb_s8(d[p + 2]);
                by = cb_s8(d[p + 3]);
                adv = cast(i32, d[p + 4]);
                // the metrics are 5 or 8 bytes; the length sits after them
                i32 hdr = 9;
                if img_fmt == 18 { hdr = 12; }
                png_len = cast(i64, cb_be32(d + p + hdr - 4));
                p = p + hdr;
            } else if img_fmt == 19 {   // png only, metrics from the strike
                png_len = cast(i64, cb_be32(d + p));
                p = p + 4;
            } else {
                return r;
            }
            if png_len < 8 || p + png_len > n { return r; }
            PngImage img = png_decode(d + p, png_len);
            if img.pixels == null { return r; }
            r.rgba = img.pixels;
            r.w = img.width;
            r.h = img.height;
            r.ppem = cast(i32, ppem);
            if img_fmt == 19 {
                r.adv = img.width;
                r.bx = 0;
                r.by = cast(i32, ppem);
            } else {
                r.adv = adv;
                r.bx = bx;
                r.by = by;
            }
            return r;
        }
    }
    return r;
}
