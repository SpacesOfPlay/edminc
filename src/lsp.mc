// lsp.mc - LSP client: minc-lsp for minc files and clangd for C and
// C++, each over piped stdio in its own plat_child_* slot. A reader
// thread per server splits Content-Length frames off the child's
// stdout and queues the payloads under a mutex; plat_wake hands them
// to lsp_pump on the main thread, which parses JSON and dispatches.
// Outgoing traffic is framed by lsp_send through plat_child_write. The
// lifecycle (initialize round-trip, didOpen, didChange), the requests,
// and the publishDiagnostics store live here; view.mc draws the
// diagnostics and ed.mc decides when to push.

import thread;
import json;

private const i64 LSP_ACC_MAX = 8 * 1024 * 1024;
private const i64 LSP_OPEN_MAX = 2 * 1024 * 1024;  // didOpen size cap
private const i32 LSP_MAX_DIAG_FILES = 16;
private const i32 LSP_MAX_DIAGS = 256;             // per file
private const i32 LSP_INIT_ID = 1;
const i32 HOVER_TEXT_MAX = 2048;   // what a hover popup will show
const i32 HOVER_LINES_MAX = 64;   // lines the hover panel keeps code flags for

// jw_esc emits up to six bytes for one input byte: a control character
// with no short escape becomes \u00xx. A JSON buffer sized on the
// input length has to allow for that, and a document can hold control
// bytes (a form feed in a source file, or pasted binary).
private const i64 ESC_MAX = 6;
private const i64 URI_ROOM = ESC_MAX * cast(i64, PATH_MAX + 8);

bool lsp_on = false;      // child spawned, reader running
bool lsp_ready = false;   // initialize round-trip complete
bool lsp_trace = false;   // --lsp-trace: print traffic milestones
// LSP positions count UTF-16 code units unless the server agrees to
// utf-8 (3.17's positionEncoding). The spec default is the safe one to
// assume until the reply lands.
bool lsp_pos_utf16 = true;
// the server granted TextDocumentSyncKind.Incremental (change = 2); it
// does so only with utf-8 positions, which is the unit the record below
// keeps, so a utf-16 server always gets the whole text
bool lsp_sync_incremental = false;

// --- the edit record --------------------------------------------------
// The edits since the last push, as the server takes them under
// incremental sync: a range in the document as it stood before that
// edit, in byte columns, and the text put there. text_buf reports every
// insert and delete before applying it. A record that overflows, or
// that cannot cover everything since the last push (a buffer switch),
// sends the whole text instead, which the server takes under either
// mode.
private const i32 LSP_REC_MAX = 512;
private const i64 LSP_REC_TEXT_MAX = 65536;

private struct LspEdit {
    i32 l0;
    i32 c0;
    i32 l1;
    i32 c1;
    i64 toff;
    i32 tlen;
}

private LspEdit[LSP_REC_MAX] lsp_rec;
private i32 lsp_rec_n = 0;
private u8* lsp_rec_text = null;
private i64 lsp_rec_len = 0;
private bool lsp_rec_whole = false;   // the next push carries the whole text

private void lsp_rec_push(i32 l0, i32 c0, i32 l1, i32 c1, u8* s, i32 n) {
    if lsp_rec_whole { return; }
    if lsp_pos_utf16 || lsp_rec_n == LSP_REC_MAX || lsp_rec_len + n > LSP_REC_TEXT_MAX {
        lsp_rec_whole = true;
        return;
    }
    if lsp_rec_text == null { lsp_rec_text = alloc<u8>(LSP_REC_TEXT_MAX); }
    LspEdit* e = &lsp_rec[lsp_rec_n];
    e.l0 = l0;
    e.c0 = c0;
    e.l1 = l1;
    e.c1 = c1;
    e.toff = lsp_rec_len;
    e.tlen = n;
    if n > 0 {
        memcpy(lsp_rec_text + lsp_rec_len, s, n);
        lsp_rec_len += n;
    }
    lsp_rec_n++;
}

// text_buf, before it inserts n bytes at pos
void lsp_note_insert(i64 pos, u8* s, i32 n) {
    if lsp_rec_whole { return; }
    if tb.nlines <= 0 {
        lsp_rec_whole = true;
        return;
    }
    i32 l = tb_line_of(pos);
    i32 c = cast(i32, pos - tb_line_start(l));
    lsp_rec_push(l, c, l, c, s, n);
}

// text_buf, before it deletes n bytes at pos
void lsp_note_delete(i64 pos, i64 n) {
    if lsp_rec_whole { return; }
    if tb.nlines <= 0 {
        lsp_rec_whole = true;
        return;
    }
    i32 l0 = tb_line_of(pos);
    i32 c0 = cast(i32, pos - tb_line_start(l0));
    i32 l1 = tb_line_of(pos + n);
    i32 c1 = cast(i32, pos + n - tb_line_start(l1));
    lsp_rec_push(l0, c0, l1, c1, null, 0);
}

// the server has the text as it is now
void lsp_rec_reset() {
    lsp_rec_n = 0;
    lsp_rec_len = 0;
    lsp_rec_whole = false;
}

// the record cannot cover what the server has: the loaded buffer's
// edits since its last push were never recorded
void lsp_rec_invalidate() {
    lsp_rec_n = 0;
    lsp_rec_len = 0;
    lsp_rec_whole = true;
}

struct LspDiag {
    i32 line;      // 0-based start line
    i32 col0;      // start character
    i32 line1;
    i32 col1;
    i32 severity;  // 1 error, 2 warning, 3 info, 4 hint
    i32 msg_off;
    i32 msg_len;
}

private struct LspDiagSet {
    u8[PATH_MAX] path;
    i32 path_len;
    LspDiag* items;
    i32 count;
    u8* msgs;
    i64 msgs_cap;
}

private LspDiagSet[LSP_MAX_DIAG_FILES] lsp_sets;
private i32 lsp_nsets = 0;

// reader-side frame accumulator per slot (reader thread only; tests
// feed it directly)
private u8*[PLAT_CHILDREN] lsp_acc;
private i64[PLAT_CHILDREN] lsp_acc_len;
private i64[PLAT_CHILDREN] lsp_acc_cap;

// payload queue crossing to the main thread: [i32 len][i32 slot][bytes]...
private Mutex lsp_mx;
private bool lsp_mx_ready = false;
private u8* lsp_q = null;
private i64 lsp_q_len = 0;
private i64 lsp_q_cap = 0;

private Thread[PLAT_CHILDREN] lsp_thread;
private bool[PLAT_CHILDREN] lsp_thread_up;
private i32[PLAT_CHILDREN] lsp_slot_arg;   // each thread's slot, by address

// opened documents, so didOpen is sent once per file. The table
// grows: a session opens more files than any fixed count, and a file
// past the end would never reach the server.
private u8* lsp_open_paths = null;
private i64 lsp_open_len = 0;
private i64 lsp_open_cap = 0;
private i32* lsp_open_off = null;
private i32* lsp_open_n = null;
private i32* lsp_open_ver = null;
private i32 lsp_nopen = 0;
private i32 lsp_open_slots = 0;

// --- servers ----------------------------------------------------------
// lsp_on, lsp_ready, the position and sync flags, the capabilities and
// the opened table describe one server, the current one. lsp_use saves
// them and loads another's. The editor makes the current server the
// one for the buffer in its globals, and lsp_pump makes it the one
// whose message it handles. Request ids come from one counter, so a
// reply names its request whichever server sent it. The thread side
// (the frame accumulator, the writer queue) runs beside the main
// thread and is indexed by slot instead.
const i32 LSP_MINC = 0;   // minc-lsp
const i32 LSP_C = 1;      // clangd
private const i32 LSP_SERVERS = PLAT_CHILDREN;

private struct LspSrvState {
    bool on;
    bool ready;
    bool pos_utf16;
    bool sync_incremental;
    bool calls_ok;
    bool sem_ok;
    u8* open_paths;
    i64 open_len;
    i64 open_cap;
    i32* open_off;
    i32* open_n;
    i32* open_ver;
    i32 nopen;
    i32 open_slots;
}

private LspSrvState[LSP_SERVERS] lsp_saved;
private bool lsp_saved_init = false;
i32 lsp_cur = LSP_MINC;
// the server's program was not found; it is looked for again after a
// folder switch
private bool[LSP_SERVERS] lsp_absent_flag;

// the server for a buffer in this language
i32 lsp_server_of(i32 lang) {
    if lang == LANG_C { return LSP_C; }
    return LSP_MINC;
}

void lsp_use(i32 k) {
    if k == lsp_cur || k < 0 || k >= LSP_SERVERS { return; }
    if !lsp_saved_init {
        // the spec's default until a server says otherwise
        for i32 i = 0; i < LSP_SERVERS; i++ { lsp_saved[i].pos_utf16 = true; }
        lsp_saved_init = true;
    }
    LspSrvState* o = &lsp_saved[lsp_cur];
    o.on = lsp_on;
    o.ready = lsp_ready;
    o.pos_utf16 = lsp_pos_utf16;
    o.sync_incremental = lsp_sync_incremental;
    o.calls_ok = lsp_calls_ok;
    o.sem_ok = lsp_sem_ok;
    o.open_paths = lsp_open_paths;
    o.open_len = lsp_open_len;
    o.open_cap = lsp_open_cap;
    o.open_off = lsp_open_off;
    o.open_n = lsp_open_n;
    o.open_ver = lsp_open_ver;
    o.nopen = lsp_nopen;
    o.open_slots = lsp_open_slots;
    LspSrvState* n = &lsp_saved[k];
    lsp_on = n.on;
    lsp_ready = n.ready;
    lsp_pos_utf16 = n.pos_utf16;
    lsp_sync_incremental = n.sync_incremental;
    lsp_calls_ok = n.calls_ok;
    lsp_sem_ok = n.sem_ok;
    lsp_open_paths = n.open_paths;
    lsp_open_len = n.open_len;
    lsp_open_cap = n.open_cap;
    lsp_open_off = n.open_off;
    lsp_open_n = n.open_n;
    lsp_open_ver = n.open_ver;
    lsp_nopen = n.nopen;
    lsp_open_slots = n.open_slots;
    lsp_cur = k;
}

