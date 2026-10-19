// win.mc - Win32 platform surface: externs, structs, constants,
// window state, and the plat_* services from plat.mc. The driver
// is plat_win.mc.

type HWND = void*;
type UINT = u32;
type WPARAM = u64;
type LPARAM = i64;
type LRESULT = i64;
type WNDPROC = fn(HWND, UINT, WPARAM, LPARAM): LRESULT;

struct POINT {
    i32 x;
    i32 y;
}

struct RECT {
    i32 left;
    i32 top;
    i32 right;
    i32 bottom;
}

struct WINDOWPLACEMENT {
    u32 length;
    u32 flags;
    u32 showCmd;
    POINT ptMinPosition;
    POINT ptMaxPosition;
    RECT rcNormalPosition;
}

const u32 WPF_RESTORETOMAXIMIZED = 2;

struct MSG {
    HWND hwnd;
    u32 message;
    u64 wParam;
    i64 lParam;
    u32 time;
    POINT pt;
}

struct ICONINFO {
    i32 fIcon;
    u32 xHotspot;
    u32 yHotspot;
    void* hbmMask;
    void* hbmColor;
}

struct WNDCLASSEXW {
    u32 cbSize;
    u32 style;
    WNDPROC lpfnWndProc;
    i32 cbClsExtra;
    i32 cbWndExtra;
    void* hInstance;
    void* hIcon;
    void* hCursor;
    void* hbrBackground;
    u16* lpszMenuName;
    u16* lpszClassName;
    void* hIconSm;
}

struct PAINTSTRUCT {
    void* hdc;
    i32 fErase;
    RECT rcPaint;
    i32 fRestore;
    i32 fIncUpdate;
    u8[32] rgbReserved;
}

struct TEXTMETRICW {
    i32 tmHeight;
    i32 tmAscent;
    i32 tmDescent;
    i32 tmInternalLeading;
    i32 tmExternalLeading;
    i32 tmAveCharWidth;
    i32 tmMaxCharWidth;
    i32 tmWeight;
    i32 tmOverhang;
    i32 tmDigitizedAspectX;
    i32 tmDigitizedAspectY;
    u16 tmFirstChar;
    u16 tmLastChar;
    u16 tmDefaultChar;
    u16 tmBreakChar;
    u8 tmItalic;
    u8 tmUnderlined;
    u8 tmStruckOut;
    u8 tmPitchAndFamily;
    u8 tmCharSet;
}

struct FIXED {
    u16 fract;
    i16 value;
}

struct MAT2 {
    FIXED eM11;
    FIXED eM12;
    FIXED eM21;
    FIXED eM22;
}

struct GLYPHMETRICS {
    u32 gmBlackBoxX;
    u32 gmBlackBoxY;
    POINT gmptGlyphOrigin;
    i16 gmCellIncX;
    i16 gmCellIncY;
}

extern "kernel32.dll" {
    void* GetModuleHandleA(u8* name);
    u32 GetLastError();
    void* LoadLibraryA(u8* name);
    void* GetProcAddress(void* mod, u8* name);
}

extern "user32.dll" {
    u16 RegisterClassExW(void* wc);
    void* CreateWindowExW(u32 exstyle, u16* cls, u16* title, u32 style, i32 x, i32 y, i32 w, i32 h, void* parent, void* menu, void* inst, void* param);
    i64 DefWindowProcW(HWND h, u32 m, u64 wp, i64 lp);
    i32 ShowWindow(HWND h, i32 cmd);
    i32 SetForegroundWindow(HWND h);
    i32 DestroyWindow(HWND h);
    void PostQuitMessage(i32 code);
    i32 PostMessageW(HWND h, u32 m, u64 wp, i64 lp);
    i32 GetMessageW(void* msg, HWND h, u32 lo, u32 hi);
    i32 PeekMessageW(void* msg, HWND h, u32 lo, u32 hi, u32 remove);
    u32 MsgWaitForMultipleObjectsEx(u32 n, void** hs, u32 ms, u32 wake, u32 flags);
    i32 TranslateMessage(void* msg);
    i64 DispatchMessageW(void* msg);
    i32 InvalidateRect(HWND h, void* rc, i32 erase);
    i32 UpdateWindow(HWND h);
    void* BeginPaint(HWND h, void* ps);
    i32 EndPaint(HWND h, void* ps);
    i32 GetClientRect(HWND h, void* rc);
    i32 GetWindowRect(HWND h, void* rc);
    void* LoadCursorA(void* inst, u8* name);
    i32 AdjustWindowRect(void* rc, u32 style, i32 menu);
    i16 GetKeyState(i32 vk);
    u64 SetTimer(HWND h, u64 id, u32 ms, void* proc);
    i32 KillTimer(HWND h, u64 id);
    i32 SetProcessDpiAwarenessContext(i64 ctx);
    u32 GetDpiForWindow(HWND h);
    i32 SetWindowTextW(HWND h, u16* title);
    i32 SetWindowPos(HWND h, HWND after, i32 x, i32 y, i32 w, i32 h, u32 flags);
    HWND SetCapture(HWND h);
    i32 ReleaseCapture();
    i32 SystemParametersInfoW(u32 action, u32 param, void* pv, u32 winini);
    i32 ScreenToClient(HWND h, void* pt);
    i32 OpenClipboard(HWND h);
    i32 CloseClipboard();
    i32 EmptyClipboard();
    void* GetClipboardData(u32 format);
    void* SetClipboardData(u32 format, void* h);
    i32 IsClipboardFormatAvailable(u32 format);
    void* CreateIconIndirect(void* ii);
    i32 IsZoomed(HWND h);
    i32 IsIconic(HWND h);
    i32 GetWindowPlacement(HWND h, WINDOWPLACEMENT* wp);
    i32 GetSystemMetrics(i32 index);
    i32 GetCursorPos(POINT* p);
    void* SetCursor(void* cursor);
    i32 TrackMouseEvent(TRACKMOUSEEVENT* t);
}

// WM_MOUSELEAVE arrives once per TrackMouseEvent, which is what clears
// a window button's hover look when the pointer leaves the window
const u32 WM_MOUSELEAVE = 0x02A3;
const u32 TME_LEAVE = 0x2;

struct TRACKMOUSEEVENT {
    u32 cbSize;
    u32 dwFlags;
    HWND hwndTrack;
    u32 dwHoverTime;
}

extern "kernel32.dll" {
    u32 GetCurrentDirectoryW(u32 cap, u16* buf);
}

// self-drawn caption (see plat.mc g_caption_h)
const u32 WM_NCCALCSIZE = 0x0083;
const u32 WM_NCHITTEST = 0x0084;
const u32 WM_SYSCOMMAND = 0x0112;
const i64 HTCLIENT = 1;
const i64 HTCAPTION = 2;
const i64 HTTOP = 12;
const u64 SC_MINIMIZE = 0xF020;
const u64 SC_MAXIMIZE = 0xF030;
const u64 SC_RESTORE = 0xF120;
const i32 SM_CYSIZEFRAME = 33;
const i32 SM_CXSCREEN = 0;
const i32 SM_CYSCREEN = 1;
const i32 SM_CXPADDEDBORDER = 92;
const u64 SIZE_MAXIMIZED = 2;
const u32 SWP_NOSIZE = 0x0001;
const u32 SWP_NOMOVE = 0x0002;
const u32 SWP_FRAMECHANGED = 0x0020;

// Windows 11 caption attributes; the calls no-op on Windows 10
// (immersive dark mode still applies there).
const u32 DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
const u32 DWMWA_CAPTION_COLOR = 35;
const u32 DWMWA_TEXT_COLOR = 36;

extern "dwmapi.dll" {
    i32 DwmSetWindowAttribute(HWND h, u32 attr, void* pv, u32 cb);
}

extern "kernel32.dll" {
    void* GlobalAlloc(u32 flags, u64 bytes);
    void* GlobalFree(void* h);
    void* GlobalLock(void* h);
    i32 GlobalUnlock(void* h);
    i32 QueryPerformanceCounter(i64* v);
    i32 QueryPerformanceFrequency(i64* v);
    void win_sleep_ms(u32 ms) from "Sleep";
    i32 win_close_handle(void* h) from "CloseHandle";
    u32 win_wait_object(void* h, u32 ms) from "WaitForSingleObject";
}

// IME: the composition UI is anchored at the caret; committed text
// arrives as regular WM_CHAR messages
struct COMPOSITIONFORM {
    u32 style;
    POINT pt;
    RECT area;
}

extern "imm32.dll" {
    void* ImmGetContext(HWND h);
    i32 ImmReleaseContext(HWND h, void* himc);
    i32 ImmSetCompositionWindow(void* himc, void* form);
}

extern "gdi32.dll" {
    void* CreateBitmap(i32 w, i32 h, u32 planes, u32 bpp, void* bits);
    void* CreateCompatibleDC(void* hdc);
    i32 DeleteDC(void* hdc);
    void* CreateFontW(i32 h, i32 w, i32 esc, i32 orient, i32 weight, u32 italic, u32 underline, u32 strikeout, u32 charset, u32 outprec, u32 clipprec, u32 quality, u32 pitchfam, u16* face);
    void* SelectObject(void* hdc, void* obj);
    i32 DeleteObject(void* obj);
    i32 GetTextMetricsW(void* hdc, void* tm);
    u32 GetGlyphOutlineW(void* hdc, u32 ch, u32 fmt, void* gm, u32 bufsize, void* buf, void* mat2);
}

const u32 CS_HREDRAW = 2;
const u32 CS_VREDRAW = 1;
const u32 WS_OVERLAPPEDWINDOW = 0x00CF0000;
const i32 SW_SHOW = 5;
const i32 SW_MAXIMIZE = 3;
const u32 SWP_NOZORDER = 0x0004;
const u32 SWP_NOACTIVATE = 0x0010;
const u32 SWP_SHOWWINDOW = 0x0040;
const u32 CW_USEDEFAULT = 0x80000000;
const i32 IDC_IBEAM = 32513;
const i32 IDC_SIZEWE = 32644;
const i32 IDC_SIZENS = 32645;
const i32 IDC_HAND = 32649;
const i32 IDC_ARROW = 32512;
const u32 WM_SETCURSOR = 0x0020;
const i64 DPI_AWARE_PER_MONITOR_V2 = -4;
const i32 WHEEL_DELTA = 120;
const u32 WM_MOUSEHWHEEL = 0x020E;
const u32 WM_SETTINGCHANGE = 0x001A;
const u32 CF_UNICODETEXT = 13;
const u32 GMEM_MOVEABLE = 0x0002;
const u32 SPI_GETFONTSMOOTHINGORIENTATION = 0x2012;
const u32 FE_FONTSMOOTHINGORIENTATIONBGR = 0;

const u32 WM_SIZE = 0x0005;
const u32 WM_SETFOCUS = 0x0007;
const u32 WM_KILLFOCUS = 0x0008;
const u32 WM_PAINT = 0x000F;
const u32 WM_CLOSE = 0x0010;
const u32 WM_DESTROY = 0x0002;
const u32 WM_ERASEBKGND = 0x0014;
const u32 WM_KEYDOWN = 0x0100;
const u32 WM_KEYUP = 0x0101;
const u32 WM_CHAR = 0x0102;
const u32 WM_SYSKEYDOWN = 0x0104;
const u32 WM_SYSKEYUP = 0x0105;
const u32 WM_SYSCHAR = 0x0106;
const u32 WM_IME_STARTCOMPOSITION = 0x010D;
const u32 CFS_POINT = 0x0002;
const u32 WM_TIMER = 0x0113;
const u32 WM_MOUSEMOVE = 0x0200;
const u32 WM_LBUTTONDOWN = 0x0201;
const u32 WM_LBUTTONUP = 0x0202;
const u32 WM_RBUTTONDOWN = 0x0204;
const u32 WM_RBUTTONUP = 0x0205;
const u32 WM_MOUSEWHEEL = 0x020A;
const u32 WM_DPICHANGED = 0x02E0;

