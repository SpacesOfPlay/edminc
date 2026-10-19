# edminc — tests, headless runs and debugging

How to test the editor, drive it without a human at the keyboard, and
debug it. CLAUDE.md has the build commands and the rules; TECH_DOC.md
describes the behaviour these checks exercise.

## Tests

- `minc test` runs the build, then `src/ed_test.mc`, then
  `src/ed_fuzz.mc` (four short seeds of generated input, see below),
  then `edmc src/edminc.mc --smoke`. ed_test runs headless checks of
  the editor core through the app_* entries and needs no window. It
  also holds the terminal's cases, written as bytes in and the screen
  as text out, with ^ for escape, ` for bell and | for backspace. The
  smoke run renders one frame, prints vert/line counts and load/frame
  times, and exits 0. Run `minc test` after every change. New editing
  behavior gets a check in ed_test.mc. On macOS the smoke path renders
  directly without entering the event loop, so it is safe headless.
- `src/ed_fuzz.mc` fuzzes the same core. A seeded PRNG drives weighted
  user actions through the app_* entries. A mock language server
  replies with responses that range from valid to hostile:
  out-of-range positions, every uri shape, junk frames, and framing
  split at random offsets. After each step the fuzzer checks the
  editor invariants and the quad batch that view.mc built, so it
  reports both textual and graphical failures. It also runs oracles,
  which check that a result is correct and not only in range. An undo
  run paired with an equal redo run must restore the text. The
  incremental lex cache must agree with a full relex from line 0. A
  cursor column must survive typing: cursors on distinct lines at one
  visual column form a rectangle, and a character typed into each
  line must leave a rectangle one column over. This oracle detects
  multi-cursor drift. The state checks cannot, because drifted cursors
  are in range and do not overlap.
  The seed picks each run's window from four screen classes, 1200x800
  up to 3840x2160. A 4K frame uses about 250k of the batch's 600k
  vertices. The resize action ranges up to the same size. The summary
  line names the size, so a failure reproduces at it.
  The undo oracle counts key presses, not journal entries. One press
  undoes a multi-cursor group, so counting entries would redo past the
  start of the undo run. The fuzzer never writes to disk: Ctrl+S and
  save-as are not in the action table.
  `minc test fuzz [--count N] [--steps N] [--seeds a,b]` runs the
  soaks: it builds scripts/fuzz.mc as build/fuzz and passes the
  arguments on, so `build/fuzz` can be run directly afterwards.
  The driver shrinks each failure to its minimal step count by
  bisecting `--steps`. This works because the action stream is a pure
  function of the seed. The driver is a minc program that talks to the
  fuzzer across the process boundary, so the harness is the same on
  every platform and contains no shell script. A failure prints the
  state, the visible text, and an ink map of the frame. `--trace`
  writes unbuffered, so its output survives a hard fault; `print`
  output does not. The caret must sit where decoding its line lands;
  this was opt-in while definition responses were read as byte
  columns, and holds always now that they are converted from utf-16.
  `--twice` runs each clean seed again and requires the same frame
  hash, which detects nondeterminism. `--replay` records each clean
  seed and replays the script, and requires the same frame hash, which
  detects input the script does not carry. `--hashes` prints the seed and
  frame hash on each line. Run it on two platforms and diff the
  output; the lines must agree byte for byte. They agree because
  directory listings are sorted (dir_sort in pick.mc), so a seed means
  the same thing on every platform.
- The fuzzer's terminal family feeds a screen generated control
  sequences mixed with junk, in chunks of random size. It calls
  term_check after every step. term_check requires the cursor inside
  the screen, the scroll region inside the screen, the scrollback
  inside the ring, and no half of a two-cell glyph without the other.
  Two coverage states belong to the family: "terminal open" and
  "alternate screen".
- The fuzzer's explode family opens the explode view, walks the grid,
  types into the filter, and picks a tile by Enter or a click, or
  leaves with Escape, the chord or a click elsewhere, or leaves the
  view open for the next action. Every frame with the view up draws its
  tiles, so the frame checks cover the scaled quads: their u is read
  back through the -u - 1 mark. Its coverage state is "explode view".
- The fuzzer's changes-view family opens the view, walks and clicks its
  rows to open diffs, and runs the pane and buffer actions a user takes
  with a diff up: focus, Ctrl+W, Ctrl+Shift+W, split, the pane move,
  the change walk and a click in the editor. Each is one step, so the
  list and the diff's second pane arrive between them. Every step
  checks that an open diff has two panes with the file's pane active,
  and that the active buffer is a slot in the table. Its coverage state
  is "diff open". The watch family sends the file watcher's
  records (tracked, ignored, git, junk and lost) and fires the refresh.
- The fuzzer also checks the traffic it sends. Every outgoing frame
  must be framed and parse, carry jsonrpc 2.0 and a method, use ids
  that advance, name an absolute file uri, and keep didOpen before
  didChange with a rising version. The fuzzer keeps a shadow document
  per didOpen (src/lsp_shadow.mc) and applies each didChange's
  contentChanges to it as the server does. After every push the
  shadow must equal the buffer byte for byte. This verifies the ranged
  edits of incremental sync. The mock grants incremental sync on half
  the seeds and full sync on the rest, and `--coverage` counts the
  incremental ones. The mock returns semantic tokens in eight shapes.
  Five are hostile: negative deltas, a span past the line, an
  out-of-order stream, a type past the legend, and junk. A coverage
  state counts the runs that held tokens. The fuzzer checks frames as
  they are written, not at the mock's step, because the buffer changes
  within the step. These checks give the coverage a real server would
  give by accepting the traffic. The harness does not start a real
  server: the stdlib has no streaming child process, and linking the
  platform layer into a headless binary would lose the harness's
  portability.
- `edmc <file> --play <script> [--play-ms N]` plays a dumped run in
  the live window, one fuzzer step per timer tick (default 20 ms).
  Use it to watch or record a fuzz run:
  `build/ed_fuzz --seed 1 --steps 400 --dump-script build/s.evs` then
  `build/edmc doc/TESTING.md --play build/s.evs`. It is not a faithful
  replay. The window keeps its size, dpi and focus, the real server
  replies instead of the mock, and the player skips the settle waits.
  Clicks therefore land where the live layout puts them. Pass
  `--dpi 96` for the layout the run was recorded against. A script
  begins with the run's own resize. The window opens at that size when
  the screen has room for it and maximized otherwise, since the sizes
  go up to 4K. The player skips later resizes in the run. The event
  kinds live in src/evscript.mc, which the fuzzer and the player
  (src/play.mc) share.
- `--coverage` reports the action families and editor states a run
  reached. `build/fuzz --coverage` sums them over seeds and fails when
  a counter is never reached, which detects a gap in the action table.
  It also fails when a run fails, and names the seed: a run that stops
  early reports only the counters it reached.
- `--dump-script <f>` writes the run as a replayable list of primitive
  events. `--script <f>` replays it with no prng and no mock, and a
  recorded run reproduces its frame hash exactly. The script carries
  every input: the seed the stubs answer from (`git status`, the
  build's output), the start (the resize, a wake, `EV_INIT` where the
  core starts, the focus), the status request that stands in for a
  save, and the terminal family's operations on its own emulator, which
  takes a slot in the editor's table. An input that bypasses the
  `ev_*` wrappers breaks this. `--replay-check` replays the run's
  script in a child and fails when it ends on another frame hash;
  `minc test` runs it on the first seed, and `build/fuzz --replay` on
  every seed. `--show <step>` prints the state, the text and every quad
  of one step's frame, in a run and in a replay, so the two can be
  diffed; `--trace` lines end with the clock. `--shrink <f>`
  delta-debugs a failing script by dropping runs of events, whole
  steps first. It keeps a drop only when the same FAIL line remains.
  It re-runs itself as a child process, so give it a budget
  (`--budget`, default 6000 replays) and expect it to take minutes.
  How far it gets depends on the trace. Unrelated tails drop quickly,
  but a failure whose caret position depends on every earlier scroll
  and click does not reduce.
- ed_test also model-checks text_buf against a plain byte array:
  content, line count and every line start, over 20k random edits. It
  round-trips save and load, including the CRLF paths, which the
  fuzzer cannot reach because it never writes to disk. It also
  model-checks the change gutter. One random edit against a baseline
  of distinct lines has one correct answer, so the check detects a
  diff that has the right shape but is off by a line.
- ed_fuzz's clock is input: it moves 50 ms at every recorded event and
  a read returns it unchanged, so a run and its replay see the same
  time at every event. git's jobs run inline there (`git_threaded`),
  as the language server's and the terminals' do, so a job's result
  lands at the same wake in every run.
- ed_test stubs `plat_time_us` with a clock that advances only
  when it is read (`g_clock_step`). This keeps runs deterministic. The
  step decides whether two presses count as a double click. The core
  detects double clicks itself and does not take them from the OS.
- ed_test is built with `--track-alloc` so that `alloc_live()` returns
  an actual count. Its leak check opens, edits and closes a buffer
  twenty times and requires the live count to stay flat. Without the
  flag the counters read 0 and the check skips itself.
- The harness is portable: ed_fuzz stubs every plat_*/gpu_* function
  the core reaches, and the soak driver is minc, not a shell script.
  Keep it portable with
  `minc --target <linux|linux-arm64|macos|wasm> src/ed_fuzz.mc -o /tmp/x`,
  which type-checks the other platforms' stdlib arms from this one. Do
  the same for scripts/fuzz.mc and src/ed_test.mc.
- The harness also runs as a browser-target module under node:
  `minc --target wasm src/ed_fuzz.mc -o build/ed_fuzz.wasm` then
  `node scripts/wasm_fuzz.mjs build/ed_fuzz.wasm --seed 1 --steps 400`
  (the same for ed_test, built with `--track-alloc`). The node host
  provides only the runtime's file, output, clock and argument imports
  over the repository, plus two "harness" imports the stubs need
  there: directory listing and delete, which the stdlib cannot do on
  that target. Its frame hashes agree byte for byte with a native run,
  so a difference is a port bug in the core, not a rendering bug. Run
  it after a change that touches a `when os(wasm)` arm.

## Headless runs

- `edmc <file> --shot out.ppm` renders one frame offscreen, writes it
  as a PPM and exits. It draws in Dark+ and never reads the user's
  settings; `--theme <name>` draws it in another built-in theme. The pixels are the app's own, so no
  screen-capture permission is needed. Add `--key <key>:<mods>`
  (repeatable; mods bitmask 1=ctrl 2=shift 4=alt 8=super) to inject
  keys through app_key after init. The shot can then capture any
  keyboard-reachable UI state (e.g. `--key 92:1` splits). `--char <cp>`
  does the same for typed input a key code cannot carry, above all
  Enter (13). The two interleave in the order given: `--key 71:3 --char 13`
  opens the changes view and then the diff for its first row. Each
  injection settles before the next, so a view that a worker finishes
  is present for the next key. A run takes up to 128 injections,
  enough for a shell command typed into a terminal pane. Both flags
  also work on a normal launch. This puts a live window into a state
  that needs typing without real input (`edmc <file> --key 71:3 --char 13`
  opens a diff and leaves the window up). Prefer this over lldb
  injection for UI validation: it is one command with no attach. The
  pixel loop is:
  `build/edmc doc/TESTING.md --shot shot.ppm`, then read the dump.
  The shot frame is unfocused, so the caret is not in it (the render
  gates on g_focused). Selections, the current-line band and the
  status bar are in it, so assert on those. Colors in a dump are
  `R | G<<8 | B<<16`: C_SEL 0xFF784F26 is rgb(38,79,120), not the
  other way round.
- `--shot` works on all three backends. The drivers call `app_settle()`
  before the dump so background work (the git fetch) is in the frame.
  Pass `--dpi <n>` so the dump is the same size on any machine. For the
  same reason the shot path keeps the default 1200x800 window instead
  of maximizing. Windows dumps are 1200x845, taller than the other
  platforms', because the self-drawn caption band is reclaimed into
  the client area.
- The scrollbar thumb draws over the change-gutter ruler marks, so a
  mark under the thumb shows the two colors blended. Match on the
  blend or scroll the thumb away before asserting.
- A solid rect drawn in the frame background color is invisible. The
  shader normalizes coverage against the frame background, so
  src == bg yields zero effective alpha. Never "mask" overdraw with a
  bg-colored quad; clip via draw_clip.
- A terminal pane: `edmc <file> --key 75:1 --key 84:0 --char 116`
  opens one through the injection path. The char is the chord's own, which a
  keyboard sends and the chord consumes; without it the chord
  consumes the next typed char. `--char` after that types into the
  shell. `--dump-term <file>` writes the pane's screen as text once
  the shell has stopped printing, so a check can assert a command's
  output. Use `--char 13` for Enter. `--shot` shows the pane too, and
  the dump's wait puts the prompt in it. `--key 66:3 --dump-term <f>`
  builds the project in the build pane and dumps its output; the
  settle waits for the compiler. `--term-raw <f>` writes every byte
  the child sent from the first key after the pane opened.
  `--dump-wait <ms>` lengthens the wait for a slow child. Together
  they read a program's output stream. Claude Code's stream showed
  `CSI > 4 m`, colon sub-parameters, and a logo in block elements;
  `--shot` on the same run checks the fix. `--wait <ms>` between
  injections pumps the terminal without sending anything. A
  full-screen program needs this, since it has to be on screen before
  the next key reaches it. Setting `EDMINC_SHELL` to the program runs
  it in the pane with no shell in between, so one run captures its
  complete stream. One such run:
  `EDMINC_SHELL=claude.exe edmc doc/TESTING.md --key 75:1 --key 84:0
  --char 116 --wait 9000 --char 47 --wait 3000 --term-raw <f>
  --dump-term <f>`.
- A check on a terminal pane has to account for two things. A real
  keyboard sends a chord's own control character after the key, and
  the pane drops it, so a check that sends only the key does not
  reproduce a keyboard. Enter and Backspace are the two controls that
  arrive as text and pass on to the shell. A terminal that no pane
  shows requests no frame.
- A restart: a run that restarts partway forwards its `--dump-term`,
  `--dump-wait` and the injections after the restarting one to the
  new process.
  `... --key 75:1 --key 82:0 --char 114 --char <text> --dump-term <f>`
  therefore types into the handed-over shell from the new process and
  dumps its reply. `--wait` runs a real wake, so the editor reads a
  request file during one.
  The restart request is a file in the folder, so every editor with
  that folder open races to take it. Test a restart in a scratch
  folder, not in one that an editor you are using has open.
- The changes view: the baseline arrives from the gutter's worker, so
  the second pane appears when the fetch completes, not on the
  keystroke. A headless check has to settle before the list or the
  second pane exists.
- Buffers: `ed_view_file` opens a preview, `ed_open_file` opens a kept
  buffer, and `ed_buf_cap_set` sets the cap. A session restore skips
  both limits. `session_set_base` sets the session's base directory,
  so ed_test round-trips the session under build/ instead of the repo
  root. The native drivers call app_session_restore after app_init,
  never on --shot/--play/--smoke and never in the harness.
- `edmc <file> --newwin` opens a second window at start, for the
  multi-window path.

## Probes

- A plain launch on macOS and Linux detaches from the shell: the
  process the prompt returns from is not the editor (doc/TECH_DOC.md,
  "The launch"). Pass `--no-detach` to run it under lldb, to read its
  output, or to wait on its exit. Every headless flag keeps the
  process in the foreground on its own.
- macOS full editor: `screencapture` silently returns wallpaper only
  (no windows at all) unless the invoking terminal has the Screen
  Recording permission. Do not conclude "window missing" from such a
  shot. These checks need no permission: confirm the window with a
  CGWindowListCopyWindowInfo probe (layer-0 windows by pid/bounds),
  and drive input by attaching lldb to a `-g` build and calling entry
  points through function-pointer casts, e.g.
  `expr -- ((void(*)(unsigned int))&app_char)(88)`. Assert from the
  window title (leading `*` = dirty), read through the attached lldb.
  Synthetic CGEvents need the Accessibility permission. Real
  keypresses need a human.
- `minc scripts/mac_windows_probe.mc -o build/mac_windows_probe` then
  `build/mac_windows_probe <pid>` lists a process's on-screen windows
  with their bounds. It needs no permission; titles come only with
  Screen Recording. To check multi-window, open a window with
  `--newwin` or `--key 75:1 --key 78:1` (Cmd+K, Cmd+N through
  app_key), then read the count. Close a window from outside through
  lldb:
  `lldb -p <pid> --batch -o 'expr -l objc -O -- [(NSWindow*)[[[NSApplication
  sharedApplication] orderedWindows] objectAtIndex:0] performClose:0]'
  -o detach`. Closing the last window stops the run loop only when the
  next event arrives, so post one or expect the process to linger.
  Run these one process at a time. Concurrent launches fight over
  activation, the windows never composite, and the probe reads 0.
  Drive the folder dialog through lldb on a running editor, after
  `expr -l objc -- @import AppKit`. `[[[NSClassFromString(@"EdmincTimerTarget")
  alloc] init] performSelector:@selector(onPickFolder:) withObject:nil
  afterDelay:0.2]` opens it (the IMP ignores self). `sample <pid> 1`
  then shows the main thread inside runModal.
  `[NSApp stopModalWithCode:0]` followed by a posted
  `NSEventTypeApplicationDefined` event (built with NSMakePoint) cancels
  it; the modal loop acts on the next event. `stopModalWithCode:1`
  opens the panel's current folder. `--key 75:1 --key 79:1` also opens
  the dialog, but before the window has composited, so the window probe
  reads 0 afterwards. Open it from the running app instead. abortModal
  throws through the stopped frame. A delayed perform fires inside the
  modal loop only when it is scheduled in NSModalPanelRunLoopMode.
- macOS idle check: `ps -p <pid> -o cputime=` delta over ~10s must
  be flat.
- `pwsh scripts/ui_probe.ps1 [-File <f>] [-Ctrl <letter>] [-Type "text"]
  [-Out shot.png]` launches the editor, optionally sends one Ctrl
  chord, posts WM_CHAR keystrokes, saves a window screenshot
  (PrintWindow), prints the window title and kills the editor. A
  leading `*` in the title means a dirty buffer, so typed input can be
  asserted from the title alone. Example: ``-Ctrl P -Type "view`r"``
  fuzzy-opens src/view.mc, and the title confirms it.
