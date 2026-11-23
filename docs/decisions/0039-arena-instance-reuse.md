# 0039: One arena instance per isolate, written back before each request

- Date: 2026-11-13
- Status: Accepted by the owner on 2026-11-13 (the snapshot approach, on by
  default for arena builds; a request that finds the shared instance busy gets
  a new instance).
- Scope: `tools/wasm/spinel-wasm`, `tools/wasm/snapshot.c`,
  `tools/wasm/wasi_shim.mjs`, `tools/wasm/worker.mjs`, `tests/edge`.

## Context

`worker.mjs` made a new WebAssembly instance for every request, so that no
request could see anything an earlier one left behind. On Cloudflare that
instance is most of a small request's CPU time: a 168 B module with no runtime
used a median of 2 ms with a new instance per request and 0 ms with one
instance reused, and hello-http's arena build used 2 to 3 ms
([measurements](../edge/workers-limits.md#measured-on-cloudflare-2026-11-12)).

Two prototypes of hello-http that reuse one instance per isolate were deployed
and measured on 2026-11-12 and 2026-11-13 (the same page). Both answered all
400 measured requests correctly and read a CPU median of 0 to 1 ms.

## Options

1. **Keep a new instance per request.** Simplest, and the isolation is the
   engine's. It keeps the 2 to 3 ms.
2. **Reactor (prototype A).** A `--mode reactor` module, initialized once,
   with `main` called again for each request. Ruby state (globals, constants,
   caches) carries over from one request into the next, so the isolation the
   CGI-shaped contract promises is lost. It needs the collector, whose 64 MB
   slab leaves the instance at 69 MiB of the isolate's 128 MB. And it met a
   defect in the generated `main`: `sp_argv.len` is set before `sp_argv.data`
   is filled, so a collection during the fill marks unwritten slots, which in
   a reused `malloc` block hold allocator links. The prototype trapped on its
   295th request. Upstream `matz/spinel` at `f2c23f5` generates the same order.
3. **Snapshot (prototype B).** The arena build, which has no collector. The
   host copies the linear memory once, right after instantiation, and writes
   it back before each request. Each request starts from the bytes a new
   instance would have, at about 1 MiB of memory.

## Decision

Option 3, on by default for every arena command module (`--request-arena` or
`# spinel-tier: arena`).

- **The module's side** (`tools/wasm/snapshot.c`, linked by `spinel-wasm`):
  an `sbrk` that keeps the heap break in linear memory (wasi-libc's answers
  the memory's size, which a write-back cannot shrink), and the exports
  `__stack_pointer` and `spinel_snapshot_abi` (returns 1, the contract's
  version). `__stack_pointer` is the module's only mutable global, and
  `tests/edge/arena.sh` checks that in the global section of a built module.
  The contract adds 132 B to hello-http (941,475 B against 941,343 B).
- **The host's side** (`runModule` in `tools/wasm/wasi_shim.mjs`): for a module
  with the marker, one instance per module per isolate. Its memory is copied
  before `_start` first runs; before every request the copy is written back,
  the rest of the memory is zeroed and the stack pointer is reset. The WASI and
  host imports forward to the request that is running. Requests that arrive
  while the instance is being made share it.
- **Fallbacks to a new instance for the request**, as before:
  - The shared instance is running another request. That happens only when a
    request waits on the host API under JSPI, since otherwise a request runs to
    completion before the next one starts.
  - The request's host API suspends on other imports than the instance was made
    with.
  - The module lacks the marker, or the caller passes `snapshot: false`.
- **When the shared instance is made again**: after a trap, and after a request
  that leaves its memory above 16 MiB, because every later write-back would
  zero all of it.
- **Observability**: each response from `worker.mjs` carries
  `x-spinel-instance: reused call=N made=startup|request` or `new`.
- **Opting out**: `--no-snapshot` builds an arena module without the contract.
  It is refused without the arena tier, since no other build is reused.

The same work adds the pooled WASI state and its isolation test, and the CPU
harness `tests/edge/bench-cpu.mjs`. These were written on 2026-09-24 and left
unmerged. The isolation test now runs on both builds. Its program also prints a
Ruby global and a constant Hash's size, which would read 2 on the second
request if state carried over. It is registered as the suite
`edge-isolation`.

## Limits

- Arena modules only. A module with a collector still gets a new instance per
  request, because writing back its memory would zero 69 MiB per request.
  Reactors and Fastly packages are unchanged.
- The write-back copies the module's initial memory and zeroes what the last
  request grew: 448 KiB copied for hello-http.
- A module with host imports still makes its instance in its first request
  on each isolate (5 to 21 ms of CPU in the measured runs); see the addition
  below for the others.
- Not measured on Cloudflare in this form. The deployed prototype B is the
  same mechanism, but in a separate runner without the pooled WASI state.

## Evidence

On Debian 13, 2026-11-13, the suites `tools/test/affected.rb --base main`
selects for this change:

| Suite | Result |
|---|---|
| `bash tests/edge/arena.sh` | 28 passed, 0 failed, 2 known defects (the upstream catch/throw case on both builds) |
| `bash tests/edge/isolation.sh` | 13 passed on the ordinary build, 13 on the arena build |
| `bash tests/edge/run.sh` | 40 passed, 0 failed |
| `sh tests/compute/run.sh` | 75 passed, 0 failed, 0 skipped |
| `bash tests/fiber/run.sh` | 81 passed, 0 failed, 0 skipped |
| `sh tests/ghostty-terminal/run.sh` | 3 passed, 1 skipped (no built Ghostty checkout on this host) |
| `sh tests/affected/run.sh DIR` | 67 of 67 |
| `sh tests/imports/run.sh DIR` | 10 of 10 |
| `sh tests/dist/run.sh DIR` | 104 of 104 |
| `sh tests/dist/export.sh DIR` | 1 of 1 |
| `sh tests/oracle/check.sh` | 0 failures |

`tests/edge/snapshot.mjs`, run from `arena.sh`, checks:

- the exports, and a single mutable global in the module;
- 200 requests in a row on one instance, every answer exact;
- 50 simultaneous first requests on one instance;
- a new instance after a request that grew the memory to 312 pages, with the
  control that a small request keeps the instance;
- a second request that arrives while the first waits on a suspending host
  import gets a new instance, and the next request is back on the shared one;
- the `--no-snapshot` and `snapshot: false` controls.

As a negative control run by hand, the isolation test was run against a copy of
the shim with the write-back removed: the second request trapped at `_start`.

## Addition, 2026-11-13: the instance made at startup

On the owner's instruction, `prepareModule(mod)` in `wasi_shim.mjs` makes the
shared instance synchronously (`new WebAssembly.Instance`), and the `index.mjs`
that `--emit-worker` writes calls it at global scope. The instantiation then
falls in the isolate's startup, which Workers limits to 1 s, and not in the
first request's CPU time. It applies only to a module without host imports:
which host imports suspend is decided from the request's env, which global
scope does not have. For any other module it returns false and nothing
changes. `x-spinel-instance` gained `made=startup` or `made=request`.
An existing project keeps its own `index.mjs` (`--emit-worker` writes it only
when absent), so it needs the two lines added by hand.

`tests/edge/snapshot.mjs` checks that the instance exists before any await,
that the first two requests run on it with no other instance made, that the
module built with `--no-snapshot` and the host-API module are left alone, and
that after the startup instance is let go a request makes the next one. Under
`wrangler dev --local` (wrangler 4.160.1), four requests to the arena build of
hello-http all answered `reused call=1..4 made=startup`.

The suites `tools/test/affected.rb --base main` selected for the addition, on
Debian 13, 2026-11-13: `tests/edge/arena.sh` 33 passed, 0 failed, the same 2
known defects; `tests/edge/isolation.sh` 13 passed on each build;
`tests/edge/run.sh` 40 passed; `tests/compute/run.sh` 75/0/0;
`tests/fiber/run.sh` 81/0/0; `tests/ghostty-terminal/run.sh` 3 passed,
1 skipped (no built Ghostty checkout); `tests/imports/run.sh` 10 of 10;
`tests/oracle/check.sh` 0 failures; `git diff --check` on `docs` clean.

Measured on Cloudflare on 2026-11-13: hello-http's arena build with this
addition, deployed as a test Worker since deleted. The deploy reported a
startup time of 1 ms. Of 400 requests, all answered correctly and all ran on
an instance made at startup. CPU time, as median, p90 and maximum, was 0, 1
and 13 ms for 187 `/info` requests and 0, 1 and 2 ms for 184 `/echo` requests
(371 of the 400 reached the tail). The four slow `/info` requests (11, 5, 8
and 13 ms) are the four first requests on new isolates (`call=1`). Making the
instance at startup did not remove that cost: it is in the first run of the
module's code, not in the instantiation. In node, on Debian, the instance took
0.6 to 0.9 ms of CPU, the first request 2.6 to 4.1 ms and the next ones 0.1 to
0.3 ms. The likely cause, V8 compiling each function when first called, is
not confirmed.
