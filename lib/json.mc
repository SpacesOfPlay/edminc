// json.mc - minimal JSON reader and string escaping for the LSP
// client. Parses one message into a node pool over the source bytes
// (string values are raw slices; jd_str_copy unescapes). Enough for
// LSP traffic: objects, arrays, strings, numbers, bools, null. The
// lenient parse also takes what a hand-edited file has: // and /* */
// comments, and a comma before a closing bracket.

const u8 J_NULL = 0;
const u8 J_BOOL = 1;
const u8 J_NUM = 2;
const u8 J_STR = 3;
const u8 J_ARR = 4;
const u8 J_OBJ = 5;

struct JNode {
    u8 kind;
    i32 a;         // str: src offset; arr/obj: first child; bool: 0/1
    i32 b;         // str: byte length; arr/obj: child count
    f64 num;
    i32 next;      // next sibling, -1 at the end
    i32 key_off;   // object-member key offset in src, -1 outside objects
    i32 key_len;
}

struct JDoc {
    u8* src;
    i64 len;
    JNode* nodes;
    i32 count;
    i32 cap;
    i64 pos;       // parse cursor
    bool fail;
    bool lenient;  // comments and trailing commas (json_parse_lenient)
}

private i32 jd_node(JDoc* d, u8 kind) {
    if d.count == d.cap {
        i32 ncap = d.cap * 2 + 64;
        JNode* nn = alloc<JNode>(ncap);
        if d.nodes != null {
            memcpy(nn, d.nodes, d.count * sizeof(JNode));
            free(d.nodes);
        }
        d.nodes = nn;
        d.cap = ncap;
    }
    i32 i = d.count;
    d.nodes[i] = JNode{ kind, 0, 0, 0.0, -1, -1, 0 };
    d.count++;
    return i;
}

private void jd_ws(JDoc* d) {
    while d.pos < d.len {
        u8 c = d.src[d.pos];
        if c == ' ' || c == 9 || c == 10 || c == 13 {
            d.pos++;
            continue;
        }
        if !d.lenient || c != '/' || d.pos + 1 >= d.len { break; }
        u8 c2 = d.src[d.pos + 1];
        if c2 == '/' {
            while d.pos < d.len && d.src[d.pos] != 10 { d.pos++; }
            continue;
        }
        if c2 != '*' { break; }
        d.pos += 2;
        while d.pos + 1 < d.len && !(d.src[d.pos] == '*' && d.src[d.pos + 1] == '/') { d.pos++; }
        d.pos += 2;
        if d.pos > d.len { d.pos = d.len; }
    }
}

// raw span of a string literal at pos (opening quote consumed by the
// caller); escapes kept, decoded later by jd_str_copy
private bool jd_string_span(JDoc* d, i32* off, i32* n) {
    *off = cast(i32, d.pos);
    while d.pos < d.len {
        u8 c = d.src[d.pos];
        if c == '"' {
            *n = cast(i32, d.pos) - *off;
            d.pos++;
            return true;
        }
        if c == 92 && d.pos + 1 < d.len { d.pos++; }
        d.pos++;
    }
    return false;
}

private bool jd_lit(JDoc* d, str w) {
    if d.pos + w.len > d.len { return false; }
    for i32 i = 0; i < w.len; i++ {
        if d.src[d.pos + i] != w.data[i] { return false; }
    }
    d.pos += w.len;
    return true;
}

