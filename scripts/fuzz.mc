// fuzz.mc - soak driver for src/ed_fuzz.mc. Runs a range of seeds and
// shrinks whatever fails to the shortest reproducing step count.
//
// Written in minc and talking to the fuzzer only through the process
// boundary, so it is the same driver on Windows, macOS and Linux.
//
//   minc scripts/fuzz.mc -o build/fuzz
//   build/fuzz                       # seeds 1..50, 2000 steps each
//   build/fuzz --count 500           # a longer soak
//   build/fuzz --seeds 9,12 --steps 300
//   build/fuzz --no-build
//
// Two failure kinds are distinguished because they need different
// handling. Exit 1 is an invariant the fuzzer checked and reported, so
// its own output names the state and prints an ink map of the frame.
// Any other non-zero exit is a hard fault with no report, and the
// shrink is the only evidence. Both shrink by bisecting --steps: the
// action stream is a pure function of the seed, so step N always
// replays identically.

import process;
import file;
import str;

private const i32 SEED_MAX = 4096;

private i32[SEED_MAX] fz_seeds;
private i32 fz_nseeds = 0;
private i32 fz_steps = 2000;
private i32 fz_verify = 8;
private bool fz_build = true;
private bool fz_twice = false;   // re-run each clean seed, compare hashes
private bool fz_replay = false;  // record each clean seed, replay it, compare hashes
private bool fz_hashes = false;  // print seed -> frame hash, for diffing
private bool fz_cov = false;     // sum what the seeds reached

// coverage totals, summed over seeds in the order ed_fuzz prints them
private const i32 COV_MAX = 64;
private i64[COV_MAX] cv_total;
private u8[COV_MAX * 48] cv_names;
private i32[COV_MAX] cv_name_off;
private i32[COV_MAX] cv_name_len;
private i32 cv_n = 0;

// failures, for the summary
private const i32 FAIL_MAX = 256;
private i32[FAIL_MAX] fl_seed;
private i32[FAIL_MAX] fl_steps;
private bool[FAIL_MAX] fl_fault;
private i32 fl_n = 0;

private void say(str s) {
    ignore write(stdout(), s.data, s.len);
}

private void say_i(i64 v) {
    noinit u8[24] b;
    i32 n = 0;
    if v < 0 {
        b[0] = '-';
        n = 1;
        v = 0 - v;
    }
    if v == 0 {
        b[n] = '0';
        n++;
    } else {
        noinit u8[24] tmp;
        i32 t = 0;
        while v > 0 {
            tmp[t] = cast(u8, '0' + cast(i32, v % 10));
            v /= 10;
            t++;
        }
        for i32 i = 0; i < t; i++ {
            b[n] = tmp[t - 1 - i];
            n++;
        }
    }
    ignore write(stdout(), &b[0], n);
}

// pad a decimal to `wide` columns so the report lines up
private void say_pad(i64 v, i32 wide) {
    i32 digits = 1;
    i64 t = v;
    while t >= 10 {
        t /= 10;
        digits++;
    }
    say_i(v);
    for i32 i = digits; i < wide; i++ { say(" "); }
}

private i32 fz_atoi(str s) {
    i32 v = 0;
    for i32 i = 0; i < s.len; i++ {
        if s.data[i] < '0' || s.data[i] > '9' { break; }
        v = v * 10 + cast(i32, s.data[i] - '0');
    }
    return v;
}

private void seed_add(i32 s) {
    if fz_nseeds == SEED_MAX { return; }
    fz_seeds[fz_nseeds] = s;
    fz_nseeds++;
}

// "3,9,12" into the seed list
private void seeds_parse(str spec) {
    i32 at = 0;
    while at < spec.len {
        i32 e = at;
        while e < spec.len && spec.data[e] != ',' { e++; }
        if e > at { seed_add(fz_atoi(str_from(spec.data + at, e - at))); }
        at = e + 1;
    }
}

