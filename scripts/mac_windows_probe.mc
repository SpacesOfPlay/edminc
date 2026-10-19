// mac_windows_probe.mc - the on-screen windows of a process, through
// CGWindowListCopyWindowInfo, which needs neither the screen-recording
// nor the accessibility permission. Run from the repo root:
//
//   minc scripts/mac_windows_probe.mc -o build/mac_windows_probe
//   build/mac_windows_probe <pid>
//
// One line per layer-0 window with its bounds in points (top-left
// origin, as CoreGraphics reports them) and its title when the system
// hands one out (it withholds titles without the screen-recording
// permission), then the count. This is how multi-window is checked
// headless here: --newwin or a Cmd+K N through --key, then this.

import str;

private struct CGRectP {
    f64 x;
    f64 y;
    f64 w;
    f64 h;
}

extern "CoreGraphics" {
    void* CGWindowListCopyWindowInfo(u32 option, u32 relative);
    bool CGRectMakeWithDictionaryRepresentation(void* dict, CGRectP* out);
}
extern "CoreFoundation" {
    i64 CFArrayGetCount(void* arr);
    void* CFArrayGetValueAtIndex(void* arr, i64 i);
    void* CFDictionaryGetValue(void* d, void* key);
    bool CFNumberGetValue(void* n, i64 type, void* out);
    bool CFStringGetCString(void* s, u8* buf, i64 size, u32 enc);
    void CFRelease(void* cf);
}
extern "CoreGraphics" void* kCGWindowOwnerPID;
extern "CoreGraphics" void* kCGWindowLayer;
extern "CoreGraphics" void* kCGWindowName;
extern "CoreGraphics" void* kCGWindowBounds;

private const u32 kCGWindowListOptionOnScreenOnly = 1;
private const i64 kCFNumberSInt64Type = 4;
private const u32 kCFStringEncodingUTF8 = 0x08000100;

i32 main() {
    if get_argc() < 2 {
        print("usage: mac_windows_probe <pid>\n");
        return 2;
    }
    str a = str_from_cstr(get_arg(1));
    i64 want = 0;
    for i32 i = 0; i < a.len; i++ {
        if a.data[i] < '0' || a.data[i] > '9' { break; }
        want = want * 10 + cast(i64, a.data[i] - '0');
    }
    void* list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, 0);
    if list == null {
        print("no window list\n");
        return 1;
    }
    i64 n = CFArrayGetCount(list);
    i32 count = 0;
    for i64 i = 0; i < n; i++ {
        void* d = CFArrayGetValueAtIndex(list, i);
        void* pidn = CFDictionaryGetValue(d, kCGWindowOwnerPID);
        void* layn = CFDictionaryGetValue(d, kCGWindowLayer);
        if pidn == null || layn == null { continue; }
        i64 pid = 0;
        i64 layer = 0;
        ignore CFNumberGetValue(pidn, kCFNumberSInt64Type, cast(void*, &pid));
        ignore CFNumberGetValue(layn, kCFNumberSInt64Type, cast(void*, &layer));
        if pid != want || layer != 0 { continue; }
        noinit u8[512] name;
        name[0] = 0;
        void* nm = CFDictionaryGetValue(d, kCGWindowName);
        if nm != null { ignore CFStringGetCString(nm, &name[0], 512, kCFStringEncodingUTF8); }
        CGRectP r;
        void* bd = CFDictionaryGetValue(d, kCGWindowBounds);
        if bd != null { ignore CGRectMakeWithDictionaryRepresentation(bd, &r); }
        print("window {} x {} y {} w {} h {} title '{}'\n", count,
            cast(i32, r.x), cast(i32, r.y), cast(i32, r.w), cast(i32, r.h), str_from_cstr(&name[0]));
        count++;
    }
    CFRelease(list);
    print("count {}\n", count);
    return 0;
}
