// plat_x11.mc - Linux driver: window creation, the poll()-blocked
// event loop, and translation of X events into the app_* calls from
// plat.mc. Renders once per event burst, only when damaged.

private const i32 WIN_DEFAULT_W = 1200;
private const i32 WIN_DEFAULT_H = 800;
private const i32 WHEEL_LINES = 3;
private const u32 X11_BUTTON_LEFTWARD = 6;
private const u32 X11_BUTTON_RIGHTWARD = 7;

private i64 g_key_t = 0;       // KeyPress arrival, for input latency
private i64 g_load_us = 0;
private bool g_dragging = false;
private bool g_exposed = false;
private bool g_maximize_pending = false;
// A caption press on a maximized window, in root coordinates. The
// window is restored and moved once the pointer passes the threshold.
private bool g_caption_armed = false;
private i32 g_caption_px = 0;
private i32 g_caption_py = 0;
private const i32 CAPTION_DRAG_PX = 4;

// Weston's manager (WSLg) keeps the shadow margin around an
// undecorated window when it maximizes it, and WSLg then shows the
// window offset by that margin from where X places it, so the pointer
// misses what is drawn. On Weston the driver maximizes by itself: it
// lets the manager compute the maximized rectangle, drops the
// manager's state, and places a normal window on that rectangle.
private bool g_self_max = false;
private const i32 MAX_IDLE = 0;
private const i32 MAX_CAPTURE = 1;   // wait for the manager's rectangle
private const i32 MAX_UNMAX = 2;     // wait for the manager to drop its state
private const i32 MAX_PLACE = 3;     // wait for the window to reach the rectangle
private i32 g_max_phase = MAX_IDLE;
private i32 g_max_x = 0;             // the maximized rectangle, root coordinates
private i32 g_max_y = 0;
private i32 g_max_w = 0;
private i32 g_max_h = 0;
private i32 g_norm_x = 0;            // the restore-down rectangle
private i32 g_norm_y = 0;
private i32 g_norm_w = 0;
private i32 g_norm_h = 0;

private void x11_request_maximize() {
    if g_self_max { g_max_phase = MAX_CAPTURE; }
    x11_set_maximized(true);
}

private void x11_restore_to(i32 x, i32 y) {
    g_win_zoomed = false;
    g_max_phase = MAX_IDLE;
    ignore XMoveResizeWindow(g_dpy, g_win, x, y, cast(u32, g_norm_w), cast(u32, g_norm_h));
    ignore XFlush(g_dpy);
    plat_damage();
}

private void x11_toggle_zoom() {
    if !g_self_max {
        x11_toggle_maximized();
    } else if g_win_zoomed {
        x11_restore_to(g_norm_x, g_norm_y);
    } else {
        x11_request_maximize();
    }
}

// True when the rectangle lies on one monitor and spans its full width
// or height: where the manager puts a maximized window, the taskbar
// taken off. The manager sends the size and the position of a
// maximize as separate events, so a half-applied one fails this.
private bool x11_fills_monitor(i32 x, i32 y, i32 w, i32 h) {
    for i32 i = 0; i < x11_nmons; i++ {
        X11Monitor* m = &x11_mons[i];
        if x < m.x || y < m.y || x + w > m.x + m.w || y + h > m.y + m.h { continue; }
        if w == m.w || h == m.h { return true; }
    }
    return false;
}

// Steps the driver's own maximize on every ConfigureNotify and
// _NET_WM_STATE change. The manager's events arrive in no fixed
// order, so each phase waits on the state, not on an event.
private void x11_self_max_step() {
    bool wm_max = x11_read_maximized();
    i32 rx = 0;
    i32 ry = 0;
    Window child = 0;
    if XTranslateCoordinates(g_dpy, g_win, XDefaultRootWindow(g_dpy), 0, 0, &rx, &ry, &child) == 0 {
        return;
    }
    bool at_max = rx == g_max_x && ry == g_max_y && g_win_w == g_max_w && g_win_h == g_max_h;
    // the manager maximized the window, on our request or its own
    if wm_max && (g_max_phase == MAX_IDLE || g_max_phase == MAX_CAPTURE) {
        g_max_phase = MAX_CAPTURE;
        if !x11_fills_monitor(rx, ry, g_win_w, g_win_h) { return; }
        g_max_x = rx;
        g_max_y = ry;
        g_max_w = g_win_w;
        g_max_h = g_win_h;
        g_max_phase = MAX_UNMAX;
        x11_set_maximized(false);
        return;
    }
    // placed only once the manager's restore has landed, size and
    // position, or the rest of the restore overrides the placement
    if g_max_phase == MAX_UNMAX {
        bool at_norm = rx == g_norm_x && ry == g_norm_y && g_win_w == g_norm_w && g_win_h == g_norm_h;
        bool off_max = (g_win_w != g_max_w || g_win_h != g_max_h) && (rx != g_max_x || ry != g_max_y);
        if wm_max || !(at_norm || off_max) { return; }
        g_max_phase = MAX_PLACE;
        ignore XMoveResizeWindow(g_dpy, g_win, g_max_x, g_max_y, cast(u32, g_max_w), cast(u32, g_max_h));
        ignore XFlush(g_dpy);
        return;
    }
    if g_max_phase == MAX_PLACE {
        if !at_max { return; }
        g_max_phase = MAX_IDLE;
        g_win_zoomed = true;
        plat_damage();
        return;
    }
    if g_max_phase != MAX_IDLE { return; }
    if g_win_zoomed {
        // moved or sized off the rectangle by something else
        if !at_max {
            g_win_zoomed = false;
            plat_damage();
        }
        return;
    }
    // the manager maps the window off screen first; that is no
    // position to restore to
    if x11_monitor_at(rx + g_win_w / 2, ry + g_win_h / 2) < 0 { return; }
    g_norm_x = rx;
    g_norm_y = ry;
    g_norm_w = g_win_w;
    g_norm_h = g_win_h;
}