// --- running the fuzzer ----------------------------------------------

private str fz_exe = "build/ed_fuzz.exe";
private str mc_exe = "minc.exe";

// Argument numbers live here rather than in allocations: proc_arg
// keeps the str it is handed, so the bytes must outlive proc_run.
private u8[64] arg_arena;
private i32 arg_at = 0;

private str arg_num(i32 v) {
    i32 s = arg_at;
    if v == 0 {
        arg_arena[arg_at] = '0';
        arg_at++;
    } else {
        noinit u8[16] tmp;
        i32 t = 0;
        while v > 0 {
            tmp[t] = cast(u8, '0' + v % 10);
            v /= 10;
            t++;
        }
        for i32 i = 0; i < t; i++ {
            arg_arena[arg_at] = tmp[t - 1 - i];
            arg_at++;
        }
    }
    return str_from(&arg_arena[s], arg_at - s);
}

private void seed_cmd(ProcCmd* c, i32 seed, i32 steps, bool quiet) {
    arg_at = 0;
    proc_init(c, fz_exe);
    proc_arg(c, "--seed");
    proc_arg(c, arg_num(seed));
    proc_arg(c, "--steps");
    proc_arg(c, arg_num(steps));
    proc_arg(c, "--verify");
    proc_arg(c, arg_num(fz_verify));
    if quiet { proc_arg(c, "--quiet"); }
    proc_capture(c, true);
}

// One run; the output is swallowed, only the exit code matters.
private i32 run_seed(i32 seed, i32 steps) {
    ProcCmd c;
    seed_cmd(&c, seed, steps, true);
    ProcResult r = proc_run(&c);
    i32 code = r.exit_code;
    bool spawned = r.spawned;
    proc_result_free(&r);
    if !spawned {
        say("cannot run ");
        say(fz_exe);
        say(" - build it first, or drop --no-build\n");
        exit(2);
    }
    return code;
}

// Shortest step count that still fails, by bisection. The failing side
// is monotone: a longer run repeats the same prefix.
private i32 min_steps(i32 seed, i32 steps) {
    i32 lo = 1;
    i32 hi = steps;
    while lo < hi {
        i32 mid = lo + (hi - lo) / 2;
        if run_seed(seed, mid) != 0 { hi = mid; } else { lo = mid + 1; }
    }
    return lo;
}

// Re-run and hand back the reported FAIL line as an owned copy; the
// ProcResult's own buffer dies with it.
private string fail_report(i32 seed, i32 steps) {
    ProcCmd c;
    seed_cmd(&c, seed, steps, false);
    ProcResult r = proc_run(&c);
    string copy = str_concat(fail_line(str_from(r.out.data, r.out.len)), "");
    proc_result_free(&r);
    return copy;
}

// the frame hash the summary line carries, or an empty str
private str hash_of(str s) {
    str key = "frame hash ";
    for i32 i = 0; i + key.len < s.len; i++ {
        bool m = true;
        for i32 k = 0; k < key.len; k++ {
            if s.data[i + k] != key.data[k] { m = false; break; }
        }
        if !m { continue; }
        i32 b = i + key.len;
        i32 e = b;
        while e < s.len && s.data[e] >= '0' && s.data[e] <= '9' { e++; }
        return str_from(s.data + b, e - b);
    }
    return "";
}

// Same seed, same frame hash. The batch is hashed vertex by vertex, so
// a mismatch means the run was not deterministic: uninitialised memory
// read into the frame, or worker results landing in a different order.
private string run_hash(i32 seed, i32 steps) {
    ProcCmd c;
    seed_cmd(&c, seed, steps, false);
    ProcResult r = proc_run(&c);
    string copy = str_concat(hash_of(str_from(r.out.data, r.out.len)), "");
    proc_result_free(&r);
    return copy;
}

