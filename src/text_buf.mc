// text_buf.mc - text buffer: gap buffer of bytes + line-start index.
//
// Offsets in the public API are logical (gap excluded). The line index
// holds the logical start offset of every line; edits shift the tail.

struct TextBuf {
    u8* data;
    i64 cap;
    i64 gap_start;
    i64 gap_end;
    i64* lstart;
    i32 nlines;
    i32 lcap;
    bool dirty;
    bool crlf;
    // The file as it was last loaded or saved, as bytes on disk: a
    // change on disk is a file whose bytes no longer hash to this.
    bool disk_known;
    u64 disk_hash;
    i64 disk_len;
    bool disk_gone;     // the file was deleted on disk after that
    u64 disk_noted;     // the on-disk hash last reported as a conflict
}

TextBuf tb;

private const i64 TB_MIN_GAP = 65536;

i64 tb_len() {
    return tb.cap - (tb.gap_end - tb.gap_start);
}

private u8 tb_at(i64 i) {
    if i < tb.gap_start { return tb.data[i]; }
    return tb.data[i + (tb.gap_end - tb.gap_start)];
}

// FNV-1a; the basis does not fit a decimal literal, so it is two halves
private const u64 TB_FNV_BASIS = (cast(u64, 0xCBF29CE4) << 32) | cast(u64, 0x84222325);
private const u64 TB_FNV_PRIME = 1099511628211;

u64 tb_hash(u8* p, i64 n) {
    u64 h = TB_FNV_BASIS;
    for i64 i = 0; i < n; i++ {
        h = (h ^ cast(u64, p[i])) * TB_FNV_PRIME;
    }
    return h;
}

// how many leading bytes of the buffer equal p[0..n)
i64 tb_common_prefix(u8* p, i64 n) {
    i64 len = tb_len();
    i64 i = 0;
    while i < len && i < n && tb_at(i) == p[i] { i++; }
    return i;
}

// how many trailing bytes of the buffer equal the end of p[0..n), at
// most `limit`
i64 tb_common_suffix(u8* p, i64 n, i64 limit) {
    i64 len = tb_len();
    i64 i = 0;
    while i < limit && i < len && i < n && tb_at(len - 1 - i) == p[n - 1 - i] { i++; }
    return i;
}

private void tb_disk_note(u8* p, i64 n) {
    tb.disk_known = true;
    tb.disk_hash = tb_hash(p, n);
    tb.disk_len = n;
    tb.disk_gone = false;
    tb.disk_noted = tb.disk_hash;
}

private void tb_disk_forget() {
    tb.disk_known = false;
    tb.disk_hash = 0;
    tb.disk_len = 0;
    tb.disk_gone = false;
    tb.disk_noted = 0;
}

// Copy [pos, pos+n) into dst, straddling the gap.
void tb_copy(i64 pos, u8* dst, i64 n) {
    i64 gsz = tb.gap_end - tb.gap_start;
    if pos + n <= tb.gap_start {
        memcpy(dst, tb.data + pos, n);
    } else if pos >= tb.gap_start {
        memcpy(dst, tb.data + pos + gsz, n);
    } else {
        i64 front = tb.gap_start - pos;
        memcpy(dst, tb.data + pos, front);
        memcpy(dst + front, tb.data + tb.gap_end, n - front);
    }
}

private const u64 TB_ONES = 0x0101010101010101;
private const u64 TB_HIGHS = 0x8080808080808080;

// nonzero when any byte of w equals the byte replicated in pat
private u64 tb_byte_match(u64 w, u64 pat) {
    u64 x = w ^ pat;
    return (x - TB_ONES) & ~x & TB_HIGHS;
}

// first index of byte b in d[at, len), or -1; 8 bytes per probe
private i64 tb_find_byte(u8* d, i64 at, i64 len, u8 b) {
    i64 i = at;
    while i < len && (i & 7) != 0 {
        if d[i] == b { return i; }
        i++;
    }
    u64 pat = cast(u64, b) * TB_ONES;
    while i + 8 <= len {
        if tb_byte_match(*cast(u64*, d + i), pat) != 0 {
            for i64 j = 0; j < 8; j++ {
                if d[i + j] == b { return i + j; }
            }
        }
        i += 8;
    }
    while i < len {
        if d[i] == b { return i; }
        i++;
    }
    return -1;
}

private i64* tb_ls_grow(i64* ls, i32 n, i32* cap) {
    i32 ncap = *cap + *cap / 2 + 256;
    i64* nl = alloc<i64>(ncap);
    memcpy(nl, ls, n * sizeof(i64));
    free(ls);
    *cap = ncap;
    return nl;
}

