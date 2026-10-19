# minc — guidance for AI coding agents

This file is read automatically by Claude, Cursor, Codex, Aider and
other agent tools when it sits in a project's root directory. Drop a
copy into any project that uses minc and the agent will follow the
conventions below without further prompting.

## What is minc

minc is a small C replacement that compiles `.mc` source files
directly to native binaries on every supported target, with no
assembler, linker or runtime. Targets: Windows x64 (PE), Linux x64 /
arm64 (ELF), macOS arm64 (Mach-O), iOS arm64 (Mach-O), Android arm64
(ELF), and WebAssembly.

The standard library is intentionally minimal. There is no `stdio.h`
and no `string.h`: the compiler ships built-in I/O and basic
utilities, plus a small `lib/` of opt-in modules (math, file I/O,
strings, sokol bindings, threading). Programs `import` library
modules; there are no headers.

## Read first

`LANGUAGE.md` is the full language reference. It sits in the
compiler's install directory next to this file, and online at
https://minc.dev/docs/. Read it once before writing minc code. The
rest of this file assumes you have, and focuses on the patterns and
shapes that real code uses.

## Commands

```
minc run app.mc              # compile and run; arguments after -- go to the program
minc app.mc -o app           # compile only
minc run --track-alloc app.mc   # report allocations still live when main returns
minc debug app.mc            # run under the debugger; --batch prints a backtrace on a crash
minc profile app.mc          # sampling profiler, functions by share
minc test                    # run test/*.mc in a project
minc --agent=json app.mc     # one JSON record per diagnostic, with a code and a fix
```

A project is a directory with a `build.mc`; `minc build`, `minc run`
and `minc test` there hand the verb to that script. Every tool has a
section in `LANGUAGE.md`.

## Agent mode and the MCP server

Pass `--agent` (or set `MINC_AGENT=1`) and every diagnostic is one
line with no colour or source excerpt, and the ones the compiler can
repair carry the repair:

```
app.mc:3:9: error: initializer type mismatch [fix: wrap 3:13-14 in cast(i32, ...)]
```

`--agent=json` (or `MINC_AGENT=json`) makes every line a JSON record:
diagnostics with `code` and `fix`, then a `summary` or `output`
record. `minc run`, `minc test`, `minc query` and `--track-alloc`
print their results as records in the same mode. Both flags reach
the processes the compiler starts, so a `build.mc` and the test
runner inherit them.

`minc agent` is the same toolchain as a Model Context Protocol
server over stdio. Register it once and the tools `query`, `compile`,
`run`, `debug`, `profile` and `test` become available to the harness:

```
claude mcp add minc -- minc agent
```

The project is the client's first root, else the directory the server
was started in. The source index is built on the first call and kept
warm, so `query` (definitions, references, callers, symbols, the
import closure of a file) answers in milliseconds afterwards.
`compile`, `run`, `debug` and `profile` act on the file they name;
`test` runs the project's tests. `isError` is set when the command
failed: diagnostics for `compile`, a crash or nonzero exit for `run`.

## Differences from C

minc looks like C and most C reasoning carries over, but a handful
of differences matter at every keystroke. Check these before falling
back on C habits.

**Things minc has that C does not:**

- **Function overloading by parameter type.** `dot(float2, float2)`
  and `dot(float3, float3)` both exist; the call site picks by
  exact-type match, and no implicit conversion is used to
  disambiguate. `lib/linear.mc` exposes the same op for different
  vector widths this way.
- **Tagged unions with pattern matching.** `union Token { Number(i32),
  Plus, Eof }`; construct with `Number(123)`; consume with `switch`,
  which enforces exhaustive coverage. Generic unions (`Option<T>`,
  `Result<T, E>`) work.
- **Generics**, monomorphised at compile time: `alloc<T>(n)`,
  `Vec<T>`, generic functions and structs.
- **`defer stmt;` for LIFO cleanup at block exit.** Use it instead
  of trailing `goto cleanup:` chains. Runs on every path that leaves
  the block: early `return`, `break` and `continue` included.
- **`when os(linux) { ... }` / `when arch(arm64) { ... }`** for
  compile-time conditional code. Replaces `#ifdef`. Conditions can
  also be `when defined(NAME)` for `-DNAME` build flags.
- **`import name;`** brings in a `lib/<name>.mc` module: from the
  importing file's directory, then `lib/` under the working
  directory, then the compiler's own `lib/`. Quoted
  `import "file.mc";` resolves relative to the importing file.
  Declarations and definitions live in the same file. `#include
  "file.mc"` exists for textual inclusion, but `import` is the normal
  form.
- **Two string types.** `str` is a borrowed view `{ u8* data; i32
  len }`; `string` is owned and must be freed: `defer free(s);`.
  String literals are `str`, read-only, and not null-terminated.
