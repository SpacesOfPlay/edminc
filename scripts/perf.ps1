# perf.ps1 - phase-1 performance measurements: file open, keypress to
# present, sustained scroll rate. Prints a summary; raw logs land in
# build/. Run from the repo root with build/edmc.exe built.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PerfProbe {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, UIntPtr wp, IntPtr lp);
}
'@
[void][PerfProbe]::SetProcessDpiAwarenessContext([IntPtr]-4)

$root = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")).Path
$exe = Join-Path $root "build\edmc.exe"
if (-not (Test-Path $exe)) { Write-Error "build/edmc.exe missing - run 'minc build' first"; exit 1 }

function Percentile([double[]]$v, [double]$p) {
    $s = $v | Sort-Object
    $s[[math]::Min($s.Count - 1, [math]::Floor($s.Count * $p))]
}

# --- 1. file open ----------------------------------------------------
$big = Join-Path $root "build\perf_100mb.mc"
if (-not (Test-Path $big)) {
    "generating 100MB test file..."
    python -c "
line = 'state_update(frame_ctx* ctx, entity* items, world_grid* grid) marker\n'
chunk = line * 4096
with open(r'$big', 'wb') as f:
    n = 0
    while n < 100 * 1024 * 1024:
        f.write(chunk.encode())
        n += len(chunk)
"
}
$bigcrlf = Join-Path $root "build\perf_100mb_crlf.mc"
if (-not (Test-Path $bigcrlf)) {
    python -c "
line = 'state_update(frame_ctx* ctx, entity* items, world_grid* grid) marker\r\n'
chunk = line * 4096
with open(r'$bigcrlf', 'wb') as f:
    n = 0
    while n < 100 * 1024 * 1024:
        f.write(chunk.encode())
        n += len(chunk)
"
}
"--- open ---"
foreach ($f in @($big, $bigcrlf, (Join-Path $root "src\ed.mc"))) {
    $out = & $exe $f --smoke
    $mb = [math]::Round((Get-Item $f).Length / 1MB, 1)
    "  $(Split-Path -Leaf $f) (${mb} MB): $out"
}

# --- 2. keypress to present ------------------------------------------
"--- input latency ---"
$log = Join-Path $root "build\perf_lat.log"
$p = Start-Process $exe -ArgumentList (Join-Path $root "src\ed.mc"), "--time" `
    -RedirectStandardOutput $log -PassThru
Start-Sleep -Seconds 1.5
[void][PerfProbe]::SetForegroundWindow($p.MainWindowHandle)
Start-Sleep -Milliseconds 300
$sk = [System.Windows.Forms.SendKeys]
foreach ($i in 1..40) {
    $sk::SendWait([char](97 + ($i % 26)))
    Start-Sleep -Milliseconds 60
}
Stop-Process -Id $p.Id -Force
Start-Sleep -Milliseconds 300
$lat = Select-String -Path $log -Pattern 'char_to_present_us (\d+)' |
    ForEach-Object { [double]$_.Matches[0].Groups[1].Value / 1000.0 }
if ($lat.Count -gt 0) {
    "  samples $($lat.Count)  median $([math]::Round((Percentile $lat 0.5), 2)) ms  " +
    "p95 $([math]::Round((Percentile $lat 0.95), 2)) ms  max $([math]::Round(($lat | Measure-Object -Maximum).Maximum, 2)) ms"
} else {
    "  no samples captured"
}

# --- 3. sustained scroll at 4K ---------------------------------------
"--- scroll ---"
$log2 = Join-Path $root "build\perf_scroll.log"
$p = Start-Process $exe -ArgumentList $big, "--time" -RedirectStandardOutput $log2 -PassThru
Start-Sleep -Seconds 2
$scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
[void][PerfProbe]::SetWindowPos($p.MainWindowHandle, [IntPtr]::Zero, $scr.X, $scr.Y, $scr.Width, $scr.Height, 0x0004)
"  window $($scr.Width)x$($scr.Height)"
Start-Sleep -Seconds 1.5
$h = $p.MainWindowHandle
$wp = [UIntPtr][uint32]4287102976   # 0xFF880000: wheel delta -120 in the high word
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$sent = 0
while ($sw.ElapsedMilliseconds -lt 5000) {
    [void][PerfProbe]::PostMessage($h, 0x020A, $wp, [IntPtr]::Zero)
    $sent++
    Start-Sleep -Milliseconds 1
}
Start-Sleep -Milliseconds 500
Stop-Process -Id $p.Id -Force
Start-Sleep -Milliseconds 300
$paints = Select-String -Path $log2 -Pattern 'paint_us (-?\d+) dur (\d+)' |
    ForEach-Object { [double]$_.Matches[0].Groups[1].Value }
$durs = Select-String -Path $log2 -Pattern 'paint_us (-?\d+) dur (\d+)' |
    ForEach-Object { [double]$_.Matches[0].Groups[2].Value / 1000.0 }
if ($paints.Count -gt 10) {
    # intervals over the busy window (drop the first and last few)
    $iv = @()
    for ($i = 4; $i -lt $paints.Count - 2; $i++) { $iv += ($paints[$i] - $paints[$i - 1]) / 1000.0 }
    $med = Percentile $iv 0.5
    "  wheel events sent: $sent  paints: $($paints.Count)"
    "  frame interval: median $([math]::Round($med, 2)) ms  p95 $([math]::Round((Percentile $iv 0.95), 2)) ms  -> $([math]::Round(1000.0 / $med, 1)) fps"
    "  render dur: median $([math]::Round((Percentile $durs 0.5), 2)) ms  p95 $([math]::Round((Percentile $durs 0.95), 2)) ms"
} else {
    "  not enough paints captured"
}