- `ui_probe.ps1` takes
  `-Flags @("--lsp-trace")` for extra editor flags. The parameter is
  not named Args because PowerShell reserves that name. Invoke the
  script in-process or through `pwsh -Command`: `pwsh -File` passes the
  array as literal text, and the editor then gets the wrong flags.
  `-Log <file>` captures the editor's stdout. The script then closes the
  window with WM_CLOSE instead of killing it, because a kill loses what
  `print` has buffered. `--lsp-trace` prints every symbol request and
  reply and every jump, each push's form (ranged or whole), each
  arriving publish with its count, and each semantic token reply with
  its count. Use it when a Ctrl+T jumps somewhere unexpected: the trace
  shows the jump inside the reply, and the target can be the server's
  own first hit for the full query.
- Posted WM_CHAR works for text/Enter/Tab/Backspace; [char]27 posts
  Esc as WM_KEYDOWN. Alt+arrows arrive as WM_SYSKEYDOWN and cannot be
  posted either. `ui_probe.ps1 -AltAfter Left|Right|Up|Down` sends a
  real Alt chord after the typed text. This drives the navigation
  history: Ctrl+T to jump, then Alt+Left to go back. The driver
  forwards all four Alt+arrows; Alt+F4 and Alt+Space stay with
  DefWindowProc. Ctrl combos do NOT work via PostMessage, because the
  handler reads GetKeyState, i.e. the real keyboard. `-Ctrl` sends a
  real SendInput chord after it brings the window to the foreground,
  which works in an interactive session (RDP included). `-Shift` sends
  that chord as Ctrl+Shift+<letter>, which opens the changes view
  (Ctrl+Shift+G). `-Settle <ms>` waits before the shot for a view that
  a worker finishes: the diff draws two panes only after the baseline
  fetch completes.