const i32 VK_BACK = 0x08;
const i32 VK_TAB = 0x09;
const i32 VK_RETURN = 0x0D;
const i32 VK_SHIFT = 0x10;
const i32 VK_CONTROL = 0x11;
const i32 VK_MENU = 0x12;
const i32 VK_ESCAPE = 0x1B;
const i32 VK_PRIOR = 0x21;
const i32 VK_NEXT = 0x22;
const i32 VK_END = 0x23;
const i32 VK_HOME = 0x24;
const i32 VK_LEFT = 0x25;
const i32 VK_UP = 0x26;
const i32 VK_RIGHT = 0x27;
const i32 VK_DOWN = 0x28;
const i32 VK_DELETE = 0x2E;
const i32 VK_OEM_2 = 0xBF;   // the '/' key on US layouts
const i32 VK_OEM_5 = 0xDC;   // the backslash key on US layouts
const i32 VK_OEM_PERIOD = 0xBE;   // the '.' key on every layout

const i32 FW_NORMAL = 400;
const u32 DEFAULT_CHARSET = 1;
const u32 ANTIALIASED_QUALITY = 4;
const u32 GGO_METRICS = 0;
const u32 GGO_GRAY8_BITMAP = 6;
const u32 GDI_ERROR = 0xFFFFFFFF;

// The one window. Portable code reaches it through the plat_*
// services only.
HWND g_hwnd = null;

private const i32 TITLE_MAX = 2300;

// Widen an ASCII literal to UTF-16 for the W entry points. Leaks;
// only for one-time strings (class name, font face).
u16* win_wide(u8* s) {
    i32 n = 0;
    while s[n] != 0 { n++; }
    u16* buf = alloc<u16>(n + 1);
    for i32 i = 0; i < n; i++ {
        buf[i] = s[i];
    }
    buf[n] = 0;
    return buf;
}

i32 win_lo16s(i64 v) {
    return cast(i32, cast(i16, cast(u16, v & 0xFFFF)));
}

i32 win_hi16s(i64 v) {
    return cast(i32, cast(i16, cast(u16, (v >> 16) & 0xFFFF)));
}

bool win_key_down(i32 vk) {
    return (cast(i32, GetKeyState(vk)) & 0x8000) != 0;
}

void plat_set_timer(i32 id, i32 ms) {
    ignore SetTimer(g_hwnd, cast(u64, id), cast(u32, ms), null);
}

void plat_kill_timer(i32 id) {
    ignore KillTimer(g_hwnd, cast(u64, id));
}

// UTF-8 in, UTF-16 at the API.
void plat_set_title(str s) {
    noinit u16[TITLE_MAX + 4] w;
    if win_utf16(s, &w[0], TITLE_MAX + 4) < 0 { return; }   // the core keeps it under TITLE_MAX
    ignore SetWindowTextW(g_hwnd, &w[0]);
}

void plat_quit() {
    PostQuitMessage(0);
}

const u32 WM_WAKE = 0x8000;   // WM_APP: plat_wake, from any thread

// Thread-safe main-thread wake. A worker sets an auto-reset event, and
// the message loop turns a set event into one WM_WAKE (win_wake_take).
// Posting WM_WAKE from the workers instead fills the queue during a
// flood of terminal output. The queue returns posted messages before
// input and WM_PAINT, so the window then neither draws nor takes keys.
private void* g_wake_ev = null;

void win_wake_init() {
    if g_wake_ev == null { g_wake_ev = wc_create_event(null, 0, 0, null); }
}

// the event the message loop waits on beside the input, or null
void* win_wake_event() {
    return g_wake_ev;
}

// A set event becomes one WM_WAKE. The wait takes the event, so any
// number of plat_wake calls since the last take post one message.
void win_wake_take() {
    if g_wake_ev == null || win_wait_object(g_wake_ev, 0) != 0 { return; }
    ignore PostMessageW(g_hwnd, WM_WAKE, 0, 0);
}

void plat_wake() {
    if g_wake_ev != null {
        ignore wc_set_event(g_wake_ev);
        return;
    }
    ignore PostMessageW(g_hwnd, WM_WAKE, 0, 0);
}

// working directory, UTF-8; feeds the title's project name
i32 plat_cwd(u8* buf, i32 cap) {
    noinit u16[PATH_MAX] w;
    u32 n = GetCurrentDirectoryW(cast(u32, PATH_MAX), &w[0]);
    if n == 0 || n >= cast(u32, PATH_MAX) { return 0; }
    i32 m = win_utf8(&w[0], cast(i64, n), buf, cap);
    if m < 0 { return 0; }
    return m;
}

private i64 win_qpc_freq = 0;

i64 plat_time_us() {
    if win_qpc_freq == 0 {
        ignore QueryPerformanceFrequency(&win_qpc_freq);
    }
    i64 t = 0;
    ignore QueryPerformanceCounter(&t);
    // split to avoid t * 1e6 overflowing after ~10 days of uptime
    return (t / win_qpc_freq) * 1000000 + (t % win_qpc_freq) * 1000000 / win_qpc_freq;
}

// UTF-8 + '\n' in, UTF-16 + CRLF on the clipboard.
void plat_clipboard_set(u8* s, i64 n) {
    if n <= 0 || n > 2147483647 { return; }
    if OpenClipboard(g_hwnd) == 0 { return; }
    ignore EmptyClipboard();
    void* h = GlobalAlloc(GMEM_MOVEABLE, cast(u64, (n * 2 + 2) * 2));
    if h == null {
        ignore CloseClipboard();
        return;
    }
    u16* w = cast(u16*, GlobalLock(h));
    if w == null {
        ignore GlobalFree(h);
        ignore CloseClipboard();
        return;
    }
    i32 i = 0;
    i64 m = 0;
    while i < cast(i32, n) {
        u32 cp = utf8_next(s, cast(i32, n), &i);
        if cp == 10 {
            w[m] = 13;
            m++;
            w[m] = 10;
            m++;
        } else if cp >= SURR_BASE {
            w[m] = cast(u16, SURR_HI + ((cp - SURR_BASE) >> 10));
            m++;
            w[m] = cast(u16, SURR_LO + ((cp - SURR_BASE) & 0x3FF));
            m++;
        } else {
            w[m] = cast(u16, cp);
            m++;
        }
    }
    w[m] = 0;
    ignore GlobalUnlock(h);
    if SetClipboardData(CF_UNICODETEXT, h) == null {
        ignore GlobalFree(h);
    }
    ignore CloseClipboard();
}

// UTF-16 + CRLF on the clipboard, UTF-8 + '\n' out.
u8* plat_clipboard_get(i64* out_len) {
    *out_len = 0;
    if IsClipboardFormatAvailable(CF_UNICODETEXT) == 0 { return null; }
    if OpenClipboard(g_hwnd) == 0 { return null; }
    void* h = GetClipboardData(CF_UNICODETEXT);
    if h == null {
        ignore CloseClipboard();
        return null;
    }
    u16* w = cast(u16*, GlobalLock(h));
    if w == null {
        ignore CloseClipboard();
        return null;
    }
    i64 units = 0;
    while w[units] != 0 { units++; }
    u8* buf = alloc<u8>(units * 3 + 4);
    i64 m = 0;
    i64 i = 0;
    while i < units {
        u32 c = cast(u32, w[i]);
        i++;
        if c == 13 { continue; }
        if c >= SURR_HI && c < SURR_LO && i < units {
            u32 lo = cast(u32, w[i]);
            if lo >= SURR_LO && lo <= SURR_END {
                c = SURR_BASE + ((c - SURR_HI) << 10) + (lo - SURR_LO);
                i++;
            }
        }
        m += cast(i64, utf8_encode(c, buf + m));
    }
    ignore GlobalUnlock(h);
    ignore CloseClipboard();
    *out_len = m;
    return buf;
}

// --- child process (the LSP server) ----------------------------------
// CreatePipe + CreateProcessW with redirected stdio. Structures and
// constants from the SDK headers; compile-verified on the Windows
// machine, like the rest of this file.

private struct WinSecAttrs {
    u32 nLength;
    u32 _pad;
    void* lpSecurityDescriptor;
    i32 bInheritHandle;
    i32 _pad2;
}

private struct WinStartupInfoW {
    u32 cb;
    u32 _pad;
    u16* lpReserved;
    u16* lpDesktop;
    u16* lpTitle;
    u32 dwX;
    u32 dwY;
    u32 dwXSize;
    u32 dwYSize;
    u32 dwXCountChars;
    u32 dwYCountChars;
    u32 dwFillAttribute;
    u32 dwFlags;
    u16 wShowWindow;
    u16 cbReserved2;
    u32 _pad3;
    u8* lpReserved2;
    void* hStdInput;
    void* hStdOutput;
    void* hStdError;
}

private struct WinProcInfo {
    void* hProcess;
    void* hThread;
    u32 dwProcessId;
    u32 dwThreadId;
}

private const u32 STARTF_USESTDHANDLES = 0x100;
private const u32 CREATE_NO_WINDOW = 0x08000000;
private const u32 HANDLE_FLAG_INHERIT = 1;

private extern "kernel32.dll" {
    i32 wc_create_pipe(void** rd, void** wr, WinSecAttrs* sa, u32 size) from "CreatePipe";
    i32 wc_set_handle_info(void* h, u32 mask, u32 flags) from "SetHandleInformation";
    i32 wc_create_process(u16* app, u16* cmd, void* pa, void* ta, i32 inherit,
        u32 flags, void* env, u16* cwd, WinStartupInfoW* si, WinProcInfo* pi) from "CreateProcessW";
    i32 wc_read_file(void* h, void* buf, u32 n, u32* got, void* ov) from "ReadFile";
    i32 wc_write_file(void* h, void* buf, u32 n, u32* put, void* ov) from "WriteFile";
    i32 wc_terminate(void* h, u32 code) from "TerminateProcess";
    i32 wc_close_handle(void* h) from "CloseHandle";
    u32 wc_wait_object(void* h, u32 ms) from "WaitForSingleObject";
    i32 wc_exit_code(void* h, u32* code) from "GetExitCodeProcess";
    i32 wc_duplicate_handle(void* sp, void* h, void* tp, void** out, u32 access, i32 inherit,
        u32 options) from "DuplicateHandle";
    void* wc_current_process() from "GetCurrentProcess";
    void* wc_create_job(void* sa, u16* name) from "CreateJobObjectW";
    i32 wc_assign_job(void* job, void* proc) from "AssignProcessToJobObject";
    i32 wc_terminate_job(void* job, u32 code) from "TerminateJobObject";
    u32 wc_resume_thread(void* thread) from "ResumeThread";
}

private const u32 CREATE_SUSPENDED = 0x4;

private const u32 DUPLICATE_SAME_ACCESS = 0x2;

// Both spawn paths create an inheritable pipe end, hand it to a child,
// and close it again. If the other spawn's CreateProcess lands inside
// that window it inherits the handle too, and then the pipe never
// reaches end of file: the reader waits for a writer that is some
// other child process and will not close it. The language server
// inheriting the git pipe froze the editor exactly that way. One
// spawn at a time closes the window; both spawners are ours.
// stdin pipe quota for the language server; see plat_child_spawn
private const u32 CHILD_PIPE_BYTES = 4194304;

private Mutex spawn_mutex;
private bool spawn_mutex_ready = false;

private void spawn_lock() {
    if !spawn_mutex_ready {
        mutex_init(&spawn_mutex);
        spawn_mutex_ready = true;
    }
    mutex_lock(&spawn_mutex);
}

private void*[PLAT_CHILDREN] child_proc;
private void*[PLAT_CHILDREN] child_in;    // write end: the child's stdin
private void*[PLAT_CHILDREN] child_out;   // read end: the child's stdout

private const u32 GENERIC_WRITE = 0x40000000;

