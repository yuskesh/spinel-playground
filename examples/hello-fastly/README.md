# hello-fastly — one Ruby program on Fastly Compute and Cloudflare Workers

The same `app.rb`, with no edit and no conditional compilation, is built twice
and answers alike on both platforms.

```sh
./build.sh      # dist/ for Fastly, dist-workers/ for Workers
(cd dist && fastly compute serve --skip-build)           # Viceroy, :7676
(cd dist-workers && npx wrangler dev --local)            # workerd, :8787
curl 'http://127.0.0.1:7676/info?a=1&b=2'
curl 'http://localhost:8787/info?a=1&b=2'
```

Both platforms run the same CGI contract. On Workers, JavaScript
(`worker.mjs`) translates requests; on Fastly, `fastly_cgi.c` does it inside
the module. The host API (`Edge::HTTP`, `Edge::KV`) is the same Ruby surface
on both.

## Routes

| Route | Answer |
|---|---|
| `POST /echo` | the body, byte for byte |
| `GET /info` | path, query, parsed params, method, content type, a probe header, body size |
| `GET /kv` | a counter in the KV store `app_kv` |
| `GET /platform` | which platform answered. This one differs by design |
| `GET /fetch` | a request to the backend `origin` through `Edge::HTTP` |
| `/errors`, `/fail`, `/raise`, `/rescue`, `/status` | the error and status paths: a failing exit, an uncaught and a rescued exception, a chosen status |

## Differences it does not hide

- `Edge::HTTP` takes `backend:`, which Fastly requires and Workers ignores, so
  the program always passes it.
- `Cloudflare::R2` and `Cloudflare::D1` raise `NotImplementedError` on Fastly,
  which has no equivalent. The build prints a note saying so.

## Checked

`tests/edge/run.sh` serves both builds against the same local origin. It
requires `/echo`, `/info` and `/kv` to answer byte for byte alike on Viceroy
and workerd, and `/echo` to return its body. Only well-formed requests count:
a GET carrying a body is passed through by Fastly and dropped by Workers.
