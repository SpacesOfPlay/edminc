// evscript.mc - the event script the fuzzer records and the editor can
// play. `ed_fuzz --dump-script` writes a run as this flat list of
// primitive events, `ed_fuzz --script` replays it headless, and
// `edmc --play` feeds it through the live window (play.mc). One byte
// of kind, then i32 fields, little endian; an f32 travels as its bit
// pattern. EV_FEED carries a byte count and that many bytes of mock
// server traffic. EV_WATCH carries a byte count and that many bytes of
// watcher records, or -1 for changes the watcher lost. EV_STEP
// separates the fuzzer's steps.

const u8 EV_CHAR = 1;     // cp
const u8 EV_KEY = 2;      // key, mods
const u8 EV_MOUSE = 3;    // x, y, btn, down, mods
const u8 EV_MOVE = 4;     // x, y
const u8 EV_SCROLL = 5;   // dx (f32), dy (f32), x, y
const u8 EV_HOVER = 6;    // x, y, mods
const u8 EV_RESIZE = 7;   // w, h
const u8 EV_SCALE = 8;    // dpi
const u8 EV_FOCUS = 9;    // on
const u8 EV_TIMER = 10;   // id
const u8 EV_WAKE = 11;
const u8 EV_FEED = 12;    // n, then n bytes
const u8 EV_SETTLE = 13;
const u8 EV_STEP = 14;
const u8 EV_WATCH = 15;   // n (-1: lost), then n bytes
const u8 EV_NOTCH = 16;   // a wheel's notch: dx (f32), dy (f32), x, y
const u8 EV_INIT = 17;    // the core starts (app_init), after the first resize
const u8 EV_STATUS = 18;  // git status asked for, as a save asks for it
const u8 EV_TERM = 19;    // op, 5 args, n, then n bytes: the fuzzer's own terminal
const u8 EV_SEED = 20;    // seed: the streams the stubs answer from
