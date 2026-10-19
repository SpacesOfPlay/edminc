// lexer.mc - per-line incremental minc highlighter. Classification
// mirrors the reference highlighting (doc/TECH_DOC.md "Highlighting"), including
// what its LSP semantic tokens produce where a lexer can: CamelCase
// identifiers as types, identifiers before '(' as functions, other
// identifiers as variables, and bracket colors cycled by depth.
//
// lex_line fills one color class per byte and returns the carried
// state for the next line: bit 7 = inside /* */, bits 0..6 = bracket
// nesting depth.

const u8 LEX_DEF = 0;
const u8 LEX_CTRL = 1;
const u8 LEX_DECL = 2;
const u8 LEX_TYPE = 3;
const u8 LEX_VAR = 4;
const u8 LEX_FN = 5;
const u8 LEX_STR = 6;
const u8 LEX_ESC = 7;
const u8 LEX_NUM = 8;
const u8 LEX_COM = 9;
const u8 LEX_PRE = 10;
const u8 LEX_BR0 = 11;   // bracket depth % 3 == 0
const u8 LEX_BR1 = 12;
const u8 LEX_BR2 = 13;
const u8 LEX_LIST = 14;  // markdown list markers

// the language a buffer lexes in; ed.mc maps the file extension to one
// and lex_row (ed.mc) dispatches to the matching lex_*_line below
const i32 LANG_MINC = 0;
const i32 LANG_MD = 1;
const i32 LANG_JS = 2;
const i32 LANG_PY = 3;
const i32 LANG_SH = 4;
const i32 LANG_HTML = 5;
const i32 LANG_JSON = 6;
const i32 LANG_YAML = 7;
const i32 LANG_CSS = 8;
const i32 LANG_GML = 9;
const i32 LANG_C = 10;

private const i32 LEX_IN_COMMENT = 0x80;
private const i32 LEX_DEPTH_MASK = 0x7F;
private const i32 LEX_DEPTH_MAX = 120;

private bool lex_word_eq(u8* s, i32 len, str w) {
    if len != w.len { return false; }
    for i32 i = 0; i < len; i++ {
        if s[i] != w.data[i] { return false; }
    }
    return true;
}

private bool lex_is_ctrl(u8* s, i32 len) {
    if lex_word_eq(s, len, "if") { return true; }
    if lex_word_eq(s, len, "else") { return true; }
    if lex_word_eq(s, len, "while") { return true; }
    if lex_word_eq(s, len, "for") { return true; }
    if lex_word_eq(s, len, "return") { return true; }
    if lex_word_eq(s, len, "break") { return true; }
    if lex_word_eq(s, len, "continue") { return true; }
    if lex_word_eq(s, len, "switch") { return true; }
    if lex_word_eq(s, len, "case") { return true; }
    if lex_word_eq(s, len, "default") { return true; }
    if lex_word_eq(s, len, "when") { return true; }
    if lex_word_eq(s, len, "cast") { return true; }
    return false;
}

private bool lex_is_decl(u8* s, i32 len) {
    if lex_word_eq(s, len, "struct") { return true; }
    if lex_word_eq(s, len, "enum") { return true; }
    if lex_word_eq(s, len, "union") { return true; }
    if lex_word_eq(s, len, "extern") { return true; }
    if lex_word_eq(s, len, "fn") { return true; }
    if lex_word_eq(s, len, "var") { return true; }
    if lex_word_eq(s, len, "const") { return true; }
    if lex_word_eq(s, len, "private") { return true; }
    if lex_word_eq(s, len, "import") { return true; }
    if lex_word_eq(s, len, "from") { return true; }
    return false;
}

// keywords the extension leaves unscoped; they render plain
private bool lex_is_plain_kw(u8* s, i32 len) {
    if lex_word_eq(s, len, "sizeof") { return true; }
    if lex_word_eq(s, len, "new") { return true; }
    if lex_word_eq(s, len, "defer") { return true; }
    if lex_word_eq(s, len, "noalias") { return true; }
    if lex_word_eq(s, len, "noinit") { return true; }
    if lex_word_eq(s, len, "unused") { return true; }
    if lex_word_eq(s, len, "type") { return true; }
    if lex_word_eq(s, len, "ignore") { return true; }
    if lex_word_eq(s, len, "fallthrough") { return true; }
    if lex_word_eq(s, len, "unsafe_union") { return true; }
    return false;
}

// The builtin types, in the order they are written in practice:
// counted over this editor and the installed stdlib, where i32 alone
// is a third of all type mentions. Completion offers them in this
// order, so typing "i" puts i32 and i64 first. The scalars come first;
// LEX_NSCALAR_TYPES splits them from the vector and SIMD builtins.
const i32 LEX_NTYPES = 33;
const i32 LEX_NSCALAR_TYPES = 14;
str[LEX_NTYPES] lex_types = {
    "i32", "void", "f32", "u32", "u64", "u8", "bool", "i64", "f64", "str",
    "u16", "i16", "string", "i8",
    "float4", "float3", "float2", "float4x4", "float3x3", "float2x2",
    "int4", "int3", "int2", "uint4", "uint3", "uint2",
    "f32x8", "i32x8", "i8x32", "f64x2", "i64x2", "u64x2", "i8x16" };

private bool lex_is_type(u8* s, i32 len) {
    for i32 i = 0; i < LEX_NSCALAR_TYPES; i++ {
        if lex_word_eq(s, len, lex_types[i]) { return true; }
    }
    return false;
}

// The vector and SIMD builtins. The extension's grammar keeps them
// in the scalar types' blue scope, but the reference shows them in
// the struct color: the server's semantic tokens class them as types,
// and that is what the eye is used to.
private bool lex_is_vec_type(u8* s, i32 len) {
    for i32 i = LEX_NSCALAR_TYPES; i < LEX_NTYPES; i++ {
        if lex_word_eq(s, len, lex_types[i]) { return true; }
    }
    return false;
}

private bool lex_is_const_kw(u8* s, i32 len) {
    if lex_word_eq(s, len, "true") { return true; }
    if lex_word_eq(s, len, "false") { return true; }
    if lex_word_eq(s, len, "null") { return true; }
    return false;
}

// @directives render like #include; other @annotations render blue
private bool lex_is_directive(u8* s, i32 len) {
    if lex_word_eq(s, len, "minc_min_version") { return true; }
    if lex_word_eq(s, len, "unchecked") { return true; }
    if lex_word_eq(s, len, "define") { return true; }
    if lex_word_eq(s, len, "link") { return true; }
    if lex_word_eq(s, len, "gpu") { return true; }
    if lex_word_eq(s, len, "gui") { return true; }
    return false;
}

private bool lex_ident_start(u8 c) {
    if c >= 'a' && c <= 'z' { return true; }
    if c >= 'A' && c <= 'Z' { return true; }
    return c == '_';
}

private bool lex_ident_char(u8 c) {
    if lex_ident_start(c) { return true; }
    return c >= '0' && c <= '9';
}

private bool lex_is_escape_char(u8 c) {
    return c == 'n' || c == 'r' || c == 't' || c == '0'
        || c == '\\' || c == '\'' || c == '"';
}

private u8 lex_bracket_class(i32 depth) {
    i32 m = depth % 3;
    if m == 0 { return LEX_BR0; }
    if m == 1 { return LEX_BR1; }
    return LEX_BR2;
}