private i32 jd_container(JDoc* d, u8 kind, u8 close) {
    i32 v = jd_node(d, kind);
    d.nodes[v].a = -1;
    d.pos++;
    jd_ws(d);
    if d.pos < d.len && d.src[d.pos] == close {
        d.pos++;
        return v;
    }
    i32 tail = -1;
    while true {
        jd_ws(d);
        i32 koff = -1;
        i32 klen = 0;
        if kind == J_OBJ {
            if d.pos >= d.len || d.src[d.pos] != '"' { d.fail = true; return -1; }
            d.pos++;
            if !jd_string_span(d, &koff, &klen) { d.fail = true; return -1; }
            jd_ws(d);
            if d.pos >= d.len || d.src[d.pos] != ':' { d.fail = true; return -1; }
            d.pos++;
        }
        i32 c = jd_value(d);
        if c < 0 { d.fail = true; return -1; }
        d.nodes[c].key_off = koff;
        d.nodes[c].key_len = klen;
        if tail < 0 { d.nodes[v].a = c; } else { d.nodes[tail].next = c; }
        tail = c;
        d.nodes[v].b++;
        jd_ws(d);
        if d.pos >= d.len { d.fail = true; return -1; }
        u8 ch = d.src[d.pos];
        if ch == ',' {
            d.pos++;
            if d.lenient {
                jd_ws(d);
                if d.pos < d.len && d.src[d.pos] == close {
                    d.pos++;
                    return v;
                }
            }
            continue;
        }
        if ch == close {
            d.pos++;
            return v;
        }
        d.fail = true;
        return -1;
    }
}

private i32 jd_value(JDoc* d) {
    jd_ws(d);
    if d.pos >= d.len { d.fail = true; return -1; }
    u8 c = d.src[d.pos];
    if c == '{' { return jd_container(d, J_OBJ, '}'); }
    if c == '[' { return jd_container(d, J_ARR, ']'); }
    if c == '"' {
        d.pos++;
        i32 off = 0;
        i32 n = 0;
        if !jd_string_span(d, &off, &n) { d.fail = true; return -1; }
        i32 v = jd_node(d, J_STR);
        d.nodes[v].a = off;
        d.nodes[v].b = n;
        return v;
    }
    if c == 't' {
        if !jd_lit(d, "true") { d.fail = true; return -1; }
        i32 v = jd_node(d, J_BOOL);
        d.nodes[v].a = 1;
        return v;
    }
    if c == 'f' {
        if !jd_lit(d, "false") { d.fail = true; return -1; }
        return jd_node(d, J_BOOL);
    }
    if c == 'n' {
        if !jd_lit(d, "null") { d.fail = true; return -1; }
        return jd_node(d, J_NULL);
    }
    // number: sign, int, optional fraction/exponent
    f64 sign = 1.0;
    if c == '-' {
        sign = -1.0;
        d.pos++;
    }
    f64 v = 0.0;
    bool any = false;
    while d.pos < d.len && d.src[d.pos] >= '0' && d.src[d.pos] <= '9' {
        v = v * 10.0 + cast(f64, d.src[d.pos] - '0');
        d.pos++;
        any = true;
    }
    if !any { d.fail = true; return -1; }
    if d.pos < d.len && d.src[d.pos] == '.' {
        d.pos++;
        f64 scale = 0.1;
        while d.pos < d.len && d.src[d.pos] >= '0' && d.src[d.pos] <= '9' {
            v += cast(f64, d.src[d.pos] - '0') * scale;
            scale = scale / 10.0;
            d.pos++;
        }
    }
    if d.pos < d.len && (d.src[d.pos] == 'e' || d.src[d.pos] == 'E') {
        d.pos++;
        f64 esign = 1.0;
        if d.pos < d.len && (d.src[d.pos] == '+' || d.src[d.pos] == '-') {
            if d.src[d.pos] == '-' { esign = -1.0; }
            d.pos++;
        }
        f64 e = 0.0;
        while d.pos < d.len && d.src[d.pos] >= '0' && d.src[d.pos] <= '9' {
            e = e * 10.0 + cast(f64, d.src[d.pos] - '0');
            d.pos++;
        }
        while e > 0.0 {
            if esign > 0.0 { v = v * 10.0; } else { v = v / 10.0; }
            e = e - 1.0;
        }
    }
    i32 nv = jd_node(d, J_NUM);
    d.nodes[nv].num = sign * v;
    return nv;
}

