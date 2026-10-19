// gpu_gl.mc - Linux gpu backend: a GLX 3.3 core context, one program,
// one streamed vertex buffer, one draw call per frame. glFinish after
// the swap caps the queue at one frame, the same property the
// flip-model swapchain and CAMetalLayer provide on the other
// platforms.

import ext_gl;

// Entry points the toolchain's ext_gl does not declare.
private extern "libGL.so.1" {
    void glBlendFunc(u32 src, u32 dst);
    void glReadPixels(i32 x, i32 y, i32 w, i32 h, u32 format, u32 type, void* pixels);
    void glFinish();
    void glGenerateMipmap(u32 target);
}

// ext_gl declares these only in its macOS arm.
private const u32 GL_SRC1_COLOR = 35065;
private const u32 GL_ONE_MINUS_SRC1_COLOR = 35066;

private type PFNSwapIntervalEXT = fn(Display*, GLXDrawable, i32): void;
private type PFNCreateContextAttribsARB = fn(Display*, GLXFBConfig, GLXContext, i32, i32*): GLXContext;

// Text blending, same math as the D3D11 and Metal backends (see
// gpu_d3d11.mc): TEXT_CONTRAST steepens edge coverage, then the
// blend result is computed in gamma space against the known
// background color and converted back to an effective per-channel
// coverage for the fixed-function dual-source blend. The effective
// coverage is per channel even for grayscale input, so the second
// fragment output is required here too; GLSL 330's index= layout
// qualifier supplies it without glBindFragDataLocationIndexed.
// TEXT_GAMMA is 2.2, unlike the other two: the vendored rasterizer
// hands over raw geometric coverage, with neither hinting nor stem
// darkening, so the blend is done in linear light. That is both the
// physically right operation and the weight CoreText and DirectWrite
// bake into their coverage before this stage ever sees it.
private u8* GL_VS_SRC =
    "#version 330 core\n"
    "layout(location = 0) in vec2 a_pos;\n"
    "layout(location = 1) in vec2 a_uv;\n"
    "layout(location = 2) in vec4 a_col;\n"
    "uniform vec2 u_screen;\n"
    "uniform vec2 u_shift;\n"
    "out vec2 v_uv;\n"
    "out vec4 v_col;\n"
    "void main() {\n"
    "    gl_Position = vec4(a_pos.x * 2.0 / u_screen.x - 1.0,\n"
    "                       1.0 - (a_pos.y + u_shift.y) * 2.0 / u_screen.y, 0.0, 1.0);\n"
    "    v_uv = a_uv;\n"
    "    v_col = a_col;\n"
    "}\n";

private u8* GL_FS_SRC =
    "#version 330 core\n"
    "const float TEXT_CONTRAST = 0.5;\n"
    "const float TEXT_GAMMA = 2.2;\n"
    "in vec2 v_uv;\n"
    "in vec4 v_col;\n"
    "uniform sampler2D u_tex;\n"
    "uniform vec3 u_bg;\n"
    "uniform int u_img;\n"
    "layout(location = 0, index = 0) out vec4 o_col;\n"
    "layout(location = 0, index = 1) out vec4 o_cov;\n"
    "void main() {\n"
    // an image: its texels as they are, through its mip levels
    "    if (u_img != 0) {\n"
    "        vec4 ti = texture(u_tex, vec2(v_uv.x < 0.0 ? -v_uv.x - 1.0 : v_uv.x, v_uv.y));\n"
    "        float ai = ti.a * v_col.a;\n"
    "        o_col = vec4(ti.rgb, 1.0);\n"
    "        o_cov = vec4(ai, ai, ai, 1.0);\n"
    "        return;\n"
    "    }\n"
    // a marked u (below 0): a glyph drawn scaled, averaged over the pixel
    "    bool sc = v_uv.x < 0.0;\n"
    "    vec2 uv = vec2(sc ? -v_uv.x - 1.0 : v_uv.x, v_uv.y);\n"
    "    vec2 fw = fwidth(uv);\n"
    "    vec4 t = textureLod(u_tex, uv, 0.0);\n"
    "    if (sc) {\n"
    "        t = vec4(0.0);\n"
    "        for (int k = 0; k < 9; k++) { t += textureLod(u_tex, uv + vec2(float(k % 3) - 1.0, float(k / 3) - 1.0) * fw * 0.33, 0.0); }\n"
    "        t = t / 9.0;\n"
    "    }\n"
    "    if (v_col.a == 0.0) {\n"           // color glyph: straight RGBA, composited by the dual-source blend
    "        o_col = vec4(t.rgb, 1.0);\n"
    "        o_cov = vec4(t.a, t.a, t.a, 1.0);\n"
    "        return;\n"
    "    }\n"
    "    vec3 a = t.rgb;\n"
    "    a = a + TEXT_CONTRAST * a * (1.0 - a);\n"
    "    vec3 og = pow(pow(v_col.rgb, vec3(TEXT_GAMMA)) * a\n"
    "                + pow(u_bg, vec3(TEXT_GAMMA)) * (1.0 - a), vec3(1.0 / TEXT_GAMMA));\n"
    "    vec3 dn = v_col.rgb - u_bg;\n"
    "    vec3 sg = step(vec3(0.0), dn) * 2.0 - 1.0;\n"
    "    vec3 aeff = clamp((og - u_bg) / (sg * max(abs(dn), vec3(0.004))), 0.0, 1.0);\n"
    "    aeff = max(aeff, step(1.0, a));\n"
    "    o_col = vec4(v_col.rgb, 1.0);\n"
    "    o_cov = vec4(aeff * v_col.a, 1.0);\n"
    "}\n";