i32 lex_line(u8* s, i32 len, i32 state, u8* cls) {
    bool in_com = (state & LEX_IN_COMMENT) != 0;
    i32 depth = state & LEX_DEPTH_MASK;
    i32 i = 0;
    while i < len {
        if in_com {
            if s[i] == '*' && i + 1 < len && s[i + 1] == '/' {
                cls[i] = LEX_COM;
                cls[i + 1] = LEX_COM;
                i += 2;
                in_com = false;
            } else {
                cls[i] = LEX_COM;
                i++;
            }
            continue;
        }
        u8 c = s[i];
        if c == '/' && i + 1 < len && s[i + 1] == '/' {
            while i < len {
                cls[i] = LEX_COM;
                i++;
            }
            break;
        }
        if c == '/' && i + 1 < len && s[i + 1] == '*' {
            cls[i] = LEX_COM;
            cls[i + 1] = LEX_COM;
            i += 2;
            in_com = true;
            continue;
        }
        if c == '"' || c == '\'' {
            u8 q = c;
            cls[i] = LEX_STR;
            i++;
            while i < len {
                if s[i] == '\\' && i + 1 < len {
                    u8 e = LEX_STR;
                    if lex_is_escape_char(s[i + 1]) { e = LEX_ESC; }
                    cls[i] = e;
                    cls[i + 1] = e;
                    i += 2;
                    continue;
                }
                cls[i] = LEX_STR;
                if s[i] == q {
                    i++;
                    break;
                }
                i++;
            }
            continue;
        }
        if c == '@' || c == '#' {
            i32 j = i + 1;
            while j < len && lex_ident_char(s[j]) { j++; }
            u8 k = LEX_PRE;
            if c == '@' && !lex_is_directive(s + i + 1, j - i - 1) {
                k = LEX_DECL;  // annotation (@must_use etc.)
            }
            lex_fill(cls, i, j, k);
            i = j;
            continue;
        }
        if c >= '0' && c <= '9' {
            i = lex_num(s, len, i, cls);
            continue;
        }
        if lex_ident_start(c) {
            i32 j = i + 1;
            bool has_lower = c >= 'a' && c <= 'z';
            while j < len && lex_ident_char(s[j]) {
                if s[j] >= 'a' && s[j] <= 'z' { has_lower = true; }
                j++;
            }
            i32 wlen = j - i;
            u8 k = LEX_VAR;
            if lex_is_ctrl(s + i, wlen) {
                k = LEX_CTRL;
            } else if lex_is_vec_type(s + i, wlen) {
                k = LEX_TYPE;
            } else if lex_is_decl(s + i, wlen) || lex_is_type(s + i, wlen)
                || lex_is_const_kw(s + i, wlen) {
                k = LEX_DECL;
            } else if lex_is_plain_kw(s + i, wlen) {
                k = LEX_DEF;
            } else if c >= 'A' && c <= 'Z' && has_lower {
                k = LEX_TYPE;
            } else if lex_before_paren(s, len, j) {
                k = LEX_FN;
            }
            lex_fill(cls, i, j, k);
            i = j;
            continue;
        }
        if c == '(' || c == '[' || c == '{' {
            cls[i] = lex_bracket_class(depth);
            if depth < LEX_DEPTH_MAX { depth++; }
            i++;
            continue;
        }
        if c == ')' || c == ']' || c == '}' {
            if depth > 0 { depth--; }
            cls[i] = lex_bracket_class(depth);
            i++;
            continue;
        }
        cls[i] = LEX_DEF;
        i++;
    }
    i32 out = depth;
    if in_com { out = out | LEX_IN_COMMENT; }
    return out;
}

// --- markdown --------------------------------------------------------
// Color-only Dark+ mapping: ATX headings, emphasis spans, and link
// titles LEX_DECL; code spans, fences, and link urls LEX_STR;
// blockquotes LEX_COM; list markers LEX_LIST. Carried state: inside
// a fenced code block. Emphasis and spans close on their own line.

private const i32 LEX_MD_FENCE = 1;

private bool lex_md_fence_at(u8* s, i32 len, i32 i) {
    return i + 2 < len && s[i] == 96 && s[i + 1] == 96 && s[i + 2] == 96;
}

private void lex_fill(u8* cls, i32 a, i32 b, u8 k) {
    for i32 i = a; i < b; i++ { cls[i] = k; }
}

i32 lex_md_line(u8* s, i32 len, i32 state, u8* cls) {
    lex_fill(cls, 0, len, LEX_DEF);
    i32 ws = 0;
    while ws < len && (s[ws] == ' ' || s[ws] == 9) { ws++; }
    if (state & LEX_MD_FENCE) != 0 {
        lex_fill(cls, 0, len, LEX_STR);
        if lex_md_fence_at(s, len, ws) { return 0; }
        return LEX_MD_FENCE;
    }
    if lex_md_fence_at(s, len, ws) {
        lex_fill(cls, ws, len, LEX_STR);
        return LEX_MD_FENCE;
    }
    if ws < len && s[ws] == '#' {
        i32 k = ws;
        while k < len && s[k] == '#' { k++; }
        if k - ws <= 6 && (k >= len || s[k] == ' ') {
            lex_fill(cls, ws, len, LEX_DECL);
            return 0;
        }
    }
    if ws < len && s[ws] == '>' {
        lex_fill(cls, ws, len, LEX_COM);
        return 0;
    }
    i32 p = ws;
    if p + 1 < len && (s[p] == '-' || s[p] == '+' || s[p] == '*') && s[p + 1] == ' ' {
        cls[p] = LEX_LIST;
        p += 2;
    } else {
        i32 d = p;
        while d < len && s[d] >= '0' && s[d] <= '9' { d++; }
        if d > p && d + 1 < len && (s[d] == '.' || s[d] == ')') && s[d + 1] == ' ' {
            lex_fill(cls, p, d + 1, LEX_LIST);
            p = d + 2;
        }
    }
    while p < len {
        u8 c = s[p];
        if c == 96 {
            i32 e = p + 1;
            while e < len && s[e] != 96 { e++; }
            if e < len {
                lex_fill(cls, p, e + 1, LEX_STR);
                p = e + 1;
                continue;
            }
        }
        if c == '*' || c == '_' {
            // '_' is literal inside words (snake_case); an emphasis
            // opener needs a boundary before it and ink after it
            if c == '_' && p > 0
                && ((s[p - 1] >= 'a' && s[p - 1] <= 'z')
                    || (s[p - 1] >= 'A' && s[p - 1] <= 'Z')
                    || (s[p - 1] >= '0' && s[p - 1] <= '9')) {
                p++;
                continue;
            }
            i32 m = 1;
            if p + 1 < len && s[p + 1] == c { m = 2; }
            if p + m >= len || s[p + m] == ' ' || s[p + m] == 9 {
                p += m;
                continue;
            }
            i32 e = p + m;
            while e < len {
                if s[e] == c && (m == 1 || (e + 1 < len && s[e + 1] == c)) { break; }
                e++;
            }
            if e < len && e > p + m {
                lex_fill(cls, p, e + m, LEX_DECL);
                p = e + m;
                continue;
            }
        }
        if c == '[' {
            i32 e = p + 1;
            while e < len && s[e] != ']' { e++; }
            if e < len {
                lex_fill(cls, p, e + 1, LEX_DECL);
                if e + 1 < len && s[e + 1] == '(' {
                    i32 u = e + 2;
                    while u < len && s[u] != ')' { u++; }
                    if u < len {
                        lex_fill(cls, e + 1, u + 1, LEX_STR);
                        p = u + 1;
                        continue;
                    }
                }
                p = e + 1;
                continue;
            }
        }
        p++;
    }
    return 0;
}

// --- shared scanners for the basic language lexers -------------------
// Each lex_*_line below fills one class per byte and returns a carried
// state for line-spanning constructs, the same contract as lex_line.
// Brackets are left LEX_DEF (rainbow off), so the carried state only
// tracks comments and strings. Keywords, strings, numbers and comments
// are the whole of "basic": no grammar, no server.

// a number run from i (s[i] is a digit): decimal, hex, float, with the
// usual letter/point/underscore tail. Always advances.
private i32 lex_num(u8* s, i32 len, i32 i, u8* cls) {
    i32 j = i;
    while j < len {
        u8 d = s[j];
        if d >= '0' && d <= '9' { j++; continue; }
        if d >= 'a' && d <= 'f' { j++; continue; }
        if d >= 'A' && d <= 'F' { j++; continue; }
        if d == 'x' || d == 'X' || d == '.' || d == '_' { j++; continue; }
        break;
    }
    lex_fill(cls, i, j, LEX_NUM);
    return j;
}