// Record the run as a script, replay the script, and compare the two
// frame hashes. The replay has no prng and no mock, so a mismatch is
// input the script does not carry: a call past the event wrappers, a
// stub answering from a stream the replay does not seed, or a worker
// whose result lands at another point.
private bool replay_same(i32 seed, i32 steps, string* h1, string* h2) {
    str path = "build/fuzz_replay.evs";
    ProcCmd c;
    seed_cmd(&c, seed, steps, false);
    proc_arg(&c, "--dump-script");
    proc_arg(&c, path);
    ProcResult r = proc_run(&c);
    *h1 = str_concat(hash_of(str_from(r.out.data, r.out.len)), "");
    proc_result_free(&r);
    arg_at = 0;
    ProcCmd p;
    proc_init(&p, fz_exe);
    proc_arg(&p, "--script");
    proc_arg(&p, path);
    proc_arg(&p, "--verify");
    proc_arg(&p, arg_num(fz_verify));
    proc_capture(&p, true);
    ProcResult q = proc_run(&p);
    *h2 = str_concat(hash_of(str_from(q.out.data, q.out.len)), "");
    proc_result_free(&q);
    return h1.len > 0 && str_equal(str_from(h1.data, h1.len), str_from(h2.data, h2.len));
}

// "cov <count> <name>" lines, summed by position; the order is fixed
// so the names only need recording once
private void cov_accumulate(str s) {
    str key = "cov ";
    i32 at = 0;
    i32 slot = 0;
    while at < s.len {
        i32 e = at;
        while e < s.len && s.data[e] != '\n' { e++; }
        bool m = e - at > key.len;
        if m {
            for i32 k = 0; k < key.len; k++ {
                if s.data[at + k] != key.data[k] { m = false; break; }
            }
        }
        if m && slot < COV_MAX {
            i32 i = at + key.len;
            i64 v = 0;
            while i < e && s.data[i] >= '0' && s.data[i] <= '9' {
                v = v * 10 + cast(i64, s.data[i] - '0');
                i++;
            }
            while i < e && s.data[i] == ' ' { i++; }
            if slot >= cv_n {
                i32 n = e - i;
                if n > 47 { n = 47; }
                memcpy(&cv_names[slot * 48], s.data + i, n);
                cv_name_off[slot] = slot * 48;
                cv_name_len[slot] = n;
                cv_n = slot + 1;
            }
            cv_total[slot] += v;
            slot++;
        }
        at = e + 1;
    }
}

// One run with coverage on; the output is parsed, not shown. False when
// the run failed: a run that stops early reports only the counters it
// reached, so the soak would read a crash as less coverage.
private bool cov_run(i32 seed, i32 steps) {
    ProcCmd c;
    seed_cmd(&c, seed, steps, true);
    proc_arg(&c, "--coverage");
    ProcResult r = proc_run(&c);
    bool ok = r.spawned && r.exit_code == 0;
    cov_accumulate(str_from(r.out.data, r.out.len));
    proc_result_free(&r);
    return ok;
}

// the first line of `s` starting with "FAIL", if any
private str fail_line(str s) {
    i32 at = 0;
    str key = "FAIL";
    while at < s.len {
        i32 e = at;
        while e < s.len && s.data[e] != '\n' { e++; }
        if e - at > key.len {
            bool m = true;
            for i32 k = 0; k < key.len; k++ {
                if s.data[at + k] != key.data[k] { m = false; break; }
            }
            if m { return str_from(s.data + at, e - at); }
        }
        at = e + 1;
    }
    return "";
}

// --- build -----------------------------------------------------------

// MINC first (an install directory or the binary itself), then PATH.
private string find_minc() {
    string env = env_get("MINC");
    if env.len > 0 {
        str e = str_from(env.data, env.len);
        if path_is_dir(e) {
            string cand = path_join(e, mc_exe);
            free(env);
            return cand;
        }
        return env;
    }
    free(env);
    return path_which("minc");
}

