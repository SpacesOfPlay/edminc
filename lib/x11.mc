// x11.mc - Linux platform surface: Xlib/GLX declarations, shared
// window state, and the plat_* services from plat.mc. The driver is
// plat_x11.mc.
//
// The types and externs are declared here rather than imported: the
// toolchain's ext_x11 leaves the Xlib types to its consumer and
// carries its own copy of the GL_* constants, which collide with
// ext_gl (the GL entry points gpu_gl needs).

type XID = u64;
type Window = XID;
type Drawable = XID;
type Pixmap = XID;
type Cursor = XID;
type Colormap = XID;
type Atom = XID;
type KeySym = XID;
type VisualID = u64;
type Time = u64;
type Bool32 = i32;          // Xlib's Bool
type GLXDrawable = XID;

// opaque handles; Xlib only ever hands back pointers to these
struct XDisplay { i32 _opaque; }
struct XVisual { i32 _opaque; }
struct XScreen { i32 _opaque; }
struct GLXContextRec { i32 _opaque; }
struct XIMRec { i32 _opaque; }
struct XICRec { i32 _opaque; }
struct GLXFBConfigRec { i32 _opaque; }

type Display = XDisplay;
type Visual = XVisual;
type Screen = XScreen;
type GLXContext = GLXContextRec*;
type XIM = XIMRec*;
type XIC = XICRec*;
type GLXFBConfig = GLXFBConfigRec*;

struct XVisualInfo {
    Visual* visual;
    VisualID visualid;
    i32 screen;
    i32 depth;
    i32 class;
    u64 red_mask;
    u64 green_mask;
    u64 blue_mask;
    i32 colormap_size;
    i32 bits_per_rgb;
}

struct XSetWindowAttributes {
    Pixmap background_pixmap;
    u64 background_pixel;
    Pixmap border_pixmap;
    u64 border_pixel;
    i32 bit_gravity;
    i32 win_gravity;
    i32 backing_store;
    u64 backing_planes;
    u64 backing_pixel;
    Bool32 save_under;
    i64 event_mask;
    i64 do_not_propagate_mask;
    Bool32 override_redirect;
    Colormap colormap;
    Cursor cursor;
}

// WM_NORMAL_HINTS; the aspect pairs are flattened
struct XSizeHints {
    i64 flags;
    i32 x;
    i32 y;
    i32 width;
    i32 height;
    i32 min_width;
    i32 min_height;
    i32 max_width;
    i32 max_height;
    i32 width_inc;
    i32 height_inc;
    i32 min_aspect_x;
    i32 min_aspect_y;
    i32 max_aspect_x;
    i32 max_aspect_y;
    i32 base_width;
    i32 base_height;
    i32 win_gravity;
}

const i64 USPosition = 1 << 0;
const i64 USSize = 1 << 1;

struct XAnyEvent {
    i32 type;
    u64 serial;
    Bool32 send_event;
    Display* display;
    Window window;
}

struct XKeyEvent {
    i32 type;
    u64 serial;
    Bool32 send_event;
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
    Bool32 same_screen;
}

struct XButtonEvent {
    i32 type;
    u64 serial;
    Bool32 send_event;
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
    Bool32 same_screen;
}

struct XMotionEvent {
    i32 type;
    u64 serial;
    Bool32 send_event;
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
    u8 is_hint;
    Bool32 same_screen;
}

struct XExposeEvent {
    i32 type;
    u64 serial;
    Bool32 send_event;
    Display* display;
    Window window;
    i32 x;
    i32 y;
    i32 width;
    i32 height;
    i32 count;
}

struct XConfigureEvent {
    i32 type;
    u64 serial;
    Bool32 send_event;
    Display* display;
    Window event;
    Window window;
    i32 x;
    i32 y;
    i32 width;
    i32 height;
    i32 border_width;
    Window above;
    Bool32 override_redirect;
}

struct XClientMessageEvent {
    i32 type;
    u64 serial;
    Bool32 send_event;
    Display* display;
    Window window;
    Atom message_type;
    i32 format;
    unsafe_union {
        u8[20] b;
        i16[10] s;
        i64[5] l;
    } data;
}

struct XFocusChangeEvent {
    i32 type;
    u64 serial;
    Bool32 send_event;
    Display* display;
    Window window;
    i32 mode;
    i32 detail;
}

struct XPropertyEvent {
    i32 type;
    u64 serial;
    Bool32 send_event;
    Display* display;
    Window window;
    Atom atom;
    Time time;
    i32 state;
}

struct XSelectionEvent {
    i32 type;
    u64 serial;
    Bool32 send_event;
    Display* display;
    Window requestor;
    Atom selection;
    Atom target;
    Atom property;
    Time time;
}

struct XSelectionRequestEvent {
    i32 type;
    u64 serial;
    Bool32 send_event;
    Display* display;
    Window owner;
    Window requestor;
    Atom selection;
    Atom target;
    Atom property;
    Time time;
}

unsafe_union XEvent {
    i32 type;
    XAnyEvent xany;
    XKeyEvent xkey;
    XButtonEvent xbutton;
    XMotionEvent xmotion;
    XExposeEvent xexpose;
    XConfigureEvent xconfigure;
    XClientMessageEvent xclient;
    XFocusChangeEvent xfocus;
    XPropertyEvent xproperty;
    XSelectionEvent xselection;
    XSelectionRequestEvent xselectionrequest;
    i64[24] pad;
}

// RandR 1.5 monitor info. Verified layout: 56 bytes, and the
// geometry read back matches `xrandr --listmonitors`.
struct XRRMonitorInfo {
    Atom name;
    Bool32 primary;
    Bool32 automatic;
    i32 noutput;
    i32 x;
    i32 y;
    i32 width;
    i32 height;
    i32 mwidth;
    i32 mheight;
    void* outputs;
}

struct XrmValue {
    u32 size;
    u8* addr;
}

struct pollfd {
    i32 fd;
    i16 events;
    i16 revents;
}

struct timespec {
    i64 tv_sec;
    i64 tv_nsec;
}

// --- constants -------------------------------------------------------

const i32 KeyPress = 2;
const i32 KeyRelease = 3;
const i32 ButtonPress = 4;
const i32 ButtonRelease = 5;
const i32 MotionNotify = 6;
const i32 LeaveNotify = 8;
const i32 FocusIn = 9;
const i32 FocusOut = 10;
const i32 Expose = 12;
const i32 ConfigureNotify = 22;
const i32 PropertyNotify = 28;
const i32 SelectionClear = 29;
const i32 SelectionRequest = 30;
const i32 SelectionNotify = 31;
const i32 ClientMessage = 33;

const i64 KeyPressMask = 1 << 0;
const i64 KeyReleaseMask = 1 << 1;
const i64 ButtonPressMask = 1 << 2;
const i64 ButtonReleaseMask = 1 << 3;
const i64 LeaveWindowMask = 1 << 5;
const i64 PointerMotionMask = 1 << 6;
const i64 ExposureMask = 1 << 15;
const i64 StructureNotifyMask = 1 << 17;
const i64 FocusChangeMask = 1 << 21;
const i64 PropertyChangeMask = 1 << 22;

const u64 CWBorderPixel = 1 << 3;
const u64 CWEventMask = 1 << 11;
const u64 CWColormap = 1 << 13;

const u32 ShiftMask = 1 << 0;
const u32 ControlMask = 1 << 2;
const u32 Mod1Mask = 1 << 3;    // Alt
const u32 Mod4Mask = 1 << 6;    // Super

const u32 Button1 = 1;
const u32 Button2 = 2;
const u32 Button3 = 3;
const u32 Button4 = 4;          // wheel up
const u32 Button5 = 5;          // wheel down