- PowerShell quirks the script already handles: byref RECT structs are
  unreliable in pwsh (C# returns the rect as int[] instead),
  PrintWindow needs flag 2, and the capturing process must be
  per-monitor DPI aware or Windows virtualizes the coordinates.
- Linux DPI: nothing publishes a scale under WSLg, so pass
  `--dpi <n>` or set `EDMINC_DPI=<n>` (144 = 1.5x). On a desktop
  session the editor reads `Xft.dpi` itself. `--dpi` also makes
  `--shot` dumps reproducible across machines. When monitors
  disagree, key the value by RandR output name:
  `--dpi DP-1=1.5x,HDMI-1=1x`. Unlisted outputs fall through. A
  value is a DPI (`144`) or a scale of the 96 base (`1.5x`). The
  window re-scales when dragged between outputs.
- `minc scripts/x11_probe.mc -o build/x11_probe` then
  `build/x11_probe <title> title|ctrl <letter>|key <keysym>` drives
  the editor. `clip <text> <ms>` / `readclip` own or read the
  CLIPBOARD selection to test copy and paste. The probe sends keys as
  synthetic events to the window. This display's compositor owns focus
  and leaves the X input focus None, so XTest has nowhere to deliver.
  Ctrl chords DO work here (unlike the Windows probe), because the
  driver reads the modifier from the event. `utf8
  <keysym>` sends a keysym the layout does not map: it borrows an
  unused keycode and restores it afterwards. This tests committed
  UTF-8 without an IME installed.
- `python scripts/web_probe.py [--out build/web.png]` drives the
  browser build headless. It starts `minc wasm --no-browser`, loads
  the page in Edge through Playwright, checks that a frame rendered and
  the title contains the project, types and expects the dirty mark,
  opens the picker, and measures idle for three seconds after the
  blink timer has stopped (zero frames, zero ticks). It refuses to run
  when something already serves port 8080. Afterwards it kills the
  server's process tree, because the compiler's server is a grandchild
  that can outlive a plain kill and serve stale files.
  With a server staged, it also opens src/ed.mc, expects the
  initialize round-trip, presses F12 on a symbol defined in lexer.mc
  and expects the title to show the jump arrived there, then types a
  word start and expects a completion reply (the counters
  `lspOut`/`lspIn` on `window.edminc.stats`). The jump checks that
  the staged server accepts `minc/workspaceFiles`. The page sends the
  server the file list instead of a root to walk. A server built
  before that method drops the notification and returns nothing for
  every cross-file jump, while same-file jumps still work. `minc wasm`
  stages the copy beside the compiler by default. A copy named by
  `MINC_LSP_WASM` does not update with the toolchain. It then opens
  src/watch.mc, which imports the stdlib's `thread`, and fails on a
  "cannot find library" diagnostic. The server looks for a stdlib
  module as lib/<name>.mc relative to its working directory, the
  project root, and the worker (web/edminc_lsp_worker.js) resolves the
  paths it opens against that root.
  `window.edminc` on the page exposes the exports, the file map and
  activity counters for ad-hoc probing. Browser limits: Ctrl+W and
  Ctrl+T stay with the browser, and the primary modifier is Ctrl
  everywhere (Cmd on a Mac browser).
- `python3 scripts/hold_mac.py [--gap-ms 33] [--seconds 6] [--file src/ed.mc]`
  measures a held caret key under smooth scrolling on macOS. It writes
  a play script of Down keys, runs the editor on it with `--time` at
  that tick, and reads the frame log: the frame cadence, the render
  time, the main thread's wait in `nextDrawable` (`drawable_wait_us`,
  0 when the fetch thread had the drawable ready), and the trail each
  frame drew (`glide`). A held key reads as a trail
  that shrinks by the same amount every frame and steps up on each
  key; a wait near a refresh means the main thread is blocked. The
  player's timer fires late when the main thread is held, so the key
  cadence in the log is itself a finding.
