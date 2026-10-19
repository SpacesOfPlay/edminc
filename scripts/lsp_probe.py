# lsp_probe.py - talk to minc-lsp over stdio and print what it answers,
# for telling a server problem from an editor one without the editor.
#   python scripts/lsp_probe.py def <file> <line0> <col>   definition at a position
#   python scripts/lsp_probe.py body <file> <prefix>       completion of <prefix> in a fresh
#                                                          function body appended to the file
#   python scripts/lsp_probe.py ws <file> <query>          workspace/symbol
#   python scripts/lsp_probe.py sym <file> [name ...]      documentSymbol, reports the names
#   python scripts/lsp_probe.py at <file> "<line>" <col>   append a typed line, definition at col
#   python scripts/lsp_probe.py atc <file> "<line>" <col>  same, but completion
#   python scripts/lsp_probe.py sig <file> "<line>" <col>   signatureHelp on a typed line
#   python scripts/lsp_probe.py sem <file>                  semantic tokens: decodes the
#                                                           deltas and reports the line offset
#                                                           each token actually lands on
#   python scripts/lsp_probe.py prepare <file> <line0> <col> prepareCallHierarchy at a position
#   python scripts/lsp_probe.py in <file> <line0> <col>     prepare, then incomingCalls on the item
#   python scripts/lsp_probe.py out <file> <line0> <col>    prepare, then outgoingCalls on the item
# Every reply prints its round-trip time. LSP_EXE names the server binary
# (default: minc-lsp on PATH).
# LSP_PREOPEN=a,b opens those files first; LSP_POSTOPEN after; LSP_WAIT and
# LSP_WAIT2 sleep after initialized and after didOpen.
import json, subprocess, sys, os, time

NL = chr(10)
mode, path = sys.argv[1], sys.argv[2]
root = os.getcwd().replace(os.sep, "/")
base = open(path, encoding="utf-8").read()
if not base.endswith(NL):
    base += NL

if mode in ("def", "prepare", "in", "out"):
    line, col = int(sys.argv[3]), int(sys.argv[4])
    text = base
elif mode in ("ws", "sym", "sem"):
    text = base
    line, col = 0, 0
elif mode in ("at", "atc", "sig"):
    # append a typed line and ask at a column on it, as a user would;
    # "at" asks for the definition, "atc" for completion
    typed, col = sys.argv[3], int(sys.argv[4])
    text = base + typed + NL
    line = base.count(NL)
else:
    pre = sys.argv[3]
    text = base + "void probe_fn() {" + NL + "    " + pre + NL + "}" + NL
    line, col = base.count(NL) + 1, 4 + len(pre)

p = subprocess.Popen([os.environ.get("LSP_EXE", "minc-lsp")], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=open(os.environ["LSP_STDERR"], "ab") if os.environ.get("LSP_STDERR") else subprocess.DEVNULL)
t_sent = {}


def send(o):
    if "id" in o:
        t_sent[o["id"]] = time.perf_counter()
    b = json.dumps(o).encode()
    p.stdin.write(("Content-Length: %d" % len(b)).encode() + b"\r\n\r\n" + b)
    p.stdin.flush()


def recv():
    hdr = b""
    while not hdr.endswith(b"\r\n\r\n"):
        c = p.stdout.read(1)
        if not c:
            return None
        hdr += c
    n = 0
    for l in hdr.decode().split("\r\n"):
        if l.lower().startswith("content-length"):
            n = int(l.split(":")[1])
    return json.loads(p.stdout.read(n))


uri = "file:///%s/%s" % (root, path)
send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"processId": None, "rootUri": "file:///" + root, "capabilities": {}}})
while True:
    m = recv()
    if m and m.get("id") == 1:
        res = m.get("result") or {}
        print("init: serverInfo=%r caps=%s" % (res.get("serverInfo"), sorted((res.get("capabilities") or {}).keys())))
        break
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
time.sleep(float(os.environ.get("LSP_WAIT", "0")))
def open_doc(rel):
    t = open(rel, encoding="utf-8").read()
    send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
          "params": {"textDocument": {"uri": "file:///%s/%s" % (root, rel), "languageId": "minc", "version": 1, "text": t}}})
for rel in [x for x in os.environ.get("LSP_PREOPEN", "").split(",") if x]:
    open_doc(rel)
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": uri, "languageId": "minc", "version": 1, "text": text}}})
for rel in [x for x in os.environ.get("LSP_POSTOPEN", "").split(",") if x]:
    open_doc(rel)
time.sleep(float(os.environ.get("LSP_WAIT2", "0")))
method = "textDocument/definition" if mode in ("def", "at") else "textDocument/completion"
if mode == "sig":
    method = "textDocument/signatureHelp"
pre = typed[typed.rfind("(") + 1:] if mode == "atc" else (sys.argv[3] if mode == "body" else "")
if mode in ("prepare", "in", "out"):
    send({"jsonrpc": "2.0", "id": 2, "method": "textDocument/prepareCallHierarchy",
          "params": {"textDocument": {"uri": uri}, "position": {"line": line, "character": col}}})
elif mode == "ws":
    send({"jsonrpc": "2.0", "id": 2, "method": "workspace/symbol", "params": {"query": sys.argv[3]}})