// the current server's program could not be found or started
bool lsp_absent() {
    return lsp_absent_flag[lsp_cur];
}

// A call hierarchy item as the call graph keeps it (calls.mc): the
// server finds the function again from these fields alone.
const i32 CALL_NAME_MAX = 256;

struct CallItem {
    u8[CALL_NAME_MAX] name;
    i32 name_len;
    u8[CALL_NAME_MAX] detail;   // the declaration as written, when the server gives it
    i32 detail_len;
    u8[PATH_MAX] path;
    i32 path_len;
    i32 l0;    // the whole function, 0-based lines and server columns
    i32 c0;
    i32 l1;
    i32 c1;
    i32 sl0;   // its name
    i32 sc0;
    i32 sl1;
    i32 sc1;
}

// outstanding definition request (one at a time)
private i32 lsp_next_id = 2;
private i32 lsp_def_id = 0;
private i32 lsp_hover_id = 0;   // hover-link validation probe
private i32 lsp_hovdoc_id = 0;  // hover documentation request
private i32 lsp_sig_id = 0;     // signature help request
private i32 lsp_cmp_id = 0;     // completion request
private i32 lsp_ref_id = 0;     // references request
private i32 lsp_cprep_id = 0;   // call graph: prepareCallHierarchy
private i32 lsp_cin_id = 0;     // call graph: incomingCalls
private i32 lsp_cout_id = 0;    // call graph: outgoingCalls
bool lsp_calls_ok = false;      // the server offers call hierarchy
// the error an index request gets while the workspace scan runs
private const i64 LSP_CONTENT_MODIFIED = -32801;
private i32 lsp_sym_id = 0;     // workspace symbol query (ctrl+t)
private i32 lsp_sem_id = 0;     // semantic tokens, one in flight
private bool lsp_sem_ok = false;   // the server offers full-document tokens
private bool lsp_sem_again = false;   // an ask came in while one was out
private u8[PATH_MAX] lsp_sem_path;    // whose reply is pending
private i32 lsp_sem_path_len = 0;
private u8[PATH_MAX] lsp_sem_next;    // whose ask was held back
private i32 lsp_sem_next_len = 0;

private void lsp_opened_add(str path) {
    if lsp_nopen == lsp_open_slots {
        i32 ns = lsp_open_slots * 2 + 64;
        i32* noff = alloc<i32>(ns);
        i32* nn = alloc<i32>(ns);
        i32* nver = alloc<i32>(ns);
        if lsp_nopen > 0 {
            memcpy(noff, lsp_open_off, lsp_nopen * sizeof(i32));
            memcpy(nn, lsp_open_n, lsp_nopen * sizeof(i32));
            memcpy(nver, lsp_open_ver, lsp_nopen * sizeof(i32));
        }
        if lsp_open_off != null {
            free(lsp_open_off);
            free(lsp_open_n);
            free(lsp_open_ver);
        }
        lsp_open_off = noff;
        lsp_open_n = nn;
        lsp_open_ver = nver;
        lsp_open_slots = ns;
    }
    if lsp_open_len + path.len > lsp_open_cap {
        i64 ncap = lsp_open_cap * 2 + 4096;
        u8* na = alloc<u8>(ncap);
        if lsp_open_paths != null {
            memcpy(na, lsp_open_paths, lsp_open_len);
            free(lsp_open_paths);
        }
        lsp_open_paths = na;
        lsp_open_cap = ncap;
    }
    memcpy(lsp_open_paths + lsp_open_len, path.data, path.len);
    lsp_open_off[lsp_nopen] = cast(i32, lsp_open_len);
    lsp_open_n[lsp_nopen] = path.len;
    lsp_open_ver[lsp_nopen] = 1;
    lsp_open_len += path.len;
    lsp_nopen++;
}

private void lsp_opened_remove(i32 i) {
    // the arena bytes stay put; only the index triple is dropped, so a
    // later open re-appends the path. The set mirrors the server's open
    // documents, nothing more.
    for i32 j = i; j < lsp_nopen - 1; j++ {
        lsp_open_off[j] = lsp_open_off[j + 1];
        lsp_open_n[j] = lsp_open_n[j + 1];
        lsp_open_ver[j] = lsp_open_ver[j + 1];
    }
    lsp_nopen--;
}

private i32 lsp_opened_idx(str path) {
    for i32 i = 0; i < lsp_nopen; i++ {
        if lsp_open_n[i] == path.len
            && str_equal(str_from(lsp_open_paths + lsp_open_off[i], path.len), path) {
            return i;
        }
    }
    return -1;
}

// --- outgoing --------------------------------------------------------
// Sends leave through a writer thread. A push carries the whole file,
// and the pipe blocks once its buffer is full, so writing from the UI
// thread makes the editor wait on a server that is busy indexing -
// the one thing the UI thread must never do. The queue is drained in
// the order frames were built, which is what didOpen-before-didChange
// rests on. Where there is no thread - the harness, and the browser,
// whose page does its own pushing - the write stays inline, so the
// stubs still see the stream they check.

// Test seam: the harnesses stub the child, so a real writer thread
// would take their frames off the stub's synchronous path and their
// checks with it. They set this false and keep sends inline.
bool lsp_threaded = true;

when !os(wasm) {

private Mutex[PLAT_CHILDREN] lsp_wmx;
private bool[PLAT_CHILDREN] lsp_wmx_ready;
private Semaphore[PLAT_CHILDREN] lsp_wsem;
private u8*[PLAT_CHILDREN] lsp_wq;
private i64[PLAT_CHILDREN] lsp_wq_len;
private i64[PLAT_CHILDREN] lsp_wq_cap;
private Thread[PLAT_CHILDREN] lsp_wthread;
private bool[PLAT_CHILDREN] lsp_wthread_up;
private bool[PLAT_CHILDREN] lsp_wstop;

// caller holds lsp_wmx[k]
private void lsp_wq_put(i32 k, u8* p, i64 n) {
    if lsp_wq_len[k] + n > lsp_wq_cap[k] {
        i64 ncap = lsp_wq_cap[k] * 2 + n + 65536;
        u8* nq = alloc<u8>(ncap);
        if lsp_wq[k] != null {
            memcpy(nq, lsp_wq[k], lsp_wq_len[k]);
            free(lsp_wq[k]);
        }
        lsp_wq[k] = nq;
        lsp_wq_cap[k] = ncap;
    }
    memcpy(lsp_wq[k] + lsp_wq_len[k], p, n);
    lsp_wq_len[k] += n;
}

private void lsp_writer(void* arg) {
    i32 k = *cast(i32*, arg);
    while true {
        sem_wait(&lsp_wsem[k]);
        mutex_lock(&lsp_wmx[k]);
        u8* q = lsp_wq[k];
        i64 n = lsp_wq_len[k];
        lsp_wq[k] = null;
        lsp_wq_len[k] = 0;
        lsp_wq_cap[k] = 0;
        bool stop = lsp_wstop[k];
        mutex_unlock(&lsp_wmx[k]);
        if q != null {
            // blocking is what this thread is for
            ignore plat_child_write(k, q, n);
            free(q);
        }
        if stop { break; }
    }
}

}

private void lsp_send(u8* payload, i64 n) {
    noinit u8[64] hdr;
    i64 o = 0;
    str h = "Content-Length: ";
    memcpy(&hdr[0], h.data, h.len);
    o = h.len;
    o = jw_int(&hdr[0], o, n);
    hdr[o] = 13; o++;
    hdr[o] = 10; o++;
    hdr[o] = 13; o++;
    hdr[o] = 10; o++;
    i32 k = lsp_cur;
    when !os(wasm) {
        if lsp_wthread_up[k] {
            mutex_lock(&lsp_wmx[k]);
            lsp_wq_put(k, &hdr[0], o);
            lsp_wq_put(k, payload, n);
            mutex_unlock(&lsp_wmx[k]);
            sem_signal(&lsp_wsem[k]);
            return;
        }
    }
    ignore plat_child_write(k, &hdr[0], o);
    ignore plat_child_write(k, payload, n);
}

// working directory with '/' separators; Windows hands back '\'
private i32 lsp_cwd_norm(u8* buf, i32 cap) {
    i32 n = plat_cwd(buf, cap);
    for i32 i = 0; i < n; i++ {
        if buf[i] == 92 { buf[i] = '/'; }
    }
    return n;
}

// already rooted: '/unix/path' or 'C:/windows/path'
private bool lsp_abs(str p) {
    if p.len > 0 && (p.data[0] == '/' || p.data[0] == 92) { return true; }
    return p.len > 2 && p.data[1] == ':';
}

// file URI for a workspace-relative or absolute path. A drive path
// needs the root slash the unix form already carries, so both land
// on the three-slash form the server expects
// (file:///C:/dir/f.mc, file:///dir/f.mc). An empty path gives the
// workspace root.
private void lsp_uri(u8* out, i64* on, str path) {
    noinit u8[PATH_MAX] abs;
    i32 an = 0;
    if lsp_abs(path) {
        if path.len < PATH_MAX {
            memcpy(&abs[0], path.data, path.len);
            an = path.len;
        }
    } else {
        an = lsp_cwd_norm(&abs[0], PATH_MAX);
        if path.len > 0 && an + 1 + path.len < PATH_MAX {
            abs[an] = '/';
            an++;
            memcpy(&abs[an], path.data, path.len);
            an += path.len;
        }
    }
    for i32 i = 0; i < an; i++ {
        if abs[i] == 92 { abs[i] = '/'; }
    }
    i64 o = 0;
    str pre = "file://";
    memcpy(out, pre.data, pre.len);
    o = pre.len;
    if an > 0 && abs[0] != '/' {
        out[o] = '/';
        o++;
    }
    memcpy(out + o, &abs[0], an);
    o += an;
    *on = o;
}