const i32 InputOutput = 1;
const i32 AllocNone = 0;
const i32 PropModeReplace = 0;
const i32 PropertyNewValue = 0;
const Time CurrentTime = 0;
// XIM input styles and Xutf8LookupString status values
const i64 XIMPreeditNothing = 0x0008;
const i64 XIMStatusNothing = 0x0400;
const i32 XLookupNone = 1;
const i32 XLookupChars = 2;
const i32 LC_ALL = 6;

// modifier keysyms, either side
const i64 XK_Shift_L = 0xFFE1;
const i64 XK_Shift_R = 0xFFE2;
const i64 XK_Control_L = 0xFFE3;
const i64 XK_Control_R = 0xFFE4;
const i64 XK_Alt_L = 0xFFE9;
const i64 XK_Alt_R = 0xFFEA;
const i64 XK_Super_L = 0xFFEB;
const i64 XK_Super_R = 0xFFEC;

const i32 XC_hand2 = 60;
const i32 XC_left_ptr = 68;
const i32 XC_xterm = 152;
const i32 XC_sb_h_double_arrow = 108;
const i32 XC_sb_v_double_arrow = 116;
const i32 XC_top_left_corner = 134;
const i32 XC_top_right_corner = 136;
const i32 XC_bottom_left_corner = 12;
const i32 XC_bottom_right_corner = 14;

// _NET_WM_MOVERESIZE directions: the window manager takes over the
// drag, so moving and resizing an undecorated window still snaps and
// tiles the way a decorated one does.
const i64 NET_MOVERESIZE_TOPLEFT = 0;
const i64 NET_MOVERESIZE_TOP = 1;
const i64 NET_MOVERESIZE_TOPRIGHT = 2;
const i64 NET_MOVERESIZE_RIGHT = 3;
const i64 NET_MOVERESIZE_BOTTOMRIGHT = 4;
const i64 NET_MOVERESIZE_BOTTOM = 5;
const i64 NET_MOVERESIZE_BOTTOMLEFT = 6;
const i64 NET_MOVERESIZE_LEFT = 7;
const i64 NET_MOVERESIZE_MOVE = 8;

const i64 NET_WM_STATE_REMOVE = 0;
const i64 NET_WM_STATE_ADD = 1;
const i64 NET_WM_STATE_TOGGLE = 2;

const i64 SubstructureNotifyMask = 1 << 19;
const i64 SubstructureRedirectMask = 1 << 20;

// MWM_HINTS_DECORATIONS; the rest of the Motif hint struct is unused
const u64 MWM_HINTS_DECORATIONS = 2;

const i32 CLOCK_MONOTONIC = 1;
const i16 POLLIN = 1;

const i32 GLX_RED_SIZE = 8;
const i32 GLX_GREEN_SIZE = 9;
const i32 GLX_BLUE_SIZE = 10;
const i32 GLX_ALPHA_SIZE = 11;
const i32 GLX_DOUBLEBUFFER = 5;
const i32 GLX_RENDER_TYPE = 0x8011;
const i32 GLX_RGBA_BIT = 1;
const i32 GLX_DRAWABLE_TYPE = 0x8010;
const i32 GLX_WINDOW_BIT = 1;
const i32 GLX_X_RENDERABLE = 0x8012;
const i32 GLX_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
const i32 GLX_CONTEXT_MINOR_VERSION_ARB = 0x2092;
const i32 GLX_CONTEXT_PROFILE_MASK_ARB = 0x9126;
const i32 GLX_CONTEXT_CORE_PROFILE_BIT_ARB = 1;

// --- externs ---------------------------------------------------------

extern "libX11.so.6" {
    Display* XOpenDisplay(u8* name);
    i32 XCloseDisplay(Display* dpy);
    i32 XDefaultScreen(Display* dpy);
    Window XDefaultRootWindow(Display* dpy);
    i32 XConnectionNumber(Display* dpy);
    Window XCreateWindow(Display* dpy, Window parent, i32 x, i32 y, u32 w, u32 h, u32 border_w, i32 depth, u32 class, Visual* visual, u64 valuemask, XSetWindowAttributes* attrs);
    i32 XDestroyWindow(Display* dpy, Window w);
    i32 XMapWindow(Display* dpy, Window w);
    i32 XFlush(Display* dpy);
    i32 XPending(Display* dpy);
    i32 XNextEvent(Display* dpy, XEvent* ev);
    Colormap XCreateColormap(Display* dpy, Window w, Visual* visual, i32 alloc);
    Atom XInternAtom(Display* dpy, u8* name, i32 only_if_exists);
    i32 XSetWMProtocols(Display* dpy, Window w, Atom* protocols, i32 count);
    i32 XChangeProperty(Display* dpy, Window w, Atom property, Atom type, i32 format, i32 mode, u8* data, i32 nelements);
    i32 XFree(void* data);
    i32 XLookupString(XKeyEvent* ev, u8* buf, i32 nbytes, KeySym* keysym, void* status);
    KeySym XLookupKeysym(XKeyEvent* ev, i32 index);
    Cursor XCreateFontCursor(Display* dpy, u32 shape);
    i32 XDefineCursor(Display* dpy, Window w, Cursor c);
    u8* XResourceManagerString(Display* dpy);
    void XrmInitialize();
    void* XrmGetStringDatabase(u8* data);
    i32 XrmGetResource(void* db, u8* name, u8* class, u8** type, void* value);
    void XrmDestroyDatabase(void* db);
    i32 XkbSetDetectableAutoRepeat(Display* dpy, i32 detectable, i32* supported);
    i32 XIconifyWindow(Display* dpy, Window w, i32 screen);
    i32 XUngrabPointer(Display* dpy, Time t);
    i32 XInitThreads();
    u8* XGetAtomName(Display* dpy, Atom atom);
    i32 XSetSelectionOwner(Display* dpy, Atom selection, Window owner, Time t);
    Window XGetSelectionOwner(Display* dpy, Atom selection);
    i32 XConvertSelection(Display* dpy, Atom selection, Atom target, Atom property, Window requestor, Time t);
    i32 XSendEvent(Display* dpy, Window w, i32 propagate, i64 event_mask, XEvent* ev);
    i32 XCheckTypedWindowEvent(Display* dpy, Window w, i32 type, XEvent* ev);
    i32 XGetWindowProperty(Display* dpy, Window w, Atom property, i64 offset, i64 length, i32 delete, Atom req_type, Atom* actual_type, i32* actual_format, u64* nitems, u64* bytes_after, u8** prop);
    i32 XDeleteProperty(Display* dpy, Window w, Atom property);
    i32 XTranslateCoordinates(Display* dpy, Window src, Window dst, i32 sx, i32 sy, i32* dx, i32* dy, Window* child);
    XIM XOpenIM(Display* dpy, void* db, u8* res_name, u8* res_class);
    i32 XCloseIM(XIM im);
    void XSetICFocus(XIC ic);
    void XUnsetICFocus(XIC ic);
    i32 XFilterEvent(XEvent* ev, Window w);
    i32 Xutf8LookupString(XIC ic, XKeyEvent* ev, u8* buf, i32 nbytes, KeySym* keysym, i32* status);
    u8* XSetLocaleModifiers(u8* modifiers);
    i32 XSupportsLocale();
    void XSetWMNormalHints(Display* dpy, Window w, XSizeHints* hints);
    i32 XMoveResizeWindow(Display* dpy, Window w, i32 x, i32 y, u32 width, u32 height);
}

// XCreateIC is variadic (NULL-terminated name/value pairs). Declared
// at the one shape we call it with: three pairs and the terminator.
// Integer and pointer arguments follow the same calling convention
// either way.
private extern "libX11.so.6" {
    XIC XCreateIC(XIM im, u8* n1, i64 v1, u8* n2, Window v2, u8* n3, Window v3, void* end);
}