private GLXFBConfig gl_fbc = null;
private GLXContext gl_ctx = null;
private GLXDrawable gl_drawable = 0;
private u32 gl_prog = 0;
private u32 gl_vao = 0;
private u32 gl_vbo = 0;
private u32 gl_atlas = 0;
private i32 gl_u_screen = -1;
private i32 gl_u_shift = -1;
private i32 gl_u_bg = -1;
private i32 gl_u_tex = -1;
private i32 gl_u_img = -1;
private const i32 GPU_IMAGE_MAX = 64;
private u32[GPU_IMAGE_MAX] gl_images;   // 0: a free slot
private i64 gl_vbo_cap = 0;
private i32 gpu_width = 0;
private i32 gpu_height = 0;

// --shot: read the frame back and write it as a PPM, for automated
// pixel validation.
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
    i64 n = cast(i64, gpu_width) * cast(i64, gpu_height);
    if n <= 0 { return; }
    u8* px = alloc<u8>(n * 3);
    glReadPixels(0, 0, gpu_width, gpu_height, GL_RGB, GL_UNSIGNED_BYTE, cast(void*, px));
    u8* out = alloc<u8>(n * 3 + 64);
    i32 hn = ppm_header(out, gpu_width, gpu_height);
    // glReadPixels returns bottom-up rows; the PPM is top-down
    for i32 y = 0; y < gpu_height; y++ {
        u8* src = px + cast(i64, gpu_height - 1 - y) * cast(i64, gpu_width) * 3;
        memcpy(out + hn + cast(i64, y) * cast(i64, gpu_width) * 3, src, gpu_width * 3);
    }
    FileData fd;
    fd.data = out;
    fd.len = cast(i32, hn + n * 3);
    ignore file_write(str_from(&shot_path[0], shot_path_len), fd);
    free(out);
    free(px);
}

// The window must carry the fbconfig's visual, so the driver asks for
// it before creating the window.
XVisualInfo* gpu_choose_visual(i32 screen) {
    i32[15] attribs = {
        GLX_X_RENDERABLE, 1,
        GLX_DRAWABLE_TYPE, GLX_WINDOW_BIT,
        GLX_RENDER_TYPE, GLX_RGBA_BIT,
        GLX_RED_SIZE, 8,
        GLX_GREEN_SIZE, 8,
        GLX_BLUE_SIZE, 8,
        GLX_DOUBLEBUFFER, 1,
        0
    };
    i32 nitems = 0;
    GLXFBConfig* cfgs = glXChooseFBConfig(g_dpy, screen, &attribs[0], &nitems);
    if cfgs == null || nitems <= 0 { return null; }
    gl_fbc = cfgs[0];
    XVisualInfo* vi = glXGetVisualFromFBConfig(g_dpy, gl_fbc);
    ignore XFree(cast(void*, cfgs));
    return vi;
}