// the window button under (x, y): 0 minimize, 1 maximize, 2 close,
// -1 anywhere else
private i32 x11_caption_zone(i32 x, i32 y) {
    if g_caption_h <= 0 || y < 0 || y >= g_caption_h { return -1; }
    i32 bw = caption_btn_w();
    if x < g_w - 3 * bw || x >= g_w { return -1; }
    return (x - (g_w - 3 * bw)) / bw;
}

private void x11_caption_act(i32 zone) {
    if zone == 0 { x11_minimize(); }
    if zone == 1 { x11_toggle_zoom(); }
    if zone == 2 {
        if app_close() { x11_running = false; }
    }
}
private Cursor g_cur_arrow = 0;
private Cursor g_cur_ibeam = 0;
private Cursor g_cur_sizewe = 0;
private Cursor g_cur_hand = 0;
private Cursor[5] g_cur_edge;   // v, top-left, top-right, bottom-left, bottom-right
private i32 g_last_mx = 0;      // for modifier-only hover changes
private i32 g_last_my = 0;
private i32 g_win_w = 0;
private i32 g_win_h = 0;
private i32 g_cur_kind = -1;
private extern "libc.so.6" {
    i32 usleep(u32 us);
}

void plat_sleep_ms(u32 ms) {
    ignore usleep(ms * 1000);
}

private u8[256] g_dpi_spec;    // --dpi / EDMINC_DPI
private i32 g_dpi_spec_len = 0;
private i32 g_dpi_cur = 0;     // the DPI the core is currently built for

private const i32 X11_MAX_MONITORS = 8;

private struct X11Monitor {
    i32 x;
    i32 y;
    i32 w;
    i32 h;
    i32 dpi;
    bool primary;
    u8[32] name;
    i32 name_len;
}

private X11Monitor[X11_MAX_MONITORS] x11_mons;
private i32 x11_nmons = 0;
private i32 x11_mon_cur = -1;

// X keysyms for the keys the core names; printable keys pass as ASCII.
private const u64 XK_BackSpace = 0xFF08;
private const u64 XK_Tab = 0xFF09;
private const u64 XK_ISO_Left_Tab = 0xFE20;   // Shift+Tab
private const u64 XK_Return = 0xFF0D;
private const u64 XK_Escape = 0xFF1B;
private const u64 XK_Home = 0xFF50;
private const u64 XK_Left = 0xFF51;
private const u64 XK_Up = 0xFF52;
private const u64 XK_Right = 0xFF53;
private const u64 XK_Down = 0xFF54;
private const u64 XK_Page_Up = 0xFF55;
private const u64 XK_Page_Down = 0xFF56;
private const u64 XK_End = 0xFF57;
private const u64 XK_Delete = 0xFFFF;
private const u64 XK_KP_Enter = 0xFF8D;
private const u64 XK_F12 = 0xFFC9;
private const u64 XK_F7 = 0xFFC4;
private const u64 XK_F8 = 0xFFC5;
private const u64 XK_F5 = 0xFFC2;
private const u64 XK_F1 = 0xFFBE;
private const u64 XK_F2 = 0xFFBF;
private const u64 XK_Menu = 0xFF67;
private const u64 XK_F3 = 0xFFC0;
private const u64 XK_F4 = 0xFFC1;
private const u64 XK_F6 = 0xFFC3;
private const u64 XK_F9 = 0xFFC6;
private const u64 XK_F10 = 0xFFC7;
private const u64 XK_F11 = 0xFFC8;

private i32 x11_key_translate(KeySym ks) {
    if ks == XK_Left { return K_LEFT; }
    if ks == XK_Right { return K_RIGHT; }
    if ks == XK_Up { return K_UP; }
    if ks == XK_Down { return K_DOWN; }
    if ks == XK_Page_Up { return K_PGUP; }
    if ks == XK_Page_Down { return K_PGDN; }
    if ks == XK_Home { return K_HOME; }
    if ks == XK_End { return K_END; }
    if ks == XK_Delete { return K_DELETE; }
    if ks == XK_Escape { return K_ESCAPE; }
    if ks == XK_Tab || ks == XK_ISO_Left_Tab { return K_TAB; }
    if ks == XK_F12 { return K_F12; }
    if ks == XK_F7 { return K_F7; }
    if ks == XK_F8 { return K_F8; }
    if ks == XK_F5 { return K_F5; }
    if ks == XK_F1 { return K_F1; }
    if ks == XK_F2 { return K_F2; }
    if ks == XK_F3 { return K_F3; }
    if ks == XK_F4 { return K_F4; }
    if ks == XK_F6 { return K_F6; }
    if ks == XK_F9 { return K_F9; }
    if ks == XK_F10 { return K_F10; }
    if ks == XK_F11 { return K_F11; }
    if ks == XK_Menu { return K_MENU; }
    // latin1 keysyms are their own codepoints; the core wants the
    // unshifted uppercase letter for chords
    if ks >= 'a' && ks <= 'z' { return cast(i32, ks) - 32; }
    if ks >= 'A' && ks <= 'Z' { return cast(i32, ks); }
    if ks >= '0' && ks <= '9' { return cast(i32, ks); }
    if ks == '`' { return 96; }
    if ks == '/' { return '/'; }
    if ks == '.' { return '.'; }
    // zoom: = and its shifted +, minus, and the keypad's
    if ks == '=' || ks == '+' || ks == 0xFFAB { return '='; }   // XK_KP_Add
    if ks == '-' || ks == 0xFFAD { return '-'; }                // XK_KP_Subtract
    return 0;
}

