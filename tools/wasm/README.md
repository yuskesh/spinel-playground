# tools/wasm — Ruby to `wasm32-wasip1`, for Workers and Fastly

`spinel-wasm` compiles one Ruby program to a `wasm32-wasip1` module with the
pinned `vendor/spinel`. It drives the ordinary compiler (`spinel -c`), builds
the runtime for wasm32, and links the two with the official LLVM 23.1.1. It
does not modify `vendor/spinel`. Ported from spinel-llvm `463d49dd`; see
[provenance](../../docs/provenance.md).

## Use

```sh
export LLVM_PREFIX=/path/to/llvm-23.1.1        # clang and wasm-ld
export WASI_SYSROOT=/path/to/wasi-sysroot       # wasi-libc
export WASI_BUILTINS=/path/to/wasm32-unknown-wasip1/libclang_rt.builtins.a
tools/wasm/spinel-wasm app.rb -o app.wasm                     # a WASI command
tools/wasm/spinel-wasm app.rb --emit-worker dist              # a Workers project
tools/wasm/spinel-wasm app.rb --emit-fastly dist --host-api   # a Fastly package
```

`spinel-wasm --help` lists every option. The main ones:

| Option | Meaning |
| --- | --- |
| `--mode command` / `--mode reactor` | one `main()` per instance (default), or an instance that serves many calls |
| `--int-overflow raise\|wrap\|promote` | the overflow mode, passed to both the compiler and the runtime (default `raise`) |
| `--host-api` | opt in to the host API: `edge/http`, `edge/kv`, `edge/cgi`, `cloudflare/r2`, `cloudflare/d1`, `fastly/config` |
| `--platform workers` / `--platform fastly` | where the request lifecycle lives: in JavaScript (`worker.mjs`) on Workers, or linked into the module (`fastly/fastly_cgi.c`) on Fastly |
| `--emit-worker DIR` / `--emit-fastly DIR` | write a project that `wrangler dev` or `fastly compute serve` runs as it is |
| `--size-opt` | trade CPU for size (`spinel -c --no-inline-hot`). Size does not always fall |
| `--elim-bigint` | drop the Bignum subsystem when inference proves it unreachable. **Needs spinel-llvm's vendor Patch 5, which the pinned vendor lacks**, so it is refused |
| `--request-arena` | the small build for one request at a time: no collector (upstream `--gc=none`), the slab off, and the collector's tables shrunk. Memory is reclaimed when the request ends, by the instance's death or, on Workers, by writing the instance's memory back (below). Command mode only. `# spinel-tier: arena` selects it too, and either way the arena tier's checks refuse GC-semantics names such as `GC.start` and `ObjectSpace` at build time. `bash tests/edge/arena.sh` |
| `--no-snapshot` | with `--request-arena`: leave out the instance-reuse contract, so the host makes an instance for every request |

## The request contract

On both platforms a request is CGI-shaped, with no new API. `ARGV[0]` is the
path, `ARGV[1]` the query string, `$stdin` the body and `ENV` the CGI variables.
The response is `$stdout`. `exit(0)` gives 200 and anything else gives 500 with
`$stderr` as the body. With `SPINEL_CGI_HEADERS=1`, a program may print a
header block (`Status:`, `Content-Type:`, `Location:`) first. The scaffolds'
READMEs (`worker-template/`, `fastly/package-template/`) describe each
platform's side.

## One instance per isolate for an arena module