- `minc scripts/macwatch_probe.mc -o build/macwatch_probe` then
  `build/macwatch_probe` checks the macOS file watcher alone. It links
  lib/mac.mc and src/term.mc as macpty_probe does. It watches
  build/watch_probe, creates, rewrites, renames and deletes entries there from its own process, prints the records the read
  returns, and fails when one it expects is missing; a second thread
  then blocks in a read and the close must end it. The editor's side
  is checked headless on any platform with a watcher: start
  `build/edmc <folder>/a.txt --wait 2500 --shot out.ppm`, rewrite the
  file from another shell during the wait, and the dump shows the new
  text, since `app_settle` runs a due refresh before the shot.
- `minc scripts/macpty_probe.mc -o build/macpty_probe` then
  `build/macpty_probe` runs the real macOS pty layer
  against the login shell through the Windows probe's stages. After
  each stage it prints the screen the emulator built, with the
  invariant check. It is the check for lib/mac.mc's pty layer and the
  headless way to see what a shell sends on macOS. It polls the
  emulator instead of running the run loop, so a wake the reader posts
  is never delivered. The probe still initializes the objc runtime and
  gives it a Foundation NSObject as the target, because the post goes
  through them.
- `edmc --term-probe [--term-flags 0|1] [--term-log <file>]` is the
  terminal prototype (Windows only), built before the emulator. It
  runs a shell behind ConPTY and dumps every byte the host sends with
  the escapes shown. It walks a script of prompt, command, history
  recall, completion, resize, burst, idle and kill. `--term-flags`
  picks the ConPTY mode and `--term-log` writes the dump to a file
  instead of stdout. Use the log: when the std handles are not pinned,
  the shell inherits a redirected stdout. `--term-grid` feeds the
  emulator instead and prints the screen it builds, rows between bars,
  with the cursor, the title and the invariant check. This is the live
  check that src/term.mc parses what a real shell sends. `EDMINC_SHELL`
  overrides the shell.
