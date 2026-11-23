# Spinel on Fastly Compute

This package was written by `spinel-wasm --emit-fastly`. It serves one Ruby
program as a Fastly Compute guest (a `wasm32-wasip1` command module), and
`fastly compute serve` runs it as it is.

```bash
fastly compute serve --skip-build          # local, under Viceroy
curl -X POST --data-binary 'héllo' 'http://127.0.0.1:7676/echo'
curl 'http://127.0.0.1:7676/info?a=1&b=2'
```

## Files

| File | Role |
| --- | --- |
| `bin/main.wasm` | the Ruby program. The path is fixed: `fastly compute pack` looks only here |
| `fastly.toml` | the manifest: `language = "other"` (no SDK), and `[local_server]` declarations for backends, KV and Config stores |
| `examples/` | Ruby programs showing the contract: `echo.rb` and `portable.rb` |

## The same program as on Workers

The Ruby contract is the CGI form, identical to the Cloudflare Workers one:

| Ruby | Meaning |
| --- | --- |
| `ARGV[0]` | the path |
| `ARGV[1]` | the raw query string, or `""` |
| `$stdin` | the request body, byte for byte |
| `ENV` | the CGI variables (`REQUEST_METHOD`, `PATH_INFO`, `QUERY_STRING`, `CONTENT_TYPE`, `CONTENT_LENGTH`, `HTTP_*`), plus nine `FASTLY_*` platform values |
| `$stdout` | the response body, byte for byte |
| `$stderr` | Fastly's log endpoint, and the body of a 500 |
| `exit(0)` | 200. `exit(n)` gives 500 and discards `$stdout`, whose size is reported in `x-spinel-stdout-bytes` |

Only where the translation lives differs. On Workers, JavaScript (`worker.mjs`)
does it. Fastly has no JavaScript layer, so the same layer is linked inside the
module (`tools/wasm/fastly/fastly_cgi.c`). `examples/portable.rb` is built for
both platforms, and its `/echo`, `/info` and `/kv` answers match byte for byte.

## The host API (a module built with `--host-api`)

```ruby
require "edge/http"
r = Edge::HTTP.request("http://origin.example/", backend: "origin")
Edge::KV.put("app_kv", "k", "v")
Edge::KV.get("app_kv", "k")        # "v", or nil when absent (not "")
Fastly::Config.get("spinel", "SPINEL_CGI_HEADERS")
```

- **`backend:` is required on Fastly**; leaving it out raises `ArgumentError`
  before any traffic. Workers ignores the argument, so writing it always keeps
  one program working on both.
- Only KV stores, backends and Config stores declared in `fastly.toml`'s
  `[local_server]` (locally) or in the service configuration (at the edge) are
  reachable. An undeclared name raises `ArgumentError` naming it; it never
  answers a silent nil.
- `Cloudflare::R2` and `Cloudflare::D1` raise `NotImplementedError` on Fastly,
  which has no equivalent hostcall and no SQL database. An empty result would
  be an answer where there is none.

## Caution

`fastly compute serve` enforces none of the edge's limits (CPU, heap, stack,
wall time, outbound requests), so passing locally is not evidence of passing at
the edge. The local KV store is in memory and is lost when `serve` stops.
