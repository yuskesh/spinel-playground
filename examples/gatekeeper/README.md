# gatekeeper — a 2 KB gate in front of a full Ruby Worker

One Worker, two wasm modules. `kern.wasm`, about 2 KB, is Ruby compiled through
the freestanding `wasm32-worker` profile. It decides about every request
before the full Ruby module (`app.wasm`, built by `spinel-wasm`) is
instantiated at all. A request the gate sheds costs a 2 KB module, not a Ruby
runtime.

```sh
./build.sh                          # dist/: kern.wasm, app.wasm and the router
(cd dist && npx wrangler dev --local)
curl -H 'x-user-id: alice' -H 'user-agent: Mozilla/5.0' localhost:8787/api/me
curl -s localhost:8787/__gate/stats
```

## The gate (`kern.rb`, called by `index.mjs`)

| Stage | Kernel | Refusal |
|---|---|---|
| bot score | `bot_score` / `bot_block`, from six integer features | 403 |
| token bucket | `tb_allow` / `tb_tokens` / `tb_retry_after` | 429 with `Retry-After` |
| A/B bucket | `bucket_hrw` | — (sets `X-Gate-Variant`) |

Every refusal carries `x-gate-app-run: 0`: the Ruby module did not run. A kernel
trap, such as an arithmetic overflow in a refill computation, answers 422
instead of letting the limiter fail open. The settings are in `[vars]`:
`GATE_RATE_MT_S`, `GATE_BURST_MT`, `GATE_COST_MT`, `GATE_BUCKETS` and
`GATE_BOT_THRESHOLD`.

The kernel is built with this repository's `spinel-fs-emit`; spinel-llvm used
its `spinel-mlirgen` front, which took the same arguments.

## Checked

`tests/edge/run.sh` runs it under local workerd:

- An ordinary request to `/api/me` is admitted and runs the Ruby module.
- With the default 20-token burst, the first 20 rapid requests from one identity
  pass, later ones get 429 with `Retry-After`, and none of those runs the module.
- A request built from `bot_score`'s own weights to score exactly 60, the
  threshold, gets 403 with that score and does not run the module.
