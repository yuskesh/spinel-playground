# Cloudflare Workers limits for Spinel WASM modules

This page records the Cloudflare Workers limits that bind the modules
`tools/wasm/spinel-wasm` builds, and what our own measurements say about them.
The limits were read on **2026-09-24** from Cloudflare's
[Limits](https://developers.cloudflare.com/workers/platform/limits/) and
[Pricing](https://developers.cloudflare.com/workers/platform/pricing/) pages.
Cloudflare changes them; check those pages before relying on a figure here.

## The limits

| Limit | Workers Free | Workers Paid |
|---|---|---|
| Requests | 100,000 per day | 10 million per month included, then billed |
| CPU time per HTTP request | **10 ms** | 5 min (default 30 s) |
| Memory per isolate (JavaScript heap and WebAssembly allocations) | 128 MB | 128 MB |
| Subrequests per request | 50 | 10,000 |
| Simultaneous outgoing connections | 6 | 6 |
| Worker size (uncompressed; there is no compressed-size limit) | 64 MiB | 64 MiB |
| Startup time (parsing and running the global scope) | 1 s | 1 s |
| Environment variables | 64 per Worker, 5 KB each | 128 per Worker, 5 KB each |
| Cache API calls per request | 50 | 1,000 |
| Log data per request | 256 KB | 256 KB |

On the Free plan the daily limits reset at 00:00 UTC. Once a limit is exceeded,
further operations of that type fail with an error.

What the CPU limit counts, in Cloudflare's words:

- "Waiting on network requests (such as `fetch()` calls, KV reads, or database
  queries) does not count toward CPU time."
- "Each isolate has some built-in flexibility to allow for cases where your
  Worker infrequently runs over the configured limit." A Worker that exceeds it
  consistently is terminated, and the client sees error 1102.

Cloudflare does not expose a request's CPU time to the Worker itself. The
figure per invocation appears in Workers Logs.

## What our modules measured

These figures are **not measured on Cloudflare**; for those, see
[Measured on Cloudflare](#measured-on-cloudflare-2026-11-12). Each request instantiates the
module, runs `_start` and discards the instance, as `tools/wasm/worker.mjs`
did for every module before [decision 0039](../decisions/0039-arena-instance-reuse.md).
Compiling the module is not counted, because Workers compiles it once per
isolate. CPU time is the process's user plus system time around instantiation
plus run, measured single-threaded (`node --single-threaded`) so that V8's own
work lands on the request; the figure is the median of 1,000 requests after 200
warm-up requests.

### At the current pin, 2026-11-01

Measured at pin `ed8c753a4` (commit `27d542a`) with node
v24.20.0 on a Debian x86_64 host (Intel Core i7-12700K), both builds at `-O2`,
on hello-http. The arena build is `--request-arena`, which is upstream's
`--gc=none` with the slab off by default; `SPINEL_GC_SLAB` was not set for the
ordinary build. `POST /echo` sends 1,024 bytes.

| hello-http | Ordinary build | Arena build (`--gc=none`) | Arena / ordinary |
|---|---|---|---|
| Module, raw | 966,677 B | 940,993 B | 0.973 |
| Module, gzip -9 | 324,834 B | 316,396 B | 0.974 |
| Linear memory at start | 16 pages | 7 pages | |
| Linear memory after one request | 1,104 pages (69 MiB) | 8 pages (512 KiB) | |
| CPU per request, `GET /info` | 1.644 ms | 0.695 ms | 0.423 |
| CPU per request, `POST /echo` | 1.297 ms | 0.569 ms | 0.439 |

On the same pin and host, the arena build is about 3% smaller than the ordinary
build and uses about 42-44% of its CPU per request. With `SPINEL_GC_SLAB=1` the
same arena module grows to 1,095 pages after one request. Every median is under
a fifth of the Free plan's 10 ms. mvc-blog, the 64 KiB echo and `-Oz` were not
measured at this pin.

These figures are not comparable with the 2026-09-24 ones below. The ordinary
build itself measured 2.9 times larger and 4.7 to 5.7 times slower than on
2026-09-24, so most of the change is the pin and the host. The recorded arena
was about 10% smaller than the ordinary build and used about 23% of its CPU;
whether `--gc=none` gains less than the arena did, or the pin and host account
for the difference, **has not been separated**.

### Recorded for the process-lifetime arena, 2026-09-24 (history)

The arena these figures describe was replaced by `--gc=none` on 2026-11-01. They
come from node v24.12.0, which uses the same V8 engine, on an Apple M1 Max, on
2026-09-24 at `main` `d301113`. An M1 Max core is faster than a Cloudflare edge
core, so read them as optimistic.

| Request | Ordinary build, `-O2` | Arena build, `-O2` |
|---|---|---|
| hello-http `GET /info` | 0.290 ms | 0.065 ms |
| hello-http `POST /echo`, 1 KiB | 0.276 ms | 0.063 ms |
| hello-http `POST /echo`, 64 KiB | 0.292 ms | 0.110 ms |
| mvc-blog index | 0.424 ms | 0.470 ms (0.175 ms at `-Oz`) |
| mvc-blog create | 0.352 ms | 0.194 ms (0.095 ms at `-Oz`) |

The rare slow request is a V8 major garbage collection that lands inside it.
In the arena build, 73% of the per-request JavaScript garbage that triggers
those collections is the new `WebAssembly.Instance` and V8's JS-to-wasm
wrappers. That cost belongs to the one-instance-per-request model. On
mvc-blog's index, the arena build's instantiation p99 was about 3.2 ms with
V8 confined to one thread, and 0.14-0.17 ms (maximum 0.86-1.5 ms) with node's
normal concurrent GC. Cloudflare tunes V8's GC differently from node, so
neither figure is Workers'. Whether concurrent GC work is billed to a request
is not known.

| hello-http | Ordinary build | Arena build |
|---|---|---|
| Linear memory after one request | 69 MiB (1,104 pages) | 256 KiB (4 pages) |
| Module, `-O2`, gzip -9 | 121.0 KB | 110.1 KB |
| Module, `-Oz`, gzip -9 | 106.3 KB | 96.8 KB |

The ordinary build reaches 69 MiB because the runtime's slab allocator reserves
64 MB of linear memory at startup on WASI. The arena build turns the slab off,
so its memory stays small. See `tools/wasm/README.md` for how to select it.

## Measured on Cloudflare, 2026-11-12

One deployed Worker, one run. The module is hello-http built with
`tools/wasm/spinel-wasm examples/hello-http/app.rb --request-arena
--emit-worker` at main `dc232181` (pin `c23d82a7c`), LLVM 23.1.1 and wasi-sdk
34's sysroot on the Debian host: `app.wasm` 941,341 B. wrangler 4.160.1
deployed the project as `spinel-hello` on a `workers.dev` route, one version;
it reported a total upload of 958.87 KiB, 326.19 KiB gzipped. `wrangler.toml`
enabled Workers Logs (`[observability]`, head sampling 1), and the Worker
required the `SPINEL_AUTH_TOKEN` bearer secret: a request without it, or with a
wrong one, got 401. With it, `/info`, `/echo` and `/fail` answered as under
`wrangler dev --local`.

From a client on the internet, one request at a time, 200 `GET /info?a=1&b=2`
and 200 `POST /echo` with a 1,024-byte body, after one unmeasured request.
Every request got 200. CPU and wall time are the `cpuTime` and `wallTime`
fields of the events `wrangler tail --format json` captured, in whole
milliseconds as Cloudflare gives them. The tail captured 198 of the 200
`/info` requests and 193 of the 200 `/echo` requests; it is best-effort, and
the missing nine were not looked for.

| hello-http, arena build | `GET /info` | `POST /echo`, 1 KiB |
|---|---|---|
| Events (outcome `ok`) | 198 | 193 |
| CPU time, median | 2 ms | 3 ms |
| CPU time, p90 | 5 ms | 5 ms |
| CPU time, maximum | 11 ms | 9 ms |
| Requests above 10 ms CPU | 1 | 0 |
| Wall time, median / p90 / maximum | 3 / 6 / 12 ms | 3 / 6 / 10 ms |

p90 is the nearest rank. The client's own round trip (curl's `time_total`,
information only) had a median of 118 ms for `/info` and 115 ms for `/echo`.

- The medians are about three to five times the local figures above
  (0.695 ms and 0.569 ms). Those were measured at another pin, on another
  host, and on a module built at `ed8c753a4`, so the factor mixes the edge's
  cores, Cloudflare's V8 settings, the per-request instantiation and the
  change of pin; none of these has been separated. With whole-millisecond
  readings, the two medians do not tell the two paths apart.
- Against the Free plan's 10 ms, the medians and p90 leave room, but one
  `/info` request in 198 used 11 ms. Cloudflare tolerates an occasional
  overrun (above); a program that does more per request than hello-http has
  less margin.

### A freestanding module beside it, the same day

A second Worker, `spinel-add`, serves one freestanding function: E040's
`add` (`a + b` on i32), the 168 B `kern.one.wasm` that
`tests/freestanding/e063/build.sh` links, with the same tools and LLVM. Its
JavaScript is `tests/freestanding/e063/probe/index.mjs` with the same bearer
gate added and one change: `fresh=1` in the query makes a new instance for
the request, as hello-http's Worker does for every request; without it one
instance per isolate serves every request. The module has no heap and no
collector, so reuse carries no state from one request to the next. The upload
was 3.33 KiB, 1.60 KiB gzipped. Measured as above: 200 `GET
/add?a=20&b=22` and 200 with `&fresh=1`, one at a time, every one a 200 with
`42`.

| spinel-add | Instance reused | New instance per request |
|---|---|---|
| Events (outcome `ok`) | 196 | 193 |
| CPU time, median | 0 ms | 2 ms |
| CPU time, p90 | 0 ms | 4 ms |
| CPU time, maximum | 4 ms | 7 ms |
| Wall time, median / p90 / maximum | 0 / 1 / 7 ms | 3 / 5 / 10 ms |

183 of the 196 reused requests read 0 ms. With a new instance, a 168 B
module with no runtime used a median of 2 ms, as much as hello-http's
941,341 B module did for `/info`. On Cloudflare, then, most of hello-http's
per-request CPU time goes with making an instance, not with the size of the
runtime it carries. What in making an instance costs it (linear memory, the
JavaScript-to-wasm wrappers, or something else) was not measured.

### One instance per isolate for hello-http, 2026-11-12 and 2026-11-13

Two prototypes of the same hello-http keep one instance per isolate and
reuse it for every request. They were built from the tools at main
`eab8d452` with local changes that are **not in this repository**: a modified
copy of `tools/wasm/`, its `reactor.c` and a JavaScript runner beside
`worker.mjs`. B became `tools/wasm`'s behaviour for arena modules in
[decision 0039](../decisions/0039-arena-instance-reuse.md); A did not.

- **A, reactor.** `--mode reactor`, the ordinary collected build, 969,245 B.
  `_initialize` runs once; each request calls `main` again through
  `sp_reactor_run`. Ruby-level state (globals, caches) carries from one
  request into the next.
- **B, snapshot.** The `--request-arena` command module, 941,388 B, linked
  with an `sbrk` that grows linear memory in place and with
  `__stack_pointer` exported. The runner copies the linear memory once after
  instantiation; before each request it writes the copy back, zeroes the
  rest and resets the stack pointer, so each request starts from the bytes a
  new instance would have.

Both put each request's WASI state (arguments, environment, standard input
and output) behind import functions that forward to the current request,
because imports are bound when the instance is made.