// a '...' or "..." string from i (s[i] is the quote); backslash escapes
// gold. Returns the index past the close, or len if it runs to the
// line end (these lexers do not carry single-line strings over).
private i32 lex_qstr(u8* s, i32 len, i32 i, u8* cls) {
    u8 q = s[i];
    cls[i] = LEX_STR;
    i++;
    while i < len {
        if s[i] == '\\' && i + 1 < len {
            cls[i] = LEX_ESC;
            cls[i + 1] = LEX_ESC;
            i += 2;
            continue;
        }
        cls[i] = LEX_STR;
        if s[i] == q {
            i++;
            break;
        }
        i++;
    }
    return i;
}

// an identifier immediately followed by '(' (ignoring spaces): a call
// or a definition, colored like a function name
private bool lex_before_paren(u8* s, i32 len, i32 j) {
    i32 p = j;
    while p < len && (s[p] == ' ' || s[p] == 9) { p++; }
    return p < len && s[p] == '(';
}

// --- JavaScript (.js, .mjs) ------------------------------------------
// Carried state: inside /* */, inside a `` `template` ``.

private const i32 LEX_JS_BLOCK = 1;
private const i32 LEX_JS_TMPL = 2;

private bool lex_js_ctrl(u8* s, i32 n) {
    return lex_word_eq(s, n, "if") || lex_word_eq(s, n, "else")
        || lex_word_eq(s, n, "for") || lex_word_eq(s, n, "while")
        || lex_word_eq(s, n, "do") || lex_word_eq(s, n, "return")
        || lex_word_eq(s, n, "break") || lex_word_eq(s, n, "continue")
        || lex_word_eq(s, n, "switch") || lex_word_eq(s, n, "case")
        || lex_word_eq(s, n, "default") || lex_word_eq(s, n, "throw")
        || lex_word_eq(s, n, "try") || lex_word_eq(s, n, "catch")
        || lex_word_eq(s, n, "finally") || lex_word_eq(s, n, "new")
        || lex_word_eq(s, n, "delete") || lex_word_eq(s, n, "typeof")
        || lex_word_eq(s, n, "instanceof") || lex_word_eq(s, n, "in")
        || lex_word_eq(s, n, "of") || lex_word_eq(s, n, "void")
        || lex_word_eq(s, n, "yield") || lex_word_eq(s, n, "await");
}

private bool lex_js_decl(u8* s, i32 n) {
    return lex_word_eq(s, n, "function") || lex_word_eq(s, n, "const")
        || lex_word_eq(s, n, "let") || lex_word_eq(s, n, "var")
        || lex_word_eq(s, n, "class") || lex_word_eq(s, n, "extends")
        || lex_word_eq(s, n, "import") || lex_word_eq(s, n, "export")
        || lex_word_eq(s, n, "from") || lex_word_eq(s, n, "as")
        || lex_word_eq(s, n, "static") || lex_word_eq(s, n, "get")
        || lex_word_eq(s, n, "set") || lex_word_eq(s, n, "async");
}

private bool lex_js_lit(u8* s, i32 n) {
    return lex_word_eq(s, n, "true") || lex_word_eq(s, n, "false")
        || lex_word_eq(s, n, "null") || lex_word_eq(s, n, "undefined")
        || lex_word_eq(s, n, "this") || lex_word_eq(s, n, "super")
        || lex_word_eq(s, n, "NaN") || lex_word_eq(s, n, "Infinity");
}

i32 lex_js_line(u8* s, i32 len, i32 state, u8* cls) {
    lex_fill(cls, 0, len, LEX_DEF);
    bool blk = (state & LEX_JS_BLOCK) != 0;
    bool tmpl = (state & LEX_JS_TMPL) != 0;
    i32 i = 0;
    while i < len {
        if blk {
            if s[i] == '*' && i + 1 < len && s[i + 1] == '/' {
                cls[i] = LEX_COM;
                cls[i + 1] = LEX_COM;
                i += 2;
                blk = false;
                continue;
            }
            cls[i] = LEX_COM;
            i++;
            continue;
        }
        if tmpl {
            if s[i] == '\\' && i + 1 < len {
                cls[i] = LEX_ESC;
                cls[i + 1] = LEX_ESC;
                i += 2;
                continue;
            }
            cls[i] = LEX_STR;
            if s[i] == 96 {
                i++;
                tmpl = false;
            } else {
                i++;
            }
            continue;
        }
        u8 c = s[i];
        if c == '/' && i + 1 < len && s[i + 1] == '/' {
            lex_fill(cls, i, len, LEX_COM);
            break;
        }
        if c == '/' && i + 1 < len && s[i + 1] == '*' {
            cls[i] = LEX_COM;
            cls[i + 1] = LEX_COM;
            i += 2;
            blk = true;
            continue;
        }
        if c == '"' || c == '\'' {
            i = lex_qstr(s, len, i, cls);
            continue;
        }
        if c == 96 {
            cls[i] = LEX_STR;
            i++;
            tmpl = true;
            continue;
        }
        if c >= '0' && c <= '9' {
            i = lex_num(s, len, i, cls);
            continue;
        }
        if lex_ident_start(c) {
            i32 j = i + 1;
            while j < len && lex_ident_char(s[j]) { j++; }
            i32 wl = j - i;
            u8 k = LEX_VAR;
            if lex_js_ctrl(s + i, wl) { k = LEX_CTRL; }
            else if lex_js_decl(s + i, wl) { k = LEX_DECL; }
            else if lex_js_lit(s + i, wl) { k = LEX_DECL; }
            else if lex_before_paren(s, len, j) { k = LEX_FN; }
            lex_fill(cls, i, j, k);
            i = j;
            continue;
        }
        i++;
    }
    i32 out = 0;
    if blk { out = out | LEX_JS_BLOCK; }
    if tmpl { out = out | LEX_JS_TMPL; }
    return out;
}

// --- Python (.py) ----------------------------------------------------
// Carried state: inside a triple-quoted string, and which quote it uses.

private const i32 LEX_PY_TRIPLE = 1;
private const i32 LEX_PY_TDQUOTE = 2;

private bool lex_py_triple(u8* s, i32 len, i32 i, u8 q) {
    return i + 3 <= len && s[i] == q && s[i + 1] == q && s[i + 2] == q;
}

private bool lex_py_ctrl(u8* s, i32 n) {
    return lex_word_eq(s, n, "if") || lex_word_eq(s, n, "elif")
        || lex_word_eq(s, n, "else") || lex_word_eq(s, n, "for")
        || lex_word_eq(s, n, "while") || lex_word_eq(s, n, "return")
        || lex_word_eq(s, n, "break") || lex_word_eq(s, n, "continue")
        || lex_word_eq(s, n, "try") || lex_word_eq(s, n, "except")
        || lex_word_eq(s, n, "finally") || lex_word_eq(s, n, "raise")
        || lex_word_eq(s, n, "with") || lex_word_eq(s, n, "as")
        || lex_word_eq(s, n, "pass") || lex_word_eq(s, n, "yield")
        || lex_word_eq(s, n, "assert") || lex_word_eq(s, n, "import")
        || lex_word_eq(s, n, "from") || lex_word_eq(s, n, "global")
        || lex_word_eq(s, n, "nonlocal") || lex_word_eq(s, n, "lambda")
        || lex_word_eq(s, n, "del") || lex_word_eq(s, n, "in")
        || lex_word_eq(s, n, "is") || lex_word_eq(s, n, "not")
        || lex_word_eq(s, n, "and") || lex_word_eq(s, n, "or")
        || lex_word_eq(s, n, "await") || lex_word_eq(s, n, "async");
}

private bool lex_py_lit(u8* s, i32 n) {
    return lex_word_eq(s, n, "True") || lex_word_eq(s, n, "False")
        || lex_word_eq(s, n, "None") || lex_word_eq(s, n, "self");
}

