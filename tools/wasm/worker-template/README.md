# Spinel on Cloudflare Workers

This project was written by `spinel-wasm --emit-worker`. It runs one Ruby
program, compiled to `app.wasm`, as a Worker.

```bash
npx wrangler dev --local
curl -X POST --data-binary 'héllo' 'http://localhost:8787/echo'
curl 'http://localhost:8787/info?a=1&b=2'
```

`--local` runs workerd on this machine: no account and no network.

## Files

| File | Role |
| --- | --- |
| `app.wasm` | the Ruby program, built by the same `--emit-worker` run |
| `index.mjs` | the entry point: imports `app.wasm` at module scope, makes its instance at startup for an arena module (`prepareModule`), and hands it to `serveSpinel` |
| `worker.mjs` | turns a Request into ARGV, stdin and ENV, and stdout into a Response (a copy of `tools/wasm/worker.mjs`) |
| `wasi_shim.mjs` | the `wasi_snapshot_preview1` implementation (a copy of `tools/wasm/wasi_shim.mjs`) |
| `spinel_host.mjs` | the host API (outbound HTTP, KV, R2, D1). Wired in only for a module built with `--host-api` |
| `wrangler.toml` | the `[[rules]] CompiledWasm` rule and `[vars]` |
| `examples/` | Ruby programs showing the contract: `echo`, `env`, `fetch` and `r2d1` |

## The Ruby side: the CGI contract, and no new API

| Ruby | Meaning |
| --- | --- |
| `ARGV[0]` | the path, for example `"/echo"` |
| `ARGV[1]` | the raw query string, for example `"a=1&b=2"`, or `""` |
| `$stdin` | the request body, as bytes. Empty for GET and HEAD |
| `ENV` | wrangler `[vars]` and secrets (string values only), plus the CGI variables: `REQUEST_METHOD`, `PATH_INFO`, `QUERY_STRING`, `CONTENT_TYPE`, `CONTENT_LENGTH`, `HTTP_*` |
| `$stdout` | the response body, as bytes |
| `$stderr` | goes to `console.error`, and becomes the body of a 500 |
| `exit(n)` | `n == 0` gives **200**, and anything else gives **500** with `$stderr` as the body |

To choose the status and headers from Ruby, set `SPINEL_CGI_HEADERS = "1"` in
`[vars]` and print a CGI header block (`Status: 404`, `Content-Type: ...`, then
a blank line) before the body.

## Outbound HTTP and bindings: `--host-api` (opt-in)

A module built with `--host-api` can `require "edge/http"` and `require
"edge/kv"`; `cloudflare/r2` and `cloudflare/d1` are also available. Each call
suspends the module while JavaScript does the work. Reachability is declared
in `wrangler.toml`, never assumed:

```toml
[vars]
SPINEL_HOST_KV = "MY_KV"          # the KV bindings Ruby may reach
# SPINEL_HOST_FETCH = "0"         # turn outbound HTTP off
# SPINEL_HOST_MAX_BODY = "1048576"
```

## Replacing the program

Build another program into this directory with
`spinel-wasm your.rb --emit-worker <this dir>`, then run
`npx wrangler dev --local` again.

## Limits

wasm32 has no threads, fibers, sockets, processes or filesystem, so programs
using `Thread`, `Fiber`, `Socket`, `Kernel#system` or `Dir` are refused at build
time. Integer is 32-bit on this target with the pinned runtime; a value that
does not fit is promoted or raises, as its overflow mode says, and never wraps
silently.