private void lsp_send_initialize() {
    noinit u8[PATH_MAX + 8] root;
    i64 rn = 0;
    lsp_uri(&root[0], &rn, "");
    u8* b = alloc<u8>(1024 + URI_ROOM);
    i64 o = 0;
    o = jw_raw(b, o, "{\"jsonrpc\":\"2.0\",\"id\":");
    o = jw_int(b, o, LSP_INIT_ID);
    o = jw_raw(b, o, ",\"method\":\"initialize\",\"params\":{\"processId\":null,\"rootUri\":\"");
    o = jw_esc(b, o, &root[0], rn);
    if lsp_cur == LSP_C {
        // clangd before 3.17 names the encoding offsetEncoding; it
        // gives the active parameter as offsets only when asked to
        o = jw_raw(b, o, "\",\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-8\",\"utf-16\"]},\"offsetEncoding\":[\"utf-8\",\"utf-16\"],\"textDocument\":{\"publishDiagnostics\":{},\"signatureHelp\":{\"signatureInformation\":{\"parameterInformation\":{\"labelOffsetSupport\":true}}}}}}}");
    } else {
        o = jw_raw(b, o, "\",\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-8\",\"utf-16\"]},\"textDocument\":{\"publishDiagnostics\":{}}}}}");
    }
    lsp_pos_utf16 = true;   // until the server says otherwise
    lsp_sync_incremental = false;
    lsp_send(b, o);
    free(b);
}

// The browser's server cannot walk a directory: no wasm host hands it
// one, so its workspace scan finds nothing and every file's closure is
// itself, which leaves cross-file definition unanswered until each file
// has been opened. It takes the list instead and indexes it the way the
// native scan does. Native servers walk the root themselves, so this
// goes only where it is needed.
when os(wasm) {

private void lsp_send_workspace_files() {
    pick_scan();
    i32 n = pick_file_count();
    if n <= 0 { return; }
    i64 cap = 256 + cast(i64, n) * (cast(i64, PATH_MAX) + URI_ROOM);
    u8* b = alloc<u8>(cap);
    i64 o = 0;
    o = jw_raw(b, o, "{\"jsonrpc\":\"2.0\",\"method\":\"minc/workspaceFiles\",\"params\":{\"files\":[");
    i32 sent = 0;
    for i32 i = 0; i < n; i++ {
        str p = pick_file_path(i);
        if !str_ends_with(p, ".mc") { continue; }
        if sent > 0 { o = jw_raw(b, o, ","); }
        noinit u8[PATH_MAX] u;
        i64 un = 0;
        lsp_uri(&u[0], &un, p);
        o = jw_raw(b, o, "\"");
        o = jw_esc(b, o, &u[0], un);
        o = jw_raw(b, o, "\"");
        sent++;
    }
    o = jw_raw(b, o, "]}}");
    if sent > 0 { lsp_send(b, o); }
    free(b);
    if lsp_trace { print("lsp: sent {} workspace files\n", sent); }
}

}

// the file's uri, escaped into the payload at o
private i64 lsp_jw_uri(u8* b, i64 o, str path) {
    noinit u8[PATH_MAX + 8] uri;
    i64 un = 0;
    lsp_uri(&uri[0], &un, path);
    return jw_esc(b, o, &uri[0], un);
}

// the languageId a didOpen names
private str lsp_language_id(str path) {
    if lsp_cur == LSP_MINC { return "minc"; }
    if str_ends_with(path, ".c") || str_ends_with(path, ".h") { return "c"; }
    return "cpp";
}

// full-text didOpen; text is the caller's copy of the buffer. True
// when it went out now: the server then has this text, and the edits
// recorded before it are in it.
bool lsp_did_open(str path, u8* text, i64 n) {
    if !lsp_ready || n > LSP_OPEN_MAX { return false; }
    if lsp_opened_idx(path) >= 0 { return false; }
    lsp_opened_add(path);
    u8* b = alloc<u8>(ESC_MAX * n + 512 + URI_ROOM);
    i64 o = 0;
    o = jw_raw(b, o, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"");
    o = lsp_jw_uri(b, o, path);
    o = jw_raw(b, o, "\",\"languageId\":\"");
    o = jw_raw(b, o, lsp_language_id(path));
    o = jw_raw(b, o, "\",\"version\":1,\"text\":\"");
    o = jw_esc(b, o, text, n);
    o = jw_raw(b, o, "\"}}}");
    lsp_send(b, o);
    free(b);
    return true;
}

// didChange, pushing the live buffer before a request; no-op until the
// file has had its didOpen. The recorded edits go as ranges when the
// server takes them; otherwise, or when the record cannot stand for
// the buffer, the whole text goes. Either way the record starts over.
void lsp_did_change(str path, u8* text, i64 n) {
    if !lsp_ready { return; }
    i32 di = lsp_opened_idx(path);
    if di < 0 { return; }
    bool ranged = lsp_sync_incremental && !lsp_rec_whole && lsp_rec_n > 0;
    if !ranged && n > LSP_OPEN_MAX {
        lsp_rec_reset();
        return;
    }
    lsp_open_ver[di]++;
    i64 room = 512 + URI_ROOM + ESC_MAX * n;
    if ranged { room = 512 + URI_ROOM + cast(i64, lsp_rec_n) * 128 + ESC_MAX * lsp_rec_len; }
    u8* b = alloc<u8>(room);
    i64 o = 0;
    o = jw_raw(b, o, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"");
    o = lsp_jw_uri(b, o, path);
    o = jw_raw(b, o, "\",\"version\":");
    o = jw_int(b, o, cast(i64, lsp_open_ver[di]));
    o = jw_raw(b, o, "},\"contentChanges\":[");
    if ranged {
        for i32 i = 0; i < lsp_rec_n; i++ {
            LspEdit* e = &lsp_rec[i];
            if i > 0 { o = jw_raw(b, o, ","); }
            o = jw_raw(b, o, "{\"range\":{\"start\":{\"line\":");
            o = jw_int(b, o, cast(i64, e.l0));
            o = jw_raw(b, o, ",\"character\":");
            o = jw_int(b, o, cast(i64, e.c0));
            o = jw_raw(b, o, "},\"end\":{\"line\":");
            o = jw_int(b, o, cast(i64, e.l1));
            o = jw_raw(b, o, ",\"character\":");
            o = jw_int(b, o, cast(i64, e.c1));
            o = jw_raw(b, o, "}},\"text\":\"");
            o = jw_esc(b, o, lsp_rec_text + e.toff, cast(i64, e.tlen));
            o = jw_raw(b, o, "\"}");
        }
        if lsp_trace { print("lsp: didChange with {} ranged edits\n", lsp_rec_n); }
    } else {
        o = jw_raw(b, o, "{\"text\":\"");
        o = jw_esc(b, o, text, n);
        o = jw_raw(b, o, "\"}");
        if lsp_trace { print("lsp: didChange with the whole text\n"); }
    }
    o = jw_raw(b, o, "]}}");
    lsp_send(b, o);
    free(b);
    lsp_rec_reset();
}

// how many documents the client believes the server has open; the set
// mirrors the server, so a stop clears it
i32 lsp_opened_count() {
    return lsp_nopen;
}

// The buffer for this file is gone. Tell the server and drop it from
// the opened set, so a later open sends a fresh didOpen with the file's
// current text rather than skipping it and letting ranged edits accrue
// against the server's stale copy. A no-op for a file never opened.
void lsp_did_close(str path) {
    // the closing buffer need not be the current server's: ask each
    i32 back = lsp_cur;
    for i32 k = 0; k < LSP_SERVERS; k++ {
        lsp_use(k);
        lsp_did_close_cur(path);
    }
    lsp_use(back);
}

private void lsp_did_close_cur(str path) {
    i32 di = lsp_opened_idx(path);
    if di < 0 { return; }
    if lsp_ready {
        u8* b = alloc<u8>(512 + URI_ROOM);
        i64 o = 0;
        o = jw_raw(b, o, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"");
        o = lsp_jw_uri(b, o, path);
        o = jw_raw(b, o, "\"}}}");
        lsp_send(b, o);
        free(b);
    }
    lsp_opened_remove(di);
    // the record's positions were against this file; the next buffer
    // reloads it anyway (buf_load invalidates), but do not leave edits
    // for a closed document pending
    if lsp_opened_idx_active(path) { lsp_rec_reset(); }
}

// whether the just-closed path is still the active buffer's; the record
// only matters when it is (this keeps the reset above from touching a
// record that belongs to a different, still-open buffer)
private bool lsp_opened_idx_active(str path) {
    return g_has_path && str_equal(str_from(&g_path[0], g_path_len), path);
}

// the whole document's tokens; one request in flight, a push during
// it asks again when the reply lands
void lsp_request_semantic(str path) {
    if !lsp_ready || !lsp_sem_ok { return; }
    if lsp_opened_idx(path) < 0 { return; }
    if lsp_sem_id != 0 {
        // hold the path too: the ask is usually for another buffer, and
        // asking again for the one that just answered would leave the
        // buffer on screen with no tokens at all
        lsp_sem_again = true;
        if path.len > PATH_MAX { path.len = PATH_MAX; }
        memcpy(&lsp_sem_next[0], path.data, path.len);
        lsp_sem_next_len = path.len;
        return;
    }
    lsp_sem_id = lsp_next_id;
    lsp_next_id++;
    if path.len > PATH_MAX { path.len = PATH_MAX; }
    memcpy(&lsp_sem_path[0], path.data, path.len);
    lsp_sem_path_len = path.len;
    u8* b = alloc<u8>(512 + URI_ROOM);
    i64 o = 0;
    o = jw_raw(b, o, "{\"jsonrpc\":\"2.0\",\"id\":");
    o = jw_int(b, o, cast(i64, lsp_sem_id));
    o = jw_raw(b, o, ",\"method\":\"textDocument/semanticTokens/full\",\"params\":{\"textDocument\":{\"uri\":\"");
    o = lsp_jw_uri(b, o, path);
    o = jw_raw(b, o, "\"}}}");
    lsp_send(b, o);
    free(b);
}

// the id of the token request in flight, 0 when none; a test answers
// it before it can watch for the next one
i32 lsp_sem_id_pending() {
    return lsp_sem_id;
}

void lsp_request_refs(str path, i32 line, i32 col) {
    if !lsp_ready { return; }
    lsp_ref_id = lsp_next_id;
    lsp_next_id++;
    lsp_send_pos_req(lsp_ref_id, "textDocument/references", path, line, col, "},\"context\":{\"includeDeclaration\":true}}}");
}

