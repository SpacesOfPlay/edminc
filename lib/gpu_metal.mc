// gpu_metal.mc - macOS gpu backend: one Metal device, a CAMetalLayer
// per window, one pipeline, one draw call per frame. displaySyncEnabled with
// maximumDrawableCount 2 makes nextDrawable block until a drawable
// frees, which caps the queue at one frame. Two vertex buffers
// alternate so the frame being encoded never writes the buffer the
// previous frame's GPU work still reads.

import str;
import objc_runtime;
import ext_macos;

// Text blending, same math as the D3D11 backend (see gpu_d3d11.mc):
// TEXT_CONTRAST steepens edge coverage, then the blend result is
// computed in gamma space against the known background color and
// converted back to an effective per-channel coverage for the
// fixed-function dual-source blend (source1Color carries it). The
// effective coverage is per channel even for grayscale input, so
// dual-source is required here too. TEXT_GAMMA is 1.0 here: native
// macOS text blends coverage directly in sRGB space and lets stem
// darkening (which this raster gets, measured) carry the weight, and
// 1.55 is the DirectWrite emulation Windows needs. At 1.0 the gamma math is an
// identity, kept in this shape so the knob and the HLSL stay
// aligned. TEXT_CONTRAST is 0.25, half of what the other backends
// take: the darkened raster arrives with most of that weight already
// in it and needs correspondingly less edge steepening.
// A color glyph (color emoji) is signalled by a fully clear vertex
// color (col.a == 0, which no real draw uses): its atlas cell is
// straight RGBA, so the shader outputs the cell's rgb and its alpha as
// the coverage, and the same dual-source blend composites it over,
// skipping the coverage/gamma math. Same branch as the HLSL.
private u8* MTL_SHADER_SRC = "#include <metal_stdlib>\nusing namespace metal;\nconstant float TEXT_CONTRAST = 0.25;\nconstant float TEXT_GAMMA = 1.0;\nstruct VIn { packed_float2 pos; packed_float2 uv; uchar4 col; };\nstruct VOut { float4 pos [[position]]; float2 uv; float4 col; };\nstruct PSOut { float4 col [[color(0), index(0)]]; float4 cov [[color(0), index(1)]]; };\nvertex VOut vsmain(uint vid [[vertex_id]], const device VIn* verts [[buffer(0)]], constant float2& screen [[buffer(1)]]) {\n    VIn v = verts[vid];\n    VOut o;\n    o.pos = float4(float(v.pos[0]) * 2.0 / screen.x - 1.0, 1.0 - float(v.pos[1]) * 2.0 / screen.y, 0.0, 1.0);\n    o.uv = float2(v.uv);\n    o.col = float4(v.col) / 255.0;\n    return o;\n}\nfragment PSOut psmain(VOut i [[stage_in]], texture2d<float> tex [[texture(0)]], constant float4& bgcol [[buffer(0)]]) {\n    constexpr sampler smp(coord::normalized, filter::nearest);\n    if (bgcol.w > 0.5) {\n        constexpr sampler ls(coord::normalized, filter::linear, mip_filter::linear);\n        constexpr sampler bs(coord::normalized, mag_filter::nearest, min_filter::linear, mip_filter::linear);\n        float2 ui = float2(i.uv.x < 0.0 ? -i.uv.x - 1.0 : i.uv.x, i.uv.y);\n        float4 ti = bgcol.w > 1.5 ? tex.sample(bs, ui) : tex.sample(ls, ui);\n        float ai = ti.a * i.col.a;\n        PSOut oi;\n        oi.col = float4(ti.rgb, 1.0);\n        oi.cov = float4(ai, ai, ai, 1.0);\n        return oi;\n    }\n    bool sc = i.uv.x < 0.0;\n    float2 uv = float2(sc ? -i.uv.x - 1.0 : i.uv.x, i.uv.y);\n    float2 fw = fwidth(uv);\n    float4 t = tex.sample(smp, uv, level(0));\n    if (sc) {\n        t = float4(0.0);\n        for (int k = 0; k < 9; k++) { t += tex.sample(smp, uv + float2(float(k % 3) - 1.0, float(k / 3) - 1.0) * fw * 0.33, level(0)); }\n        t = t / 9.0;\n    }\n    PSOut o;\n    if (i.col.a == 0.0) { o.col = float4(t.rgb, 1.0); o.cov = float4(t.a, t.a, t.a, 1.0); return o; }\n    float3 a = t.rgb;\n    a = a + TEXT_CONTRAST * a * (1.0 - a);\n    float3 og = pow(pow(i.col.rgb, TEXT_GAMMA) * a + pow(bgcol.rgb, TEXT_GAMMA) * (1.0 - a), 1.0 / TEXT_GAMMA);\n    float3 dn = i.col.rgb - bgcol.rgb;\n    float3 sg = step(0.0, dn) * 2.0 - 1.0;\n    float3 aeff = saturate((og - bgcol.rgb) / (sg * max(abs(dn), 0.004)));\n    aeff = max(aeff, step(1.0, a));\n    o.col = float4(i.col.rgb, 1.0);\n    o.cov = float4(aeff * i.col.a, 1.0);\n    return o;\n}\n";