bool plat_child_spawn(i32 k, str* argv, i32 argc) {
    if k < 0 || k >= PLAT_CHILDREN || child_proc[k] != null { return false; }
    noinit u16[8] nul_name;
    if win_utf16("NUL", &nul_name[0], 8) < 0 { return false; }
    spawn_lock();
    WinSecAttrs sa;
    sa.nLength = sizeof(WinSecAttrs);
    sa.lpSecurityDescriptor = null;
    sa.bInheritHandle = 1;
    // the null device, for stderr: a server logs there, and a log line
    // in the stdout pipe would land inside a frame
    void* nul = wc_create_file(&nul_name[0], GENERIC_WRITE, FILE_SHARE_ALL, &sa, OPEN_EXISTING, 0, null);
    if nul == null || cast(i64, nul) == -1 {
        mutex_unlock(&spawn_mutex);
        return false;
    }
    void* in_rd = null;
    void* in_wr = null;
    void* out_rd = null;
    void* out_wr = null;
    // A push carries the whole file, so the default pipe buffer (a few
    // kilobytes) makes plat_child_write block until the server drains
    // it - on the UI thread, for as long as an indexing server takes to
    // come back. Ask for room for a whole file instead. The size is a
    // quota, not a reservation.
    if wc_create_pipe(&in_rd, &in_wr, &sa, CHILD_PIPE_BYTES) == 0 {
        mutex_unlock(&spawn_mutex);
        ignore wc_close_handle(nul);
        return false;
    }
    if wc_create_pipe(&out_rd, &out_wr, &sa, 0) == 0 {
        ignore wc_close_handle(in_rd);
        ignore wc_close_handle(in_wr);
        mutex_unlock(&spawn_mutex);
        ignore wc_close_handle(nul);
        return false;
    }
    // our ends must not leak into the child
    ignore wc_set_handle_info(in_wr, HANDLE_FLAG_INHERIT, 0);
    ignore wc_set_handle_info(out_rd, HANDLE_FLAG_INHERIT, 0);
    i32 ccap = win_cmdline_cap(argv, argc);
    u16* cmd = alloc<u16>(ccap);
    ignore win_cmdline_argv(argv, argc, cmd, ccap);
    WinStartupInfoW si;
    si.cb = sizeof(WinStartupInfoW);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = in_rd;
    si.hStdOutput = out_wr;
    si.hStdError = nul;
    WinProcInfo pi;
    i32 ok = wc_create_process(null, cmd, null, null, 1, CREATE_NO_WINDOW, null, null, &si, &pi);
    free(cmd);
    ignore wc_close_handle(in_rd);
    ignore wc_close_handle(out_wr);
    ignore wc_close_handle(nul);
    // the inheritable ends are gone, so another spawn may proceed
    mutex_unlock(&spawn_mutex);
    if ok == 0 {
        ignore wc_close_handle(in_wr);
        ignore wc_close_handle(out_rd);
        return false;
    }
    ignore wc_close_handle(pi.hThread);
    child_proc[k] = pi.hProcess;
    child_in[k] = in_wr;
    child_out[k] = out_rd;
    return true;
}

// One argument as the C runtime parses it back: plain when it has no
// space, tab or quote, else wrapped, with the backslashes that run into
// a quote doubled and the quote escaped. An LSP launch could skip
// this; a file path cannot.
private i64 win_cmdline_arg(str a, u8* out) {
    bool quote = a.len == 0;
    for i64 i = 0; i < a.len; i++ {
        u8 c = a.data[i];
        if c == ' ' || c == 9 || c == '"' { quote = true; }
    }
    if !quote {
        memcpy(out, a.data, a.len);
        return a.len;
    }
    i64 o = 0;
    out[o] = '"';
    o++;
    i64 slashes = 0;
    for i64 i = 0; i < a.len; i++ {
        u8 c = a.data[i];
        if c == 92 {
            slashes++;
            out[o] = 92;
            o++;
            continue;
        }
        if c == '"' {
            for i64 k = 0; k < slashes + 1; k++ {
                out[o] = 92;
                o++;
            }
        }
        slashes = 0;
        out[o] = c;
        o++;
    }
    for i64 k = 0; k < slashes; k++ {
        out[o] = 92;
        o++;
    }
    out[o] = '"';
    o++;
    return o;
}

// worst case for a command line of these arguments, in bytes and in
// utf-16 units alike: every byte a quote needing an escape, plus the
// wrapping quotes, the separating space and the terminator
i32 win_cmdline_cap(str* argv, i32 argc) {
    i64 total = 1;
    for i32 i = 0; i < argc; i++ { total += 2 * argv[i].len + 4; }
    return cast(i32, total);
}

// argv as a CreateProcessW command line, terminated; the unit count
// without the terminator, 0 when it does not fit cap
i32 win_cmdline_argv(str* argv, i32 argc, u16* out, i32 cap) {
    u8* b = alloc<u8>(win_cmdline_cap(argv, argc));
    i64 o = 0;
    for i32 i = 0; i < argc; i++ {
        if i > 0 { b[o] = ' '; o++; }
        o += win_cmdline_arg(argv[i], b + o);
    }
    i32 n = win_utf16(str_from(b, cast(i32, o)), out, cap);
    free(b);
    if n < 0 { return 0; }
    return n;
}

// Run a program to completion and hand back its stdout. Separate from
// the children above because the language servers own those for the
// whole session; this is the one-shot git needs.
u8* plat_run_capture(str* argv, i32 argc, i64* out_len, i32* out_code) {
    *out_len = 0;
    *out_code = -1;
    spawn_lock();
    WinSecAttrs sa;
    sa.nLength = sizeof(WinSecAttrs);
    sa.lpSecurityDescriptor = null;
    sa.bInheritHandle = 1;
    void* out_rd = null;
    void* out_wr = null;
    if wc_create_pipe(&out_rd, &out_wr, &sa, 0) == 0 {
        mutex_unlock(&spawn_mutex);
        return null;
    }
    ignore wc_set_handle_info(out_rd, HANDLE_FLAG_INHERIT, 0);

    i32 ccap = win_cmdline_cap(argv, argc);
    u16* cmd = alloc<u16>(ccap);
    ignore win_cmdline_argv(argv, argc, cmd, ccap);
    WinStartupInfoW si;
    si.cb = sizeof(WinStartupInfoW);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = null;
    si.hStdOutput = out_wr;
    si.hStdError = out_wr;
    WinProcInfo pi;
    i32 ok = wc_create_process(null, cmd, null, null, 1, CREATE_NO_WINDOW,
        null, null, &si, &pi);
    free(cmd);
    // our copy of the write end has to go, or the read below never
    // sees end-of-file: the child is not the only one holding it
    ignore wc_close_handle(out_wr);
    // the inheritable end is gone, so another spawn may proceed. The
    // read below can take as long as the child does and must not hold
    // the lock while it waits.
    mutex_unlock(&spawn_mutex);
    if ok == 0 {
        ignore wc_close_handle(out_rd);
        return null;
    }
    ignore wc_close_handle(pi.hThread);
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
        u32 got = 0;
        if wc_read_file(out_rd, buf + n, cast(u32, cap - n), &got, null) == 0 { break; }
        if got == 0 { break; }
        n += cast(i64, got);
    }
    ignore wc_close_handle(out_rd);
    ignore wc_wait_object(pi.hProcess, 0xFFFFFFFF);
    u32 code = 0;
    ignore wc_exit_code(pi.hProcess, &code);
    ignore wc_close_handle(pi.hProcess);
    *out_code = cast(i32, code);
    *out_len = n;
    return buf;
}

i64 plat_child_write(i32 k, u8* p, i64 n) {
    if k < 0 || k >= PLAT_CHILDREN || child_in[k] == null { return -1; }
    i64 done = 0;
    while done < n {
        u32 put = 0;
        if wc_write_file(child_in[k], p + done, cast(u32, n - done), &put, null) == 0 { return done; }
        done += cast(i64, put);
    }
    return done;
}

i64 plat_child_read(i32 k, u8* p, i64 cap) {
    if k < 0 || k >= PLAT_CHILDREN || child_out[k] == null { return -1; }
    u32 got = 0;
    if wc_read_file(child_out[k], p, cast(u32, cap), &got, null) == 0 { return 0; }
    return cast(i64, got);
}

void plat_child_kill(i32 k) {
    if k < 0 || k >= PLAT_CHILDREN || child_proc[k] == null { return; }
    ignore wc_close_handle(child_in[k]);
    ignore wc_close_handle(child_out[k]);
    ignore wc_terminate(child_proc[k], 0);
    ignore wc_close_handle(child_proc[k]);
    child_proc[k] = null;
    child_in[k] = null;
    child_out[k] = null;
}


// --- pseudo-terminal (the terminal pane) -----------------------------
// ConPTY: CreatePseudoConsole over two pipes, then a process with the
// pty in its attribute list. The console host translates the child's
// console API calls into VT sequences on the way out and VT input into
// console events on the way in, so the emulator upstream sees the same
// byte protocol on every platform. Windows 10 1809 is the floor: the
// three entry points are resolved at spawn, so the binary still loads
// on an older Windows and plat_term_spawn answers -1 there.

private type PCreatePseudoConsole = fn(u32, void*, void*, u32, void**): i32;
private type PResizePseudoConsole = fn(void*, u32): i32;
private type PClosePseudoConsole = fn(void*): void;

private extern "kernel32.dll" {
    i32 wc_init_attrs(void* list, u32 count, u32 flags, i64* size)
        from "InitializeProcThreadAttributeList";
    i32 wc_update_attr(void* list, u32 flags, i64 attr, void* val, i64 cb,
        void* prev, i64* ret) from "UpdateProcThreadAttribute";
    void wc_delete_attrs(void* list) from "DeleteProcThreadAttributeList";
}

// STARTUPINFOEXW: the base structure followed by the attribute list.
// CreateProcessW takes it through the same parameter, which is what
// EXTENDED_STARTUPINFO_PRESENT tells it.
private struct WinStartupInfoExW {
    WinStartupInfoW si;
    void* lpAttributeList;
}

private const u32 EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
// ProcThreadAttributeValue(22, FALSE, TRUE, FALSE)
private const i64 PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;

// The flags argument to CreatePseudoConsole. 0 is the default host,
// which re-renders the console buffer; 1 asks it to take the cursor
// where it finds it, and it then reads the screen rather than clearing
// it. A probe option, so one capture runs under both
// (doc/TECH_DOC.md, "Terminal"); a shell opened under handed-over text asks for
// it whatever this says.
const i32 PSEUDOCONSOLE_INHERIT_CURSOR = 1;
i32 win_term_flags = 0;
// the probe prints what the spawn did; nothing else does
bool win_term_trace = false;

private struct WinTerm {
    void* hpc;
    void* proc;
    u32 pid;
    void* in_wr;     // write end: the child's input
    void* out_rd;    // read end: the child's output
    bool used;
    void* wait_proc; // the exit waiter's own copy of the process handle
    bool wait_up;
    Thread wait_thr;
    void* job;       // a command's process tree, or null for a shell
}
private WinTerm[TERM_MAX] g_terms;
private i32[TERM_MAX] g_term_wait_idx;
private Mutex g_term_pc_mu;   // the pty handle: the waiter and a kill both close it

private bool term_api_tried = false;
private bool term_api_ok = false;
private PCreatePseudoConsole term_create = null;
private PResizePseudoConsole term_resize_pc = null;
private PClosePseudoConsole term_close_pc = null;

private bool term_api() {
    if term_api_tried { return term_api_ok; }
    term_api_tried = true;
    void* k = LoadLibraryA("kernel32.dll");
    if k == null { return false; }
    term_create = cast(PCreatePseudoConsole, GetProcAddress(k, "CreatePseudoConsole"));
    term_resize_pc = cast(PResizePseudoConsole, GetProcAddress(k, "ResizePseudoConsole"));
    term_close_pc = cast(PClosePseudoConsole, GetProcAddress(k, "ClosePseudoConsole"));
    term_api_ok = term_create != null && term_resize_pc != null && term_close_pc != null;
    mutex_init(&g_term_pc_mu);
    return term_api_ok;
}

// the pty handle, taken: whoever takes it closes it, once
private void* term_take_pc(i32 h) {
    mutex_lock(&g_term_pc_mu);
    void* pc = g_terms[h].hpc;
    g_terms[h].hpc = null;
    mutex_unlock(&g_term_pc_mu);
    return pc;
}

// The console host does not always exit with its last client, and the
// output pipe ends only when the host does. So a thread waits for the
// child and then closes the pty: the host writes what it still holds,
// exits, and the reader gets its end of file. Windows Terminal ends a
// session the same way. The wait uses a handle of its own, since a kill
// closes the one in the record.
private void term_exit_wait(void* arg) {
    i32 h = *cast(i32*, arg);
    ignore wc_wait_object(g_terms[h].wait_proc, WAIT_INFINITE);
    void* pc = term_take_pc(h);
    if pc != null { term_close_pc(pc); }
}

// COORD is two 16-bit fields in one 32-bit word: X low, Y high.
private u32 term_coord(i32 cols, i32 rows) {
    if cols < 1 { cols = 1; }
    if rows < 1 { rows = 1; }
    if cols > 1000 { cols = 1000; }
    if rows > 1000 { rows = 1000; }
    return cast(u32, cols) | (cast(u32, rows) << 16);
}

