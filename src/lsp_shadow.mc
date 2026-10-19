// lsp_shadow.mc - a document as the language server would hold it,
// for the harnesses: applies a didChange's contentChanges the way the
// server does, so what the client sent can be checked against the
// buffer it described. A ranged entry splices [start, end) in the text
// as it stood before that entry, columns in bytes, lines ending at
// '\n' only, positions clamped; an entry without a range replaces the
// whole text. Not part of the editor.

// byte offset of a position, clamped as the server clamps: a column
// past its line's end stops at the line end, a line past the last
// stops at the end of the text
i64 lsp_shadow_offset(u8* t, i64 n, i32 line, i32 col) {
    i64 at = 0;
    i32 l = 0;
    while l < line {
        while at < n && t[at] != '\n' { at++; }
        if at >= n { return n; }
        at++;
        l++;
    }
    i64 end = at;
    while end < n && t[end] != '\n' { end++; }
    if col < 0 { col = 0; }
    if at + col > end { return end; }
    return at + col;
}

// replaces [a, b) of the text with `s`; the text is reallocated to fit
private void lsp_shadow_splice(u8** text, i64* len, i64 a, i64 b, u8* s, i64 sn) {
    i64 n = *len;
    if a < 0 { a = 0; }
    if b > n { b = n; }
    if b < a { b = a; }
    i64 nn = n - (b - a) + sn;
    u8* out = alloc<u8>(nn + 1);
    if a > 0 { memcpy(out, *text, a); }
    if sn > 0 { memcpy(out + a, s, sn); }
    if n - b > 0 { memcpy(out + a + sn, *text + b, n - b); }
    if *text != null { free(*text); }
    *text = out;
    *len = nn;
}

// `changes` is the contentChanges array node of a parsed didChange.
// False when its shape is not the protocol's.
bool lsp_shadow_apply(u8** text, i64* len, JDoc* d, i32 changes) {
    if changes < 0 || jd_kind(d, changes) != J_ARR { return false; }
    i32 n = jd_len(d, changes);
    for i32 i = 0; i < n; i++ {
        i32 e = jd_at(d, changes, i);
        if e < 0 || jd_kind(d, e) != J_OBJ { return false; }
        i32 jt = jd_get(d, e, "text");
        if jt < 0 { return false; }
        str raw = jd_str(d, jt);
        u8* s = alloc<u8>(raw.len + 1);
        i64 sn = jd_str_copy(d, jt, s, raw.len + 1);
        i32 jr = jd_get(d, e, "range");
        if jr < 0 {
            lsp_shadow_splice(text, len, 0, *len, s, sn);
            free(s);
            continue;
        }
        i32 js = jd_get(d, jr, "start");
        i32 je = jd_get(d, jr, "end");
        if js < 0 || je < 0 {
            free(s);
            return false;
        }
        i32 l0 = cast(i32, jd_int(d, jd_get(d, js, "line")));
        i32 c0 = cast(i32, jd_int(d, jd_get(d, js, "character")));
        i32 l1 = cast(i32, jd_int(d, jd_get(d, je, "line")));
        i32 c1 = cast(i32, jd_int(d, jd_get(d, je, "character")));
        i64 a = lsp_shadow_offset(*text, *len, l0, c0);
        i64 b = lsp_shadow_offset(*text, *len, l1, c1);
        lsp_shadow_splice(text, len, a, b, s, sn);
        free(s);
    }
    return true;
}