// Control, Shift, Alt and Super, either side.
private bool x11_is_modifier(KeySym ks) {
    return x11_modifier_bit(ks) != 0;
}

// the MOD_ bit a modifier keysym stands for, 0 for any other key
private i32 x11_modifier_bit(KeySym ks) {
    if ks == XK_Control_L || ks == XK_Control_R { return MOD_CTRL; }
    if ks == XK_Shift_L || ks == XK_Shift_R { return MOD_SHIFT; }
    if ks == XK_Alt_L || ks == XK_Alt_R { return MOD_ALT; }
    if ks == XK_Super_L || ks == XK_Super_R { return MOD_SUPER; }
    return 0;
}

// The state field on a key event predates the key itself: a modifier
// being pressed is not in it yet, and one being released still is.
private void x11_hover_again(u32 state, KeySym ks, bool pressed) {
    i32 bit = x11_modifier_bit(ks);
    i32 mods = x11_mods(state);
    if pressed {
        mods = mods | bit;
    } else {
        mods = mods & ~bit;
    }
    app_hover(g_last_mx, g_last_my - g_caption_h, mods);
    x11_update_cursor(g_last_mx, g_last_my);
}

private i32 x11_mods(u32 state) {
    i32 m = 0;
    if (state & ControlMask) != 0 { m = m | MOD_CTRL; }
    if (state & ShiftMask) != 0 { m = m | MOD_SHIFT; }
    if (state & Mod1Mask) != 0 { m = m | MOD_ALT; }
    if (state & Mod4Mask) != 0 { m = m | MOD_SUPER; }
    return m;
}

// An undecorated window has no window-manager resize border, so the
// outermost few pixels become one. Zero while maximized.
private i32 x11_resize_border() {
    i32 b = font_line_h / 4;
    if b < 4 { b = 4; }
    return b;
}

// _NET_WM_MOVERESIZE direction for a window-relative point, or -1.
private i64 x11_edge_dir(i32 x, i32 y) {
    if g_win_zoomed { return -1; }
    i32 b = x11_resize_border();
    bool l = x < b;
    bool r = x >= g_win_w - b;
    bool t = y < b;
    bool bo = y >= g_win_h - b;
    if t && l { return NET_MOVERESIZE_TOPLEFT; }
    if t && r { return NET_MOVERESIZE_TOPRIGHT; }
    if bo && l { return NET_MOVERESIZE_BOTTOMLEFT; }
    if bo && r { return NET_MOVERESIZE_BOTTOMRIGHT; }
    if t { return NET_MOVERESIZE_TOP; }
    if bo { return NET_MOVERESIZE_BOTTOM; }
    if l { return NET_MOVERESIZE_LEFT; }
    if r { return NET_MOVERESIZE_RIGHT; }
    return -1;
}

// I-beam over text, arrow over chrome, resize arrows on the frame
// edges; the pointer only changes when the region does, so this costs
// one X request per crossing. Encoded kinds above CURSOR_* are the
// edge directions, offset so they never collide.
private const i32 CURSOR_EDGE_BASE = 100;

private void x11_update_cursor(i32 x, i32 y) {
    i64 dir = x11_edge_dir(x, y);
    i32 kind = 0;
    if dir >= 0 {
        kind = CURSOR_EDGE_BASE + cast(i32, dir);
    } else if y < g_caption_h {
        kind = CURSOR_ARROW;
    } else {
        kind = app_cursor_kind(x, y - g_caption_h);
    }
    if kind == g_cur_kind { return; }
    g_cur_kind = kind;
    Cursor c = g_cur_arrow;
    if kind == CURSOR_IBEAM {
        c = g_cur_ibeam;
    } else if kind == CURSOR_HAND {
        c = g_cur_hand;
    } else if kind == CURSOR_RESIZE_H {
        c = g_cur_sizewe;
    } else if kind == CURSOR_RESIZE_V {
        c = g_cur_edge[0];   // XC_sb_v_double_arrow
    } else if kind >= CURSOR_EDGE_BASE {
        i64 d = cast(i64, kind - CURSOR_EDGE_BASE);
        if d == NET_MOVERESIZE_LEFT || d == NET_MOVERESIZE_RIGHT {
            c = g_cur_sizewe;
        } else if d == NET_MOVERESIZE_TOP || d == NET_MOVERESIZE_BOTTOM {
            c = g_cur_edge[0];
        } else if d == NET_MOVERESIZE_TOPLEFT {
            c = g_cur_edge[1];
        } else if d == NET_MOVERESIZE_TOPRIGHT {
            c = g_cur_edge[2];
        } else if d == NET_MOVERESIZE_BOTTOMLEFT {
            c = g_cur_edge[3];
        } else {
            c = g_cur_edge[4];
        }
    }
    ignore XDefineCursor(g_dpy, g_win, c);
}