// The shell to run: EDMINC_SHELL when it is set, else PowerShell 7.
// Windows PowerShell 5 and cmd.exe are not supported shells; either
// still runs as a child of this one.
private i32 term_cmdline(u16* out, i32 cap) {
    string sh = env_get("EDMINC_SHELL");
    i32 n = 0;
    if sh.len > 0 {
        n = win_utf16(str_from(sh.data, cast(i32, sh.len)), out, cap);
    } else {
        n = win_utf16("pwsh.exe -NoLogo", out, cap);
    }
    free(sh);
    return n;
}

i32 plat_term_spawn(i32 cols, i32 rows, str* cargv, i32 cargc, bool under) {
    if !term_api() { return -1; }
    i32 h = -1;
    for i32 i = 0; i < TERM_MAX; i++ {
        if !g_terms[i].used {
            h = i;
            break;
        }
    }
    if h < 0 { return -1; }

    // Neither pipe end is inheritable: the child reaches the pty
    // through the attribute list instead, and CreateProcessW below
    // inherits nothing at all. That is why this path needs none of the
    // handle dance, or the spawn lock, that plat_child_spawn does.
    void* in_rd = null;
    void* in_wr = null;
    void* out_rd = null;
    void* out_wr = null;
    if wc_create_pipe(&in_rd, &in_wr, null, 0) == 0 { return -1; }
    if wc_create_pipe(&out_rd, &out_wr, null, 0) == 0 {
        ignore wc_close_handle(in_rd);
        ignore wc_close_handle(in_wr);
        return -1;
    }
    void* hpc = null;
    // A shell coming up under text already on the screen inherits the
    // cursor: the host then asks where it is (DSR) and paints from
    // there instead of clearing, so the old output stays above the
    // new prompt.
    i32 flags = win_term_flags;
    if under { flags = PSEUDOCONSOLE_INHERIT_CURSOR; }
    i32 hr = term_create(term_coord(cols, rows), in_rd, out_wr,
        cast(u32, flags), &hpc);
    // the host dup'd its two ends; our copies have to go, or the read
    // side never sees the child's output end close
    ignore wc_close_handle(in_rd);
    ignore wc_close_handle(out_wr);
    if hr < 0 || hpc == null {
        ignore wc_close_handle(in_wr);
        ignore wc_close_handle(out_rd);
        return -1;
    }

    // one attribute: the pty the child is to be attached to
    i64 asz = 0;
    ignore wc_init_attrs(null, 1, 0, &asz);
    u8* alist = alloc<u8>(asz);
    bool ok = wc_init_attrs(cast(void*, alist), 1, 0, &asz) != 0;
    if ok {
        ok = wc_update_attr(cast(void*, alist), 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            hpc, cast(i64, sizeof(void*)), null, null) != 0;
    }
    noinit u16[2048] cmd;
    if ok {
        if cargc > 0 { ok = win_cmdline_argv(cargv, cargc, &cmd[0], 2048) > 0; }
        else { ok = term_cmdline(&cmd[0], 2048) > 0; }
    }
    WinProcInfo pi;
    if ok {
        WinStartupInfoExW six;
        six.si.cb = sizeof(WinStartupInfoExW);
        six.lpAttributeList = cast(void*, alist);
        // Without this the child takes the editor's own standard
        // handles, and an editor launched with its output redirected
        // (a log, a pipe) hands the shell that redirect instead of the
        // pty: its output never reaches the pane. Naming them empty
        // leaves the console host to fill them from the pty.
        six.si.dwFlags = STARTF_USESTDHANDLES;
        six.si.hStdInput = null;
        six.si.hStdOutput = null;
        six.si.hStdError = null;
        // a command starts suspended, so it is in its job before it can
        // start anything
        u32 cflags = EXTENDED_STARTUPINFO_PRESENT;
        if cargc > 0 { cflags |= CREATE_SUSPENDED; }
        ok = wc_create_process(null, &cmd[0], null, null, 0,
            cflags, null, null, cast(WinStartupInfoW*, &six), &pi) != 0;
        if win_term_trace {
            print("term: spawn ok {} pid {} err {}\n",
                ok, pi.dwProcessId, cast(i32, GetLastError()));
        }
    }
    wc_delete_attrs(cast(void*, alist));
    free(cast(void*, alist));
    if !ok {
        ignore wc_close_handle(in_wr);
        ignore wc_close_handle(out_rd);
        term_close_pc(hpc);
        return -1;
    }
    // A command (a build, a run) gets a job: the processes it starts
    // are in the job too, a program with a window of its own included,
    // which the console's close event does not reach. A kill ends the
    // job. A shell gets none, so closing it leaves what was launched
    // from it running, as a terminal window does.
    g_terms[h].job = null;
    if cargc > 0 {
        void* job = wc_create_job(null, null);
        if job != null && wc_assign_job(job, pi.hProcess) != 0 {
            g_terms[h].job = job;
        } else if job != null {
            ignore wc_close_handle(job);
        }
        ignore wc_resume_thread(pi.hThread);
    }
    ignore wc_close_handle(pi.hThread);
    g_terms[h].hpc = hpc;
    g_terms[h].proc = pi.hProcess;
    g_terms[h].pid = pi.dwProcessId;
    g_terms[h].in_wr = in_wr;
    g_terms[h].out_rd = out_rd;
    g_terms[h].used = true;
    g_terms[h].wait_up = false;
    g_terms[h].wait_proc = null;
    if wc_duplicate_handle(wc_current_process(), pi.hProcess, wc_current_process(),
            &g_terms[h].wait_proc, 0, 0, DUPLICATE_SAME_ACCESS) != 0 {
        g_term_wait_idx[h] = h;
        thread_create(&g_terms[h].wait_thr, term_exit_wait, cast(void*, &g_term_wait_idx[h]));
        g_terms[h].wait_up = true;
    }
    return h;
}

private bool term_valid(i32 h) {
    return h >= 0 && h < TERM_MAX && g_terms[h].used;
}

i64 plat_term_read(i32 h, u8* buf, i64 cap) {
    if !term_valid(h) { return -1; }
    void* rd = g_terms[h].out_rd;
    if rd == null { return -1; }
    u32 got = 0;
    // the kill closes this handle, which is what ends the blocking
    // read the terminal's reader thread sits in
    if wc_read_file(rd, buf, cast(u32, cap), &got, null) == 0 { return 0; }
    return cast(i64, got);
}

i64 plat_term_write(i32 h, u8* p, i64 n) {
    if !term_valid(h) { return -1; }
    void* wr = g_terms[h].in_wr;
    if wr == null { return -1; }
    i64 done = 0;
    while done < n {
        u32 put = 0;
        if wc_write_file(wr, p + done, cast(u32, n - done), &put, null) == 0 { return done; }
        if put == 0 { return done; }
        done += cast(i64, put);
    }
    return done;
}

// The child's exit code, or -1 while it is still running: the pane's
// banner says which it is.
i32 plat_term_code(i32 h) {
    if !term_valid(h) { return -1; }
    u32 code = 0;
    if wc_exit_code(g_terms[h].proc, &code) == 0 { return -1; }
    if code == 259 { return -1; }   // STILL_ACTIVE
    return cast(i32, code);
}

void plat_term_resize(i32 h, i32 cols, i32 rows) {
    if !term_valid(h) { return; }
    ignore term_resize_pc(g_terms[h].hpc, term_coord(cols, rows));
}

// Order matters here. The shell goes first, then the pty: the host
// exits with the pty and closes the output pipe, and that end of file
// is what ends the read the reader thread is parked in. Closing the
// pipe under a parked ReadFile does not end it - the first prototype
// hung there. The output handle outlives this call for the same
// reason, and plat_term_free releases it once the reader has gone.
// Draining until then is also what keeps the pty close from waiting
// on a host parked in a write nobody is reading.
void plat_term_kill(i32 h) {
    if !term_valid(h) { return; }
    if g_terms[h].job != null {
        ignore wc_terminate_job(g_terms[h].job, 1);
        ignore wc_close_handle(g_terms[h].job);
        g_terms[h].job = null;
    }
    if g_terms[h].proc != null {
        ignore wc_terminate(g_terms[h].proc, 0);
        ignore wc_close_handle(g_terms[h].proc);
        g_terms[h].proc = null;
    }
    if g_terms[h].in_wr != null {
        ignore wc_close_handle(g_terms[h].in_wr);
        g_terms[h].in_wr = null;
    }
    void* pc = term_take_pc(h);
    if pc != null { term_close_pc(pc); }
}

// After the reader has read its end of file and gone. The child has
// exited by then, so the exit waiter has woken and the join is short.
void plat_term_free(i32 h) {
    if h < 0 || h >= TERM_MAX { return; }
    if g_terms[h].wait_up {
        thread_join(&g_terms[h].wait_thr);
        g_terms[h].wait_up = false;
    }
    if g_terms[h].wait_proc != null {
        ignore wc_close_handle(g_terms[h].wait_proc);
        g_terms[h].wait_proc = null;
    }
    if g_terms[h].out_rd != null { ignore wc_close_handle(g_terms[h].out_rd); }
    g_terms[h].hpc = null;
    g_terms[h].proc = null;
    g_terms[h].in_wr = null;
    g_terms[h].out_rd = null;
    g_terms[h].used = false;
}

// --- the file watcher ----------------------------------------------------
// ReadDirectoryChangesW on the folder handle, with the subtree flag, so
// one handle covers every folder under it, .git included. The read is
// overlapped: the watcher's thread waits on its completion event and on
// a stop event together, so plat_watch_close ends the wait without
// closing a handle under a pending read. The next read is issued before
// the records go back, so changes made while the editor handles them
// are held by the system. Changes before the first read are not, so
// the first one is issued at open.

private struct WinOverlapped {
    u64 internal;
    u64 internal_high;
    u32 offset;
    u32 offset_high;
    void* event;
}

private extern "kernel32.dll" {
    void* wc_create_file(u16* name, u32 access, u32 share, void* sa, u32 disp,
        u32 flags, void* tmpl) from "CreateFileW";
    i32 wc_read_dir_changes(void* dir, void* buf, u32 len, i32 subtree, u32 filter,
        u32* got, WinOverlapped* ov, void* done) from "ReadDirectoryChangesW";
    void* wc_create_event(void* sa, i32 manual, i32 initial, u16* name) from "CreateEventW";
    i32 wc_set_event(void* h) from "SetEvent";
    i32 wc_reset_event(void* h) from "ResetEvent";
    u32 wc_wait_many(u32 n, void** hs, i32 all, u32 ms) from "WaitForMultipleObjects";
    i32 wc_overlapped_result(void* h, WinOverlapped* ov, u32* got, i32 wait) from "GetOverlappedResult";
    i32 wc_cancel_io(void* h, WinOverlapped* ov) from "CancelIoEx";
}

private const u32 FILE_LIST_DIRECTORY = 0x0001;
private const u32 FILE_SHARE_ALL = 0x0007;            // read, write, delete
private const u32 OPEN_EXISTING = 3;
private const u32 FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;   // opens a folder
private const u32 FILE_FLAG_OVERLAPPED = 0x40000000;
// file and folder names, size, last write
private const u32 WATCH_FILTER = 0x0001 | 0x0002 | 0x0008 | 0x0010;
private const u32 FILE_ACTION_MODIFIED = 3;
private const u32 WAIT_OBJECT_0 = 0;
private const u32 WAIT_INFINITE = 0xFFFFFFFF;
// 64 KB is the most a read over the network may ask for
private const u32 WATCH_BUF_BYTES = 65536;
private const i32 WATCH_MAX = 4;

private struct WinWatch {
    bool used;
    bool dead;       // a read could not be issued again
    void* dir;
    void* done;      // the read's completion event
    void* stop;
    u32* buf;        // DWORD-aligned, as the call requires
    WinOverlapped ov;
}

private WinWatch[WATCH_MAX] g_watch;

private bool watch_issue(i32 h) {
    memset(cast(void*, &g_watch[h].ov), 0, sizeof(WinOverlapped));
    g_watch[h].ov.event = g_watch[h].done;
    return wc_read_dir_changes(g_watch[h].dir, cast(void*, g_watch[h].buf),
        WATCH_BUF_BYTES, 1, WATCH_FILTER, null, &g_watch[h].ov, null) != 0;
}