private u32 gl_compile(u32 kind, u8* src, str what) {
    u32 sh = glCreateShader(kind);
    glShaderSource(sh, 1, &src, null);
    glCompileShader(sh);
    i32 ok = 0;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if ok == 0 {
        noinit u8[2048] log;
        i32 len = 0;
        glGetShaderInfoLog(sh, 2048, &len, &log[0]);
        print("{} shader compile failed: {}\n", what, str_from(&log[0], len));
        return 0;
    }
    return sh;
}

bool gpu_init(Window win, i32 w, i32 h) {
    gpu_width = w;
    gpu_height = h;
    gl_drawable = cast(GLXDrawable, win);

    var create = cast(PFNCreateContextAttribsARB, glXGetProcAddressARB("glXCreateContextAttribsARB"));
    if create == null {
        print("glXCreateContextAttribsARB unavailable\n");
        return false;
    }
    i32[7] ctx_attribs = {
        GLX_CONTEXT_MAJOR_VERSION_ARB, 3,
        GLX_CONTEXT_MINOR_VERSION_ARB, 3,
        GLX_CONTEXT_PROFILE_MASK_ARB, GLX_CONTEXT_CORE_PROFILE_BIT_ARB,
        0
    };
    gl_ctx = create(g_dpy, gl_fbc, null, 1, &ctx_attribs[0]);
    if gl_ctx == null {
        print("GL 3.3 core context creation failed\n");
        return false;
    }
    if glXMakeCurrent(g_dpy, gl_drawable, gl_ctx) == 0 {
        print("glXMakeCurrent failed\n");
        return false;
    }

    // vsync; absent on a compositor that refuses it, which only
    // costs pacing, not correctness
    var swap_interval = cast(PFNSwapIntervalEXT, glXGetProcAddressARB("glXSwapIntervalEXT"));
    if swap_interval != null {
        swap_interval(g_dpy, gl_drawable, 1);
    }

    u32 vs = gl_compile(GL_VERTEX_SHADER, GL_VS_SRC, "vertex");
    u32 fs = gl_compile(GL_FRAGMENT_SHADER, GL_FS_SRC, "fragment");
    if vs == 0 || fs == 0 { return false; }
    gl_prog = glCreateProgram();
    glAttachShader(gl_prog, vs);
    glAttachShader(gl_prog, fs);
    glLinkProgram(gl_prog);
    i32 linked = 0;
    glGetProgramiv(gl_prog, GL_LINK_STATUS, &linked);
    if linked == 0 {
        noinit u8[2048] log;
        i32 len = 0;
        glGetProgramInfoLog(gl_prog, 2048, &len, &log[0]);
        print("program link failed: {}\n", str_from(&log[0], len));
        return false;
    }
    glDeleteShader(vs);
    glDeleteShader(fs);

    gl_u_screen = glGetUniformLocation(gl_prog, "u_screen");
    gl_u_shift = glGetUniformLocation(gl_prog, "u_shift");
    gl_u_bg = glGetUniformLocation(gl_prog, "u_bg");
    gl_u_tex = glGetUniformLocation(gl_prog, "u_tex");
    gl_u_img = glGetUniformLocation(gl_prog, "u_img");

    glGenVertexArrays(1, &gl_vao);
    glBindVertexArray(gl_vao);
    glGenBuffers(1, &gl_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, gl_vbo);
    i32 stride = cast(i32, sizeof(DrawVtx));
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, 0, stride, cast(void*, 0));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, 0, stride, cast(void*, 8));
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(2, 4, GL_UNSIGNED_BYTE, 1, stride, cast(void*, 16));

    glGenTextures(1, &gl_atlas);
    glBindTexture(GL_TEXTURE_2D, gl_atlas);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, cast(i32, GL_NEAREST));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, cast(i32, GL_NEAREST));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, cast(i32, GL_CLAMP_TO_EDGE));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, cast(i32, GL_CLAMP_TO_EDGE));
    glTexImage2D(GL_TEXTURE_2D, 0, cast(i32, GL_RGBA8), ATLAS_W, ATLAS_H, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);

    // dst = o_col * o_cov + dst * (1 - o_cov), per channel
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC1_COLOR, GL_ONE_MINUS_SRC1_COLOR);
    return true;
}

void gpu_resize(i32 w, i32 h) {
    if w <= 0 || h <= 0 { return; }
    gpu_width = w;
    gpu_height = h;
}

