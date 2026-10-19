// gpu_webgl.mc - browser gpu backend: WebGL2 through the toolchain's
// GLES3 bindings, one program, one streamed vertex buffer, one draw
// call per frame. The page created the context; presenting is the
// browser's, after the frame callback returns. WebGL2 has no
// dual-source blending, and needs none: the vendored rasterizer
// produces grayscale coverage, so the per-channel effective coverage
// the other backends compute is the same in every channel and plain
// alpha blending is equivalent (see gpu_gl.mc for the math).

// Text blending as in gpu_gl.mc, with the effective coverage written
// to alpha instead of a second output. TEXT_GAMMA 2.2 as on Linux:
// the same vendored rasterizer, the same raw geometric coverage, so
// the blend is done in linear light.
private u8* WGL_VS_SRC =
    "#version 300 es\n"
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

private u8* WGL_FS_SRC =
    "#version 300 es\n"
    "precision highp float;\n"
    "const float TEXT_CONTRAST = 0.5;\n"
    "const float TEXT_GAMMA = 2.2;\n"
    "in vec2 v_uv;\n"
    "in vec4 v_col;\n"
    "uniform sampler2D u_tex;\n"
    "uniform vec3 u_bg;\n"
    "uniform int u_img;\n"
    "layout(location = 0) out vec4 o_col;\n"
    "void main() {\n"
    // an image: its texels as they are, through its mip levels
    "    if (u_img != 0) {\n"
    "        vec4 ti = texture(u_tex, vec2(v_uv.x < 0.0 ? -v_uv.x - 1.0 : v_uv.x, v_uv.y));\n"
    "        o_col = vec4(ti.rgb, ti.a * v_col.a);\n"
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
    "    if (v_col.a == 0.0) { o_col = t; return; }\n"  // color glyph: straight RGBA
    "    vec3 a = t.rgb;\n"
    "    a = a + TEXT_CONTRAST * a * (1.0 - a);\n"
    "    vec3 og = pow(pow(v_col.rgb, vec3(TEXT_GAMMA)) * a\n"
    "                + pow(u_bg, vec3(TEXT_GAMMA)) * (1.0 - a), vec3(1.0 / TEXT_GAMMA));\n"
    "    vec3 dn = v_col.rgb - u_bg;\n"
    "    vec3 sg = step(vec3(0.0), dn) * 2.0 - 1.0;\n"
    "    vec3 aeff = clamp((og - u_bg) / (sg * max(abs(dn), vec3(0.004))), 0.0, 1.0);\n"
    "    aeff = max(aeff, step(1.0, a));\n"
    "    o_col = vec4(v_col.rgb, aeff.r * v_col.a);\n"
    "}\n";

private bool wgl_up = false;
private u32 wgl_prog = 0;
private u32 wgl_vao = 0;
private u32 wgl_vbo = 0;
private u32 wgl_atlas = 0;
private i32 wgl_u_screen = -1;
private i32 wgl_u_shift = -1;
private i32 wgl_u_bg = -1;
private i32 wgl_u_tex = -1;
private i32 wgl_u_img = -1;
private const i32 GPU_IMAGE_MAX = 64;
private u32[GPU_IMAGE_MAX] wgl_images;   // 0: a free slot
private i64 wgl_vbo_cap = 0;
private i32 gpu_width = 0;
private i32 gpu_height = 0;

private u32 wgl_compile(u32 kind, u8* src, str what) {
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

// the handle is the page's context, already current; unused here
bool gpu_init(i32 handle, i32 w, i32 h) {
    gpu_width = w;
    gpu_height = h;

    u32 vs = wgl_compile(GL_VERTEX_SHADER, WGL_VS_SRC, "vertex");
    u32 fs = wgl_compile(GL_FRAGMENT_SHADER, WGL_FS_SRC, "fragment");
    if vs == 0 || fs == 0 { return false; }
    wgl_prog = glCreateProgram();
    glAttachShader(wgl_prog, vs);
    glAttachShader(wgl_prog, fs);
    glLinkProgram(wgl_prog);
    i32 linked = 0;
    glGetProgramiv(wgl_prog, GL_LINK_STATUS, &linked);
    if linked == 0 {
        noinit u8[2048] log;
        i32 len = 0;
        glGetProgramInfoLog(wgl_prog, 2048, &len, &log[0]);
        print("program link failed: {}\n", str_from(&log[0], len));
        return false;
    }
    glDeleteShader(vs);
    glDeleteShader(fs);

    wgl_u_screen = glGetUniformLocation(wgl_prog, "u_screen");
    wgl_u_shift = glGetUniformLocation(wgl_prog, "u_shift");
    wgl_u_bg = glGetUniformLocation(wgl_prog, "u_bg");
    wgl_u_tex = glGetUniformLocation(wgl_prog, "u_tex");
    wgl_u_img = glGetUniformLocation(wgl_prog, "u_img");

    glGenVertexArrays(1, &wgl_vao);
    glBindVertexArray(wgl_vao);
    glGenBuffers(1, &wgl_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, wgl_vbo);
    i32 stride = cast(i32, sizeof(DrawVtx));
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, 0, stride, cast(void*, 0));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, 0, stride, cast(void*, 8));
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(2, 4, GL_UNSIGNED_BYTE, 1, stride, cast(void*, 16));

    glGenTextures(1, &wgl_atlas);
    glBindTexture(GL_TEXTURE_2D, wgl_atlas);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, cast(i32, GL_NEAREST));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, cast(i32, GL_NEAREST));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, cast(i32, GL_CLAMP_TO_EDGE));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, cast(i32, GL_CLAMP_TO_EDGE));
    glTexImage2D(GL_TEXTURE_2D, 0, cast(i32, GL_RGBA8), ATLAS_W, ATLAS_H, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);

    // dst = col * a + dst * (1 - a); the canvas is opaque, so its
    // alpha stays 1 whatever the coverage
    glEnable(GL_BLEND);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ZERO, GL_ONE);
    wgl_up = true;
    return true;
}

