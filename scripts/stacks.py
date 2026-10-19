# stacks.py - native stack sampler for a hung process, for when the
# editor stops responding and there is no debugger on the machine.
#
#   python scripts/stacks.py <pid> [tid ...]
#
# Suspends each thread, reads RIP/RSP, and scans the stack for values
# that land inside a loaded module. There are no symbols: what it gives
# you is the module each frame is in, plus the RVA for edmc.exe
# frames, against image base 0x400000.
#
# Reading it: a thread parked in GetMessageW is idle and fine. One in
# WaitForSingleObject with edminc frames under it is blocked on
# something the editor asked for, which is what a freeze looks like.
# Compare the thread count against a healthy instance first: the D3D11
# driver keeps a pool of its own, so a high count means nothing on its
# own.
# Suspends each thread, reads RIP/RSP, scans the stack for values that
# land inside a loaded module, and prints them as candidate frames.
# No symbols: the point is which module (and which edminc RVA) each
# frame is in.
import ctypes as C
import ctypes.wintypes as W
import sys

k32 = C.WinDLL("kernel32", use_last_error=True)
psapi = C.WinDLL("psapi", use_last_error=True)

PROCESS_ALL = 0x1F0FFF
THREAD_ALL = 0x1F03FF
CONTEXT_CONTROL_INTEGER = 0x100003

k32.OpenProcess.restype = W.HANDLE
k32.OpenThread.restype = W.HANDLE
k32.CreateToolhelp32Snapshot.restype = W.HANDLE


class THREADENTRY32(C.Structure):
    _fields_ = [("dwSize", W.DWORD), ("cntUsage", W.DWORD),
                ("th32ThreadID", W.DWORD), ("th32OwnerProcessID", W.DWORD),
                ("tpBasePri", C.c_long), ("tpDeltaPri", C.c_long),
                ("dwFlags", W.DWORD)]


class MODULEINFO(C.Structure):
    _fields_ = [("lpBaseOfDll", C.c_void_p), ("SizeOfImage", W.DWORD),
                ("EntryPoint", C.c_void_p)]


def modules(hp):
    arr = (C.c_uint64 * 1024)()
    need = W.DWORD()
    if not psapi.EnumProcessModulesEx(hp, arr, C.sizeof(arr), C.byref(need), 3):
        return []
    out = []
    for i in range(need.value // 8):
        h = C.c_void_p(arr[i])
        name = C.create_unicode_buffer(260)
        psapi.GetModuleBaseNameW(hp, h, name, 260)
        mi = MODULEINFO()
        psapi.GetModuleInformation(hp, h, C.byref(mi), C.sizeof(mi))
        out.append((arr[i], mi.SizeOfImage, name.value))
    return sorted(out)


def which(mods, addr):
    for base, size, name in mods:
        if base <= addr < base + size:
            return name, addr - base
    return None, 0


def thread_ids(pid):
    snap = k32.CreateToolhelp32Snapshot(0x00000004, 0)
    te = THREADENTRY32()
    te.dwSize = C.sizeof(te)
    ids = []
    if k32.Thread32First(snap, C.byref(te)):
        while True:
            if te.th32OwnerProcessID == pid:
                ids.append(te.th32ThreadID)
            if not k32.Thread32Next(snap, C.byref(te)):
                break
    k32.CloseHandle(snap)
    return ids


def context_of(ht):
    buf = (C.c_ubyte * (1232 + 16))()
    addr = C.addressof(buf)
    aligned = (addr + 15) & ~15
    C.memset(aligned, 0, 1232)
    C.c_uint32.from_address(aligned + 0x30).value = CONTEXT_CONTROL_INTEGER
    if not k32.GetThreadContext(ht, C.c_void_p(aligned)):
        return None
    rsp = C.c_uint64.from_address(aligned + 0x98).value
    rbp = C.c_uint64.from_address(aligned + 0xA0).value
    rip = C.c_uint64.from_address(aligned + 0xF8).value
    return rip, rsp, rbp


def read(hp, addr, n):
    buf = (C.c_ubyte * n)()
    got = C.c_size_t()
    if not k32.ReadProcessMemory(hp, C.c_void_p(addr), buf,
                                 n, C.byref(got)):
        return b""
    return bytes(buf[:got.value])


def main():
    pid = int(sys.argv[1])
    want = [int(x) for x in sys.argv[2:]] if len(sys.argv) > 2 else None
    hp = k32.OpenProcess(PROCESS_ALL, False, pid)
    if not hp:
        print("OpenProcess failed", C.get_last_error())
        return
    mods = modules(hp)
    print(f"modules: {len(mods)}")
    for b, s, n in mods:
        if "edminc" in n.lower():
            print(f"  {n} base 0x{b:x} size 0x{s:x}")
    for tid in thread_ids(pid):
        if want and tid not in want:
            continue
        ht = k32.OpenThread(THREAD_ALL, False, tid)
        if not ht:
            continue
        k32.SuspendThread(ht)
        ctx = context_of(ht)
        if ctx is None:
            k32.ResumeThread(ht)
            k32.CloseHandle(ht)
            continue
        rip, rsp, rbp = ctx
        mn, rva = which(mods, rip)
        print(f"\ntid {tid}  rip 0x{rip:x} [{mn}+0x{rva:x}]  rsp 0x{rsp:x}")
        data = read(hp, rsp, 4096)
        seen = []
        for off in range(0, len(data) - 8, 8):
            v = int.from_bytes(data[off:off + 8], "little")
            n2, r2 = which(mods, v)
            if n2 is None:
                continue
            tag = f"{n2}+0x{r2:x}"
            if seen and seen[-1] == tag:
                continue
            seen.append(tag)
            print(f"    +0x{off:04x}  {tag}")
            if len(seen) > 24:
                break
        k32.ResumeThread(ht)
        k32.CloseHandle(ht)
    k32.CloseHandle(hp)


main()
