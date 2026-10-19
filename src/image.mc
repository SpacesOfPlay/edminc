// image.mc - the image viewer. A .png, .jpg or .jpeg file opens as a
// buffer that holds an image instead of text; ed.mc keeps the image's
// index in the buffer slot, g_img for the loaded one. The file is
// decoded off the UI thread with the stdlib's decoders, the texture is
// made on it (gpu_image_create), and view.mc draws the image fitted to
// the pane or at the zoom asked for (image_render).
// Keys: + and - zoom, 0 fills the pane, 1 shows actual size, the arrows pan. A
// wheel notch zooms around the pointer; a touchpad's scroll and a drag
// with the left button pan.

import file;
import png;
import jpeg;

const i32 IMG_LOADING = 0;
const i32 IMG_READY = 1;
const i32 IMG_FAILED = 2;

private const i32 IMG_MAX = 64;
private const i32 IMG_ERR_MAX = 200;
private const f32 IMG_ZOOM_MIN = 0.01f;
private const f32 IMG_ZOOM_MAX = 64.0f;
private const f32 IMG_ZOOM_STEP = 1.25f;
private const f32 IMG_BLOCKS_FROM = 3.0f;   // magnified this far, texels draw as blocks
private const i32 IMG_SIDE_MAX = 8192;      // larger images are halved until they fit a texture
private const i32 IMG_PAN_PARTS = 8;        // an arrow pans an eighth of the pane

private struct ImgEntry {
    bool used;
    u8[PATH_MAX] path;
    i32 path_len;
    i32 state;
    i32 w;             // as decoded, before any halving for the texture
    i32 h;
    i64 bytes;         // the file's size
    bool alpha;        // some texel is not opaque: a checkerboard goes behind
    u8[IMG_ERR_MAX] err;
    i32 err_len;
    i32 gpu;           // the texture, -1 until it is made
    i32 gen;           // the decode asked for last; an older result is dropped
    FileStamp stamp;   // the file as it was when that decode started
    // the view: fitted, or `zoom` with image point (cx, cy) at the
    // pane's center. A fit opens at most at the image's own size; `grow`
    // (the 0 key) lets it fill the pane.
    bool fit;
    bool grow;
    f32 zoom;
    f32 cx;
    f32 cy;
    // where it was drawn last, for the mouse and the keys
    i32 vx0;
    i32 vy0;
    i32 vx1;
    i32 vy1;
    f32 vscale;
}
private ImgEntry[IMG_MAX] img_tab;

// the harnesses decode where the file opens, so a run is the same each
// time; the browser has no threads
bool image_threaded = true;

// --- the files ------------------------------------------------------------

private u8 img_lower(u8 c) {
    if c >= 'A' && c <= 'Z' { return cast(u8, c + 32); }
    return c;
}

private bool img_ends(str p, str ext) {
    if p.len < ext.len { return false; }
    for i32 i = 0; i < ext.len; i++ {
        if img_lower(p.data[p.len - ext.len + i]) != ext.data[i] { return false; }
    }
    return true;
}

// the files the viewer opens instead of the text editor
bool image_path(str p) {
    return img_ends(p, ".png") || img_ends(p, ".jpg") || img_ends(p, ".jpeg");
}

// --- the decode ---------------------------------------------------------------

// what a decode gives back: RGBA8 pixels, or the reason there are none
private struct ImgResult {
    i32 idx;
    i32 gen;
    u8* px;
    i32 w;             // the image's own size
    i32 h;
    i32 tw;            // the texture's, after any halving
    i32 th;
    i64 bytes;
    bool alpha;
    u8[IMG_ERR_MAX] err;
    i32 err_len;
}

private void img_err(ImgResult* r, str m) {
    i32 n = m.len;
    if n > IMG_ERR_MAX { n = IMG_ERR_MAX; }
    memcpy(&r.err[0], m.data, n);
    r.err_len = n;
}

