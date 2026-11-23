# Go 1.25.14 -- installation record

Go builds `tools/ebpf/go` (the spbpf builder and `spbpf-bindgen`) and
`examples/ebpf-go`. Debian 13 did not have it. It is installed user-local, and
the checks call it by full path through `GO`. It is not on `PATH`, as in
spinel-llvm.

| | |
|---|---|
| version | go1.25.14, linux/amd64. The modules declare `go 1.25.0`; this is the newest 1.25 release on 2026-09-23 |
| archive | `https://go.dev/dl/go1.25.14.linux-amd64.tar.gz`, sha256 `a21ae5633a269bcd7e90cf767e48225633795e99d831742cbf3397064fee7712` (the value go.dev publishes) |
| location | `~/toolchains/go-1.25.14` |

```sh
cd ~/toolchains
curl -sSLo go1.25.14.linux-amd64.tar.gz https://go.dev/dl/go1.25.14.linux-amd64.tar.gz
echo "a21ae5633a269bcd7e90cf767e48225633795e99d831742cbf3397064fee7712  go1.25.14.linux-amd64.tar.gz" | sha256sum -c -
mkdir go-1.25.14 && tar -xzf go1.25.14.linux-amd64.tar.gz -C go-1.25.14 --strip-components=1
export GO=$HOME/toolchains/go-1.25.14/bin/go GOTOOLCHAIN=local
```

`GOTOOLCHAIN=local` stops Go from downloading another toolchain. The module
cache and the build cache are Go's per-user defaults (`~/go/pkg/mod`,
`~/.cache/go-build`). Modules come from `proxy.golang.org` and are checked
against `go.sum`. `xdp-counter` requires `github.com/cilium/ebpf v0.22.0` and
`golang.org/x/sys v0.43.0`, and its `go.sum` pins 13 modules of their graph.
The spbpf package and the otlp agent use the standard library only. Nothing system-wide was changed.