private struct MTLRegion {
    u64 x;
    u64 y;
    u64 z;
    u64 w;
    u64 h;
    u64 d;
}

private struct MTLClearColorMC {
    f64 red;
    f64 green;
    f64 blue;
    f64 alpha;
}

private void* mtl_device = null;
private void* mtl_queue = null;
private void* mtl_pso = null;
private void* mtl_atlas = null;
private const i32 GPU_IMAGE_MAX = 64;
private void*[GPU_IMAGE_MAX] mtl_images;   // null: a free slot
private void*[2] mtl_vbuf;
private i32 mtl_cur = 0;

// One layer per window; the device, queue, pipeline, vertex buffers and
// atlas are shared. gpu_bound selects the surface the frame path
// targets, the way the D3D11 backend binds a swapchain.
private const i32 GPU_WIN_MAX = 8;
private struct GpuSurf {
    void* layer;
    i32 w;
    i32 h;
    bool sync_present;   // presentsWithTransaction, on during a live resize
    bool used;
    void* pending;       // a drawable fetched ahead (gpu_fetch_drawable), retained
}
private GpuSurf[GPU_WIN_MAX] gpu_surf;
private i32 gpu_bound = 0;

// --shot: re-render the current batch to an offscreen texture and
// write it as a PPM, for automated pixel validation
private bool shot_on = false;
private u8[1024] shot_path;
private i32 shot_path_len = 0;

void gpu_request_shot(str p) {
    if p.len > 1023 { return; }
    memcpy(&shot_path[0], p.data, p.len);
    shot_path_len = p.len;
    shot_on = true;
}