On Workers most of a small request's CPU time goes into making the instance
([measured](../../docs/edge/workers-limits.md#measured-on-cloudflare-2026-11-12)).
An arena module therefore carries a contract that lets the host reuse one
instance and still start every request from a new instance's bytes
([decision 0039](../../docs/decisions/0039-arena-instance-reuse.md)):

- `tools/wasm/snapshot.c` replaces `sbrk` with one that keeps the heap break in
  linear memory, and the module exports `__stack_pointer` and the marker
  `spinel_snapshot_abi`. `__stack_pointer` is the module's only mutable global.
- `runModule` in `wasi_shim.mjs`, which `worker.mjs` calls, makes one instance
  per module, copies its linear memory before `_start` first runs, and before
  every request writes the copy back, zeroes the rest and resets the stack
  pointer. Ruby globals, constants, the heap and the output of one request do
  not reach the next.
- A request gets a new instance, as before, when the shared one is busy (the
  module is waiting on the host API under JSPI), or when its host API suspends
  on other imports. The shared instance is made again after a trap, and after a
  request that leaves its memory above 16 MiB.
- `prepareModule(mod)` makes the shared instance at once, with
  `new WebAssembly.Instance`. The generated `index.mjs` calls it at global
  scope, so the instance is made in the isolate's startup (Workers allows 1 s)
  and not in its first request. It applies only to a module without host
  imports, since which host imports suspend depends on the request's env; for
  others it returns false and the first request makes the instance.
- Each response says which instance served it: `x-spinel-instance:
  reused call=N made=startup`, `reused call=N made=request` or `new`.

`--no-snapshot` builds an arena module without the contract, and
`serveSpinel(..., { snapshot: false })` or `runModule(mod, { snapshot: false })`
turns reuse off on the host side. A module built with a collector, a reactor
and a Fastly package are not reused. `bash tests/edge/arena.sh` and
`bash tests/edge/isolation.sh` check this.

## What is shimmed and what raises

wasm32-wasip1 has no threads, fibers, sockets, processes, signals or
filesystem. The rule, from spinel-llvm:

- A **true no-op** may be a stub: the program cannot observe a different
  answer. Examples: `backtrace`, `flockfile` on one thread, `Thread.pass` with
  no other thread.
- **An observed answer is never faked**, so it raises or fails with `ENOSYS`:
  `File.fnmatch`, `Dir.glob`, file locks and signal-mask changes.
- A stub **keeps the libc contract its caller relies on**. `madvise(MADV_DONTNEED)`
  zeroes the range, because the runtime's slab allocator trusts a released page
  to read as zero.

Programs that use `Thread`, `Socket` or `Kernel#system` are refused at build
time, by name. `Fiber` in the entry file is rewritten first into a stackless
state machine by `tools/fiber/spinel-fiber-rewrite` (see
[Stackless Fiber](#stackless-fiber)); a `Fiber` the rewrite does not reach is
refused by name like the others. `stubs.c`, `wasi_posix.c`, `raise_stubs.c`, `shim/`, `shim_*.h` and
`wasi_shim.mjs` hold the details, each with its reason.

The runtime source list follows the pinned Makefile's `RT_MEMBERS` and
`RE_SRC`, including the scheduler, fiber, process and networking translation
units; optional C-extension units are excluded. Compilation uses upstream's
`lib/wasi` declarations and regexp shim headers. `wasi_posix.c` includes the
pinned `lib/wasi/sp_wasi.c`, retaining its unsupported POSIX definitions with
the following deliberate differences:

- `flock`, including `LOCK_NB`, returns `-1` / `ENOSYS`. Upstream returns
  success because there is one process; Extended refuses to claim a lock
  operation was performed.
- `sigaddset` and `sigprocmask` return `-1` / `ENOSYS` without changing masks.
  Upstream reports success without changing them; Extended treats an observed
  signal-mask operation as unavailable. Initializing an empty mask remains
  a local operation: Extended actually zeroes the mask in `sigemptyset`,
  preserving the previous shim's behavior, while upstream leaves it untouched.
- `madvise(MADV_DONTNEED)` uses the zeroing implementation in `stubs.c`.
  Upstream's no-op would violate the slab allocator's zero-page assumption.

The generated main keeps upstream's startup path: WASI's mmap emulation
rejects the runtime's `MAP_NORESERVE` stack mapping, so `sp_main_stack_run`
falls back to calling the program body directly. Extended additionally sets
`SP_NO_SIGNALS`, which upstream's WASI driver does not set: signal handlers
cannot be installed here, so the runtime's existing no-signals branch avoids
allocating a useless 64 KiB alternate signal stack. POSIX signal operations
keep their unavailable-operation responses; this define only skips fault-handler
arming. `SP_MAX_WORKERS=1` retains the sole worker's real run queue: this
profile never defines `SP_THREADS`, so worker ID stays zero and helper-worker
creation is compiled out. This avoids reserving 256 queues for one worker.
The fiber stack-cache arrays retain their upstream sizes: their maximum is
not configurable. Only the arena profile sets `SP_STR_SHAPE_MAX=1`. That ring
holds major string-sweep samples for diagnostics, and under `--gc=none` nothing
calls the collector, so no sweep completes; its sample count remains zero. One slot is the minimum valid
ring size, so no live storage or collected diagnostic history is truncated.
The collecting profile retains the complete default ring.
No replacement Spinel runtime functions are provided. Source, header and regexp flag changes invalidate both
successful objects and failed-compilation stamps in the runtime cache.

## Stackless Fiber

wasm cannot switch stacks, so [decision 0035](../../docs/decisions/0035-stackless-fiber.md)
gives this route a stackless `Fiber` and `Enumerator.new`. When the entry file
refers to the `Fiber` constant or calls `Enumerator.new`, `spinel-wasm` runs `tools/fiber/spinel-fiber-rewrite` before Spinel. The
rewrite needs a Ruby that can `require "prism"` (`RUBY`, default `ruby`).

The rewrite turns each `Fiber.new do ... end` body into a step lambda. The
body's locals live in the lambda's closure, and the body is cut into numbered
states at every suspension. A top-level method, or an instance method of a
top-level class, that reaches `Fiber.yield` is a *yielding method*. It also gets a `__sf_mk_NAME` definition that builds the same
kind of step lambda for one call. Calling it from a fiber body steps the callee
until it finishes, so a yield deep in the callee suspends the whole chain.
`resume` and `Fiber.yield` pass values both ways. `alive?` works, and a
finished fiber raises `FiberError` when resumed. An exception escapes through
`resume` and ends the fiber. The rewritten module contains no `sp_Fiber_*`
code.

`Enumerator.new { |y| ... }` (stage 3) is the same rewrite, with `y << v` and
`y.yield v` as the suspensions. It gives a `SpinelEnum` with `next`, `peek`
and `rewind`. `next` and `peek` raise `StopIteration` at the end, and a
`loop` ends there as `Kernel#loop` does, including a `loop` that the rewrite
lowers. `each`, `to_a`, `first`, `take`, `take_while`, `find`/`detect`,
`include?`, `each_with_index`, `with_index`, `with_object`, `map`/`collect`,
`select`/`filter`, `reject`, `filter_map` and `each_with_object` are its own,
and each starts a fresh pass. So they stop early when their block breaks,
even on an endless enumerator, and leave the external position alone. Other
`Enumerable` methods (`sum`, `count`, `inject`, `sort`, `zip` and so on) are
Spinel's, which reads the whole sequence first, so on an endless enumerator
they do not return. `lazy`, `to_set` and a few others reach the runtime
`Enumerator` and are refused by the symbol scan. `size` is `nil`.

A frame that one site makes more than once must not be shared. Spinel gives
the locals a lambda captures one cell per activation of the method around it,
not one per call of the lambda. So a `Fiber.new` site that runs more than once
per activation builds its frame in a method of its own, `__sf_fr_N`, placed
beside the `def` around the site. That covers a site inside a loop, a block,
a lambda or a `begin` whose `rescue` retries, and every `Enumerator.new`
site. The locals of the surrounding
scope that the block uses are passed in, copied when the frame is made.
Ruby's block would see later assignments to them, so the following are
refused:
- a block that assigns such a local;
- a scope that assigns it after the site;
- a scope that assigns it inside a loop, block or retried `begin` around
  the site;
- a scope that assigns it inside any block or lambda before the site,
  because that block may be stored and called later.

This is conservative. A fiber that finishes before the next assignment would
be safe, but that cannot be known before run time.

The rewrite has these limits. Each is refused with `FILE:LINE:COL: spinel-fiber:`
and a reason, and no module is written.

- A suspension may sit in an expression, such as `x = 1 + Fiber.yield(2)`,
  `puts Fiber.yield(:a)` or `if Fiber.yield(:q)`. It is moved ahead of the
  rest of its statement into a temporary. Anything Ruby evaluates before it
  in the same statement must have no effect: a literal, a local variable,
  a constant or `self`. A method call there is refused with a message that
  suggests a statement of its own. So is a suspension that Ruby evaluates
  only under a condition, as in `a && Fiber.yield(b)` or a ternary.
- A suspension may sit inside `if`/`unless`/`elsif`/`else`, `case`/`when`,
  `case`/`in`, `while`/`until`, `loop`, `Integer#times`, `Integer#upto`, and
  `each` on an Array or Range literal or on a receiver typed as one (see
  below). It may not sit inside any other block
  or inside `begin` with `rescue` or `ensure`. A statement that suspends and
  also leaves its loop or method in the same expression is refused.
- Yielding methods are top-level `def`s and instance methods of top-level
  classes. A call without a receiver or through `self` looks in the class
  around it first, then at the top-level `def`s. A call through any other
  receiver needs the analysis to type the receiver as an instance of one
  class, and the receiver must be a local variable. An override must yield
  exactly when the method it overrides does. Refused: a yielding method
  reached through `send` or `method`, one in a module or a singleton class,
  and a call whose receiver is `poly` or untyped. Anything that could hide
  a yielding method behind another of its name is refused too: such a `def`
  outside a top-level class, `define_method`, `attr_*` or an alias making
  the name, `include` or `prepend` in a class that has or inherits one,
  `extend`, and `Class.new` on such a class.
- Two forms read the analysis through `spinel-typedump`: `each` over an Array
  or Integer Range held in a variable (an endless one is walked lazily), and a yielding method called through a
  receiver. `spinel-wasm` passes the reader at
  `tools/contract/build/spinel-typedump` when it is built, or the one named by
  `SPINEL_TYPEDUMP`. Without a reader both forms are refused, and the
  refusal says so.
- `Fiber.new` inside a fiber body or a yielding method is rewritten too. Refused:
  `Fiber.new` without a literal block or with arguments, and a block with more
  than one parameter.
- Hoisting puts a body's locals at its top. A block local that shares a name
  with a local of the enclosing body is refused, because the two would
  merge. A local declared inside a loop that suspends starts as `nil` at
  every iteration, as a block's locals do.
- Refused: `transfer`, `Fiber#raise`, `kill`, `Fiber.current`, fiber storage,
  the scheduler and `blocking` calls, and yielding several values at once.
- An `Enumerator.new` block takes exactly one plain parameter, the yielder,
  which may only receive `<<` or `yield`. It may not be passed on or chained
  (`y << a << b`), and `y.yield` takes at most one value. A size argument,
  `Fiber.yield` inside the block and a call to a yielding method are refused.
  So is `return`.
- External iteration over a runtime enumerator, as in `[1, 2].each.next`, is
  not rewritten and stays refused by the symbol scan.
- Only the entry file is rewritten. A `Fiber` or `Enumerator.new` in a
  required file is refused by the symbol scan.
- `.resume` and `.alive?` calls are renamed to reserved names, so that a fiber
  reached through a boxed value does not pull in the runtime Fiber. The rename
  is skipped when the program defines its own `resume` or `alive?`, or when a
  `require` cannot be followed. Files are followed through `require_relative`
  and through `require` resolved by the `-I` roots. When the rename is skipped,
  a fiber reached through a boxed value is refused by the symbol scan.

`bash tests/fiber/run.sh` builds the accepted programs, runs them on node and
wasmtime, compares the output with hand-written expectations, and checks each
refusal's position and text.

## Differences from spinel-llvm

- **Integer is 32-bit on wasm32.** spinel-llvm's vendor tree carried Patch 4
  (`SP_INT64`); the pinned one does not, and ignores the `-DSP_INT64` the driver
  still passes. A value that does not fit is promoted or raises, as its overflow
  mode says. It never wraps silently, except in `wrap` mode, whose contract that
  is.
- **The pinned runtime is newer than spinel-llvm's vendor tree.** Its new calls
  (`sigaction`, `madvise`, `flockfile`, the scheduler and fiber hooks, and the
  WASI imports `fd_filestat_get`, `fd_pread` and `sock_send`) are handled by
  the upstream WASI declarations, `wasi_posix.c`, `shim_flockfile.h`,
  `stubs.c` and `wasi_shim.mjs`. Each of
  those files says why its answer is honest.
- There are no Homebrew or home-directory defaults: `LLVM_PREFIX` (or `LLVM`),
  `WASI_SYSROOT` and `WASI_BUILTINS` must be set.

## Checks

`sh tests/edge/posix-shims.sh` checks unsupported file locks, signal-mask
operations and allocator zeroing directly under WASI.
`tests/edge/run.sh` builds and runs the edge examples locally,
`tests/edge/isolation.sh` checks that one request leaves nothing for the
next, on a new instance and on a reused one, and
`tests/edge/capcheck_rc.rb` checks the capability checker. See
[building](../../docs/building.md).

## The edge tools on the hosts that ran it

The Mac's edge tools are not recorded here. On Debian 13 (x86_64),
2026-09-23, user-local under `~/toolchains`: wasi-sdk 34 for `WASI_SYSROOT`
and `WASI_BUILTINS` and ICU 70 for the LLVM release's `wasm-ld` (both as in
[the freestanding lanes](../../tests/freestanding/README.md)); wrangler
4.61.1 from npm in its own prefix, with workerd 2026-01-28; and Viceroy
0.21.1 from its release archive `viceroy_v0.21.1_linux-amd64.tar.gz` (sha256
`54a5b46ab05ce1492f4df136728b2eb81b350cb42da5d9f2eec66558ddc1e233`), named by
`VICEROY`. Measured there: `capcheck_rc.rb` 46 passed, `tests/edge/run.sh` 40
passed, in 50 s.
