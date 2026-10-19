// x11_probe.mc - drive the editor from outside, the Linux twin of
// scripts/ui_probe.ps1. Keystrokes go through XTest, so they arrive
// as real key events; the clipboard side owns or reads the CLIPBOARD
// selection, which is the only way to test copy and paste without a
// human at the keyboard.
//
//   minc scripts/x11_probe.mc -o build/x11_probe
//   build/x11_probe <title-substring> <command> [arg]
//
// Commands:
//   title                 print the window's _NET_WM_NAME
//   ctrl <letter>         send one Ctrl+<letter> chord
//   key <keysym-decimal>  send one key by keysym
//   clip <text> <ms>      own CLIPBOARD with <text> for <ms>, serving
//                         requests, so the editor can paste it
//   click <x> <y>         synthetic left click at window coordinates
//   readclip              print the CLIPBOARD owner's text
//   utf8 <keysym-decimal> send a keysym the layout does not map, by
//                         borrowing an unused keycode and restoring it

import str;
import thread;

struct XDisplay { i32 _opaque; }
type Display = XDisplay;
type XID = u64;
type Window = XID;
type Atom = XID;
type Time = u64;

struct XKeyEvent {
    i32 type;
    u64 serial;
    i32 send_event;
    Display* display;
    Window window;
    Window root;
    Window subwindow;
    Time time;
    i32 x;
    i32 y;
    i32 x_root;
    i32 y_root;
    u32 state;
    u32 keycode;
    i32 same_screen;
}

struct XButtonEvent {
    i32 type;
    u64 serial;
    i32 send_event;
    Display* display;
    Window window;
    Window root;
    Window subwindow;
    Time time;
    i32 x;
    i32 y;
    i32 x_root;
    i32 y_root;
    u32 state;
    u32 button;
    i32 same_screen;
}

struct XSelectionRequestEvent {
    i32 type;
    u64 serial;
    i32 send_event;
    Display* display;
    Window owner;
    Window requestor;
    Atom selection;
    Atom target;
    Atom property;
    Time time;
}

struct XSelectionEvent {
    i32 type;
    u64 serial;
    i32 send_event;
    Display* display;
    Window requestor;
    Atom selection;
    Atom target;
    Atom property;
    Time time;
}

unsafe_union XEvent {
    i32 type;
    XKeyEvent xkey;
    XButtonEvent xbutton;
    XSelectionEvent xselection;
    XSelectionRequestEvent xselectionrequest;
    i64[24] pad;
}

const i32 ButtonPress = 4;
const i32 ButtonRelease = 5;
const i64 ButtonPressMask = 1 << 2;
const i32 KeyPress = 2;
const i32 KeyRelease = 3;
const i64 KeyPressMask = 1 << 0;
const u32 ControlMask = 1 << 2;
const u32 ShiftMask = 1 << 0;
const i32 SelectionNotify = 31;
const i32 SelectionRequest = 30;
const i32 PropModeReplace = 0;
const Atom XA_STRING = 31;
const Atom XA_ATOM = 4;
const i32 RevertToParent = 2;

extern "libX11.so.6" {
    Display* XOpenDisplay(u8* name);
    Window XDefaultRootWindow(Display* d);
    Window XCreateSimpleWindow(Display* d, Window parent, i32 x, i32 y, u32 w, u32 h, u32 bw, u64 border, u64 bg);
    i32 XQueryTree(Display* d, Window w, Window* root, Window* parent, Window** kids, u32* n);
    Atom XInternAtom(Display* d, u8* name, i32 only);
    i32 XGetWindowProperty(Display* d, Window w, Atom prop, i64 off, i64 len, i32 del, Atom req, Atom* atype, i32* afmt, u64* nitems, u64* after, u8** ret);
    i32 XChangeProperty(Display* d, Window w, Atom prop, Atom type, i32 fmt, i32 mode, u8* data, i32 n);
    i32 XDeleteProperty(Display* d, Window w, Atom prop);
    i32 XSetSelectionOwner(Display* d, Atom sel, Window owner, Time t);
    Window XGetSelectionOwner(Display* d, Atom sel);
    i32 XConvertSelection(Display* d, Atom sel, Atom target, Atom prop, Window req, Time t);
    i32 XSendEvent(Display* d, Window w, i32 prop, i64 mask, XEvent* ev);
    i32 XNextEvent(Display* d, XEvent* ev);
    i32 XPending(Display* d);
    i32 XFlush(Display* d);
    i32 XSync(Display* d, i32 discard);
    i32 XFree(void* p);
    i32 XRaiseWindow(Display* d, Window w);
    i32 XSetInputFocus(Display* d, Window w, i32 revert, Time t);
    u8 XKeysymToKeycode(Display* d, u64 keysym);
    i32 XGetInputFocus(Display* d, Window* focus, i32* revert);
    i32 XDisplayKeycodes(Display* d, i32* min_kc, i32* max_kc);
    u64* XGetKeyboardMapping(Display* d, u8 first, i32 count, i32* syms_per_code);
    i32 XChangeKeyboardMapping(Display* d, i32 first, i32 syms_per_code, u64* syms, i32 count);
    i32 XSelectInput(Display* d, Window w, i64 mask);
}