private void x11_handle(XEvent* ev) {
    switch ev.type {
        case Expose: {
            g_exposed = true;
            plat_damage();
        }
        case ConfigureNotify: {
            i32 w = ev.xconfigure.width;
            i32 h = ev.xconfigure.height;
            g_win_w = w;
            g_win_h = h;
            gpu_resize(w, h);
            i32 ah = h - g_caption_h;
            if ah < 0 { ah = 0; }
            app_resize(w, ah);
            x11_track_monitor(w, h);
            if g_self_max { x11_self_max_step(); }
        }
        case PropertyNotify: {
            // the manager reports maximize/restore here; the caption's
            // middle button follows it
            if ev.xproperty.atom == g_atom_net_wm_state {
                if g_self_max {
                    x11_self_max_step();
                } else {
                    bool was = g_win_zoomed;
                    g_win_zoomed = x11_read_maximized();
                    if was != g_win_zoomed { plat_damage(); }
                }
            }
        }
        case KeyPress: {
            if g_time { g_key_t = plat_time_us(); }
            noinit u8[64] text;
            KeySym ks = 0;
            i32 n = 0;
            if g_xic != null {
                // committed UTF-8: dead keys are composed and IME
                // commits arrive here with no keysym
                i32 status = 0;
                n = Xutf8LookupString(g_xic, &ev.xkey, &text[0], 64, &ks, &status);
                if status == XLookupNone { return; }
                if status == XLookupChars { ks = 0; }
            } else {
                n = XLookupString(&ev.xkey, &text[0], 64, &ks, null);
            }
            i32 mods = x11_mods(ev.xkey.state);
            i32 key = x11_key_translate(ks);
            // Ctrl+Space triggers completion; space is not otherwise a
            // chord key. The chord guard below drops its text.
            if key == 0 && ks == ' ' && (mods & MOD_CTRL) != 0 && (mods & MOD_ALT) == 0 {
                key = ' ';
            }
            if key != 0 { app_key(key, mods); }
            if x11_is_modifier(ks) {
                x11_hover_again(ev.xkey.state, ks, true);
                return;
            }
            // Ctrl/Alt chords are keys, not text; the lookup would
            // hand back the C0 control character for them
            if (mods & (MOD_CTRL | MOD_ALT)) != 0 {
                if ks == XK_BackSpace && (mods & MOD_CTRL) != 0 { app_char(127); }
                return;
            }
            if ks == XK_Return || ks == XK_KP_Enter { app_char(13); return; }
            if ks == XK_Tab { app_char(9); return; }
            if ks == XK_BackSpace { app_char(8); return; }
            i32 i = 0;
            while i < n {
                u32 cp = utf8_next(&text[0], n, &i);
                if cp >= 32 { app_char(cp); }
            }
        }
        case KeyRelease: {
            // a modifier let go re-evaluates the hover link where the
            // pointer already sits, as the other platforms do
            KeySym ks = XLookupKeysym(&ev.xkey, 0);
            if x11_is_modifier(ks) { x11_hover_again(ev.xkey.state, ks, false); }
        }
        case ButtonPress: {
            u32 b = ev.xbutton.button;
            i32 x = ev.xbutton.x;
            i32 y = ev.xbutton.y;
            if b == Button4 || b == Button5 {
                f32 dy = cast(f32, WHEEL_LINES * font_line_h);
                if b == Button4 { dy = -dy; }
                app_scroll_notch(0.0f, dy, x, y - g_caption_h);
                return;
            }
            // 6 and 7: the sideways buttons, left and right
            if b == X11_BUTTON_LEFTWARD || b == X11_BUTTON_RIGHTWARD {
                f32 dx = cast(f32, WHEEL_LINES * font_cell_w);
                if b == X11_BUTTON_LEFTWARD { dx = -dx; }
                app_scroll_notch(dx, 0.0f, x, y - g_caption_h);
                return;
            }
            if b == Button1 {
                // the frame edge resizes; undecorated windows have no
                // window-manager border of their own
                i64 dir = x11_edge_dir(x, y);
                if dir >= 0 {
                    x11_begin_moveresize(ev.xbutton.x_root, ev.xbutton.y_root, dir);
                    return;
                }
                if g_caption_h > 0 && y < g_caption_h {
                    i32 zone = x11_caption_zone(x, y);
                    if zone >= 0 {
                        // acts on release over itself; the press arms
                        // it and shows the held look
                        g_caption_press = zone;
                        g_caption_hover = zone;
                        plat_damage();
                        return;
                    }
                    // a manager may refuse to move a maximized
                    // window (WSLg does); the drag restores it first
                    if g_win_zoomed {
                        g_caption_armed = true;
                        g_caption_px = ev.xbutton.x_root;
                        g_caption_py = ev.xbutton.y_root;
                        return;
                    }
                    // the manager owns the drag, so snapping and
                    // double-click maximize keep working
                    x11_begin_moveresize(ev.xbutton.x_root, ev.xbutton.y_root, NET_MOVERESIZE_MOVE);
                    return;
                }
                g_dragging = true;
                app_mouse(x, y - g_caption_h, 0, true, x11_mods(ev.xbutton.state));
                return;
            }
            if b == Button3 { app_mouse(x, y - g_caption_h, 1, true, x11_mods(ev.xbutton.state)); }
            if b == Button2 { app_mouse(x, y - g_caption_h, 2, true, x11_mods(ev.xbutton.state)); }
        }
        case ButtonRelease: {
            u32 b = ev.xbutton.button;
            if b == Button4 || b == Button5 { return; }
            if b == Button1 && g_caption_press >= 0 {
                i32 z = g_caption_press;
                g_caption_press = -1;
                g_caption_hover = -1;
                plat_damage();
                if x11_caption_zone(ev.xbutton.x, ev.xbutton.y) == z { x11_caption_act(z); }
                return;
            }
            if b == Button1 && g_caption_armed {
                g_caption_armed = false;
                return;
            }
            if b == Button1 { g_dragging = false; }
            i32 btn = 0;
            if b == Button3 { btn = 1; }
            if b == Button2 { btn = 2; }
            app_mouse(ev.xbutton.x, ev.xbutton.y - g_caption_h, btn, false, x11_mods(ev.xbutton.state));
        }
        case MotionNotify: {
            i32 x = ev.xmotion.x;
            i32 y = ev.xmotion.y;
            g_last_mx = x;
            g_last_my = y;
            if g_caption_armed {
                i32 dx = ev.xmotion.x_root - g_caption_px;
                i32 dy = ev.xmotion.y_root - g_caption_py;
                if dx * dx + dy * dy > CAPTION_DRAG_PX * CAPTION_DRAG_PX {
                    g_caption_armed = false;
                    if g_self_max {
                        // the restored window keeps the pointer at the
                        // same fraction of the caption's width
                        i32 px = ev.xmotion.x_root;
                        i32 nx = px - (px - g_max_x) * g_norm_w / g_max_w;
                        x11_restore_to(nx, g_max_y);
                    } else {
                        x11_set_maximized(false);
                    }
                    x11_begin_moveresize(ev.xmotion.x_root, ev.xmotion.y_root, NET_MOVERESIZE_MOVE);
                }
                return;
            }
            i32 zone = x11_caption_zone(x, y);
            if g_caption_press >= 0 {
                i32 want = -1;
                if zone == g_caption_press { want = zone; }
                if want != g_caption_hover {
                    g_caption_hover = want;
                    plat_damage();
                }
                return;
            }
            if zone != g_caption_hover {
                g_caption_hover = zone;
                plat_damage();
            }
            if g_dragging {
                app_mouse_move(x, y - g_caption_h);
            } else {
                app_hover(x, y - g_caption_h, x11_mods(ev.xmotion.state));
            }
            x11_update_cursor(x, y);
        }
        case LeaveNotify: {
            if g_caption_hover >= 0 && g_caption_press < 0 {
                g_caption_hover = -1;
                plat_damage();
            }
        }
        case FocusIn: {
            if g_xic != null { XSetICFocus(g_xic); }
            app_focus(true);
        }
        case FocusOut: {
            if g_xic != null { XUnsetICFocus(g_xic); }
            app_focus(false);
        }
        case SelectionRequest: {
            x11_selection_request(&ev.xselectionrequest);
        }
        case SelectionClear: {
            x11_selection_clear();
        }
        case ClientMessage: {
            if ev.xclient.message_type == g_atom_wm_protocols
                && cast(Atom, ev.xclient.data.l[0]) == g_atom_wm_delete {
                if app_close() { x11_running = false; }
            }
        }
        default: {
        }
    }
}