i32 lex_py_line(u8* s, i32 len, i32 state, u8* cls) {
    lex_fill(cls, 0, len, LEX_DEF);
    bool tri = (state & LEX_PY_TRIPLE) != 0;
    u8 tq = 39;
    if (state & LEX_PY_TDQUOTE) != 0 { tq = 34; }
    i32 i = 0;
    while i < len {
        if tri {
            if lex_py_triple(s, len, i, tq) {
                lex_fill(cls, i, i + 3, LEX_STR);
                i += 3;
                tri = false;
                continue;
            }
            cls[i] = LEX_STR;
            i++;
            continue;
        }
        u8 c = s[i];
        if c == '#' {
            lex_fill(cls, i, len, LEX_COM);
            break;
        }
        if c == 39 || c == 34 {
            if lex_py_triple(s, len, i, c) {
                lex_fill(cls, i, i + 3, LEX_STR);
                i += 3;
                tri = true;
                tq = c;
                continue;
            }
            i = lex_qstr(s, len, i, cls);
            continue;
        }
        if c >= '0' && c <= '9' {
            i = lex_num(s, len, i, cls);
            continue;
        }
        if lex_ident_start(c) {
            i32 j = i + 1;
            while j < len && lex_ident_char(s[j]) { j++; }
            i32 wl = j - i;
            u8 k = LEX_VAR;
            if lex_py_ctrl(s + i, wl) { k = LEX_CTRL; }
            else if lex_word_eq(s + i, wl, "def") || lex_word_eq(s + i, wl, "class") { k = LEX_DECL; }
            else if lex_py_lit(s + i, wl) { k = LEX_DECL; }
            else if lex_before_paren(s, len, j) { k = LEX_FN; }
            lex_fill(cls, i, j, k);
            i = j;
            continue;
        }
        i++;
    }
    i32 out = 0;
    if tri {
        out = LEX_PY_TRIPLE;
        if tq == 34 { out = out | LEX_PY_TDQUOTE; }
    }
    return out;
}

// --- shell: PowerShell (.ps1) and POSIX sh (.sh) ---------------------
// Carried state: inside a PowerShell <# #> block comment. Variables
// ($name) are colored; '#' starts a line comment in both dialects.

private const i32 LEX_SH_BLOCK = 1;

private bool lex_sh_kw(u8* s, i32 n) {
    return lex_word_eq(s, n, "if") || lex_word_eq(s, n, "then")
        || lex_word_eq(s, n, "else") || lex_word_eq(s, n, "elif")
        || lex_word_eq(s, n, "elseif") || lex_word_eq(s, n, "fi")
        || lex_word_eq(s, n, "for") || lex_word_eq(s, n, "foreach")
        || lex_word_eq(s, n, "while") || lex_word_eq(s, n, "do")
        || lex_word_eq(s, n, "done") || lex_word_eq(s, n, "case")
        || lex_word_eq(s, n, "esac") || lex_word_eq(s, n, "switch")
        || lex_word_eq(s, n, "in") || lex_word_eq(s, n, "return")
        || lex_word_eq(s, n, "break") || lex_word_eq(s, n, "continue")
        || lex_word_eq(s, n, "function") || lex_word_eq(s, n, "param")
        || lex_word_eq(s, n, "begin") || lex_word_eq(s, n, "process")
        || lex_word_eq(s, n, "end") || lex_word_eq(s, n, "filter")
        || lex_word_eq(s, n, "try") || lex_word_eq(s, n, "catch")
        || lex_word_eq(s, n, "finally") || lex_word_eq(s, n, "throw")
        || lex_word_eq(s, n, "local") || lex_word_eq(s, n, "export");
}

i32 lex_sh_line(u8* s, i32 len, i32 state, u8* cls) {
    lex_fill(cls, 0, len, LEX_DEF);
    bool blk = (state & LEX_SH_BLOCK) != 0;
    i32 i = 0;
    while i < len {
        if blk {
            if s[i] == '#' && i + 1 < len && s[i + 1] == '>' {
                cls[i] = LEX_COM;
                cls[i + 1] = LEX_COM;
                i += 2;
                blk = false;
                continue;
            }
            cls[i] = LEX_COM;
            i++;
            continue;
        }
        u8 c = s[i];
        if c == '<' && i + 1 < len && s[i + 1] == '#' {
            cls[i] = LEX_COM;
            cls[i + 1] = LEX_COM;
            i += 2;
            blk = true;
            continue;
        }
        if c == '#' {
            lex_fill(cls, i, len, LEX_COM);
            break;
        }
        if c == '$' {
            i32 j = i + 1;
            while j < len && (lex_ident_char(s[j]) || s[j] == ':') { j++; }
            if j > i + 1 {
                lex_fill(cls, i, j, LEX_VAR);
                i = j;
            } else {
                i++;
            }
            continue;
        }
        if c == 39 || c == 34 {
            i = lex_qstr(s, len, i, cls);
            continue;
        }
        if c >= '0' && c <= '9' {
            i = lex_num(s, len, i, cls);
            continue;
        }
        if lex_ident_start(c) {
            i32 j = i + 1;
            while j < len && lex_ident_char(s[j]) { j++; }
            i32 wl = j - i;
            u8 k = LEX_DEF;
            if lex_sh_kw(s + i, wl) { k = LEX_CTRL; }
            lex_fill(cls, i, j, k);
            i = j;
            continue;
        }
        i++;
    }
    i32 out = 0;
    if blk { out = LEX_SH_BLOCK; }
    return out;
}

// --- HTML (.html, .htm) ----------------------------------------------
// Tag names are types, attribute names variables, attribute values
// strings. The body of a <script> goes to the JavaScript lexer and the
// body of a <style> to the CSS lexer, up to the closing tag, which ends
// the body wherever it appears, as it does in a browser.
// Carried state: bit 0 inside <!-- -->, bit 1 inside a < ... > tag,
// bits 2-3 the element whose body follows its tag (LEX_HT_SCRIPT,
// LEX_HT_STYLE): inside its opening tag while bit 1 is set, inside the
// body after. Bits 4-7 are the embedded lexer's own state.

private const i32 LEX_HT_COMMENT = 1;
private const i32 LEX_HT_TAG = 2;
private const i32 LEX_HT_KIND_SHIFT = 2;
private const i32 LEX_HT_KIND_MASK = 3;
private const i32 LEX_HT_SCRIPT = 1;
private const i32 LEX_HT_STYLE = 2;
private const i32 LEX_HT_INNER_SHIFT = 4;
private const i32 LEX_HT_INNER_MASK = 15;

private bool lex_ht_name_char(u8 c) {
    return lex_ident_char(c) || c == '-' || c == ':';
}

// s[0..n) is w, ignoring ASCII case
private bool lex_ieq(u8* s, i32 n, str w) {
    if n != w.len { return false; }
    for i32 k = 0; k < n; k++ {
        u8 c = s[k];
        if c >= 'A' && c <= 'Z' { c = cast(u8, c + 32); }
        if c != w.data[k] { return false; }
    }
    return true;
}

// where the body of element `kind` ends on the line: the "</script" or
// "</style" at or after i, or len
private i32 lex_ht_body_end(u8* s, i32 len, i32 i, i32 kind) {
    str w = "script";
    if kind == LEX_HT_STYLE { w = "style"; }
    for i32 k = i; k + 2 + w.len <= len; k++ {
        if s[k] == '<' && s[k + 1] == '/' && lex_ieq(s + k + 2, w.len, w) { return k; }
    }
    return len;
}

