// sem.mc - semantic tokens from the language server, laid over the
// lexer's classes for the lines on screen. The lexer is the instant
// first pass; the server's token list for the whole document arrives
// after each push and refines what a byte scan cannot know: a
// function named without a call, a type in lower case, a field.
// Tokens follow edits by line, so the display holds between a push
// and its reply; a line that was edited falls back to the lexer until
// the next reply. One list, for the active buffer; a switch drops it
// and asks again.

private struct SemTok {
    i32 line;
    i32 col;   // byte column
    i32 len;
    u8 cls;    // LEX_* class, 255 for a type the legend maps to nothing
}

private const i32 SEM_MAX = 65536;
private const i32 SEM_LEN_MAX = 4096;
private const i32 SEM_TYPES_MAX = 32;

private SemTok* sem_toks = null;
private i32 sem_n = 0;
private i32 sem_cap = 0;
private bool sem_on = false;          // a list is held for sem_path
private u8[PATH_MAX] sem_path;
private i32 sem_path_len = 0;
private bool sem_ok = true;           // the reply was in order

// the server's legend, index to class, from the initialize reply
private u8[SEM_TYPES_MAX] sem_type_cls;
private i32 sem_ntypes = 0;

void sem_legend_reset() {
    sem_ntypes = 0;
}

// token types in the legend's order; the reference's theme colors
// these the way the lexer's classes are colored here
void sem_legend_add(str name) {
    if sem_ntypes >= SEM_TYPES_MAX { return; }
    u8 k = 255;
    if str_equal(name, "variable") || str_equal(name, "parameter") || str_equal(name, "property")
        || str_equal(name, "enumMember") {
        k = LEX_VAR;
    } else if str_equal(name, "function") || str_equal(name, "method") {
        k = LEX_FN;
    } else if str_equal(name, "type") || str_equal(name, "class") || str_equal(name, "struct")
        || str_equal(name, "enum") || str_equal(name, "interface") || str_equal(name, "typeParameter")
        || str_equal(name, "namespace") {
        k = LEX_TYPE;
    } else if str_equal(name, "keyword") {
        k = LEX_DECL;
    } else if str_equal(name, "number") {
        k = LEX_NUM;
    } else if str_equal(name, "string") {
        k = LEX_STR;
    } else if str_equal(name, "comment") {
        k = LEX_COM;
    } else if str_equal(name, "macro") {
        k = LEX_PRE;
    }
    sem_type_cls[sem_ntypes] = k;
    sem_ntypes++;
}

i32 sem_legend_n() {
    return sem_ntypes;
}

bool sem_active() {
    return sem_on;
}

i32 sem_count() {
    return sem_n;
}

void sem_clear() {
    sem_on = false;
    sem_n = 0;
    sem_path_len = 0;
}

// a reply is coming in for `path`
// FNV-1a over what the view reads: whether the list applies, its
// path, and the tokens. The basis does not fit a decimal literal.
private const u64 SEM_FNV_BASIS = (cast(u64, 0xCBF29CE4) << 32) | cast(u64, 0x84222325);
private const u64 SEM_FNV_PRIME = 1099511628211;
private u64 sem_prev = 0;   // the digest before the reply being read

private u64 sem_mix(u64 h, i64 v) {
    return (h ^ cast(u64, v)) * SEM_FNV_PRIME;
}

private u64 sem_digest() {
    u64 h = SEM_FNV_BASIS;
    if !sem_on { return h; }
    for i32 i = 0; i < sem_path_len; i++ { h = sem_mix(h, cast(i64, sem_path[i])); }
    h = sem_mix(h, cast(i64, sem_n));
    for i32 i = 0; i < sem_n; i++ {
        SemTok* t = &sem_toks[i];
        h = sem_mix(h, cast(i64, t.line));
        h = sem_mix(h, cast(i64, t.col));
        h = sem_mix(h, cast(i64, t.len));
        h = sem_mix(h, cast(i64, t.cls));
    }
    return h;
}

void sem_begin(str path) {
    sem_prev = sem_digest();
    sem_n = 0;
    sem_ok = true;
    sem_on = false;
    if path.len > PATH_MAX { path.len = PATH_MAX; }
    memcpy(&sem_path[0], path.data, path.len);
    sem_path_len = path.len;
}

// in the document's order; anything out of order or out of bounds
// discredits the reply and the lexer stands alone
void sem_add(i32 line, i32 col, i32 len, i32 type_index) {
    if !sem_ok { return; }
    if line < 0 || col < 0 || len <= 0 || len > SEM_LEN_MAX || sem_n >= SEM_MAX {
        sem_ok = false;
        return;
    }
    if sem_n > 0 {
        SemTok* last = &sem_toks[sem_n - 1];
        if line < last.line || (line == last.line && col < last.col + last.len) {
            sem_ok = false;
            return;
        }
    }
    if sem_n >= sem_cap {
        i32 ncap = sem_cap * 2 + 1024;
        SemTok* nt = alloc<SemTok>(ncap);
        if sem_toks != null {
            memcpy(nt, sem_toks, sem_n * sizeof(SemTok));
            free(sem_toks);
        }
        sem_toks = nt;
        sem_cap = ncap;
    }
    u8 k = 255;
    if type_index >= 0 && type_index < sem_ntypes { k = sem_type_cls[type_index]; }
    sem_toks[sem_n] = SemTok{ line, col, len, k };
    sem_n++;
}

// true when the list differs from the one before the reply, which is
// when the frame changes
bool sem_end() {
    if !sem_ok {
        sem_n = 0;
    } else {
        sem_on = true;
    }
    return sem_digest() != sem_prev;
}

// whether the held list is for `path`
bool sem_is_for(str path) {
    return sem_on && str_equal(str_from(&sem_path[0], sem_path_len), path);
}

// the classes of `line`, refined in place: each token's span takes
// its class, clamped to the line
void sem_overlay(i32 line, u8* cls, i32 n) {
    if !sem_on || sem_n == 0 { return; }
    i32 lo = 0;
    i32 hi = sem_n;
    while lo < hi {
        i32 mid = (lo + hi) / 2;
        if sem_toks[mid].line < line { lo = mid + 1; } else { hi = mid; }
    }
    for i32 i = lo; i < sem_n && sem_toks[i].line == line; i++ {
        SemTok* t = &sem_toks[i];
        if t.cls == 255 { continue; }
        i32 a = t.col;
        i32 b = t.col + t.len;
        if a < 0 { a = 0; }
        if b > n { b = n; }
        for i32 k = a; k < b; k++ { cls[k] = t.cls; }
    }
}

// text_buf reports each edit: line `at` changed, `removed` lines after
// it are gone, `added` are new. The changed lines lose their tokens,
// the lines below move with the edit.
void sem_note_edit(i32 at, i32 removed, i32 added) {
    if !sem_on || sem_n == 0 { return; }
    i32 w = 0;
    for i32 i = 0; i < sem_n; i++ {
        SemTok t = sem_toks[i];
        if t.line >= at && t.line <= at + removed { continue; }
        if t.line > at + removed { t.line += added - removed; }
        sem_toks[w] = t;
        w++;
    }
    sem_n = w;
}
