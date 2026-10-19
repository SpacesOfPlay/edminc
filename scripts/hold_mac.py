#!/usr/bin/env python3
"""hold_mac.py - a held caret key under smooth scrolling, on macOS.

Writes a play script of Down keys (src/evscript.mc's format), runs
build/edmc on a file with --play at the key repeat rate and --time, and
reads the frame log: the frame cadence, the render time, the wait for
the drawable and the trail each frame drew. Run from the repo root.

  python3 scripts/hold_mac.py [--gap-ms 33] [--seconds 6] [--file src/ed.mc]
"""
import argparse, os, statistics, struct, subprocess, sys, time

K_DOWN = 259

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gap-ms", type=float, default=33.0)
    ap.add_argument("--seconds", type=float, default=6.0)
    ap.add_argument("--file", default="src/ed.mc")
    a = ap.parse_args()
    os.makedirs("build", exist_ok=True)
    n = int(a.seconds * 1000 / a.gap_ms)
    b = bytearray(bytes([7]) + struct.pack("<ii", 1200, 800))   # EV_RESIZE
    for _ in range(n):
        b += bytes([2]) + struct.pack("<ii", K_DOWN, 0)          # EV_KEY
        b += bytes([14])                                         # EV_STEP
    script = "build/hold_mac.evs"
    log = "build/hold_mac.log"
    open(script, "wb").write(b)
    with open(log, "w") as out:
        p = subprocess.Popen(["build/edmc", a.file, "--play", script,
                              "--play-ms", str(int(a.gap_ms)), "--time"],
                             stdout=out, stderr=subprocess.STDOUT)
        time.sleep(a.seconds + 2.5)
        p.kill()
    paints = []
    for line in open(log):
        f = line.split()
        if line.startswith("paint_us") and len(f) >= 8:
            paints.append((int(f[1]), int(f[3]), int(f[5]), int(f[7])))
    if len(paints) < 10:
        print("too few frames in the log:", len(paints)); sys.exit(1)
    mid = paints[len(paints) // 3: 2 * len(paints) // 3]
    gaps = [(mid[i + 1][0] - mid[i][0]) / 1000 for i in range(len(mid) - 1)]
    print("frames %d, in the middle third:" % len(paints))
    print("  frame gap ms  min %.1f  median %.1f  max %.1f" % (min(gaps), statistics.median(gaps), max(gaps)))
    print("  render us     median %d  max %d" % (statistics.median(p[1] for p in mid), max(p[1] for p in mid)))
    print("  drawable wait median %d  max %d" % (statistics.median(p[3] for p in mid), max(p[3] for p in mid)))
    print("  trail px      " + " ".join(str(p[2]) for p in mid[:24]))

if __name__ == "__main__":
    main()