// the pixels at half the size, each the mean of a 2 by 2 block
private u8* img_halve(u8* px, i32 w, i32 h, i32* ow, i32* oh) {
    i32 nw = w / 2;
    i32 nh = h / 2;
    if nw < 1 { nw = 1; }
    if nh < 1 { nh = 1; }
    u8* out = alloc<u8>(cast(i64, nw) * cast(i64, nh) * 4);
    for i32 y = 0; y < nh; y++ {
        i32 y0 = y * 2;
        i32 y1 = y0 + 1;
        if y1 >= h { y1 = y0; }
        for i32 x = 0; x < nw; x++ {
            i32 x0 = x * 2;
            i32 x1 = x0 + 1;
            if x1 >= w { x1 = x0; }
            for i32 c = 0; c < 4; c++ {
                i32 s = cast(i32, px[(cast(i64, y0) * w + x0) * 4 + c]) + cast(i32, px[(cast(i64, y0) * w + x1) * 4 + c])
                    + cast(i32, px[(cast(i64, y1) * w + x0) * 4 + c]) + cast(i32, px[(cast(i64, y1) * w + x1) * 4 + c]);
                out[(cast(i64, y) * nw + x) * 4 + c] = cast(u8, (s + 2) / 4);
            }
        }
    }
    *ow = nw;
    *oh = nh;
    return out;
}

// The file into pixels: by its first bytes, not its name, so a .jpg that
// is a PNG still shows. A JPEG is turned upright by its EXIF
// orientation.
private void img_decode(str path, ImgResult* r) {
    r.px = null;
    r.err_len = 0;
    r.alpha = false;
    FileData fd = file_read(path);
    if fd.data == null {
        img_err(r, "cannot read the file");
        return;
    }
    r.bytes = cast(i64, fd.len);
    bool is_png = fd.len >= 8 && fd.data[0] == 0x89 && fd.data[1] == 'P' && fd.data[2] == 'N' && fd.data[3] == 'G';
    bool is_jpeg = fd.len >= 3 && fd.data[0] == 0xFF && fd.data[1] == 0xD8 && fd.data[2] == 0xFF;
    if is_png {
        PngImage im = png_decode(fd.data, cast(i64, fd.len));
        if im.pixels == null {
            img_err(r, im.error);
        } else {
            r.px = im.pixels;
            r.w = im.width;
            r.h = im.height;
        }
    } else if is_jpeg {
        JpegImage jm = jpeg_decode(fd.data, cast(i64, fd.len));
        if jm.pixels == null {
            img_err(r, jm.error);
        } else {
            jpeg_apply_orientation(&jm);
            r.px = jm.pixels;
            r.w = jm.width;
            r.h = jm.height;
        }
    } else {
        img_err(r, "not a PNG or JPEG file");
    }
    free(fd.data);
    if r.px == null { return; }
    i64 n = cast(i64, r.w) * cast(i64, r.h);
    for i64 k = 0; k < n; k++ {
        if r.px[k * 4 + 3] != 255 {
            r.alpha = true;
            break;
        }
    }
    // a texture has a largest side; the image is shown at its own size
    // all the same, from the smaller copy
    r.tw = r.w;
    r.th = r.h;
    while r.tw > IMG_SIDE_MAX || r.th > IMG_SIDE_MAX {
        i32 nw = 0;
        i32 nh = 0;
        u8* hp = img_halve(r.px, r.tw, r.th, &nw, &nh);
        free(r.px);
        r.px = hp;
        r.tw = nw;
        r.th = nh;
    }
}

// --- the worker ---------------------------------------------------------------
// One thread decodes, the jobs in the order they came; it waits on a
// semaphore between them, so it costs nothing at idle. The results go
// back to the UI thread, which makes the textures (image_pump).

private const i32 IMG_JOBS_MAX = 64;
private Mutex img_mu;
private Semaphore img_sem;
private Thread img_thr;
private bool img_started = false;
private i32[IMG_JOBS_MAX] img_job_idx;
private i32[IMG_JOBS_MAX] img_job_gen;
private u8[IMG_JOBS_MAX * PATH_MAX] img_job_path;
private i32[IMG_JOBS_MAX] img_job_len;
private i32 img_njobs = 0;
private ImgResult[IMG_JOBS_MAX] img_res;
private i32 img_nres = 0;

