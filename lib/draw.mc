// draw.mc - portable quad batch. Every visible element is a
// textured quad in one vertex array; the gpu backend draws the whole
// batch in one call. Solid rects sample the atlas's white pixel.

struct DrawVtx {
    f32 x;
    f32 y;
    f32 u;
    f32 v;
    u32 col;   // R | G<<8 | B<<16 | A<<24
}

const i32 DRAW_MAX_VERTS = 600000;
const i32 ATLAS_W = 1024;
const i32 ATLAS_H = 1024;

DrawVtx* draw_verts = null;
i32 draw_nverts = 0;

// The batch in runs of one texture each: the glyph atlas, or an image
// the gpu backend holds (gpu_image_create). A backend draws each run
// with its texture: draw_run_first[r] is the run's first vertex, and it
// ends where the next one starts or at draw_nverts. An image run draws
// its texels as they are, smoothed, or as blocks when DRAW_RUN_NEAREST
// is set in its flags. The atlas is DRAW_TEX_ATLAS.
const i32 DRAW_TEX_ATLAS = -1;
const i32 DRAW_RUN_NEAREST = 1;
const i32 DRAW_RUN_MAX = 256;
i32[DRAW_RUN_MAX] draw_run_first;
i32[DRAW_RUN_MAX] draw_run_tex;
i32[DRAW_RUN_MAX] draw_run_flags;
i32 draw_nruns = 0;
private i32 draw_cur_tex = DRAW_TEX_ATLAS;
private i32 draw_cur_flags = 0;

// the run the next quad goes into, opened when the texture changed;
// false when the table is full and the quad cannot be drawn
private bool draw_run_ready() {
    if draw_nruns > 0 && draw_run_tex[draw_nruns - 1] == draw_cur_tex
        && draw_run_flags[draw_nruns - 1] == draw_cur_flags { return true; }
    // an empty last run takes the new texture instead of a new entry
    if draw_nruns > 0 && draw_run_first[draw_nruns - 1] == draw_nverts {
        draw_run_tex[draw_nruns - 1] = draw_cur_tex;
        draw_run_flags[draw_nruns - 1] = draw_cur_flags;
        return true;
    }
    if draw_nruns == DRAW_RUN_MAX { return false; }
    draw_run_first[draw_nruns] = draw_nverts;
    draw_run_tex[draw_nruns] = draw_cur_tex;
    draw_run_flags[draw_nruns] = draw_cur_flags;
    draw_nruns++;
    return true;
}

// Horizontal clip window applied in draw_quad; pane columns clip
// their content exactly at the pane edge (there is no GPU scissor:
// the whole frame is one draw call).
private f32 draw_clip_x0 = -1000000.0f;
private f32 draw_clip_x1 = 1000000.0f;

void draw_clip(f32 x0, f32 x1) {
    draw_clip_x0 = x0;
    draw_clip_x1 = x1;
}

void draw_clip_off() {
    draw_clip_x0 = -1000000.0f;
    draw_clip_x1 = 1000000.0f;
}

// The same in y, for a tile of the explode view, which has an edge at
// the bottom as well as at the sides.
private f32 draw_clip_y0 = -1000000.0f;
private f32 draw_clip_y1 = 1000000.0f;

void draw_clip_y(f32 y0, f32 y1) {
    draw_clip_y0 = y0;
    draw_clip_y1 = y1;
}

void draw_clip_y_off() {
    draw_clip_y0 = -1000000.0f;
    draw_clip_y1 = 1000000.0f;
}

// A scale and an offset applied to every quad while set, for the
// explode view's tiles: a quad at x lands at tx + x * s. The clips are
// in the transformed, on-screen coordinates. A textured quad drawn this
// way has its u stored as -u - 1: the shader then averages the texels a
// pixel covers instead of taking the nearest one, which a glyph drawn
// smaller than its atlas cell needs. A solid rect samples one white
// texel and is left as it is.
private bool draw_xf = false;
private f32 draw_xs = 1.0f;
private f32 draw_xtx = 0.0f;
private f32 draw_xty = 0.0f;