// Parse src into d; returns the root node or -1. The doc borrows
// src; free with json_free.
i32 json_parse(JDoc* d, u8* src, i64 len) {
    d.src = src;
    d.len = len;
    d.pos = 0;
    d.count = 0;
    d.fail = false;
    i32 root = jd_value(d);
    if d.fail { return -1; }
    return root;
}

// The same for a file a person edits: comments and trailing commas
// are taken, and anything after the root other than them fails.
i32 json_parse_lenient(JDoc* d, u8* src, i64 len) {
    d.lenient = true;
    i32 root = json_parse(d, src, len);
    if root < 0 { return -1; }
    jd_ws(d);
    if d.pos < d.len {
        d.fail = true;
        return -1;
    }
    return root;
}

// the 1-based line the parse stopped on, for an error message
i32 json_fail_line(JDoc* d) {
    i32 line = 1;
    i64 end = d.pos;
    if end > d.len { end = d.len; }
    for i64 i = 0; i < end; i++ {
        if d.src[i] == 10 { line++; }
    }
    return line;
}

void json_free(JDoc* d) {
    if d.nodes != null {
        free(d.nodes);
        d.nodes = null;
    }
    d.cap = 0;
    d.count = 0;
}

u8 jd_kind(JDoc* d, i32 v) {
    return d.nodes[v].kind;
}

// object member by key, or -1
i32 jd_get(JDoc* d, i32 obj, str key) {
    if obj < 0 || d.nodes[obj].kind != J_OBJ { return -1; }
    i32 c = d.nodes[obj].a;
    while c >= 0 {
        if d.nodes[c].key_len == key.len
            && str_equal(str_from(d.src + d.nodes[c].key_off, d.nodes[c].key_len), key) {
            return c;
        }
        c = d.nodes[c].next;
    }
    return -1;
}

i32 jd_len(JDoc* d, i32 v) {
    if v < 0 { return 0; }
    return d.nodes[v].b;
}

// First child of an array or object, -1 if empty. With jd_next this
// walks a container in one pass: jd_at starts from the head every
// call, so indexing a long array in a loop is quadratic.
i32 jd_first(JDoc* d, i32 v) {
    if v < 0 { return -1; }
    i32 k = d.nodes[v].kind;
    if k != J_ARR && k != J_OBJ { return -1; }
    return d.nodes[v].a;
}

// next sibling of a child node, -1 at the end
i32 jd_next(JDoc* d, i32 v) {
    if v < 0 { return -1; }
    return d.nodes[v].next;
}

// array element i, or -1
i32 jd_at(JDoc* d, i32 arr, i32 i) {
    if arr < 0 || d.nodes[arr].kind != J_ARR { return -1; }
    i32 c = d.nodes[arr].a;
    while c >= 0 && i > 0 {
        c = d.nodes[c].next;
        i--;
    }
    return c;
}

// raw slice; escapes still encoded
str jd_str(JDoc* d, i32 v) {
    if v < 0 || d.nodes[v].kind != J_STR { return ""; }
    return str_from(d.src + d.nodes[v].a, d.nodes[v].b);
}

f64 jd_num(JDoc* d, i32 v) {
    if v < 0 || d.nodes[v].kind != J_NUM { return 0.0; }
    return d.nodes[v].num;
}

i64 jd_int(JDoc* d, i32 v) {
    return cast(i64, jd_num(d, v));
}

bool jd_bool(JDoc* d, i32 v) {
    return v >= 0 && d.nodes[v].kind == J_BOOL && d.nodes[v].a != 0;
}

// a hex digit's value, -1 for any other byte
i32 jd_hex_digit(u8 c) {
    if c >= '0' && c <= '9' { return cast(i32, c - '0'); }
    if c >= 'a' && c <= 'f' { return cast(i32, c - 'a') + 10; }
    if c >= 'A' && c <= 'F' { return cast(i32, c - 'A') + 10; }
    return -1;
}