// An image as a texture of its own: straight RGBA8, w by h, with its mip
// levels. The handle, or -1 without a context or a free slot.
i32 gpu_image_create(u8* rgba, i32 w, i32 h) {
    if gl_ctx == null || w <= 0 || h <= 0 { return -1; }
    i32 slot = -1;
    for i32 i = 0; i < GPU_IMAGE_MAX; i++ {
        if gl_images[i] == 0 {
            slot = i;
            break;
        }
    }
    if slot < 0 { return -1; }
    u32 t = 0;
    glGenTextures(1, &t);
    glBindTexture(GL_TEXTURE_2D, t);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, cast(i32, GL_LINEAR_MIPMAP_LINEAR));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, cast(i32, GL_LINEAR));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, cast(i32, GL_CLAMP_TO_EDGE));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, cast(i32, GL_CLAMP_TO_EDGE));
    glTexImage2D(GL_TEXTURE_2D, 0, cast(i32, GL_RGBA8), w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, cast(void*, rgba));
    glGenerateMipmap(GL_TEXTURE_2D);
    gl_images[slot] = t;
    return slot;
}

void gpu_image_free(i32 h) {
    if h < 0 || h >= GPU_IMAGE_MAX || gl_images[h] == 0 { return; }
    glDeleteTextures(1, &gl_images[h]);
    gl_images[h] = 0;
}

void gpu_upload_atlas(u8* pixels) {
    if gl_ctx == null { return; }
    glBindTexture(GL_TEXTURE_2D, gl_atlas);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, ATLAS_W, ATLAS_H, GL_RGBA, GL_UNSIGNED_BYTE, cast(void*, pixels));
}

void gpu_frame_end(f32 bg_r, f32 bg_g, f32 bg_b) {
    // headless --smoke builds the batch without a context
    if gl_ctx == null { return; }

    glViewport(0, 0, gpu_width, gpu_height);
    glClearColor(bg_r, bg_g, bg_b, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glUseProgram(gl_prog);
    f32[2] screen = { cast(f32, gpu_width), cast(f32, gpu_height) };
    glUniform2fv(gl_u_screen, 1, &screen[0]);
    f32[2] shift = { 0.0f, cast(f32, g_caption_h) };
    glUniform2fv(gl_u_shift, 1, &shift[0]);
    f32[3] bg = { bg_r, bg_g, bg_b };
    glUniform3fv(gl_u_bg, 1, &bg[0]);
    glUniform1i(gl_u_tex, 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, gl_atlas);

    glBindVertexArray(gl_vao);
    glBindBuffer(GL_ARRAY_BUFFER, gl_vbo);
    if draw_nverts > 0 {
        i64 bytes = cast(i64, draw_nverts) * sizeof(DrawVtx);
        // orphan the old store so the driver never stalls on it
        if bytes > gl_vbo_cap {
            gl_vbo_cap = bytes;
        }
        glBufferData(GL_ARRAY_BUFFER, gl_vbo_cap, null, GL_STREAM_DRAW);
        glBufferSubData(GL_ARRAY_BUFFER, 0, bytes, cast(void*, draw_verts));
        // each run with its texture: the atlas, or an image
        for i32 r = 0; r < draw_nruns; r++ {
            i32 first = draw_run_first[r];
            i32 end = draw_nverts;
            if r + 1 < draw_nruns { end = draw_run_first[r + 1]; }
            if end <= first { continue; }
            i32 t = draw_run_tex[r];
            if t >= 0 {
                if t >= GPU_IMAGE_MAX || gl_images[t] == 0 { continue; }
                glBindTexture(GL_TEXTURE_2D, gl_images[t]);
                i32 mag = cast(i32, GL_LINEAR);
                if (draw_run_flags[r] & DRAW_RUN_NEAREST) != 0 { mag = cast(i32, GL_NEAREST); }
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, mag);
                glUniform1i(gl_u_img, 1);
            } else {
                glBindTexture(GL_TEXTURE_2D, gl_atlas);
                glUniform1i(gl_u_img, 0);
            }
            glDrawArrays(GL_TRIANGLES, first, end - first);
        }
    }

    if shot_on {
        shot_on = false;
        glFinish();
        gpu_do_shot();
    }

    glXSwapBuffers(g_dpy, gl_drawable);
    // caps the queue at one frame; refine against measurement
    glFinish();
}
