# ui_probe.ps1 - headless-ish UI check for edminc: launch, optionally send
# a Ctrl chord and/or type, screenshot, report the title, kill.
#
#   pwsh scripts/ui_probe.ps1                          # open src/edminc.mc, shot
#   pwsh scripts/ui_probe.ps1 -Type "hello`r"          # type + Enter first
#   pwsh scripts/ui_probe.ps1 -Ctrl P -Type "view`r"   # fuzzy-open a file
#   pwsh scripts/ui_probe.ps1 -Ctrl G -Shift -Type "`r"  # a chord with shift
#   pwsh scripts/ui_probe.ps1 -File doc/TESTING.md -Out x.png
#
# Typed text goes through WM_CHAR: printable chars, `r = Enter, `t = Tab,
# backspace = [char]8, [char]27 = Esc (posted as WM_KEYDOWN). Ctrl combos
# cannot be posted (the editor reads GetKeyState); -Ctrl <letter> sends a
# real chord through SendInput after foregrounding the window, which
# works in an interactive session (RDP included). A leading * in the
# reported title means the buffer is dirty, so typing can be asserted
# without pixel inspection.
param(
    [string]$File = "src/edminc.mc",
    [string]$Out = "build/ui_probe.png",
    [string]$Type = "",
    [string]$Ctrl = "",
    [switch]$Shift,          # send -Ctrl as Ctrl+Shift+<letter>
    [string]$AltAfter = "",  # Alt chord sent after typing: Left|Right|Up|Down
    [double]$Wait = 2.0,
    [string[]]$Flags = @(),  # extra editor flags, e.g. --lsp-trace ($Args is reserved)
    [string]$Log = "",       # capture the editor's stdout here
    [int]$Settle = 0         # extra ms before the shot, for work on a worker
)

