# latency.ps1 - input-to-display latency, measured with the DXGI frame
# statistics. The script posts WM_BENCH messages that carry its QPC
# count; edmc --time matches each frame with the refresh that showed it
# and prints the time from the oldest and the newest input in the frame.
# Run from the repo root with build/edmc.exe built. A Remote Desktop
# session shows the window through its own display driver, so measure
# at the machine.
param([string]$Dir = (Join-Path $env:TEMP "edmc_latency"), [string]$Only = "")
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LatProbe {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, UIntPtr wp, IntPtr lp);
}
'@
[void][LatProbe]::SetProcessDpiAwarenessContext([IntPtr]-4)

$root = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")).Path
$exe = Join-Path $root "build\edmc.exe"
if (-not (Test-Path $exe)) { Write-Error "build/edmc.exe missing - run 'minc build' first"; exit 1 }

# a copy in a scratch folder, so the session and the typing stay out of the repo
New-Item -ItemType Directory -Force $Dir | Out-Null
$file = Join-Path $Dir "ed.mc"
Copy-Item (Join-Path $root "src\ed.mc") $file -Force

$WM_BENCH = 0x8002
$BENCH_WHEEL = 0
$BENCH_CHAR = 1
$BENCH_FLUSH = 2

function Percentile([double[]]$v, [double]$p) {
    $s = $v | Sort-Object
    $s[[math]::Min($s.Count - 1, [math]::Floor($s.Count * $p))]
}

function Stat([double[]]$v) {
    if ($v.Count -eq 0) { return "-" }
    "{0,5:N1} / {1,5:N1} / {2,5:N1}" -f (Percentile $v 0.5), (Percentile $v 0.95), ($v | Measure-Object -Maximum).Maximum
}

# posts $count inputs of $kind, on average one every $gapUs
# microseconds, paced by spinning on the QPC clock. Each gap varies by
# half its length either way, so the inputs fall at every phase of the
# refresh and not at one.
$rng = [System.Random]::new(1)
function Drive($h, $kind, $count, $gapUs) {
    $freq = [System.Diagnostics.Stopwatch]::Frequency
    $next = [System.Diagnostics.Stopwatch]::GetTimestamp()
    for ($i = 0; $i -lt $count; $i++) {
        while ([System.Diagnostics.Stopwatch]::GetTimestamp() -lt $next) { }
        $t = [System.Diagnostics.Stopwatch]::GetTimestamp()
        [void][LatProbe]::PostMessage($h, $WM_BENCH, [UIntPtr][uint32]$kind, [IntPtr]$t)
        $next += [int64]($gapUs * (0.5 + $rng.NextDouble()) * $freq / 1000000)
    }
    # the last frames reach the screen after the input stops; the flush
    # messages make the editor read the statistics again
    foreach ($i in 1..10) {
        Start-Sleep -Milliseconds 30
        [void][LatProbe]::PostMessage($h, $WM_BENCH, [UIntPtr][uint32]$BENCH_FLUSH, [IntPtr]0)
    }
    Start-Sleep -Milliseconds 200
}

function Run($name, $kind, $count, $gapUs) {
    if ($Only -and $name -ne $Only) { return }
    $log = Join-Path $Dir "lat_$name.log"
    $p = Start-Process $exe -ArgumentList $file, "--time" -RedirectStandardOutput $log -PassThru
    Start-Sleep -Seconds 2
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $h = $p.MainWindowHandle
    [void][LatProbe]::SetWindowPos($h, [IntPtr]::Zero, $scr.X, $scr.Y, $scr.Width, $scr.Height, 0x0004)
    [void][LatProbe]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 800
    Drive $h $kind $count $gapUs
    Stop-Process -Id $p.Id -Force
    Start-Sleep -Milliseconds 300
    $old = @(); $new = @(); $pres = @()
    foreach ($m in (Select-String -Path $log -Pattern 'bench_frame old_us (-?\d+) new_us (-?\d+) pres_us (-?\d+)')) {
        $g = $m.Matches[0].Groups
        $old += [double]$g[1].Value / 1000.0
        $new += [double]$g[2].Value / 1000.0
        $pres += [double]$g[3].Value / 1000.0
    }
    $miss = @(Select-String -Path $log -Pattern 'bench_miss').Count
    "{0,-12} frames {1,4} missed {2,3} | oldest {3} | newest {4} | to present {5}" -f `
        $name, $old.Count, $miss, (Stat $old), (Stat $new), (Stat $pres)
}

"input to display, ms as median / p95 / max; 'to present' ends when Present returns"
Run "keys-100ms" $BENCH_CHAR 40 100000
Run "keys-33ms" $BENCH_CHAR 90 33333
Run "wheel-8ms" $BENCH_WHEEL 500 8000
Run "wheel-2ms" $BENCH_WHEEL 1500 2000