i32 lex_html_line(u8* s, i32 len, i32 state, u8* cls) {
    lex_fill(cls, 0, len, LEX_DEF);
    bool com = (state & LEX_HT_COMMENT) != 0;
    bool tag = (state & LEX_HT_TAG) != 0;
    i32 kind = (state >> LEX_HT_KIND_SHIFT) & LEX_HT_KIND_MASK;
    i32 inner = (state >> LEX_HT_INNER_SHIFT) & LEX_HT_INNER_MASK;
    i32 i = 0;
    while i < len {
        if kind != 0 && !tag {
            // a script or style body, up to its closing tag
            i32 e = lex_ht_body_end(s, len, i, kind);
            if kind == LEX_HT_SCRIPT {
                inner = lex_js_line(s + i, e - i, inner, cls + i);
            } else {
                inner = lex_css_line(s + i, e - i, inner, cls + i);
            }
            i = e;
            if e < len {
                kind = 0;
                inner = 0;
            }
            continue;
        }
        if com {
            if i + 3 <= len && s[i] == '-' && s[i + 1] == '-' && s[i + 2] == '>' {
                lex_fill(cls, i, i + 3, LEX_COM);
                i += 3;
                com = false;
                continue;
            }
            cls[i] = LEX_COM;
            i++;
            continue;
        }
        if tag {
            u8 c = s[i];
            if c == '>' {
                i++;
                tag = false;
                inner = 0;
                continue;
            }
            if c == '"' || c == '\'' {
                i = lex_qstr(s, len, i, cls);
                continue;
            }
            if lex_ident_start(c) {
                i32 j = i + 1;
                while j < len && lex_ht_name_char(s[j]) { j++; }
                lex_fill(cls, i, j, LEX_VAR);
                i = j;
                continue;
            }
            i++;
            continue;
        }
        u8 c = s[i];
        if c == '<' && i + 4 <= len && s[i + 1] == '!' && s[i + 2] == '-' && s[i + 3] == '-' {
            lex_fill(cls, i, i + 4, LEX_COM);
            i += 4;
            com = true;
            continue;
        }
        if c == '<' && i + 1 < len && s[i + 1] == '!' {
            i32 j = i;
            while j < len && s[j] != '>' { j++; }
            if j < len { j++; }
            lex_fill(cls, i, j, LEX_PRE);
            i = j;
            continue;
        }
        if c == '<' {
            i++;
            bool close = i < len && s[i] == '/';
            if close { i++; }
            i32 j = i;
            while j < len && lex_ht_name_char(s[j]) { j++; }
            lex_fill(cls, i, j, LEX_TYPE);
            kind = 0;
            if !close && lex_ieq(s + i, j - i, "script") { kind = LEX_HT_SCRIPT; }
            if !close && lex_ieq(s + i, j - i, "style") { kind = LEX_HT_STYLE; }
            i = j;
            tag = true;
            continue;
        }
        if c == '&' {
            i32 j = i + 1;
            while j < len && (lex_ident_char(s[j]) || s[j] == '#') { j++; }
            if j < len && s[j] == ';' {
                j++;
                lex_fill(cls, i, j, LEX_ESC);
                i = j;
                continue;
            }
        }
        i++;
    }
    i32 out = 0;
    if com { out = out | LEX_HT_COMMENT; }
    if tag { out = out | LEX_HT_TAG; }
    out = out | (kind << LEX_HT_KIND_SHIFT);
    if kind != 0 && !tag { out = out | (inner << LEX_HT_INNER_SHIFT); }
    return out;
}

// --- CSS (.css) ------------------------------------------------------
// Selectors are types, property names and custom properties variables,
// keyword values strings, numbers with their units and hex colors
// numbers, functions function names, at-rules and !important control
// keywords. Carried state: bit 0 inside /* */, bit 1 inside a
// declaration's value or an at-rule's prelude, bits 2-3 the brace depth (held at 3). The state
// fits in four bits, the room the HTML lexer has for a <style> body.

private const i32 LEX_CSS_BLOCK = 1;
private const i32 LEX_CSS_VALUE = 2;
private const i32 LEX_CSS_DEPTH_SHIFT = 2;
private const i32 LEX_CSS_DEPTH_MAX = 3;

private bool lex_css_name_char(u8 c) {
    return lex_ident_char(c) || c == '-';
}

private bool lex_css_name_start(u8* s, i32 len, i32 i) {
    if lex_ident_start(s[i]) { return true; }
    return s[i] == '-' && i + 1 < len && (lex_ident_start(s[i + 1]) || s[i + 1] == '-');
}

// the next character after spaces from j is ':'
private bool lex_css_colon_next(u8* s, i32 len, i32 j) {
    while j < len && (s[j] == ' ' || s[j] == 9) { j++; }
    return j < len && s[j] == ':';
}

// At a name inside a block: a property when the line has a ':' and no
// '{' before its first ';' or '}', and does not end in ','. Otherwise a
// selector, as at the top level.
private bool lex_css_is_prop(u8* s, i32 len, i32 i, i32 depth) {
    if depth == 0 { return false; }
    bool colon = false;
    for i32 k = i; k < len; k++ {
        u8 c = s[k];
        if c == '{' { return false; }
        if c == ';' || c == '}' { return colon; }
        if c == ':' { colon = true; }
    }
    i32 e = len;
    while e > i && (s[e - 1] == ' ' || s[e - 1] == 9) { e--; }
    if e > i && s[e - 1] == ',' { return false; }
    return colon;
}

i32 lex_css_line(u8* s, i32 len, i32 state, u8* cls) {
    lex_fill(cls, 0, len, LEX_DEF);
    bool com = (state & LEX_CSS_BLOCK) != 0;
    bool val = (state & LEX_CSS_VALUE) != 0;
    i32 depth = (state >> LEX_CSS_DEPTH_SHIFT) & LEX_CSS_DEPTH_MAX;
    i32 i = 0;
    while i < len {
        u8 c = s[i];
        if com {
            if c == '*' && i + 1 < len && s[i + 1] == '/' {
                cls[i] = LEX_COM;
                cls[i + 1] = LEX_COM;
                i += 2;
                com = false;
                continue;
            }
            cls[i] = LEX_COM;
            i++;
            continue;
        }
        if c == '/' && i + 1 < len && s[i + 1] == '*' {
            cls[i] = LEX_COM;
            cls[i + 1] = LEX_COM;
            i += 2;
            com = true;
            continue;
        }
        if c == '{' {
            if depth < LEX_CSS_DEPTH_MAX { depth++; }
            val = false;
            i++;
            continue;
        }
        if c == '}' {
            if depth > 0 { depth--; }
            val = false;
            i++;
            continue;
        }
        if c == ';' {
            val = false;
            i++;
            continue;
        }
        if c == '"' || c == '\'' {
            i = lex_qstr(s, len, i, cls);
            continue;
        }
        if c == '@' && i + 1 < len && lex_ident_start(s[i + 1]) {
            i32 j = i + 1;
            while j < len && lex_css_name_char(s[j]) { j++; }
            lex_fill(cls, i, j, LEX_CTRL);
            i = j;
            // the prelude up to '{' or ';' lexes as a value
            val = true;
            continue;
        }
        bool digit = c >= '0' && c <= '9';
        bool num = digit || ((c == '.' || c == '-' || c == '+') && i + 1 < len && s[i + 1] >= '0' && s[i + 1] <= '9');
        if num {
            // a number with its unit: 1.5em, -2px, 50%
            i32 j = i + 1;
            while j < len && ((s[j] >= '0' && s[j] <= '9') || s[j] == '.') { j++; }
            while j < len && (lex_ident_start(s[j]) || s[j] == '%') { j++; }
            lex_fill(cls, i, j, LEX_NUM);
            i = j;
            continue;
        }
        if val {
            if c == '!' && i + 1 < len && lex_ident_start(s[i + 1]) {
                i32 j = i + 1;
                while j < len && lex_ident_char(s[j]) { j++; }
                lex_fill(cls, i, j, LEX_CTRL);
                i = j;
                continue;
            }
            if c == '#' {
                i32 j = i + 1;
                while j < len && lex_ident_char(s[j]) { j++; }
                lex_fill(cls, i, j, LEX_NUM);
                i = j;
                continue;
            }
            if lex_css_name_start(s, len, i) {
                i32 j = i + 1;
                while j < len && lex_css_name_char(s[j]) { j++; }
                if j < len && s[j] == '(' {
                    lex_fill(cls, i, j, LEX_FN);
                    // url(...) unquoted: the address is a string
                    if lex_word_eq(s + i, j - i, "url") && j + 1 < len && s[j + 1] != '"' && s[j + 1] != '\'' {
                        i32 e = j + 1;
                        while e < len && s[e] != ')' { e++; }
                        lex_fill(cls, j + 1, e, LEX_STR);
                        i = e;
                        continue;
                    }
                } else if c == '-' && s[i + 1] == '-' {
                    lex_fill(cls, i, j, LEX_VAR);
                } else if lex_css_colon_next(s, len, j) {
                    // a feature in a prelude: (max-width: 600px)
                    lex_fill(cls, i, j, LEX_VAR);
                } else {
                    lex_fill(cls, i, j, LEX_STR);
                }
                i = j;
                continue;
            }
            i++;
            continue;
        }
        if lex_css_name_start(s, len, i) && lex_css_is_prop(s, len, i, depth) {
            i32 j = i + 1;
            while j < len && lex_css_name_char(s[j]) { j++; }
            lex_fill(cls, i, j, LEX_VAR);
            while j < len && (s[j] == ' ' || s[j] == 9) { j++; }
            if j < len && s[j] == ':' {
                j++;
                val = true;
            }
            i = j;
            continue;
        }
        // a selector: a tag, .class, #id, :pseudo or ::pseudo
        i32 st = i;
        while i < len && (s[i] == '.' || s[i] == '#' || s[i] == ':') { i++; }
        if i < len && lex_css_name_start(s, len, i) {
            i32 j = i + 1;
            while j < len && lex_css_name_char(s[j]) { j++; }
            lex_fill(cls, st, j, LEX_TYPE);
            i = j;
            continue;
        }
        if i == st { i++; }
    }
    i32 out = depth << LEX_CSS_DEPTH_SHIFT;
    if com { out = out | LEX_CSS_BLOCK; }
    if val { out = out | LEX_CSS_VALUE; }
    return out;
}