private extern "libc.so.6" {
    u8* setlocale(i32 category, u8* locale);
}

extern "libXrandr.so.2" {
    XRRMonitorInfo* XRRGetMonitors(Display* dpy, Window w, i32 get_active, i32* nmonitors);
    void XRRFreeMonitors(XRRMonitorInfo* monitors);
}

// Xlib loads the same library to theme the font cursors
extern "libXcursor.so.1" {
    Bool32 XcursorSetDefaultSize(Display* dpy, i32 size);
}

extern "libGL.so.1" {
    GLXFBConfig* glXChooseFBConfig(Display* dpy, i32 screen, i32* attribs, i32* nitems);
    XVisualInfo* glXGetVisualFromFBConfig(Display* dpy, GLXFBConfig cfg);
    i32 glXMakeCurrent(Display* dpy, GLXDrawable d, GLXContext ctx);
    void glXSwapBuffers(Display* dpy, GLXDrawable d);
    void* glXGetProcAddressARB(u8* name);
}

extern "libc.so.6" {
    i32 poll(pollfd* fds, u64 nfds, i32 timeout);
    i32 clock_gettime(i32 clk, timespec* tp);
    u8* getcwd(u8* buf, u64 size);
    i32 pipe(i32* fds);
}

// --- shared window state ---------------------------------------------

// The one display, window, and GL drawable. Portable code reaches
// them through the plat_* services only.
Display* g_dpy = null;
Window g_win = 0;
i32 g_screen = 0;

Atom g_atom_wm_delete = 0;
Atom g_atom_wm_protocols = 0;
Atom g_atom_net_wm_name = 0;
Atom g_atom_utf8 = 0;
Atom g_atom_clipboard = 0;
Atom g_atom_targets = 0;
Atom g_atom_incr = 0;
Atom g_atom_paste = 0;      // the property a paste is delivered into
Atom g_atom_motif_hints = 0;
Atom g_atom_moveresize = 0;
Atom g_atom_net_wm_state = 0;
Atom g_atom_max_horz = 0;
Atom g_atom_max_vert = 0;

const Atom XA_STRING = 31;
const Atom XA_ATOM = 4;
const Atom XA_WINDOW = 33;
const Atom XA_WM_NAME = 39;

// The loop renders once per burst when this is set (plat_damage),
// and blocks in poll() when it is not.
bool x11_damaged = false;
bool x11_running = true;

// --- services --------------------------------------------------------

void plat_damage() {
    x11_damaged = true;
}

// one window here
void plat_damage_window(i32 win) {
    x11_damaged = true;
}