private void img_worker(void* arg) {
    while true {
        sem_wait(&img_sem);
        mutex_lock(&img_mu);
        if img_njobs == 0 {
            mutex_unlock(&img_mu);
            continue;
        }
        i32 idx = img_job_idx[0];
        i32 gen = img_job_gen[0];
        noinit u8[PATH_MAX] pb;
        i32 plen = img_job_len[0];
        memcpy(&pb[0], &img_job_path[0], plen);
        for i32 k = 1; k < img_njobs; k++ {
            img_job_idx[k - 1] = img_job_idx[k];
            img_job_gen[k - 1] = img_job_gen[k];
            img_job_len[k - 1] = img_job_len[k];
            memcpy(&img_job_path[(k - 1) * PATH_MAX], &img_job_path[k * PATH_MAX], img_job_len[k]);
        }
        img_njobs--;
        mutex_unlock(&img_mu);
        ImgResult r;
        r.idx = idx;
        r.gen = gen;
        img_decode(str_from(&pb[0], plen), &r);
        mutex_lock(&img_mu);
        if img_nres < IMG_JOBS_MAX {
            img_res[img_nres] = r;
            img_nres++;
        } else if r.px != null {
            free(r.px);
        }
        mutex_unlock(&img_mu);
        plat_wake();
    }
}

private void img_apply(ImgResult* r) {
    if r.idx < 0 || r.idx >= IMG_MAX || !img_tab[r.idx].used || img_tab[r.idx].gen != r.gen {
        if r.px != null { free(r.px); }
        return;
    }
    ImgEntry* e = &img_tab[r.idx];
    e.bytes = r.bytes;
    if r.px == null {
        e.state = IMG_FAILED;
        memcpy(&e.err[0], &r.err[0], r.err_len);
        e.err_len = r.err_len;
        plat_damage();
        return;
    }
    i32 g = gpu_image_create(r.px, r.tw, r.th);
    free(r.px);
    if g < 0 {
        e.state = IMG_FAILED;
        str m = "the graphics device did not take the image";
        memcpy(&e.err[0], m.data, m.len);
        e.err_len = m.len;
        plat_damage();
        return;
    }
    if e.gpu >= 0 { gpu_image_free(e.gpu); }
    e.gpu = g;
    e.w = r.w;
    e.h = r.h;
    e.alpha = r.alpha;
    e.state = IMG_READY;
    plat_damage();
}

// the decodes that finished, into textures; the UI thread, on a wake
void image_pump() {
    if !img_started { return; }
    mutex_lock(&img_mu);
    i32 n = img_nres;
    noinit ImgResult[IMG_JOBS_MAX] got;
    for i32 k = 0; k < n; k++ { got[k] = img_res[k]; }
    img_nres = 0;
    mutex_unlock(&img_mu);
    for i32 k = 0; k < n; k++ { img_apply(&got[k]); }
}

private void img_decode_start(i32 i) {
    ImgEntry* e = &img_tab[i];
    e.gen++;
    str p = str_from(&e.path[0], e.path_len);
    e.stamp = file_stamp(p);
    bool inline_decode = !image_threaded;
    when os(wasm) { inline_decode = true; }
    if inline_decode {
        ImgResult r;
        r.idx = i;
        r.gen = e.gen;
        img_decode(p, &r);
        img_apply(&r);
        return;
    }
    when !os(wasm) {
        if !img_started {
            mutex_init(&img_mu);
            sem_init(&img_sem, 0);
            img_started = true;
            thread_create(&img_thr, img_worker, null);
        }
        mutex_lock(&img_mu);
        if img_njobs < IMG_JOBS_MAX {
            img_job_idx[img_njobs] = i;
            img_job_gen[img_njobs] = e.gen;
            memcpy(&img_job_path[img_njobs * PATH_MAX], p.data, p.len);
            img_job_len[img_njobs] = p.len;
            img_njobs++;
        }
        mutex_unlock(&img_mu);
        sem_signal(&img_sem);
    }
}

// --- the table ------------------------------------------------------------------

