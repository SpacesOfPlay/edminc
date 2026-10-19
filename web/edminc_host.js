// edminc_host.js - the page side of the browser platform (lib/web.mc,
// lib/plat_web.mc). It holds the project's files, feeds DOM input into
// the module's exported entries, draws through WebGL2, and renders one
// frame per animation frame after the editor asks for one. Nothing runs
// at idle: no animation loop, and timers only while the editor holds
// one.
//
// Boundary: i32 and pointers cross as numbers, i64 and u32 as BigInt,
// f32 as numbers. The "host" imports below are declared in lib/web.mc
// with i32 everywhere but the clock.

const K = { LEFT: 256, RIGHT: 257, UP: 258, DOWN: 259, PGUP: 260, PGDN: 261,
            HOME: 262, END: 263, DELETE: 264, ESCAPE: 265, TAB: 266, F12: 267, F8: 268, F7: 270,
            F1: 271, F2: 272, F3: 273, F4: 274, F6: 275, F9: 276, F10: 277, F11: 278, MENU: 279 };
const MOD = { CTRL: 1, SHIFT: 2, ALT: 4, SUPER: 8 };
const SPECIAL = { ArrowLeft: K.LEFT, ArrowRight: K.RIGHT, ArrowUp: K.UP, ArrowDown: K.DOWN,
                  PageUp: K.PGUP, PageDown: K.PGDN, Home: K.HOME, End: K.END,
                  Delete: K.DELETE, Escape: K.ESCAPE, F12: K.F12, F8: K.F8, F7: K.F7,
                  F1: K.F1, F2: K.F2, F3: K.F3, F4: K.F4, F6: K.F6, F9: K.F9, F10: K.F10, F11: K.F11, ContextMenu: K.MENU };
const CURSORS = ['default', 'text', 'col-resize', 'pointer', 'row-resize'];   // CURSOR_* in lib/plat.mc
const BUTTONS = [0, 2, 1];   // DOM left/middle/right to the contract's left/right/middle