Two defects showed up on the way, both handled only in the prototypes:

- A trapped on its 295th request in a collection inside `main`. The
  generated `main` sets `sp_argv.len` before it fills `sp_argv.data` from
  `malloc`, so a collection triggered while the strings are copied marks
  slots not yet written. In a command module those slots are fresh, zeroed
  memory; in a reactor `malloc` hands back a freed block holding allocator
  links. Prototype A zeroes the argument array as it is allocated. Upstream
  `matz/spinel` at `f2c23f5` (2026-11-12) generates the same order.
- The first versions cached the instance only after `WebAssembly.instantiate`
  resolved, so requests arriving together on a new isolate each made an
  instance (200 simultaneous requests made 200 in node). The runners now
  share the instance being made. One request runs to completion at a time on
  an isolate, since nothing in hello-http's path waits on the host; a module
  that suspends mid-request (a host call through JSPI) would let another
  request into the same memory.

Locally with node, 10,000 requests through each prototype gave 0 wrong
answers. Linear memory stayed at 1,104 pages (69 MiB) for A, whose collector
reserves a 64 MB slab on WASI, and at 8 pages (512 KiB) for B.

On Cloudflare both were deployed as their own Workers with the bearer gate,
and measured as `spinel-hello` was, on the versions that share the instance
being made: 200 `GET /info?a=1&b=2` and 200 `POST /echo` with 1,024 bytes,
one at a time, every answer checked against a hand-written expectation (all
400 right on each). The tail captured fewer events than on 2026-11-12.