i32 plat_watch_open(str dir) {
    i32 h = -1;
    for i32 i = 0; i < WATCH_MAX; i++ {
        if !g_watch[i].used { h = i; break; }
    }
    if h < 0 { return -1; }
    noinit u16[PATH_MAX] w;
    if win_utf16(dir, &w[0], PATH_MAX) < 0 { return -1; }
    void* d = wc_create_file(&w[0], FILE_LIST_DIRECTORY, FILE_SHARE_ALL, null,
        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, null);
    if d == null || cast(i64, d) == -1 { return -1; }
    g_watch[h].dir = d;
    g_watch[h].done = wc_create_event(null, 1, 0, null);
    g_watch[h].stop = wc_create_event(null, 1, 0, null);
    g_watch[h].buf = alloc<u32>(cast(i32, WATCH_BUF_BYTES / 4));
    g_watch[h].dead = false;
    g_watch[h].used = true;
    if g_watch[h].done == null || g_watch[h].stop == null || !watch_issue(h) {
        // a folder the call refuses (some network shares)
        plat_watch_free(h);
        return -1;
    }
    return h;
}

i64 plat_watch_read(i32 h, u8* out, i64 cap) {
    if h < 0 || h >= WATCH_MAX || !g_watch[h].used || g_watch[h].dead { return -1; }
    noinit void*[2] hs;
    hs[0] = g_watch[h].done;
    hs[1] = g_watch[h].stop;
    u32 r = wc_wait_many(2, &hs[0], 0, WAIT_INFINITE);
    if r != WAIT_OBJECT_0 {
        // stopped: cancel the read and let it finish before the buffer goes
        ignore wc_cancel_io(g_watch[h].dir, &g_watch[h].ov);
        u32 junk = 0;
        ignore wc_overlapped_result(g_watch[h].dir, &g_watch[h].ov, &junk, 1);
        g_watch[h].dead = true;
        return -1;
    }
    u32 got = 0;
    bool ok = wc_overlapped_result(g_watch[h].dir, &g_watch[h].ov, &got, 0) != 0;
    ignore wc_reset_event(g_watch[h].done);
    i64 n = 0;
    bool lost = !ok || got == 0;   // the system's buffer overflowed
    u8* p = cast(u8*, g_watch[h].buf);
    u32 o = 0;
    while !lost {
        u32 next = *cast(u32*, p + o);
        u32 action = *cast(u32*, p + o + 4);
        u32 nbytes = *cast(u32*, p + o + 8);
        if n + 1 >= cap { lost = true; break; }
        out[n] = 'm';
        if action == FILE_ACTION_MODIFIED { out[n] = 'c'; }
        n++;
        i32 m = win_utf8(cast(u16*, p + o + 12), cast(i64, nbytes / 2), out + n, cast(i32, cap - n - 1));
        if m < 0 { lost = true; break; }
        for i32 k = 0; k < m; k++ {
            if out[n + k] == '\\' { out[n + k] = '/'; }
        }
        n += m;
        out[n] = '\n';
        n++;
        if next == 0 { break; }
        o += next;
    }
    if !watch_issue(h) { g_watch[h].dead = true; }
    if lost { return 0; }
    return n;
}

void plat_watch_close(i32 h) {
    if h < 0 || h >= WATCH_MAX || !g_watch[h].used { return; }
    ignore wc_set_event(g_watch[h].stop);
}

void plat_watch_free(i32 h) {
    if h < 0 || h >= WATCH_MAX || !g_watch[h].used { return; }
    if g_watch[h].dir != null { ignore wc_close_handle(g_watch[h].dir); }
    if g_watch[h].done != null { ignore wc_close_handle(g_watch[h].done); }
    if g_watch[h].stop != null { ignore wc_close_handle(g_watch[h].stop); }
    if g_watch[h].buf != null { free(cast(void*, g_watch[h].buf)); }
    WinWatch z;
    g_watch[h] = z;
}

// --- the terminal's colors -------------------------------------------
// The pane takes the colors the user set up for their own terminal, the
// way the macOS layer takes Terminal.app's profile. Windows Terminal
// keeps settings.json under its package's LocalState; the stable build,
// the preview and the unpackaged build each have their own, and the one
// written last is the one being used. Paths are written with forward
// slashes, which Win32 takes.
//
// A profile names a colour scheme rather than carrying one, and reads
// what it does not set from the profiles' shared defaults. A scheme the
// user wrote is in the same file. The two the installer assigns are not:
// they live in the package's own defaults.json, under a versioned path
// that cannot be found from outside the package, so those two are here.

private const i32 WT_SLOTS = 19;   // foreground, background, cursor, the sixteen

private str[16] WT_ANSI_KEYS = {
    "black", "red", "green", "yellow", "blue", "purple", "cyan", "white",
    "brightBlack", "brightRed", "brightGreen", "brightYellow",
    "brightBlue", "brightPurple", "brightCyan", "brightWhite" };

// "#RRGGBB" in the atlas's layout; false when it is not one
private bool wt_hex(str s, u32* out) {
    if s.len != 7 || s.data[0] != '#' { return false; }
    u32 v = 0;
    for i32 i = 1; i < 7; i++ {
        u8 c = s.data[i];
        i32 d = -1;
        if c >= '0' && c <= '9' { d = cast(i32, c - '0'); }
        else if c >= 'a' && c <= 'f' { d = cast(i32, c - 'a') + 10; }
        else if c >= 'A' && c <= 'F' { d = cast(i32, c - 'A') + 10; }
        if d < 0 { return false; }
        v = v * 16 + cast(u32, d);
    }
    *out = 0xFF000000 | ((v >> 16) & 0xFF) | (v & 0xFF00) | ((v & 0xFF) << 16);
    return true;
}

// The settings files, newest written first. A machine can carry the
// stable build, the preview and an unpackaged copy at once, each with
// settings of its own, and which one the user means is not written
// down anywhere: opening either app rewrites its file, so the times
// only say which was launched last. The caller reads them in this
// order and keeps the first that names a colour, since a fresh install
// that names none has nothing to say about how a terminal should look.
private const i32 WT_FILES = 3;

private i32 wt_settings_paths(u8* out, i32 cap, i32* lens) {
    string la = env_get("LOCALAPPDATA");
    if la.len == 0 {
        free(la);
        return 0;
    }
    str[WT_FILES] tails = {
        "/Packages/Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe/LocalState/settings.json",
        "/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json",
        "/Microsoft/Windows Terminal/settings.json" };
    noinit u64[WT_FILES] when_at;
    i32 got = 0;
    for i32 i = 0; i < WT_FILES; i++ {
        i32 n = cast(i32, la.len);
        if n + tails[i].len >= cap { continue; }
        noinit u8[PATH_MAX] p;
        memcpy(&p[0], la.data, la.len);
        memcpy(&p[n], tails[i].data, tails[i].len);
        n += tails[i].len;
        FileStamp st = file_stamp(str_from(&p[0], n));
        if !st.ok { continue; }
        // in place, newest first
        i32 at = got;
        while at > 0 && when_at[at - 1] < st.mtime {
            when_at[at] = when_at[at - 1];
            lens[at] = lens[at - 1];
            memcpy(out + at * cap, out + (at - 1) * cap, lens[at]);
            at--;
        }
        when_at[at] = st.mtime;
        lens[at] = n;
        memcpy(out + at * cap, &p[0], n);
        got++;
    }
    free(la);
    return got;
}

// Windows Terminal writes comments into its settings, which JSON does
// not have; they go before the parser sees them, what is inside a
// string left alone.
private i64 wt_decomment(u8* p, i64 n) {
    i64 w = 0;
    i64 i = 0;
    bool instr = false;
    while i < n {
        u8 c = p[i];
        if instr {
            p[w] = c;
            w++;
            i++;
            if c == 92 && i < n {
                p[w] = p[i];
                w++;
                i++;
                continue;
            }
            if c == '"' { instr = false; }
            continue;
        }
        if c == '"' {
            instr = true;
            p[w] = c;
            w++;
            i++;
            continue;
        }
        if c == '/' && i + 1 < n && p[i + 1] == '/' {
            while i < n && p[i] != 10 { i++; }
            continue;
        }
        if c == '/' && i + 1 < n && p[i + 1] == '*' {
            i += 2;
            while i + 1 < n && (p[i] != '*' || p[i + 1] != '/') { i++; }
            i += 2;
            if i > n { i = n; }
            continue;
        }
        p[w] = c;
        w++;
        i++;
    }
    return w;
}

// the schemes the installer assigns, which the user's file never holds
private bool wt_builtin(str name, str* out) {
    bool plain = str_equal(name, "Campbell");
    bool pwsh = str_equal(name, "Campbell Powershell");
    if !plain && !pwsh { return false; }
    out[0] = "#CCCCCC";
    out[1] = "#0C0C0C";
    if pwsh { out[1] = "#012456"; }
    out[2] = "#FFFFFF";
    str[16] ansi = {
        "#0C0C0C", "#C50F1F", "#13A10E", "#C19C00",
        "#0037DA", "#881798", "#3A96DD", "#CCCCCC",
        "#767676", "#E74856", "#16C60C", "#F9F1A5",
        "#3B78FF", "#B4009E", "#61D6D6", "#F2F2F2" };
    for i32 i = 0; i < 16; i++ { out[3 + i] = ansi[i]; }
    return true;
}

private i32 wt_scheme_named(JDoc* d, i32 root, str name) {
    i32 arr = jd_get(d, root, "schemes");
    if arr < 0 { return -1; }
    for i32 it = jd_first(d, arr); it >= 0; it = jd_next(d, it) {
        i32 nm = jd_get(d, it, "name");
        if nm >= 0 && str_equal(jd_str(d, nm), name) { return it; }
    }
    return -1;
}

// a key from the profile, else from the profiles' shared defaults
private i32 wt_pick(JDoc* d, i32 prof, i32 defs, str key) {
    i32 v = -1;
    if prof >= 0 { v = jd_get(d, prof, key); }
    if v < 0 && defs >= 0 { v = jd_get(d, defs, key); }
    return v;
}

private void wt_take(JDoc* d, i32 node, i32 slot, u32* out, u32* have) {
    if node < 0 { return; }
    u32 c = 0;
    if !wt_hex(jd_str(d, node), &c) { return; }
    out[slot] = c;
    *have = *have | (1 << cast(u32, slot));
}

// what one settings file says, 0 when it names no colour at all
private u32 wt_palette_of(str file, u32* out) {
    FileData fd = file_read(file);
    if fd.data == null { return 0; }
    i64 flen = wt_decomment(fd.data, fd.len);
    JDoc d;
    i32 root = json_parse(&d, fd.data, flen);
    if root < 0 {
        json_free(&d);
        free(fd.data);
        return 0;
    }
    u32 have = 0;

    i32 profs = jd_get(&d, root, "profiles");
    i32 defs = -1;
    i32 list = -1;
    if profs >= 0 {
        defs = jd_get(&d, profs, "defaults");
        list = jd_get(&d, profs, "list");
        // "profiles" is the list itself when there are no shared defaults
        if defs < 0 && list < 0 { list = profs; }
    }
    i32 prof = -1;
    i32 dp = jd_get(&d, root, "defaultProfile");
    if dp >= 0 && list >= 0 {
        str want = jd_str(&d, dp);
        for i32 it = jd_first(&d, list); it >= 0; it = jd_next(&d, it) {
            i32 g = jd_get(&d, it, "guid");
            if g >= 0 && str_equal(jd_str(&d, g), want) {
                prof = it;
                break;
            }
        }
    }

    // the scheme first, then what the profile says over it
    i32 cs = wt_pick(&d, prof, defs, "colorScheme");
    if cs >= 0 {
        // newer settings name one scheme per appearance
        i32 dark = jd_get(&d, cs, "dark");
        if dark >= 0 { cs = dark; }
        str name = jd_str(&d, cs);
        i32 sch = wt_scheme_named(&d, root, name);
        if sch >= 0 {
            wt_take(&d, jd_get(&d, sch, "foreground"), TP_FG, out, &have);
            wt_take(&d, jd_get(&d, sch, "background"), TP_BG, out, &have);
            wt_take(&d, jd_get(&d, sch, "cursorColor"), TP_CURSOR, out, &have);
            wt_take(&d, jd_get(&d, sch, "selectionBackground"), TP_SEL, out, &have);
            for i32 i = 0; i < 16; i++ {
                wt_take(&d, jd_get(&d, sch, WT_ANSI_KEYS[i]), TP_ANSI + i, out, &have);
            }
        } else {
            noinit str[WT_SLOTS] b;
            if wt_builtin(name, &b[0]) {
                u32 c = 0;
                if wt_hex(b[0], &c) {
                    out[TP_FG] = c;
                    have = have | (1 << cast(u32, TP_FG));
                }
                if wt_hex(b[1], &c) {
                    out[TP_BG] = c;
                    have = have | (1 << cast(u32, TP_BG));
                }
                if wt_hex(b[2], &c) {
                    out[TP_CURSOR] = c;
                    have = have | (1 << cast(u32, TP_CURSOR));
                }
                for i32 i = 0; i < 16; i++ {
                    if wt_hex(b[3 + i], &c) {
                        out[TP_ANSI + i] = c;
                        have = have | (1 << cast(u32, TP_ANSI + i));
                    }
                }
            }
        }
    }
    wt_take(&d, wt_pick(&d, prof, defs, "foreground"), TP_FG, out, &have);
    wt_take(&d, wt_pick(&d, prof, defs, "background"), TP_BG, out, &have);
    wt_take(&d, wt_pick(&d, prof, defs, "cursorColor"), TP_CURSOR, out, &have);
    wt_take(&d, wt_pick(&d, prof, defs, "selectionBackground"), TP_SEL, out, &have);

    // Windows Terminal has no color for bold text of its own: it draws
    // it in the bright entry, or in the same one, by intenseTextStyle.
    // The foreground is the honest answer for the pane's own default,
    // and the bright-entry rule is view.mc's already.
    if (have & (1 << cast(u32, TP_FG))) != 0 && (have & (1 << cast(u32, TP_BOLD))) == 0 {
        out[TP_BOLD] = out[TP_FG];
        have = have | (1 << cast(u32, TP_BOLD));
    }
    json_free(&d);
    free(fd.data);
    return have;
}