// One sweep: build the line index over d[0, len), 8 bytes per probe.
// With watch_cr, returns false at the first '\r' (index discarded).
private bool tb_index_scan(u8* d, i64 len, bool watch_cr) {
    i32 cap = cast(i32, len / 32) + 256;
    i64* ls = alloc<i64>(cap);
    ls[0] = 0;
    i32 n = 1;
    u64 nlpat = 0x0A0A0A0A0A0A0A0A;
    u64 crpat = 0x0D0D0D0D0D0D0D0D;
    i64 nw = len / 8;
    for i64 k = 0; k < nw; k++ {
        u64 w = *cast(u64*, d + k * 8);
        u64 xn = w ^ nlpat;
        u64 hit = (xn - TB_ONES) & ~xn & TB_HIGHS;
        if watch_cr {
            u64 xc = w ^ crpat;
            hit = hit | ((xc - TB_ONES) & ~xc & TB_HIGHS);
        }
        if hit != 0 {
            i64 base = k * 8;
            for i64 j = 0; j < 8; j++ {
                u8 c = d[base + j];
                if watch_cr && c == '\r' {
                    free(ls);
                    return false;
                }
                if c == '\n' {
                    if n == cap { ls = tb_ls_grow(ls, n, &cap); }
                    ls[n] = base + j + 1;
                    n++;
                }
            }
        }
    }
    for i64 j = nw * 8; j < len; j++ {
        u8 c = d[j];
        if watch_cr && c == '\r' {
            free(ls);
            return false;
        }
        if c == '\n' {
            if n == cap { ls = tb_ls_grow(ls, n, &cap); }
            ls[n] = j + 1;
            n++;
        }
    }
    if tb.lstart != null { free(tb.lstart); }
    tb.lstart = ls;
    tb.lcap = cap;
    tb.nlines = n;
    return true;
}

// rebuild the whole index; the text must be contiguous at the front
// of the buffer (the gap at the end), which load and init guarantee
private void tb_index_rebuild() {
    ignore tb_index_scan(tb.data, tb_len(), false);
}

void tb_init_empty() {
    tb.cap = TB_MIN_GAP;
    tb.data = alloc<u8>(tb.cap);
    tb.gap_start = 0;
    tb.gap_end = tb.cap;
    tb_index_rebuild();
    tb.dirty = false;
    tb_disk_forget();
    wrap_reset();
}

// release the buffer so another file can load into tb
void tb_free() {
    if tb.data != null {
        free(tb.data);
        tb.data = null;
    }
    if tb.lstart != null {
        free(tb.lstart);
        tb.lstart = null;
    }
    tb.cap = 0;
    tb.gap_start = 0;
    tb.gap_end = 0;
    tb.nlines = 0;
    tb.lcap = 0;
    tb.dirty = false;
    tb.crlf = false;
    tb_disk_forget();
}

bool tb_load(str path) {
    FileData fd = file_read(path);
    if fd.data == null {
        tb_init_empty();
        return false;
    }
    // index in one sweep, assuming LF; the sweep aborts at the first
    // '\r' and the CRLF path strips and rescans (restored on save)
    i64 flen = cast(i64, fd.len);
    tb.crlf = !tb_index_scan(fd.data, flen, true);
    tb.cap = flen + TB_MIN_GAP;
    tb.data = alloc<u8>(tb.cap);
    if !tb.crlf {
        memcpy(tb.data, fd.data, flen);
        tb.gap_start = flen;
    } else {
        // copy in CR-delimited chunks
        i64 w = 0;
        i64 s = 0;
        i64 p = tb_find_byte(fd.data, 0, flen, '\r');
        while p >= 0 {
            memcpy(tb.data + w, fd.data + s, p - s);
            w += p - s;
            s = p + 1;
            p = tb_find_byte(fd.data, s, flen, '\r');
        }
        // the tail after the last CR counts too; without this the
        // bytes past it are copied but left outside the buffer, which
        // drops the final newline, or the whole last line when the
        // file does not end with one
        memcpy(tb.data + w, fd.data + s, flen - s);
        w += flen - s;
        tb.gap_start = w;
        ignore tb_index_scan(tb.data, w, false);
    }
    tb_disk_note(fd.data, flen);
    free(fd.data);
    tb.gap_end = tb.cap;
    tb.dirty = false;
    wrap_reset();
    return true;
}

bool tb_save(str path) {
    i64 len = tb_len();
    i64 outcap = len;
    if tb.crlf { outcap = len + tb.nlines + 1; }
    u8* out = alloc<u8>(outcap + 1);
    i64 w = 0;
    if tb.crlf {
        for i64 i = 0; i < len; i++ {
            u8 c = tb_at(i);
            if c == '\n' {
                out[w] = '\r';
                w++;
            }
            out[w] = c;
            w++;
        }
    } else {
        tb_copy(0, out, len);
        w = len;
    }
    FileData fd = FileData{ out, cast(i32, w) };
    bool ok = file_write(path, fd);
    if ok {
        tb.dirty = false;
        tb_disk_note(out, w);
    }
    free(out);
    return ok;
}

