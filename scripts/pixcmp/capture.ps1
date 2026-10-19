# capture.ps1 - render pixel comparison, capture step. Opens the test
# text in edminc and in VS Code (isolated profile, Consolas 16px, Dark+,
# letterSpacing tuned so both apps land on the same 9px integer
# grid), parks both on a 96-dpi screen, and screenshots them into
# build/pixcmp/. Then: python scripts/pixcmp/compare.py build/pixcmp
param([string]$Which = "both",   # edminc | code | both
      [switch]$Native,           # both apps at the screen's own dpi
      [string]$Settings = "")    # vscode settings json (default: vscode_settings.json)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PixProbe {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public KEYBDINPUT ki; public long pad; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
    public static int[] Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return new int[] { r.L, r.T, r.R, r.B }; }
    // SetForegroundWindow is refused unless the caller owns the input
    // queue; attach to the current foreground thread first.
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
    static INPUT Key(ushort vk, bool up) {
        INPUT i = new INPUT(); i.type = 1; i.ki.vk = vk;
        i.ki.flags = up ? 2u : 0u; return i;
    }
    public static uint Chord(ushort vk) {   // Ctrl+vk, real key state
        INPUT[] seq = { Key(0x11,false), Key(vk,false), Key(vk,true), Key(0x11,true) };
        return SendInput(4, seq, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@
[void][PixProbe]::SetProcessDpiAwarenessContext([IntPtr]-4)

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path (Join-Path $dir "..\..")).Path
$out = Join-Path $root "build\pixcmp"
New-Item -ItemType Directory -Force $out | Out-Null
$file = Join-Path $dir "render_test.txt"

function Find-Screen96 {
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $f = New-Object System.Windows.Forms.Form
        $f.StartPosition = 'Manual'
        $f.ShowInTaskbar = $false
        $f.FormBorderStyle = 'None'
        $f.Location = New-Object System.Drawing.Point(($s.Bounds.X + 60), ($s.Bounds.Y + 60))
        $f.Size = New-Object System.Drawing.Size(120, 80)
        $f.Show()
        Start-Sleep -Milliseconds 150
        $dpi = $f.DeviceDpi
        $f.Close(); $f.Dispose()
        if ($dpi -eq 96) { return $s }
    }
    return $null
}

function Shoot([IntPtr]$h, [string]$path) {
    $r = [PixProbe]::Rect($h)
    $bmp = New-Object System.Drawing.Bitmap(($r[2]-$r[0]), ($r[3]-$r[1]))
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $dc = $g.GetHdc()
    [void][PixProbe]::PrintWindow($h, $dc, 2)
    $g.ReleaseHdc($dc)
    $bmp.Save($path)
    $g.Dispose(); $bmp.Dispose()
}

$scr = $null
$force1 = $false
if ($Native) {
    # Both apps at the screen's own dpi. The glyph grid is then whatever
    # that dpi produces, which is not the 9px one the default settings
    # are tuned for: pass -Settings with a letterSpacing matched to it,
    # and compare.py the advance it lands on.
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen
    "native dpi on $($scr.DeviceName) $($scr.Bounds)"
} else {
    $scr = Find-Screen96
}
if ((-not $scr) -and (-not $Native)) {
    # No 96-dpi screen (a 150% panel, say). Render both apps at scale 1
    # on whatever screen there is instead: edminc takes --dpi 96 and
    # Chromium --force-device-scale-factor=1, so both still put Consolas
    # 16px on the same 9px grid of physical pixels. Numbers from a
    # forced run compare to each other, not to ones taken on a real
    # 96-dpi screen.
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen
    $force1 = $true
    "no 96-dpi screen; forcing both apps to scale 1 on $($scr.DeviceName) $($scr.Bounds)"
} elseif (-not $Native) {
    "using $($scr.DeviceName) $($scr.Bounds)"
}
$X = $scr.Bounds.X + 60
$Y = $scr.Bounds.Y + 60

if ($Which -eq 'edminc' -or $Which -eq 'both') {
    $exe = Join-Path $root "build\edmc.exe"
    if (-not (Test-Path $exe)) { Write-Error "build/edmc.exe missing - run 'minc build' first"; exit 1 }
    $edArgs = @($file)
    if ($force1) { $edArgs += @('--dpi', '96') }
    $p = Start-Process $exe -ArgumentList $edArgs -PassThru
    Start-Sleep -Seconds 1.5
    [void][PixProbe]::SetWindowPos($p.MainWindowHandle, [IntPtr]::Zero, $X, $Y, 1200, 800, 0x0004)
    Start-Sleep -Seconds 1.2
    # The file tree would sit in the frame and the geometry pass would
    # lock onto its rows instead of the editor text, so close it. Real
    # input: the editor reads GetKeyState, so a posted chord will not do.
    if ([PixProbe]::Focus($p.MainWindowHandle)) {
        [void][PixProbe]::Chord(0x42)   # Ctrl+B
        Start-Sleep -Milliseconds 600
    } else {
        Write-Warning "could not focus edminc; the tree stays open and the geometry pass will miss"
    }
    Shoot $p.MainWindowHandle (Join-Path $out "edminc.png")
    Stop-Process -Id $p.Id -Force
    "edminc captured"
}

if ($Which -eq 'code' -or $Which -eq 'both') {
    $udd = Join-Path $out "vscode_profile"
    New-Item -ItemType Directory -Force (Join-Path $udd "User") | Out-Null
    $sfile = if ($Settings -ne "") { $Settings } else { Join-Path $dir "vscode_settings.json" }
    Copy-Item $sfile (Join-Path $udd "User\settings.json") -Force
    $codeArgs = @('--user-data-dir', $udd, '--extensions-dir', (Join-Path $udd "ext"),
                  '--disable-workspace-trust', '--new-window')
    if ($force1) { $codeArgs += '--force-device-scale-factor=1' }
    $codeArgs += $file
    & code @codeArgs | Out-Null
    $cw = $null
    foreach ($i in 1..60) {
        Start-Sleep -Milliseconds 500
        $cand = Get-Process code -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*render_test*" }
        if ($cand) { $cw = $cand | Select-Object -First 1; break }
    }
    if (-not $cw) { Write-Error "vscode window not found"; exit 1 }
    Start-Sleep -Seconds 2
    [void][PixProbe]::SetWindowPos($cw.MainWindowHandle, [IntPtr]::Zero, $X, $Y, 1200, 800, 0x0004)
    Start-Sleep -Seconds 2.5
    Shoot $cw.MainWindowHandle (Join-Path $out "code.png")
    Stop-Process -Id $cw.Id -Force
    "code captured"
}