| CPU time, median / p90 / max | `GET /info` | `POST /echo`, 1 KiB |
|---|---|---|
| A, reactor | 0 / 1 / 2 ms (195 events) | 0 / 0 / 1 ms (184 events) |
| B, snapshot | 0 / 1 / 14 ms (197 events) | 0 / 1 / 2 ms (186 events) |
| `spinel-hello`, new instance per request (above) | 2 / 5 / 11 ms | 3 / 5 / 9 ms |

Each response named how many calls its isolate's instance had served. In
this run no request in A's set made a new instance, and four in B's did;
those four used 14, 5, 6 and 7 ms. A first run of both, on versions
that did not yet share the instance being made, gave the same medians within
1 ms and maxima of 18 to 21 ms, with seven new instances in each set. How
many new instances a run meets depends on how Cloudflare places requests on
isolates.

- With the instance reused, hello-http's per-request CPU time on Cloudflare
  falls from a median of 2 to 3 ms to 0 to 1 ms. Whole-millisecond readings
  do not tell A and B apart.
- The cost moves to the first request on each new isolate: 5 to 21 ms of
  CPU in these runs, sometimes above the Free plan's 10 ms.
- A keeps Ruby state across requests and needs 69 MiB of the isolate's
  128 MB; B keeps the clean start of every request at about 1 MiB (its
  memory plus the copy) and writes back 448 KiB per request.