u32 plat_term_palette(u32* out, i32 n) {
    if n < TP_N { return 0; }
    noinit u8[WT_FILES * PATH_MAX] paths;
    noinit i32[WT_FILES] lens;
    i32 got = wt_settings_paths(&paths[0], PATH_MAX, &lens[0]);
    for i32 i = 0; i < got; i++ {
        u32 have = wt_palette_of(str_from(&paths[i * PATH_MAX], lens[i]), out);
        if have != 0 { return have; }
    }
    return 0;
}

// directory listing: the stdlib's, this platform has a file system
DirList plat_dir_list(str dir, bool want_dirs) {
    return dir_list(dir, "", want_dirs);
}

// UTF-8 to NUL-terminated UTF-16; the unit count, or -1 when it does
// not fit (cap counts the terminator)
i32 win_utf16(str s, u16* out, i32 cap) {
    i32 n = 0;
    i32 i = 0;
    while i < s.len {
        u32 cp = utf8_next(s.data, s.len, &i);
        if n + 3 > cap { return -1; }
        if cp >= SURR_BASE {
            out[n] = cast(u16, SURR_HI + ((cp - SURR_BASE) >> 10));
            n++;
            out[n] = cast(u16, SURR_LO + ((cp - SURR_BASE) & 0x3FF));
            n++;
        } else {
            out[n] = cast(u16, cp);
            n++;
        }
    }
    out[n] = 0;
    return n;
}

// UTF-16 to UTF-8; the byte count, or -1 when it does not fit
i32 win_utf8(u16* w, i64 units, u8* out, i32 cap) {
    i64 m = 0;
    i64 i = 0;
    while i < units {
        u32 c = cast(u32, w[i]);
        i++;
        if c >= SURR_HI && c < SURR_LO && i < units {
            u32 lo = cast(u32, w[i]);
            if lo >= SURR_LO && lo <= SURR_END {
                c = SURR_BASE + ((c - SURR_HI) << 10) + (lo - SURR_LO);
                i++;
            }
        }
        if m + 4 > cast(i64, cap) { return -1; }
        m += cast(i64, utf8_encode(c, out + m));
    }
    return cast(i32, m);
}

private extern "kernel32.dll" {
    i32 SetCurrentDirectoryW(u16* path);
}

bool plat_chdir(str dir) {
    noinit u16[PATH_MAX] w;
    if win_utf16(dir, &w[0], PATH_MAX) < 0 { return false; }
    return SetCurrentDirectoryW(&w[0]) != 0;
}

private extern "kernel32.dll" {
    u32 GetModuleFileNameW(void* module, u16* buf, u32 size);
    i32 MoveFileExW(u16* src, u16* dst, u32 flags);
}

// a file or folder to a new name; fails when the target exists
bool plat_file_rename(str src, str dst) {
    noinit u16[PATH_MAX] wf;
    noinit u16[PATH_MAX] wt;
    if win_utf16(src, &wf[0], PATH_MAX) < 0 || win_utf16(dst, &wt[0], PATH_MAX) < 0 { return false; }
    return MoveFileExW(&wf[0], &wt[0], 0) != 0;
}

// the directory holding the running executable, UTF-8, no trailing slash
i32 plat_exe_path(u8* out, i32 cap) {
    noinit u16[PATH_MAX] w;
    u32 n = GetModuleFileNameW(null, &w[0], PATH_MAX);
    if n == 0 || n >= cast(u32, PATH_MAX) { return 0; }
    return win_utf8(&w[0], cast(i64, n), out, cap);
}

private extern "kernel32.dll" {
    void ExitProcess(u32 code);
}

private extern "user32.dll" {
    i32 AllowSetForegroundWindow(u32 pid);
    u32 WaitForInputIdle(void* proc, u32 ms);
}

// how long the old process stays for the new one's window
private const u32 EXEC_SELF_WAIT_MS = 10000;

// A new process rather than a replaced image, since Windows has no
// exec: the new one starts, this one exits. A running executable is
// locked against a rewrite, so a rebuilt one has to be built beside it
// and named here; ConPTY handles do not cross yet, so the terminals
// come back as new shells under the text the old ones had.
// Only the foreground process may hand the foreground on, so this one
// grants it and stays until the new one's message loop first waits,
// which is after its window is shown. Exiting first leaves the new
// window behind whatever the system activates next.
bool plat_exec_self(str exe, str* argv, i32 argc) {
    noinit str[RESTART_ARGV_MAX] full;
    // a headless run that restarts hands its dump flags and the
    // injections it has not delivered to the process it starts
    i32 extra = hl_restart_arg_count();
    if argc + 1 + extra > RESTART_ARGV_MAX { return false; }
    full[0] = exe;
    for i32 i = 0; i < argc; i++ { full[i + 1] = argv[i]; }
    for i32 i = 0; i < extra; i++ { full[argc + 1 + i] = hl_restart_arg(i); }
    noinit u16[4096] cmd;
    if win_cmdline_argv(&full[0], argc + 1 + extra, &cmd[0], 4096) <= 0 { return false; }
    WinStartupInfoW si;
    si.cb = sizeof(WinStartupInfoW);
    WinProcInfo pi;
    i32 ok = wc_create_process(null, &cmd[0], null, null, 0, 0, null, null, &si, &pi);
    if ok == 0 { return false; }
    ignore AllowSetForegroundWindow(pi.dwProcessId);
    ignore WaitForInputIdle(pi.hProcess, EXEC_SELF_WAIT_MS);
    ExitProcess(0);
    return false;
}

bool plat_term_export(i32 h, i64* fd, i32* pid) { return false; }
i32 plat_term_adopt(i64 fd, i32 pid) { return -1; }

i32 plat_exe_dir(u8* out, i32 cap) {
    noinit u16[PATH_MAX] w;
    u32 n = GetModuleFileNameW(null, &w[0], PATH_MAX);
    if n == 0 || n >= cast(u32, PATH_MAX) { return 0; }
    i32 last = -1;
    for i32 i = 0; i < cast(i32, n); i++ {
        if w[i] == '\\' || w[i] == '/' { last = i; }
    }
    if last <= 0 { return 0; }
    return win_utf8(&w[0], cast(i64, last), out, cap);
}

// --- the shell's folder and save dialogs -------------------------------
// IFileOpenDialog with the pick-folders option, and IFileSaveDialog;
// both share the IFileDialog slots used here. Show runs the dialog's
// own message loop, so the request is a posted message and the dialog
// opens from the wndproc once the event that asked has returned: no
// editor entry is on the stack while that loop runs. Slot positions
// follow shobjidl_core.h in the Windows SDK.

struct GUID {
    u32 Data1;
    u16 Data2;
    u16 Data3;
    u8[8] Data4;
}

private extern "ole32.dll" {
    i32 CoInitializeEx(void* reserved, u32 coinit);
    i32 CoCreateInstance(GUID* clsid, void* outer, u32 ctx, GUID* iid, void** out);
    void CoTaskMemFree(void* p);
}

private GUID CLSID_FileOpenDialog = GUID{ cast(u32, 0xDC1C5A9C), cast(u16, 0xE88A), cast(u16, 0x4DDE),
    { cast(u8, 0xA5), cast(u8, 0xA1), cast(u8, 0x60), cast(u8, 0xF8),
      cast(u8, 0x2A), cast(u8, 0x20), cast(u8, 0xAE), cast(u8, 0xF7) } };

private GUID IID_IFileOpenDialog = GUID{ cast(u32, 0xD57C7288), cast(u16, 0xD4AD), cast(u16, 0x4768),
    { cast(u8, 0xBE), cast(u8, 0x02), cast(u8, 0x9D), cast(u8, 0x96),
      cast(u8, 0x95), cast(u8, 0x32), cast(u8, 0xD9), cast(u8, 0x60) } };

private GUID CLSID_FileSaveDialog = GUID{ cast(u32, 0xC0B4E2F3), cast(u16, 0xBA21), cast(u16, 0x4773),
    { cast(u8, 0x8D), cast(u8, 0xBA), cast(u8, 0x33), cast(u8, 0x5E),
      cast(u8, 0xC9), cast(u8, 0x46), cast(u8, 0xEB), cast(u8, 0x8B) } };

private GUID IID_IFileSaveDialog = GUID{ cast(u32, 0x84BCCD23), cast(u16, 0x5FDE), cast(u16, 0x4CDB),
    { cast(u8, 0xAE), cast(u8, 0xA4), cast(u8, 0xAF), cast(u8, 0x64),
      cast(u8, 0xB8), cast(u8, 0x3D), cast(u8, 0x78), cast(u8, 0xAB) } };

private GUID IID_IShellItem = GUID{ cast(u32, 0x43826D1E), cast(u16, 0xE718), cast(u16, 0x42EE),
    { cast(u8, 0xBC), cast(u8, 0x55), cast(u8, 0xA1), cast(u8, 0xE2),
      cast(u8, 0x61), cast(u8, 0xC3), cast(u8, 0x7B), cast(u8, 0xFE) } };

private extern "shell32.dll" {
    i32 SHCreateItemFromParsingName(u16* path, void* bind, GUID* iid, void** out);
    i32 SHFileOperationW(SHFILEOPSTRUCTW* op);
    void* ILCreateFromPathW(u16* path);
    void ILFree(void* pidl);
    i32 SHOpenFolderAndSelectItems(void* pidl, u32 n, void** items, u32 flags);
    void* ShellExecuteW(HWND h, u16* op, u16* file, u16* params, u16* dir, i32 show);
}

struct SHFILEOPSTRUCTW {
    HWND hwnd;
    u32 wFunc;
    u16* pFrom;
    u16* pTo;
    u16 fFlags;
    i32 fAnyOperationsAborted;
    void* hNameMappings;
    u16* lpszProgressTitle;
}

private const u32 FO_DELETE = 3;
private const u16 FOF_SILENT = 0x4;
private const u16 FOF_NOCONFIRMATION = 0x10;
private const u16 FOF_ALLOWUNDO = 0x40;
private const u16 FOF_NOERRORUI = 0x400;

// a file or folder to the recycle bin, by its absolute path; no
// dialog, no progress
bool plat_trash(str path) {
    noinit u16[PICK_OUT_MAX] w;
    i32 n = win_utf16(path, &w[0], PICK_OUT_MAX - 1);
    if n <= 0 { return false; }
    w[n + 1] = 0;   // pFrom is a list, ended by an empty name
    SHFILEOPSTRUCTW op;
    op.hwnd = g_hwnd;
    op.wFunc = FO_DELETE;
    op.pFrom = &w[0];
    op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI;
    return SHFileOperationW(&op) == 0 && op.fAnyOperationsAborted == 0;
}