i64 plat_time_us() {
    timespec ts;
    ignore clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

// Timers are repeating and owned by the loop: poll()'s timeout is the
// nearest deadline, and -1 when the table is empty, so an idle editor
// makes no wakeups at all.
private const i32 X11_MAX_TIMERS = 16;

private struct X11Timer {
    i32 id;
    bool armed;
    i64 period_us;
    i64 due_us;
}

private X11Timer[X11_MAX_TIMERS] x11_timers;

void plat_set_timer(i32 id, i32 ms) {
    plat_kill_timer(id);
    for i32 i = 0; i < X11_MAX_TIMERS; i++ {
        if !x11_timers[i].armed {
            x11_timers[i].id = id;
            x11_timers[i].armed = true;
            x11_timers[i].period_us = cast(i64, ms) * 1000;
            x11_timers[i].due_us = plat_time_us() + x11_timers[i].period_us;
            return;
        }
    }
}

void plat_kill_timer(i32 id) {
    for i32 i = 0; i < X11_MAX_TIMERS; i++ {
        if x11_timers[i].armed && x11_timers[i].id == id {
            x11_timers[i].armed = false;
        }
    }
}

// milliseconds until the nearest deadline, -1 when nothing is armed
i32 x11_timer_timeout() {
    i64 best = -1;
    i64 now = plat_time_us();
    for i32 i = 0; i < X11_MAX_TIMERS; i++ {
        if !x11_timers[i].armed { continue; }
        i64 d = x11_timers[i].due_us - now;
        if d < 0 { d = 0; }
        if best < 0 || d < best { best = d; }
    }
    if best < 0 { return -1; }
    return cast(i32, (best + 999) / 1000);
}

// fire every timer whose deadline has passed
void x11_timers_fire() {
    i64 now = plat_time_us();
    for i32 i = 0; i < X11_MAX_TIMERS; i++ {
        if !x11_timers[i].armed { continue; }
        if x11_timers[i].due_us > now { continue; }
        x11_timers[i].due_us = now + x11_timers[i].period_us;
        if !play_timer(x11_timers[i].id) { app_timer(x11_timers[i].id); }
    }
}

// The title is UTF-8; _NET_WM_NAME is the property modern window
// managers read, WM_NAME the pre-UTF-8 fallback.
void plat_set_title(str s) {
    if g_dpy == null || g_win == 0 { return; }
    ignore XChangeProperty(g_dpy, g_win, g_atom_net_wm_name, g_atom_utf8, 8,
        PropModeReplace, s.data, s.len);
    ignore XChangeProperty(g_dpy, g_win, XA_WM_NAME, g_atom_utf8, 8,
        PropModeReplace, s.data, s.len);
    ignore XFlush(g_dpy);
}

void plat_quit() {
    x11_running = false;
}

i32 plat_cwd(u8* buf, i32 cap) {
    if getcwd(buf, cast(u64, cap)) == null { return 0; }
    i32 n = 0;
    while n < cap && buf[n] != 0 { n++; }
    return n;
}

// Worker wake: a self-pipe in the loop's poll() set. Writing one byte
// is async-signal-safe and thread-safe, which XSendEvent on the main
// display connection is not.
i32[2] x11_wake_fd = { -1, -1 };

void plat_wake() {
    if x11_wake_fd[1] < 0 { return; }
    u8 b = 1;
    ignore write(cast(i64, x11_wake_fd[1]), &b, 1);
}

// --- input method ----------------------------------------------------
// Text reaches the core as committed codepoints. XIM at the
// committed-text level gives dead keys and IME commits; the
// composition is drawn by the input method in its own window
// (XIMPreeditNothing), not inline, which matches the scope the other
// platforms ship. When no input method is reachable the driver falls
// back to XLookupString, which is latin-1 only.
XIM g_xim = null;
XIC g_xic = null;

bool x11_im_init() {
    ignore setlocale(LC_ALL, "");
    if XSupportsLocale() == 0 { return false; }
    ignore XSetLocaleModifiers("");
    g_xim = XOpenIM(g_dpy, null, null, null);
    if g_xim == null { return false; }
    g_xic = XCreateIC(g_xim,
        "inputStyle", XIMPreeditNothing | XIMStatusNothing,
        "clientWindow", g_win,
        "focusWindow", g_win,
        null);
    if g_xic == null {
        ignore XCloseIM(g_xim);
        g_xim = null;
        return false;
    }
    XSetICFocus(g_xic);
    return true;
}

bool x11_wake_init() {
    if pipe(&x11_wake_fd[0]) != 0 {
        x11_wake_fd[0] = -1;
        x11_wake_fd[1] = -1;
        return false;
    }
    return true;
}

void x11_wake_drain() {
    noinit u8[64] buf;
    while read(cast(i64, x11_wake_fd[0]), &buf[0], 64) == 64 {}
}

// --- child process (the LSP server) ----------------------------------
// fork + execvp with both stdio ends piped, the same POSIX shape the
// macOS surface uses. Only async-signal-safe calls between fork and
// exec. The names are aliased so they do not collide with the
// builtins of the same name.

private extern "libc.so.6" {
    i32 mc_pipe(i32* fds) from "pipe";
    i32 mc_fork() from "fork";
    i32 mc_dup2(i32 a, i32 b) from "dup2";
    i32 mc_execvp(u8* file, u8** argv) from "execvp";
    i32 mc_close(i32 fd) from "close";
    i64 mc_read(i32 fd, void* buf, i64 n) from "read";
    i64 mc_write(i32 fd, void* buf, i64 n) from "write";
    i32 mc_kill(i32 pid, i32 sig) from "kill";
    i32 mc_waitpid(i32 pid, i32* st, i32 opts) from "waitpid";
    void mc_exit(i32 code) from "_exit";
}

// a slot is free when its pid is 0
private i32[PLAT_CHILDREN] child_pid;
private i32[PLAT_CHILDREN] child_in;    // write end: the child's stdin
private i32[PLAT_CHILDREN] child_out;   // read end: the child's stdout

bool plat_child_spawn(i32 k, str* argv, i32 argc) {
    if k < 0 || k >= PLAT_CHILDREN || child_pid[k] > 0 { return false; }
    noinit i32[2] pin;
    noinit i32[2] pout;
    if mc_pipe(&pin[0]) != 0 { return false; }
    if mc_pipe(&pout[0]) != 0 {
        ignore mc_close(pin[0]);
        ignore mc_close(pin[1]);
        return false;
    }
    // NUL-terminated argv copies for execvp
    u8** av = alloc<u8*>(argc + 1);
    for i32 i = 0; i < argc; i++ {
        u8* a = alloc<u8>(argv[i].len + 1);
        memcpy(a, argv[i].data, argv[i].len);
        a[argv[i].len] = 0;
        av[i] = a;
    }
    av[argc] = null;
    i32 pid = mc_fork();
    if pid == 0 {
        ignore mc_dup2(pin[0], 0);
        ignore mc_dup2(pout[1], 1);
        // Everything else goes, not just this pipe: a fork inherits
        // every descriptor, so the other spawn's pipe would be held
        // open by this child and its reader would never see end of
        // file. That froze the editor on Windows, where the same
        // hazard is handle inheritance.
        for i32 fd = 3; fd < 256; fd++ { ignore mc_close(fd); }
        ignore mc_execvp(av[0], av);
        mc_exit(127);
    }
    ignore mc_close(pin[0]);
    ignore mc_close(pout[1]);
    for i32 i = 0; i < argc; i++ { free(av[i]); }
    free(av);
    if pid < 0 {
        ignore mc_close(pin[1]);
        ignore mc_close(pout[0]);
        return false;
    }
    child_pid[k] = pid;
    child_in[k] = pin[1];
    child_out[k] = pout[0];
    return true;
}

// Run a program to completion and hand back its stdout. Separate from
// the children above because the language servers own those for the
// whole session; this is the one-shot git needs.
u8* plat_run_capture(str* argv, i32 argc, i64* out_len, i32* out_code) {
    *out_len = 0;
    *out_code = -1;
    noinit i32[2] pout;
    if mc_pipe(&pout[0]) != 0 { return null; }
    u8** av = alloc<u8*>(argc + 1);
    for i32 i = 0; i < argc; i++ {
        u8* a = alloc<u8>(argv[i].len + 1);
        memcpy(a, argv[i].data, argv[i].len);
        a[argv[i].len] = 0;
        av[i] = a;
    }
    av[argc] = null;
    i32 pid = mc_fork();
    if pid == 0 {
        ignore mc_dup2(pout[1], 1);
        // stderr rides the same pipe, as on Windows and macOS: the build
        // panel sees the compiler's diagnostics, and git's "fatal" for a
        // path HEAD lacks stays in the discarded capture
        ignore mc_dup2(pout[1], 2);
        // see plat_child_spawn: every inherited descriptor goes, or a
        // pipe belonging to another spawn stays open in this child
        for i32 fd = 3; fd < 256; fd++ { ignore mc_close(fd); }
        ignore mc_execvp(av[0], av);
        mc_exit(127);
    }
    ignore mc_close(pout[1]);
    for i32 i = 0; i < argc; i++ { free(av[i]); }
    free(av);
    if pid < 0 {
        ignore mc_close(pout[0]);
        return null;
    }
    i64 cap = 65536;
    u8* buf = alloc<u8>(cap);
    i64 n = 0;
    while true {
        if n == cap {
            i64 ncap = cap * 2;
            u8* nb = alloc<u8>(ncap);
            memcpy(nb, buf, n);
            free(buf);
            buf = nb;
            cap = ncap;
        }
        i64 got = mc_read(pout[0], buf + n, cap - n);
        if got <= 0 { break; }
        n += got;
    }
    ignore mc_close(pout[0]);
    i32 st = 0;
    ignore mc_waitpid(pid, &st, 0);
    // the low byte holds the signal, the next one the exit status
    *out_code = (st >> 8) & 0xFF;
    *out_len = n;
    return buf;
}

i64 plat_child_write(i32 k, u8* p, i64 n) {
    if k < 0 || k >= PLAT_CHILDREN || child_pid[k] <= 0 { return -1; }
    i64 done = 0;
    while done < n {
        i64 w = mc_write(child_in[k], p + done, n - done);
        if w <= 0 { return done; }
        done += w;
    }
    return done;
}

i64 plat_child_read(i32 k, u8* p, i64 cap) {
    if k < 0 || k >= PLAT_CHILDREN || child_pid[k] <= 0 { return -1; }
    return mc_read(child_out[k], p, cap);
}

void plat_child_kill(i32 k) {
    if k < 0 || k >= PLAT_CHILDREN || child_pid[k] <= 0 { return; }
    ignore mc_close(child_in[k]);
    ignore mc_close(child_out[k]);
    ignore mc_kill(child_pid[k], 15);   // SIGTERM
    i32 st = 0;
    ignore mc_waitpid(child_pid[k], &st, 0);
    child_pid[k] = 0;
    child_in[k] = -1;
    child_out[k] = -1;
}

// --- pseudo-terminal (the terminal pane) -----------------------------
// The macOS layer's shape (lib/mac.mc), with glibc's names and numbers:
// posix_openpt for the master, a fork whose child becomes its own
// session, opens the slave as its controlling terminal, sizes it, and
// execs the login shell; the parent keeps the master.

private extern "libc.so.6" {
    i32 mt_openpt(i32 flags) from "posix_openpt";
    i32 mt_grantpt(i32 fd) from "grantpt";
    i32 mt_unlockpt(i32 fd) from "unlockpt";
    u8* mt_ptsname(i32 fd) from "ptsname";
    i32 mt_open(u8* path, i32 flags, ...) from "open";
    i32 mt_setsid() from "setsid";
    i32 mt_ioctl(i32 fd, u64 req, ...) from "ioctl";
    i32 mt_setenv(u8* name, u8* value, i32 overwrite) from "setenv";
    i32 mt_unsetenv(u8* name) from "unsetenv";
    u8* mt_getenv(u8* name) from "getenv";
}

private const i32 MT_O_RDWR = 0x0002;
private const i32 MT_O_NOCTTY = 0x0100;
private const i32 MT_O_CLOEXEC = 0x80000;
private const u64 MT_TIOCSWINSZ = 0x5414;
private const u64 MT_TIOCSCTTY = 0x540E;
private const i32 MT_SIGHUP = 1;
private const i32 MT_WNOHANG = 1;

private struct LinuxWinsize {
    u16 ws_row;
    u16 ws_col;
    u16 ws_xpixel;
    u16 ws_ypixel;
}

private struct LinuxTerm {
    i32 master;
    i32 pid;
    i32 code;
    bool used;
}
private LinuxTerm[TERM_MAX] g_lterm;

private u8* mt_shell_path() {
    u8* s = mt_getenv("EDMINC_SHELL");
    if s != null && s[0] != 0 { return s; }
    s = mt_getenv("SHELL");
    if s != null && s[0] != 0 { return s; }
    return "/bin/bash";
}

// argv as one shell command, each word in single quotes (a quote
// inside becomes '\'' ), NUL-terminated; the caller frees
private u8* mt_shell_command(str* argv, i32 argc) {
    i64 cap = 8;
    for i32 i = 0; i < argc; i++ { cap += argv[i].len * 4 + 4; }
    u8* out = alloc<u8>(cap);
    i64 o = 0;
    for i32 i = 0; i < argc; i++ {
        if i > 0 { out[o] = ' '; o++; }
        out[o] = 39;
        o++;
        for i64 k = 0; k < argv[i].len; k++ {
            u8 c = argv[i].data[k];
            if c == 39 {
                out[o] = 39; out[o + 1] = 92; out[o + 2] = 39; out[o + 3] = 39;
                o += 4;
            } else {
                out[o] = c;
                o++;
            }
        }
        out[o] = 39;
        o++;
    }
    out[o] = 0;
    return out;
}

i32 plat_term_spawn(i32 cols, i32 rows, str* cargv, i32 cargc, bool under) {
    i32 h = -1;
    for i32 i = 0; i < TERM_MAX; i++ {
        if !g_lterm[i].used {
            h = i;
            break;
        }
    }
    if h < 0 { return -1; }
    i32 master = mt_openpt(MT_O_RDWR | MT_O_NOCTTY | MT_O_CLOEXEC);
    if master < 0 { return -1; }
    if mt_grantpt(master) != 0 || mt_unlockpt(master) != 0 {
        ignore mc_close(master);
        return -1;
    }
    u8* slave_name = mt_ptsname(master);
    if slave_name == null {
        ignore mc_close(master);
        return -1;
    }
    noinit u8[256] sname;
    i32 sn = 0;
    while sn < 255 && slave_name[sn] != 0 {
        sname[sn] = slave_name[sn];
        sn++;
    }
    sname[sn] = 0;
    LinuxWinsize ws;
    ws.ws_row = cast(u16, rows);
    ws.ws_col = cast(u16, cols);
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    u8* shell = mt_shell_path();
    // a command runs under the same login shell with -c, so the user's
    // PATH applies
    u8* cmd = null;
    if cargc > 0 { cmd = mt_shell_command(cargv, cargc); }
    u8*[5] argv;
    argv[0] = shell;
    argv[1] = "-l";
    argv[2] = null;
    if cmd != null {
        argv[2] = "-c";
        argv[3] = cmd;
        argv[4] = null;
    }
    i32 pid = mc_fork();
    if pid == 0 {
        ignore mt_setsid();
        i32 slave = mt_open(&sname[0], MT_O_RDWR);
        if slave < 0 { mc_exit(127); }
        ignore mt_ioctl(slave, MT_TIOCSCTTY, 0);
        ignore mt_ioctl(slave, MT_TIOCSWINSZ, &ws);
        ignore mc_dup2(slave, 0);
        ignore mc_dup2(slave, 1);
        ignore mc_dup2(slave, 2);
        for i32 fd = 3; fd < 256; fd++ { ignore mc_close(fd); }
        ignore mt_setenv("TERM", "xterm-256color", 1);
        ignore mt_setenv("COLORTERM", "truecolor", 1);
        // the child is in this terminal, not the one the editor was
        // launched from: the launching terminal's session variables
        // would make the shell restore that session here
        ignore mt_setenv("TERM_PROGRAM", "edminc", 1);
        ignore mt_unsetenv("TERM_PROGRAM_VERSION");
        ignore mt_unsetenv("TERM_SESSION_ID");
        ignore mc_execvp(shell, &argv[0]);
        mc_exit(127);
    }
    if cmd != null { free(cmd); }
    if pid < 0 {
        ignore mc_close(master);
        return -1;
    }
    g_lterm[h].master = master;
    g_lterm[h].pid = pid;
    g_lterm[h].code = -1;
    g_lterm[h].used = true;
    return h;
}

private bool lt_valid(i32 h) {
    return h >= 0 && h < TERM_MAX && g_lterm[h].used;
}

i64 plat_term_read(i32 h, u8* buf, i64 cap) {
    if !lt_valid(h) || g_lterm[h].master < 0 { return -1; }
    // EIO once the slave has closed: the end of file the reader ends on
    i64 n = mc_read(g_lterm[h].master, buf, cap);
    if n < 0 { return 0; }
    return n;
}

i64 plat_term_write(i32 h, u8* p, i64 n) {
    if !lt_valid(h) || g_lterm[h].master < 0 { return -1; }
    i64 done = 0;
    while done < n {
        i64 w = mc_write(g_lterm[h].master, p + done, n - done);
        if w <= 0 { return done; }
        done += w;
    }
    return done;
}

i32 plat_term_code(i32 h) {
    if !lt_valid(h) { return -1; }
    if g_lterm[h].code >= 0 { return g_lterm[h].code; }
    if g_lterm[h].pid <= 0 { return -1; }
    i32 st = 0;
    i32 r = mc_waitpid(g_lterm[h].pid, &st, MT_WNOHANG);
    if r != g_lterm[h].pid { return -1; }
    g_lterm[h].pid = -1;
    if (st & 0x7F) == 0 { g_lterm[h].code = (st >> 8) & 0xFF; }
    else { g_lterm[h].code = 128 + (st & 0x7F); }
    return g_lterm[h].code;
}

void plat_term_resize(i32 h, i32 cols, i32 rows) {
    if !lt_valid(h) || g_lterm[h].master < 0 { return; }
    LinuxWinsize ws;
    ws.ws_row = cast(u16, rows);
    ws.ws_col = cast(u16, cols);
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    ignore mt_ioctl(g_lterm[h].master, MT_TIOCSWINSZ, &ws);
}

// the hangup ends the shell and closing the master ends the pty, which
// returns the reader's blocking read; the handle stays for the free
void plat_term_kill(i32 h) {
    if !lt_valid(h) { return; }
    if g_lterm[h].pid > 0 { ignore mc_kill(g_lterm[h].pid, MT_SIGHUP); }
    if g_lterm[h].master >= 0 {
        ignore mc_close(g_lterm[h].master);
        g_lterm[h].master = -1;
    }
}

void plat_term_free(i32 h) {
    if h < 0 || h >= TERM_MAX { return; }
    if g_lterm[h].pid > 0 {
        i32 st = 0;
        ignore mc_waitpid(g_lterm[h].pid, &st, 0);
    }
    g_lterm[h].master = -1;
    g_lterm[h].pid = -1;
    g_lterm[h].used = false;
}

// no one terminal to read a scheme from here
u32 plat_term_palette(u32* out, i32 n) { return 0; }

// no file watcher on this platform yet: the editor refreshes on its own
// saves only, and a save still checks the file on disk first
i32 plat_watch_open(str dir) { return -1; }
i64 plat_watch_read(i32 h, u8* buf, i64 cap) { return -1; }
void plat_watch_close(i32 h) {}
void plat_watch_free(i32 h) {}

// --- window frame ----------------------------------------------------

// Ask the window manager not to decorate. The caption is drawn by
// the portable view instead (g_caption_h), as on Windows, where the
// native caption cannot center its title.
void x11_set_undecorated() {
    u64[5] hints;
    hints[0] = MWM_HINTS_DECORATIONS;
    hints[2] = 0;   // no decorations
    ignore XChangeProperty(g_dpy, g_win, g_atom_motif_hints, g_atom_motif_hints,
        32, PropModeReplace, cast(u8*, &hints[0]), 5);
}

private void x11_root_message(Atom type, i64 a, i64 b, i64 c, i64 d, i64 e) {
    XEvent ev;
    ev.xclient.type = ClientMessage;
    ev.xclient.display = g_dpy;
    ev.xclient.window = g_win;
    ev.xclient.message_type = type;
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = a;
    ev.xclient.data.l[1] = b;
    ev.xclient.data.l[2] = c;
    ev.xclient.data.l[3] = d;
    ev.xclient.data.l[4] = e;
    ignore XSendEvent(g_dpy, XDefaultRootWindow(g_dpy), 0,
        SubstructureRedirectMask | SubstructureNotifyMask, &ev);
    ignore XFlush(g_dpy);
}

// Hand the drag to the window manager. The pointer grab from the
// button press has to go first or the manager cannot take it.
void x11_begin_moveresize(i32 x_root, i32 y_root, i64 dir) {
    ignore XUngrabPointer(g_dpy, CurrentTime);
    ignore XFlush(g_dpy);
    x11_root_message(g_atom_moveresize, cast(i64, x_root), cast(i64, y_root), dir, 1, 1);
}

void x11_toggle_maximized() {
    x11_root_message(g_atom_net_wm_state, NET_WM_STATE_TOGGLE,
        cast(i64, g_atom_max_horz), cast(i64, g_atom_max_vert), 1, 0);
}

void x11_set_maximized(bool on) {
    i64 action = NET_WM_STATE_REMOVE;
    if on { action = NET_WM_STATE_ADD; }
    x11_root_message(g_atom_net_wm_state, action,
        cast(i64, g_atom_max_horz), cast(i64, g_atom_max_vert), 1, 0);
}

void x11_minimize() {
    ignore XIconifyWindow(g_dpy, g_win, g_screen);
    ignore XFlush(g_dpy);
}

// True when the manager reports the window maximized both ways,
// through _NET_WM_STATE.
bool x11_read_maximized() {
    Atom type = 0;
    i32 fmt = 0;
    u64 nitems = 0;
    u64 after = 0;
    u8* data = null;
    if XGetWindowProperty(g_dpy, g_win, g_atom_net_wm_state, 0, 64, 0, XA_ATOM,
        &type, &fmt, &nitems, &after, &data) != 0 {
        return false;
    }
    if data == null { return false; }
    bool h = false;
    bool v = false;
    Atom* atoms = cast(Atom*, data);
    for u64 i = 0; i < nitems; i++ {
        if atoms[i] == g_atom_max_horz { h = true; }
        if atoms[i] == g_atom_max_vert { v = true; }
    }
    ignore XFree(cast(void*, data));
    return h && v;
}

// True when the window manager is Weston's X11 manager, as under WSLg.
// It names itself through _NET_SUPPORTING_WM_CHECK and _NET_WM_NAME.
bool x11_wm_is_weston() {
    Window root = XDefaultRootWindow(g_dpy);
    Atom check = XInternAtom(g_dpy, "_NET_SUPPORTING_WM_CHECK", 0);
    Atom type = 0;
    i32 fmt = 0;
    u64 nitems = 0;
    u64 after = 0;
    u8* data = null;
    if XGetWindowProperty(g_dpy, root, check, 0, 1, 0, XA_WINDOW,
        &type, &fmt, &nitems, &after, &data) != 0 || data == null {
        return false;
    }
    Window wm = 0;
    if nitems == 1 { wm = cast(Window*, data)[0]; }
    ignore XFree(cast(void*, data));
    if wm == 0 { return false; }
    data = null;
    if XGetWindowProperty(g_dpy, wm, g_atom_net_wm_name, 0, 16, 0, g_atom_utf8,
        &type, &fmt, &nitems, &after, &data) != 0 || data == null {
        return false;
    }
    bool weston = str_equal(str_from(data, cast(i32, nitems)), "Weston WM");
    ignore XFree(cast(void*, data));
    return weston;
}

// --- clipboard -------------------------------------------------------
// X11 has no clipboard server: whoever owns the CLIPBOARD selection
// answers requests for it from its own event loop, and the content
// dies with the owner unless a clipboard manager saves it. So a copy
// keeps the bytes and takes ownership, the loop serves
// SelectionRequest, and a paste asks the current owner and waits.

private u8* x11_clip = null;      // what we published, if we own it
private i64 x11_clip_len = 0;
private const i32 CLIP_WAIT_MS = 1000;
private const i64 CLIP_CHUNK = 65536;   // in 32-bit units: 256 KB

void plat_clipboard_set(u8* s, i64 n) {
    if g_dpy == null || g_win == 0 || n <= 0 { return; }
    if x11_clip != null { free(x11_clip); }
    x11_clip = alloc<u8>(n);
    memcpy(x11_clip, s, n);
    x11_clip_len = n;
    ignore XSetSelectionOwner(g_dpy, g_atom_clipboard, g_win, CurrentTime);
    ignore XFlush(g_dpy);
}

// Another client took the selection; our copy is no longer the one.
void x11_selection_clear() {
    if x11_clip != null {
        free(x11_clip);
        x11_clip = null;
    }
    x11_clip_len = 0;
}

// Serve one SelectionRequest from the event loop.
void x11_selection_request(XSelectionRequestEvent* rq) {
    XEvent resp;
    resp.xselection.type = SelectionNotify;
    resp.xselection.display = rq.display;
    resp.xselection.requestor = rq.requestor;
    resp.xselection.selection = rq.selection;
    resp.xselection.target = rq.target;
    resp.xselection.time = rq.time;
    resp.xselection.property = rq.property;
    // obsolete clients send property None and mean the target
    if resp.xselection.property == 0 { resp.xselection.property = rq.target; }

    if x11_clip == null {
        resp.xselection.property = 0;
    } else if rq.target == g_atom_targets {
        Atom[4] list = { g_atom_targets, g_atom_utf8, XA_STRING, 0 };
        list[3] = XInternAtom(g_dpy, "TEXT", 0);
        ignore XChangeProperty(g_dpy, rq.requestor, resp.xselection.property,
            XA_ATOM, 32, PropModeReplace, cast(u8*, &list[0]), 4);
    } else if rq.target == g_atom_utf8 || rq.target == XA_STRING
        || rq.target == XInternAtom(g_dpy, "TEXT", 0) {
        ignore XChangeProperty(g_dpy, rq.requestor, resp.xselection.property,
            rq.target, 8, PropModeReplace, x11_clip, cast(i32, x11_clip_len));
    } else {
        resp.xselection.property = 0;   // we do not speak that target
    }
    ignore XSendEvent(g_dpy, rq.requestor, 0, 0, &resp);
    ignore XFlush(g_dpy);
}

// Wait for one event of `kind` on our window, up to a deadline.
// Only that event type is taken from the queue, so nothing else is
// consumed or dispatched while a paste is in flight.
private bool x11_wait_event(i32 kind, XEvent* out) {
    i64 deadline = plat_time_us() + cast(i64, CLIP_WAIT_MS) * 1000;
    while true {
        if XCheckTypedWindowEvent(g_dpy, g_win, kind, out) != 0 { return true; }
        i64 left = deadline - plat_time_us();
        if left <= 0 { return false; }
        pollfd pf;
        pf.fd = XConnectionNumber(g_dpy);
        pf.events = POLLIN;
        ignore XFlush(g_dpy);
        ignore poll(&pf, 1, cast(i32, left / 1000) + 1);
    }
    return false;
}

// Read our paste property, appending to buf. Returns bytes added.
private i64 x11_read_prop(u8** buf, i64 have, Atom* out_type) {
    Atom type = 0;
    i32 fmt = 0;
    u64 nitems = 0;
    u64 after = 0;
    u8* data = null;
    if XGetWindowProperty(g_dpy, g_win, g_atom_paste, 0, CLIP_CHUNK, 0, 0,
        &type, &fmt, &nitems, &after, &data) != 0 {
        return 0;
    }
    *out_type = type;
    if data == null { return 0; }
    i64 n = cast(i64, nitems);
    if fmt != 8 || n <= 0 || type == g_atom_incr {
        ignore XFree(cast(void*, data));
        return 0;
    }
    u8* grown = alloc<u8>(have + n);
    if have > 0 {
        memcpy(grown, *buf, have);
        free(*buf);
    }
    memcpy(grown + have, data, n);
    *buf = grown;
    ignore XFree(cast(void*, data));
    return n;
}

u8* plat_clipboard_get(i64* out_len) {
    *out_len = 0;
    if g_dpy == null || g_win == 0 { return null; }

    // Our own copy: asking the server for it would need the loop to
    // answer our own request, and we are called from inside the loop.
    if x11_clip != null {
        u8* copy = alloc<u8>(x11_clip_len);
        memcpy(copy, x11_clip, x11_clip_len);
        *out_len = x11_clip_len;
        return copy;
    }
    if XGetSelectionOwner(g_dpy, g_atom_clipboard) == 0 { return null; }

    ignore XDeleteProperty(g_dpy, g_win, g_atom_paste);
    ignore XConvertSelection(g_dpy, g_atom_clipboard, g_atom_utf8, g_atom_paste, g_win, CurrentTime);
    ignore XFlush(g_dpy);
    XEvent ev;
    if !x11_wait_event(SelectionNotify, &ev) { return null; }
    if ev.xselection.property == 0 { return null; }   // owner refused UTF8

    u8* buf = null;
    i64 len = 0;
    Atom type = 0;
    len = x11_read_prop(&buf, 0, &type);
    if type == g_atom_incr {
        // large transfer: the owner sends chunks, each announced by a
        // PropertyNotify, and signals the end with an empty one
        ignore XDeleteProperty(g_dpy, g_win, g_atom_paste);
        ignore XFlush(g_dpy);
        while true {
            XEvent pv;
            if !x11_wait_event(PropertyNotify, &pv) { break; }
            if pv.xproperty.atom != g_atom_paste
                || pv.xproperty.state != PropertyNewValue { continue; }
            Atom ct = 0;
            i64 got = x11_read_prop(&buf, len, &ct);
            ignore XDeleteProperty(g_dpy, g_win, g_atom_paste);
            ignore XFlush(g_dpy);
            if got == 0 { break; }
            len += got;
        }
    }
    ignore XDeleteProperty(g_dpy, g_win, g_atom_paste);
    if buf == null || len <= 0 {
        if buf != null { free(buf); }
        return null;
    }
    // the core speaks '\n'; strip CR from cross-platform content
    i64 m = 0;
    for i64 i = 0; i < len; i++ {
        if buf[i] != 13 {
            buf[m] = buf[i];
            m++;
        }
    }
    if m == 0 {
        free(buf);
        return null;
    }
    *out_len = m;
    return buf;
}

// directory listing: the stdlib's, this platform has a file system
DirList plat_dir_list(str dir, bool want_dirs) {
    return dir_list(dir, "", want_dirs);
}

private extern "libc.so.6" {
    i32 chdir(u8* path);
}

bool plat_chdir(str dir) {
    u8* c = str_to_cstr(dir);
    bool ok = chdir(c) == 0;
    free(c);
    return ok;
}

private extern "libc.so.6" {
    i32 mc_rename(u8* src, u8* dst) from "rename";
}

// --- the trash and the file manager ----------------------------------------
// The freedesktop trash: the file moves into Trash/files under
// $XDG_DATA_HOME (~/.local/share by default), and a record of where it
// was and when goes into Trash/info. A file on another file system
// than the home trash cannot be renamed there, and stays.

private extern "libc.so.6" {
    i64 mc_time(i64* t) from "time";
    void* mc_localtime_r(i64* t, u8* tm) from "localtime_r";
    u64 mc_strftime(u8* s, u64 max, u8* fmt, u8* tm) from "strftime";
}

private const i32 TRASH_TM_SIZE = 64;   // covers struct tm on glibc and musl

// the path, percent-encoded as the trash record's Path= wants it
private i32 trash_url_path(str p, u8* out, i32 cap) {
    u8[16] hex = { '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F' };
    i32 n = 0;
    for i32 i = 0; i < p.len; i++ {
        u8 c = p.data[i];
        bool plain = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
            || c == '/' || c == '-' || c == '_' || c == '.' || c == '~';
        if n + 3 >= cap { return -1; }
        if plain {
            out[n] = c;
            n++;
        } else {
            out[n] = '%';
            out[n + 1] = hex[c >> 4];
            out[n + 2] = hex[c & 15];
            n += 3;
        }
    }
    return n;
}

// the trash folder, Trash under the data home; its length
private i32 trash_dir(u8* out, i32 cap) {
    u8* dh = mt_getenv("XDG_DATA_HOME");
    str base = "";
    str tail = "/Trash";
    if dh != null && dh[0] != 0 {
        base = str_from_cstr(dh);
    } else {
        u8* home = mt_getenv("HOME");
        if home == null || home[0] == 0 { return 0; }
        base = str_from_cstr(home);
        tail = "/.local/share/Trash";
    }
    if base.len + tail.len >= cap { return 0; }
    memcpy(out, base.data, base.len);
    memcpy(out + base.len, tail.data, tail.len);
    return base.len + tail.len;
}

bool plat_trash(str path) {
    noinit u8[PATH_MAX] td;
    i32 tn = trash_dir(&td[0], PATH_MAX - 300);
    if tn == 0 { return false; }
    str files = "/files/";
    str info = "/info/";
    memcpy(&td[tn], files.data, files.len);
    ignore dir_create(str_from(&td[0], tn + files.len - 1));
    memcpy(&td[tn], info.data, info.len);
    ignore dir_create(str_from(&td[0], tn + info.len - 1));
    // a name not taken in either folder: the file's own, then name.2, ...
    i32 b = path.len;
    while b > 0 && path.data[b - 1] != '/' { b--; }
    str name = str_from(path.data + b, path.len - b);
    if name.len == 0 || name.len > 200 { return false; }
    noinit u8[PATH_MAX] dst;
    noinit u8[PATH_MAX] rec;
    i32 dn = 0;
    i32 rn = 0;
    for i32 k = 1; k < 1000; k++ {
        noinit u8[16] sfx;
        i32 sn = 0;
        if k > 1 {
            sfx[0] = '.';
            sn = 1 + fmt_i32(&sfx[1], k);
        }
        memcpy(&dst[0], &td[0], tn);
        memcpy(&dst[tn], files.data, files.len);
        dn = tn + files.len;
        memcpy(&dst[dn], name.data, name.len);
        dn += name.len;
        memcpy(&dst[dn], &sfx[0], sn);
        dn += sn;
        memcpy(&rec[0], &td[0], tn);
        memcpy(&rec[tn], info.data, info.len);
        rn = tn + info.len;
        memcpy(&rec[rn], name.data, name.len);
        rn += name.len;
        memcpy(&rec[rn], &sfx[0], sn);
        rn += sn;
        str ext = ".trashinfo";
        memcpy(&rec[rn], ext.data, ext.len);
        rn += ext.len;
        if !path_exists(str_from(&dst[0], dn)) && !path_exists(str_from(&rec[0], rn)) { break; }
    }
    // the record first, as the specification orders it
    noinit u8[PATH_MAX * 3 + 128] body;
    str head = "[Trash Info]\nPath=";
    memcpy(&body[0], head.data, head.len);
    i32 bn = head.len;
    i32 un = trash_url_path(path, &body[bn], PATH_MAX * 3);
    if un < 0 { return false; }
    bn += un;
    str dd = "\nDeletionDate=";
    memcpy(&body[bn], dd.data, dd.len);
    bn += dd.len;
    i64 now = mc_time(null);
    noinit u8[TRASH_TM_SIZE] tm;
    if mc_localtime_r(&now, &tm[0]) == null { return false; }
    bn += cast(i32, mc_strftime(&body[bn], 32, "%Y-%m-%dT%H:%M:%S", &tm[0]));
    body[bn] = '\n';
    bn++;
    str rp = str_from(&rec[0], rn);
    if !file_write(rp, FileData{ &body[0], bn }) { return false; }
    if !plat_file_rename(path, str_from(&dst[0], dn)) {
        ignore file_remove(rp);
        return false;
    }
    return true;
}

// The file manager on the folder holding path, through xdg-open. The
// child forks again and exits at once, so the wait for it is short and
// the file manager is nobody's child here.
bool plat_reveal(str path) {
    i32 b = path.len;
    while b > 0 && path.data[b - 1] != '/' { b--; }
    if b > 1 { b--; }
    return x11_xdg_open(str_from(path.data, b));
}

bool plat_open_url(str url) {
    return x11_xdg_open(url);
}

// xdg-open on arg, in a grandchild so no zombie is left to reap
private bool x11_xdg_open(str arg) {
    u8* dir = str_to_cstr(arg);
    u8* prog = str_to_cstr("xdg-open");
    noinit u8*[3] av;
    av[0] = prog;
    av[1] = dir;
    av[2] = null;
    i32 pid = mc_fork();
    if pid == 0 {
        if mc_fork() == 0 {
            for i32 fd = 3; fd < 256; fd++ { ignore mc_close(fd); }
            ignore mc_execvp(av[0], &av[0]);
            mc_exit(127);
        }
        mc_exit(0);
    }
    if pid > 0 {
        i32 st = 0;
        ignore mc_waitpid(pid, &st, 0);
    }
    free(dir);
    free(prog);
    return pid > 0;
}

// a file or folder to a new name; the caller checks that the target
// does not exist, since rename(2) replaces it
bool plat_file_rename(str src, str dst) {
    u8* cf = str_to_cstr(src);
    u8* ct = str_to_cstr(dst);
    bool ok = mc_rename(cf, ct) == 0;
    free(cf);
    free(ct);
    return ok;
}

private extern "libc.so.6" {
    i64 readlink(u8* path, u8* buf, u64 bufsz);
}

private extern "libc.so.6" {
    i32 mc_execv(u8* path, u8** argv) from "execv";
    i32 mc_fcntl(i32 fd, i32 cmd, i32 arg) from "fcntl";
}
private const i32 MT_F_SETFD = 2;

i32 plat_exe_path(u8* out, i32 cap) {
    noinit u8[PATH_MAX] buf;
    u8* p = str_to_cstr("/proc/self/exe");
    i64 n = readlink(p, &buf[0], cast(u64, PATH_MAX));
    free(p);
    if n <= 0 { return 0; }
    i32 outn = cast(i32, n);
    if outn > cap { outn = cap; }
    memcpy(out, &buf[0], outn);
    return outn;
}

// a fork, the exec in the child, and this process gone, as on macOS;
// the ptys without close-on-exec cross into the child
bool plat_exec_self(str exe, str* argv, i32 argc) {
    // a headless run that restarts hands its dump flags and the
    // injections it has not delivered to the process it starts
    i32 extra = hl_restart_arg_count();
    u8** av = alloc<u8*>(cast(i64, argc + extra + 2));
    av[0] = str_to_cstr(exe);
    for i32 i = 0; i < argc; i++ { av[i + 1] = str_to_cstr(argv[i]); }
    for i32 i = 0; i < extra; i++ { av[argc + 1 + i] = str_to_cstr(hl_restart_arg(i)); }
    av[argc + extra + 1] = null;
    i32 pid = mc_fork();
    if pid == 0 {
        ignore mc_execv(av[0], av);
        mc_exit(127);
    }
    if pid < 0 { return false; }
    mc_exit(0);
    return false;
}

// the detach, as on macOS: a plain launch forks, the child takes a
// session of its own and execs this executable with --no-detach in
// front of the arguments, and this process exits, so the shell gets
// its prompt back and the terminal's Ctrl+C and close do not reach
// the editor; a failed fork stays in the foreground
void x11_detach() {
    noinit u8[PATH_MAX] ep;
    i32 en = plat_exe_path(&ep[0], PATH_MAX);
    if en == 0 { return; }
    i32 argc = get_argc();
    u8** av = alloc<u8*>(cast(i64, argc + 2));
    av[0] = str_to_cstr(str_from(&ep[0], en));
    av[1] = str_to_cstr("--no-detach");
    for i32 i = 1; i < argc; i++ { av[i + 1] = get_arg(i); }
    av[argc + 1] = null;
    i32 pid = mc_fork();
    if pid == 0 {
        ignore mt_setsid();
        ignore mc_execv(av[0], av);
        mc_exit(127);
    }
    if pid < 0 { return; }
    mc_exit(0);
}

bool plat_term_export(i32 h, i64* fd, i32* pid) {
    if h < 0 || h >= TERM_MAX || !g_lterm[h].used || g_lterm[h].master < 0 { return false; }
    ignore mc_fcntl(g_lterm[h].master, MT_F_SETFD, 0);   // the master was opened close-on-exec
    *fd = cast(i64, g_lterm[h].master);
    *pid = g_lterm[h].pid;
    return true;
}

i32 plat_term_adopt(i64 fd, i32 pid) {
    if fd < 0 { return -1; }
    i32 h = -1;
    for i32 i = 0; i < TERM_MAX; i++ {
        if !g_lterm[i].used {
            h = i;
            break;
        }
    }
    if h < 0 { return -1; }
    g_lterm[h].master = cast(i32, fd);
    g_lterm[h].pid = pid;
    g_lterm[h].code = -1;
    g_lterm[h].used = true;
    return h;
}

// the directory holding the running executable, no trailing slash
i32 plat_exe_dir(u8* out, i32 cap) {
    noinit u8[PATH_MAX] buf;
    u8* p = str_to_cstr("/proc/self/exe");
    i64 n = readlink(p, &buf[0], cast(u64, PATH_MAX));
    free(p);
    if n <= 0 { return 0; }
    i32 last = -1;
    for i32 i = 0; i < cast(i32, n); i++ {
        if buf[i] == '/' { last = i; }
    }
    if last <= 0 { return 0; }
    i32 outn = last;
    if outn > cap { outn = cap; }
    memcpy(out, &buf[0], outn);
    return outn;
}

// this driver makes no second window yet; a no-op
i32 plat_window_open() {
    return -1;
}

bool plat_window_rect(i32 win, i32* x, i32* y, i32* w, i32* h, i32* maxi) {
    return false;
}
i32 plat_window_open_at(i32 x, i32 y, i32 w, i32 h, i32 maxi) {
    return -1;
}
void plat_window_set_rect(i32 win, i32 x, i32 y, i32 w, i32 h, i32 maxi) {
}

// no dialog in Xlib; the caller asks its own way
bool plat_pick_folder() {
    return false;
}

bool plat_pick_save(str dir, str name) {
    return false;
}

// the recent folders changed; the shell's list for the app follows
// (the Windows taskbar's jump list), nothing here yet
void plat_recent_folders(str* dirs, i32 n) {}