// A DPI ("144") or a scale of the 96-dpi base ("1.5x"). 0 when the
// text is neither, or lands outside a plausible range.
private i32 x11_parse_dpi(u8* s, i32 len) {
    i32 whole = 0;
    i32 i = 0;
    while i < len && s[i] >= '0' && s[i] <= '9' {
        whole = whole * 10 + cast(i32, s[i]) - 48;
        i++;
    }
    if i == 0 { return 0; }
    i32 frac = 0;
    i32 fdiv = 1;
    if i < len && s[i] == '.' {
        i++;
        while i < len && s[i] >= '0' && s[i] <= '9' && fdiv < 1000 {
            frac = frac * 10 + cast(i32, s[i]) - 48;
            fdiv = fdiv * 10;
            i++;
        }
    }
    i32 v = whole;
    if i < len && (s[i] == 'x' || s[i] == 'X') {
        v = (whole * fdiv + frac) * DPI_BASE / fdiv;
    }
    // a fraction without the suffix is a DPI written as a float
    if v < 48 || v > 480 { return 0; }
    return v;
}

// The override spec is either one number for every output ("144") or
// a comma-separated list keyed by RandR monitor name
// ("DP-1=144,HDMI-1=144"). Unlisted outputs fall through.
private i32 x11_spec_dpi(str name) {
    i32 i = 0;
    while i < g_dpi_spec_len {
        i32 s = i;
        while i < g_dpi_spec_len && g_dpi_spec[i] != ',' { i++; }
        i32 e = i;
        if i < g_dpi_spec_len { i++; }
        i32 eq = s;
        while eq < e && g_dpi_spec[eq] != '=' { eq++; }
        if eq == e {
            i32 v = x11_parse_dpi(&g_dpi_spec[s], e - s);
            if v > 0 { return v; }
        } else if str_equal(str_from(&g_dpi_spec[s], eq - s), name) {
            i32 v = x11_parse_dpi(&g_dpi_spec[eq + 1], e - eq - 1);
            if v > 0 { return v; }
        }
    }
    return 0;
}

// Xft.dpi is what a desktop environment writes; read once.
private i32 g_xft_dpi = 0;

private i32 x11_xft_dpi() {
    if g_xft_dpi != 0 { return g_xft_dpi; }
    g_xft_dpi = DPI_BASE;
    u8* rms = XResourceManagerString(g_dpy);
    if rms == null { return g_xft_dpi; }
    XrmInitialize();
    void* db = XrmGetStringDatabase(rms);
    if db == null { return g_xft_dpi; }
    u8* type = null;
    XrmValue val;
    if XrmGetResource(db, "Xft.dpi", "Xft.Dpi", &type, cast(void*, &val)) != 0 && val.addr != null {
        i32 n = 0;
        while val.addr[n] != 0 { n++; }
        i32 v = x11_parse_dpi(val.addr, n);
        if v > 0 { g_xft_dpi = v; }
    }
    XrmDestroyDatabase(db);
    return g_xft_dpi;
}

