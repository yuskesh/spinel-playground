# tools/gcmon — GC and allocation monitoring

Tools that answer "did this code allocate, and did the GC run?", by counts,
without disturbing the answer. Ported from spinel-llvm `463d49dd` (its E131);
see [provenance](../../docs/provenance.md). The section probe needs vendor
Patch 1 (`SPINEL_EXTERN_METHODS`), which the pin carries.

| File | What it is |
|---|---|
| `gcmon_contract.h` | the WHOLE surface read from `vendor/spinel`: seven GC counters and the Patch 1 integer type. Nothing else names a vendor symbol |
| `gcmon_probe.c` | the section probe. It reads the counters directly into static storage, so observing allocates nothing, and writes its TSV at exit with `write(2)` |
| `malloc_count.c` | a malloc/calloc/realloc/free counter by DYLD interposition, **macOS only**. The GC counter misses direct mallocs such as an Array's element storage; this one does not |
| `spinel-gcmon` | the driver: `run`, `ab`, `flame`, `stress`, all writing one TSV |
| `run_gcmon_gate.sh` | the gate for DOOM's dynamic zero allocation (PASS 0, FAIL 1, SKIP 2) |
| `gcmon_stub.rb` | no-op `gcmon_begin`/`gcmon_end` for running a subject under CRuby. That differential is an oracle: the file is kept and nothing here runs it |

## Use

```sh
tools/gcmon/run_gcmon_gate.sh                          # DOOM: zero allocation
tools/gcmon/spinel-gcmon ab --a "prog 500" --b "prog 5026" --expect-zero
tools/gcmon/spinel-gcmon flame -- prog args -o out.folded
tools/gcmon/spinel-gcmon stress -- prog args           # SPINEL_GC_STRESS + SPINEL_GC_VERIFY_GEN
```

`CC` selects the C compiler for the malloc counter (and, in the gate, for
Spinel). On macOS, use the LLVM release as [building](../../docs/building.md)
describes.

`ab` runs A and B with the GC counter (`SPINEL_ALLOC_REPORT`), the malloc
counter and the section probe attached, and writes each metric's delta. With
`--expect-zero` it passes only when every counted delta is 0, no value is
missing, and both subjects exited 0.

## Three rules

1. **It does not measure time.** Allocation and collection deltas only;
   timing belongs to hyperfine.
2. **The verdict is by counts.** The malloc counter's `bytes` react to the
   length of argv and the environment: the same program at a path of different
   length moved by 32 bytes. `--expect-zero` leaves `bytes` out.
3. **MISSING is not 0.** A value no instrument produced is written `MISSING`,
   and an attached instrument that says nothing on a side (for example, the GC
   counter under a program that is not a Spinel program) is a `(no output)`
   row. Either fails `--expect-zero`. A gate whose prerequisite is absent
   answers SKIP, never PASS.

## The section probe

```sh
$CC -c -O2 -o gcmon_probe.o tools/gcmon/gcmon_probe.c -Itools/gcmon
SPINEL_EXTERN_METHODS=gcmon_begin,gcmon_end \
  vendor/spinel/bin/spinel app.rb --link gcmon_probe.o -o app
GCMON_OUT=probe.tsv ./app
```

`app.rb` defines stubs whose bodies are never compiled. They must return an
int, because Patch 1's canonical value ABI returns `sp_int` only for a concrete
int result:

```ruby
def gcmon_begin(id)
  id
end

def gcmon_end(id)
  id
end

gcmon_begin(1)
# ... the section to measure (the probe allocates nothing in between) ...
gcmon_end(1)
```

Each section id (0 to 63) reports `entries`, and the summed deltas of `cycle`,
`full_runs`, `bytes`, `old_bytes`, `threshold` and `remembered`, with the last
`rem_peak`. A begin or end that does not pair is reported as `unmatched`, and
an id out of range as `out_of_range`; neither is dropped silently.

## Checks

`sh tests/gcmon/run.sh` (macOS): the probe's properties; the probe leaves both
counters' counts unchanged (the same source built with and without it); the
driver's verdicts, including that 300 extra allocations fail `--expect-zero`
and that a non-Spinel subject fails it; `run`, `flame` and `stress`; the
`--pause` refusal; and the DOOM gate. On another host the two DYLD sections
skip and the suite exits 2.

The DOOM gate builds `examples/doom/bin/bench_tic.rb` and runs DEMO1 in mode 1
(every tic simulated and drawn, nothing written) to tic 500 and to tic 5026.
Every count must be equal: 4526 tics of play allocate nothing.

## Not ported

- **The pause-time axis (`--pause`).** It reads `SPINEL_GC_TRACE`, which vendor
  patch L8 adds. L8 is not approved at this pin, so `--pause` is refused, and
  the `gc_trace` rows do not exist.

## Limits

- **Single-threaded.** Under an `SP_THREADS` build the counters are relaxed
  atomics (`lib/sp_gc.h`'s `SP_GC_CTR_*`); the probe reads them plainly.
- **Allocation by type is per process.** A section sees collections and heap
  state only; the per-type table of `SPINEL_ALLOC_REPORT` is static inside the
  vendor runtime.
- **The malloc counter is macOS only**, and macOS strips
  `DYLD_INSERT_LIBRARIES` from SIP-protected system binaries, so a subject must
  be a binary built here.