private Display* g_d = null;
private Atom g_utf8 = 0;
private Atom g_netname = 0;
private Atom g_clipboard = 0;
private Atom g_targets = 0;

private bool name_matches(Window w, str want) {
    Atom at = 0;
    i32 fmt = 0;
    u64 ni = 0;
    u64 aft = 0;
    u8* p = null;
    if XGetWindowProperty(g_d, w, g_netname, 0, 1024, 0, g_utf8, &at, &fmt, &ni, &aft, &p) != 0 {
        return false;
    }
    if p == null { return false; }
    i32 n = cast(i32, ni);
    bool hit = false;
    for i32 i = 0; i + want.len <= n; i++ {
        bool m = true;
        for i32 j = 0; j < want.len; j++ {
            if p[i + j] != want.data[j] { m = false; break; }
        }
        if m { hit = true; break; }
    }
    ignore XFree(cast(void*, p));
    return hit;
}

private Window find_window(Window w, str want, i32 depth) {
    if depth > 0 && name_matches(w, want) { return w; }
    Window root = 0;
    Window parent = 0;
    Window* kids = null;
    u32 n = 0;
    if XQueryTree(g_d, w, &root, &parent, &kids, &n) == 0 { return 0; }
    Window hit = 0;
    for u32 i = 0; i < n; i++ {
        if hit != 0 { break; }
        hit = find_window(kids[i], want, depth + 1);
    }
    if kids != null { ignore XFree(cast(void*, kids)); }
    return hit;
}

private void print_title(Window w) {
    Atom at = 0;
    i32 fmt = 0;
    u64 ni = 0;
    u64 aft = 0;
    u8* p = null;
    if XGetWindowProperty(g_d, w, g_netname, 0, 1024, 0, g_utf8, &at, &fmt, &ni, &aft, &p) != 0 {
        return;
    }
    if p == null { return; }
    print("{}\n", str_from(p, cast(i32, ni)));
    ignore XFree(cast(void*, p));
}

private void send_key(Window win, u64 keysym, u32 state) {
    u8 kc = XKeysymToKeycode(g_d, keysym);
    if kc == 0 {
        print("no keycode for keysym {}\n", cast(i32, keysym));
        return;
    }
    XEvent ev;
    ev.xkey.type = KeyPress;
    ev.xkey.send_event = 1;
    ev.xkey.display = g_d;
    ev.xkey.window = win;
    ev.xkey.root = XDefaultRootWindow(g_d);
    ev.xkey.time = 0;
    ev.xkey.state = state;
    ev.xkey.keycode = cast(u32, kc);
    ev.xkey.same_screen = 1;
    ignore XSendEvent(g_d, win, 1, KeyPressMask, &ev);
    ignore XFlush(g_d);
}