- **`var x = expr;`** infers the type from the right-hand side.
- **`p.field` auto-dereferences pointers**: write `p.x`, not
  `p->x`. The `->` operator is not in the language.
- **`new(T)`** allocates a zero-initialised `T` on the heap;
  `alloc<T>(n)` a typed uninitialised array.
- **`noinit T[N] arr;`** declares an array without zero-fill.
- **Struct literals** at the use site: `Point{3, 4}` (positional)
  and `sg_color{ .r = 1.0f, .g = 0.5f, .b = 0.2f, .a = 1.0f }`
  (named-field).
- **Variable destructuring**: `var (a, b) = pair_returning_fn();`.
- **Slices**: `T[]` is a length-carrying fat pointer; `T[N]` is a
  fixed array. C's "array decays to pointer" rule does not apply.
- **`private { }` blocks** for file-scope visibility, in place of
  C's `static`.
- **`extern "lib.dll" T name(...);`** for FFI. The library is
  named at the declaration, not at link time. Group several
  declarations against one library in the block form:
  `extern "libc.so.6" { i32 socket(...); i32 bind(...); }`.
  `from` binds a library symbol under another name.
- **Built-in vector and matrix types.** `float2`, `float3`, `float4`,
  `float4x4`, `int2`/`int3`/`int4`, `f64x2`: first-class, with
  swizzles (`v.xyz`), constructor literals and arithmetic
  operators. `+ - * / dot cross length normalize` are overloaded
  across them. Operations on `float4`/`float4x4`/`f64x2` lower to
  SSE / AVX / NEON instructions; you don't write intrinsics by hand
  for the common cases.
- **`@shader` functions.** Write a vertex, fragment or compute
  shader as a regular minc function and the compiler emits the
  matching HLSL / GLSL / MSL / WGSL text and metadata for sokol_gfx.
  Same syntax, same type system, no separate shader files. See
  `lib/shader.mc` and the sokol-samples-minc repository.

**Things minc does not have that C does:**

- **No undefined behavior.** Signed overflow wraps; divide by zero,
  null deref and out-of-bounds indexing trap. The compiler never
  deletes code by reasoning "this can't happen because it would be
  UB". Write the obvious code and trust it; defensive guards against
  UB are noise.
- **No preprocessor.** `const` for constants, `enum` for sets of
  integers, `import` for modules, `when` for conditional
  compilation. `@define "NAME" 3` and `-DNAME=3` set values `when`
  can test.
- **No header files.** One source file is one module; its external
  surface is whatever is not inside `private { }`.
- **No implicit fall-through in `switch`.** Every case ends on its
  own. Multi-value cases use commas: `case 1, 2, 3: { ... }`. Opt in
  per case with `fallthrough;` as the last statement.
- **No implicit narrowing.** `i32 x = some_i64;` is an error;
  write `i32 x = cast(i32, some_i64);`. Implicit widening (i32→i64,
  i32→f64, u8→i32, u32→i64) is allowed and expected.
- **No mixed-sign arithmetic without a cast.** `i32 a = 5; u32 b =
  6; a + b;` is an error. Cast one side explicitly. Integer literals
  are exempt.
- **No `void*` punning of typed pointers.** Pointer types are
  enforced; round-tripping requires explicit casts.
- **No null-terminated strings as a primitive.** A `str` carries its
  length. A `u8*` parameter is a C string by convention; pass
  `str_to_cstr(s)` or `s.data`, never the `str` itself.

**Subtle behavior shifts to keep in mind:**

- **Bounds checks on by default.** `arr[i]` traps on out-of-range
  in release builds too, unless the compiler is invoked with
  `--unchecked`.
- **`null` is a keyword**, not `0` or `NULL`.
- **`bool` is a first-class type.** `if x` requires `x` to be
  `bool`; integers don't convert.
- **Switch cases need braces.** `case X: { ... }`, never bare
  statements. A statement after `break`, `continue` or `return` at
  the same level is a compile error.
- **Globals, locals, structs and arrays are zero-initialised by
  default.** `noinit` opts out.
- **`main()` takes no parameters.** Read arguments with
  `get_argc()` / `get_arg(i)`.
- **`@must_use` results must be consumed.** Discard one on purpose
  with `ignore f();`.

**On performance:** the compiler runs solid local optimisations:
constant folding, register allocation, CSE, LICM, strength
reduction, loop unrolling, inlining, FMA fusion, and loop
vectorization for lock-step f32 and f64 loops. Well-formed code
reaches MSVC `/O2` and `clang -O2` parity on most workloads. The
deeper transformations a much larger compiler pulls off
(whole-program devirtualisation, profile-guided layout) are not
there: write code in a shape that is already close to the machine
and the compiler will keep it tight.

## Style

### Use modern syntax