void draw_transform(f32 s, f32 tx, f32 ty) {
    draw_xf = true;
    draw_xs = s;
    draw_xtx = tx;
    draw_xty = ty;
}

void draw_transform_off() {
    draw_xf = false;
}

// the transform is on: the caller draws inside a tile, whose clips stay
bool draw_transformed() { return draw_xf; }

void draw_init() {
    draw_verts = alloc<DrawVtx>(DRAW_MAX_VERTS);
}

void draw_begin() {
    draw_nverts = 0;
    draw_nruns = 0;
    draw_cur_tex = DRAW_TEX_ATLAS;
    draw_cur_flags = 0;
}

// Image `img` (gpu_image_create) over x, y, w, h; u0..u1 and v0..v1 are
// the part of it shown, 0 to 1 across the whole image. `nearest` draws
// the texels as blocks, for a zoom past the image's own size. The alpha
// of `col` fades the image; its color is not used. The clips and the
// transform apply as to any quad.
void draw_image(i32 img, f32 x, f32 y, f32 w, f32 h, f32 u0, f32 v0, f32 u1, f32 v1, bool nearest, u32 col) {
    if img < 0 { return; }
    draw_cur_tex = img;
    draw_cur_flags = 0;
    if nearest { draw_cur_flags = DRAW_RUN_NEAREST; }
    draw_quad(x, y, w, h, u0, v0, u1, v1, col);
    draw_cur_tex = DRAW_TEX_ATLAS;
    draw_cur_flags = 0;
}

void draw_quad(f32 x, f32 y, f32 w, f32 h, f32 u0, f32 v0, f32 u1, f32 v1, u32 col) {
    if draw_nverts + 6 > DRAW_MAX_VERTS { return; }
    if !draw_run_ready() { return; }
    if draw_xf {
        x = draw_xtx + x * draw_xs;
        y = draw_xty + y * draw_xs;
        w = w * draw_xs;
        h = h * draw_xs;
    }
    f32 xa = x;
    f32 xb = x + w;
    if xb <= draw_clip_x0 || xa >= draw_clip_x1 { return; }
    f32 ua = u0;
    f32 ub = u1;
    if xa < draw_clip_x0 || xb > draw_clip_x1 {
        f32 inv = (u1 - u0) / (xb - xa);
        if xa < draw_clip_x0 {
            ua = u0 + (draw_clip_x0 - xa) * inv;
            xa = draw_clip_x0;
        }
        if xb > draw_clip_x1 {
            ub = u1 - (xb - draw_clip_x1) * inv;
            xb = draw_clip_x1;
        }
    }
    f32 ya = y;
    f32 yb = y + h;
    if yb <= draw_clip_y0 || ya >= draw_clip_y1 { return; }
    f32 va = v0;
    f32 vb = v1;
    if ya < draw_clip_y0 || yb > draw_clip_y1 {
        f32 inv = (v1 - v0) / (yb - ya);
        if ya < draw_clip_y0 {
            va = v0 + (draw_clip_y0 - ya) * inv;
            ya = draw_clip_y0;
        }
        if yb > draw_clip_y1 {
            vb = v1 - (yb - draw_clip_y1) * inv;
            yb = draw_clip_y1;
        }
    }
    if draw_xf && u0 != u1 {
        ua = -ua - 1.0f;
        ub = -ub - 1.0f;
    }
    DrawVtx* p = draw_verts + draw_nverts;
    p[0] = DrawVtx{ xa, ya, ua, va, col };
    p[1] = DrawVtx{ xb, ya, ub, va, col };
    p[2] = DrawVtx{ xa, yb, ua, vb, col };
    p[3] = DrawVtx{ xb, ya, ub, va, col };
    p[4] = DrawVtx{ xb, yb, ub, vb, col };
    p[5] = DrawVtx{ xa, yb, ua, vb, col };
    draw_nverts += 6;
}

