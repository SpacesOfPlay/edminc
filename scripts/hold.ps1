# hold.ps1 - a held caret key under smooth scrolling, on Windows. Starts
# build/edmc.exe on a copy of src/ed.mc with --time, moves the caret to
# the bottom edge, sends VK_DOWN presses every -GapMs for -Seconds (the
# repeat rate of a held key: 33 ms at the default setting), and reads
# the frame log: the frame cadence, the trail each frame drew and the
# motion per frame it implies. Steady motion is one value. -JitterMs
# varies the gaps as a keyboard's timer does. -Hz switches the display
# to that refresh rate for the run, without saving it, and restores the
# saved mode after. Run from the repo root, at the machine.
param(
    [double]$GapMs = 33.3,
    [double]$Seconds = 3.0,
    [double]$JitterMs = 0.0,
    [int]$Hz = 0,
    [string]$Tag = "run",
    [string]$Dir = (Join-Path $env:TEMP "edmc_hold")
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class HoldProbe {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
    public delegate bool EnumCb(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumCb cb, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
    // the first top-level window of the editor's class
    public static IntPtr FindEditor() {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            var sb = new System.Text.StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "edmincWindow") { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public KEYBDINPUT ki; public long pad; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public static void Key(ushort vk, bool up) {
        INPUT[] a = new INPUT[1];
        a[0].type = 1;
        a[0].ki.wVk = vk;
        a[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }
    // the display mode: DEVMODEW is 220 bytes, dmSize at 68, dmFields at
    // 72 and dmDisplayFrequency at 184
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplaySettingsW(string dev, int mode, IntPtr dm);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int ChangeDisplaySettingsExW(string dev, IntPtr dm, IntPtr hwnd, uint flags, IntPtr param);
    static IntPtr Mode() {
        IntPtr p = Marshal.AllocHGlobal(2048);
        for (int i = 0; i < 2048; i++) Marshal.WriteByte(p, i, 0);
        Marshal.WriteInt16(p, 68, (short)220);
        EnumDisplaySettingsW(null, -1, p);
        return p;
    }
    public static int Hz() { IntPtr p = Mode(); int hz = Marshal.ReadInt32(p, 184); Marshal.FreeHGlobal(p); return hz; }
    public static int SetHz(int hz) {
        IntPtr p = Mode();
        Marshal.WriteInt32(p, 184, hz);
        Marshal.WriteInt32(p, 72, 0x400000);   // DM_DISPLAYFREQUENCY
        int r = ChangeDisplaySettingsExW(null, p, IntPtr.Zero, 0, IntPtr.Zero);
        Marshal.FreeHGlobal(p);
        return r;
    }
    public static int RestoreHz() { return ChangeDisplaySettingsExW(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero); }
}
'@
[void][HoldProbe]::SetProcessDpiAwarenessContext([IntPtr]-4)

$root = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")).Path
$exe = Join-Path $root "build\edmc.exe"
if (-not (Test-Path $exe)) { Write-Error "build/edmc.exe missing - run 'minc build' first"; exit 1 }
New-Item -ItemType Directory -Force $Dir | Out-Null
$file = Join-Path $Dir "ed.mc"
Copy-Item (Join-Path $root "src\ed.mc") $file -Force
$log = Join-Path $Dir "hold_$Tag.log"

function Percentile([double[]]$v, [double]$p) {
    $s = $v | Sort-Object
    $s[[math]::Min($s.Count - 1, [math]::Floor($s.Count * $p))]
}

function Hist($values) {
    $h = @{}
    foreach ($v in $values) { if ($h.ContainsKey($v)) { $h[$v]++ } else { $h[$v] = 1 } }
    ($h.Keys | Sort-Object | ForEach-Object { "$_`:$($h[$_])" }) -join " "
}

$was = [HoldProbe]::Hz()
if ($Hz -gt 0 -and $Hz -ne $was) {
    $r = [HoldProbe]::SetHz($Hz)
    if ($r -ne 0) { Write-Error "ChangeDisplaySettingsEx($Hz Hz) returned $r"; exit 1 }
    Start-Sleep -Seconds 2
}
"display $([HoldProbe]::Hz()) Hz"
try {
    # the log goes to a file through cmd: a pipe read by this script
    # stalls the editor's prints while the script spins on the clock
    $p = Start-Process cmd -ArgumentList "/c", "`"`"$exe`" `"$file`" --time > `"$log`"`"" -WindowStyle Hidden -PassThru
    $h = [IntPtr]::Zero
    for ($i = 0; $i -lt 50 -and $h -eq [IntPtr]::Zero; $i++) {
        Start-Sleep -Milliseconds 100
        $h = [HoldProbe]::FindEditor()
    }
    if ($h -eq [IntPtr]::Zero) { Write-Error "no editor window"; exit 1 }
    Start-Sleep -Seconds 1
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    [void][HoldProbe]::SetWindowPos($h, [IntPtr]::Zero, $scr.X, $scr.Y, $scr.Width, $scr.Height, 0x0004)
    [void][HoldProbe]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 800

    # the caret to the bottom of the view, so each repeat scrolls a line
    [HoldProbe]::Key(0x22, $false); [HoldProbe]::Key(0x22, $true)
    Start-Sleep -Milliseconds 300

    $rng = [System.Random]::new(7)
    $freq = [System.Diagnostics.Stopwatch]::Frequency
    $next = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $end = $next + [int64]($Seconds * $freq)
    $n = 0
    while ($next -lt $end) {
        while ([System.Diagnostics.Stopwatch]::GetTimestamp() -lt $next) { }
        [HoldProbe]::Key(0x28, $false)
        $n++
        $gap = $GapMs + ($rng.NextDouble() * 2.0 - 1.0) * $JitterMs
        $next += [int64]($gap * $freq / 1000.0)
    }
    [HoldProbe]::Key(0x28, $true)
    Start-Sleep -Milliseconds 400
    Get-Process -Name edmc -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300
} finally {
    if ($Hz -gt 0 -and $Hz -ne $was) {
        [void][HoldProbe]::RestoreHz()
        "display restored to $([HoldProbe]::Hz()) Hz"
    }
}

$paints = @()
foreach ($m in (Select-String -Path $log -Pattern 'paint_us (\d+) dur (\d+) glide (-?\d+)')) {
    $g = $m.Matches[0].Groups
    $paints += [pscustomobject]@{ t = [int64]$g[1].Value; dur = [int64]$g[2].Value; glide = [int]$g[3].Value }
}
$gaps = @()
foreach ($m in (Select-String -Path $log -Pattern 'key_us \d+ gap_us (\d+)')) {
    $v = [double]$m.Matches[0].Groups[1].Value / 1000.0
    if ($v -lt 200) { $gaps += $v }
}
"$Tag : keys sent $n, paints $($paints.Count), log $log"
if ($gaps.Count -gt 0) {
    "key gap ms: p50 $([math]::Round((Percentile $gaps 0.5),1)) min $([math]::Round(($gaps | Measure-Object -Minimum).Minimum,1)) max $([math]::Round(($gaps | Measure-Object -Maximum).Maximum,1))"
}
$gl = @($paints | Where-Object { $_.glide -ne 0 })
if ($gl.Count -lt 3) { "too few glide frames"; exit }
$first = $gl[0].t; $last = $gl[-1].t
$run = @($paints | Where-Object { $_.t -ge $first -and $_.t -le $last })
$iv = @(); for ($i = 1; $i -lt $run.Count; $i++) { $iv += ($run[$i].t - $run[$i-1].t) / 1000.0 }
"frames in run $($run.Count) over $([math]::Round(($last - $first) / 1000.0)) ms: $([math]::Round($run.Count * 1000000.0 / ($last - $first), 1)) fps"
"frame interval ms: p50 $([math]::Round((Percentile $iv 0.5), 2)) p90 $([math]::Round((Percentile $iv 0.9), 2)) max $([math]::Round(($iv | Measure-Object -Maximum).Maximum, 2))"
"frame interval histogram (ms: frames): " + (Hist ($iv | ForEach-Object { [math]::Round($_) }))
$dur = $run | ForEach-Object { $_.dur / 1000.0 }
"render ms: p50 $([math]::Round((Percentile $dur 0.5), 2)) max $([math]::Round(($dur | Measure-Object -Maximum).Maximum, 2))"
"frames that drew no trail (view arrived, waiting): $(@($run | Where-Object { $_.glide -eq 0 }).Count)"
# the motion per frame: the trail's decrease, plus a line where a key
# step raised the trail
# the first glide frame trails by the line height
$lh = [math]::Max(16, ($gl | Select-Object -First 1).glide)
$mot = @()
for ($i = 1; $i -lt $run.Count; $i++) {
    $m = $run[$i - 1].glide - $run[$i].glide
    if ($m -lt -($lh / 4)) { $m += $lh }
    $mot += $m
}
"motion per frame histogram (px: frames): " + (Hist $mot)
"trail per frame (first 80): " + (($run | Select-Object -First 80 | ForEach-Object { $_.glide }) -join " ")
foreach ($pat in 'frame_wait_timeout', 'frame_nested_unsignalled', 'paint_pre_us', 'slow_msg') {
    $c = @(Select-String -Path $log -Pattern $pat).Count
    if ($c -gt 0) { "$pat : $c" }
}