// Own CLIPBOARD and answer requests for ms milliseconds, so the
// editor under test has something to paste.
private void serve_clipboard(str text, i32 ms) {
    Window w = XCreateSimpleWindow(g_d, XDefaultRootWindow(g_d), 0, 0, 1, 1, 0, 0, 0);
    ignore XSetSelectionOwner(g_d, g_clipboard, w, 0);
    ignore XFlush(g_d);
    if XGetSelectionOwner(g_d, g_clipboard) != w {
        print("could not take CLIPBOARD\n");
        return;
    }
    print("serving CLIPBOARD ({} bytes) for {} ms\n", text.len, ms);
    i32 waited = 0;
    while waited < ms {
        while XPending(g_d) > 0 {
            XEvent ev;
            ignore XNextEvent(g_d, &ev);
            if ev.type != SelectionRequest { continue; }
            XSelectionRequestEvent* rq = &ev.xselectionrequest;
            XEvent resp;
            resp.xselection.type = SelectionNotify;
            resp.xselection.display = rq.display;
            resp.xselection.requestor = rq.requestor;
            resp.xselection.selection = rq.selection;
            resp.xselection.target = rq.target;
            resp.xselection.time = rq.time;
            resp.xselection.property = rq.property;
            if resp.xselection.property == 0 { resp.xselection.property = rq.target; }
            if rq.target == g_targets {
                Atom[2] list = { g_targets, g_utf8 };
                ignore XChangeProperty(g_d, rq.requestor, resp.xselection.property,
                    XA_ATOM, 32, PropModeReplace, cast(u8*, &list[0]), 2);
            } else if rq.target == g_utf8 || rq.target == XA_STRING {
                ignore XChangeProperty(g_d, rq.requestor, resp.xselection.property,
                    rq.target, 8, PropModeReplace, text.data, text.len);
                print("served target as {} bytes\n", text.len);
            } else {
                resp.xselection.property = 0;
            }
            ignore XSendEvent(g_d, rq.requestor, 0, 0, &resp);
            ignore XFlush(g_d);
        }
        thread_sleep(20);
        waited += 20;
    }
}

private void read_clipboard() {
    Window w = XCreateSimpleWindow(g_d, XDefaultRootWindow(g_d), 0, 0, 1, 1, 0, 0, 0);
    Atom prop = XInternAtom(g_d, "PROBE_PASTE", 0);
    if XGetSelectionOwner(g_d, g_clipboard) == 0 {
        print("CLIPBOARD has no owner\n");
        return;
    }
    ignore XDeleteProperty(g_d, w, prop);
    ignore XConvertSelection(g_d, g_clipboard, g_utf8, prop, w, 0);
    ignore XFlush(g_d);
    i32 waited = 0;
    while waited < 2000 {
        while XPending(g_d) > 0 {
            XEvent ev;
            ignore XNextEvent(g_d, &ev);
            if ev.type != SelectionNotify { continue; }
            if ev.xselection.property == 0 {
                print("owner refused UTF8_STRING\n");
                return;
            }
            Atom at = 0;
            i32 fmt = 0;
            u64 ni = 0;
            u64 aft = 0;
            u8* p = null;
            if XGetWindowProperty(g_d, w, prop, 0, 65536, 0, 0, &at, &fmt, &ni, &aft, &p) != 0 {
                print("property read failed\n");
                return;
            }
            if p == null {
                print("empty property\n");
                return;
            }
            print("clipboard: [{}]\n", str_from(p, cast(i32, ni)));
            ignore XFree(cast(void*, p));
            return;
        }
        thread_sleep(20);
        waited += 20;
    }
    print("timed out waiting for SelectionNotify\n");
}

// Send a keysym the current layout does not map, by borrowing a
// keycode that maps to nothing and handing it back afterwards. This
// is the only way to exercise multi-byte committed text on a layout
// with no non-ASCII keys and no input method installed.
private void send_unmapped(Window win, u64 keysym) {
    i32 lo = 0;
    i32 hi = 0;
    ignore XDisplayKeycodes(g_d, &lo, &hi);
    i32 per = 0;
    u64* map = XGetKeyboardMapping(g_d, cast(u8, lo), hi - lo + 1, &per);
    if map == null || per <= 0 {
        print("cannot read the keyboard map\n");
        return;
    }
    i32 spare = -1;
    for i32 kc = hi; kc >= lo; kc-- {
        bool empty = true;
        for i32 j = 0; j < per; j++ {
            if map[(kc - lo) * per + j] != 0 { empty = false; break; }
        }
        if empty {
            spare = kc;
            break;
        }
    }
    ignore XFree(cast(void*, map));
    if spare < 0 {
        print("no spare keycode to borrow\n");
        return;
    }
    u64* syms = alloc<u64>(per);
    for i32 j = 0; j < per; j++ { syms[j] = keysym; }
    ignore XChangeKeyboardMapping(g_d, spare, per, syms, 1);
    ignore XSync(g_d, 0);
    thread_sleep(200);
    print("borrowed keycode {} for keysym {}\n", spare, cast(i32, keysym));

    XEvent ev;
    ev.xkey.type = KeyPress;
    ev.xkey.send_event = 1;
    ev.xkey.display = g_d;
    ev.xkey.window = win;
    ev.xkey.root = XDefaultRootWindow(g_d);
    ev.xkey.time = 0;
    ev.xkey.state = 0;
    ev.xkey.keycode = cast(u32, spare);
    ev.xkey.same_screen = 1;
    ignore XSendEvent(g_d, win, 1, KeyPressMask, &ev);
    ignore XFlush(g_d);
    thread_sleep(300);

    for i32 j = 0; j < per; j++ { syms[j] = 0; }
    ignore XChangeKeyboardMapping(g_d, spare, per, syms, 1);
    ignore XSync(g_d, 0);
    free(syms);
    print("keycode {} released\n", spare);
}

