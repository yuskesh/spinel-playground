# examples/http_server/

The place for the deliverables of the project goal "implement an HTTP server with spinel + eBPF"
set by ADR-005.
Added step by step following the P001 roadmap.

## Layout (planned)

```
examples/http_server/
├── README.md           # ← this file
├── M001/               # spinel-only HTTP/1.0 server (to be completed in E035)
│   ├── server.rb       # Ruby input for spinel
│   ├── README.md       # build + start + curl check
│   └── ab_results.txt  # baseline numbers (vs nginx)
├── M002/               # + XDP early reject + L7 metric
│   ├── server.rb
│   ├── filter.rb       # spinel-ebpf input (XDP / TC)
│   ├── README.md
│   └── ab_results.txt
├── M003/               # + SO_REUSEPORT BPF + multi-worker
│   └── ...
└── M004/               # + kernel-side static response (XDP/sockmap)
    └── ...
```

Each milestone is **a working, complete server implementation**. Work proceeds by stacking new
optimizations one step at a time on top of the previous milestone.

## Start (as expected after M001 is achieved)

```bash
# inside the Apple container
container exec dev bash -c '
  cd /work/examples/http_server/M001
  /work/bin/spinel-ebpf compile server.rb -o build --build --native-only
  ./build/server &
  sleep 1
  curl -v http://127.0.0.1:8080/
'
```

## Benchmarks

Each milestone's `ab_results.txt` lists the result of `ab -c <N> -n <M>` side by side with the
numbers of **nginx alpine under the same conditions** (see P001 §benchmark infrastructure).

## Current state

- M001: **not started** (the next task)
- M002: not started
- M003: not started
- M004: not started

Progress is updated in P001 §Status (in the P001 roadmap, which is not part of this tree).
