// plat_mac.mc - macOS driver: NSApplication setup, an NSWindow per
// editor window, each with a runtime-built layer-backed view
// (CAMetalLayer via makeBackingLayer), translation of Cocoa events
// into the app_* calls from plat.mc, and plat_main(). [NSApp run] owns the
// loop; rendering happens only in displayLayer: after plat_damage's
// [layer setNeedsDisplay], so idle is zero wakeups.
//
// The view is the layer's CA delegate. AppKit never routes its
// updateLayer/drawRect display pass to a view whose backing layer
// is custom (verified: wantsUpdateLayer is queried, nothing is
// ever displayed), so damage goes through Core Animation directly:
// [layer setNeedsDisplay] -> commit -> displayLayer: -> app_render.

import str;
import file;
import objc_runtime;
import ext_macos;

private const i32 WIN_DEFAULT_W = 1200;   // points
private const i32 WIN_DEFAULT_H = 800;
private const i32 WHEEL_LINES = 3;

// kVK_* virtual keycodes (HIToolbox); layout-independent positions.
private const i32 KVK_ESCAPE = 0x35;
private const i32 KVK_TAB = 0x30;
private const i32 KVK_HOME = 0x73;
private const i32 KVK_PGUP = 0x74;
private const i32 KVK_FWD_DELETE = 0x75;
private const i32 KVK_END = 0x77;
private const i32 KVK_PGDN = 0x79;
private const i32 KVK_LEFT = 0x7B;
private const i32 KVK_RIGHT = 0x7C;
private const i32 KVK_DOWN = 0x7D;
private const i32 KVK_UP = 0x7E;
private const i32 KVK_ANSI_MINUS = 0x1B;
private const i32 KVK_F1 = 122;
private const i32 KVK_F2 = 120;
private const i32 KVK_F3 = 99;
private const i32 KVK_F4 = 118;
private const i32 KVK_F5 = 96;
private const i32 KVK_F6 = 97;
private const i32 KVK_F7 = 98;
private const i32 KVK_F8 = 100;
private const i32 KVK_F9 = 101;
private const i32 KVK_F10 = 109;
private const i32 KVK_F11 = 103;
private const i32 KVK_F12 = 111;

// the dpi the core works in, from the backing scale
private i32 mac_dpi(f64 scale) {
    return cast(i32, cast(f64, DPI_BASE) * scale + 0.5);
}

private struct NSRange {
    u64 location;
    u64 length;
}

private const u64 NS_NOT_FOUND = 0x7FFFFFFFFFFFFFFF;   // NSNotFound

private void* g_win_delegate = null;   // one EdmincWinDelegate serves every window

private extern "libSystem.B.dylib" {
    i32 usleep(u32 us);
}

void plat_sleep_ms(u32 ms) {
    ignore usleep(ms * 1000);
}
private bool mac_marked = false;   // IME composition in progress
private i64 g_char_t = 0;      // key event arrival, for input latency
private i64 g_load_us = 0;

private i32 mac_key_translate(i32 kc) {
    if kc == KVK_LEFT { return K_LEFT; }
    if kc == KVK_RIGHT { return K_RIGHT; }
    if kc == KVK_UP { return K_UP; }
    if kc == KVK_DOWN { return K_DOWN; }
    if kc == KVK_PGUP { return K_PGUP; }
    if kc == KVK_PGDN { return K_PGDN; }
    if kc == KVK_HOME { return K_HOME; }
    if kc == KVK_END { return K_END; }
    if kc == KVK_FWD_DELETE { return K_DELETE; }
    if kc == KVK_ESCAPE { return K_ESCAPE; }
    if kc == KVK_TAB { return K_TAB; }
    if kc == KVK_ANSI_MINUS { return '-'; }   // the history chord's key
    if kc == KVK_F1 { return K_F1; }
    if kc == KVK_F2 { return K_F2; }
    if kc == KVK_F3 { return K_F3; }
    if kc == KVK_F4 { return K_F4; }
    if kc == KVK_F5 { return K_F5; }
    if kc == KVK_F6 { return K_F6; }
    if kc == KVK_F7 { return K_F7; }
    if kc == KVK_F8 { return K_F8; }
    if kc == KVK_F9 { return K_F9; }
    if kc == KVK_F10 { return K_F10; }
    if kc == KVK_F11 { return K_F11; }
    if kc == KVK_F12 { return K_F12; }
    return 0;
}

// MOD_CTRL is the primary shortcut modifier: Cmd here.
private i32 mac_mods(void* event) {
    u64 f = cast(fn(void*, void*): u64, objc.raw)(event, objc_selref("modifierFlags"));
    i32 m = 0;
    if (f & NSEventModifierFlagCommand) != 0 { m |= MOD_CTRL; }
    if (f & NSEventModifierFlagShift) != 0 { m |= MOD_SHIFT; }
    if (f & NSEventModifierFlagOption) != 0 { m |= MOD_ALT; }
    if (f & NSEventModifierFlagControl) != 0 { m |= MOD_SUPER; }
    return m;
}

// Event position in pixels, top-left origin.
private void mac_mouse_xy(void* event, i32* x, i32* y) {
    CGPoint p = cast(fn(void*, void*): CGPoint, objc.raw)(event, objc_selref("locationInWindow"));
    CGPoint q = cast(fn(void*, void*, CGPoint, void*): CGPoint, objc.raw)(g_view, objc_selref("convertPoint:fromView:"), p, null);
    CGRect b = cast(fn(void*, void*): CGRect, objc.raw)(g_view, objc_selref("bounds"));
    *x = cast(i32, q.x * g_scale);
    *y = cast(i32, (b.size.height - q.y) * g_scale);
}

// insertText/setMarkedText hand over NSString or NSAttributedString.
private void* mac_plain_string(void* s) {
    if s == null { return null; }
    if objc.msg_bool_i(s, objc_selref("isKindOfClass:"), objc_classref("NSAttributedString", "/System/Library/Frameworks/Foundation.framework/Foundation")) {
        return objc.msg_id_v(s, objc_selref("string"));
    }
    return s;
}