export async function start({ wasmPath, canvas, file }) {
  const isMac = /Mac|iPhone|iPad/.test(navigator.platform);
  const project = (wasmPath.split('/').pop() || 'edminc').replace(/\.wasm$/, '');
  const dec = new TextDecoder('utf-8');
  const enc = new TextEncoder();
  let mem = null;
  let ex = null;
  let ready = false;
  const stats = { frames: 0, timerTicks: 0, wakes: 0, lspOut: 0, lspIn: 0, log: [] };
  const N = Number;
  const u8 = () => new Uint8Array(mem.buffer);
  const readStr = (ptr, len) => dec.decode(u8().subarray(N(ptr), N(ptr) + N(len)));
  const readCStr = (ptr) => { const b = u8(); let e = N(ptr); while (b[e]) e++; return dec.decode(b.subarray(N(ptr), e)); };
  const arr = (type, ptr, n) => {
    ptr = N(ptr); n = N(n);
    if (type === 'u8') return new Uint8Array(mem.buffer, ptr, n);
    if (type === 'u32') return new Uint32Array(mem.buffer, ptr, n);
    if (type === 'i32') return new Int32Array(mem.buffer, ptr, n);
    return new Float32Array(mem.buffer, ptr, n);
  };
  // bytes into a buffer the module handed us, two-call protocol: the
  // count when they fit, minus the count needed when they do not
  function putBytes(bytes, buf, cap) {
    if (bytes.length > N(cap)) return -bytes.length;
    u8().set(bytes, N(buf));
    return bytes.length;
  }

  // --- files: the project, fetched once into a map --------------------
  const vfs = new Map();   // path -> Uint8Array
  // the editor roots its file uris at /<project>, so a path from the
  // server side may carry that prefix
  const norm = p => {
    p = p.replace(/\\/g, '/').replace(/^(\.\/)+/, '').replace(/^\/+/, '');
    if (p.startsWith(project + '/')) p = p.slice(project.length + 1);
    return p;
  };
  async function seed() {
    let list = [];
    try { const r = await fetch('files.json'); if (r.ok) list = await r.json(); } catch (e) { /* no manifest */ }
    await Promise.all(list.map(async p => {
      const r = await fetch('fs/' + p);
      if (r.ok) vfs.set(norm(p), new Uint8Array(await r.arrayBuffer()));
    }));
    // the language server, when the build staged one, and the stdlib
    // sources it resolves imports against (worker-only: the editor's
    // own tree never lists them)
    try {
      const r = await fetch('minc_lsp_web.wasm');
      if (r.ok) lspWasm = await r.arrayBuffer();
    } catch (e) { /* no server on this page */ }
    if (lspWasm) {
      let libs = [];
      try { const r = await fetch('lsplib.json'); if (r.ok) libs = await r.json(); } catch (e) { /* none */ }
      await Promise.all(libs.map(async name => {
        const r = await fetch('lsplib/' + name);
        if (r.ok) lspLib.push(['lib/' + name, new Uint8Array(await r.arrayBuffer())]);
      }));
    }
  }
  let lspWasm = null;
  const lspLib = [];
  const fds = new Map();
  let nextFd = 3;
  function fsOpen(path, mode) {
    path = norm(path);
    if (mode === 0) {
      const d = vfs.get(path);
      if (!d) return -1;
      const fd = nextFd++;
      fds.set(fd, { data: d, pos: 0 });
      return fd;
    }
    const fd = nextFd++;
    fds.set(fd, { path, chunks: [] });
    return fd;
  }
  function fsRead(fd, ptr, len) {
    const f = fds.get(fd);
    if (!f || !f.data) return 0;
    const n = Math.min(len, f.data.length - f.pos);
    if (n > 0) u8().set(f.data.subarray(f.pos, f.pos + n), ptr);
    f.pos += n;
    return n;
  }
  function fsWrite(fd, ptr, len) {
    if (fd === 1 || fd === 2) {
      const s = readStr(ptr, len);
      stats.log.push(s);
      (fd === 2 ? console.error : console.log)(s.replace(/\n$/, ''));
      return len;
    }
    const f = fds.get(fd);
    if (!f || !f.chunks) return 0;
    f.chunks.push(u8().slice(ptr, ptr + len));
    return len;
  }
  function fsClose(fd) {
    const f = fds.get(fd);
    if (!f) return 0;
    if (f.chunks) {
      let n = 0;
      for (const c of f.chunks) n += c.length;
      const out = new Uint8Array(n);
      let o = 0;
      for (const c of f.chunks) { out.set(c, o); o += c.length; }
      vfs.set(f.path, out);
      if (lspWorker) lspWorker.postMessage({ type: 'file', path: project + '/' + f.path, bytes: out });
    }
    fds.delete(fd);
    return 0;
  }
  // "name\n" per entry directly inside dir; files or directories
  function dirList(dir, wantDirs) {
    dir = norm(dir);
    const prefix = dir === '' || dir === '.' ? '' : dir + '/';
    const names = new Set();
    for (const k of vfs.keys()) {
      if (!k.startsWith(prefix)) continue;
      const rest = k.slice(prefix.length);
      const slash = rest.indexOf('/');
      if (wantDirs) { if (slash > 0) names.add(rest.slice(0, slash)); }
      else if (slash < 0 && rest.length > 0) names.add(rest);
    }
    return [...names].map(n => n + '\n').join('');
  }

  // --- the runtime's imports ---------------------------------------------
  const env = new Proxy({
    write: (fd, ptr, len) => BigInt(fsWrite(N(fd), N(ptr), N(len))),
    open: (pathPtr, mode) => BigInt(fsOpen(readCStr(pathPtr), N(mode))),
    read: (fd, ptr, len) => BigInt(fsRead(N(fd), N(ptr), N(len))),
    close: (fd) => BigInt(fsClose(N(fd))),
    clock: () => BigInt(Math.round(performance.now() * 1e6)),
    // no argv on a page, but both cross as i64, so the zero has to be one
    get_argc: () => 0n,
    get_arg: () => 0n,
    __minc_file_size: (pathPtr) => { const d = vfs.get(norm(readCStr(pathPtr))); return BigInt(d ? d.length : -1); },
    // declared i64-returning like the rest, so it has to return one even
    // though the caller never comes back for it
    __sys_exit: (code) => { console.warn('edminc: exit', N(code)); return 0n; },
  }, { get(t, k) { if (k in t) return t[k]; console.warn('edminc: unhandled runtime import', String(k)); return () => 0; } });
  const math = new Proxy({}, { get(t, k) { return Math[k] || ((a, b) => (k.startsWith('fmod') ? a % b : 0)); } });

  // --- the platform's imports ---------------------------------------------
  let rafPending = false;
  const timers = new Map();
  let clip = '';
  const host = {
    host_damage() {
      if (rafPending) return;
      rafPending = true;
      requestAnimationFrame(() => { rafPending = false; if (ready) { stats.frames++; ex.web_frame(); } });
    },
    host_set_timer(id, ms) {
      id = N(id);
      if (timers.has(id)) clearInterval(timers.get(id));
      timers.set(id, setInterval(() => { if (ready) { stats.timerTicks++; ex.web_timer(id); } }, Math.max(1, N(ms))));
    },
    host_kill_timer(id) {
      id = N(id);
      if (timers.has(id)) { clearInterval(timers.get(id)); timers.delete(id); }
    },
    host_time_us: () => BigInt(Math.round(performance.now() * 1000)),
    host_set_title(p, n) { document.title = readStr(p, n); },
    host_clipboard_set(p, n) {
      clip = readStr(p, n);
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(clip).catch(() => {});
    },
    host_clipboard_get: (buf, cap) => putBytes(enc.encode(clip), buf, cap),
    host_quit() { console.log('edminc: quit'); },
    host_open_url(p, n) { window.open(readStr(p, n), '_blank', 'noopener'); },
    host_wake() { setTimeout(() => { if (ready) { stats.wakes++; ex.web_wake(); } }, 0); },
    // the project is the module's name: the title carries it, and file
    // uris root there
    host_cwd: (buf, cap) => putBytes(enc.encode('/' + project), buf, cap),
    host_dir_list: (dir, dn, wantDirs, buf, cap) => putBytes(enc.encode(dirList(readStr(dir, dn), N(wantDirs) !== 0)), buf, cap),
    // the language server: a worker over the same files. The editor
    // writes a framed stream; each message goes over as its body, and
    // the server's framed replies come back as bytes for the editor's
    // own splitting
    host_lsp_start() {
      if (!lspWasm) return 0;
      if (lspWorker) return 1;
      lspWorker = new Worker('edminc_lsp_worker.js');
      lspWorker.onmessage = (e) => {
        const m = e.data;
        if (m.type === 'recv') {
          stats.lspIn++;
          const p = ex.web_alloc(m.bytes.length);
          u8().set(m.bytes, p);
          ex.web_lsp_recv(p, m.bytes.length);
          ex.web_free(p);
        } else if (m.type === 'error') {
          console.error('edminc: language server:', m.message);
        }
      };
      // Keyed under the project root, because that is how rootUri names
      // these files and so how the server asks for them: cwd is
      // '/' + project. Seeded flat, the server finds nothing it was not
      // handed by didOpen, and cross-file definition stays unanswered.
      const rooted = a => a.map(([p, b]) => [project + '/' + p, b]);
      lspWorker.postMessage({ type: 'init', wasm: lspWasm, root: project,
        files: rooted([...vfs.entries()]).concat(rooted(lspLib)) });
      return 1;
    },
    host_lsp_send(p, n) {
      if (!lspWorker) return;
      const chunk = u8().slice(N(p), N(p) + N(n));
      const joined = new Uint8Array(lspOut.length + chunk.length);
      joined.set(lspOut, 0);
      joined.set(chunk, lspOut.length);
      lspOut = joined;
      for (;;) {
        const head = dec.decode(lspOut.subarray(0, Math.min(lspOut.length, 256)));
        const hdrEnd = head.indexOf('\r\n\r\n');
        if (hdrEnd < 0) return;
        const m = head.slice(0, hdrEnd).match(/Content-Length:\s*(\d+)/i);
        if (!m) { lspOut = new Uint8Array(0); return; }
        const bodyLen = parseInt(m[1], 10);
        const headBytes = enc.encode(head.slice(0, hdrEnd + 4)).length;
        if (lspOut.length < headBytes + bodyLen) return;
        const body = lspOut.slice(headBytes, headBytes + bodyLen);
        lspOut = lspOut.slice(headBytes + bodyLen);
        stats.lspOut++;
        lspWorker.postMessage({ type: 'send', body }, [body.buffer]);
      }
    },
    host_lsp_stop() {
      if (lspWorker) { lspWorker.terminate(); lspWorker = null; }
      lspOut = new Uint8Array(0);
    },
  };
  let lspWorker = null;
  let lspOut = new Uint8Array(0);

  // --- WebGL2 through the toolchain's GLES3 names -----------------------------
  const gl = canvas.getContext('webgl2', { alpha: false, antialias: false, depth: false, stencil: false, preserveDrawingBuffer: false });
  if (!gl) throw new Error('WebGL2 is required');
  const handles = [null];
  const put = o => { handles.push(o); return handles.length - 1; };
  const get = i => handles[N(i)] || null;
  const warned = new Set();
  const glImports = new Proxy({
    glClear: (mask) => gl.clear(N(mask)),
    glClearColor: (r, g, b, a) => gl.clearColor(r, g, b, a),
    glViewport: (x, y, w, h) => gl.viewport(N(x), N(y), N(w), N(h)),
    glEnable: (c) => gl.enable(N(c)),
    glDisable: (c) => gl.disable(N(c)),
    glBlendFuncSeparate: (sr, dr, sa, da) => gl.blendFuncSeparate(N(sr), N(dr), N(sa), N(da)),
    glGenBuffers: (n, ptr) => { const v = arr('u32', ptr, n); for (let k = 0; k < N(n); k++) v[k] = put(gl.createBuffer()); },
    glBindBuffer: (tgt, b) => gl.bindBuffer(N(tgt), get(b)),
    glBufferData: (tgt, sz, ptr, usage) => { if (N(ptr) === 0) gl.bufferData(N(tgt), N(sz), N(usage)); else gl.bufferData(N(tgt), arr('u8', ptr, sz), N(usage)); },
    glBufferSubData: (tgt, off, sz, ptr) => gl.bufferSubData(N(tgt), N(off), arr('u8', ptr, sz)),
    glGenVertexArrays: (n, ptr) => { const v = arr('u32', ptr, n); for (let k = 0; k < N(n); k++) v[k] = put(gl.createVertexArray()); },
    glBindVertexArray: (va) => gl.bindVertexArray(get(va)),
    glEnableVertexAttribArray: (i) => gl.enableVertexAttribArray(N(i)),
    glVertexAttribPointer: (i, size, type, norm, stride, ptr) => gl.vertexAttribPointer(N(i), N(size), N(type), N(norm) !== 0, N(stride), N(ptr)),
    glGenTextures: (n, ptr) => { const v = arr('u32', ptr, n); for (let k = 0; k < N(n); k++) v[k] = put(gl.createTexture()); },
    glBindTexture: (tgt, t) => gl.bindTexture(N(tgt), get(t)),
    glActiveTexture: (u) => gl.activeTexture(N(u)),
    glTexParameteri: (tgt, p, v) => gl.texParameteri(N(tgt), N(p), N(v)),
    glGenerateMipmap: (tgt) => gl.generateMipmap(N(tgt)),
    glDeleteTextures: (n, ptr) => { const v = arr('u32', ptr, n); for (let k = 0; k < N(n); k++) { const t = get(v[k]); if (t) gl.deleteTexture(t); } },
    glTexImage2D: (tgt, lvl, ifmt, w, h, border, fmt, ty, ptr) => {
      const data = N(ptr) ? arr('u8', ptr, N(w) * N(h) * 4) : null;
      gl.texImage2D(N(tgt), N(lvl), N(ifmt), N(w), N(h), N(border), N(fmt), N(ty), data);
    },
    glTexSubImage2D: (tgt, lvl, xo, yo, w, h, fmt, ty, ptr) =>
      gl.texSubImage2D(N(tgt), N(lvl), N(xo), N(yo), N(w), N(h), N(fmt), N(ty), arr('u8', ptr, N(w) * N(h) * 4)),
    glCreateShader: (t) => BigInt(put(gl.createShader(N(t)))),
    glShaderSource: (s, count, strs, lens) => {
      const sp = arr('u32', strs, count);
      let src = '';
      for (let k = 0; k < N(count); k++) src += readCStr(sp[k]);
      gl.shaderSource(get(s), src);
    },
    glCompileShader: (s) => gl.compileShader(get(s)),
    glGetShaderiv: (s, pname, ptr) => { arr('i32', ptr, 1)[0] = gl.getShaderParameter(get(s), N(pname)) ? 1 : 0; },
    glGetShaderInfoLog: (s, max, lenPtr, logPtr) => {
      const b = enc.encode(gl.getShaderInfoLog(get(s)) || '').subarray(0, Math.max(0, N(max) - 1));
      u8().set(b, N(logPtr));
      arr('i32', lenPtr, 1)[0] = b.length;
    },
    glCreateProgram: () => BigInt(put(gl.createProgram())),
    glAttachShader: (p, s) => gl.attachShader(get(p), get(s)),
    glLinkProgram: (p) => gl.linkProgram(get(p)),
    glGetProgramiv: (p, pname, ptr) => { arr('i32', ptr, 1)[0] = gl.getProgramParameter(get(p), N(pname)) ? 1 : 0; },
    glGetProgramInfoLog: (p, max, lenPtr, logPtr) => {
      const b = enc.encode(gl.getProgramInfoLog(get(p)) || '').subarray(0, Math.max(0, N(max) - 1));
      u8().set(b, N(logPtr));
      arr('i32', lenPtr, 1)[0] = b.length;
    },
    glDeleteShader: (s) => gl.deleteShader(get(s)),
    glUseProgram: (p) => gl.useProgram(get(p)),
    glGetUniformLocation: (p, namePtr) => { const loc = gl.getUniformLocation(get(p), readCStr(namePtr)); return loc === null ? -1 : put(loc); },
    glUniform1i: (l, x) => gl.uniform1i(get(l), N(x)),
    glUniform2fv: (l, n, ptr) => gl.uniform2fv(get(l), arr('f32', ptr, 2 * N(n))),
    glUniform3fv: (l, n, ptr) => gl.uniform3fv(get(l), arr('f32', ptr, 3 * N(n))),
    glDrawArrays: (m, f, c) => gl.drawArrays(N(m), N(f), N(c)),
  }, { get(t, k) { if (k in t) return t[k]; return (...a) => { if (!warned.has(k)) { warned.add(k); console.warn('edminc: unhandled gl import', String(k)); } return 0; }; } });

  // --- input ------------------------------------------------------------------
  const dpr = () => window.devicePixelRatio || 1;
  const dpi = () => Math.round(96 * dpr());
  let curDpi = dpi();
  let lastX = 0, lastY = 0, leftDown = false;
  function mods(e) {
    const primary = isMac ? e.metaKey : e.ctrlKey;
    const other = isMac ? e.ctrlKey : e.metaKey;
    return (primary ? MOD.CTRL : 0) | (e.shiftKey ? MOD.SHIFT : 0) | (e.altKey ? MOD.ALT : 0) | (other ? MOD.SUPER : 0);
  }
  function pos(e) {
    const r = canvas.getBoundingClientRect();
    lastX = Math.round((e.clientX - r.left) * dpr());
    lastY = Math.round((e.clientY - r.top) * dpr());
    return [lastX, lastY];
  }
  // the backing store in device pixels: exact from the observer when
  // the browser reports device pixels, else the css box scaled
  function fit(entry) {
    let w, h;
    if (entry && entry.devicePixelContentBoxSize && entry.devicePixelContentBoxSize.length) {
      w = entry.devicePixelContentBoxSize[0].inlineSize;
      h = entry.devicePixelContentBoxSize[0].blockSize;
    } else {
      const r = canvas.getBoundingClientRect();
      w = Math.round(r.width * dpr());
      h = Math.round(r.height * dpr());
    }
    w = Math.max(1, w);
    h = Math.max(1, h);
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    return [w, h];
  }
  canvas.tabIndex = 0;
  canvas.style.outline = 'none';
  canvas.addEventListener('keydown', e => {
    if (!ready || e.isComposing) return;
    const m = mods(e);
    const primary = (m & MOD.CTRL) !== 0;
    if (e.key === 'Control' || e.key === 'Meta' || e.key === 'Shift' || e.key === 'Alt') {
      ex.web_hover(lastX, lastY, m);   // the modifier-only change (the cmd+hover link)
      return;
    }
    if (e.key in SPECIAL) { ex.web_key(SPECIAL[e.key], m); e.preventDefault(); return; }
    if (e.key === 'Tab') { if (m & (MOD.CTRL | MOD.SUPER)) ex.web_key(K.TAB, m); else ex.web_char(9); e.preventDefault(); return; }
    if (e.key === 'Enter') { ex.web_char(13); e.preventDefault(); return; }
    if (e.key === 'Backspace') { ex.web_char(8); e.preventDefault(); return; }
    if (primary && !e.altKey && e.key.toLowerCase() === 'v') {
      // Read the clipboard directly rather than waiting for a paste event:
      // Firefox fires paste only on editable elements, never on a canvas.
      // readText needs a secure context (localhost is one) and this keydown
      // gesture; on failure fall back to the last in-app copy so paste
      // within the editor still works. preventDefault stops the browser's
      // own paste, so the paste event below does not also fire for Ctrl+V.
      e.preventDefault();
      const paste = t => { if (t != null) clip = t.replace(/\r\n?/g, '\n'); ex.web_key('V'.codePointAt(0), MOD.CTRL); };
      if (navigator.clipboard && navigator.clipboard.readText) {
        navigator.clipboard.readText().then(paste).catch(() => paste(null));
      } else {
        paste(null);
      }
      return;
    }
    const printable = [...e.key].length === 1;
    // AltGr arrives as ctrl+alt and types; a bare alt is a chord key
    const chord = primary || (m & MOD.SUPER) !== 0 || (e.altKey && !e.ctrlKey);
    if (chord) {
      let code = 0;
      if (printable) { code = e.key.toUpperCase().codePointAt(0); if (code > 127) code = 0; }
      if (code === 43) code = 61;   // zoom in: + is the shifted =
      if (code) { ex.web_key(code, m); e.preventDefault(); }
      return;
    }
    if (printable) { ex.web_char(e.key.codePointAt(0)); e.preventDefault(); }
  });
  canvas.addEventListener('keyup', e => {
    if (!ready) return;
    if (e.key === 'Control' || e.key === 'Meta' || e.key === 'Shift' || e.key === 'Alt') ex.web_hover(lastX, lastY, mods(e));
  });
  canvas.addEventListener('compositionend', e => {
    if (!ready) return;
    for (const ch of e.data || '') ex.web_char(ch.codePointAt(0));
  });
  canvas.addEventListener('paste', e => {
    if (!ready) return;
    clip = (e.clipboardData.getData('text/plain') || '').replace(/\r\n?/g, '\n');
    ex.web_key('V'.codePointAt(0), MOD.CTRL);
    e.preventDefault();
  });
  canvas.addEventListener('pointerdown', e => {
    if (!ready) return;
    canvas.focus();
    const b = BUTTONS[e.button];
    if (b === undefined) return;
    const [x, y] = pos(e);
    if (b === 0) leftDown = true;
    try { canvas.setPointerCapture(e.pointerId); } catch (err) { /* fine */ }
    ex.web_mouse(x, y, b, 1, mods(e));
    e.preventDefault();
  });
  canvas.addEventListener('pointerup', e => {
    if (!ready) return;
    const b = BUTTONS[e.button];
    if (b === undefined) return;
    const [x, y] = pos(e);
    if (b === 0) leftDown = false;
    ex.web_mouse(x, y, b, 0, mods(e));
  });
  canvas.addEventListener('pointermove', e => {
    if (!ready) return;
    const [x, y] = pos(e);
    if (leftDown) { ex.web_mouse_move(x, y); return; }
    ex.web_hover(x, y, mods(e));
    canvas.style.cursor = CURSORS[ex.web_cursor(x, y)] || 'default';
  });
  canvas.addEventListener('wheel', e => {
    if (!ready) return;
    const [x, y] = pos(e);
    const s = e.deltaMode === 1 ? 20 * dpr() : e.deltaMode === 2 ? canvas.height : dpr();
    // lines or pages come from a wheel's notches; pixels from a
    // touchpad, or a wheel the browser already smooths
    if (e.deltaMode !== 0) ex.web_scroll_notch(e.deltaX * s, e.deltaY * s, x, y);
    else ex.web_scroll(e.deltaX * s, e.deltaY * s, x, y);
    e.preventDefault();
  }, { passive: false });
  canvas.addEventListener('contextmenu', e => e.preventDefault());
  // the caret follows the canvas's own focus; the window's events do
  // not fire for a page that loads already focused
  const focused = () => document.hasFocus() && document.activeElement === canvas;
  canvas.addEventListener('focus', () => { if (ready) ex.web_focus(1); });
  canvas.addEventListener('blur', () => { if (ready) ex.web_focus(0); });
  window.addEventListener('blur', () => { if (ready) ex.web_focus(0); });
  window.addEventListener('focus', () => { if (ready) ex.web_focus(focused() ? 1 : 0); });
  window.addEventListener('beforeunload', e => {
    if (ready && ex.web_close() === 0) { e.preventDefault(); e.returnValue = ''; }
  });
  // a move to a screen with another device pixel ratio keeps the css
  // size, so it must be watched on its own: the observer sees it when
  // it reports device pixels, and the media query when it does not
  function refit(entry) {
    if (!ready) return;
    const d = dpi();
    if (d !== curDpi) { curDpi = d; ex.web_scale(d); }
    const [w, h] = fit(entry);
    ex.web_resize(w, h);
  }
  const ro = new ResizeObserver(entries => refit(entries[entries.length - 1]));
  try { ro.observe(canvas, { box: 'device-pixel-content-box' }); } catch (e) { ro.observe(canvas); }
  function watchDpr() {
    const mq = matchMedia('(resolution: ' + dpr() + 'dppx)');
    mq.addEventListener('change', () => { refit(null); watchDpr(); }, { once: true });
  }
  watchDpr();

  // --- up --------------------------------------------------------------------------
  await seed();
  const bytes = await (await fetch(wasmPath)).arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes, { env, host, gl: glImports, math });
  ex = instance.exports;
  mem = ex.memory;
  if (ex.__minc_init_data) ex.__minc_init_data();
  ex.main();
  const [w, h] = fit();
  const initial = file || new URLSearchParams(location.search).get('file') || 'README.md';
  const pb = enc.encode(initial);
  const p = ex.web_alloc(pb.length);
  u8().set(pb, p);
  ex.web_start(w, h, curDpi, p, pb.length);
  ex.web_free(p);
  ready = true;
  canvas.focus();
  ex.web_focus(focused() ? 1 : 0);
  // The color emoji font is large and kept out of files.json, so the seed
  // above starts fast; fetch it in the background and, once it lands in the
  // file system, tell the module so cached tofu re-rasters as color emoji.
  fetch('fs/assets/NotoColorEmoji.ttf').then(async r => {
    if (!r.ok) return;
    vfs.set(norm('assets/NotoColorEmoji.ttf'), new Uint8Array(await r.arrayBuffer()));
    if (ex.web_emoji_loaded) ex.web_emoji_loaded();
  }).catch(() => { /* no font staged: emoji stay tofu */ });
  // for probes: the exports, the file system, and activity counters
  window.edminc = { exports: ex, vfs, stats, mem: () => mem };
  return window.edminc;
}
