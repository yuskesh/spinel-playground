# fib flame graph — visualizing "what gets faster" with spinel (AOT) vs CRuby (E181)

The same `fib.rb` is run under the **CRuby interpreter** and as **spinel AOT native**, and on-CPU flame graphs
taken with `perf` + FlameGraph are compared. The aim is not the speed difference itself but visualizing
**"which work, concretely, spinel's speedup removes"**.

## Results (fib(38), Apple container / debian:trixie / Ruby 3.3.8)

| | wall time fib(35) | where on-CPU time goes |
|---|---|---|
| CRuby | 0.93s | `vm_exec_core` **89.6%** (bytecode dispatch) + `vm_call_iseq_setup_*` 7.5% (method calls) + `vm_opt_plus` 2.1% (boxed `+`) |
| spinel | 0.037s (**~25x**) | `sp_fib` **100%** (native recursion, no interpreter) |

→ What spinel removes is **the interpreter machinery itself** (instruction dispatch, method
call setup, integer boxing). The "actual computation" of `fib` is buried inside
`vm_exec_core` in CRuby; in spinel it becomes the native instructions of `sp_fib` directly.

The flame graph SVGs are in `docs/experiments/results/E181/`
(`cruby_flame.svg` / `spinel_flame.svg`).

## Reproduction steps (inside the container)

```bash
container exec spnlbuild bash -c '
  set -e; export LANG=C.UTF-8; cd /work
  FG=/opt/FlameGraph   # flamegraph.pl / stackcollapse-perf.pl

  # --- spinel: build the AOT native binary with frame pointers ---
  # (unwinding the user stack for perf/eBPF needs -fno-omit-frame-pointer) ---
  ruby bin/spinel-ebpf compile examples/profiling/fib_flamegraph/fib.rb \
    -o /tmp/fibb --native-only            # generates fib.c
  clang -O2 -g -fno-omit-frame-pointer -I third_party/spinel/lib -I include \
    /tmp/fibb/fib.c third_party/spinel/lib/libspinel_rt.a -lm -o /tmp/fib_spinel

  # --- fetch debug symbols to resolve CRuby interpreter function names ---
  export DEBUGINFOD_URLS="https://debuginfod.debian.net/"
  BID=$(readelf -n /lib/aarch64-linux-gnu/libruby-3.3.so.3.3 \
        | grep -oE "Build ID: [0-9a-f]+" | awk "{print \$3}")
  debuginfod-find debuginfo "$BID" >/dev/null
  mkdir -p /usr/lib/debug/.build-id/${BID:0:2}
  ln -sf /root/.cache/debuginfod_client/$BID/debuginfo \
         /usr/lib/debug/.build-id/${BID:0:2}/${BID:2}.debug

  # --- sampling (same fib(38), wall ~4s matched with loops) ---
  perf record -e cpu-clock -F 299 --call-graph fp -o /tmp/cr.data -- \
    env FIB_N=38            ruby examples/profiling/fib_flamegraph/fib.rb
  perf record -e cpu-clock -F 299 --call-graph fp -o /tmp/sp.data -- \
    env FIB_N=38 FIB_LOOPS=30 /tmp/fib_spinel

  # --- folded → SVG ---
  perf script -i /tmp/cr.data | $FG/stackcollapse-perf.pl > cruby.folded
  perf script -i /tmp/sp.data | $FG/stackcollapse-perf.pl > spinel.folded
  $FG/flamegraph.pl --colors java  cruby.folded  > cruby_flame.svg
  $FG/flamegraph.pl --colors green spinel.folded > spinel_flame.svg
'
```

## Notes

- `perf` works on the custom kernel too, with the software event `cpu-clock` (no PMU needed).
- A spinel binary in a normal build (`-O2`, frame pointers omitted) cannot have its user stack unwound,
  so the profiling build is a separate build with `-fno-omit-frame-pointer`.
- CRuby's `vm_exec_core` and friends are `static` (symtab stripped), so their names appear only after
  fetching debug info with debuginfod. Where it cannot be fetched they show as hex `libruby+0x...`, but
  the picture of "time scattered across the interpreter" looks the same.
- The above uses standard `perf`. A version that **draws the same picture with spinel-ebpf's own eBPF profiler**
  was added in E182
  (`user_profile.rb`, below).

## Own-profiler version (E182 — no perf needed)

`user_profile.rb` samples with `on :perf_event, hz: 99` + `user_stack_id`, and the host
prints the folded output with `spnl_dump_folded_user`. A fallback to a separate build-id debug file was added to
`spnl_sym_user`, so stripped statics such as CRuby's `vm_exec_core` get their names resolved too.

```bash
container exec spnlbuild bash -c '
  set -e; export LANG=C.UTF-8; cd /work; FG=/opt/FlameGraph
  ruby bin/spinel-ebpf compile examples/profiling/fib_flamegraph/user_profile.rb -o /tmp/uprof --build

  # debug symbols into the build-id tree, to show the CRuby interpreter static function names
  export DEBUGINFOD_URLS="https://debuginfod.debian.net/"
  BID=$(readelf -n /lib/aarch64-linux-gnu/libruby-3.3.so.3.3 | grep -oE "Build ID: [0-9a-f]+" | awk "{print \$2}")
  debuginfod-find debuginfo "$BID" >/dev/null
  mkdir -p /usr/lib/debug/.build-id/${BID:0:2}
  ln -sf /root/.cache/debuginfod_client/$BID/debuginfo /usr/lib/debug/.build-id/${BID:0:2}/${BID:2}.debug

  # SPNL_SYM_PID = the target ns-local pid (BPF records the init-ns pid, so it is required inside a container)
  FIB_N=35 FIB_LOOPS=20 ruby examples/profiling/fib_flamegraph/fib.rb >/dev/null 2>&1 & WL=$!
  sleep 0.5
  SPNL_SYM_PID=$WL PROFILE_SECS=6 /tmp/uprof/user_profile 2>cruby.folded >/dev/null
  kill $WL; wait $WL 2>/dev/null
  $FG/flamegraph.pl --colors java cruby.folded > cruby_selfprofiler.svg
'
```

Note: the target process must be alive at dump time (its maps are read). For short-lived processes perf is stronger.