// workspace/symbol for the ctrl+t overlay. A new query supersedes the
// last: only the newest id is honored when the replies come back, so a
// slow answer to an old query cannot overwrite the current list.
void lsp_request_symbols(str query) {
    if !lsp_ready { return; }
    lsp_sym_id = lsp_next_id;
    lsp_next_id++;
    u8* b = alloc<u8>(256 + ESC_MAX * query.len);
    i64 o = 0;
    o = jw_raw(b, o, "{\"jsonrpc\":\"2.0\",\"id\":");
    o = jw_int(b, o, cast(i64, lsp_sym_id));
    o = jw_raw(b, o, ",\"method\":\"workspace/symbol\",\"params\":{\"query\":\"");
    o = jw_esc(b, o, query.data, cast(i64, query.len));
    o = jw_raw(b, o, "\"}}");
    if lsp_trace { print("lsp: symbols request {} query [{}]\n", lsp_sym_id, query); }
    lsp_send(b, o);
    free(b);
}

void lsp_request_complete(str path, i32 line, i32 col) {
    if !lsp_ready { return; }
    lsp_cmp_id = lsp_next_id;
    lsp_next_id++;
    lsp_send_pos_req(lsp_cmp_id, "textDocument/completion", path, line, col, "}}}");
}

// documentation for the symbol under the pointer. Distinct from the
// probe below, which asks for a definition only to decide whether the
// word is a link.
void lsp_request_hover(str path, i32 line, i32 col) {
    if !lsp_ready { return; }
    lsp_hovdoc_id = lsp_next_id;
    lsp_next_id++;
    lsp_send_pos_req(lsp_hovdoc_id, "textDocument/hover", path, line, col, "}}}");
}

// Signature help for the call the caret sits in. The reply carries the
// signature as one string plus the active parameter as a span into it,
// so the popup can mark which argument is being typed.
void lsp_request_sig(str path, i32 line, i32 col) {
    if !lsp_ready { return; }
    lsp_sig_id = lsp_next_id;
    lsp_next_id++;
    lsp_send_pos_req(lsp_sig_id, "textDocument/signatureHelp", path, line, col, "}}}");
}

// Hover contents arrive in three shapes: a string, an object carrying
// a value, or an array of either. Take the text out of whichever, and
// drop the code-fence lines a markdown reply wraps a signature in,
// since there is nothing here that would render them.
private i32 lsp_hover_text(JDoc* d, i32 node, u8* out, i32 cap) {
    if node < 0 || cap <= 0 { return 0; }
    u8 k = jd_kind(d, node);
    if k == J_STR { return cast(i32, jd_str_copy(d, node, out, cast(i64, cap))); }
    if k == J_OBJ {
        i32 v = jd_get(d, node, "value");
        if v < 0 { return 0; }
        return cast(i32, jd_str_copy(d, v, out, cast(i64, cap)));
    }
    if k == J_ARR {
        i32 o = 0;
        i32 nx = jd_first(d, node);
        while nx >= 0 && o + 2 < cap {
            if o > 0 {
                out[o] = '\n';
                o++;
            }
            o += lsp_hover_text(d, nx, out + o, cap - o);
            nx = jd_next(d, nx);
        }
        return o;
    }
    return 0;
}

// Drops the fence lines of a markdown reply and says which of the
// lines left were inside one: those are code, and the panel colors
// them as the editor does. `code` gets one flag per remaining line.
private i32 lsp_strip_fences(u8* s, i32 n, u8* code, i32 code_cap) {
    for i32 i = 0; i < code_cap; i++ { code[i] = 0; }
    i32 w = 0;
    i32 at = 0;
    i32 line = 0;
    bool inside = false;
    while at < n {
        i32 e = at;
        while e < n && s[e] != '\n' { e++; }
        bool fence = e - at >= 3 && s[at] == '`' && s[at + 1] == '`' && s[at + 2] == '`';
        if fence {
            inside = !inside;
        } else {
            if w > 0 {
                s[w] = '\n';
                w++;
            }
            for i32 i = at; i < e; i++ {
                s[w] = s[i];
                w++;
            }
            if line < code_cap && inside { code[line] = 1; }
            line++;
        }
        at = e + 1;
    }
    return w;
}

// definition probe for the hover link: same request, but the
// response only confirms or clears the link
void lsp_request_hoverdef(str path, i32 line, i32 col) {
    if !lsp_ready { return; }
    lsp_hover_id = lsp_next_id;
    lsp_next_id++;
    lsp_send_pos_req(lsp_hover_id, "textDocument/definition", path, line, col, "}}}");
}

// textDocument/definition at (line, character); the response lands
// in lsp_handle and navigates through ed_lsp_goto
void lsp_request_def(str path, i32 line, i32 col) {
    if !lsp_ready { return; }
    lsp_def_id = lsp_next_id;
    lsp_next_id++;
    lsp_send_pos_req(lsp_def_id, "textDocument/definition", path, line, col, "}}}");
}

// --- the call graph (calls.mc) -----------------------------------------
// prepareCallHierarchy at the caret, then incomingCalls and
// outgoingCalls on the item it names. Only the newest id of each is
// honored, so a reply to a center the view has left is dropped.

void lsp_request_call_prepare(str path, i32 line, i32 col) {
    if !lsp_ready { return; }
    lsp_cprep_id = lsp_next_id;
    lsp_next_id++;
    lsp_send_pos_req(lsp_cprep_id, "textDocument/prepareCallHierarchy", path, line, col, "}}}");
}

private i64 lsp_jw_range(u8* b, i64 o, i32 l0, i32 c0, i32 l1, i32 c1) {
    o = jw_raw(b, o, "{\"start\":{\"line\":");
    o = jw_int(b, o, cast(i64, l0));
    o = jw_raw(b, o, ",\"character\":");
    o = jw_int(b, o, cast(i64, c0));
    o = jw_raw(b, o, "},\"end\":{\"line\":");
    o = jw_int(b, o, cast(i64, l1));
    o = jw_raw(b, o, ",\"character\":");
    o = jw_int(b, o, cast(i64, c1));
    o = jw_raw(b, o, "}}");
    return o;
}

// incomingCalls (callers) or outgoingCalls (callees) on the item the
// view holds. The item is written back from its fields; the server
// finds the function by name, file and selection line.
void lsp_request_calls(bool incoming, CallItem* it) {
    if !lsp_ready { return; }
    i32 id = lsp_next_id;
    lsp_next_id++;
    if incoming { lsp_cin_id = id; } else { lsp_cout_id = id; }
    u8* b = alloc<u8>(1024 + URI_ROOM + 2 * CALL_NAME_MAX);
    i64 o = 0;
    o = jw_raw(b, o, "{\"jsonrpc\":\"2.0\",\"id\":");
    o = jw_int(b, o, cast(i64, id));
    if incoming {
        o = jw_raw(b, o, ",\"method\":\"callHierarchy/incomingCalls\",\"params\":{\"item\":{\"name\":\"");
    } else {
        o = jw_raw(b, o, ",\"method\":\"callHierarchy/outgoingCalls\",\"params\":{\"item\":{\"name\":\"");
    }
    o = jw_esc(b, o, &it.name[0], it.name_len);
    o = jw_raw(b, o, "\",\"kind\":12,\"uri\":\"");
    o = lsp_jw_uri(b, o, str_from(&it.path[0], it.path_len));
    o = jw_raw(b, o, "\",\"range\":");
    o = lsp_jw_range(b, o, it.l0, it.c0, it.l1, it.c1);
    o = jw_raw(b, o, ",\"selectionRange\":");
    o = lsp_jw_range(b, o, it.sl0, it.sc0, it.sl1, it.sc1);
    o = jw_raw(b, o, "}}}");
    lsp_send(b, o);
    free(b);
}

// a Range's start and end into four ints
private void lsp_range_of(JDoc* d, i32 r, i32* l0, i32* c0, i32* l1, i32* c1) {
    i32 st = jd_get(d, r, "start");
    i32 en = jd_get(d, r, "end");
    *l0 = cast(i32, jd_int(d, jd_get(d, st, "line")));
    *c0 = cast(i32, jd_int(d, jd_get(d, st, "character")));
    *l1 = cast(i32, jd_int(d, jd_get(d, en, "line")));
    *c1 = cast(i32, jd_int(d, jd_get(d, en, "character")));
}

// a CallHierarchyItem into it; false when a field it needs is missing
private bool lsp_call_item(JDoc* d, i32 j, CallItem* it) {
    if j < 0 || jd_kind(d, j) != J_OBJ { return false; }
    i32 jn = jd_get(d, j, "name");
    i32 ju = jd_get(d, j, "uri");
    i32 jr = jd_get(d, j, "range");
    i32 js = jd_get(d, j, "selectionRange");
    if jn < 0 || ju < 0 || jr < 0 || js < 0 { return false; }
    it.name_len = cast(i32, jd_str_copy(d, jn, &it.name[0], CALL_NAME_MAX));
    it.detail_len = 0;
    i32 jdt = jd_get(d, j, "detail");
    if jdt >= 0 && jd_kind(d, jdt) == J_STR {
        it.detail_len = cast(i32, jd_str_copy(d, jdt, &it.detail[0], CALL_NAME_MAX));
    }
    noinit u8[PATH_MAX] ptmp;
    str p = lsp_path_of(d, ju, &ptmp[0]);
    if p.len == 0 || p.len > PATH_MAX { return false; }
    memcpy(&it.path[0], p.data, p.len);
    it.path_len = p.len;
    lsp_range_of(d, jr, &it.l0, &it.c0, &it.l1, &it.c1);
    lsp_range_of(d, js, &it.sl0, &it.sc0, &it.sl1, &it.sc1);
    return true;
}

// true when the reply is the server's "index not ready" error
private bool lsp_not_ready(JDoc* d, i32 root) {
    i32 je = jd_get(d, root, "error");
    return je >= 0 && jd_int(d, jd_get(d, je, "code")) == LSP_CONTENT_MODIFIED;
}