// A new image for the file at `path`, its decode started; the index, or
// -1 when the table is full.
i32 image_open(str path) {
    if path.len == 0 || path.len > PATH_MAX { return -1; }
    i32 i = -1;
    for i32 k = 0; k < IMG_MAX; k++ {
        if !img_tab[k].used {
            i = k;
            break;
        }
    }
    if i < 0 { return -1; }
    ImgEntry* e = &img_tab[i];
    i32 gen = e.gen;
    ImgEntry z;
    *e = z;
    e.gen = gen;
    e.used = true;
    memcpy(&e.path[0], path.data, path.len);
    e.path_len = path.len;
    e.state = IMG_LOADING;
    e.gpu = -1;
    e.fit = true;
    e.zoom = 1.0f;
    img_decode_start(i);
    return i;
}

// the file changed on disk: decoded again, the old picture shown until
// the new one is ready
void image_reload(i32 i) {
    if i < 0 || i >= IMG_MAX || !img_tab[i].used { return; }
    img_decode_start(i);
}

// The watcher saw a change: decoded again when this file's stamp moved.
// A deleted file keeps the picture it had.
void image_disk_check(i32 i) {
    if i < 0 || i >= IMG_MAX || !img_tab[i].used { return; }
    ImgEntry* e = &img_tab[i];
    FileStamp now = file_stamp(str_from(&e.path[0], e.path_len));
    if !now.ok || !file_stamp_changed(now, e.stamp) { return; }
    img_decode_start(i);
}

// the buffer went; a decode still running for it is dropped when it lands
void image_release(i32 i) {
    if i < 0 || i >= IMG_MAX || !img_tab[i].used { return; }
    ImgEntry* e = &img_tab[i];
    if e.gpu >= 0 { gpu_image_free(e.gpu); }
    e.gpu = -1;
    e.used = false;
    e.gen++;
}

i32 image_state(i32 i) {
    if i < 0 || i >= IMG_MAX || !img_tab[i].used { return IMG_FAILED; }
    return img_tab[i].state;
}

i32 image_w(i32 i) { return img_tab[i].w; }
i32 image_h(i32 i) { return img_tab[i].h; }
i32 image_gpu(i32 i) { return img_tab[i].gpu; }
bool image_alpha(i32 i) { return img_tab[i].alpha; }
str image_error(i32 i) { return str_from(&img_tab[i].err[0], img_tab[i].err_len); }
bool image_fitted(i32 i) { return img_tab[i].fit; }

// --- the view ---------------------------------------------------------------------

// the scale the image draws at in a pane w by h: fitted (above its own
// size only with grow), or the zoom asked for
f32 image_scale(i32 i, i32 w, i32 h) {
    ImgEntry* e = &img_tab[i];
    if !e.fit { return e.zoom; }
    if e.w <= 0 || e.h <= 0 || w <= 0 || h <= 0 { return 1.0f; }
    f32 s = cast(f32, w) / cast(f32, e.w);
    f32 sh = cast(f32, h) / cast(f32, e.h);
    if sh < s { s = sh; }
    if s > 1.0f && !e.grow { s = 1.0f; }
    return s;
}

// whether texels draw as blocks at scale s
bool image_blocks(f32 s) { return s >= IMG_BLOCKS_FROM; }

// The image's top-left on screen in the pane x0, y0, x1, y1 at scale s:
// fitted, centered; else image point (cx, cy) at the pane's center. The
// drawn rectangle is kept for the mouse and the keys.
void image_place(i32 i, i32 x0, i32 y0, i32 x1, i32 y1, f32 s, f32* ox, f32* oy) {
    ImgEntry* e = &img_tab[i];
    f32 mx = cast(f32, x0 + x1) * 0.5f;
    f32 my = cast(f32, y0 + y1) * 0.5f;
    if e.fit {
        *ox = mx - cast(f32, e.w) * s * 0.5f;
        *oy = my - cast(f32, e.h) * s * 0.5f;
    } else {
        *ox = mx - e.cx * s;
        *oy = my - e.cy * s;
    }
    e.vx0 = x0;
    e.vy0 = y0;
    e.vx1 = x1;
    e.vy1 = y1;
    e.vscale = s;
}