elif mode == "sym":
    send({"jsonrpc": "2.0", "id": 2, "method": "textDocument/documentSymbol", "params": {"textDocument": {"uri": uri}}})
elif mode == "sem":
    send({"jsonrpc": "2.0", "id": 2, "method": "textDocument/semanticTokens/full", "params": {"textDocument": {"uri": uri}}})
else:
    send({"jsonrpc": "2.0", "id": 2, "method": method,
          "params": {"textDocument": {"uri": uri}, "position": {"line": line, "character": col}}})
while True:
    m = recv()
    if m is None:
        print("server closed")
        break
    if "id" not in m:
        print("notify: %s %s" % (m.get("method"), json.dumps(m.get("params"))[:300]))
        continue
    if "id" in m and m["id"] in t_sent:
        print("  (%s: %.1f ms)" % (m["id"], (time.perf_counter() - t_sent.pop(m["id"])) * 1000))
    if m.get("id") == 2 and mode in ("prepare", "in", "out"):
        if "error" in m:
            print("prepareCallHierarchy at %s:%d:%d -> error %s" % (path, line, col, m["error"]))
            break
        items = m.get("result") or []
        print("prepareCallHierarchy at %s:%d:%d -> %d item(s)" % (path, line, col, len(items)))
        for it in items:
            rg = it.get("range", {})
            print("  %s  %s  lines %d-%d  detail=%r" % (it.get("name"), it.get("uri"),
                  rg.get("start", {}).get("line", -1), rg.get("end", {}).get("line", -1), it.get("detail")))
        if mode == "prepare" or not items:
            break
        send({"jsonrpc": "2.0", "id": 3, "method": "callHierarchy/incomingCalls" if mode == "in" else "callHierarchy/outgoingCalls",
              "params": {"item": items[0]}})
        continue
    if m.get("id") == 3:
        if "error" in m:
            print("  error %s" % m["error"])
            break
        rows = m.get("result") or []
        key = "from" if mode == "in" else "to"
        print("%s -> %d row(s)" % ("incomingCalls" if mode == "in" else "outgoingCalls", len(rows)))
        for row in rows[:int(os.environ.get("LSP_ROWS", "40"))]:
            it = row.get(key, {})
            fr = row.get("fromRanges", [])
            print("  %-28s %s:%d  sites %s" % (it.get("name"), it.get("uri", "").rsplit("/", 1)[-1],
                  it.get("selectionRange", {}).get("start", {}).get("line", -1) + 1,
                  [r["start"]["line"] + 1 for r in fr]))
        break
    if m.get("id") == 2:
        r = m.get("result")
        if mode == "sym":
            names = [it.get("name") for it in (r or [])]
            want = sys.argv[3:]
            print("documentSymbol %s -> %d symbols; wanted present: %s" % (path, len(names), {w: (w in names) for w in want}))
            print("  first 10:", names[:10])
        elif mode == "ws":
            print("workspace/symbol %r -> %d results" % (sys.argv[3], len(r or [])))
            for it in (r or [])[:8]:
                print("  %s  %s" % (it.get("name"), (it.get("location") or {}).get("uri")))
        elif mode == "sem":
            import re
            data = (r or {}).get("data") or []
            src = text.split(NL)
            ident = re.compile("^[A-Za-z_][A-Za-z_0-9]*$")
            toks = []
            ln_, col_ = 0, 0
            for i in range(0, len(data) - 4, 5):
                dl, dc, n, ty, mod = data[i:i+5]
                if dl > 0:
                    ln_ += dl
                    col_ = dc
                else:
                    col_ += dc
                toks.append((ln_, col_, n))
            def fits(l, c, n):
                if l >= len(src):
                    return False
                t = src[l][c:c+n]
                return len(t) == n and bool(ident.match(t))
            if not toks:
                print("semanticTokens %s -> empty; raw result: %s" % (path, json.dumps(r)[:200]))
            print("semanticTokens %s -> %d tokens" % (path, len(toks)))
            for off in (0, 1, 2, 3):
                print("  offset +%d: %d land on an identifier" % (off, sum(1 for t in toks if fits(t[0]+off, t[1], t[2]))))
            bad = next((t for t in toks if not fits(t[0], t[1], t[2]) and fits(t[0]+1, t[1], t[2])), None)
            if bad:
                print("  first token that only fits one line lower: 0-based line %d col %d -> %r"
                      % (bad[0], bad[1], src[bad[0]+1][bad[1]:bad[1]+bad[2]]))
        elif mode == "sig":
            print("signatureHelp at %s:%d:%d ->" % (path, line, col))
            print(json.dumps(r, indent=1)[:1500])
        elif mode in ("def", "at"):
            print("definition at %s:%d:%d ->" % (path, line, col))
            print(json.dumps(r, indent=1)[:1200])
        else:
            items = r.get("items") if isinstance(r, dict) else (r or [])
            print("%d items for %r in %s (%s)" % (len(items), pre, path, mode))
            labs = [it["label"] for it in items]
            print("  first 15:", labs[:15])
            print("  sortText:", [(it.get("label"), it.get("sortText"), it.get("kind")) for it in items[:12]])
            print("  lower-prefix matches:", [l for l in labs if l.lower().startswith(pre.lower())][:15])
        break
p.kill()