// committed text: UTF-16 units to codepoints, surrogates paired
private void mac_send_text(void* ns) {
    if ns == null { return; }
    i64 len = objc.msg_q_v(ns, objc_selref("length"));
    u32 hi = 0;
    for i64 i = 0; i < len; i++ {
        u32 c = cast(u32, cast(fn(void*, void*, u64): u16, objc.raw)(ns, objc_selref("characterAtIndex:"), cast(u64, i)));
        if c >= SURR_HI && c < SURR_LO {
            hi = c;
            continue;
        }
        if c >= SURR_LO && c <= SURR_END {
            if hi != 0 {
                app_char(SURR_BASE + ((hi - SURR_HI) << 10) + (c - SURR_LO));
                hi = 0;
            }
            continue;
        }
        hi = 0;
        app_char(c);
    }
}

// Chord/navigation key of an event: K_* from the keycode, else the
// layout's base letter/digit as ASCII. 0 = nothing app_key takes.
private i32 mac_event_key(void* event) {
    i32 kc = cast(fn(void*, void*): i32, objc.raw)(event, objc_selref("keyCode"));
    i32 key = mac_key_translate(kc);
    if key == 0 {
        void* ig = objc.msg_id_v(event, objc_selref("charactersIgnoringModifiers"));
        if ig != null && objc.msg_q_v(ig, objc_selref("length")) > 0 {
            u32 c = cast(u32, cast(fn(void*, void*, u64): u16, objc.raw)(ig, objc_selref("characterAtIndex:"), 0));
            if c >= 'a' && c <= 'z' {
                key = cast(i32, c) - 32;
            } else if (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
                || c == 96 || c == 92 || c == '.' || c == '=' || c == '/' {
                key = cast(i32, c);
            } else if c == '+' {
                key = '=';   // zoom in, shifted or not
            }
        }
    }
    return key;
}

// the event's unmodified character is a space
private bool mac_event_is_space(void* event) {
    void* ig = objc.msg_id_v(event, objc_selref("charactersIgnoringModifiers"));
    if ig == null || objc.msg_q_v(ig, objc_selref("length")) == 0 { return false; }
    return cast(fn(void*, void*, u64): u16, objc.raw)(ig, objc_selref("characterAtIndex:"), 0) == 32;
}

// The Cmd chords app_key (ed.mc) actually binds; every other
// key equivalent falls through to the system (Cmd+H/M/W...).
private bool mac_cmd_handled(i32 key) {
    return key == 'S' || key == 'Q' || key == 'A' || key == 'C' || key == 'X'
        || key == 'V' || key == 'Z' || key == 'Y' || key == 'W'
        || key == 'B' || key == 'E' || key == 96 || key == 92 || key == '.'
        || key == '=' || key == '-' || (key >= '0' && key <= '3')
        || key == '/' || key == '7'
        || key == K_LEFT || key == K_RIGHT
        || key == K_HOME || key == K_END;
}

private void mac_update_size() {
    CGRect b = cast(fn(void*, void*): CGRect, objc.raw)(g_view, objc_selref("bounds"));
    i32 pw = cast(i32, b.size.width * g_scale + 0.5);
    i32 ph = cast(i32, b.size.height * g_scale + 0.5);
    gpu_resize(pw, ph);
    app_resize(pw, ph);
}

// --- EdmincView method implementations (Obj-C IMP signatures) -----------

// a fresh layer per view; the record reads it back after setWantsLayer
private void* ed_view_make_backing_layer(void* self, void* _cmd) {
    return objc.msg_id_v(objc_classref("CAMetalLayer", "/System/Library/Frameworks/QuartzCore.framework/QuartzCore"), objc_selref("layer"));
}

// route a callback to its window before the core sees it
private void mac_route_view(void* view) {
    mac_win_activate(mac_win_of_view(view));
}

private void mac_route_window(void* win) {
    mac_win_activate(mac_win_of_window(win));
}

private void mac_wake_fired(void* self, void* _cmd, void* arg) {
    app_wake();
}

private void ed_view_display_layer(void* self, void* _cmd, void* layer) {
    mac_route_view(self);
    // a covered or miniaturized window's drawables are not consumed, so
    // nextDrawable would block the main thread for it; skip it, and the
    // occlusion callbacks below repaint it when it shows again
    void* wnd = objc.msg_id_v(self, objc_selref("window"));
    if wnd != null {
        u64 occ = cast(fn(void*, void*): u64, objc.raw)(wnd, objc_selref("occlusionState"));
        bool mini = cast(fn(void*, void*): bool, objc.raw)(wnd, objc_selref("isMiniaturized"));
        if (occ & NSWindowOcclusionStateVisible) == 0 || mini {
            mac_display_skipped(g_cur_win);
            return;
        }
    }
    i64 t0 = 0;
    if g_time { t0 = plat_time_us(); }
    i32 wi = g_cur_win;
    mac_display_begin(wi);
    app_render();
    mac_display_end(wi);
    if g_time {
        i64 now = plat_time_us();
        if g_char_t != 0 {
            print("char_to_present_us {}\n", now - g_char_t);
            g_char_t = 0;
        }
        print("paint_us {} dur {} glide {} drawable_wait_us {}\n", now, now - t0, ed_glide_frame_offset(), mtl_drawable_wait_us);
    }
}

private bool ed_view_accepts_first_responder(void* self, void* _cmd) {
    return true;
}

private void ed_view_key_down(void* self, void* _cmd, void* event) {
    mac_route_view(self);
    if g_time { g_char_t = plat_time_us(); }
    i32 mods = mac_mods(event);
    // during composition the input context owns arrows/enter/escape
    if !mac_marked {
        i32 key = mac_event_key(event);
        if key != 0 { app_key(key, mods); }
        else if mac_event_is_space(event) && (mods & MOD_SUPER) != 0 && (mods & MOD_ALT) == 0 {
            app_key(' ', MOD_CTRL);   // real Ctrl+Space, when it reaches keyDown
        }
    }
    if (mods & (MOD_CTRL | MOD_SUPER)) != 0 { return; }
    // text goes through the input context (NSTextInputClient below):
    // dead keys compose, IMEs see their events, committed text
    // arrives in insertText:, editing keys in doCommandBySelector:
    void* arr = objc.msg_id_i(objc_classref("NSArray", "/System/Library/Frameworks/Foundation.framework/Foundation"), objc_selref("arrayWithObject:"), event);
    objc.msg_void_i(self, objc_selref("interpretKeyEvents:"), arr);
}

// --- NSTextInputClient (committed-text level; composition shows in
// --- the IME's own candidate/composition window, not inline) ------

private void ed_view_insert_text(void* self, void* _cmd, void* string, NSRange repl) {
    mac_route_view(self);
    mac_marked = false;
    mac_send_text(mac_plain_string(string));
}

private void ed_view_do_command(void* self, void* _cmd, void* sel) {
    mac_route_view(self);
    if sel == objc_selref("insertNewline:") { app_char(13); return; }
    if sel == objc_selref("insertTab:") { app_char(9); return; }
    if sel == objc_selref("deleteBackward:") { app_char(8); return; }
    // navigation commands are already handled via app_key; swallow
    // the rest instead of chaining to super (which would beep)
}

private void ed_view_set_marked_text(void* self, void* _cmd, void* string, NSRange selr, NSRange repl) {
    mac_route_view(self);
    void* ns = mac_plain_string(string);
    mac_marked = ns != null && objc.msg_q_v(ns, objc_selref("length")) > 0;
}

private void ed_view_unmark_text(void* self, void* _cmd) {
    mac_marked = false;
}

private bool ed_view_has_marked_text(void* self, void* _cmd) {
    return mac_marked;
}

private NSRange ed_view_marked_range(void* self, void* _cmd) {
    if mac_marked { return NSRange{ 0, 1 }; }
    return NSRange{ NS_NOT_FOUND, 0 };
}

private NSRange ed_view_selected_range(void* self, void* _cmd) {
    return NSRange{ 0, 0 };
}

private void* ed_view_attr_substring(void* self, void* _cmd, NSRange range, void* actual) {
    return null;
}

private void* ed_view_valid_attrs(void* self, void* _cmd) {
    return objc.msg_id_v(objc_classref("NSArray", "/System/Library/Frameworks/Foundation.framework/Foundation"), objc_selref("array"));
}

// caret rect in screen coordinates; anchors the candidate window
private CGRect ed_view_first_rect(void* self, void* _cmd, NSRange range, void* actual) {
    mac_route_view(self);
    i32 vcol = vcol_of_col(cur_line, cur_col);
    f64 x = cast(f64, gutter_w() + (vcol - left_vcol) * font_cell_w) / g_scale;
    f64 ytop = cast(f64, (cur_line - top_line) * font_line_h - scroll_off) / g_scale;
    f64 hpt = cast(f64, font_line_h) / g_scale;
    CGRect b = cast(fn(void*, void*): CGRect, objc.raw)(self, objc_selref("bounds"));
    CGRect r = CGRect{ CGPoint{ x, b.size.height - ytop - hpt }, CGSize{ cast(f64, font_cell_w) / g_scale, hpt } };
    CGRect wr = cast(fn(void*, void*, CGRect, void*): CGRect, objc.raw)(self, objc_selref("convertRect:toView:"), r, null);
    return cast(fn(void*, void*, CGRect): CGRect, objc.raw)(g_window, objc_selref("convertRectToScreen:"), wr);
}

private u64 ed_view_char_index(void* self, void* _cmd, CGPoint p) {
    return NS_NOT_FOUND;
}

// Cmd chords arrive as key equivalents, not keyDown. Claim only the
// chords the editor binds so system ones (hide, minimize) keep
// working.
private bool ed_view_perform_key_equivalent(void* self, void* _cmd, void* event) {
    mac_route_view(self);
    i32 mods = mac_mods(event);
    i32 key = mac_event_key(event);
    // real Ctrl+Tab is AppKit's focus-loop key; claim it before the
    // window's default keyboard-UI handling eats it (Ctrl+B toggles
    // the tree from either modifier)
    if (key == K_TAB || key == 'B') && (mods & MOD_SUPER) != 0 {
        app_key(key, mods);
        return true;
    }
    // real Ctrl+Space is the completion chord here: Cmd+Space belongs to
    // Spotlight and never arrives, so it is delivered as the primary
    // chord the core binds; Option combinations type instead
    if key == 0 && mac_event_is_space(event) && (mods & MOD_SUPER) != 0 && (mods & MOD_ALT) == 0 {
        app_key(' ', MOD_CTRL);
        return true;
    }
    if (mods & MOD_CTRL) == 0 { return false; }
    if !mac_cmd_handled(key) { return false; }
    app_key(key, mods);
    return true;
}

private i32 g_last_mx = 0;
private i32 g_last_my = 0;
private i32 g_cursor_kind = -1;

// the pointer shape follows app_cursor_kind imperatively (cursor
// rects are too static for the link and the draggable dividers)
private void mac_update_cursor(i32 x, i32 y) {
    i32 k = app_cursor_kind(x, y);
    if k == g_cursor_kind { return; }
    g_cursor_kind = k;
    void* nc = objc_classref("NSCursor", "/System/Library/Frameworks/AppKit.framework/AppKit");
    void* cur = objc.msg_id_v(nc, objc_selref("arrowCursor"));
    if k == CURSOR_IBEAM { cur = objc.msg_id_v(nc, objc_selref("IBeamCursor")); }
    if k == CURSOR_RESIZE_H { cur = objc.msg_id_v(nc, objc_selref("resizeLeftRightCursor")); }
    if k == CURSOR_RESIZE_V { cur = objc.msg_id_v(nc, objc_selref("resizeUpDownCursor")); }
    if k == CURSOR_HAND { cur = objc.msg_id_v(nc, objc_selref("pointingHandCursor")); }
    objc.msg_void_v(cur, objc_selref("set"));
}

private void ed_view_mouse_moved(void* self, void* _cmd, void* event) {
    mac_route_view(self);
    i32 x = 0;
    i32 y = 0;
    mac_mouse_xy(event, &x, &y);
    g_last_mx = x;
    g_last_my = y;
    app_hover(x, y, mac_mods(event));
    mac_update_cursor(x, y);
}

// modifier-only change: re-evaluate the hover link where the
// pointer already is (cmd pressed or released without motion)
private void ed_view_flags_changed(void* self, void* _cmd, void* event) {
    mac_route_view(self);
    app_hover(g_last_mx, g_last_my, mac_mods(event));
    mac_update_cursor(g_last_mx, g_last_my);
}

private void ed_view_mouse_down(void* self, void* _cmd, void* event) {
    mac_route_view(self);
    i32 x = 0;
    i32 y = 0;
    mac_mouse_xy(event, &x, &y);
    g_last_mx = x;
    g_last_my = y;
    app_mouse(x, y, 0, true, mac_mods(event));
}

private void ed_view_mouse_up(void* self, void* _cmd, void* event) {
    mac_route_view(self);
    i32 x = 0;
    i32 y = 0;
    mac_mouse_xy(event, &x, &y);
    app_mouse(x, y, 0, false, mac_mods(event));
}

private void ed_view_mouse_dragged(void* self, void* _cmd, void* event) {
    mac_route_view(self);
    i32 x = 0;
    i32 y = 0;
    mac_mouse_xy(event, &x, &y);
    g_last_mx = x;
    g_last_my = y;
    app_mouse_move(x, y);
    mac_update_cursor(x, y);
}

private void ed_view_right_mouse_down(void* self, void* _cmd, void* event) {
    mac_route_view(self);
    i32 x = 0;
    i32 y = 0;
    mac_mouse_xy(event, &x, &y);
    app_mouse(x, y, 1, true, mac_mods(event));
}

private void ed_view_right_mouse_up(void* self, void* _cmd, void* event) {
    mac_route_view(self);
    i32 x = 0;
    i32 y = 0;
    mac_mouse_xy(event, &x, &y);
    app_mouse(x, y, 1, false, mac_mods(event));
}

private void ed_view_scroll_wheel(void* self, void* _cmd, void* event) {
    mac_route_view(self);
    f32 dx = 0.0f;
    f32 dy = 0.0f;
    bool precise = cast(fn(void*, void*): bool, objc.raw)(event, objc_selref("hasPreciseScrollingDeltas"));
    if precise {
        // trackpad: pixel deltas in points
        dx = cast(f32, cast(fn(void*, void*): f64, objc.raw)(event, objc_selref("scrollingDeltaX")) * g_scale);
        dy = cast(f32, cast(fn(void*, void*): f64, objc.raw)(event, objc_selref("scrollingDeltaY")) * g_scale);
    } else {
        // wheel: line deltas
        dx = cast(f32, cast(fn(void*, void*): f64, objc.raw)(event, objc_selref("deltaX"))) * cast(f32, WHEEL_LINES * font_line_h);
        dy = cast(f32, cast(fn(void*, void*): f64, objc.raw)(event, objc_selref("deltaY"))) * cast(f32, WHEEL_LINES * font_line_h);
    }
    i32 mx = 0;
    i32 my = 0;
    mac_mouse_xy(event, &mx, &my);
    if precise {
        app_scroll(-dx, -dy, mx, my);
    } else {
        app_scroll_notch(-dx, -dy, mx, my);
    }
}

// Window moved between screens with different scales.
private void ed_view_backing_changed(void* self, void* _cmd) {
    mac_route_view(self);
    void* win = objc.msg_id_v(g_view, objc_selref("window"));
    if win == null { return; }
    f64 scale = objc.msg_d_v(win, objc_selref("backingScaleFactor"));
    if scale == g_scale || scale <= 0.0 { return; }
    g_scale = scale;
    cast(fn(void*, void*, f64): void, objc.raw)(g_layer, objc_selref("setContentsScale:"), scale);
    app_scale(mac_dpi(scale));
    mac_update_size();
}

// --- window delegate --------------------------------------------------

// closing the main window (index 0, the one the app opened with) or the
// last window quits the whole app, with the dirty gate over every buffer;
// closing a secondary window just drops that view, buffers stay open
private bool ed_win_should_close(void* self, void* _cmd, void* sender) {
    mac_route_window(sender);
    if ed_window_active() == 0 || ed_window_count() <= 1 { return app_close(); }
    return true;
}

private void ed_win_will_close(void* self, void* _cmd, void* note) {
    void* wnd = objc.msg_id_v(note, objc_selref("object"));
    i32 wi = mac_win_of_window(wnd);
    if wi < 0 { return; }
    mac_win_activate(wi);
    if ed_window_active() == 0 || ed_window_count() <= 1 {
        // the gate above already saved the session with every window
        // present; stop further saves so the quit does not rewrite it,
        // and let the run loop stop (the process drops the other windows)
        session_set_enabled(false);
        plat_quit();
        return;
    }
    i32 gpu = g_macwin[wi].gpu;
    ignore ed_window_close();   // the core drops wi and moves on
    gpu_win_destroy(gpu);
    mac_pace_free(wi);
    g_macwin[wi].used = false;
    g_macwin[wi].window = null;
    g_macwin[wi].view = null;
    g_macwin[wi].layer = null;
    // releasedWhenClosed is off, so the driver's own reference goes;
    // AppKit still holds the window for the rest of this close
    objc.msg_void_v(wnd, objc_selref("autorelease"));
    i32 nc = ed_window_active();
    g_cur_win = nc;
    g_window = g_macwin[nc].window;
    g_view = g_macwin[nc].view;
    g_layer = g_macwin[nc].layer;
    g_scale = g_macwin[nc].scale;
    gpu_bind(g_macwin[nc].gpu);
}

// a window shown again after being covered or miniaturized needs the
// frame the display path skipped
private void ed_win_occlusion_changed(void* self, void* _cmd, void* note) {
    mac_route_window(objc.msg_id_v(note, objc_selref("object")));
    objc.msg_void_v(g_layer, objc_selref("setNeedsDisplay"));
}

private void ed_win_did_resize(void* self, void* _cmd, void* note) {
    mac_route_window(objc.msg_id_v(note, objc_selref("object")));
    mac_update_size();
}

private void ed_win_will_start_resize(void* self, void* _cmd, void* note) {
    mac_route_window(objc.msg_id_v(note, objc_selref("object")));
    mtl_present_sync(true);
}

private void ed_win_did_end_resize(void* self, void* _cmd, void* note) {
    mac_route_window(objc.msg_id_v(note, objc_selref("object")));
    mtl_present_sync(false);
    plat_damage();
}

private void ed_win_did_become_key(void* self, void* _cmd, void* note) {
    mac_route_window(objc.msg_id_v(note, objc_selref("object")));
    app_focus(true);
}

private void ed_win_did_resign_key(void* self, void* _cmd, void* note) {
    mac_route_window(objc.msg_id_v(note, objc_selref("object")));
    app_focus(false);
}

// --- native windows ------------------------------------------------------

// One window as the driver wants it: an NSWindow with the shared
// delegate, an EdmincView as its content view with a Metal layer, the
// view as first responder, and a tracking area for mouseMoved. The
// pixel size comes from the view's bounds at the display's scale.
// The first window sets g_scale before its view exists, because
// setContentView fires viewDidChangeBackingProperties, which no-ops
// only when g_scale already matches; a later window is unregistered
// while it is built, so that callback routes nowhere. False when the
// window or its layer cannot be made, with nothing left behind.
private bool mac_window_build(bool first, f64 fallback_scale, void** out_wnd, void** out_view,
        void** out_layer, f64* out_scale, i32* out_pw, i32* out_ph) {
    u64 style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    CGRect rect = CGRect{ CGPoint{ 0.0, 0.0 }, CGSize{ cast(f64, WIN_DEFAULT_W), cast(f64, WIN_DEFAULT_H) } };
    void* wnd = cast(fn(void*, void*, CGRect, u64, u64, bool): void*, objc.raw)(
        objc.msg_id_v(objc_classref("NSWindow", "/System/Library/Frameworks/AppKit.framework/AppKit"), objc_selref("alloc")),
        objc_selref("initWithContentRect:styleMask:backing:defer:"), rect, style, NSBackingStoreBuffered, false);
    if wnd == null { return false; }
    objc.msg_void_b(wnd, objc_selref("setReleasedWhenClosed:"), false);
    f64 scale = objc.msg_d_v(wnd, objc_selref("backingScaleFactor"));
    if scale <= 0.0 { scale = fallback_scale; }
    if first { g_scale = scale; }
    objc.msg_void_i(wnd, objc_selref("setDelegate:"), g_win_delegate);
    void* view = objc.msg_id_v(objc.msg_id_v(objc_getClass("EdmincView"), objc_selref("alloc")), objc_selref("init"));
    objc.msg_void_i(wnd, objc_selref("setContentView:"), view);
    mac_release(view);   // the window owns it now
    objc.msg_void_b(view, objc_selref("setWantsLayer:"), true);
    // wantsLayer builds the backing layer via makeBackingLayer
    void* layer = objc.msg_id_v(view, objc_selref("layer"));
    if layer == null {
        objc.msg_void_i(wnd, objc_selref("setDelegate:"), null);
        mac_release(wnd);
        return false;
    }
    objc.msg_void_i(layer, objc_selref("setDelegate:"), view);
    ignore objc.msg_id_i(wnd, objc_selref("makeFirstResponder:"), view);
    // mouseMoved needs a tracking area (MouseMoved | ActiveInKeyWindow
    // | InVisibleRect)
    void* ta = cast(fn(void*, void*, CGRect, u64, void*, void*): void*, objc.raw)(
        objc.msg_id_v(objc_classref("NSTrackingArea", "/System/Library/Frameworks/AppKit.framework/AppKit"), objc_selref("alloc")),
        objc_selref("initWithRect:options:owner:userInfo:"),
        CGRect{ CGPoint{ 0.0, 0.0 }, CGSize{ 0.0, 0.0 } },
        cast(u64, 0x02 | 0x20 | 0x200), view, null);
    objc.msg_void_i(view, objc_selref("addTrackingArea:"), ta);
    cast(fn(void*, void*, f64): void, objc.raw)(layer, objc_selref("setContentsScale:"), scale);
    CGRect b = cast(fn(void*, void*): CGRect, objc.raw)(view, objc_selref("bounds"));
    *out_wnd = wnd;
    *out_view = view;
    *out_layer = layer;
    *out_scale = scale;
    *out_pw = cast(i32, b.size.width * scale + 0.5);
    *out_ph = cast(i32, b.size.height * scale + 0.5);
    return true;
}

// A native window over the shared buffer set, showing the active buffer;
// returns its index, equal in the core and the driver, or -1. With
// cascade it steps off the opener's top-left; otherwise it takes the
// given frame (a session restore). The window is built unregistered,
// so the callbacks setContentView fires route nowhere and the opener's
// state stays untouched; then it is registered and made current.
i32 mac_native_create(i32 x, i32 y, i32 w, i32 h, i32 maxi, bool cascade) {
    i32 wi = ed_window_new(ed_buf_active());
    if wi < 0 { return -1; }
    void* opener = g_window;
    f64 opener_scale = g_scale;
    void* wnd = null;
    void* view = null;
    void* layer = null;
    f64 scale = 0.0;
    i32 pw = 0;
    i32 ph = 0;
    if !mac_window_build(false, opener_scale, &wnd, &view, &layer, &scale, &pw, &ph) {
        ignore ed_window_close();
        return -1;
    }
    i32 gpu = gpu_win_create(layer, pw, ph);
    if gpu < 0 {
        objc.msg_void_i(wnd, objc_selref("setDelegate:"), null);
        mac_release(wnd);
        ignore ed_window_close();
        return -1;
    }
    // ed_window_new already made the core's current window wi; register
    // the record, park the opener's scale, point the singletons at it
    g_macwin[wi].window = wnd;
    g_macwin[wi].view = view;
    g_macwin[wi].layer = layer;
    g_macwin[wi].scale = scale;
    g_macwin[wi].gpu = gpu;
    g_macwin[wi].used = true;
    g_macwin[g_cur_win].scale = g_scale;
    g_cur_win = wi;
    g_window = wnd;
    g_view = view;
    g_layer = layer;
    g_scale = scale;
    gpu_bind(gpu);
    // its own dpi context when this display's scale differs from the opener's
    if scale != opener_scale { app_scale(mac_dpi(scale)); }
    ed_retitle();
    app_resize(pw, ph);
    if cascade {
        // cascadeTopLeftFromPoint: places the window at the point and
        // returns the next one down and right; the second call steps
        // this window off the opener's top-left
        CGRect of = cast(fn(void*, void*): CGRect, objc.raw)(opener, objc_selref("frame"));
        CGPoint next = cast(fn(void*, void*, CGPoint): CGPoint, objc.raw)(wnd, objc_selref("cascadeTopLeftFromPoint:"),
            CGPoint{ of.origin.x, of.origin.y + of.size.height });
        ignore cast(fn(void*, void*, CGPoint): CGPoint, objc.raw)(wnd, objc_selref("cascadeTopLeftFromPoint:"), next);
    } else {
        cast(fn(void*, void*, CGRect, bool): void, objc.raw)(wnd, objc_selref("setFrame:display:"),
            CGRect{ CGPoint{ cast(f64, x), cast(f64, y) }, CGSize{ cast(f64, w), cast(f64, h) } }, false);
    }
    if maxi != 0 { objc.msg_void_i(wnd, objc_selref("zoom:"), null); }
    objc.msg_void_i(wnd, objc_selref("makeKeyAndOrderFront:"), null);
    return wi;
}

// --- class registration ----------------------------------------------

private void mac_register_classes() {
    void* view = objc_allocateClassPair(objc_classref("NSView", "/System/Library/Frameworks/AppKit.framework/AppKit"), "EdmincView", 0);
    ignore class_addMethod(view, objc_selref("makeBackingLayer"), cast(void*, &ed_view_make_backing_layer), OBJC_ENC_i_v);
    ignore class_addMethod(view, objc_selref("displayLayer:"), cast(void*, &ed_view_display_layer), OBJC_ENC_v_i);
    ignore class_addMethod(view, objc_selref("acceptsFirstResponder"), cast(void*, &ed_view_accepts_first_responder), OBJC_ENC_b_v);
    ignore class_addMethod(view, objc_selref("keyDown:"), cast(void*, &ed_view_key_down), OBJC_ENC_v_i);
    ignore class_addMethod(view, objc_selref("performKeyEquivalent:"), cast(void*, &ed_view_perform_key_equivalent), OBJC_ENC_b_i);
    ignore class_addMethod(view, objc_selref("mouseDown:"), cast(void*, &ed_view_mouse_down), OBJC_ENC_v_i);
    ignore class_addMethod(view, objc_selref("mouseMoved:"), cast(void*, &ed_view_mouse_moved), OBJC_ENC_v_i);
    ignore class_addMethod(view, objc_selref("flagsChanged:"), cast(void*, &ed_view_flags_changed), OBJC_ENC_v_i);
    ignore class_addMethod(view, objc_selref("mouseUp:"), cast(void*, &ed_view_mouse_up), OBJC_ENC_v_i);
    ignore class_addMethod(view, objc_selref("mouseDragged:"), cast(void*, &ed_view_mouse_dragged), OBJC_ENC_v_i);
    ignore class_addMethod(view, objc_selref("rightMouseDown:"), cast(void*, &ed_view_right_mouse_down), OBJC_ENC_v_i);
    ignore class_addMethod(view, objc_selref("rightMouseUp:"), cast(void*, &ed_view_right_mouse_up), OBJC_ENC_v_i);
    ignore class_addMethod(view, objc_selref("scrollWheel:"), cast(void*, &ed_view_scroll_wheel), OBJC_ENC_v_i);
    ignore class_addMethod(view, objc_selref("viewDidChangeBackingProperties"), cast(void*, &ed_view_backing_changed), OBJC_ENC_v_v);
    ignore class_addMethod(view, objc_selref("insertText:replacementRange:"), cast(void*, &ed_view_insert_text), "v@:@{_NSRange=QQ}");
    ignore class_addMethod(view, objc_selref("doCommandBySelector:"), cast(void*, &ed_view_do_command), "v@::");
    ignore class_addMethod(view, objc_selref("setMarkedText:selectedRange:replacementRange:"), cast(void*, &ed_view_set_marked_text), "v@:@{_NSRange=QQ}{_NSRange=QQ}");
    ignore class_addMethod(view, objc_selref("unmarkText"), cast(void*, &ed_view_unmark_text), OBJC_ENC_v_v);
    ignore class_addMethod(view, objc_selref("hasMarkedText"), cast(void*, &ed_view_has_marked_text), OBJC_ENC_b_v);
    ignore class_addMethod(view, objc_selref("markedRange"), cast(void*, &ed_view_marked_range), "{_NSRange=QQ}@:");
    ignore class_addMethod(view, objc_selref("selectedRange"), cast(void*, &ed_view_selected_range), "{_NSRange=QQ}@:");
    ignore class_addMethod(view, objc_selref("attributedSubstringForProposedRange:actualRange:"), cast(void*, &ed_view_attr_substring), "@@:{_NSRange=QQ}^{_NSRange=QQ}");
    ignore class_addMethod(view, objc_selref("validAttributesForMarkedText"), cast(void*, &ed_view_valid_attrs), "@@:");
    ignore class_addMethod(view, objc_selref("firstRectForCharacterRange:actualRange:"), cast(void*, &ed_view_first_rect), "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}");
    ignore class_addMethod(view, objc_selref("characterIndexForPoint:"), cast(void*, &ed_view_char_index), "Q@:{CGPoint=dd}");
    void* tic = objc_getProtocol("NSTextInputClient");
    if tic != null { ignore class_addProtocol(view, tic); }
    objc_registerClassPair(view);

    void* dlg = objc_allocateClassPair(objc_getClass("NSObject"), "EdmincWinDelegate", 0);
    ignore class_addMethod(dlg, objc_selref("windowShouldClose:"), cast(void*, &ed_win_should_close), OBJC_ENC_b_i);
    ignore class_addMethod(dlg, objc_selref("windowWillClose:"), cast(void*, &ed_win_will_close), OBJC_ENC_v_i);
    ignore class_addMethod(dlg, objc_selref("windowDidResize:"), cast(void*, &ed_win_did_resize), OBJC_ENC_v_i);
    ignore class_addMethod(dlg, objc_selref("windowWillStartLiveResize:"), cast(void*, &ed_win_will_start_resize), OBJC_ENC_v_i);
    ignore class_addMethod(dlg, objc_selref("windowDidEndLiveResize:"), cast(void*, &ed_win_did_end_resize), OBJC_ENC_v_i);
    ignore class_addMethod(dlg, objc_selref("windowDidBecomeKey:"), cast(void*, &ed_win_did_become_key), OBJC_ENC_v_i);
    ignore class_addMethod(dlg, objc_selref("windowDidResignKey:"), cast(void*, &ed_win_did_resign_key), OBJC_ENC_v_i);
    ignore class_addMethod(dlg, objc_selref("windowDidChangeOcclusionState:"), cast(void*, &ed_win_occlusion_changed), OBJC_ENC_v_i);
    ignore class_addMethod(dlg, objc_selref("windowDidDeminiaturize:"), cast(void*, &ed_win_occlusion_changed), OBJC_ENC_v_i);
    objc_registerClassPair(dlg);

    void* tt = objc_allocateClassPair(objc_getClass("NSObject"), "EdmincTimerTarget", 0);
    ignore class_addMethod(tt, objc_selref("onTimer:"), cast(void*, &mac_timer_fired), OBJC_ENC_v_i);
    ignore class_addMethod(tt, objc_selref("onWake:"), cast(void*, &mac_wake_fired), OBJC_ENC_v_i);
    ignore class_addMethod(tt, objc_selref("onPickFolder:"), cast(void*, &mac_pick_folder_fired), OBJC_ENC_v_i);
    ignore class_addMethod(tt, objc_selref("onPickSave:"), cast(void*, &mac_pick_save_fired), OBJC_ENC_v_i);
    ignore class_addMethod(tt, objc_selref("onFrame:"), cast(void*, &mac_frame_fired), OBJC_ENC_v_i);
    objc_registerClassPair(tt);
}

// Application icon (Dock, Cmd+Tab) from the embedded app logo
// (lib/icon_edmc.mc): the favicon rendered at 256, box-downsampled into
// the macOS icon grid and premultiplied. The favicon is full-bleed; a
// Mac icon is not: on the 1024 grid the rounded square is 824 wide,
// inset 100 on each side, with corners of radius 185.4, and an icon
// that fills its canvas sits visibly larger than every other one in
// the Dock. So the logo is drawn at that inset and its corners are
// cut to that radius (the favicon's own are tighter).
private const i32 MAC_ICON_PX = 256;
private const i32 MAC_ICON_GRID = 1024;
private const i32 MAC_ICON_INSET = 100;      // on the 1024 grid, each side
private const i32 MAC_ICON_RADIUS10 = 1854;  // corner radius on the 1024 grid, times ten

private void mac_set_app_icon() {
    i32 size = MAC_ICON_PX;
    i32 sz = 0;
    u8* src = icon_edmc_rgba(size, &sz);
    if src == null { return; }
    i32 inset = size * MAC_ICON_INSET / MAC_ICON_GRID;
    i32 content = size - 2 * inset;
    f64 radius = cast(f64, size) * cast(f64, MAC_ICON_RADIUS10) / (10.0 * cast(f64, MAC_ICON_GRID));
    str cs = "NSCalibratedRGBColorSpace";
    void* rep = cast(fn(void*, void*, void*, i64, i64, i64, i64, bool, bool, void*, i64, i64): void*, objc.raw)(
        objc.msg_id_v(objc_classref("NSBitmapImageRep", "/System/Library/Frameworks/AppKit.framework/AppKit"), objc_selref("alloc")),
        objc_selref("initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:"),
        null, cast(i64, size), cast(i64, size), 8, 4, true, false,
        mac_nsstring(cs.data, cs.len), cast(i64, size * 4), 32);
    if rep == null { return; }
    u8* px = cast(u8*, objc.msg_id_v(rep, objc_selref("bitmapData")));
    if px == null { return; }
    memset(px, 0, size * size * 4);
    for i32 y = inset; y < inset + content; y++ {
        i32 sy0 = (y - inset) * sz / content;
        i32 sy1 = (y + 1 - inset) * sz / content;
        for i32 x = inset; x < inset + content; x++ {
            i32 sx0 = (x - inset) * sz / content;
            i32 sx1 = (x + 1 - inset) * sz / content;
            // the corner cut: coverage from the distance to the corner's
            // arc centre, so the edge is one pixel of anti-aliasing
            f64 cx = cast(f64, x) + 0.5;
            f64 cy = cast(f64, y) + 0.5;
            f64 lo = cast(f64, inset) + radius;
            f64 hi = cast(f64, inset + content) - radius;
            f64 dx = 0.0;
            f64 dy = 0.0;
            if cx < lo { dx = lo - cx; } else if cx > hi { dx = cx - hi; }
            if cy < lo { dy = lo - cy; } else if cy > hi { dy = cy - hi; }
            f64 cov = 1.0;
            if dx > 0.0 && dy > 0.0 {
                f64 d = sqrt(dx * dx + dy * dy);
                cov = radius + 0.5 - d;
                if cov < 0.0 { cov = 0.0; }
                if cov > 1.0 { cov = 1.0; }
            }
            if cov <= 0.0 { continue; }
            i32 ar = 0;
            i32 ag = 0;
            i32 ab = 0;
            i32 aa = 0;
            i32 cnt = 0;
            for i32 syy = sy0; syy < sy1; syy++ {
                for i32 sxx = sx0; sxx < sx1; sxx++ {
                    i32 o = (syy * sz + sxx) * 4;
                    ar += cast(i32, src[o]);
                    ag += cast(i32, src[o + 1]);
                    ab += cast(i32, src[o + 2]);
                    aa += cast(i32, src[o + 3]);
                    cnt++;
                }
            }
            if cnt < 1 { cnt = 1; }
            i32 a = cast(i32, cast(f64, aa / cnt) * cov + 0.5);
            u8* p = px + (y * size + x) * 4;
            p[0] = cast(u8, (ar / cnt) * a / 255);   // RGBA, premultiplied
            p[1] = cast(u8, (ag / cnt) * a / 255);
            p[2] = cast(u8, (ab / cnt) * a / 255);
            p[3] = cast(u8, a);
        }
    }
    void* img = cast(fn(void*, void*, CGSize): void*, objc.raw)(
        objc.msg_id_v(objc_classref("NSImage", "/System/Library/Frameworks/AppKit.framework/AppKit"), objc_selref("alloc")),
        objc_selref("initWithSize:"), CGSize{ cast(f64, size), cast(f64, size) });
    if img == null { return; }
    objc.msg_void_i(img, objc_selref("addRepresentation:"), rep);
    objc.msg_void_i(NSApp, objc_selref("setApplicationIconImage:"), img);
}

i32 plat_main() {
    // before anything else: the process that goes on is the exec'd one
    if hl_detach_launch() { mac_detach(); }
    objc_runtime_init();
    void* pool = objc.msg_id_v(objc.msg_id_v(objc_classref("NSAutoreleasePool", "/System/Library/Frameworks/Foundation.framework/Foundation"), objc_selref("alloc")), objc_selref("init"));

    for i32 a = 1; a < get_argc(); a++ { hl_arg(&a); }

    NSApp = objc.msg_id_v(objc_classref("NSApplication", "/System/Library/Frameworks/AppKit.framework/AppKit"), objc_selref("sharedApplication"));
    cast(fn(void*, void*, i64): void, objc.raw)(NSApp, objc_selref("setActivationPolicy:"), NSApplicationActivationPolicyRegular);
    mac_set_app_icon();
    mac_register_classes();

    g_win_delegate = objc.msg_id_v(objc.msg_id_v(objc_getClass("EdmincWinDelegate"), objc_selref("alloc")), objc_selref("init"));
    mac_set_timer_target(objc.msg_id_v(objc.msg_id_v(objc_getClass("EdmincTimerTarget"), objc_selref("alloc")), objc_selref("init")));
    i32 pw = 0;
    i32 ph = 0;
    if !mac_window_build(true, 1.0, &g_window, &g_view, &g_layer, &g_scale, &pw, &ph) {
        print("NSWindow init failed\n");
        return 1;
    }
    i32 dpi = mac_dpi(g_scale);
    if !font_init(dpi) {
        print("font init failed\n");
        return 1;
    }

    if !gpu_init(g_layer, pw, ph) {
        return 1;
    }
    draw_init();
    g_macwin[0].window = g_window;
    g_macwin[0].view = g_view;
    g_macwin[0].layer = g_layer;
    g_macwin[0].scale = g_scale;
    g_macwin[0].gpu = 0;
    g_macwin[0].used = true;
    g_cur_win = 0;

    app_resize(pw, ph);
    i64 t0 = plat_time_us();
    app_init(str_from(&g_arg_path[0], g_arg_path_len), dpi);
    g_load_us = plat_time_us() - t0;

    bool restored = false;
    if g_handover_len > 0 {
        restored = app_handover_restore(str_from(&g_handover[0], g_handover_len));
    } else if g_shot_len == 0 && g_play_len == 0 && !g_smoke {
        restored = app_session_restore();
    }

    // launch zoomed to the visible screen area (menu bar and Dock
    // excluded), without entering the fullscreen space, unless a
    // restored session placed the window(s) itself
    void* screen = objc.msg_id_v(objc_classref("NSScreen", "/System/Library/Frameworks/AppKit.framework/AppKit"), objc_selref("mainScreen"));
    if !restored {
        if screen != null {
            CGRect vf = cast(fn(void*, void*): CGRect, objc.raw)(screen, objc_selref("visibleFrame"));
            cast(fn(void*, void*, CGRect, bool): void, objc.raw)(g_window, objc_selref("setFrame:display:"), vf, true);
        } else {
            objc.msg_void_v(g_window, objc_selref("center"));
        }
    }
    objc.msg_void_b(NSApp, objc_selref("activateIgnoringOtherApps:"), true);
    // every window a restored session made comes on screen here, after
    // the activation, the active one last and key; the singletons
    // follow it, since the core chose it without the driver
    i32 aw = ed_window_active();
    for i32 i = 0; i < MAC_WIN_MAX; i++ {
        if g_macwin[i].used && i != aw { objc.msg_void_i(g_macwin[i].window, objc_selref("orderFront:"), null); }
    }
    mac_win_activate(aw);
    objc.msg_void_i(g_window, objc_selref("makeKeyAndOrderFront:"), null);
    // Unbundled binaries need a synthesized activation event or the
    // window never composites (same workaround as sokol_app).
    void* focusevent = cast(fn(void*, void*, u64, NSPoint, u64, f64, i64, void*, i32, i64, i64): void*, objc.raw)(
        objc_classref("NSEvent", "/System/Library/Frameworks/AppKit.framework/AppKit"),
        objc_selref("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:"),
        NSEventTypeAppKitDefined, NSZeroPoint, 0x40, 0.0, 0, null,
        NSEventSubtypeApplicationActivated, 0, 0);
    cast(fn(void*, void*, void*, bool): void, objc.raw)(NSApp, objc_selref("postEvent:atStart:"), focusevent, true);
    plat_damage();
    // a second window opens after the first is shown, so the zoom above
    // still targets window 0
    if g_newwin { ignore plat_window_open(); }

    hl_inject();

    if g_dump_term_len > 0 {
        hl_dump_term();
        if g_shot_len == 0 {
            ed_term_close_all();
            mac_release(pool);
            return 0;
        }
    }
    if g_shot_len > 0 {
        // render one frame, dump it to a file, exit; headless-safe
        // the dump should show the finished frame, so let any
        // background work land before it is taken
        app_settle();
        gpu_request_shot(str_from(&g_shot[0], g_shot_len));
        app_render();
        mac_release(pool);
        return 0;
    }
    if g_play_len > 0 {
        // a recorded fuzz run in the live window, one step per tick
        if !play_open(str_from(&g_play[0], g_play_len)) { return 2; }
        plat_set_timer(PLAY_TIMER, g_play_ms);
    }

    if g_smoke {
        // one real frame through the full Metal path, no event loop
        i64 f0 = plat_time_us();
        app_render();
        i64 fr = plat_time_us() - f0;
        print("smoke: rendered {} verts, {} lines, load {} us, frame {} us\n",
            draw_nverts, tb.nlines, g_load_us, fr);
        mac_release(pool);
        return 0;
    }

    objc.msg_void_v(NSApp, objc_selref("run"));
    mac_release(pool);
    return 0;
}