// the rows of an incomingCalls or outgoingCalls reply
private void lsp_calls_from(JDoc* d, i32 root, i32 arr, bool incoming) {
    if lsp_not_ready(d, root) {
        calls_rows_failed(incoming, true);
        return;
    }
    calls_rows_begin(incoming);
    i32 n = 0;
    if arr >= 0 && jd_kind(d, arr) == J_ARR { n = jd_len(d, arr); }
    i32 nx = jd_first(d, arr);
    CallItem it;
    for i32 i = 0; i < n && nx >= 0; i++ {
        i32 e = nx;
        nx = jd_next(d, nx);
        if jd_kind(d, e) != J_OBJ { continue; }
        i32 ji = jd_get(d, e, "from");
        if !incoming { ji = jd_get(d, e, "to"); }
        if !lsp_call_item(d, ji, &it) { continue; }
        // the first site, for the card; the count, for the edge
        i32 sites = 0;
        i32 site_line = -1;
        i32 fr = jd_get(d, e, "fromRanges");
        if fr >= 0 && jd_kind(d, fr) == J_ARR {
            sites = jd_len(d, fr);
            i32 f0 = jd_first(d, fr);
            if f0 >= 0 {
                i32 st = jd_get(d, f0, "start");
                site_line = cast(i32, jd_int(d, jd_get(d, st, "line")));
            }
        }
        calls_row_add(incoming, &it, sites, site_line);
        // every site, for the center to mark a callee's calls
        i32 fx = jd_first(d, fr);
        for i32 k = 0; k < sites && fx >= 0; k++ {
            i32 l0 = 0;
            i32 c0 = 0;
            i32 l1 = 0;
            i32 c1 = 0;
            lsp_range_of(d, fx, &l0, &c0, &l1, &c1);
            calls_row_site(incoming, l0, c0, c1);
            fx = jd_next(d, fx);
        }
    }
    calls_rows_done(incoming);
}

// a request at a position in a file; `tail` closes the params after
// the position, with whatever the method puts there
private void lsp_send_pos_req(i32 id, str method, str path, i32 line, i32 col, str tail) {
    u8* b = alloc<u8>(512 + URI_ROOM);
    i64 o = 0;
    o = jw_raw(b, o, "{\"jsonrpc\":\"2.0\",\"id\":");
    o = jw_int(b, o, cast(i64, id));
    o = jw_raw(b, o, ",\"method\":\"");
    o = jw_raw(b, o, method);
    o = jw_raw(b, o, "\",\"params\":{\"textDocument\":{\"uri\":\"");
    o = lsp_jw_uri(b, o, path);
    o = jw_raw(b, o, "\"},\"position\":{\"line\":");
    o = jw_int(b, o, cast(i64, line));
    o = jw_raw(b, o, ",\"character\":");
    o = jw_int(b, o, cast(i64, col));
    o = jw_raw(b, o, tail);
    lsp_send(b, o);
    free(b);
}

// --- incoming --------------------------------------------------------

// a reply's Location array into the references view: references, and
// a definition with more than one answer
private void lsp_refs_from(JDoc* d, i32 arr) {
    i32 n = 0;
    if arr >= 0 && jd_kind(d, arr) == J_ARR { n = jd_len(d, arr); }
    search_refs_begin();
    i32 nx = jd_first(d, arr);
    for i32 i = 0; i < n && nx >= 0; i++ {
        i32 loc = nx;
        nx = jd_next(d, nx);
        if jd_kind(d, loc) != J_OBJ { continue; }
        i32 juri = jd_get(d, loc, "uri");
        i32 st = jd_get(d, jd_get(d, loc, "range"), "start");
        if juri < 0 || st < 0 { continue; }
        noinit u8[PATH_MAX] ptmp;
        str path = lsp_path_of(d, juri, &ptmp[0]);
        search_refs_add(path, cast(i32, jd_int(d, jd_get(d, st, "line"))),
            cast(i32, jd_int(d, jd_get(d, st, "character"))));
    }
    ed_refs_done();
}

private void lsp_enqueue(i32 k, u8* p, i64 n) {
    if !lsp_mx_ready {
        mutex_init(&lsp_mx);
        lsp_mx_ready = true;
    }
    mutex_lock(&lsp_mx);
    if lsp_q_len + n + 8 > lsp_q_cap {
        i64 ncap = lsp_q_cap * 2 + n + 65536;
        u8* nq = alloc<u8>(ncap);
        if lsp_q != null {
            memcpy(nq, lsp_q, lsp_q_len);
            free(lsp_q);
        }
        lsp_q = nq;
        lsp_q_cap = ncap;
    }
    *cast(i32*, lsp_q + lsp_q_len) = cast(i32, n);
    *cast(i32*, lsp_q + lsp_q_len + 4) = k;
    memcpy(lsp_q + lsp_q_len + 8, p, n);
    lsp_q_len += n + 8;
    mutex_unlock(&lsp_mx);
    plat_wake();
}

// drop the first `off` accumulated bytes of slot k (overlapping, forward)
private void lsp_acc_shift(i32 k, i64 off) {
    u8* acc = lsp_acc[k];
    i64 rest = lsp_acc_len[k] - off;
    for i64 i = 0; i < rest; i++ { acc[i] = acc[off + i]; }
    lsp_acc_len[k] = rest;
}

// the minc server's bytes, as the browser's page and the tests push them
void lsp_feed(u8* p, i64 n) {
    lsp_feed_from(LSP_MINC, p, n);
}

// bytes off slot k's stdout: accumulate, split frames, queue the
// payloads. Reader thread (or a test) calls this.
void lsp_feed_from(i32 k, u8* p, i64 n) {
    if lsp_acc_len[k] + n > lsp_acc_cap[k] {
        i64 ncap = lsp_acc_cap[k] * 2 + n + 65536;
        if ncap > LSP_ACC_MAX { ncap = LSP_ACC_MAX; }
        if lsp_acc_len[k] + n > ncap { return; }   // malformed peer; drop
        u8* na = alloc<u8>(ncap);
        if lsp_acc[k] != null {
            memcpy(na, lsp_acc[k], lsp_acc_len[k]);
            free(lsp_acc[k]);
        }
        lsp_acc[k] = na;
        lsp_acc_cap[k] = ncap;
    }
    memcpy(lsp_acc[k] + lsp_acc_len[k], p, n);
    lsp_acc_len[k] += n;
    while true {
        u8* acc = lsp_acc[k];
        i64 alen = lsp_acc_len[k];
        // header terminator
        i64 he = -1;
        for i64 i = 0; i + 3 < alen; i++ {
            if acc[i] == 13 && acc[i + 1] == 10
                && acc[i + 2] == 13 && acc[i + 3] == 10 {
                he = i;
                break;
            }
        }
        if he < 0 { return; }
        // Content-Length within the header block
        i64 clen = -1;
        str key = "Content-Length:";
        for i64 i = 0; i + key.len < he; i++ {
            bool m = true;
            for i32 c = 0; c < key.len; c++ {
                if acc[i + c] != key.data[c] { m = false; break; }
            }
            if m {
                i64 j = i + key.len;
                while j < he && acc[j] == ' ' { j++; }
                clen = 0;
                while j < he && acc[j] >= '0' && acc[j] <= '9' {
                    clen = clen * 10 + cast(i64, acc[j] - '0');
                    j++;
                }
                break;
            }
        }
        i64 body = he + 4;
        if clen < 0 {
            // header without a length: drop it
            lsp_acc_shift(k, body);
            continue;
        }
        if body + clen > alen { return; }   // frame incomplete
        lsp_enqueue(k, acc + body, clen);
        lsp_acc_shift(k, body + clen);
    }
}

private void lsp_reader(void* arg) {
    i32 k = *cast(i32*, arg);
    noinit u8[4096] buf;
    while true {
        i64 n = plat_child_read(k, &buf[0], 4096);
        if n <= 0 { break; }
        lsp_feed_from(k, &buf[0], n);
    }
}

// --- diagnostics store -----------------------------------------------

private LspDiagSet* lsp_set_find(str path) {
    for i32 i = 0; i < lsp_nsets; i++ {
        if lsp_sets[i].path_len == path.len
            && str_equal(str_from(&lsp_sets[i].path[0], path.len), path) {
            return &lsp_sets[i];
        }
    }
    return null;
}

private LspDiagSet* lsp_set_for(str path) {
    LspDiagSet* found = lsp_set_find(path);
    if found != null { return found; }
    if lsp_nsets == LSP_MAX_DIAG_FILES { return &lsp_sets[0]; }
    LspDiagSet* s = &lsp_sets[lsp_nsets];
    lsp_nsets++;
    memcpy(&s.path[0], path.data, path.len);
    s.path_len = path.len;
    if s.items == null { s.items = alloc<LspDiag>(LSP_MAX_DIAGS); }
    return s;
}

i32 lsp_diag_count(str path) {
    LspDiagSet* s = lsp_set_find(path);
    if s == null { return 0; }
    return s.count;
}

LspDiag* lsp_diag(str path, i32 i) {
    LspDiagSet* s = lsp_set_find(path);
    if s == null { return null; }
    return &s.items[i];
}

str lsp_diag_msg(str path, i32 i) {
    LspDiagSet* s = lsp_set_find(path);
    if s == null { return ""; }
    LspDiag* d = &s.items[i];
    return str_from(s.msgs + d.msg_off, d.msg_len);
}

// the path a reply's uri names, decoded into `tmp` (PATH_MAX bytes)
private str lsp_path_of(JDoc* d, i32 juri, u8* tmp) {
    noinit u8[PATH_MAX + 8] utmp;
    i64 un = jd_str_copy(d, juri, &utmp[0], PATH_MAX + 8);
    str path = lsp_uri_path(str_from(&utmp[0], cast(i32, un)), tmp);
    if path.data != tmp {
        // a uri too short to be one comes back as it is; it has to
        // outlive this frame
        memcpy(tmp, path.data, path.len);
        path = str_from(tmp, path.len);
    }
    return path;
}

// The workspace prefix, byte for byte, except that a Windows drive
// letter can come back in either case.
private bool lsp_prefix_eq(str a, str b) {
    if a.len != b.len { return false; }
    for i32 i = 0; i < a.len; i++ {
        u8 x = a.data[i];
        u8 y = b.data[i];
        if i == 0 {
            if x >= 'a' && x <= 'z' { x = cast(u8, x - 32); }
            if y >= 'a' && y <= 'z' { y = cast(u8, y - 32); }
        }
        if x != y { return false; }
    }
    return true;
}