// X11 has no per-window scale, and an output's physical size is
// often missing or wrong (XWayland reports 0mm x 0mm for some
// outputs, and a correct size still does not say what scale the user
// wants), so it is not used. The desktop's Xft.dpi is the real
// signal; where nothing publishes one -- a bare WM, or WSLg, which
// passes the host's display scale through neither Xft.dpi nor RandR
// -- the override names the value, per output when the screens
// disagree. Precedence: the spec, Xft.dpi, 96.
private i32 x11_dpi_for(str name) {
    i32 v = x11_spec_dpi(name);
    if v > 0 { return v; }
    return x11_xft_dpi();
}

// RandR monitor rectangles, with each one's DPI resolved once.
private void x11_read_monitors() {
    x11_nmons = 0;
    x11_mon_cur = -1;
    i32 n = 0;
    XRRMonitorInfo* m = XRRGetMonitors(g_dpy, XDefaultRootWindow(g_dpy), 1, &n);
    if m == null { return; }
    if n > X11_MAX_MONITORS { n = X11_MAX_MONITORS; }
    for i32 i = 0; i < n; i++ {
        X11Monitor* d = &x11_mons[i];
        d.x = m[i].x;
        d.y = m[i].y;
        d.w = m[i].width;
        d.h = m[i].height;
        d.primary = m[i].primary != 0;
        d.name_len = 0;
        u8* nm = XGetAtomName(g_dpy, m[i].name);
        if nm != null {
            i32 len = 0;
            while nm[len] != 0 && len < 32 { len++; }
            memcpy(&d.name[0], nm, len);
            d.name_len = len;
            ignore XFree(cast(void*, nm));
        }
        d.dpi = x11_dpi_for(str_from(&d.name[0], d.name_len));
    }
    XRRFreeMonitors(m);
    x11_nmons = n;
}

// The output a new window opens on: the RandR primary, else the first
// one listed. WSLg flags no primary and lists the Windows primary
// first. -1 when RandR reports no monitors.
private i32 x11_launch_monitor() {
    for i32 i = 0; i < x11_nmons; i++ {
        if x11_mons[i].primary { return i; }
    }
    if x11_nmons > 0 { return 0; }
    return -1;
}

private bool x11_resource_set(u8* name, u8* class) {
    u8* rms = XResourceManagerString(g_dpy);
    if rms == null { return false; }
    XrmInitialize();
    void* db = XrmGetStringDatabase(rms);
    if db == null { return false; }
    u8* type = null;
    XrmValue val;
    bool found = XrmGetResource(db, name, class, &type, cast(void*, &val)) != 0 && val.addr != null;
    XrmDestroyDatabase(db);
    return found;
}

// libXcursor sizes the themed font cursors from XCURSOR_SIZE, then
// Xcursor.size, then Xft.dpi. With none of them set it uses the root
// window's shorter side / 48, which is 80 px on a 3840-high multi-
// monitor root. Without those settings, the size follows the DPI the
// editor uses, by the same rule libXcursor applies to Xft.dpi.
private const i32 CURSOR_PT = 16;
private const i32 POINTS_PER_INCH = 72;

private void x11_cursor_size(i32 dpi) {
    string env = env_get("XCURSOR_SIZE");
    bool set = env.len > 0;
    free(env);
    if set || x11_resource_set("Xcursor.size", "Xcursor.Size") { return; }
    ignore XcursorSetDefaultSize(g_dpy, dpi * CURSOR_PT / POINTS_PER_INCH);
}

private i32 x11_monitor_at(i32 px, i32 py) {
    for i32 i = 0; i < x11_nmons; i++ {
        X11Monitor* d = &x11_mons[i];
        if px >= d.x && px < d.x + d.w && py >= d.y && py < d.y + d.h {
            return i;
        }
    }
    return -1;
}

// Which output the window sits on, by its center. ConfigureNotify
// coordinates are parent-relative under a reparenting window
// manager, so the origin is translated to the root first.
private void x11_track_monitor(i32 w, i32 h) {
    if x11_nmons == 0 { return; }
    i32 rx = 0;
    i32 ry = 0;
    Window child = 0;
    if XTranslateCoordinates(g_dpy, g_win, XDefaultRootWindow(g_dpy), 0, 0, &rx, &ry, &child) == 0 {
        return;
    }
    i32 cx = rx + w / 2;
    i32 cy = ry + h / 2;
    i32 idx = x11_monitor_at(cx, cy);
    if idx < 0 {
        // the layout changed under us; RRScreenChangeNotify is not
        // wired, so a miss is what prompts the re-read
        x11_read_monitors();
        idx = x11_monitor_at(cx, cy);
        if idx < 0 { return; }
    }
    if idx == x11_mon_cur { return; }
    x11_mon_cur = idx;
    i32 dpi = x11_mons[idx].dpi;
    if g_time {
        print("monitor {} dpi {}\n", str_from(&x11_mons[idx].name[0], x11_mons[idx].name_len), dpi);
    }
    if dpi != g_dpi_cur {
        g_dpi_cur = dpi;
        app_scale(dpi);
        // the caption is dpi derived, so it moved too
        g_caption_h = caption_default_h(dpi);
        i32 ah = g_win_h - g_caption_h;
        if ah < 0 { ah = 0; }
        app_resize(g_win_w, ah);
    }
}