- `python scripts/lsp_probe.py def <file> <line0> <col>` asks minc-lsp the
  same question the editor would, over stdio with no editor involved.
  `body`, `ws` and `sym` modes cover completion, workspace symbols and
  documentSymbol. `prepare`, `in` and `out` ask for the call hierarchy
  at a position: the item, its callers, its callees. Every reply prints
  its round-trip time. A null from this probe comes from the server,
  not the client. `LSP_EXE` names another server binary for the probe,
  and `EDMINC_LSP` does the same for the editor. `EDMINC_CLANGD` names
  the editor's C server; a path that does not exist tests the
  not-found message.
## Debugging

- When a D3D call returns E_INVALIDARG with correct-looking arguments,
  the cause is almost always a wrong API constant.
  D3D11_BIND_CONSTANT_BUFFER is 0x4; 0x40 is DEPTH_STENCIL. That mix-up
  cost a debugging session. To read D3D's validation message, create
  the device with flag 0x2 (debug layer) and capture the
  OutputDebugString stream, for example with Sysinternals DebugView.
  The message names the bad field.
- The COM vtbl structs in lib/gpu_d3d11.mc are padded slices of the
  real vtables. Their slot positions and constants are verified
  against the Windows SDK headers. Extend them by counting slots in
  the SDK headers, never from memory. minc's COM indirect-call codegen
  is verified correct. Suspect constants and struct layouts before
  you suspect the compiler.