// uri back to a workspace-relative path. Percent-escapes are decoded
// (the server sends the drive colon as %3A), separators normalized,
// and the file:/// root slash dropped ahead of a drive letter.
// tmp holds the decoded path, so it must have PATH_MAX bytes.
private str lsp_uri_path(str uri, u8* tmp) {
    str pre = "file://";
    if uri.len <= pre.len { return uri; }
    i32 o = 0;
    for i32 i = pre.len; i < uri.len && o < PATH_MAX; i++ {
        u8 c = uri.data[i];
        if c == '%' && i + 2 < uri.len {
            i32 h = jd_hex_digit(uri.data[i + 1]);
            i32 l = jd_hex_digit(uri.data[i + 2]);
            if h >= 0 && l >= 0 {
                c = cast(u8, h * 16 + l);
                i += 2;
            }
        }
        if c == 92 { c = '/'; }
        tmp[o] = c;
        o++;
    }
    i32 s = 0;
    if o > 2 && tmp[0] == '/' && tmp[2] == ':' { s = 1; }
    str p = str_from(tmp + s, o - s);
    noinit u8[PATH_MAX] cwd;
    i32 cn = lsp_cwd_norm(&cwd[0], PATH_MAX);
    if cn > 0 && p.len > cn + 1 && lsp_prefix_eq(str_from(p.data, cn), str_from(&cwd[0], cn)) && p.data[cn] == '/' {
        return str_from(p.data + cn + 1, p.len - cn - 1);
    }
    return p;
}

// FNV-1a over a file's diagnostics, messages included. The server
// publishes after every change, most often the same set again.
private const u64 LSP_FNV_BASIS = (cast(u64, 0xCBF29CE4) << 32) | cast(u64, 0x84222325);
private const u64 LSP_FNV_PRIME = 1099511628211;

private u64 lsp_diag_digest(LspDiagSet* s) {
    u64 h = LSP_FNV_BASIS;
    h = (h ^ cast(u64, s.count)) * LSP_FNV_PRIME;
    for i32 i = 0; i < s.count; i++ {
        LspDiag* g = &s.items[i];
        h = (h ^ cast(u64, g.line)) * LSP_FNV_PRIME;
        h = (h ^ cast(u64, g.col0)) * LSP_FNV_PRIME;
        h = (h ^ cast(u64, g.line1)) * LSP_FNV_PRIME;
        h = (h ^ cast(u64, g.col1)) * LSP_FNV_PRIME;
        h = (h ^ cast(u64, g.severity)) * LSP_FNV_PRIME;
        for i32 k = 0; k < g.msg_len; k++ {
            h = (h ^ cast(u64, s.msgs[g.msg_off + k])) * LSP_FNV_PRIME;
        }
    }
    return h;
}

private void lsp_on_diagnostics(JDoc* d, i32 params) {
    i32 juri = jd_get(d, params, "uri");
    if juri < 0 { return; }
    noinit u8[PATH_MAX] ptmp;
    str path = lsp_path_of(d, juri, &ptmp[0]);
    if lsp_trace {
        i32 jl = jd_get(d, params, "diagnostics");
        i32 nd = 0;
        if jl >= 0 && jd_kind(d, jl) == J_ARR { nd = jd_len(d, jl); }
        print("lsp: {} diagnostics for {}\n", nd, path);
    }
    if path.len >= PATH_MAX { return; }
    if lsp_trace { print("lsp: publish for '{}'\n", path); }
    LspDiagSet* s = lsp_set_for(path);
    u64 before = lsp_diag_digest(s);
    s.count = 0;
    i64 mo = 0;
    i32 arr = jd_get(d, params, "diagnostics");
    i32 n = jd_len(d, arr);
    i32 nx = jd_first(d, arr);
    for i32 i = 0; i < n && s.count < LSP_MAX_DIAGS; i++ {
        if nx < 0 { break; }
        i32 e = nx;
        nx = jd_next(d, nx);
        i32 rng = jd_get(d, e, "range");
        i32 st = jd_get(d, rng, "start");
        i32 en = jd_get(d, rng, "end");
        i32 jm = jd_get(d, e, "message");
        i32 sev = 1;
        i32 js = jd_get(d, e, "severity");
        if lsp_trace {
            print("lsp: diag {} at line {}\n", i, jd_int(d, jd_get(d, st, "line")));
        }
        if js >= 0 { sev = cast(i32, jd_int(d, js)); }
        // message into the set's arena
        i64 need = 0;
        if jm >= 0 { need = cast(i64, d.nodes[jm].b); }
        if mo + need + 8 > s.msgs_cap {
            i64 ncap = s.msgs_cap * 2 + need + 4096;
            u8* na = alloc<u8>(ncap);
            if s.msgs != null {
                memcpy(na, s.msgs, mo);
                free(s.msgs);
            }
            s.msgs = na;
            s.msgs_cap = ncap;
        }
        i64 ml = jd_str_copy(d, jm, s.msgs + mo, s.msgs_cap - mo);
        s.items[s.count] = LspDiag{
            cast(i32, jd_int(d, jd_get(d, st, "line"))),
            cast(i32, jd_int(d, jd_get(d, st, "character"))),
            cast(i32, jd_int(d, jd_get(d, en, "line"))),
            cast(i32, jd_int(d, jd_get(d, en, "character"))),
            sev, cast(i32, mo), cast(i32, ml) };
        mo += ml;
        s.count++;
    }
    if lsp_diag_digest(s) != before { plat_damage(); }
}

// A completion item from a server other than minc's. The label shows
// the whole declaration ("name(int a, int b)"); the text that goes in
// is the edit's, else insertText, else filterText. The server ranks
// its list, so every item keeps the arrival order.
private void lsp_cmp_add_other(JDoc* d, i32 e, str label, str detail) {
    noinit u8[512] ins;
    i64 in_n = -1;
    i32 te = jd_get(d, e, "textEdit");
    if te >= 0 && jd_kind(d, te) == J_OBJ {
        i32 nt = jd_get(d, te, "newText");
        if nt >= 0 && jd_kind(d, nt) == J_STR { in_n = jd_str_copy(d, nt, &ins[0], 512); }
    }
    if in_n < 0 {
        i32 it = jd_get(d, e, "insertText");
        if it < 0 || jd_kind(d, it) != J_STR { it = jd_get(d, e, "filterText"); }
        if it >= 0 && jd_kind(d, it) == J_STR { in_n = jd_str_copy(d, it, &ins[0], 512); }
    }
    while label.len > 0 && label.data[0] == ' ' { label = str_from(label.data + 1, label.len - 1); }
    if in_n <= 0 {
        cmp_add(label, detail, CMP_PRIO_NONE);
        return;
    }
    cmp_add_shown(str_from(&ins[0], cast(i32, in_n)), label, detail, CMP_PRIO_NONE);
}