## Consequences for building

- Build Workers modules with the arena (`--request-arena`, or
  `# spinel-tier: arena`). At the current pin it stays at 8 pages (512 KiB)
  after a request, against the ordinary build's 1,104, and uses about 42-44%
  of the ordinary build's CPU per request on the same host.
- On the Free plan, keep `-O2`. `-Oz` shrinks the module but costs up to about
  53% CPU (spectral norm, per the driver's help). The CPU limit binds before the
  size limit does.
- Cloudflare recommends instantiating WebAssembly once at global scope and
  reusing the instance
  ([Wasm in JavaScript](https://developers.cloudflare.com/workers/runtime-apis/webassembly/javascript/)).
  On Cloudflare, a new instance cost a median of 2 ms of CPU even for a
  168 B module, and a reused one read 0 ms (above). An arena module built by
  `spinel-wasm` is now served that way: one instance per isolate, its memory
  written back before each request so that every request still starts from a
  new instance's bytes ([decision 0039](../decisions/0039-arena-instance-reuse.md));
  B above measured 0 to 1 ms. Without host imports, the generated `index.mjs`
  makes that instance at global scope, in the isolate's startup. A module
  built with a collector still gets a new instance per request.
- The real CPU time on Cloudflare comes from Workers Logs or `wrangler tail`.
  For hello-http's arena build it was a median of 2 to 3 ms per request
  (above), several times the local estimate; budget from Cloudflare's figures,
  not from the local ones.