// --- GameMaker Language (.gml) -----------------------------------------
// Carried state: inside /* */, inside a verbatim @"..." or @'...' string,
// which spans lines and has no escapes. A "///" comment colors its
// @tags. $"..." is a template string; its {expr} parts lex as code.
// $FF and #RRGGBB are numbers. #macro, #region and #endregion are
// directives, and a region's label is a comment.

private const i32 LEX_GML_BLOCK = 1;
private const i32 LEX_GML_VERB = 2;
private const i32 LEX_GML_VERB_SQ = 4;   // the verbatim string closes on '

private const i32 LEX_GML_HEX_COLOR = 6;   // #RRGGBB

private bool lex_gml_ctrl(u8* s, i32 n) {
    return lex_word_eq(s, n, "if") || lex_word_eq(s, n, "else")
        || lex_word_eq(s, n, "then") || lex_word_eq(s, n, "for")
        || lex_word_eq(s, n, "while") || lex_word_eq(s, n, "do")
        || lex_word_eq(s, n, "until") || lex_word_eq(s, n, "repeat")
        || lex_word_eq(s, n, "switch") || lex_word_eq(s, n, "case")
        || lex_word_eq(s, n, "default") || lex_word_eq(s, n, "break")
        || lex_word_eq(s, n, "continue") || lex_word_eq(s, n, "exit")
        || lex_word_eq(s, n, "return") || lex_word_eq(s, n, "with")
        || lex_word_eq(s, n, "try") || lex_word_eq(s, n, "catch")
        || lex_word_eq(s, n, "finally") || lex_word_eq(s, n, "throw")
        || lex_word_eq(s, n, "new") || lex_word_eq(s, n, "delete")
        || lex_word_eq(s, n, "begin") || lex_word_eq(s, n, "end")
        || lex_word_eq(s, n, "and") || lex_word_eq(s, n, "or")
        || lex_word_eq(s, n, "not") || lex_word_eq(s, n, "xor")
        || lex_word_eq(s, n, "div") || lex_word_eq(s, n, "mod");
}

private bool lex_gml_decl(u8* s, i32 n) {
    return lex_word_eq(s, n, "var") || lex_word_eq(s, n, "globalvar")
        || lex_word_eq(s, n, "function") || lex_word_eq(s, n, "constructor")
        || lex_word_eq(s, n, "static") || lex_word_eq(s, n, "enum");
}

private bool lex_gml_lit(u8* s, i32 n) {
    return lex_word_eq(s, n, "true") || lex_word_eq(s, n, "false")
        || lex_word_eq(s, n, "self") || lex_word_eq(s, n, "other")
        || lex_word_eq(s, n, "all") || lex_word_eq(s, n, "noone")
        || lex_word_eq(s, n, "global") || lex_word_eq(s, n, "undefined")
        || lex_word_eq(s, n, "pi") || lex_word_eq(s, n, "infinity")
        || lex_word_eq(s, n, "NaN") || lex_word_eq(s, n, "pointer_null")
        || lex_word_eq(s, n, "pointer_invalid");
}