private void lsp_handle(u8* p, i64 n) {
    JDoc d;
    i32 root = json_parse(&d, p, n);
    if root < 0 {
        json_free(&d);
        return;
    }
    i32 jid = jd_get(&d, root, "id");
    i32 jres = jd_get(&d, root, "result");
    if jid >= 0 && jres >= 0 && jd_int(&d, jid) == LSP_INIT_ID && !lsp_ready {
        // whichever encoding the server picked; anything but utf-8,
        // including saying nothing, means utf-16
        i32 caps = jd_get(&d, jres, "capabilities");
        if caps >= 0 {
            i32 pe = jd_get(&d, caps, "positionEncoding");
            // clangd before 3.17 answers beside the capabilities
            if pe < 0 { pe = jd_get(&d, jres, "offsetEncoding"); }
            if pe >= 0 && jd_kind(&d, pe) == J_STR && str_equal(jd_str(&d, pe), "utf-8") {
                lsp_pos_utf16 = false;
            }
            i32 chp = jd_get(&d, caps, "callHierarchyProvider");
            lsp_calls_ok = chp >= 0 && (jd_kind(&d, chp) == J_OBJ
                || (jd_kind(&d, chp) == J_BOOL && jd_bool(&d, chp)));
            // the token legend, in the server's index order. Only minc
            // files take tokens: the legend is one for the editor, and
            // C keeps the lexer's colors.
            lsp_sem_ok = false;
            i32 sp = jd_get(&d, caps, "semanticTokensProvider");
            if lsp_cur == LSP_MINC { sem_legend_reset(); } else { sp = -1; }
            if sp >= 0 && jd_kind(&d, sp) == J_OBJ {
                i32 lg = jd_get(&d, sp, "legend");
                i32 tt = -1;
                if lg >= 0 { tt = jd_get(&d, lg, "tokenTypes"); }
                if tt >= 0 && jd_kind(&d, tt) == J_ARR {
                    i32 nt = jd_len(&d, tt);
                    i32 e = jd_first(&d, tt);
                    for i32 i = 0; i < nt && e >= 0; i++ {
                        if jd_kind(&d, e) == J_STR { sem_legend_add(jd_str(&d, e)); }
                        e = jd_next(&d, e);
                    }
                    lsp_sem_ok = true;
                }
            }
            // the sync kind, in either of its two shapes; incremental
            // is taken only with byte columns
            i32 ts = jd_get(&d, caps, "textDocumentSync");
            if ts >= 0 {
                i32 ch = ts;
                if jd_kind(&d, ts) == J_OBJ { ch = jd_get(&d, ts, "change"); }
                if ch >= 0 && jd_int(&d, ch) == 2 && !lsp_pos_utf16 {
                    lsp_sync_incremental = true;
                }
            }
        }
        if lsp_trace {
            print("lsp: positions are utf-{}\n", lsp_pos_utf16 ? 16 : 8);
            if lsp_sync_incremental { print("lsp: incremental sync\n"); }
        }
        str notif = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}";
        lsp_send(notif.data, notif.len);
        lsp_ready = true;
        if lsp_trace { print("lsp: ready\n"); }
        when os(wasm) { lsp_send_workspace_files(); }
        ed_lsp_sync();
        json_free(&d);
        return;
    }
    if jid >= 0 && lsp_sig_id != 0 && jd_int(&d, jid) == lsp_sig_id {
        lsp_sig_id = 0;
        // signatures[activeSignature].label, and the active parameter
        // as [start, end] byte offsets into that label
        i32 sigs = -1;
        if jres >= 0 && jd_kind(&d, jres) == J_OBJ { sigs = jd_get(&d, jres, "signatures"); }
        i32 si = cast(i32, jd_int(&d, jd_get(&d, jres, "activeSignature")));
        i32 sig = -1;
        if sigs >= 0 && jd_kind(&d, sigs) == J_ARR {
            sig = jd_first(&d, sigs);
            for i32 k = 0; k < si && sig >= 0; k++ { sig = jd_next(&d, sig); }
        }
        if sig < 0 || jd_kind(&d, sig) != J_OBJ {
            ed_sig_hide();
            json_free(&d);
            return;
        }
        noinit u8[SIG_TEXT_MAX] sb;
        i64 sn = jd_str_copy(&d, jd_get(&d, sig, "label"), &sb[0], SIG_TEXT_MAX);
        i32 pi = cast(i32, jd_int(&d, jd_get(&d, jres, "activeParameter")));
        i32 p0 = 0;
        i32 p1 = 0;
        i32 ps = jd_get(&d, sig, "parameters");
        if ps >= 0 && jd_kind(&d, ps) == J_ARR {
            i32 e = jd_first(&d, ps);
            for i32 k = 0; k < pi && e >= 0; k++ { e = jd_next(&d, e); }
            if e >= 0 {
                i32 lab = jd_get(&d, e, "label");
                if lab >= 0 && jd_kind(&d, lab) == J_ARR {
                    p0 = cast(i32, jd_int(&d, jd_at(&d, lab, 0)));
                    p1 = cast(i32, jd_int(&d, jd_at(&d, lab, 1)));
                } else if lab >= 0 && jd_kind(&d, lab) == J_STR {
                    // a parameter named by its text: its first place in
                    // the signature after the opening parenthesis
                    str pl = jd_str(&d, lab);
                    i32 open_at = 0;
                    while open_at < cast(i32, sn) && sb[open_at] != '(' { open_at++; }
                    for i32 at = open_at; pl.len > 0 && at + pl.len <= cast(i32, sn); at++ {
                        if str_equal(str_from(&sb[at], pl.len), pl) {
                            p0 = at;
                            p1 = at + pl.len;
                            break;
                        }
                    }
                }
            }
        }
        ed_sig_show(str_from(&sb[0], cast(i32, sn)), p0, p1);
        json_free(&d);
        return;
    }
    if jid >= 0 && lsp_sem_id != 0 && jd_int(&d, jid) == lsp_sem_id {
        lsp_sem_id = 0;
        str sp = str_from(&lsp_sem_path[0], lsp_sem_path_len);
        i32 data = -1;
        if jres >= 0 && jd_kind(&d, jres) == J_OBJ { data = jd_get(&d, jres, "data"); }
        // five integers per token, positions relative to the one before
        sem_begin(sp);
        i32 got = 0;
        if data >= 0 && jd_kind(&d, data) == J_ARR {
            i32 line = 0;
            i32 col = 0;
            // walked by sibling, five at a time: this array is five
            // integers per token and runs to six figures on a large
            // file, where indexing it would be quadratic
            i32 c0 = jd_first(&d, data);
            while c0 >= 0 {
                i32 c1 = jd_next(&d, c0);
                i32 c2 = jd_next(&d, c1);
                i32 c3 = jd_next(&d, c2);
                i32 c4 = jd_next(&d, c3);
                if c4 < 0 { break; }
                i64 dl = jd_int(&d, c0);
                i64 dc = jd_int(&d, c1);
                i64 len = jd_int(&d, c2);
                i64 ty = jd_int(&d, c3);
                if dl < 0 || dc < 0 || len <= 0 || ty < 0 || dl > 100000000 || dc > 100000000 {
                    sem_add(-1, 0, 0, 0);   // discredits the reply
                    break;
                }
                if dl > 0 {
                    line += cast(i32, dl);
                    col = cast(i32, dc);
                } else {
                    col += cast(i32, dc);
                }
                i32 bcol = col;
                if lsp_pos_utf16 { bcol = cast(i32, lsp_byte_of_col(line, col)); }
                sem_add(line, bcol, cast(i32, len), cast(i32, ty));
                got++;
                c0 = jd_next(&d, c4);
            }
        }
        bool sem_changed = sem_end();
        if lsp_trace { print("lsp: {} semantic tokens for {}\n", got, sp); }
        if sem_changed { plat_damage(); }
        if lsp_sem_again {
            lsp_sem_again = false;
            lsp_request_semantic(str_from(&lsp_sem_next[0], lsp_sem_next_len));
        }
        json_free(&d);
        return;
    }
    if jid >= 0 && lsp_ref_id != 0 && jd_int(&d, jid) == lsp_ref_id {
        lsp_ref_id = 0;
        lsp_refs_from(&d, jres);
        json_free(&d);
        return;
    }
    if jid >= 0 && lsp_cprep_id != 0 && jd_int(&d, jid) == lsp_cprep_id {
        lsp_cprep_id = 0;
        CallItem it;
        bool got = false;
        if jres >= 0 && jd_kind(&d, jres) == J_ARR && jd_len(&d, jres) > 0 {
            got = lsp_call_item(&d, jd_first(&d, jres), &it);
        }
        if got {
            calls_center_found(&it);
        } else {
            calls_center_missing(lsp_not_ready(&d, root));
        }
        json_free(&d);
        return;
    }
    if jid >= 0 && lsp_cin_id != 0 && jd_int(&d, jid) == lsp_cin_id {
        lsp_cin_id = 0;
        lsp_calls_from(&d, root, jres, true);
        json_free(&d);
        return;
    }
    if jid >= 0 && lsp_cout_id != 0 && jd_int(&d, jid) == lsp_cout_id {
        lsp_cout_id = 0;
        lsp_calls_from(&d, root, jres, false);
        json_free(&d);
        return;
    }
    if jid >= 0 && lsp_sym_id != 0 && jd_int(&d, jid) == lsp_sym_id {
        lsp_sym_id = 0;
        // SymbolInformation: name, kind, location{uri, range}. Anything
        // without a string name and an object location is skipped.
        i32 n = 0;
        if jres >= 0 && jd_kind(&d, jres) == J_ARR { n = jd_len(&d, jres); }
        sym_begin();
        i32 nx = jd_first(&d, jres);
        for i32 i = 0; i < n && nx >= 0; i++ {
            i32 it = nx;
            nx = jd_next(&d, nx);
            if jd_kind(&d, it) != J_OBJ { continue; }
            i32 jn = jd_get(&d, it, "name");
            i32 loc = jd_get(&d, it, "location");
            if jn < 0 || jd_kind(&d, jn) != J_STR { continue; }
            if loc < 0 || jd_kind(&d, loc) != J_OBJ { continue; }
            i32 juri = jd_get(&d, loc, "uri");
            i32 st = jd_get(&d, jd_get(&d, loc, "range"), "start");
            if juri < 0 || st < 0 { continue; }
            noinit u8[PATH_MAX] ptmp;
            str path = lsp_path_of(&d, juri, &ptmp[0]);
            sym_add(jd_str(&d, jn), path,
                cast(i32, jd_int(&d, jd_get(&d, st, "line"))),
                cast(i32, jd_int(&d, jd_get(&d, st, "character"))));
        }
        sym_end();
        if lsp_trace { print("lsp: symbols response, {} items, query [{}]\n", n, sym_query()); }
        json_free(&d);
        return;
    }
    if jid >= 0 && lsp_cmp_id != 0 && jd_int(&d, jid) == lsp_cmp_id {
        lsp_cmp_id = 0;
        // the reply is either the item array or a list wrapping one
        i32 items = jres;
        if jres >= 0 && jd_kind(&d, jres) == J_OBJ {
            items = jd_get(&d, jres, "items");
        }
        i32 count = 0;
        if items >= 0 && jd_kind(&d, items) == J_ARR { count = jd_len(&d, items); }
        // A list the server cut short is asked for again as the word
        // grows, since narrowing it here would miss what was cut.
        bool incomplete = false;
        if jres >= 0 && jd_kind(&d, jres) == J_OBJ {
            i32 ji = jd_get(&d, jres, "isIncomplete");
            incomplete = ji >= 0 && jd_kind(&d, ji) == J_BOOL && jd_bool(&d, ji);
        }
        ed_complete_begin(lsp_cur == LSP_MINC, incomplete);
        noinit u8[512] lab;
        noinit u8[512] det;
        i32 nx = jd_first(&d, items);
        for i32 i = 0; i < count && i < CMP_MAX_ITEMS && nx >= 0; i++ {
            i32 e = nx;
            nx = jd_next(&d, nx);
            if jd_kind(&d, e) != J_OBJ { continue; }
            i32 jl = jd_get(&d, e, "label");
            if jl < 0 { continue; }
            i64 ln = jd_str_copy(&d, jl, &lab[0], 512);
            i64 dn = 0;
            i32 jd2 = jd_get(&d, e, "detail");
            if jd2 >= 0 { dn = jd_str_copy(&d, jd2, &det[0], 512); }
            if lsp_cur != LSP_MINC {
                lsp_cmp_add_other(&d, e, str_from(&lab[0], cast(i32, ln)), str_from(&det[0], cast(i32, dn)));
                continue;
            }
            // the leading digits of sortText are the scope rank; an
            // item without one goes after every labeled item
            i32 prio = CMP_PRIO_NONE;
            i32 js = jd_get(&d, e, "sortText");
            if js >= 0 && jd_kind(&d, js) == J_STR {
                str st = jd_str(&d, js);
                i32 v = 0;
                i32 nd = 0;
                while nd < st.len && nd < 9 && st.data[nd] >= '0' && st.data[nd] <= '9' {
                    v = v * 10 + cast(i32, st.data[nd] - '0');
                    nd++;
                }
                if nd > 0 { prio = v; }
            }
            cmp_add(str_from(&lab[0], cast(i32, ln)),
                str_from(&det[0], cast(i32, dn)), prio);
        }
        cmp_end();
        json_free(&d);
        return;
    }
    if jid >= 0 && lsp_hovdoc_id != 0 && jd_int(&d, jid) == lsp_hovdoc_id {
        lsp_hovdoc_id = 0;
        noinit u8[HOVER_TEXT_MAX] hb;
        noinit u8[HOVER_LINES_MAX] hcode;
        i32 hn = 0;
        if jres >= 0 { hn = lsp_hover_text(&d, jd_get(&d, jres, "contents"), &hb[0], HOVER_TEXT_MAX); }
        hn = lsp_strip_fences(&hb[0], hn, &hcode[0], HOVER_LINES_MAX);
        ed_hover_show(str_from(&hb[0], hn), &hcode[0]);
        json_free(&d);
        return;
    }
    if jid >= 0 && lsp_hover_id != 0 && jd_int(&d, jid) == lsp_hover_id {
        lsp_hover_id = 0;
        i32 loc = jres;
        if jres >= 0 && jd_kind(&d, jres) == J_ARR { loc = jd_at(&d, jres, 0); }
        ed_link_confirm(loc >= 0 && jd_kind(&d, loc) == J_OBJ);
        json_free(&d);
        return;
    }
    if jid >= 0 && lsp_def_id != 0 && jd_int(&d, jid) == lsp_def_id {
        lsp_def_id = 0;
        if lsp_trace { print("lsp: definition response\n"); }
        // More than one definition means the file belongs to more than
        // one program - a module shared by the editor and the headless
        // test, say, where each program has its own. Jumping into
        // whichever came first hides the others, so list them instead.
        if jres >= 0 && jd_kind(&d, jres) == J_ARR && jd_len(&d, jres) > 1 {
            lsp_refs_from(&d, jres);
            json_free(&d);
            return;
        }
        i32 loc = jres;
        if jres >= 0 && jd_kind(&d, jres) == J_ARR { loc = jd_at(&d, jres, 0); }
        if loc >= 0 && jd_kind(&d, loc) == J_OBJ {
            i32 juri = jd_get(&d, loc, "uri");
            i32 rng = jd_get(&d, loc, "range");
            i32 st = jd_get(&d, rng, "start");
            if juri >= 0 && st >= 0 {
                noinit u8[PATH_MAX] ptmp;
                str path = lsp_path_of(&d, juri, &ptmp[0]);
                ed_lsp_goto(path,
                    cast(i32, jd_int(&d, jd_get(&d, st, "line"))),
                    cast(i32, jd_int(&d, jd_get(&d, st, "character"))));
                json_free(&d);
                return;
            }
        }
        ed_status("no definition found");
        plat_damage();
        json_free(&d);
        return;
    }
    i32 jm = jd_get(&d, root, "method");
    if jm >= 0 && str_equal(jd_str(&d, jm), "textDocument/publishDiagnostics") {
        i32 params = jd_get(&d, root, "params");
        if params >= 0 { lsp_on_diagnostics(&d, params); }
    }
    json_free(&d);
}