- Unary minus: `-x`, never `0.0f - x` or `0 - x` for a value.
- Array initializers: `f32[4] v = { 1.0f, 2.0f, 3.0f, 4.0f };`.
  One assignment per element only when the values come out of a
  loop.
- `for i32 i = 0; i < N; i++`: postfix `++` / `--`, not `i = i + 1`.
- Math functions are overloaded on f32 and f64: `sin(x)` on an f32
  returns f32. `sqrt`, `fabs`, `floor`, `ceil`, `trunc` and their
  `f`-suffixed forms are builtins; the rest come with `import math;`.
- `noinit T[N] arr;` when seeding the array immediately afterward;
  skips the zero-fill the language otherwise inserts.
- Hex / decimal literals coerce to any integer type: write
  `u32 rng = 0x9E3779B9;`, not `cast(u32, 0x9E3779B9)`.
- `sizeof(x)` returns `i64`; don't wrap it in `cast(i64, ...)`.
- `alloc<T>(n)` returns `T*` directly. Write
  `u8* buf = alloc<u8>(n);`, never `cast(u8*, alloc(n))`.
- Type-inferred locals: `var x = expr;` when the type is obvious
  from the right-hand side.
- Struct literals: positional `Point{3, 4}` and named-field
  `sg_color{ .r = 0.1f, .g = 0.2f, .b = 0.3f, .a = 1.0f }`.
- Block-form externs when grouping several declarations against
  the same library. The single-line `extern "lib" T name(...);`
  form stays fine for one-off declarations.
- `print("{} = {}\n", name, value)` for output; the format expands
  at compile time.
- `defer` for cleanup at block exit (LIFO ordering).

### Avoid

- Unnecessary `cast(...)` when implicit widening covers the
  conversion (i32→i64, i32→f64, u32→i64, u8→i32; see the
  type-system section in LANGUAGE.md for the full list).
- Per-platform `when os(...) { ... }` blocks at app level when the
  underlying library can absorb the difference. Push the platform
  knowledge into a helper.
- Allocating heap arrays for short-lived data when a fixed-size
  stack array fits.
- Reaching for `cast(T, ptr)` to convert between pointer types when
  the type system already accepts the assignment.

### Comments

- Brief, neutral, declarative. Short sentences, plain words.
- Explain *why*, not *what*. The code already says what.
- Keep references to past sessions, fixes or PR numbers in the
  commit log, not in the source.
- State facts. Either fix a thing or leave it silent; no apologies,
  no hedging.
- Skip the comment entirely if removing it wouldn't confuse a reader.

## Canonical example

A small program that exercises the patterns this file describes:
file I/O, buffer math, a struct, defer cleanup, no platform code.

```mc
import file;

struct Sample {
    f32 t;
    f32 amp;
}

i32 main() {
    var fd = file_read("samples.bin");
    if fd.data == null { return 1; }
    defer free(fd.data);

    i64 n = fd.len / sizeof(Sample);
    if n == 0 { return 2; }
    Sample* samples = cast(Sample*, fd.data);

    f32 peak = 0.0f;
    for i64 i = 0; i < n; i++ {
        f32 a = fabsf(samples[i].amp);
        if a > peak { peak = a; }
    }

    print("{} samples, peak amplitude {}\n", n, peak);
    return 0;
}
```

The shape generalises to any program: top-level imports, structs, a
`main()` returning `i32`, `defer` for cleanup, a typed loop with
`i++`, helpers from `lib/`. The sample repositories below hold
working programs that follow this pattern at larger scales.

## Where to look

- `LANGUAGE.md`: the full language reference (types, control flow,
  generics, modules, FFI, shaders, the command-line tools).
- `lib/` in the compiler's install directory: the opt-in standard
  library (`math`, `file`, `str`, `linear`, `vec`, `thread_pool`,
  `sokol_all`, ...). Read the source when you need to know what is
  available; the modules are small and documented inline.
- https://github.com/SpacesOfPlay/minc-samples : example programs
  and benchmarks, each a single `.mc` file. Mandelbrot, a raytracer,
  chip8, an audio engine, sokol apps, and comparable minc + C
  implementations of common workloads under `bench/`.
- https://github.com/SpacesOfPlay/sokol-samples-minc : the upstream
  sokol "sapp" samples as single-file minc programs, native and
  browser, with `@shader` functions on every backend.
- https://github.com/SpacesOfPlay/box3d-minc : a port of Erin
  Catto's Box3D rigid-body physics engine with its sample browser.
  The reference for how a large minc program is laid out.

## When in doubt

Pattern-match on the sample repositories. They are the canonical
reference for both syntax and style. If a pattern shows up in three
or more programs there, it is idiomatic. If you cannot find it
there, check LANGUAGE.md before assuming it is supported.