$exe = Join-Path (Get-Location) "build\edmc.exe"
if (-not (Test-Path $exe)) { Write-Error "build/edmc.exe missing - run 'minc build' first"; exit 1 }

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class EdmincProbe {
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, UIntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, UIntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    // SetForegroundWindow is refused unless the caller owns the input
    // queue; attach to the current foreground thread first. Returns
    // false when there is no interactive desktop (locked session).
    public static bool Focus(IntPtr h) {
        for (int t = 0; t < 10; t++) {
            IntPtr fg = GetForegroundWindow();
            if (fg == h) return true;
            uint fgt = GetWindowThreadProcessId(fg, IntPtr.Zero);
            uint me = GetCurrentThreadId();
            AttachThreadInput(me, fgt, true);
            SetForegroundWindow(h);
            AttachThreadInput(me, fgt, false);
            System.Threading.Thread.Sleep(100);
        }
        return GetForegroundWindow() == h;
    }
    struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public KEYBDINPUT ki; public long pad; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
    // int[] instead of a byref struct: pwsh mangles byref value types.
    public static int[] Rect(IntPtr h) {
        RECT r; GetWindowRect(h, out r);
        return new int[] { r.L, r.T, r.R, r.B };
    }
    static INPUT Key(ushort vk, bool up) {
        INPUT i = new INPUT(); i.type = 1; i.ki.vk = vk;
        i.ki.flags = up ? 2u : 0u; return i;
    }
    public static uint ChordWith(ushort mod, ushort vk) {   // mod+vk, real key state
        INPUT[] seq = { Key(mod,false), Key(vk,false), Key(vk,true), Key(mod,true) };
        return SendInput(4, seq, Marshal.SizeOf(typeof(INPUT)));
    }
    public static uint Chord(ushort vk) {   // Ctrl+vk, real key state
        INPUT[] seq = { Key(0x11,false), Key(vk,false), Key(vk,true), Key(0x11,true) };
        return SendInput(4, seq, Marshal.SizeOf(typeof(INPUT)));
    }
    public static uint ChordShift(ushort vk) {   // Ctrl+Shift+vk
        INPUT[] seq = { Key(0x11,false), Key(0x10,false), Key(vk,false),
                        Key(vk,true), Key(0x10,true), Key(0x11,true) };
        return SendInput(6, seq, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@

# Per-monitor DPI aware, or window coordinates come back virtualized.
[EdmincProbe]::SetProcessDpiAwarenessContext([IntPtr]-4) | Out-Null

if ($Log -ne "") { $p = Start-Process -FilePath $exe -ArgumentList (@($Flags) + $File) -PassThru -RedirectStandardOutput $Log }
else { $p = Start-Process -FilePath $exe -ArgumentList (@($Flags) + $File) -PassThru }
Start-Sleep -Seconds $Wait
$h = $p.MainWindowHandle
if ($h -eq [IntPtr]::Zero) { Write-Error "no window"; Stop-Process -Id $p.Id -Force; exit 1 }

if ($Ctrl.Length -eq 1) {
    if (-not [EdmincProbe]::Focus($h)) {
        Write-Error "cannot focus the window (locked/disconnected session?); -Ctrl needs real input"
        Stop-Process -Id $p.Id -Force
        exit 1
    }
    if ($Shift) { [EdmincProbe]::ChordShift([uint16][char]$Ctrl.ToUpper()) | Out-Null }
    else { [EdmincProbe]::Chord([uint16][char]$Ctrl.ToUpper()) | Out-Null }
    Start-Sleep -Milliseconds 900
}

if ($Type.Length -gt 0) {
    [EdmincProbe]::SendMessage($h, 0x0007, [UIntPtr]::Zero, [IntPtr]::Zero) | Out-Null  # WM_SETFOCUS: enable caret path
    foreach ($c in [char[]]$Type) {
        if ([int]$c -eq 27) {
            [EdmincProbe]::PostMessage($h, 0x0100, [UIntPtr][uint32]27, [IntPtr]::Zero) | Out-Null  # WM_KEYDOWN VK_ESCAPE
        } else {
            [EdmincProbe]::PostMessage($h, 0x0102, [UIntPtr][uint32][int]$c, [IntPtr]::Zero) | Out-Null  # WM_CHAR
        }
    }
    Start-Sleep -Milliseconds 500
}

if ($AltAfter -ne "") {
    # a real Alt chord, after the typed text has been processed: Alt+arrows
    # arrive as WM_SYSKEYDOWN and cannot be posted any more than Ctrl can
    $vk = @{ Left = 0x25; Up = 0x26; Right = 0x27; Down = 0x28 }[$AltAfter]
    if ($null -eq $vk) { Write-Error "-AltAfter takes Left|Right|Up|Down"; Stop-Process -Id $p.Id -Force; exit 1 }
    Start-Sleep -Milliseconds 800
    [EdmincProbe]::Focus($h) | Out-Null
    Start-Sleep -Milliseconds 200
    [EdmincProbe]::ChordWith(0x12, [uint16]$vk) | Out-Null
    Start-Sleep -Milliseconds 800
}
if ($Settle -gt 0) { Start-Sleep -Milliseconds $Settle }
$r = [EdmincProbe]::Rect($h)
$bmp = New-Object System.Drawing.Bitmap(($r[2] - $r[0]), ($r[3] - $r[1]))
$g = [System.Drawing.Graphics]::FromImage($bmp)
$dc = $g.GetHdc()
[EdmincProbe]::PrintWindow($h, $dc, 2) | Out-Null   # 2 = PW_RENDERFULLCONTENT (D3D content)
$g.ReleaseHdc($dc)
$bmp.Save($Out)
$g.Dispose(); $bmp.Dispose()

$p.Refresh()
"title: [$($p.MainWindowTitle)]"
"shot:  $Out ($($r[2]-$r[0])x$($r[3]-$r[1]))"
"cpu:   $($p.CPU)s"
# A graceful close, so the editor's stdout flushes: a kill loses what
# print has buffered. Twice, since a dirty buffer refuses the first.
[EdmincProbe]::PostMessage($h, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero) | Out-Null
Start-Sleep -Milliseconds 300
[EdmincProbe]::PostMessage($h, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero) | Out-Null
if (-not $p.WaitForExit(2000)) { Stop-Process -Id $p.Id -Force }