// The same quad with its top and bottom edges shifted apart, which is
// the italic's shear about the baseline. At a clip edge it is drawn
// upright instead, since the clip is a vertical cut.
void draw_quad_sheared(f32 x, f32 y, f32 w, f32 h, f32 u0, f32 v0, f32 u1, f32 v1, u32 col, f32 dx_top, f32 dx_bot) {
    if draw_nverts + 6 > DRAW_MAX_VERTS { return; }
    if !draw_run_ready() { return; }
    // scaled or clipped in y (a tile): upright, which the size hides
    if draw_xf || draw_clip_y0 > -1000000.0f || draw_clip_y1 < 1000000.0f {
        draw_quad(x, y, w, h, u0, v0, u1, v1, col);
        return;
    }
    f32 lo = x + (dx_top < dx_bot ? dx_top : dx_bot);
    f32 hi = x + w + (dx_top > dx_bot ? dx_top : dx_bot);
    if hi <= draw_clip_x0 || lo >= draw_clip_x1 { return; }
    if lo < draw_clip_x0 || hi > draw_clip_x1 {
        draw_quad(x, y, w, h, u0, v0, u1, v1, col);
        return;
    }
    DrawVtx* p = draw_verts + draw_nverts;
    p[0] = DrawVtx{ x + dx_top, y, u0, v0, col };
    p[1] = DrawVtx{ x + w + dx_top, y, u1, v0, col };
    p[2] = DrawVtx{ x + dx_bot, y + h, u0, v1, col };
    p[3] = DrawVtx{ x + w + dx_top, y, u1, v0, col };
    p[4] = DrawVtx{ x + w + dx_bot, y + h, u1, v1, col };
    p[5] = DrawVtx{ x + dx_bot, y + h, u0, v1, col };
    draw_nverts += 6;
}

// A solid line from (x0, y0) to (x1, y1), w pixels wide: a quad along
// the segment, for the call graph's curves. Not transformed or clipped;
// it is drawn over the whole window.
void draw_segment(f32 x0, f32 y0, f32 x1, f32 y1, f32 w, u32 col) {
    if draw_nverts + 6 > DRAW_MAX_VERTS { return; }
    if !draw_run_ready() { return; }
    f32 dx = x1 - x0;
    f32 dy = y1 - y0;
    f32 len = cast(f32, sqrt(cast(f64, dx * dx + dy * dy)));
    if len <= 0.0f { return; }
    // half the width along the normal
    f32 nx = 0.0f - dy / len * w * 0.5f;
    f32 ny = dx / len * w * 0.5f;
    f32 u = 0.5f / cast(f32, ATLAS_W);
    f32 v = 0.5f / cast(f32, ATLAS_H);
    DrawVtx* p = draw_verts + draw_nverts;
    p[0] = DrawVtx{ x0 + nx, y0 + ny, u, v, col };
    p[1] = DrawVtx{ x1 + nx, y1 + ny, u, v, col };
    p[2] = DrawVtx{ x0 - nx, y0 - ny, u, v, col };
    p[3] = DrawVtx{ x1 + nx, y1 + ny, u, v, col };
    p[4] = DrawVtx{ x1 - nx, y1 - ny, u, v, col };
    p[5] = DrawVtx{ x0 - nx, y0 - ny, u, v, col };
    draw_nverts += 6;
}

// Solid rect: samples the reserved white pixel at atlas (0,0).
void draw_rect(f32 x, f32 y, f32 w, f32 h, u32 col) {
    f32 uw = 0.5f / cast(f32, ATLAS_W);
    f32 vw = 0.5f / cast(f32, ATLAS_H);
    draw_quad(x, y, w, h, uw, vw, uw, vw, col);
}

// the header of a binary PPM of w by h RGB pixels into out; its length.
// The shot of every gpu backend is written this way.
i32 ppm_header(u8* out, i32 w, i32 h) {
    i32 hn = 0;
    str hdr = "P6\n";
    memcpy(out, hdr.data, hdr.len);
    hn += hdr.len;
    hn += fmt_i32(out + hn, w);
    out[hn] = ' ';
    hn++;
    hn += fmt_i32(out + hn, h);
    str tail = "\n255\n";
    memcpy(out + hn, tail.data, tail.len);
    hn += tail.len;
    return hn;
}
