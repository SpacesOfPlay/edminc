# stall_watch.ps1 - watch a running edmc for UI-thread stalls and dump
# native stacks when one happens. It only observes, so it does not take
# focus: drive the editor by hand as usual.
#
#   pwsh scripts/stall_watch.ps1 [-Ms 1500] [-Out build/stalls]
#
# A stall is measured as the round trip of a WM_NULL through the
# editor's message loop, which is exactly what a frozen UI blocks.
# Idle does not register: an idle loop answers immediately.
param([int]$Ms = 1500, [string]$Out = "build/stalls")
$ErrorActionPreference = 'Stop'
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(
     IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
}
'@
[void][W]::SetProcessDpiAwarenessContext([IntPtr]-4)
New-Item -ItemType Directory -Force $Out | Out-Null

$p = Get-Process edmc -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { Write-Error "no edmc process; start the editor first"; exit 1 }
"watching pid $($p.Id), stalls over $Ms ms -> $Out"
"drive the editor by hand; ctrl+c to stop"
$n = 0
while ($true) {
    $p.Refresh()
    if ($p.HasExited) { "editor exited"; break }
    $h = $p.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200; continue }
    # A short timeout is the point: when it expires the loop is still
    # stuck, so the sample lands during the stall rather than after it.
    $r = [IntPtr]::Zero
    $t = [Diagnostics.Stopwatch]::StartNew()
    $ok = [W]::SendMessageTimeout($h, 0x0000, [IntPtr]0, [IntPtr]0, 0x0000, $Ms, [ref]$r)
    if ($ok -eq [IntPtr]::Zero) {
        $n++
        $stamp = Get-Date -Format "HHmmss"
        $f = Join-Path $Out "stall_$stamp.txt"
        "STALL (still blocked after $Ms ms) -> $f"
        & python scripts/stacks.py $p.Id 2>&1 | Out-File -Encoding utf8 $f
        # wait for it to come back so one stall is one report
        $r2 = [IntPtr]::Zero
        [void][W]::SendMessageTimeout($h, 0x0000, [IntPtr]0, [IntPtr]0, 0x0000, 120000, [ref]$r2)
        "  recovered after {0:N0} ms total" -f $t.Elapsed.TotalMilliseconds
    }
    Start-Sleep -Milliseconds 100
}
"stalls seen: $n"