// The center kept where the image covers the pane: an image narrower
// than the pane is centered across it, a wider one cannot be moved past
// its edges.
private void img_clamp(ImgEntry* e) {
    f32 hw = cast(f32, e.vx1 - e.vx0) * 0.5f / e.zoom;
    f32 hh = cast(f32, e.vy1 - e.vy0) * 0.5f / e.zoom;
    f32 w = cast(f32, e.w);
    f32 h = cast(f32, e.h);
    if hw * 2.0f >= w { e.cx = w * 0.5f; } else {
        if e.cx < hw { e.cx = hw; }
        if e.cx > w - hw { e.cx = w - hw; }
    }
    if hh * 2.0f >= h { e.cy = h * 0.5f; } else {
        if e.cy < hh { e.cy = hh; }
        if e.cy > h - hh { e.cy = h - hh; }
    }
}

// from fitted to an explicit zoom at the scale it was drawn at
private void img_unfit(ImgEntry* e) {
    if !e.fit { return; }
    e.fit = false;
    e.zoom = e.vscale;
    if e.zoom <= 0.0f { e.zoom = 1.0f; }
    e.cx = cast(f32, e.w) * 0.5f;
    e.cy = cast(f32, e.h) * 0.5f;
}

// zoom by factor f, the image point under screen (px, py) staying there
void image_zoom_at(i32 i, f32 f, i32 px, i32 py) {
    if i < 0 || i >= IMG_MAX || img_tab[i].state != IMG_READY { return; }
    ImgEntry* e = &img_tab[i];
    img_unfit(e);
    f32 mx = cast(f32, e.vx0 + e.vx1) * 0.5f;
    f32 my = cast(f32, e.vy0 + e.vy1) * 0.5f;
    // the image point under the pointer, before
    f32 ux = e.cx + (cast(f32, px) - mx) / e.zoom;
    f32 uy = e.cy + (cast(f32, py) - my) / e.zoom;
    f32 z = e.zoom * f;
    if z < IMG_ZOOM_MIN { z = IMG_ZOOM_MIN; }
    if z > IMG_ZOOM_MAX { z = IMG_ZOOM_MAX; }
    e.zoom = z;
    e.cx = ux - (cast(f32, px) - mx) / z;
    e.cy = uy - (cast(f32, py) - my) / z;
    img_clamp(e);
    plat_damage();
}

// the view moved by (dx, dy) screen pixels, the image following
void image_pan(i32 i, f32 dx, f32 dy) {
    if i < 0 || i >= IMG_MAX || img_tab[i].state != IMG_READY { return; }
    ImgEntry* e = &img_tab[i];
    img_unfit(e);
    e.cx -= dx / e.zoom;
    e.cy -= dy / e.zoom;
    img_clamp(e);
    plat_damage();
}

// fitted to the pane, a small image scaled up to fill it
void image_fit(i32 i) {
    if i < 0 || i >= IMG_MAX { return; }
    img_tab[i].fit = true;
    img_tab[i].grow = true;
    plat_damage();
}

// actual size, around the center shown now
void image_actual(i32 i) {
    if i < 0 || i >= IMG_MAX || img_tab[i].state != IMG_READY { return; }
    ImgEntry* e = &img_tab[i];
    img_unfit(e);
    e.zoom = 1.0f;
    img_clamp(e);
    plat_damage();
}

private i32 img_mid_x(ImgEntry* e) { return (e.vx0 + e.vx1) / 2; }
private i32 img_mid_y(ImgEntry* e) { return (e.vy0 + e.vy1) / 2; }

// A key in an image pane: true when it was the viewer's
bool image_key(i32 i, i32 key, i32 mods) {
    if i < 0 || mods != 0 { return false; }
    ImgEntry* e = &img_tab[i];
    i32 stepx = (e.vx1 - e.vx0) / IMG_PAN_PARTS;
    i32 stepy = (e.vy1 - e.vy0) / IMG_PAN_PARTS;
    if key == K_LEFT { image_pan(i, cast(f32, stepx), 0.0f); return true; }
    if key == K_RIGHT { image_pan(i, cast(f32, 0 - stepx), 0.0f); return true; }
    if key == K_UP { image_pan(i, 0.0f, cast(f32, stepy)); return true; }
    if key == K_DOWN { image_pan(i, 0.0f, cast(f32, 0 - stepy)); return true; }
    return false;
}