private void gpu_do_shot() {
    GpuSurf* s = &gpu_surf[gpu_bound];
    void* td = cast(fn(void*, void*, u64, u64, u64, bool): void*, objc.raw)(
        objc_classref("MTLTextureDescriptor", "/System/Library/Frameworks/Metal.framework/Metal"),
        objc_selref("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
        cast(u64, MTLPixelFormatBGRA8Unorm), cast(u64, s.w), cast(u64, s.h), false);
    cast(fn(void*, void*, u64): void, objc.raw)(td, objc_selref("setUsage:"), 5);        // render target + read
    cast(fn(void*, void*, u64): void, objc.raw)(td, objc_selref("setStorageMode:"), 0);  // shared
    void* tex = objc.msg_id_i(mtl_device, objc_selref("newTextureWithDescriptor:"), td);
    if tex == null { return; }
    void* pass = objc.msg_id_v(objc_classref("MTLRenderPassDescriptor", "/System/Library/Frameworks/Metal.framework/Metal"), objc_selref("renderPassDescriptor"));
    void* att = objc.msg_id_q(objc.msg_id_v(pass, objc_selref("colorAttachments")), objc_selref("objectAtIndexedSubscript:"), 0);
    objc.msg_void_i(att, objc_selref("setTexture:"), tex);
    cast(fn(void*, void*, u64): void, objc.raw)(att, objc_selref("setLoadAction:"), cast(u64, MTLLoadActionClear));
    cast(fn(void*, void*, u64): void, objc.raw)(att, objc_selref("setStoreAction:"), cast(u64, MTLStoreActionStore));
    cast(fn(void*, void*, MTLClearColorMC): void, objc.raw)(att, objc_selref("setClearColor:"),
        MTLClearColorMC{ cast(f64, shot_bg[0]), cast(f64, shot_bg[1]), cast(f64, shot_bg[2]), 1.0 });
    void* cb = objc.msg_id_v(mtl_queue, objc_selref("commandBuffer"));
    void* enc = objc.msg_id_i(cb, objc_selref("renderCommandEncoderWithDescriptor:"), pass);
    objc.msg_void_i(enc, objc_selref("setRenderPipelineState:"), mtl_pso);
    cast(fn(void*, void*, void*, u64, u64): void, objc.raw)(enc, objc_selref("setVertexBuffer:offset:atIndex:"), mtl_vbuf[mtl_cur], 0, 0);
    f32[2] screen = { cast(f32, s.w), cast(f32, s.h) };
    cast(fn(void*, void*, void*, u64, u64): void, objc.raw)(enc, objc_selref("setVertexBytes:length:atIndex:"), cast(void*, &screen[0]), 8, 1);
    mtl_draw_runs(enc, shot_bg[0], shot_bg[1], shot_bg[2]);
    objc.msg_void_v(enc, objc_selref("endEncoding"));
    objc.msg_void_v(cb, objc_selref("commit"));
    objc.msg_void_v(cb, objc_selref("waitUntilCompleted"));

    i64 n = cast(i64, s.w) * cast(i64, s.h);
    u8* px = alloc<u8>(n * 4);
    MTLRegion r = MTLRegion{ 0, 0, 0, cast(u64, s.w), cast(u64, s.h), 1 };
    cast(fn(void*, void*, void*, u64, MTLRegion, u64): void, objc.raw)(tex,
        objc_selref("getBytes:bytesPerRow:fromRegion:mipmapLevel:"),
        cast(void*, px), cast(u64, s.w * 4), r, 0);
    mac_release(tex);
    // PPM P6, BGRA -> RGB
    u8* out = alloc<u8>(n * 3 + 64);
    i32 hn = ppm_header(out, s.w, s.h);
    for i64 i = 0; i < n; i++ {
        out[hn + i * 3] = px[i * 4 + 2];
        out[hn + i * 3 + 1] = px[i * 4 + 1];
        out[hn + i * 3 + 2] = px[i * 4];
    }
    FileData fd;
    fd.data = out;
    fd.len = cast(i32, hn + n * 3);
    ignore file_write(str_from(&shot_path[0], shot_path_len), fd);
    free(out);
    free(px);
}

private f32[3] shot_bg;

// Each run with its texture: the atlas, or an image, which the shader
// draws as it is (the fourth background component says which).
private void mtl_draw_runs(void* enc, f32 bg_r, f32 bg_g, f32 bg_b) {
    for i32 r = 0; r < draw_nruns; r++ {
        i32 first = draw_run_first[r];
        i32 end = draw_nverts;
        if r + 1 < draw_nruns { end = draw_run_first[r + 1]; }
        if end <= first { continue; }
        i32 t = draw_run_tex[r];
        void* tex = mtl_atlas;
        f32 kind = 0.0f;
        if t >= 0 {
            if t >= GPU_IMAGE_MAX || mtl_images[t] == null { continue; }
            tex = mtl_images[t];
            kind = 1.0f;
            if (draw_run_flags[r] & DRAW_RUN_NEAREST) != 0 { kind = 2.0f; }
        }
        f32[4] bg = { bg_r, bg_g, bg_b, kind };
        cast(fn(void*, void*, void*, u64, u64): void, objc.raw)(enc, objc_selref("setFragmentBytes:length:atIndex:"), cast(void*, &bg[0]), 16, 0);
        cast(fn(void*, void*, void*, u64): void, objc.raw)(enc, objc_selref("setFragmentTexture:atIndex:"), tex, 0);
        cast(fn(void*, void*, u64, u64, u64): void, objc.raw)(enc, objc_selref("drawPrimitives:vertexStart:vertexCount:"),
            cast(u64, MTLPrimitiveTypeTriangle), cast(u64, first), cast(u64, end - first));
    }
}

// An image as a texture of its own: straight RGBA8, w by h, its mip
// levels made by a blit on the queue. The handle, or -1.
i32 gpu_image_create(u8* rgba, i32 w, i32 h) {
    if mtl_device == null || w <= 0 || h <= 0 { return -1; }
    i32 slot = -1;
    for i32 i = 0; i < GPU_IMAGE_MAX; i++ {
        if mtl_images[i] == null {
            slot = i;
            break;
        }
    }
    if slot < 0 { return -1; }
    void* td = cast(fn(void*, void*, u64, u64, u64, bool): void*, objc.raw)(
        objc_classref("MTLTextureDescriptor", "/System/Library/Frameworks/Metal.framework/Metal"),
        objc_selref("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
        cast(u64, MTLPixelFormatRGBA8Unorm), cast(u64, w), cast(u64, h), true);
    void* tex = objc.msg_id_i(mtl_device, objc_selref("newTextureWithDescriptor:"), td);
    if tex == null { return -1; }
    MTLRegion rg = MTLRegion{ 0, 0, 0, cast(u64, w), cast(u64, h), 1 };
    cast(fn(void*, void*, MTLRegion, u64, void*, u64): void, objc.raw)(tex,
        objc_selref("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
        rg, 0, cast(void*, rgba), cast(u64, w * 4));
    void* cb = objc.msg_id_v(mtl_queue, objc_selref("commandBuffer"));
    void* blit = objc.msg_id_v(cb, objc_selref("blitCommandEncoder"));
    objc.msg_void_i(blit, objc_selref("generateMipmapsForTexture:"), tex);
    objc.msg_void_v(blit, objc_selref("endEncoding"));
    objc.msg_void_v(cb, objc_selref("commit"));
    mtl_images[slot] = tex;
    return slot;
}

void gpu_image_free(i32 h) {
    if h < 0 || h >= GPU_IMAGE_MAX || mtl_images[h] == null { return; }
    mac_release(mtl_images[h]);
    mtl_images[h] = null;
}

// a window's layer into a free slot, configured for this device;
// returns its index, -1 when the table is full
private i32 gpu_surf_new(void* layer, i32 w, i32 h) {
    i32 id = -1;
    for i32 i = 0; i < GPU_WIN_MAX; i++ {
        if !gpu_surf[i].used { id = i; break; }
    }
    if id < 0 || layer == null { return -1; }
    objc.msg_void_i(layer, objc_selref("setDevice:"), mtl_device);
    cast(fn(void*, void*, u64): void, objc.raw)(layer, objc_selref("setPixelFormat:"), cast(u64, MTLPixelFormatBGRA8Unorm));
    objc.msg_void_b(layer, objc_selref("setFramebufferOnly:"), true);
    objc.msg_void_b(layer, objc_selref("setDisplaySyncEnabled:"), true);
    cast(fn(void*, void*, u64): void, objc.raw)(layer, objc_selref("setMaximumDrawableCount:"), 2);
    cast(fn(void*, void*, CGSize): void, objc.raw)(layer, objc_selref("setDrawableSize:"), CGSize{ cast(f64, w), cast(f64, h) });
    gpu_surf[id].layer = layer;
    gpu_surf[id].w = w;
    gpu_surf[id].h = h;
    gpu_surf[id].sync_present = false;
    gpu_surf[id].used = true;
    return id;
}

// a surface for another window's layer; the driver pairs it with the
// window (gpu_win_create/bind/resize/destroy mirror the D3D11 names)
i32 gpu_win_create(void* layer, i32 w, i32 h) {
    return gpu_surf_new(layer, w, h);
}

// select the surface the frame path targets
void gpu_bind(i32 id) {
    if id >= 0 && id < GPU_WIN_MAX && gpu_surf[id].used { gpu_bound = id; }
}

// drop the slot; the view owns the layer and releases it
void gpu_win_destroy(i32 id) {
    if id < 0 || id >= GPU_WIN_MAX || !gpu_surf[id].used { return; }
    gpu_pending_drop(id);
    gpu_surf[id].layer = null;
    gpu_surf[id].used = false;
    if gpu_bound == id { gpu_bound = 0; }
}

bool gpu_init(void* layer, i32 w, i32 h) {
    mtl_device = MTLCreateSystemDefaultDevice();
    if mtl_device == null {
        print("MTLCreateSystemDefaultDevice failed\n");
        return false;
    }
    mtl_queue = objc.msg_id_v(mtl_device, objc_selref("newCommandQueue"));
    if gpu_surf_new(layer, w, h) != 0 {
        print("primary surface failed\n");
        return false;
    }
    gpu_bound = 0;

    // MSL compiled at init.
    void* src = mac_nsstring(MTL_SHADER_SRC, mtl_cstrlen(MTL_SHADER_SRC));
    void* err = null;
    void* lib = cast(fn(void*, void*, void*, void*, void**): void*, objc.raw)(mtl_device, objc_selref("newLibraryWithSource:options:error:"), src, null, &err);
    mac_release(src);
    if lib == null {
        mtl_print_nserror("newLibraryWithSource failed", err);
        return false;
    }
    void* vsn = mac_nsstring("vsmain", 6);
    void* fsn = mac_nsstring("psmain", 6);
    void* vs = objc.msg_id_i(lib, objc_selref("newFunctionWithName:"), vsn);
    void* fs = objc.msg_id_i(lib, objc_selref("newFunctionWithName:"), fsn);
    mac_release(vsn);
    mac_release(fsn);
    if vs == null || fs == null {
        print("metal shader entry points missing\n");
        return false;
    }

    void* pd = objc.msg_id_v(objc.msg_id_v(objc_classref("MTLRenderPipelineDescriptor", "/System/Library/Frameworks/Metal.framework/Metal"), objc_selref("alloc")), objc_selref("init"));
    objc.msg_void_i(pd, objc_selref("setVertexFunction:"), vs);
    objc.msg_void_i(pd, objc_selref("setFragmentFunction:"), fs);
    void* att = objc.msg_id_q(objc.msg_id_v(pd, objc_selref("colorAttachments")), objc_selref("objectAtIndexedSubscript:"), 0);
    cast(fn(void*, void*, u64): void, objc.raw)(att, objc_selref("setPixelFormat:"), cast(u64, MTLPixelFormatBGRA8Unorm));
    objc.msg_void_b(att, objc_selref("setBlendingEnabled:"), true);
    cast(fn(void*, void*, u64): void, objc.raw)(att, objc_selref("setSourceRGBBlendFactor:"), cast(u64, MTLBlendFactorSource1Color));
    cast(fn(void*, void*, u64): void, objc.raw)(att, objc_selref("setDestinationRGBBlendFactor:"), cast(u64, MTLBlendFactorOneMinusSource1Color));
    cast(fn(void*, void*, u64): void, objc.raw)(att, objc_selref("setSourceAlphaBlendFactor:"), cast(u64, MTLBlendFactorOne));
    cast(fn(void*, void*, u64): void, objc.raw)(att, objc_selref("setDestinationAlphaBlendFactor:"), cast(u64, MTLBlendFactorZero));
    err = null;
    mtl_pso = cast(fn(void*, void*, void*, void**): void*, objc.raw)(mtl_device, objc_selref("newRenderPipelineStateWithDescriptor:error:"), pd, &err);
    mac_release(pd);
    mac_release(vs);
    mac_release(fs);
    mac_release(lib);
    if mtl_pso == null {
        mtl_print_nserror("newRenderPipelineState failed", err);
        return false;
    }

    for i32 i = 0; i < 2; i++ {
        mtl_vbuf[i] = objc.msg_id_qq(mtl_device, objc_selref("newBufferWithLength:options:"),
            cast(u64, DRAW_MAX_VERTS * sizeof(DrawVtx)), MTLResourceStorageModeShared);
        if mtl_vbuf[i] == null {
            print("newBufferWithLength failed\n");
            return false;
        }
    }

    // Glyph atlas: RGBA8 as the contract delivers it; the shader
    // samples the red channel (grayscale coverage has r=g=b).
    void* td = cast(fn(void*, void*, u64, u64, u64, bool): void*, objc.raw)(
        objc_classref("MTLTextureDescriptor", "/System/Library/Frameworks/Metal.framework/Metal"),
        objc_selref("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
        cast(u64, MTLPixelFormatRGBA8Unorm), cast(u64, ATLAS_W), cast(u64, ATLAS_H), false);
    mtl_atlas = objc.msg_id_i(mtl_device, objc_selref("newTextureWithDescriptor:"), td);
    if mtl_atlas == null {
        print("newTextureWithDescriptor failed\n");
        return false;
    }
    return true;
}

// Live resize: presenting inside the CA transaction keeps the
// drawable and the layer bounds committing together, so the old
// frame is never scaled to the new size. Costs a main-thread wait
// until the command buffer is scheduled, so only while resizing.
void mtl_present_sync(bool on) {
    GpuSurf* s = &gpu_surf[gpu_bound];
    if s.layer == null { return; }
    s.sync_present = on;
    objc.msg_void_b(s.layer, objc_selref("setPresentsWithTransaction:"), on);
}

void gpu_resize(i32 w, i32 h) {
    GpuSurf* s = &gpu_surf[gpu_bound];
    if s.layer == null || w <= 0 || h <= 0 { return; }
    if w == s.w && h == s.h { return; }
    s.w = w;
    s.h = h;
    cast(fn(void*, void*, CGSize): void, objc.raw)(s.layer, objc_selref("setDrawableSize:"), CGSize{ cast(f64, w), cast(f64, h) });
}

void gpu_upload_atlas(u8* pixels) {
    MTLRegion r = MTLRegion{ 0, 0, 0, cast(u64, ATLAS_W), cast(u64, ATLAS_H), 1 };
    cast(fn(void*, void*, MTLRegion, u64, void*, u64): void, objc.raw)(mtl_atlas,
        objc_selref("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
        r, 0, cast(void*, pixels), cast(u64, ATLAS_W * 4));
}

// how long the last frame waited for its drawable, for the frame log
i64 mtl_drawable_wait_us = 0;

// A drawable fetched ahead of the frame, off the main thread: with
// display sync on the layer vends one per refresh and nextDrawable
// waits for it, so the driver's fetch thread takes that wait and the
// frame build finds the drawable here. Retained by the fetch, released
// after the present or by a drop.
void* gpu_fetch_drawable(i32 gpu) {
    if gpu < 0 || gpu >= GPU_WIN_MAX || gpu_surf[gpu].layer == null { return null; }
    void* d = objc.msg_id_v(gpu_surf[gpu].layer, objc_selref("nextDrawable"));
    if d != null { ignore objc.msg_id_v(d, objc_selref("retain")); }
    return d;
}

void gpu_pending_set(i32 gpu, void* d) {
    if gpu < 0 || gpu >= GPU_WIN_MAX { return; }
    gpu_pending_drop(gpu);
    gpu_surf[gpu].pending = d;
}

// the fetched drawable goes back to the pool unpresented
void gpu_pending_drop(i32 gpu) {
    if gpu < 0 || gpu >= GPU_WIN_MAX || gpu_surf[gpu].pending == null { return; }
    objc.msg_void_v(gpu_surf[gpu].pending, objc_selref("release"));
    gpu_surf[gpu].pending = null;
}

void gpu_frame_end(f32 bg_r, f32 bg_g, f32 bg_b) {
    GpuSurf* s = &gpu_surf[gpu_bound];
    if s.layer == null { return; }
    // The drawable fetched ahead, else this frame's own: nextDrawable
    // blocks until the layer vends one, the one-frame pacing.
    bool owned = s.pending != null;
    void* drawable = s.pending;
    s.pending = null;
    mtl_drawable_wait_us = 0;
    if drawable == null {
        i64 tw = plat_time_us();
        drawable = objc.msg_id_v(s.layer, objc_selref("nextDrawable"));
        mtl_drawable_wait_us = plat_time_us() - tw;
    }
    if drawable == null { return; }

    // Safe to write this buffer: the frame that last used it has
    // fully retired for its drawable to have been recycled.
    mtl_cur = 1 - mtl_cur;
    void* vbuf = mtl_vbuf[mtl_cur];
    if draw_nverts > 0 {
        memcpy(objc.msg_id_v(vbuf, objc_selref("contents")), draw_verts, draw_nverts * sizeof(DrawVtx));
    }

    void* pass = objc.msg_id_v(objc_classref("MTLRenderPassDescriptor", "/System/Library/Frameworks/Metal.framework/Metal"), objc_selref("renderPassDescriptor"));
    void* att = objc.msg_id_q(objc.msg_id_v(pass, objc_selref("colorAttachments")), objc_selref("objectAtIndexedSubscript:"), 0);
    objc.msg_void_i(att, objc_selref("setTexture:"), objc.msg_id_v(drawable, objc_selref("texture")));
    cast(fn(void*, void*, u64): void, objc.raw)(att, objc_selref("setLoadAction:"), cast(u64, MTLLoadActionClear));
    cast(fn(void*, void*, u64): void, objc.raw)(att, objc_selref("setStoreAction:"), cast(u64, MTLStoreActionStore));
    cast(fn(void*, void*, MTLClearColorMC): void, objc.raw)(att, objc_selref("setClearColor:"),
        MTLClearColorMC{ cast(f64, bg_r), cast(f64, bg_g), cast(f64, bg_b), 1.0 });

    void* cb = objc.msg_id_v(mtl_queue, objc_selref("commandBuffer"));
    void* enc = objc.msg_id_i(cb, objc_selref("renderCommandEncoderWithDescriptor:"), pass);
    objc.msg_void_i(enc, objc_selref("setRenderPipelineState:"), mtl_pso);
    cast(fn(void*, void*, void*, u64, u64): void, objc.raw)(enc, objc_selref("setVertexBuffer:offset:atIndex:"), vbuf, 0, 0);
    f32[2] screen = { cast(f32, s.w), cast(f32, s.h) };
    cast(fn(void*, void*, void*, u64, u64): void, objc.raw)(enc, objc_selref("setVertexBytes:length:atIndex:"), cast(void*, &screen[0]), 8, 1);
    mtl_draw_runs(enc, bg_r, bg_g, bg_b);
    objc.msg_void_v(enc, objc_selref("endEncoding"));
    if shot_on {
        shot_on = false;
        shot_bg[0] = bg_r;
        shot_bg[1] = bg_g;
        shot_bg[2] = bg_b;
        gpu_do_shot();
    }
    if s.sync_present {
        objc.msg_void_v(cb, objc_selref("commit"));
        objc.msg_void_v(cb, objc_selref("waitUntilScheduled"));
        objc.msg_void_v(drawable, objc_selref("present"));
    } else {
        objc.msg_void_i(cb, objc_selref("presentDrawable:"), drawable);
        objc.msg_void_v(cb, objc_selref("commit"));
    }
    if owned { objc.msg_void_v(drawable, objc_selref("release")); }
}

private i64 mtl_cstrlen(u8* s) {
    i64 n = 0;
    while s[n] != 0 { n++; }
    return n;
}

private void mtl_print_nserror(str what, void* err) {
    if err == null {
        print("{}\n", what);
        return;
    }
    u8* msg = cast(u8*, objc.msg_id_v(objc.msg_id_v(err, objc_selref("localizedDescription")), objc_selref("UTF8String")));
    if msg == null {
        print("{}\n", what);
        return;
    }
    print("{}: {}\n", what, str_from_cstr(msg));
}
