// wasm_fuzz.mjs - run the headless harness as a browser-target module
// under node, with the repository as its file system:
//   minc --target wasm src/ed_fuzz.mc -o build/ed_fuzz.wasm
//   node scripts/wasm_fuzz.mjs build/ed_fuzz.wasm --seed 1 --steps 400
// The harness stubs every platform service itself, so this host only
// has to be the runtime's: files, output, the clock, the arguments.
// Its frame hashes must agree byte for byte with a native run, which
// is the port's conformance check for the editor core.
import fs from 'node:fs';
import path from 'node:path';

const [wasmPath, ...args] = process.argv.slice(2);
if (!wasmPath) { console.error('usage: node scripts/wasm_fuzz.mjs <module.wasm> [harness args]'); process.exit(2); }
const bytes = fs.readFileSync(wasmPath);
const dec = new TextDecoder('utf-8');
const enc = new TextEncoder();
let mem = null;
let ex = null;
const u8 = () => new Uint8Array(mem.buffer);
const N = Number;
const readCStr = (ptr) => { const b = u8(); const s = N(ptr); let e = s; while (b[e]) e++; return dec.decode(b.subarray(s, e)); };

const fds = new Map();
let nextFd = 3;
const argPtrs = [];
const env = new Proxy({
  write: (fd, ptr, len) => {
    const n = N(len);
    const s = dec.decode(u8().subarray(N(ptr), N(ptr) + n));
    (N(fd) === 2 ? process.stderr : process.stdout).write(s);
    return BigInt(n);
  },
  open: (pathPtr, mode) => {
    const p = readCStr(pathPtr);
    if (N(mode) !== 0) {
      // the harness writes only for --dump-script; keep those too
      try { const fd = fs.openSync(p, 'w'); fds.set(nextFd, { fd, w: true }); return BigInt(nextFd++); } catch (e) { return -1n; }
    }
    try {
      const data = fs.readFileSync(p);
      fds.set(nextFd, { data, pos: 0 });
      return BigInt(nextFd++);
    } catch (e) { return -1n; }
  },
  read: (fd, ptr, len) => {
    const f = fds.get(N(fd));
    if (!f || !f.data) return 0n;
    const n = Math.min(N(len), f.data.length - f.pos);
    if (n > 0) u8().set(f.data.subarray(f.pos, f.pos + n), N(ptr));
    f.pos += n;
    return BigInt(n);
  },
  close: (fd) => { const f = fds.get(N(fd)); if (f && f.w) fs.closeSync(f.fd); fds.delete(N(fd)); return 0n; },
  clock: () => BigInt(process.hrtime.bigint()),
  get_argc: () => BigInt(argPtrs.length),   // both cross as i64
  get_arg: (i) => BigInt(argPtrs[N(i)] || 0),
  __minc_file_size: (pathPtr) => { try { return BigInt(fs.statSync(readCStr(pathPtr)).size); } catch (e) { return -1n; } },
  __sys_exit: (code) => { process.exit(N(code)); },
}, { get(t, k) { if (k in t) return t[k]; return (...a) => { console.error('wasm_fuzz: unhandled runtime import', String(k)); return 0; }; } });
// a write through a writable fd
env.write = ((orig) => (fd, ptr, len) => {
  const f = fds.get(N(fd));
  if (f && f.w) { const n = N(len); fs.writeSync(f.fd, u8().subarray(N(ptr), N(ptr) + n)); return BigInt(n); }
  return orig(fd, ptr, len);
})(env.write);
const math = new Proxy({}, { get(t, k) { return Math[k] || ((a, b) => (String(k).startsWith('fmod') ? a % b : 0)); } });
// the harness's own listing import: names directly inside dir, one per
// line, files or directories; bytes written, or minus the bytes needed
const harness = {
  harness_dir_list: (dirPtr, dn, wantDirs, buf, cap) => {
    const dir = dec.decode(u8().subarray(N(dirPtr), N(dirPtr) + N(dn))) || '.';
    let names = [];
    try {
      names = fs.readdirSync(dir, { withFileTypes: true })
        .filter(d => (N(wantDirs) !== 0) === d.isDirectory())
        .map(d => d.name + '\n');
    } catch (e) { names = []; }
    const b = enc.encode(names.join(''));
    if (b.length > N(cap)) return -b.length;
    u8().set(b, N(buf));
    return b.length;
  },
  harness_file_remove: (p, n) => {
    try { fs.unlinkSync(dec.decode(u8().subarray(N(p), N(p) + N(n)))); return 0; } catch (e) { return -1; }
  },
};

const { instance } = await WebAssembly.instantiate(bytes, { env, math, harness });
ex = instance.exports;
mem = ex.memory;
// argv as C strings inside the module, argv[0] first like a native run
for (const a of [path.basename(wasmPath), ...args]) {
  const b = enc.encode(a + '\0');
  const p = Number(ex.__wasm_alloc(BigInt(b.length)));   // the size is i64
  u8().set(b, p);
  argPtrs.push(p);
}
if (ex.__minc_init_data) ex.__minc_init_data();
process.exit(ex.main());