- `python scripts/stacks.py <pid> [tid ...]` samples a hung process's
  native stacks without a debugger (none is installed). For each
  thread it prints the module of each frame plus edminc RVAs. A thread
  in WaitForSingleObject with edminc frames under it is blocked on
  something the editor asked for. A thread in GetMessageW is idle.
  Compare the thread count against a healthy instance first, because
  the D3D11 driver keeps its own thread pool. The RVAs are against
  image base 0x400000.
- Nothing on the UI thread may wait for a worker or for the language
  server. Joining the change gutter's fetch when the next file opens
  freezes the editor with no way out. Writing to the server blocks the
  same way: a push carries the whole file, the pipe blocks once its
  buffer is full, and a server busy indexing a large workspace drains
  it slowly, so the UI thread stalls for seconds. Sends therefore go
  through a writer thread over an outbound queue (src/lsp.mc), which
  keeps them in the order the frames were built. The harnesses set
  `lsp_threaded` to false, because they stub the child and check each
  frame as it is written. The editor also requests a stdin pipe buffer
  large enough for a whole file (lib/win.mc).
- The UI thread reads the reply, so reading must stay cheap in the
  size of the reply. `jd_at` walks an array from its head, so indexing
  one in a loop is quadratic. Decoding semantic tokens that way froze
  the editor for 15 s on a 79k-line file. Walk with `jd_first`/
  `jd_next` instead. `mcp__minc__profile` names the function when a
  freeze burns CPU. `pwsh scripts/stall_watch.ps1` catches a freeze
  that blocks: it samples stacks while the UI is still stuck.
