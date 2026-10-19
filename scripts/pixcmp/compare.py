import os
import sys
import numpy as np
from PIL import Image
from measure import load, text_mask, line_bands, m_band_index, advance_of

# Per-glyph pixel comparison between edminc.png and code.png (produced
# by capture.ps1). Both apps render Consolas 16px on the same integer
# grid; glyph cells anchor on the M line, and each pair is aligned by
# a small (dx, dy) search before the diff. The advance is read off the
# capture, since it follows the dpi the run was taken at (9px at 96,
# 13px at 144); pass it as a second argument to override. Usage:
#   python scripts/pixcmp/compare.py build/pixcmp [advance]

ADV = 9
LINES = [
    (1, "m w a e g s o l i t x z v k"),
    (2, "the quick brown fox jumps over the lazy dog pack my box"),
    (3, "alpha bravo delta echo golf hotel india juliet kilo lima"),
    (4, "Illegal mixed weight minimum alignment howl jowl WWWWW llll"),
    (5, "(parens) {braces} [brackets] semi; comma, dot. dash- plus"),
]

def geometry(path):
    img = load(path)
    mask = text_mask(img)
    bands = line_bands(mask)
    mi = m_band_index(mask, bands)
    a, b = bands[mi]
    prof = mask[a:b, :].sum(axis=0)
    on = prof > (b - a) * 0.30
    edges = [x for x in range(1, len(on)) if on[x] and not on[x - 1]]
    return img, bands, mi, edges[0]

def crop(img, x0, y0, w, h):
    H, W, _ = img.shape
    out = np.zeros((h, w, 3), np.int32) + 30
    xs, ys = max(0, x0), max(0, y0)
    xe, ye = min(W, x0 + w), min(H, y0 + h)
    out[ys - y0:ye - y0, xs - x0:xe - x0] = img[ys:ye, xs:xe]
    return out

def best_align(tmpl, region, rx, ry):
    th, tw, _ = tmpl.shape
    best = (1 << 60, 0, 0)
    for dy in range(-ry, ry + 1):
        for dx in range(-rx, rx + 1):
            sub = region[ry + dy:ry + dy + th, rx + dx:rx + dx + tw]
            sad = int(np.abs(sub - tmpl).sum())
            if sad < best[0]:
                best = (sad, dx, dy)
    return best

def main():
    global ADV
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    if len(sys.argv) > 2:
        ADV = int(sys.argv[2])
    else:
        ADV = int(round(advance_of(os.path.join(d, "edminc.png"))["advance"]))
    print(f"advance: {ADV}px")
    m_img, m_bands, m_mi, m_x0 = geometry(os.path.join(d, "edminc.png"))
    c_img, c_bands, c_mi, c_x0 = geometry(os.path.join(d, "code.png"))

    results = []
    for rel, text in LINES:
        mb = m_bands[m_mi + rel]
        cb = c_bands[c_mi + rel]
        mh = mb[1] - mb[0]
        for i, ch in enumerate(text):
            if ch == " ":
                continue
            pad = 2
            tw, th = ADV + 2 * pad, mh + 2 * pad
            tmpl = crop(m_img, m_x0 + i * ADV - pad, mb[0] - pad, tw, th)
            rx, ry = 3, 5
            region = crop(c_img, c_x0 + i * ADV - pad - rx, cb[0] - pad - ry,
                          tw + 2 * rx, th + 2 * ry)
            sad, dx, dy = best_align(tmpl, region, rx, ry)
            sub = region[ry + dy:ry + dy + th, rx + dx:rx + dx + tw]
            diff = np.abs(sub - tmpl)
            npx = tw * th
            results.append({
                "ch": ch, "line": rel, "col": i, "dx": dx, "dy": dy,
                "mean": diff.mean(), "max": int(diff.max()),
                "pct24": 100.0 * (diff.max(axis=2) > 24).sum() / npx,
                "meanR": diff[:, :, 0].mean(),
                "meanG": diff[:, :, 1].mean(),
                "meanB": diff[:, :, 2].mean(),
            })

    means = np.array([r["mean"] for r in results])
    dxs = np.array([r["dx"] for r in results])
    dys = np.array([r["dy"] for r in results])
    print(f"glyphs compared: {len(results)}")
    print(f"alignment dx: median {np.median(dxs):.0f} spread {dxs.min()}..{dxs.max()}")
    print(f"alignment dy: median {np.median(dys):.0f} spread {dys.min()}..{dys.max()}")
    print(f"mean abs diff (0..255): avg {means.mean():.2f}  median {np.median(means):.2f}  worst {means.max():.2f}")
    print(f"per channel avg: R {np.mean([r['meanR'] for r in results]):.2f}  "
          f"G {np.mean([r['meanG'] for r in results]):.2f}  "
          f"B {np.mean([r['meanB'] for r in results]):.2f}")
    print(f"pixels differing >24 levels: avg {np.mean([r['pct24'] for r in results]):.1f}%")
    worst = sorted(results, key=lambda r: -r["mean"])[:8]
    print("worst glyphs:")
    for r in worst:
        print(f"  '{r['ch']}' line+{r['line']} col {r['col']}: mean {r['mean']:.1f} "
              f"max {r['max']} >24: {r['pct24']:.0f}% (dx {r['dx']}, dy {r['dy']})")

    # composite: first 26 chars of the pangram, rows edminc / code /
    # |diff| x4, scaled 6x
    rel, text = LINES[1]
    mb = m_bands[m_mi + rel]
    cb = c_bands[c_mi + rel]
    nchars = 26
    pad = 2
    w = nchars * ADV + 2 * pad
    h = 20
    dxm = int(np.median(dxs))
    dym = int(np.median(dys))
    a = crop(m_img, m_x0 - pad, mb[0] - 2, w, h)
    b = crop(c_img, c_x0 - pad + dxm, cb[0] - 2 + dym, w, h)
    diff = np.clip(np.abs(a - b) * 4, 0, 255)
    gap = np.zeros((4, w, 3), np.int32) + 90
    stack = np.vstack([a, gap, b, gap, diff]).astype(np.uint8)
    im = Image.fromarray(stack).resize((w * 6, stack.shape[0] * 6), Image.NEAREST)
    outpath = os.path.join(d, "compare_out.png")
    im.save(outpath)
    print(f"wrote {outpath} (rows: edminc, code, |diff| x4)")

if __name__ == "__main__":
    main()