void gpu_resize(i32 w, i32 h) {
    if w <= 0 || h <= 0 { return; }
    gpu_width = w;
    gpu_height = h;
}

// An image as a texture of its own: straight RGBA8, w by h, with its mip
// levels. The handle, or -1 before the context or without a free slot.
i32 gpu_image_create(u8* rgba, i32 w, i32 h) {
    if !wgl_up || w <= 0 || h <= 0 { return -1; }
    i32 slot = -1;
    for i32 i = 0; i < GPU_IMAGE_MAX; i++ {
        if wgl_images[i] == 0 {
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
    wgl_images[slot] = t;
    return slot;
}

void gpu_image_free(i32 h) {
    if h < 0 || h >= GPU_IMAGE_MAX || wgl_images[h] == 0 { return; }
    glDeleteTextures(1, &wgl_images[h]);
    wgl_images[h] = 0;
}

void gpu_upload_atlas(u8* pixels) {
    if !wgl_up { return; }
    glBindTexture(GL_TEXTURE_2D, wgl_atlas);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, ATLAS_W, ATLAS_H, GL_RGBA, GL_UNSIGNED_BYTE, cast(void*, pixels));
}

void gpu_frame_end(f32 bg_r, f32 bg_g, f32 bg_b) {
    if !wgl_up { return; }

    glViewport(0, 0, gpu_width, gpu_height);
    glClearColor(bg_r, bg_g, bg_b, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glUseProgram(wgl_prog);
    f32[2] screen = { cast(f32, gpu_width), cast(f32, gpu_height) };
    glUniform2fv(wgl_u_screen, 1, &screen[0]);
    f32[2] shift = { 0.0f, cast(f32, g_caption_h) };
    glUniform2fv(wgl_u_shift, 1, &shift[0]);
    f32[3] bg = { bg_r, bg_g, bg_b };
    glUniform3fv(wgl_u_bg, 1, &bg[0]);
    glUniform1i(wgl_u_tex, 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, wgl_atlas);

    glBindVertexArray(wgl_vao);
    glBindBuffer(GL_ARRAY_BUFFER, wgl_vbo);
    if draw_nverts > 0 {
        i64 bytes = cast(i64, draw_nverts) * sizeof(DrawVtx);
        if bytes > wgl_vbo_cap {
            wgl_vbo_cap = bytes;
        }
        glBufferData(GL_ARRAY_BUFFER, wgl_vbo_cap, null, GL_STREAM_DRAW);
        glBufferSubData(GL_ARRAY_BUFFER, 0, bytes, cast(void*, draw_verts));
        // each run with its texture: the atlas, or an image
        for i32 r = 0; r < draw_nruns; r++ {
            i32 first = draw_run_first[r];
            i32 end = draw_nverts;
            if r + 1 < draw_nruns { end = draw_run_first[r + 1]; }
            if end <= first { continue; }
            i32 t = draw_run_tex[r];
            if t >= 0 {
                if t >= GPU_IMAGE_MAX || wgl_images[t] == 0 { continue; }
                glBindTexture(GL_TEXTURE_2D, wgl_images[t]);
                i32 mag = cast(i32, GL_LINEAR);
                if (draw_run_flags[r] & DRAW_RUN_NEAREST) != 0 { mag = cast(i32, GL_NEAREST); }
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, mag);
                glUniform1i(wgl_u_img, 1);
            } else {
                glBindTexture(GL_TEXTURE_2D, wgl_atlas);
                glUniform1i(wgl_u_img, 0);
            }
            glDrawArrays(GL_TRIANGLES, first, end - first);
        }
    }
}