- `pwsh scripts/perf.ps1` measures file open, keypress-to-present,
  and sustained scroll rate (`edmc.exe <file> --time` prints per-paint
  timing and input latency to stdout). The phase-1 numbers are in
  TECH_DOC.md "Performance".
- `pwsh scripts/latency.ps1` measures input to display on Windows:
  typing and scrolling at four input rates. It posts `WM_BENCH`
  messages that carry its QPC count. `--time` matches each frame with
  the refresh that showed it, from the DXGI frame statistics, which a
  thread reads every millisecond once the first timed input arrives.
  Run it at the machine: a Remote Desktop session shows the window
  through its own display driver. Keep the pointer off the window
  during an idle check as well, since hover work costs CPU.
- `pwsh scripts/hold.ps1` measures a held caret key under smooth
  scrolling on Windows. It sends Down at the repeat rate (`-GapMs`,
  `-JitterMs`) and reads the frame log for the frame cadence, the trail
  each frame drew and the motion per frame. Steady motion is one value.
  `-Hz 240` switches the display to that rate for the run and restores
  the saved mode after. The `--time` log has `glide` on each paint
  line, a `key_us` line with the gap since the previous key message,
  and `paint_pre_us` when the paint handler took over 5 ms before the
  render. The log costs frames of its own: a write to the log file
  stalls the editor for about 30 ms every 16 KB (`paint_print_us`),
  and a pipe read by a script that spins on the clock stalls every
  print until the script's next iteration. The probes write to a file,
  and a dropped frame every second or two in a `--time` run is the
  log.