// A synthetic click at window coordinates. The driver does not check
// send_event, so this exercises the same path a real click takes.
private void send_click(Window win, i32 x, i32 y) {
    XEvent ev;
    ev.xbutton.type = ButtonPress;
    ev.xbutton.send_event = 1;
    ev.xbutton.display = g_d;
    ev.xbutton.window = win;
    ev.xbutton.root = XDefaultRootWindow(g_d);
    ev.xbutton.time = 0;
    ev.xbutton.x = x;
    ev.xbutton.y = y;
    ev.xbutton.x_root = x;
    ev.xbutton.y_root = y;
    ev.xbutton.state = 0;
    ev.xbutton.button = 1;
    ev.xbutton.same_screen = 1;
    ignore XSendEvent(g_d, win, 1, ButtonPressMask, &ev);
    ev.xbutton.type = ButtonRelease;
    ignore XSendEvent(g_d, win, 1, ButtonPressMask, &ev);
    ignore XFlush(g_d);
}

i32 numarg(i32 i) {
    str a = str_from_cstr(get_arg(i));
    i32 v = 0;
    for i32 k = 0; k < a.len; k++ {
        if a.data[k] >= '0' && a.data[k] <= '9' { v = v * 10 + cast(i32, a.data[k]) - 48; }
    }
    return v;
}

i32 main() {
    g_d = XOpenDisplay(null);
    if g_d == null {
        print("no display\n");
        return 1;
    }
    g_utf8 = XInternAtom(g_d, "UTF8_STRING", 0);
    g_netname = XInternAtom(g_d, "_NET_WM_NAME", 0);
    g_clipboard = XInternAtom(g_d, "CLIPBOARD", 0);
    g_targets = XInternAtom(g_d, "TARGETS", 0);

    str title = str_from_cstr(get_arg(1));
    str cmd = str_from_cstr(get_arg(2));

    if str_equal(cmd, "clip") {
        serve_clipboard(str_from_cstr(get_arg(3)), numarg(4));
        return 0;
    }
    if str_equal(cmd, "readclip") {
        read_clipboard();
        return 0;
    }

    Window win = find_window(XDefaultRootWindow(g_d), title, 0);
    if win == 0 {
        print("window not found\n");
        return 1;
    }
    if str_equal(cmd, "title") {
        print_title(win);
        return 0;
    }
    if str_equal(cmd, "focus") {
        Window f = 0;
        i32 rev = 0;
        ignore XGetInputFocus(g_d, &f, &rev);
        print("target 0x{} focus 0x{} (before)\n", win, f);
        ignore XRaiseWindow(g_d, win);
        ignore XSetInputFocus(g_d, win, RevertToParent, 0);
        ignore XSync(g_d, 0);
        thread_sleep(300);
        ignore XGetInputFocus(g_d, &f, &rev);
        print("target 0x{} focus 0x{} (after)\n", win, f);
        return 0;
    }
    ignore XRaiseWindow(g_d, win);
    ignore XSetInputFocus(g_d, win, RevertToParent, 0);
    ignore XSync(g_d, 0);
    thread_sleep(150);
    if str_equal(cmd, "ctrl") {
        str l = str_from_cstr(get_arg(3));
        if l.len > 0 { send_key(win, cast(u64, l.data[0]), ControlMask); }
        return 0;
    }
    if str_equal(cmd, "key") {
        send_key(win, cast(u64, numarg(3)), 0);
        return 0;
    }
    if str_equal(cmd, "click") {
        send_click(win, numarg(3), numarg(4));
        return 0;
    }
    if str_equal(cmd, "utf8") {
        send_unmapped(win, cast(u64, numarg(3)));
        return 0;
    }
    print("commands: title | ctrl <letter> | key <keysym> | clip <text> <ms> | readclip\n");
    return 1;
}