// main thread, from app_wake: drain the queue and dispatch
void lsp_pump() {
    if !lsp_mx_ready { return; }
    mutex_lock(&lsp_mx);
    u8* q = lsp_q;
    i64 qn = lsp_q_len;
    lsp_q = null;
    lsp_q_len = 0;
    lsp_q_cap = 0;
    mutex_unlock(&lsp_mx);
    if q == null { return; }
    i64 o = 0;
    while o + 8 <= qn {
        i32 n = *cast(i32*, q + o);
        i32 k = *cast(i32*, q + o + 4);
        o += 8;
        if o + n > qn { break; }
        lsp_use(k);
        lsp_handle(q + o, n);
        o += n;
    }
    free(q);
    // back to the server of the buffer in the globals, which a handler
    // that opened a file may have changed
    ed_lsp_follow();
}

// --- lifecycle -------------------------------------------------------

// Where clangd is: EDMINC_CLANGD, then PATH, then where the common
// installs put it, since an editor started from the desktop does not
// always get the shell's PATH. Empty when there is none. Owned.
private string lsp_clangd_path() {
    string over = env_get("EDMINC_CLANGD");
    if over.len > 0 { return over; }
    free(over);
    string w = path_which("clangd");
    if w.len > 0 { return w; }
    free(w);
    when os(windows) {
        str[2] roots = { "ProgramFiles", "ProgramFiles(x86)" };
        str[10] subs = {
            "/LLVM/bin/clangd.exe",
            "/Microsoft Visual Studio/18/Enterprise/VC/Tools/Llvm/x64/bin/clangd.exe",
            "/Microsoft Visual Studio/18/Professional/VC/Tools/Llvm/x64/bin/clangd.exe",
            "/Microsoft Visual Studio/18/Community/VC/Tools/Llvm/x64/bin/clangd.exe",
            "/Microsoft Visual Studio/18/BuildTools/VC/Tools/Llvm/x64/bin/clangd.exe",
            "/Microsoft Visual Studio/2022/Enterprise/VC/Tools/Llvm/x64/bin/clangd.exe",
            "/Microsoft Visual Studio/2022/Professional/VC/Tools/Llvm/x64/bin/clangd.exe",
            "/Microsoft Visual Studio/2022/Community/VC/Tools/Llvm/x64/bin/clangd.exe",
            "/Microsoft Visual Studio/2022/BuildTools/VC/Tools/Llvm/x64/bin/clangd.exe",
            "/Microsoft Visual Studio/2019/BuildTools/VC/Tools/Llvm/x64/bin/clangd.exe" };
        for i32 r = 0; r < 2; r++ {
            string root = env_get(roots[r]);
            if root.len > 0 {
                for i32 i = 0; i < 10; i++ {
                    string c = str_concat(str_from(root.data, cast(i32, root.len)), subs[i]);
                    if path_exists(str_from(c.data, cast(i32, c.len))) {
                        free(root);
                        return c;
                    }
                    free(c);
                }
            }
            free(root);
        }
    }
    when os(macos) {
        str[4] macs = {
            "/opt/homebrew/opt/llvm/bin/clangd",
            "/usr/local/opt/llvm/bin/clangd",
            "/Library/Developer/CommandLineTools/usr/bin/clangd",
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clangd" };
        for i32 i = 0; i < 4; i++ {
            if path_exists(macs[i]) { return str_concat(macs[i], ""); }
        }
    }
    string none = { .data = null, .len = 0 };
    return none;
}

// starts the current server
void lsp_start() {
    if lsp_on || lsp_absent_flag[lsp_cur] { return; }
    if !lsp_mx_ready {
        mutex_init(&lsp_mx);
        lsp_mx_ready = true;
    }
    i32 k = lsp_cur;
    bool spawned = false;
    if k == LSP_C {
        // the server logs errors only, and completes a name without
        // adding an #include for it: the client applies no edit but
        // the word it replaces
        string exe = lsp_clangd_path();
        if exe.len > 0 {
            str[4] argv = { "", "--log=error", "--header-insertion=never", "--header-insertion-decorators=0" };
            argv[0] = str_from(exe.data, cast(i32, exe.len));
            spawned = plat_child_spawn(k, &argv[0], 4);
        }
        free(exe);
        if !spawned {
            // looked for once per folder: the search walks PATH and the
            // install locations on disk
            lsp_absent_flag[k] = true;
            if lsp_trace { print("lsp: clangd not found\n"); }
            return;
        }
    } else {
        // EDMINC_LSP names another server binary, a development build
        str[1] argv = { "minc-lsp" };
        string over = env_get("EDMINC_LSP");
        if over.len > 0 { argv[0] = str_from(over.data, cast(i32, over.len)); }
        spawned = plat_child_spawn(k, &argv[0], 1);
        free(over);
        if !spawned { return; }
    }
    lsp_on = true;
    // the browser has neither thread: its page pushes the server's
    // bytes into lsp_feed itself and does its own writing. Both are up
    // before the first frame, so initialize goes out the same way as
    // everything after it.
    when !os(wasm) {
        lsp_slot_arg[k] = k;
        if !lsp_wmx_ready[k] {
            mutex_init(&lsp_wmx[k]);
            sem_init(&lsp_wsem[k], 0);
            lsp_wmx_ready[k] = true;
        }
        if lsp_threaded {
            lsp_wstop[k] = false;
            thread_create(&lsp_wthread[k], lsp_writer, &lsp_slot_arg[k]);
            lsp_wthread_up[k] = true;
        }
        thread_create(&lsp_thread[k], lsp_reader, &lsp_slot_arg[k]);
        lsp_thread_up[k] = true;
    }
    lsp_send_initialize();
}

// stops every server, for the folder switch, the restart and quit; a
// server that was not found is looked for again at its next start
void lsp_stop() {
    i32 back = lsp_cur;
    for i32 k = 0; k < LSP_SERVERS; k++ {
        lsp_use(k);
        lsp_stop_cur();
        lsp_absent_flag[k] = false;
    }
    lsp_use(back);
}

private void lsp_stop_cur() {
    if !lsp_on { return; }
    i32 k = lsp_cur;
    lsp_on = false;
    lsp_ready = false;
    // the server is gone; nothing is open on it any more. Without this
    // a file open in the old project would skip didOpen against the
    // restarted server after a folder switch.
    lsp_nopen = 0;
    lsp_open_len = 0;
    lsp_rec_invalidate();
    plat_child_kill(k);
    when !os(wasm) {
        // the kill closed the pipe, so a writer parked in a blocked
        // write comes back with an error rather than holding the join
        if lsp_wthread_up[k] {
            lsp_wthread_up[k] = false;
            mutex_lock(&lsp_wmx[k]);
            lsp_wstop[k] = true;
            mutex_unlock(&lsp_wmx[k]);
            sem_signal(&lsp_wsem[k]);
            thread_join(&lsp_wthread[k]);
            mutex_lock(&lsp_wmx[k]);
            if lsp_wq[k] != null {
                free(lsp_wq[k]);
                lsp_wq[k] = null;
            }
            lsp_wq_len[k] = 0;
            lsp_wq_cap[k] = 0;
            mutex_unlock(&lsp_wmx[k]);
        }
        if lsp_thread_up[k] {
            thread_join(&lsp_thread[k]);
            lsp_thread_up[k] = false;
        }
    }
    // a frame the old server left half written is not the start of the
    // next one's stream
    lsp_acc_len[k] = 0;
}