// up to four hex digits at *i, which moves past them; a byte that is
// not one counts as 0, the way a lax reader takes a short escape
private u32 jd_hex4(u8* s, i32 n, i32* i) {
    u32 v = 0;
    for i32 k = 0; k < 4 && *i < n; k++ {
        i32 hv = jd_hex_digit(s[*i]);
        *i = *i + 1;
        if hv < 0 { hv = 0; }
        v = (v << 4) | cast(u32, hv);
    }
    return v;
}

// decoded string value into out; returns the byte count (truncated
// at cap)
i64 jd_str_copy(JDoc* d, i32 v, u8* out, i64 cap) {
    if v < 0 || d.nodes[v].kind != J_STR { return 0; }
    u8* s = d.src + d.nodes[v].a;
    i32 n = d.nodes[v].b;
    i64 o = 0;
    i32 i = 0;
    while i < n && o < cap {
        u8 c = s[i];
        if c != 92 {
            out[o] = c;
            o++;
            i++;
            continue;
        }
        i++;
        if i >= n { break; }
        u8 e = s[i];
        i++;
        if e == 'n' { out[o] = 10; o++; continue; }
        if e == 't' { out[o] = 9; o++; continue; }
        if e == 'r' { out[o] = 13; o++; continue; }
        if e == 'b' { out[o] = 8; o++; continue; }
        if e == 'f' { out[o] = 12; o++; continue; }
        if e == 'u' {
            u32 cp = jd_hex4(s, n, &i);
            // surrogate pair
            if cp >= 0xD800 && cp < 0xDC00 && i + 5 < n && s[i] == 92 && s[i + 1] == 'u' {
                i += 2;
                u32 lo = jd_hex4(s, n, &i);
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            }
            noinit u8[8] enc;
            i32 en = utf8_encode(cp, &enc[0]);
            for i32 k = 0; k < en && o < cap; k++ {
                out[o] = enc[k];
                o++;
            }
            continue;
        }
        out[o] = e;   // '"', '\', '/'
        o++;
    }
    return o;
}

// --- writing ---------------------------------------------------------
// Requests are assembled into a caller-owned byte buffer; jw_esc
// appends a JSON-escaped string body (no quotes).

i64 jw_raw(u8* out, i64 o, str s) {
    memcpy(out + o, s.data, s.len);
    return o + s.len;
}

i64 jw_int(u8* out, i64 o, i64 v) {
    if v < 0 {
        out[o] = '-';
        o++;
        v = -v;
    }
    noinit u8[24] tmp;
    i32 n = 0;
    if v == 0 {
        tmp[0] = '0';
        n = 1;
    }
    while v > 0 {
        tmp[n] = cast(u8, '0' + v % 10);
        v /= 10;
        n++;
    }
    while n > 0 {
        n--;
        out[o] = tmp[n];
        o++;
    }
    return o;
}

i64 jw_esc(u8* out, i64 o, u8* s, i64 n) {
    for i64 i = 0; i < n; i++ {
        u8 c = s[i];
        if c == '"' || c == 92 {
            out[o] = 92;
            o++;
            out[o] = c;
            o++;
        } else if c == 10 {
            out[o] = 92; o++;
            out[o] = 'n'; o++;
        } else if c == 13 {
            out[o] = 92; o++;
            out[o] = 'r'; o++;
        } else if c == 9 {
            out[o] = 92; o++;
            out[o] = 't'; o++;
        } else if c < 32 {
            out[o] = 92; o++;
            out[o] = 'u'; o++;
            out[o] = '0'; o++;
            out[o] = '0'; o++;
            u8 hi = cast(u8, c >> 4);
            u8 lo = cast(u8, c & 15);
            out[o] = cast(u8, '0' + hi); o++;
            if lo < 10 { out[o] = cast(u8, '0' + lo); } else { out[o] = cast(u8, 'a' + lo - 10); }
            o++;
        } else {
            out[o] = c;
            o++;
        }
    }
    return o;
}