// an Explorer window on the folder holding path, with path selected
bool plat_reveal(str path) {
    if !win_com_ready {
        win_com_ready = CoInitializeEx(null, COINIT_APARTMENTTHREADED) >= 0;
    }
    noinit u16[PICK_OUT_MAX] w;
    if win_utf16(path, &w[0], PICK_OUT_MAX) <= 0 { return false; }
    void* pidl = ILCreateFromPathW(&w[0]);
    if pidl == null { return false; }
    bool ok = SHOpenFolderAndSelectItems(pidl, 0, null, 0) >= 0;
    ILFree(pidl);
    return ok;
}

private const i64 SHELLEXEC_OK_MIN = 32;   // ShellExecuteW returns more than this on success

bool plat_open_url(str url) {
    if !win_com_ready {
        win_com_ready = CoInitializeEx(null, COINIT_APARTMENTTHREADED) >= 0;
    }
    noinit u16[PICK_OUT_MAX] w;
    noinit u16[8] op;
    if win_utf16(url, &w[0], PICK_OUT_MAX) <= 0 || win_utf16("open", &op[0], 8) <= 0 { return false; }
    return cast(i64, ShellExecuteW(null, &op[0], &w[0], null, null, SW_SHOW)) > SHELLEXEC_OK_MIN;
}

struct IFileDialogVtbl {
    void* _pad0;
    void* _pad1;
    fn(void*): u32 Release;
    fn(void*, HWND): i32 Show;
    void* _pad4;
    void* _pad5;
    void* _pad6;
    void* _pad7;
    void* _pad8;
    fn(void*, u32): i32 SetOptions;
    fn(void*, u32*): i32 GetOptions;
    void* _pad11;
    fn(void*, void*): i32 SetFolder;
    void* _pad13;
    void* _pad14;
    fn(void*, u16*): i32 SetFileName;
    void* _pad16;
    fn(void*, u16*): i32 SetTitle;
    void* _pad18;
    void* _pad19;
    fn(void*, void**): i32 GetResult;
}

struct IFileDialog {
    IFileDialogVtbl* lpVtbl;
}

struct IShellItemVtbl {
    void* _pad0;
    void* _pad1;
    fn(void*): u32 Release;
    void* _pad3;
    void* _pad4;
    fn(void*, u32, u16**): i32 GetDisplayName;
}

struct IShellItem {
    IShellItemVtbl* lpVtbl;
}

private const u32 COINIT_APARTMENTTHREADED = 0x2;
private const u32 CLSCTX_INPROC_SERVER = 0x1;
private const u32 FOS_PICKFOLDERS = 0x20;
private const u32 FOS_FORCEFILESYSTEM = 0x40;
private const u32 FOS_PATHMUSTEXIST = 0x800;
private const u32 SIGDN_FILESYSPATH = 0x80058000;
private const i32 PICK_OUT_MAX = 4096;
const u32 WM_PICK_FOLDER = 0x8001;   // WM_APP + 1: open the dialog
const u32 WM_BENCH = 0x8002;         // WM_APP + 2: timed input from scripts/latency.ps1
const u32 WM_PICK_SAVE = 0x8004;     // WM_APP + 4: open the save dialog
private const u32 FOS_OVERWRITEPROMPT = 0x2;

private bool win_com_ready = false;

bool plat_pick_folder() {
    ignore PostMessageW(g_hwnd, WM_PICK_FOLDER, 0, 0);
    return true;
}