private bool build_fuzzer() {
    string minc = find_minc();
    defer free(minc);
    if minc.len == 0 {
        say("minc compiler not found; set MINC or add it to PATH\n");
        return false;
    }
    ProcCmd c;
    proc_init(&c, str_from(minc.data, minc.len));
    proc_arg(&c, "src/ed_fuzz.mc");
    proc_arg(&c, "-o");
    proc_arg(&c, fz_exe);
    ProcResult r = proc_run(&c);
    bool ok = r.spawned && r.exit_code == 0;
    proc_result_free(&r);
    return ok;
}

// --- main ------------------------------------------------------------

i32 main() {
    when !os(windows) {
        fz_exe = "build/ed_fuzz";
        mc_exe = "minc";
    }

    i32 start = 1;
    i32 count = 50;
    bool have_list = false;
    for i32 a = 1; a < get_argc(); a++ {
        str arg = str_from_cstr(get_arg(a));
        if str_equal(arg, "--seeds") && a + 1 < get_argc() {
            a++;
            seeds_parse(str_from_cstr(get_arg(a)));
            have_list = true;
        } else if str_equal(arg, "--start") && a + 1 < get_argc() {
            a++;
            start = fz_atoi(str_from_cstr(get_arg(a)));
        } else if str_equal(arg, "--count") && a + 1 < get_argc() {
            a++;
            count = fz_atoi(str_from_cstr(get_arg(a)));
        } else if str_equal(arg, "--steps") && a + 1 < get_argc() {
            a++;
            fz_steps = fz_atoi(str_from_cstr(get_arg(a)));
        } else if str_equal(arg, "--verify") && a + 1 < get_argc() {
            a++;
            fz_verify = fz_atoi(str_from_cstr(get_arg(a)));
            if fz_verify < 1 { fz_verify = 1; }
        } else if str_equal(arg, "--twice") {
            fz_twice = true;
        } else if str_equal(arg, "--replay") {
            fz_replay = true;
        } else if str_equal(arg, "--hashes") {
            fz_hashes = true;
        } else if str_equal(arg, "--coverage") {
            fz_cov = true;
        } else if str_equal(arg, "--no-build") {
            fz_build = false;
        } else {
            say("usage: fuzz [--start N] [--count N] [--seeds a,b,c]\n");
            say("            [--twice] [--replay] [--hashes] [--coverage]\n");
            say("            [--steps N] [--verify N] [--no-build]\n");
            return 2;
        }
    }
    if !have_list {
        for i32 i = 0; i < count; i++ { seed_add(start + i); }
    }
    if fz_nseeds == 0 {
        say("no seeds\n");
        return 2;
    }

    if fz_build && !build_fuzzer() {
        say("build failed\n");
        return 1;
    }

    if fz_cov {
        i32 failed = 0;
        for i32 i = 0; i < fz_nseeds; i++ {
            if !cov_run(fz_seeds[i], fz_steps) {
                say("seed ");
                say_i(cast(i64, fz_seeds[i]));
                say(" failed; run it without --coverage for the failure\n");
                failed++;
            }
            // the counters print at the end; this shows the soak is alive
            if (i + 1) % 10 == 0 && i + 1 < fz_nseeds {
                say_i(cast(i64, i + 1));
                say(" of ");
                say_i(cast(i64, fz_nseeds));
                say(" seeds run\n");
            }
        }
        i32 never = 0;
        for i32 i = 0; i < cv_n; i++ {
            say_pad(cv_total[i], 10);
            say(str_from(&cv_names[cv_name_off[i]], cv_name_len[i]));
            if cv_total[i] == 0 {
                say("   <- never reached");
                never++;
            }
            say("\n");
        }
        say("\n");
        say_i(cast(i64, fz_nseeds));
        say(" seeds, ");
        say_i(cast(i64, never));
        say(" counters never reached\n");
        if failed > 0 {
            say_i(cast(i64, failed));
            say(" runs failed\n");
            return 1;
        }
        if never > 0 { return 1; }
        return 0;
    }

    // seed -> hash, for diffing one platform's output against another
    if fz_hashes {
        i32 bad = 0;
        for i32 i = 0; i < fz_nseeds; i++ {
            i32 seed = fz_seeds[i];
            say("seed ");
            say_pad(cast(i64, fz_seeds[i]), 6);
            string h = run_hash(seed, fz_steps);
            if h.len == 0 {
                say("FAILED");
                bad++;
            } else {
                say(str_from(h.data, h.len));
            }
            free(h);
            say("\n");
        }
        if bad > 0 { return 1; }
        return 0;
    }

    i32 clean = 0;
    for i32 i = 0; i < fz_nseeds; i++ {
        i32 seed = fz_seeds[i];
        i32 code = run_seed(seed, fz_steps);
        if code == 0 {
            if fz_twice {
                string h1 = run_hash(seed, fz_steps);
                string h2 = run_hash(seed, fz_steps);
                bool same = str_equal(str_from(h1.data, h1.len),
                    str_from(h2.data, h2.len));
                if !same {
                    say("seed ");
                    say_pad(cast(i64, seed), 6);
                    say("nondeterministic  frame hash ");
                    say(str_from(h1.data, h1.len));
                    say(" then ");
                    say(str_from(h2.data, h2.len));
                    say("\n");
                    if fl_n < FAIL_MAX {
                        fl_seed[fl_n] = seed;
                        fl_steps[fl_n] = fz_steps;
                        fl_fault[fl_n] = false;
                        fl_n++;
                    }
                }
                free(h1);
                free(h2);
                if !same { continue; }
            }
            if fz_replay {
                string r1;
                string r2;
                bool same = replay_same(seed, fz_steps, &r1, &r2);
                if !same {
                    say("seed ");
                    say_pad(cast(i64, seed), 6);
                    say("replay differs  frame hash ");
                    say(str_from(r1.data, r1.len));
                    say(", replayed ");
                    say(str_from(r2.data, r2.len));
                    say("\n");
                    if fl_n < FAIL_MAX {
                        fl_seed[fl_n] = seed;
                        fl_steps[fl_n] = fz_steps;
                        fl_fault[fl_n] = false;
                        fl_n++;
                    }
                }
                free(r1);
                free(r2);
                if !same { continue; }
            }
            clean++;
            continue;
        }
        i32 least = min_steps(seed, fz_steps);
        say("seed ");
        say_pad(cast(i64, seed), 6);
        if code == 1 {
            say("invariant  ");
        } else {
            say("fault      ");
        }
        say("minimal at ");
        say_pad(cast(i64, least), 6);
        // the report itself, for an invariant failure
        if code == 1 {
            string rep = fail_report(seed, least);
            if rep.len > 0 { say(str_from(rep.data, rep.len)); }
            free(rep);
        }
        say("\n");
        if fl_n < FAIL_MAX {
            fl_seed[fl_n] = seed;
            fl_steps[fl_n] = least;
            fl_fault[fl_n] = code != 1;
            fl_n++;
        }
    }

    say("\n");
    say_i(cast(i64, fz_nseeds));
    say(" seeds, ");
    say_i(cast(i64, clean));
    say(" clean, ");
    say_i(cast(i64, fl_n));
    say(" failing\n");
    if fl_n > 0 {
        say("\nreproduce with:\n");
        for i32 i = 0; i < fl_n && i < 10; i++ {
            say("  ");
            say(fz_exe);
            say(" --seed ");
            say_i(cast(i64, fl_seed[i]));
            say(" --steps ");
            say_i(cast(i64, fl_steps[i]));
            // --verify too: the oracles run on a step interval, so a
            // line without it names a different run and can come back
            // clean. That cost a wrong bisection once.
            say(" --verify ");
            say_i(cast(i64, fz_verify));
            say(" --trace\n");
        }
        return 1;
    }
    return 0;
}