private void tb_move_gap(i64 pos) {
    i64 gsz = tb.gap_end - tb.gap_start;
    if pos == tb.gap_start { return; }
    if pos < tb.gap_start {
        // move text [pos, gap_start) right by gsz; copy backward, ranges overlap
        i64 n = tb.gap_start - pos;
        for i64 i = n - 1; i >= 0; i-- {
            tb.data[tb.gap_end - n + i] = tb.data[pos + i];
        }
    } else {
        // move text [gap_end, gap_end + n) left by gsz; forward copy is safe
        i64 n = pos - tb.gap_start;
        for i64 i = 0; i < n; i++ {
            tb.data[tb.gap_start + i] = tb.data[tb.gap_end + i];
        }
    }
    tb.gap_start = pos;
    tb.gap_end = pos + gsz;
}

private void tb_ensure_gap(i64 need) {
    i64 gsz = tb.gap_end - tb.gap_start;
    if gsz >= need { return; }
    i64 add = need + TB_MIN_GAP;
    i64 newcap = tb.cap + add;
    u8* nd = alloc<u8>(newcap);
    memcpy(nd, tb.data, tb.gap_start);
    i64 tail = tb.cap - tb.gap_end;
    memcpy(nd + newcap - tail, tb.data + tb.gap_end, tail);
    free(tb.data);
    tb.data = nd;
    tb.gap_end = newcap - tail;
    tb.cap = newcap;
}

i32 tb_line_of(i64 pos) {
    i32 lo = 0;
    i32 hi = tb.nlines - 1;
    while lo < hi {
        i32 mid = (lo + hi + 1) / 2;
        if tb.lstart[mid] <= pos { lo = mid; } else { hi = mid - 1; }
    }
    return lo;
}

i64 tb_line_start(i32 l) {
    return tb.lstart[l];
}

// end offset of line l, exclusive of the trailing '\n'
i64 tb_line_end(i32 l) {
    if l + 1 < tb.nlines { return tb.lstart[l + 1] - 1; }
    return tb_len();
}

private void tb_lines_ensure_cap(i32 need) {
    if need <= tb.lcap { return; }
    i32 ncap = need + need / 2 + 256;
    i64* nl = alloc<i64>(ncap);
    memcpy(nl, tb.lstart, tb.nlines * sizeof(i64));
    free(tb.lstart);
    tb.lstart = nl;
    tb.lcap = ncap;
}

// A document built for something other than the buffer on screen: the
// diff's baseline is filled by inserting HEAD's whole text, and the
// change gutter and the token list are the active buffer's, not this
// one's. Telling them about that insert moved the file's tokens down by
// the length of the file, which is what slid its colors.
bool tb_quiet = false;

void tb_insert(i64 pos, u8* s, i32 n) {
    if n <= 0 { return; }
    lsp_note_insert(pos, s, n);
    brace_note_edit(pos);
    tb_move_gap(pos);
    tb_ensure_gap(n);
    memcpy(tb.data + tb.gap_start, s, n);
    tb.gap_start += n;

    i32 nl = 0;
    for i32 i = 0; i < n; i++ {
        if s[i] == '\n' { nl++; }
    }
    // shift line starts after pos
    i32 first = tb_line_of(pos) + 1;
    for i32 l = first; l < tb.nlines; l++ {
        tb.lstart[l] += n;
    }
    if nl > 0 {
        tb_lines_ensure_cap(tb.nlines + nl);
        for i32 l = tb.nlines - 1; l >= first; l-- {
            tb.lstart[l + nl] = tb.lstart[l];
        }
        i32 at = first;
        for i32 i = 0; i < n; i++ {
            if s[i] == '\n' {
                tb.lstart[at] = pos + i + 1;
                at++;
            }
        }
        tb.nlines += nl;
    }
    tb.dirty = true;
    if !tb_quiet {
        git_note_edit(first - 1, 0, nl);
        sem_note_edit(first - 1, 0, nl);
        wrap_note_edit(first - 1, 0, nl);
    }
}

void tb_delete(i64 pos, i64 n) {
    if n <= 0 { return; }
    lsp_note_delete(pos, n);
    brace_note_edit(pos);
    tb_move_gap(pos);
    tb.gap_end += n;

    // drop line starts inside (pos, pos+n], shift the rest
    i32 first = tb_line_of(pos) + 1;
    i32 gone = 0;
    while first + gone < tb.nlines && tb.lstart[first + gone] <= pos + n {
        gone++;
    }
    for i32 l = first; l + gone < tb.nlines; l++ {
        tb.lstart[l] = tb.lstart[l + gone] - n;
    }
    tb.nlines -= gone;
    tb.dirty = true;
    if !tb_quiet {
        git_note_edit(first - 1, gone, 0);
        sem_note_edit(first - 1, gone, 0);
        wrap_note_edit(first - 1, gone, 0);
    }
}
