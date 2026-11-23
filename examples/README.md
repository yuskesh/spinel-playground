# Examples

Each directory is a program written in Ruby and compiled by the pinned Spinel,
with its build and run command. Build `vendor/spinel` first
([building](../docs/building.md)); an example's own README lists anything
else it needs. The `tests/` suite named on each line is the check that runs it.

| Example | What it is | Build and run | Checked by |
|---|---|---|---|
| [doom](doom/README.md) | the DOOM engine in Ruby: headless demo playback, SDL play, the CORE route and the GPU raster path | `tools/doom/fetch-iwad.sh`, then `examples/doom/build.sh` and `build/doom/doom -iwad build/doom-wad/doom1.wad` | `tests/doom/`, `tests/doom-core/`, `tests/raster/`, `tests/gcmon/` |
| [spinel-vi](spinel-vi/README.md) | a small vi over termbox2, libgrapheme and POSIX regex | `examples/spinel-vi/build.sh && examples/spinel-vi/run.sh FILE` | `tests/spinel-vi/run.sh` |
| [mvc-blog](mvc-blog/README.md) | a Rails-style blog, native CGI or a Workers module with KV | `examples/mvc-blog/build.sh`, then `wrangler dev --local` in `dist/` | `tests/mvc-blog/run.sh` |
| [hello-http](hello-http/app.rb) | the smallest Workers program: a request in as ARGV and stdin, the response on stdout | `examples/hello-http/build.sh`, then `wrangler dev --local` in `dist/` | `tests/edge/run.sh` |
| [fetch-kv](fetch-kv/app.rb) | outbound HTTP and a KV binding through the host bridge (`--host-api`) | `examples/fetch-kv/build.sh`, then add the KV binding to `dist/wrangler.toml` | `tests/edge/run.sh` |
| [r2-d1](r2-d1/README.md) | an asset store: bytes in R2, facts about them in D1 | `examples/r2-d1/build.sh`, then `wrangler dev --local` in `dist/` | `tests/edge/run.sh` |
| [hello-fastly](hello-fastly/README.md) | one program, unchanged, on Fastly Compute and on Workers | `examples/hello-fastly/build.sh`, then serve `dist/` or `dist-workers/` | `tests/edge/run.sh` |
| [gatekeeper](gatekeeper/README.md) | a 2 KB freestanding gate that sheds requests before the full Ruby Worker starts | `examples/gatekeeper/build.sh`, then `wrangler dev --local` in `dist/` | `tests/edge/run.sh` |
| [edge-twin](edge-twin/README.md) | one kernel on a Cortex-M33 under Zephyr and in a Worker; the edge replays the device's log | `examples/edge-twin/build.sh && examples/edge-twin/run_demo.sh` | `tests/edge/run.sh` |
| [tensor](tensor/README.md) | `tensor_def`, `assign!` fusion and `tensor_extern` (MNIST) on the CPU and the Apple GPU through IREE | `./build.sh && ./run.sh` in `dense-relu/`, `fusion/` or `mnist/` | `tests/tensor/run.sh` |
| [image](image/README.md) | 4K image filtering and resizing with the tensor surface, CPU or Apple GPU | `./build.sh && ./run.sh` in `filter/` or `resize/` | `tests/tensor/run.sh` |
| [ebpf-go](ebpf-go/xdp-counter/README.md) | a Go program that builds an XDP packet counter through the SpBPF lane and reads its ring buffer (Linux; `otlp-agent/` is an oracle kept as files) | `$GO generate ./... && $GO build -o xdp-counter .` in `xdp-counter/` (see its README) | `tests/ebpf-go/run.sh`, `tests/ebpf-go/live.sh` |
| [ghostty-terminal](ghostty-terminal/README.md) | a prototype terminal in the browser: a Ruby shell in wasm on libghostty-vt, drawn with WebGPU shaders written in Ruby | `examples/ghostty-terminal/build.sh OUT` | `tests/ghostty-terminal` |

`tools/` holds helpers for these examples, not an example: `forge.rb` and
`post_fmt.rb` serve edge-twin's demo, and `kern_sig.rb` writes a freestanding
kernel's boundary signature from its generated header.

The Workers examples need `tools/wasm`'s toolchain and `wrangler` (see
[tools/wasm](../tools/wasm/README.md)); edge-twin's device half needs Zephyr;
tensor and image need IREE ([its installation record](../docs/toolchains/iree-3.11.0/INSTALLATION-RECORD.md)).
