"""Drive the browser build headless: serve it, load the page in Edge
through Playwright, screenshot it, type into it, and measure idle
activity. Usage: python scripts/web_probe.py [--out build/web.png]
[--keep]. Needs Playwright (pip install playwright) and Edge; the
server is `minc wasm --no-browser`, started here and stopped after.
Exit code 1 on any console error or a failed check."""
import argparse
import subprocess
import sys
import time
import urllib.request

from playwright.sync_api import sync_playwright

URL = "http://127.0.0.1:8080/index.html?app=edminc"

# Records what the language server sends, as text, for the checks that
# read its diagnostics: the page hands the worker's replies to the
# editor, which draws them but does not expose them.
LSP_HOOK = r"""
(() => {
  const dec = new TextDecoder('utf-8');
  window.__lspRecv = [];
  const OrigWorker = window.Worker;
  window.Worker = function (url, opts) {
    const w = new OrigWorker(url, opts);
    w.addEventListener('message', (e) => {
      const m = e.data;
      if (m && m.type === 'recv') window.__lspRecv.push(dec.decode(m.bytes));
    });
    return w;
  };
})();
"""


def wait_for_server(timeout=60.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            urllib.request.urlopen("http://127.0.0.1:8080/index.html", timeout=1).read()
            return True
        except Exception:
            time.sleep(0.25)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="build/web.png")
    ap.add_argument("--keep", action="store_true", help="leave the server running")
    ap.add_argument("--idle", type=float, default=3.0, help="seconds of idle to measure")
    args = ap.parse_args()

    # a server left over from an earlier run would serve stale files and
    # hold the build binary; refuse rather than probe the wrong thing
    if wait_for_server(timeout=0.5):
        print("FAIL something already serves on port 8080; stop it first")
        return 1
    flags = subprocess.CREATE_NEW_PROCESS_GROUP if sys.platform == "win32" else 0
    srv = subprocess.Popen(["minc", "wasm", "--no-browser"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, creationflags=flags)
    fails = []
    try:
        if not wait_for_server():
            print("FAIL server did not come up")
            return 1
        with sync_playwright() as p:
            browser = p.chromium.launch(channel="msedge", headless=True, args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader"])
            page = browser.new_page(viewport={"width": 1200, "height": 800}, device_scale_factor=1)
            page.add_init_script(LSP_HOOK)
            console = []
            page.on("console", lambda m: console.append((m.type, m.text)))
            page.on("pageerror", lambda e: console.append(("pageerror", str(e))))
            page.on("response", lambda r: console.append(("http", "%d %s" % (r.status, r.url))) if r.status >= 400 else None)
            page.goto(URL)
            page.wait_for_function("window.edminc !== undefined", timeout=60000)
            time.sleep(1.0)
            title0 = page.title()
            stats0 = page.evaluate("({frames: edminc.stats.frames, ticks: edminc.stats.timerTicks, log: edminc.stats.log.join('')})")
            page.screenshot(path=args.out)
            print("title:", title0)
            print("frames after load:", stats0["frames"], "timer ticks:", stats0["ticks"])
            if stats0["log"].strip():
                print("editor stdout:", stats0["log"].strip())
            if stats0["frames"] < 1:
                fails.append("no frame rendered after load")
            if "edminc" not in title0:
                fails.append("title not set by the editor: " + title0)

            # typing lands: the title gains the dirty mark
            page.click("#canvas", position={"x": 600, "y": 400})
            page.keyboard.type("hello")
            time.sleep(0.3)
            title1 = page.title()
            print("title after typing:", title1)
            if not title1.startswith("*"):
                fails.append("typing did not dirty the buffer (title " + title1 + ")")
            # the picker opens on the primary chord and closes on Escape
            page.keyboard.press("Control+P")
            time.sleep(0.2)
            page.screenshot(path=args.out.replace(".png", "_picker.png"))
            page.keyboard.press("Escape")
            time.sleep(0.2)

            # the language server, when the build staged one: the editor
            # starts it on the first .mc file, must hear back, and a word
            # start must draw a completion reply
            page.goto(URL + "&file=src/ed.mc")
            page.wait_for_function("window.edminc !== undefined", timeout=60000)
            time.sleep(1.0)
            lsp = page.evaluate("({out: edminc.stats.lspOut, inn: edminc.stats.lspIn})")
            if lsp["out"] > 0:
                page.wait_for_function("edminc.stats.lspIn > 0", timeout=60000)
                # a definition in another file, from a file opened cold:
                # the page hands the server the workspace list instead of
                # a root to walk, and a server too old to take it answers
                # every cross-file jump with nothing while same-file ones
                # still work. LANG_YAML is defined in lexer.mc and used in
                # ed.mc; the title says where the jump landed.
                target = None
                with open("src/ed.mc", "r", encoding="utf-8") as f:
                    for i, line in enumerate(f):
                        c = line.find("return LANG_YAML")
                        if c >= 0:
                            target = (i, c + len("return "))
                            break
                if target is None:
                    fails.append("src/ed.mc no longer mentions LANG_YAML; pick another cross-file symbol")
                else:
                    before = page.evaluate("edminc.stats.lspIn")
                    page.evaluate("""([line, col]) => {
                        const ex = edminc.exports;
                        ex.web_key(262, 1);                                  // ctrl+home
                        for (let i = 0; i < line; i++) ex.web_key(259, 0);   // down
                        for (let i = 0; i < col; i++) ex.web_key(257, 0);    // right
                        ex.web_key(267, 0);                                  // F12
                    }""", list(target))
                    try:
                        page.wait_for_function("edminc.stats.lspIn > %d" % before, timeout=30000)
                    except Exception:
                        fails.append("no reply from the language server to a definition request")
                    time.sleep(1.0)
                    if not page.title().startswith("lexer.mc"):
                        fails.append("a cross-file definition did not land in lexer.mc (title %r); the staged language server may predate minc/workspaceFiles" % page.title())
                    else:
                        print("language server: cross-file definition landed in lexer.mc")
                before = page.evaluate("edminc.stats.lspIn")
                page.click("#canvas", position={"x": 600, "y": 400})
                page.keyboard.press("End")
                page.keyboard.press("Enter")
                page.keyboard.type("tb_")
                try:
                    page.wait_for_function("edminc.stats.lspIn > %d" % before, timeout=30000)
                except Exception:
                    fails.append("no reply from the language server to a completion request")
                time.sleep(0.5)
                page.screenshot(path=args.out.replace(".png", "_lsp.png"))
                lsp = page.evaluate("({out: edminc.stats.lspOut, inn: edminc.stats.lspIn})")
                print("language server: %d messages out, %d in" % (lsp["out"], lsp["inn"]))
                page.keyboard.press("Escape")

                # a stdlib import resolves: the server looks for lib/<name>.mc
                # relative to its working directory, the project root, and
                # the worker has to resolve that against the files it holds
                page.goto(URL + "&file=src/watch.mc")
                page.wait_for_function("window.edminc !== undefined", timeout=60000)
                page.wait_for_function("edminc.stats.lspIn > 0", timeout=60000)
                time.sleep(3.0)
                recv = "".join(page.evaluate("window.__lspRecv"))
                if "cannot find library" in recv:
                    fails.append("a stdlib import did not resolve on the page (src/watch.mc imports thread)")
                else:
                    print("language server: stdlib imports resolve")
            else:
                print("language server: none on this page")

            # idle: the blink timer stops itself about seven seconds after
            # the last input; after that nothing may run
            time.sleep(8.0)
            s1 = page.evaluate("({frames: edminc.stats.frames, ticks: edminc.stats.timerTicks})")
            time.sleep(args.idle)
            s2 = page.evaluate("({frames: edminc.stats.frames, ticks: edminc.stats.timerTicks})")
            print("idle over %.1fs: frames %d, timer ticks %d" % (args.idle, s2["frames"] - s1["frames"], s2["ticks"] - s1["ticks"]))
            if s2["frames"] != s1["frames"] or s2["ticks"] != s1["ticks"]:
                fails.append("not idle: work ran with no input")

            errors = [c for c in console if c[0] in ("error", "pageerror")]
            for c in console:
                print("console %s: %s" % c)
            if errors:
                fails.append("%d console errors" % len(errors))
            browser.close()
    finally:
        if not args.keep:
            # the compiler's server is a grandchild: take the whole tree
            if sys.platform == "win32":
                subprocess.run(["taskkill", "/F", "/T", "/PID", str(srv.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            else:
                srv.kill()
    for f in fails:
        print("FAIL", f)
    print("web probe:", "FAILED" if fails else "ok")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