// One frame with no window: --smoke must run where there is no
// display, since it is the check `minc test` runs everywhere.
private i32 x11_headless_smoke(str path, i32 dpi) {
    if !font_init(dpi) {
        print("font init failed\n");
        return 1;
    }
    draw_init();
    app_resize(WIN_DEFAULT_W, WIN_DEFAULT_H);
    i64 t0 = plat_time_us();
    app_init(path, dpi);
    g_load_us = plat_time_us() - t0;
    hl_inject();
    i64 f0 = plat_time_us();
    app_render();
    i64 fr = plat_time_us() - f0;
    print("smoke: rendered {} verts, {} lines, load {} us, frame {} us\n",
        draw_nverts, tb.nlines, g_load_us, fr);
    return 0;
}

i32 plat_main() {
    // before anything else: the process that goes on is the exec'd one
    if hl_detach_launch() { x11_detach(); }
    for i32 a = 1; a < get_argc(); a++ {
        str arg = str_from_cstr(get_arg(a));
        if str_equal(arg, "--dpi") && a + 1 < get_argc() {
            a++;
            str d = str_from_cstr(get_arg(a));
            if d.len > 0 && d.len < 256 {
                memcpy(&g_dpi_spec[0], d.data, d.len);
                g_dpi_spec_len = d.len;
            }
        } else {
            hl_arg(&a);
        }
    }
    str path = str_from(&g_arg_path[0], g_arg_path_len);

    if g_dpi_spec_len == 0 {
        string env = env_get("EDMINC_DPI");
        if env.len > 0 && env.len < 256 {
            memcpy(&g_dpi_spec[0], env.data, env.len);
            g_dpi_spec_len = env.len;
        }
        free(env);
    }

    // workers call plat_wake; Xlib itself stays single-threaded
    ignore XInitThreads();
    g_dpy = XOpenDisplay(null);
    if g_dpy == null {
        if g_smoke {
            i32 d = x11_spec_dpi("");
            if d == 0 { d = DPI_BASE; }
            return x11_headless_smoke(path, d);
        }
        print("cannot open display (is DISPLAY set?)\n");
        return 1;
    }
    g_screen = XDefaultScreen(g_dpy);
    x11_read_monitors();
    // the DPI of the output the window opens on; the first
    // ConfigureNotify corrects it if the manager places it elsewhere
    i32 mon = x11_launch_monitor();
    i32 dpi = x11_dpi_for("");
    if mon >= 0 { dpi = x11_mons[mon].dpi; }
    g_dpi_cur = dpi;
    // the restore-down size, in device pixels
    i32 win_w = WIN_DEFAULT_W * dpi / DPI_BASE;
    i32 win_h = WIN_DEFAULT_H * dpi / DPI_BASE;
    // centered on that output; without a position hint the manager
    // picks the output, and maximizes on that one
    i32 win_x = 0;
    i32 win_y = 0;
    if mon >= 0 {
        X11Monitor* lm = &x11_mons[mon];
        if win_w > lm.w { win_w = lm.w; }
        if win_h > lm.h { win_h = lm.h; }
        win_x = lm.x + (lm.w - win_w) / 2;
        win_y = lm.y + (lm.h - win_h) / 2;
    }

    XVisualInfo* vi = gpu_choose_visual(g_screen);
    if vi == null {
        print("no suitable GLX framebuffer config\n");
        return 1;
    }

    Window root = XDefaultRootWindow(g_dpy);
    XSetWindowAttributes swa;
    swa.colormap = XCreateColormap(g_dpy, root, vi.visual, AllocNone);
    swa.border_pixel = 0;
    swa.event_mask = ExposureMask | StructureNotifyMask | KeyPressMask
        | KeyReleaseMask
        | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | LeaveWindowMask
        | FocusChangeMask | PropertyChangeMask;
    g_win = XCreateWindow(g_dpy, root, win_x, win_y, cast(u32, win_w), cast(u32, win_h), 0,
        vi.depth, InputOutput, vi.visual,
        CWBorderPixel | CWColormap | CWEventMask, &swa);
    if g_win == 0 {
        print("XCreateWindow failed\n");
        return 1;
    }
    ignore XFree(cast(void*, vi));

    g_atom_wm_protocols = XInternAtom(g_dpy, "WM_PROTOCOLS", 0);
    g_atom_wm_delete = XInternAtom(g_dpy, "WM_DELETE_WINDOW", 0);
    g_atom_net_wm_name = XInternAtom(g_dpy, "_NET_WM_NAME", 0);
    g_atom_utf8 = XInternAtom(g_dpy, "UTF8_STRING", 0);
    g_atom_clipboard = XInternAtom(g_dpy, "CLIPBOARD", 0);
    g_atom_targets = XInternAtom(g_dpy, "TARGETS", 0);
    g_atom_incr = XInternAtom(g_dpy, "INCR", 0);
    g_atom_paste = XInternAtom(g_dpy, "EDMINC_PASTE", 0);
    g_atom_motif_hints = XInternAtom(g_dpy, "_MOTIF_WM_HINTS", 0);
    g_atom_moveresize = XInternAtom(g_dpy, "_NET_WM_MOVERESIZE", 0);
    g_atom_net_wm_state = XInternAtom(g_dpy, "_NET_WM_STATE", 0);
    g_atom_max_horz = XInternAtom(g_dpy, "_NET_WM_STATE_MAXIMIZED_HORZ", 0);
    g_atom_max_vert = XInternAtom(g_dpy, "_NET_WM_STATE_MAXIMIZED_VERT", 0);
    x11_set_undecorated();
    g_self_max = x11_wm_is_weston();
    g_norm_x = win_x;
    g_norm_y = win_y;
    g_norm_w = win_w;
    g_norm_h = win_h;
    XSizeHints sh;
    sh.flags = USPosition | USSize;
    sh.x = win_x;
    sh.y = win_y;
    sh.width = win_w;
    sh.height = win_h;
    XSetWMNormalHints(g_dpy, g_win, &sh);
    ignore XSetWMProtocols(g_dpy, g_win, &g_atom_wm_delete, 1);


    // key repeat as press/release pairs, not the X11 default of a
    // synthetic release before every repeat
    i32 supported = 0;
    ignore XkbSetDetectableAutoRepeat(g_dpy, 1, &supported);

    if x11_im_init() {
        if g_time { print("input: XIM (committed UTF-8)\n"); }
    } else if g_time {
        print("input: no input method, latin-1 fallback\n");
    }

    x11_cursor_size(dpi);
    g_cur_arrow = XCreateFontCursor(g_dpy, cast(u32, XC_left_ptr));
    g_cur_ibeam = XCreateFontCursor(g_dpy, cast(u32, XC_xterm));
    g_cur_sizewe = XCreateFontCursor(g_dpy, cast(u32, XC_sb_h_double_arrow));
    g_cur_hand = XCreateFontCursor(g_dpy, cast(u32, XC_hand2));
    g_cur_edge[0] = XCreateFontCursor(g_dpy, cast(u32, XC_sb_v_double_arrow));
    g_cur_edge[1] = XCreateFontCursor(g_dpy, cast(u32, XC_top_left_corner));
    g_cur_edge[2] = XCreateFontCursor(g_dpy, cast(u32, XC_top_right_corner));
    g_cur_edge[3] = XCreateFontCursor(g_dpy, cast(u32, XC_bottom_left_corner));
    g_cur_edge[4] = XCreateFontCursor(g_dpy, cast(u32, XC_bottom_right_corner));

    if !font_init(dpi) {
        print("font init failed\n");
        return 1;
    }
    // adopt the self-drawn caption: the view renders the bar into
    // negative y and gpu_gl shifts all output down by the same amount
    g_caption_h = caption_default_h(dpi);
    if !gpu_init(g_win, win_w, win_h) {
        return 1;
    }
    draw_init();

    g_win_w = win_w;
    g_win_h = win_h;
    app_resize(win_w, win_h - g_caption_h);
    i64 t0 = plat_time_us();
    app_init(path, dpi);
    g_load_us = plat_time_us() - t0;
    if g_handover_len > 0 {
        ignore app_handover_restore(str_from(&g_handover[0], g_handover_len));
    } else if g_shot_len == 0 && g_play_len == 0 && !g_smoke {
        ignore app_session_restore();
    }

    ignore XMapWindow(g_dpy, g_win);
    ignore XFlush(g_dpy);
    // Launch maximized, as the Windows and macOS shells do. The
    // request is sent after the first frame: WSLg maximizes a window
    // on some other output than the one its position hint names when
    // the request arrives before the window has shown a frame. The
    // manager answers with a ConfigureNotify carrying the real size.
    g_maximize_pending = true;
    g_win_zoomed = !g_self_max;
    plat_damage();

    hl_inject();
    if g_dump_term_len > 0 {
        hl_dump_term();
        if g_shot_len == 0 {
            ed_term_close_all();
            return 0;
        }
    }

    if g_shot_len > 0 {
        // the dump should show the finished frame, so let any
        // background work land before it is taken
        app_settle();
        gpu_request_shot(str_from(&g_shot[0], g_shot_len));
        app_render();
        return 0;
    }
    if g_play_len > 0 {
        // a recorded fuzz run in the live window, one step per tick
        if !play_open(str_from(&g_play[0], g_play_len)) { return 2; }
        plat_set_timer(PLAY_TIMER, g_play_ms);
    }
    if g_smoke {
        i64 f0 = plat_time_us();
        app_render();
        i64 fr = plat_time_us() - f0;
        print("smoke: rendered {} verts, {} lines, load {} us, frame {} us\n",
            draw_nverts, tb.nlines, g_load_us, fr);
        return 0;
    }

    if !x11_wake_init() {
        print("wake pipe failed\n");
        return 1;
    }

    pollfd[2] fds;
    fds[0].fd = XConnectionNumber(g_dpy);
    fds[0].events = POLLIN;
    fds[1].fd = x11_wake_fd[0];
    fds[1].events = POLLIN;

    while x11_running {
        // Drain the queue first: XPending flushes, so anything already
        // buffered client-side would never wake poll().
        while x11_running && XPending(g_dpy) > 0 {
            XEvent ev;
            ignore XNextEvent(g_dpy, &ev);
            // the input method swallows the keys it is composing
            if XFilterEvent(&ev, 0) != 0 { continue; }
            x11_handle(&ev);
        }
        if !x11_running { break; }
        if x11_damaged {
            x11_damaged = false;
            i64 p0 = 0;
            if g_time { p0 = plat_time_us(); }
            app_render();
            if g_maximize_pending && g_exposed {
                g_maximize_pending = false;
                x11_request_maximize();
            }
            if g_time {
                i64 now = plat_time_us();
                if g_key_t != 0 {
                    print("char_to_present_us {}\n", now - g_key_t);
                    g_key_t = 0;
                }
                print("paint_us {} dur {}\n", now, now - p0);
            }
            continue;   // an event may have arrived while rendering
        }
        // Blocks with no timeout when no timer is armed: idle costs
        // nothing at all.
        ignore poll(&fds[0], 2, x11_timer_timeout());
        if (fds[1].revents & POLLIN) != 0 {
            x11_wake_drain();
            app_wake();
        }
        x11_timers_fire();
    }

    ignore XDestroyWindow(g_dpy, g_win);
    ignore XCloseDisplay(g_dpy);
    return 0;
}
