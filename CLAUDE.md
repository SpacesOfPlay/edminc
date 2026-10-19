# edminc

A native code editor and IDE for minc, written in minc. The UI follows
VS Code. The hard constraints are performance properties: zero work at
idle, one-frame input latency, and scrolling at the full refresh rate.
Windows, macOS and Linux have native platform layers, and a browser
build runs the same core as a wasm module. The binary is `edmc`,
named the way VS Code is launched as `code`.

## Read first

- `doc/TECH_DOC.md`: how the editor works, the architecture, the platform
  layer, and the source map.
- `doc/TESTING.md`: the test harness and fuzzer, headless runs, the probe
  scripts, and debugging.
- `AGENTS.md`: a general minc quick reference.
- `CLAUDE.local.md`, if it exists (gitignored): machine-local notes
  that stay out of the repo.

## Layout

- `src/`: the portable editor. `edminc.mc` is the manifest and
  `main()`; `ed.mc` the core and the `app_*` entries; `view.mc` the
  frame build. `ed_test.mc` and `ed_fuzz.mc` are the test harness and
  the fuzzer.
- `lib/`: the platform contract (`plat.mc`), the four platform layers,
  the quad batch, fonts, theme and UI primitives.
- `scripts/`: the soak driver and the probe scripts (doc/TESTING.md).
- `web/`: the browser page, its host script and the LSP worker.
- `install/`: the install and update scripts. `dist/`: the README that
  ships in the release archive. `assets/`: fonts and icons.
- `build.mc`: the build script behind the `minc` verbs.

## Build and run

```
minc run [file.mc]        # build and open the editor
minc build                # build/edmc
minc build install        # build, then install to ~/.edminc like a release
minc test                 # build, ed_test, four fuzz seeds, a smoke frame
minc test fuzz [args]     # the long fuzz soaks (scripts/fuzz.mc, arguments passed on)
minc wasm [--no-browser]  # browser build, served on port 8080
minc clean
```

build.mc finds the compiler through `MINC`, then PATH (install it from
https://minc.dev). Only `run|build|test|clean|wasm|bench` reach
build.mc; the compiler treats any other verb as a filename. `import`
resolves against the project's `lib/` first, then the installed
compiler's lib. Stdlib modules are not vendored.

The page's language server, minc_lsp_web.wasm, is not in the installed
toolchain; the toolchain's playground build produces it. build.mc
stages it from `MINC_LSP_WASM` or from the compiler's directory, with
the project's stdlib import closure under build/web/lsplib. Without it
the page runs with no language server.

`edmc --version` prints `edminc <EDMINC_VERSION>`. The constant is in
src/edminc.mc. A release fails when it disagrees with the tag, and the
installer compares it to decide whether an installed copy is current.
Bump it in the same commit as the tag.

`minc build install` stages the release archive's layout under
build/install and passes it to `install/install` (`install.ps1` on
Windows) with `--from`, so a local build installs by the same code as
a download. The archive also carries `edmc_update`, which re-runs the
installer. The installer unlinks the old files before it copies: on
macOS, a binary written over one that a running editor holds is killed
at every later launch, and the running editor dies with it. Its
version check runs the binary without a pipe, because a pipe hides
that kill. The copies served from minc.dev/edminc/install are made
from `install/`. The repo is the source of truth: copy a change to the
site.

On Windows, `minc build` replaces a running editor. It renames the old
image to build/edmc.old.exe (numbered while one is still held) and
gives the new build the name. Windows allows the rename but refuses
the write.

## Rules

- This repo is open source; the minc compiler is not. Docs, comments
  and commit messages must not reference compiler internals, only the
  public surface of the installed toolchain.
- The editor uses OS APIs only. Anything else is vendored as minc
  source (doc/TECH_DOC.md "Dependency policy").
- Run `minc test` after every change. New editing behaviour gets a
  check in ed_test.mc. Keep the harness portable: after changing it,
  type-check it with `minc --target <linux|linux-arm64|macos|wasm>
  src/ed_fuzz.mc -o /tmp/x`, and the same for src/ed_test.mc and
  scripts/fuzz.mc.
- Idle is zero wakeups: a blocking message loop, a render only on
  damage, a caret blink timer that stops itself about 7 s after the
  last input. No polling and no continuous render loop. Check with
  `(Get-Process -Name edmc).CPU` over about 10 s; it must stay flat.
- Nothing on the UI thread waits for a worker or for the language
  server. Sends to the server go through a writer thread
  (doc/TESTING.md, "Debugging").
- Test a restart (Ctrl+K X) in a scratch folder. Every editor with the
  folder open races to take the restart request.
- Text is UTF-8 everywhere inside the editor. UTF-16 exists only in the
  Windows platform modules, at the API boundary.

## Style

- Comments: short, neutral, direct and technical. Short sentences in
  the active voice and the present tense. State what the code cannot
  say, such as an invariant or an API quirk. Use the technical term
  for a thing, not a metaphor: "the interface between the stack and
  the driver", not "the seam"; "the thread waits", not "the thread
  parks and the card wakes it". No history and no plans in comments.
  doc/TECH_DOC.md holds the current limitations.
- Docs: the same voice, one idea per sentence. List what is necessary
  and nothing else. No bold claims. Use em-dashes sparingly.
- Code: explicit types by default; `var` only where the right side
  already names the type. Named constants instead of magic numbers.
  `private` on module-internal symbols. Index with `p[i]`, not
  `*(p + i)`.

## minc gotchas

- `from` and `fn` are reserved keywords, not identifiers.
- `get_arg(i)` returns `u8*` (C string), not `str`. Wrap it in
  `str_from_cstr()`. `get_argc()` returns i32.
- `alloc<T>(n)` does NOT zero memory. Call memset yourself. Locals,
  structs, and arrays declared without an initializer ARE zeroed.
- Arithmetic on u8 promotes: `p[i] = v << 2;` needs `cast(u8, ...)`.
- String equality is `str_equal()` (stdlib `str` module), not str_eq.
- There is no `__wide_literal` builtin. Use `win_wide()` from
  lib/win.mc for UTF-16 literals.
- Bounds checking is on by default. A wild-pointer segfault usually
  happens in foreign code reached through an FFI call, not in minc
  code.

## Git

- The user commits and pushes manually. Stage changes, but do not
  commit unless explicitly asked.
- Commit messages: short lowercase summaries in the style of the
  log. No AI attribution of any kind (no Co-Authored-By, no session
  links).
