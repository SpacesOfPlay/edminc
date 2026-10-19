// menu.mc - the context menu: a short list of commands at the pointer,
// drawn like the other overlays. The file tree is its one owner: it
// fills the menu (menu_clear, menu_add, menu_sep), opens it at a point,
// and runs the chosen entry's id in tree_menu_run. The keys move the
// selection and Enter runs it; a press on an entry runs it, and a press
// anywhere else, Esc, or a scroll closes the menu.

private const i32 MENU_MAX = 16;
private const i32 MENU_MIN_COLS = 18;   // the narrowest menu, in cells

bool menu_on = false;
private str[MENU_MAX] menu_label;     // "" for a separator
private str[MENU_MAX] menu_hint;      // the entry's key, dim at the right
private i32[MENU_MAX] menu_id;
private i32 menu_n = 0;
private i32 menu_sel = -1;
private i32 menu_x = 0;
private i32 menu_y = 0;

void menu_clear() {
    menu_n = 0;
    menu_sel = -1;
}

void menu_add(str label, str hint, i32 id) {
    if menu_n == MENU_MAX { return; }
    menu_label[menu_n] = label;
    menu_hint[menu_n] = hint;
    menu_id[menu_n] = id;
    menu_n++;
}

void menu_sep() {
    if menu_n == 0 || menu_n == MENU_MAX || menu_label[menu_n - 1].len == 0 { return; }
    menu_add("", "", -1);
}

private i32 menu_row_h() {
    return ui_list_row_h();
}

// a separator is a thin band, a quarter of a row
private i32 menu_entry_h(i32 i) {
    if menu_label[i].len == 0 { return menu_row_h() / 4 + 1; }
    return menu_row_h();
}

private i32 menu_pad() {
    return ui_list_pad() / 2;
}

private i32 menu_w() {
    i32 lw = 0;
    i32 hw = 0;
    for i32 i = 0; i < menu_n; i++ {
        i32 a = font_ui_text_w(menu_label[i]);
        i32 b = font_ui_text_w(menu_hint[i]);
        if a > lw { lw = a; }
        if b > hw { hw = b; }
    }
    i32 w = lw + hw + 4 * font_cell_w + 2 * ui_inset();
    if w < MENU_MIN_COLS * font_cell_w { w = MENU_MIN_COLS * font_cell_w; }
    if w > g_w - 8 { w = g_w - 8; }
    return w;
}

private i32 menu_h() {
    i32 h = 2 * menu_pad();
    for i32 i = 0; i < menu_n; i++ { h += menu_entry_h(i); }
    return h;
}

// Opens at the window point (x, y), its top left corner there, moved in
// to fit: a menu that would cross the bottom opens upward from the point.
void menu_open(i32 x, i32 y) {
    if menu_n == 0 { return; }
    if menu_label[menu_n - 1].len == 0 { menu_n--; }
    i32 w = menu_w();
    i32 h = menu_h();
    if x + w > g_w - 4 { x = g_w - 4 - w; }
    if x < 4 { x = 4; }
    if y + h > g_h - 4 { y = y - h; }
    if y + h > g_h - 4 { y = g_h - 4 - h; }
    if y < 4 { y = 4; }
    menu_x = x;
    menu_y = y;
    menu_sel = -1;
    menu_on = true;
    ed_damage();
}

// the first entry selected, for a menu opened from the keyboard
void menu_select_first() {
    menu_sel = -1;
    menu_move(1);
}

void menu_close() {
    if !menu_on { return; }
    menu_on = false;
    ed_damage();
}

// the entry at window point (x, y), or -1 (outside, or a separator)
private i32 menu_at(i32 x, i32 y) {
    if x < menu_x || x >= menu_x + menu_w() { return -1; }
    i32 ey = menu_y + menu_pad();
    for i32 i = 0; i < menu_n; i++ {
        i32 eh = menu_entry_h(i);
        if y >= ey && y < ey + eh {
            if menu_label[i].len == 0 { return -1; }
            return i;
        }
        ey += eh;
    }
    return -1;
}