- `pwsh scripts/pixcmp/capture.ps1` then
  `python scripts/pixcmp/compare.py build/pixcmp` measures text
  rendering against VS Code per glyph (needs VS Code and Python with
  numpy + PIL). Both apps render Consolas 16px on a 96-dpi screen.
  VS Code's letterSpacing is tuned so both use the same 9px integer
  grid. Without a 96-dpi screen the capture forces both to scale 1
  instead (edminc `--dpi 96`, Chromium
  `--force-device-scale-factor=1`), which gives the same 9px grid in
  physical pixels. The capture reports which mode it used. Numbers
  from the two modes are not interchangeable. It closes the file tree
  with a real Ctrl+B first, or the geometry pass locks onto the tree's
  rows instead of the editor text. compare.py reports per-glyph pixel
  diffs and writes a comparison strip. It reads the advance off the
  capture, so it follows the dpi of the run.
- `-Native` runs both apps at the screen's own dpi instead. The grid is
  then whatever that dpi gives (13px at 144, against 9px at 96), and
  the default letterSpacing does not match it. Pass `-Settings <json>`
  with a letterSpacing matched to it. For 144 that is -0.130208:
  Consolas 16px is 8.796875 wide naturally, and 13/1.5 is the css
  advance that gives a 13px device cell. edminc's cell is an integer at
  every dpi, so VS Code is the side to adjust.
- Baseline 2026-09-10, after re-tuning TEXT_CONTRAST/TEXT_GAMMA
  (0.5 / 1.55): mean abs diff ~1.16/255 at 96 dpi and ~0.24 at 144,
  every glyph aligned at (0,0). 1.55 is the optimum at both, measured
  on either side (1.2 and 2.0 are worse at both). The gamma rose from
  1.3 when the pixel shader started receiving the real background
  color. The old value had been fitted against a black background.