// the wndproc's side of plat_pick_folder: the dialog, then the reply
void win_pick_folder_run() {
    noinit u8[PICK_OUT_MAX] out;
    i32 len = 0;
    if !win_com_ready {
        // S_OK, or S_FALSE when something initialized it already
        win_com_ready = CoInitializeEx(null, COINIT_APARTMENTTHREADED) >= 0;
    }
    void* raw = null;
    if win_com_ready && CoCreateInstance(&CLSID_FileOpenDialog, null, CLSCTX_INPROC_SERVER,
            &IID_IFileOpenDialog, &raw) >= 0 {
        IFileDialog* dlg = cast(IFileDialog*, raw);
        u32 opts = 0;
        ignore dlg.lpVtbl.GetOptions(dlg, &opts);
        ignore dlg.lpVtbl.SetOptions(dlg, opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
        u16* title = win_wide("Open Folder");
        ignore dlg.lpVtbl.SetTitle(dlg, title);
        if dlg.lpVtbl.Show(dlg, g_hwnd) >= 0 {
            void* item = null;
            if dlg.lpVtbl.GetResult(dlg, &item) >= 0 {
                IShellItem* it = cast(IShellItem*, item);
                u16* w = null;
                if it.lpVtbl.GetDisplayName(it, SIGDN_FILESYSPATH, &w) >= 0 && w != null {
                    i64 units = 0;
                    while w[units] != 0 { units++; }
                    len = win_utf8(w, units, &out[0], PICK_OUT_MAX);
                    if len < 0 { len = 0; }
                    CoTaskMemFree(w);
                }
                ignore it.lpVtbl.Release(it);
            }
        }
        free(title);
        ignore dlg.lpVtbl.Release(dlg);
    }
    app_folder_picked(&out[0], len);
}

// the save dialog's starting folder and file name, held from the
// request to the posted message that opens it
private u16[PICK_OUT_MAX] win_save_dir;
private u16[PICK_OUT_MAX] win_save_name;

bool plat_pick_save(str dir, str name) {
    if win_utf16(dir, &win_save_dir[0], PICK_OUT_MAX) < 0 { win_save_dir[0] = 0; }
    if win_utf16(name, &win_save_name[0], PICK_OUT_MAX) < 0 { win_save_name[0] = 0; }
    ignore PostMessageW(g_hwnd, WM_PICK_SAVE, 0, 0);
    return true;
}

// the wndproc's side of plat_pick_save: the dialog, then the reply
void win_pick_save_run() {
    noinit u8[PICK_OUT_MAX] out;
    i32 len = 0;
    if !win_com_ready {
        win_com_ready = CoInitializeEx(null, COINIT_APARTMENTTHREADED) >= 0;
    }
    void* raw = null;
    if win_com_ready && CoCreateInstance(&CLSID_FileSaveDialog, null, CLSCTX_INPROC_SERVER,
            &IID_IFileSaveDialog, &raw) >= 0 {
        IFileDialog* dlg = cast(IFileDialog*, raw);
        u32 opts = 0;
        ignore dlg.lpVtbl.GetOptions(dlg, &opts);
        ignore dlg.lpVtbl.SetOptions(dlg, opts | FOS_OVERWRITEPROMPT | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
        u16* title = win_wide("Save As");
        ignore dlg.lpVtbl.SetTitle(dlg, title);
        if win_save_dir[0] != 0 {
            void* folder = null;
            if SHCreateItemFromParsingName(&win_save_dir[0], null, &IID_IShellItem, &folder) >= 0 {
                ignore dlg.lpVtbl.SetFolder(dlg, folder);
                IShellItem* fi = cast(IShellItem*, folder);
                ignore fi.lpVtbl.Release(fi);
            }
        }
        if win_save_name[0] != 0 { ignore dlg.lpVtbl.SetFileName(dlg, &win_save_name[0]); }
        if dlg.lpVtbl.Show(dlg, g_hwnd) >= 0 {
            void* item = null;
            if dlg.lpVtbl.GetResult(dlg, &item) >= 0 {
                IShellItem* it = cast(IShellItem*, item);
                u16* w = null;
                if it.lpVtbl.GetDisplayName(it, SIGDN_FILESYSPATH, &w) >= 0 && w != null {
                    i64 units = 0;
                    while w[units] != 0 { units++; }
                    len = win_utf8(w, units, &out[0], PICK_OUT_MAX);
                    if len < 0 { len = 0; }
                    CoTaskMemFree(w);
                }
                ignore it.lpVtbl.Release(it);
            }
        }
        free(title);
        ignore dlg.lpVtbl.Release(dlg);
    }
    app_save_picked(&out[0], len);
}

// --- the taskbar's jump list -----------------------------------------
// The recent folders as a "Recent" category in the menu the taskbar
// entry opens on a right click. Each entry is a shell link that starts
// this executable with the folder as its argument. The app has no
// explicit AppUserModelID, so the shell derives one from the
// executable's path, and a pinned entry, the running window and the
// list all match. Building the list loads shell objects and writes to
// disk, so a worker does it: plat_recent_folders hands over a copy of
// the paths and returns. The worker waits on a semaphore between
// requests and takes only the newest one. A folder the user removed
// from the list is not added back, which the shell requires, and goes
// back to the UI thread through WM_RECENT_REMOVED to leave the recent
// list as well. Slot positions follow shobjidl_core.h and propsys.h in
// the Windows SDK.

private GUID CLSID_DestinationList = GUID{ cast(u32, 0x77F10CF0), cast(u16, 0x3DB5), cast(u16, 0x4966),
    { cast(u8, 0xB5), cast(u8, 0x20), cast(u8, 0xB7), cast(u8, 0xC5),
      cast(u8, 0x4F), cast(u8, 0xD3), cast(u8, 0x5E), cast(u8, 0xD6) } };

private GUID IID_ICustomDestinationList = GUID{ cast(u32, 0x6332DEBF), cast(u16, 0x87B5), cast(u16, 0x4670),
    { cast(u8, 0x90), cast(u8, 0xC0), cast(u8, 0x5E), cast(u8, 0x57),
      cast(u8, 0xB4), cast(u8, 0x08), cast(u8, 0xA4), cast(u8, 0x9E) } };

private GUID CLSID_EnumerableObjectCollection = GUID{ cast(u32, 0x2D3468C1), cast(u16, 0x36A7), cast(u16, 0x43B6),
    { cast(u8, 0xAC), cast(u8, 0x24), cast(u8, 0xD3), cast(u8, 0xF0),
      cast(u8, 0x2F), cast(u8, 0xD9), cast(u8, 0x60), cast(u8, 0x7A) } };

private GUID IID_IObjectCollection = GUID{ cast(u32, 0x5632B1A4), cast(u16, 0xE38A), cast(u16, 0x400A),
    { cast(u8, 0x92), cast(u8, 0x8A), cast(u8, 0xD4), cast(u8, 0xCD),
      cast(u8, 0x63), cast(u8, 0x23), cast(u8, 0x02), cast(u8, 0x95) } };

private GUID IID_IObjectArray = GUID{ cast(u32, 0x92CA9DCD), cast(u16, 0x5622), cast(u16, 0x4BBA),
    { cast(u8, 0xA8), cast(u8, 0x05), cast(u8, 0x5E), cast(u8, 0x9F),
      cast(u8, 0x54), cast(u8, 0x1B), cast(u8, 0xD8), cast(u8, 0xC9) } };

private GUID CLSID_ShellLink = GUID{ cast(u32, 0x00021401), cast(u16, 0x0000), cast(u16, 0x0000),
    { cast(u8, 0xC0), cast(u8, 0x00), cast(u8, 0x00), cast(u8, 0x00),
      cast(u8, 0x00), cast(u8, 0x00), cast(u8, 0x00), cast(u8, 0x46) } };

private GUID IID_IShellLinkW = GUID{ cast(u32, 0x000214F9), cast(u16, 0x0000), cast(u16, 0x0000),
    { cast(u8, 0xC0), cast(u8, 0x00), cast(u8, 0x00), cast(u8, 0x00),
      cast(u8, 0x00), cast(u8, 0x00), cast(u8, 0x00), cast(u8, 0x46) } };

private GUID IID_IPropertyStore = GUID{ cast(u32, 0x886D8EEB), cast(u16, 0x8CF2), cast(u16, 0x4446),
    { cast(u8, 0x8D), cast(u8, 0x02), cast(u8, 0xCD), cast(u8, 0xBA),
      cast(u8, 0x1D), cast(u8, 0xBD), cast(u8, 0xCF), cast(u8, 0x99) } };

private GUID FMTID_Title = GUID{ cast(u32, 0xF29F85E0), cast(u16, 0x4FF9), cast(u16, 0x1068),
    { cast(u8, 0xAB), cast(u8, 0x91), cast(u8, 0x08), cast(u8, 0x00),
      cast(u8, 0x2B), cast(u8, 0x27), cast(u8, 0xB3), cast(u8, 0xD9) } };
private const u32 PKEY_TITLE_PID = 2;
private const u16 VT_LPWSTR = 31;
private const i32 JL_ARG_MAX = PATH_MAX + 4;
const u32 WM_RECENT_REMOVED = 0x8003;   // WM_APP + 3: the jump list's removed folders

struct PROPERTYKEY {
    GUID fmtid;
    u32 pid;
}

// the x64 layout: the type, three reserved words, a 16-byte union
struct PROPVARIANT {
    u16 vt;
    u16 r1;
    u16 r2;
    u16 r3;
    void* p;
    u64 rest;
}

struct ICustomDestinationListVtbl {
    void* _pad0;
    void* _pad1;
    fn(void*): u32 Release;
    void* _pad3;   // SetAppID
    fn(void*, u32*, GUID*, void**): i32 BeginList;
    fn(void*, u16*, void*): i32 AppendCategory;
    void* _pad6;   // AppendKnownCategory
    void* _pad7;   // AddUserTasks
    fn(void*): i32 CommitList;
}

struct ICustomDestinationList {
    ICustomDestinationListVtbl* lpVtbl;
}

// IObjectArray, and IObjectCollection after it
struct IObjectCollectionVtbl {
    fn(void*, GUID*, void**): i32 QueryInterface;
    void* _pad1;
    fn(void*): u32 Release;
    fn(void*, u32*): i32 GetCount;
    fn(void*, u32, GUID*, void**): i32 GetAt;
    fn(void*, void*): i32 AddObject;
}

struct IObjectCollection {
    IObjectCollectionVtbl* lpVtbl;
}

struct IShellLinkWVtbl {
    fn(void*, GUID*, void**): i32 QueryInterface;
    void* _pad1;
    fn(void*): u32 Release;
    void* _pad3;    // GetPath
    void* _pad4;    // GetIDList
    void* _pad5;    // SetIDList
    void* _pad6;    // GetDescription
    fn(void*, u16*): i32 SetDescription;
    void* _pad8;    // GetWorkingDirectory
    void* _pad9;    // SetWorkingDirectory
    fn(void*, u16*, i32): i32 GetArguments;
    fn(void*, u16*): i32 SetArguments;
    void* _pad12;   // GetHotkey
    void* _pad13;   // SetHotkey
    void* _pad14;   // GetShowCmd
    void* _pad15;   // SetShowCmd
    void* _pad16;   // GetIconLocation
    fn(void*, u16*, i32): i32 SetIconLocation;
    void* _pad18;   // SetRelativePath
    void* _pad19;   // Resolve
    fn(void*, u16*): i32 SetPath;
}

struct IShellLinkW {
    IShellLinkWVtbl* lpVtbl;
}

struct IPropertyStoreVtbl {
    void* _pad0;
    void* _pad1;
    fn(void*): u32 Release;
    void* _pad3;    // GetCount
    void* _pad4;    // GetAt
    void* _pad5;    // GetValue
    fn(void*, PROPERTYKEY*, PROPVARIANT*): i32 SetValue;
    fn(void*): i32 Commit;
}

struct IPropertyStore {
    IPropertyStoreVtbl* lpVtbl;
}

private Mutex g_jl_mu;
private Semaphore g_jl_sem;
private Thread g_jl_thr;
private bool g_jl_started = false;
private u8* g_jl_job = null;        // the newest request: the paths, one per line
private i32 g_jl_job_len = 0;
private u8* g_jl_gone = null;       // removed folders for the UI thread, one per line
private i32 g_jl_gone_len = 0;

void plat_recent_folders(str* dirs, i32 n) {
    i32 total = 0;
    for i32 i = 0; i < n; i++ { total += dirs[i].len + 1; }
    u8* job = alloc<u8>(total + 1);
    i32 o = 0;
    for i32 i = 0; i < n; i++ {
        memcpy(job + o, dirs[i].data, dirs[i].len);
        o += dirs[i].len;
        job[o] = 10;
        o++;
    }
    if !g_jl_started {
        mutex_init(&g_jl_mu);
        sem_init(&g_jl_sem, 0);
        g_jl_started = true;
        thread_create(&g_jl_thr, win_jl_main, null);
    }
    mutex_lock(&g_jl_mu);
    if g_jl_job != null { free(g_jl_job); }
    g_jl_job = job;
    g_jl_job_len = o;
    mutex_unlock(&g_jl_mu);
    sem_signal(&g_jl_sem);
}

private void win_jl_main(void* arg) {
    // in-process objects created and used on this thread only, so the
    // apartment needs no message loop
    bool com = CoInitializeEx(null, COINIT_APARTMENTTHREADED) >= 0;
    while true {
        sem_wait(&g_jl_sem);
        mutex_lock(&g_jl_mu);
        u8* job = g_jl_job;
        i32 len = g_jl_job_len;
        g_jl_job = null;
        mutex_unlock(&g_jl_mu);
        if job == null { continue; }   // an older signal; its job was replaced
        if com { win_jl_build(job, len); }
        free(job);
    }
}

// the folder's name, or the whole path when it has none (a drive root)
private str win_jl_title(str d) {
    i32 e = d.len;
    while e > 1 && (d.data[e - 1] == '/' || d.data[e - 1] == 92) { e--; }
    i32 s = e;
    while s > 0 && d.data[s - 1] != '/' && d.data[s - 1] != 92 { s--; }
    if s == e { return d; }
    return str_from(d.data + s, e - s);
}

// `"<dir>"`, the argument a link carries, into w
private i32 win_jl_arg(str d, u16* w) {
    w[0] = '"';
    i32 n = win_utf16(d, w + 1, JL_ARG_MAX - 3);
    if n < 0 { return -1; }
    w[n + 1] = '"';
    w[n + 2] = 0;
    return n + 2;
}

private bool win_jl_same(u16* a, u16* b) {
    i32 i = 0;
    while a[i] != 0 && a[i] == b[i] { i++; }
    return a[i] == b[i];
}

private void win_jl_build(u8* job, i32 len) {
    noinit u8[PATH_MAX] exe8;
    i32 en = plat_exe_path(&exe8[0], PATH_MAX);
    noinit u16[PATH_MAX] exe;
    if en == 0 || win_utf16(str_from(&exe8[0], en), &exe[0], PATH_MAX) < 0 { return; }

    void* raw = null;
    if CoCreateInstance(&CLSID_DestinationList, null, CLSCTX_INPROC_SERVER,
            &IID_ICustomDestinationList, &raw) < 0 { return; }
    ICustomDestinationList* dl = cast(ICustomDestinationList*, raw);
    u32 slots = 0;
    void* rraw = null;
    if dl.lpVtbl.BeginList(dl, &slots, &IID_IObjectArray, &rraw) < 0 {
        ignore dl.lpVtbl.Release(dl);
        return;
    }
    IObjectCollection* removed = cast(IObjectCollection*, rraw);
    u32 nremoved = 0;
    ignore removed.lpVtbl.GetCount(removed, &nremoved);
    // the removed links' arguments, each JL_ARG_MAX wide
    u16* gone = alloc<u16>(cast(i32, nremoved) * JL_ARG_MAX + 1);
    for u32 i = 0; i < nremoved; i++ {
        u16* g = gone + cast(i32, i) * JL_ARG_MAX;
        g[0] = 0;
        void* lraw = null;
        if removed.lpVtbl.GetAt(removed, i, &IID_IShellLinkW, &lraw) >= 0 {
            IShellLinkW* l = cast(IShellLinkW*, lraw);
            if l.lpVtbl.GetArguments(l, g, JL_ARG_MAX) < 0 { g[0] = 0; }
            ignore l.lpVtbl.Release(l);
        }
    }
    ignore removed.lpVtbl.Release(removed);

    void* craw = null;
    if CoCreateInstance(&CLSID_EnumerableObjectCollection, null, CLSCTX_INPROC_SERVER,
            &IID_IObjectCollection, &craw) >= 0 {
        IObjectCollection* col = cast(IObjectCollection*, craw);
        PROPERTYKEY key;
        key.fmtid = FMTID_Title;
        key.pid = PKEY_TITLE_PID;
        noinit u16[JL_ARG_MAX] arg;
        noinit u16[PATH_MAX] title;
        noinit u16[PATH_MAX] tip;
        u32 added = 0;
        i32 s = 0;
        for i32 i = 0; i < len && added < slots; i++ {
            if job[i] != 10 { continue; }
            str d = str_from(job + s, i - s);
            s = i + 1;
            if d.len == 0 || !path_is_dir(d) || win_jl_arg(d, &arg[0]) < 0 { continue; }
            bool was_removed = false;
            for u32 k = 0; k < nremoved; k++ {
                if win_jl_same(&arg[0], gone + cast(i32, k) * JL_ARG_MAX) { was_removed = true; }
            }
            if was_removed { continue; }
            if win_utf16(win_jl_title(d), &title[0], PATH_MAX) < 0 { continue; }
            if win_utf16(d, &tip[0], PATH_MAX) < 0 { continue; }
            void* lraw = null;
            if CoCreateInstance(&CLSID_ShellLink, null, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, &lraw) < 0 {
                continue;
            }
            IShellLinkW* l = cast(IShellLinkW*, lraw);
            ignore l.lpVtbl.SetPath(l, &exe[0]);
            ignore l.lpVtbl.SetArguments(l, &arg[0]);
            ignore l.lpVtbl.SetIconLocation(l, &exe[0], 0);
            ignore l.lpVtbl.SetDescription(l, &tip[0]);   // the tooltip
            // the menu shows the link's title, not its target
            void* praw = null;
            bool titled = false;
            if l.lpVtbl.QueryInterface(l, &IID_IPropertyStore, &praw) >= 0 {
                IPropertyStore* ps = cast(IPropertyStore*, praw);
                PROPVARIANT pv;
                pv.vt = VT_LPWSTR;
                pv.p = cast(void*, &title[0]);
                titled = ps.lpVtbl.SetValue(ps, &key, &pv) >= 0 && ps.lpVtbl.Commit(ps) >= 0;
                ignore ps.lpVtbl.Release(ps);
            }
            if titled && col.lpVtbl.AddObject(col, lraw) >= 0 { added++; }
            ignore l.lpVtbl.Release(l);
        }
        if added > 0 {
            void* araw = null;
            if col.lpVtbl.QueryInterface(col, &IID_IObjectArray, &araw) >= 0 {
                u16* cat = win_wide("Recent");
                ignore dl.lpVtbl.AppendCategory(dl, cat, araw);
                free(cat);
                IObjectCollection* arr = cast(IObjectCollection*, araw);
                ignore arr.lpVtbl.Release(arr);
            }
        }
        ignore col.lpVtbl.Release(col);
    }
    ignore dl.lpVtbl.CommitList(dl);
    ignore dl.lpVtbl.Release(dl);
    win_jl_publish_gone(gone, nremoved);
    free(gone);
}

// the removed folders, quotes stripped, to the UI thread
private void win_jl_publish_gone(u16* gone, u32 n) {
    if n == 0 { return; }
    noinit u8[PATH_MAX] d8;
    mutex_lock(&g_jl_mu);
    for u32 k = 0; k < n; k++ {
        u16* g = gone + cast(i32, k) * JL_ARG_MAX;
        i64 units = 0;
        while g[units] != 0 { units++; }
        if units < 3 || g[0] != '"' || g[units - 1] != '"' { continue; }
        i32 dn = win_utf8(g + 1, units - 2, &d8[0], PATH_MAX);
        if dn <= 0 { continue; }
        u8* nb = alloc<u8>(g_jl_gone_len + dn + 1);
        if g_jl_gone != null {
            memcpy(nb, g_jl_gone, g_jl_gone_len);
            free(g_jl_gone);
        }
        memcpy(nb + g_jl_gone_len, &d8[0], dn);
        nb[g_jl_gone_len + dn] = 10;
        g_jl_gone = nb;
        g_jl_gone_len += dn + 1;
    }
    mutex_unlock(&g_jl_mu);
    ignore PostMessageW(g_hwnd, WM_RECENT_REMOVED, 0, 0);
}

// the wndproc's side: each removed folder leaves the recent list
void win_jl_deliver_gone() {
    mutex_lock(&g_jl_mu);
    u8* g = g_jl_gone;
    i32 n = g_jl_gone_len;
    g_jl_gone = null;
    g_jl_gone_len = 0;
    mutex_unlock(&g_jl_mu);
    if g == null { return; }
    i32 s = 0;
    for i32 i = 0; i < n; i++ {
        if g[i] != 10 { continue; }
        if i > s { app_recent_forget(str_from(g + s, i - s)); }
        s = i + 1;
    }
    free(g);
}