private bool menu_inside(i32 x, i32 y) {
    return x >= menu_x && x < menu_x + menu_w() && y >= menu_y && y < menu_y + menu_h();
}

private void menu_run(i32 i) {
    if i < 0 || i >= menu_n || menu_label[i].len == 0 { return; }
    i32 id = menu_id[i];
    menu_close();
    tree_menu_run(id);
}

// the selection one entry along, past the separators, wrapping
private void menu_move(i32 d) {
    if menu_n == 0 { return; }
    i32 s = menu_sel;
    if s < 0 && d < 0 { s = 0; }
    for i32 k = 0; k < menu_n; k++ {
        s = (s + d + menu_n) % menu_n;
        if menu_label[s].len > 0 {
            menu_sel = s;
            ed_damage();
            return;
        }
    }
}

void menu_key(i32 key, i32 mods) {
    if key == K_ESCAPE { menu_close(); return; }
    if key == K_DOWN { menu_move(1); return; }
    if key == K_UP { menu_move(-1); return; }
    if key == K_HOME {
        menu_sel = -1;
        menu_move(1);
        return;
    }
    if key == K_END {
        menu_sel = 0;
        menu_move(-1);
        return;
    }
}

// Enter runs the selected entry; other text is dropped
void menu_char(u32 cp) {
    if cp == 13 { menu_run(menu_sel); }
}

// A press while the menu is up. On an entry it runs it; elsewhere it
// closes the menu, and false says the press is the caller's to handle.
bool menu_press(i32 x, i32 y) {
    if menu_inside(x, y) {
        menu_run(menu_at(x, y));
        return true;
    }
    menu_close();
    return false;
}

// the entry under the pointer is the selection
void menu_hover(i32 x, i32 y) {
    i32 i = menu_at(x, y);
    if i < 0 && !menu_inside(x, y) { return; }
    if i != menu_sel {
        menu_sel = i;
        ed_damage();
    }
}

void menu_render() {
    if !menu_on { return; }
    i32 w = menu_w();
    i32 h = menu_h();
    ui_panel(menu_x, menu_y, w, h);
    i32 ey = menu_y + menu_pad();
    f32 tx = cast(f32, menu_x + font_cell_w + ui_inset());
    f32 max_x = cast(f32, menu_x + w - font_cell_w);
    for i32 i = 0; i < menu_n; i++ {
        i32 eh = menu_entry_h(i);
        if menu_label[i].len == 0 {
            draw_rect(cast(f32, menu_x + menu_pad()), cast(f32, ey + eh / 2), cast(f32, w - 2 * menu_pad()), 1.0f, T_WIDGET_BORDER);
            ey += eh;
            continue;
        }
        ui_list_row(menu_x + menu_pad(), ey, w - 2 * menu_pad(), eh, i == menu_sel);
        f32 ty = cast(f32, ey + (eh - font_ui_h) / 2);
        if menu_hint[i].len > 0 {
            f32 hx = max_x - cast(f32, font_ui_text_w(menu_hint[i]));
            // the width is rounded; a bound at max_x would drop the last glyph
            ignore font_draw_ui_text(menu_hint[i], hx, ty, max_x + 2.0f, T_DIM);
        }
        ignore font_draw_ui_text(menu_label[i], tx, ty, max_x, T_FG);
        ey += eh;
    }
}

// tests read these back
i32 menu_count() {
    return menu_n;
}

str menu_entry(i32 i) {
    if i < 0 || i >= menu_n { return ""; }
    return menu_label[i];
}

// the window point of entry i's middle, for a test's press
void menu_entry_point(i32 i, i32* x, i32* y) {
    i32 ey = menu_y + menu_pad();
    for i32 k = 0; k < i && k < menu_n; k++ { ey += menu_entry_h(k); }
    *x = menu_x + menu_w() / 2;
    *y = ey + menu_row_h() / 2;
}
