// edminc_lsp_worker.js - the language server in a worker. The page
// posts the server module, the project's files and the stdlib sources
// once, then one unframed JSON-RPC message at a time; the server's
// framed replies (its fd 1) go back as bytes for the editor's own
// framing to split. Indexing and answering never touch the UI thread.
//
// Messages in: { type: 'init', wasm, root, files: [[path, bytes], ...] }
//              { type: 'send', body }        one message, UTF-8 bytes
//              { type: 'file', path, bytes }  a save on the page
// Messages out: { type: 'ready' } | { type: 'recv', bytes } | { type: 'error', message }

const dec = new TextDecoder('utf-8');
const vfs = new Map();
const fds = new Map();
let nextFd = 3;
let inst = null;
let pending = [];

const norm = p => p.replace(/\\/g, '/').replace(/^(\.\/)+/, '').replace(/^\/+/, '');

// The server's working directory is the project root, '/' + root, and
// the files are keyed under it. A path the server opens is resolved
// against that directory first, as a file system would: the server
// looks for a stdlib module as lib/<name>.mc relative to it, and then
// up the parents.
let root = '';
function resolve(p) {
  p = p.replace(/\\/g, '/');
  const parts = (p.startsWith('/') || !root ? [] : [root]).concat(p.split('/'));
  const out = [];
  for (const s of parts) {
    if (s === '' || s === '.') continue;
    if (s === '..') { out.pop(); continue; }
    out.push(s);
  }
  return out.join('/');
}
const mem = () => new Uint8Array(inst.exports.memory.buffer);
function readCStr(ptr) { const b = mem(); const s = Number(ptr); let e = s; while (b[e]) e++; return dec.decode(b.subarray(s, e)); }

const env = new Proxy({
  write: (fd, ptr, len) => {
    const n = Number(len);
    const data = mem().slice(Number(ptr), Number(ptr) + n);
    const f = Number(fd);
    if (f === 1) postMessage({ type: 'recv', bytes: data }, [data.buffer]);
    else if (f !== 2) { const w = fds.get(f); if (w && w.chunks) w.chunks.push(data); }
    return BigInt(n);
  },
  clock: () => BigInt(Math.round(performance.now() * 1e6)),
  open: (pathPtr, mode) => {
    const p = resolve(readCStr(pathPtr));
    if (Number(mode) === 0) {
      const d = vfs.get(p);
      if (!d) return -1n;
      fds.set(nextFd, { data: d, pos: 0 });
      return BigInt(nextFd++);
    }
    fds.set(nextFd, { chunks: [], path: p });
    return BigInt(nextFd++);
  },
  read: (fd, ptr, len) => {
    const f = fds.get(Number(fd));
    if (!f || !f.data) return 0n;
    const n = Math.min(Number(len), f.data.length - f.pos);
    if (n > 0) mem().set(f.data.subarray(f.pos, f.pos + n), Number(ptr));
    f.pos += n;
    return BigInt(n);
  },
  close: (fd) => {
    const f = fds.get(Number(fd));
    if (f && f.chunks) {
      let n = 0;
      for (const c of f.chunks) n += c.length;
      const out = new Uint8Array(n);
      let o = 0;
      for (const c of f.chunks) { out.set(c, o); o += c.length; }
      vfs.set(f.path, out);
    }
    fds.delete(Number(fd));
    return 0n;
  },
  get_argc: () => 0n,
  get_arg: () => 0n,
  __minc_file_size: (pathPtr) => { const d = vfs.get(resolve(readCStr(pathPtr))); return BigInt(d ? d.length : -1); },
  __sys_exit: (code) => { throw new Error('the language server exited with ' + Number(code)); },
}, { get(t, k) { if (k in t) return t[k]; return () => 0; } });
const math = new Proxy({}, { get(t, k) { return Math[k] || ((a, b) => (String(k).startsWith('fmod') ? a % b : 0)); } });

function send(body) {
  const ptr = Number(inst.exports.__wasm_alloc(BigInt(body.length + 1)));
  const m = mem();
  m.set(body, ptr);
  m[ptr + body.length] = 0;
  inst.exports.lsp_frame(ptr, body.length);
}

onmessage = async (e) => {
  const msg = e.data;
  try {
    if (msg.type === 'init') {
      root = norm(msg.root || '');
      for (const [p, bytes] of msg.files) vfs.set(norm(p), bytes);
      const { instance } = await WebAssembly.instantiate(msg.wasm, { env, math });
      inst = instance;
      inst.exports.lsp_init();
      postMessage({ type: 'ready' });
      for (const b of pending) send(b);
      pending = [];
    } else if (msg.type === 'send') {
      if (inst) send(msg.body); else pending.push(msg.body);
    } else if (msg.type === 'file') {
      vfs.set(norm(msg.path), msg.bytes);
    }
  } catch (err) {
    postMessage({ type: 'error', message: String(err && err.message || err) });
  }
};