private bool lex_hex_digit(u8 c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

// an identifier run from i, colored as a GML word. Returns its end.
private i32 lex_gml_word(u8* s, i32 len, i32 i, u8* cls) {
    i32 j = i + 1;
    while j < len && lex_ident_char(s[j]) { j++; }
    i32 wl = j - i;
    u8 k = LEX_VAR;
    if lex_gml_ctrl(s + i, wl) { k = LEX_CTRL; }
    else if lex_gml_decl(s + i, wl) || lex_gml_lit(s + i, wl) { k = LEX_DECL; }
    else if lex_before_paren(s, len, j) { k = LEX_FN; }
    lex_fill(cls, i, j, k);
    return j;
}

// a $"..." template string from i (s[i] is '$'). The braces of an
// {expr} part are escapes, and its words lex as code. Returns the index
// past the close, or len.
private i32 lex_gml_template(u8* s, i32 len, i32 i, u8* cls) {
    cls[i] = LEX_STR;
    cls[i + 1] = LEX_STR;
    i += 2;
    bool code = false;
    while i < len {
        u8 c = s[i];
        if code {
            if c == '}' {
                cls[i] = LEX_ESC;
                code = false;
                i++;
            } else if lex_ident_start(c) {
                i = lex_gml_word(s, len, i, cls);
            } else if c >= '0' && c <= '9' {
                i = lex_num(s, len, i, cls);
            } else {
                i++;
            }
            continue;
        }
        if c == '\\' && i + 1 < len {
            cls[i] = LEX_ESC;
            cls[i + 1] = LEX_ESC;
            i += 2;
            continue;
        }
        if c == '{' {
            cls[i] = LEX_ESC;
            code = true;
            i++;
            continue;
        }
        cls[i] = LEX_STR;
        i++;
        if c == '"' { break; }
    }
    return i;
}

i32 lex_gml_line(u8* s, i32 len, i32 state, u8* cls) {
    lex_fill(cls, 0, len, LEX_DEF);
    bool blk = (state & LEX_GML_BLOCK) != 0;
    bool verb = (state & LEX_GML_VERB) != 0;
    u8 vq = '"';
    if (state & LEX_GML_VERB_SQ) != 0 { vq = '\''; }
    i32 i = 0;
    while i < len {
        if blk {
            if s[i] == '*' && i + 1 < len && s[i + 1] == '/' {
                cls[i] = LEX_COM;
                cls[i + 1] = LEX_COM;
                i += 2;
                blk = false;
                continue;
            }
            cls[i] = LEX_COM;
            i++;
            continue;
        }
        if verb {
            cls[i] = LEX_STR;
            if s[i] == vq { verb = false; }
            i++;
            continue;
        }
        u8 c = s[i];
        if c == '/' && i + 2 < len && s[i + 1] == '/' && s[i + 2] == '/' {
            lex_fill(cls, i, len, LEX_COM);
            i32 t = i + 3;
            while t < len {
                if s[t] == '@' && t + 1 < len && lex_ident_start(s[t + 1]) {
                    i32 e = t + 1;
                    while e < len && lex_ident_char(s[e]) { e++; }
                    lex_fill(cls, t, e, LEX_DECL);
                    t = e;
                    continue;
                }
                t++;
            }
            break;
        }
        if c == '/' && i + 1 < len && s[i + 1] == '/' {
            lex_fill(cls, i, len, LEX_COM);
            break;
        }
        if c == '/' && i + 1 < len && s[i + 1] == '*' {
            cls[i] = LEX_COM;
            cls[i + 1] = LEX_COM;
            i += 2;
            blk = true;
            continue;
        }
        if c == '@' && i + 1 < len && (s[i + 1] == '"' || s[i + 1] == '\'') {
            vq = s[i + 1];
            cls[i] = LEX_STR;
            cls[i + 1] = LEX_STR;
            i += 2;
            verb = true;
            continue;
        }
        if c == '$' && i + 1 < len && s[i + 1] == '"' {
            i = lex_gml_template(s, len, i, cls);
            continue;
        }
        if c == '$' && i + 1 < len && lex_hex_digit(s[i + 1]) {
            cls[i] = LEX_NUM;
            i = lex_num(s, len, i + 1, cls);
            continue;
        }
        if c == '#' && i + 1 < len && lex_ident_start(s[i + 1]) {
            i32 j = i + 1;
            while j < len && lex_ident_char(s[j]) { j++; }
            u8* d = s + i + 1;
            i32 dl = j - i - 1;
            if lex_word_eq(d, dl, "region") || lex_word_eq(d, dl, "endregion") {
                lex_fill(cls, i, j, LEX_PRE);
                lex_fill(cls, j, len, LEX_COM);
                break;
            }
            if lex_word_eq(d, dl, "macro") {
                lex_fill(cls, i, j, LEX_PRE);
                i = j;
                continue;
            }
        }
        if c == '#' && i + 1 < len && lex_hex_digit(s[i + 1]) {
            i32 j = i + 1;
            while j < len && lex_hex_digit(s[j]) { j++; }
            if j - i - 1 == LEX_GML_HEX_COLOR && (j >= len || !lex_ident_char(s[j])) {
                lex_fill(cls, i, j, LEX_NUM);
                i = j;
                continue;
            }
        }
        if c == '"' || c == '\'' {
            i = lex_qstr(s, len, i, cls);
            continue;
        }
        if c >= '0' && c <= '9' {
            i = lex_num(s, len, i, cls);
            continue;
        }
        if lex_ident_start(c) {
            i = lex_gml_word(s, len, i, cls);
            continue;
        }
        i++;
    }
    i32 out = 0;
    if blk { out = out | LEX_GML_BLOCK; }
    if verb {
        out = out | LEX_GML_VERB;
        if vq == '\'' { out = out | LEX_GML_VERB_SQ; }
    }
    return out;
}

// --- C and C++ (.c, .h, .cpp, .hpp, .cc, .cxx, .hh) ------------------
// One lexer for both; the C++ words are rare as names in C. Carried
// state: inside /* */. A preprocessor directive is a directive word
// and, after #include, a <path> string; the rest of its line lexes as
// code. Built-in types are blue, the fixed-width typedefs teal.

private const i32 LEX_C_BLOCK = 1;

private bool lex_c_ctrl(u8* s, i32 n) {
    return lex_word_eq(s, n, "if") || lex_word_eq(s, n, "else")
        || lex_word_eq(s, n, "for") || lex_word_eq(s, n, "while")
        || lex_word_eq(s, n, "do") || lex_word_eq(s, n, "switch")
        || lex_word_eq(s, n, "case") || lex_word_eq(s, n, "default")
        || lex_word_eq(s, n, "break") || lex_word_eq(s, n, "continue")
        || lex_word_eq(s, n, "return") || lex_word_eq(s, n, "goto")
        || lex_word_eq(s, n, "try") || lex_word_eq(s, n, "catch")
        || lex_word_eq(s, n, "throw") || lex_word_eq(s, n, "new")
        || lex_word_eq(s, n, "delete") || lex_word_eq(s, n, "co_await")
        || lex_word_eq(s, n, "co_return") || lex_word_eq(s, n, "co_yield");
}

private bool lex_c_decl(u8* s, i32 n) {
    return lex_word_eq(s, n, "auto") || lex_word_eq(s, n, "const")
        || lex_word_eq(s, n, "static") || lex_word_eq(s, n, "extern")
        || lex_word_eq(s, n, "register") || lex_word_eq(s, n, "volatile")
        || lex_word_eq(s, n, "inline") || lex_word_eq(s, n, "typedef")
        || lex_word_eq(s, n, "struct") || lex_word_eq(s, n, "union")
        || lex_word_eq(s, n, "enum") || lex_word_eq(s, n, "sizeof")
        || lex_word_eq(s, n, "restrict") || lex_word_eq(s, n, "_Alignas")
        || lex_word_eq(s, n, "_Alignof") || lex_word_eq(s, n, "_Atomic")
        || lex_word_eq(s, n, "_Noreturn") || lex_word_eq(s, n, "_Static_assert")
        || lex_word_eq(s, n, "_Thread_local") || lex_word_eq(s, n, "_Generic")
        || lex_word_eq(s, n, "class") || lex_word_eq(s, n, "namespace")
        || lex_word_eq(s, n, "template") || lex_word_eq(s, n, "typename")
        || lex_word_eq(s, n, "using") || lex_word_eq(s, n, "public")
        || lex_word_eq(s, n, "private") || lex_word_eq(s, n, "protected")
        || lex_word_eq(s, n, "virtual") || lex_word_eq(s, n, "override")
        || lex_word_eq(s, n, "final") || lex_word_eq(s, n, "friend")
        || lex_word_eq(s, n, "operator") || lex_word_eq(s, n, "explicit")
        || lex_word_eq(s, n, "constexpr") || lex_word_eq(s, n, "consteval")
        || lex_word_eq(s, n, "constinit") || lex_word_eq(s, n, "mutable")
        || lex_word_eq(s, n, "noexcept") || lex_word_eq(s, n, "alignas")
        || lex_word_eq(s, n, "alignof") || lex_word_eq(s, n, "decltype")
        || lex_word_eq(s, n, "static_assert") || lex_word_eq(s, n, "thread_local")
        || lex_word_eq(s, n, "concept") || lex_word_eq(s, n, "requires")
        || lex_word_eq(s, n, "export") || lex_word_eq(s, n, "module")
        || lex_word_eq(s, n, "import") || lex_word_eq(s, n, "typeid")
        || lex_word_eq(s, n, "static_cast") || lex_word_eq(s, n, "dynamic_cast")
        || lex_word_eq(s, n, "const_cast") || lex_word_eq(s, n, "reinterpret_cast")
        || lex_word_eq(s, n, "this") || lex_word_eq(s, n, "nullptr")
        || lex_word_eq(s, n, "true") || lex_word_eq(s, n, "false")
        || lex_word_eq(s, n, "NULL");
}

private bool lex_c_prim(u8* s, i32 n) {
    return lex_word_eq(s, n, "void") || lex_word_eq(s, n, "char")
        || lex_word_eq(s, n, "short") || lex_word_eq(s, n, "int")
        || lex_word_eq(s, n, "long") || lex_word_eq(s, n, "float")
        || lex_word_eq(s, n, "double") || lex_word_eq(s, n, "signed")
        || lex_word_eq(s, n, "unsigned") || lex_word_eq(s, n, "bool")
        || lex_word_eq(s, n, "_Bool") || lex_word_eq(s, n, "wchar_t")
        || lex_word_eq(s, n, "char8_t") || lex_word_eq(s, n, "char16_t")
        || lex_word_eq(s, n, "char32_t");
}

// the stddef and stdint names: size_t, int32_t, uintptr_t and the like
private bool lex_c_typedef(u8* s, i32 n) {
    return n > 2 && s[n - 2] == '_' && s[n - 1] == 't'
        && (lex_word_eq(s, n, "size_t") || lex_word_eq(s, n, "ssize_t")
            || lex_word_eq(s, n, "ptrdiff_t") || lex_word_eq(s, n, "intptr_t")
            || lex_word_eq(s, n, "uintptr_t") || lex_word_eq(s, n, "intmax_t")
            || lex_word_eq(s, n, "uintmax_t") || lex_word_eq(s, n, "int8_t")
            || lex_word_eq(s, n, "int16_t") || lex_word_eq(s, n, "int32_t")
            || lex_word_eq(s, n, "int64_t") || lex_word_eq(s, n, "uint8_t")
            || lex_word_eq(s, n, "uint16_t") || lex_word_eq(s, n, "uint32_t")
            || lex_word_eq(s, n, "uint64_t") || lex_word_eq(s, n, "nullptr_t"));
}

i32 lex_c_line(u8* s, i32 len, i32 state, u8* cls) {
    lex_fill(cls, 0, len, LEX_DEF);
    bool blk = (state & LEX_C_BLOCK) != 0;
    // a directive starts the line, after any blanks
    i32 ws = 0;
    while ws < len && (s[ws] == ' ' || s[ws] == 9) { ws++; }
    i32 i = 0;
    if !blk && ws < len && s[ws] == '#' {
        i32 j = ws + 1;
        while j < len && (s[j] == ' ' || s[j] == 9) { j++; }
        i32 w0 = j;
        while j < len && lex_ident_char(s[j]) { j++; }
        lex_fill(cls, ws, j, LEX_PRE);
        bool inc = lex_word_eq(s + w0, j - w0, "include") || lex_word_eq(s + w0, j - w0, "import");
        while j < len && (s[j] == ' ' || s[j] == 9) { j++; }
        if inc && j < len && s[j] == '<' {
            i32 e = j + 1;
            while e < len && s[e] != '>' { e++; }
            if e < len { e++; }
            lex_fill(cls, j, e, LEX_STR);
            j = e;
        }
        i = j;
    }
    while i < len {
        if blk {
            if s[i] == '*' && i + 1 < len && s[i + 1] == '/' {
                cls[i] = LEX_COM;
                cls[i + 1] = LEX_COM;
                i += 2;
                blk = false;
                continue;
            }
            cls[i] = LEX_COM;
            i++;
            continue;
        }
        u8 c = s[i];
        if c == '/' && i + 1 < len && s[i + 1] == '/' {
            lex_fill(cls, i, len, LEX_COM);
            break;
        }
        if c == '/' && i + 1 < len && s[i + 1] == '*' {
            cls[i] = LEX_COM;
            cls[i + 1] = LEX_COM;
            i += 2;
            blk = true;
            continue;
        }
        if c == '"' || c == '\'' {
            i = lex_qstr(s, len, i, cls);
            continue;
        }
        if c >= '0' && c <= '9' {
            i = lex_num(s, len, i, cls);
            // the suffixes: 10u, 10ul, 1.5f
            while i < len && (s[i] == 'u' || s[i] == 'U' || s[i] == 'l' || s[i] == 'L') {
                cls[i] = LEX_NUM;
                i++;
            }
            continue;
        }
        if lex_ident_start(c) {
            i32 j = i + 1;
            while j < len && lex_ident_char(s[j]) { j++; }
            i32 wl = j - i;
            // L"..", u8"..", u"..", U"..": the prefix is part of the string
            if j < len && (s[j] == '"' || s[j] == '\'')
                && (lex_word_eq(s + i, wl, "L") || lex_word_eq(s + i, wl, "u8")
                    || lex_word_eq(s + i, wl, "u") || lex_word_eq(s + i, wl, "U")) {
                lex_fill(cls, i, j, LEX_STR);
                i = lex_qstr(s, len, j, cls);
                continue;
            }
            u8 k = LEX_VAR;
            if lex_c_ctrl(s + i, wl) { k = LEX_CTRL; }
            else if lex_c_decl(s + i, wl) || lex_c_prim(s + i, wl) { k = LEX_DECL; }
            else if lex_c_typedef(s + i, wl) { k = LEX_TYPE; }
            else if lex_before_paren(s, len, j) { k = LEX_FN; }
            lex_fill(cls, i, j, k);
            i = j;
            continue;
        }
        i++;
    }
    if blk { return LEX_C_BLOCK; }
    return 0;
}

// --- JSON (.json) ----------------------------------------------------
// Strings are values; a string followed by ':' is a key (blue). No
// comments, no carried state.

i32 lex_json_line(u8* s, i32 len, i32 state, u8* cls) {
    lex_fill(cls, 0, len, LEX_DEF);
    i32 i = 0;
    while i < len {
        u8 c = s[i];
        if c == '"' {
            i32 e = lex_qstr(s, len, i, cls);
            i32 p = e;
            while p < len && (s[p] == ' ' || s[p] == 9) { p++; }
            if p < len && s[p] == ':' { lex_fill(cls, i, e, LEX_DECL); }
            i = e;
            continue;
        }
        if c >= '0' && c <= '9' {
            i = lex_num(s, len, i, cls);
            continue;
        }
        if lex_ident_start(c) {
            i32 j = i + 1;
            while j < len && lex_ident_char(s[j]) { j++; }
            i32 wl = j - i;
            u8 k = LEX_DEF;
            if lex_word_eq(s + i, wl, "true") || lex_word_eq(s + i, wl, "false")
                || lex_word_eq(s + i, wl, "null") { k = LEX_DECL; }
            lex_fill(cls, i, j, k);
            i = j;
            continue;
        }
        i++;
    }
    return 0;
}

// --- YAML (.yml, .yaml) ----------------------------------------------
// Line oriented: a "key:" before a space is a key, '#' after space is a
// comment, quoted scalars are strings. Block scalars are not tracked.

i32 lex_yaml_line(u8* s, i32 len, i32 state, u8* cls) {
    lex_fill(cls, 0, len, LEX_DEF);
    i32 ws = 0;
    while ws < len && (s[ws] == ' ' || s[ws] == 9) { ws++; }
    if ws >= len { return 0; }
    i32 i = ws;
    if s[i] == '-' && (i + 1 >= len || s[i + 1] == ' ') {
        cls[i] = LEX_LIST;
        i++;
        while i < len && s[i] == ' ' { i++; }
    }
    if i < len && s[i] == '#' {
        lex_fill(cls, i, len, LEX_COM);
        return 0;
    }
    i32 c = i;
    i32 colon = -1;
    while c < len {
        if s[c] == '#' { break; }
        if s[c] == ':' && (c + 1 >= len || s[c + 1] == ' ' || s[c + 1] == 9) {
            colon = c;
            break;
        }
        c++;
    }
    if colon >= 0 {
        lex_fill(cls, i, colon, LEX_DECL);
        i = colon + 1;
    }
    while i < len {
        u8 ch = s[i];
        if ch == '#' && i > 0 && (s[i - 1] == ' ' || s[i - 1] == 9) {
            lex_fill(cls, i, len, LEX_COM);
            break;
        }
        if ch == 34 || ch == 39 {
            i = lex_qstr(s, len, i, cls);
            continue;
        }
        if ch >= '0' && ch <= '9' {
            i = lex_num(s, len, i, cls);
            continue;
        }
        if lex_ident_start(ch) {
            i32 j = i + 1;
            while j < len && lex_ident_char(s[j]) { j++; }
            i32 wl = j - i;
            u8 k = LEX_DEF;
            if lex_word_eq(s + i, wl, "true") || lex_word_eq(s + i, wl, "false")
                || lex_word_eq(s + i, wl, "null") || lex_word_eq(s + i, wl, "yes")
                || lex_word_eq(s + i, wl, "no") { k = LEX_DECL; }
            lex_fill(cls, i, j, k);
            i = j;
            continue;
        }
        i++;
    }
    return 0;
}