// A typed character in an image pane: the zoom keys; any other does
// nothing, since an image takes no text
void image_char(i32 i, u32 cp) {
    if i < 0 { return; }
    ImgEntry* e = &img_tab[i];
    if cp == '+' || cp == '=' { image_zoom_at(i, IMG_ZOOM_STEP, img_mid_x(e), img_mid_y(e)); return; }
    if cp == '-' || cp == '_' { image_zoom_at(i, 1.0f / IMG_ZOOM_STEP, img_mid_x(e), img_mid_y(e)); return; }
    if cp == '0' { image_fit(i); return; }
    if cp == '1' { image_actual(i); return; }
}

// A wheel notch zooms around the pointer, a step per notch; a touchpad's
// scroll pans, the content following the fingers.
void image_scroll(i32 i, f32 dx, f32 dy, i32 x, i32 y, bool notch) {
    if i < 0 || i >= IMG_MAX || img_tab[i].state != IMG_READY { return; }
    if notch {
        if dy == 0.0f { return; }
        f32 f = IMG_ZOOM_STEP;
        if dy < 0.0f { f = 1.0f / IMG_ZOOM_STEP; }
        image_zoom_at(i, f, x, y);
        return;
    }
    image_pan(i, dx, dy);
}

// --- dragging -------------------------------------------------------------------

private i32 img_drag = -1;
private i32 img_drag_x = 0;
private i32 img_drag_y = 0;

void image_drag_begin(i32 i, i32 x, i32 y) {
    img_drag = i;
    img_drag_x = x;
    img_drag_y = y;
}

bool image_dragging() { return img_drag >= 0; }

void image_drag_to(i32 x, i32 y) {
    if img_drag < 0 { return; }
    image_pan(img_drag, cast(f32, x - img_drag_x), cast(f32, y - img_drag_y));
    img_drag_x = x;
    img_drag_y = y;
}

void image_drag_end() { img_drag = -1; }

// --- the status bar ---------------------------------------------------------------

// "1920 x 1080  2.4 MB  42%", or the state while there is no picture
str image_status(i32 i, u8* buf) {
    if i < 0 || i >= IMG_MAX || !img_tab[i].used { return ""; }
    ImgEntry* e = &img_tab[i];
    if e.state == IMG_LOADING { return "loading"; }
    if e.state == IMG_FAILED { return "cannot show this image"; }
    i32 n = fmt_i32(buf, e.w);
    str x = " x ";
    memcpy(buf + n, x.data, x.len);
    n += x.len;
    n += fmt_i32(buf + n, e.h);
    buf[n] = ' ';
    buf[n + 1] = ' ';
    n += 2;
    // the size in the largest unit that keeps a digit before the point
    i64 b = e.bytes;
    if b >= 1048576 {
        n += fmt_i32(buf + n, cast(i32, b / 1048576));
        buf[n] = '.';
        n++;
        n += fmt_i32(buf + n, cast(i32, (b % 1048576) * 10 / 1048576));
        str mb = " MB";
        memcpy(buf + n, mb.data, mb.len);
        n += mb.len;
    } else if b >= 1024 {
        n += fmt_i32(buf + n, cast(i32, (b + 512) / 1024));
        str kb = " KB";
        memcpy(buf + n, kb.data, kb.len);
        n += kb.len;
    } else {
        n += fmt_i32(buf + n, cast(i32, b));
        str by = " bytes";
        memcpy(buf + n, by.data, by.len);
        n += by.len;
    }
    buf[n] = ' ';
    buf[n + 1] = ' ';
    n += 2;
    f32 s = e.vscale;
    if !e.fit { s = e.zoom; }
    i32 pct = cast(i32, s * 100.0f + 0.5f);
    if pct < 1 { pct = 1; }
    n += fmt_i32(buf + n, pct);
    buf[n] = '%';
    n++;
    if e.fit {
        str f = " (fit)";
        memcpy(buf + n, f.data, f.len);
        n += f.len;
    }
    return str_from(buf, n);
}
