# tools/raster — the Job IR table, checkers, MLIR generator and GPU seam

The foundation of DOOM's GPU raster path: DOOM's renderer describes a frame as
a list of plain-data **jobs** (the Job IR), and this lane turns jobs into
`linalg` gather kernels, compiles them with IREE, and runs them on the GPU.
**It holds no DOOM-specific knowledge**: only the Job IR contract and the
plumbing that carries it to MLIR and IREE. DOOM is the application
(`examples/doom`), and this is the foundation. Ported from spinel-llvm
`463d49dd` (its P005, experiments E057–E075); see
[provenance](../../docs/provenance.md).

The three tools are Ruby (CRuby and the standard library). spinel-llvm's
earlier Python versions were retired there and are not here.

## Four gather kinds, and two kinds of ordering contract

| | `opaque_columns_k<K>` / `wall_columns` | `plane_spans_k<K>` | `masked_columns_k<K>` | `fuzz_columns_k1` |
|---|---|---|---|---|
| slots are cut along | x: `slot(x,k) = x*K+k` | y: `slot(y,k) = y*K+k` | x | x |
| an interval runs along | y (`yl..yh`) | x (`x1..x2`) | y | y |
| reads | the texture column atlas | the flat atlas | a per-frame 128-byte window atlas | the frame buffer so far, and `fuzzoffset` |
| **ordering contract** | **exclusive** per x (checks #4, #13) | **exclusive** per y (#10) | **ordered fold**: the last in schedule order wins (#12) | **structural**: one per column per dispatch (#14) |
| fold | `select` | `select` | max-by-key (`maxsi`) | max-by-key |

The kinds split into two ordering contracts:

- **Exclusive.** Walls and spans rely on at most one slot covering each pixel,
  so the kernel just selects that slot's pixel.
- **Ordered or structural.** Masked columns **overlap by design**: 9.06% of
  masked pixels over the whole demo set are covered twice or more. They are
  still a gather, because each job is an opaque interval and "the last one in
  schedule order wins" can be written as a max-by-key: `cand(k) = in(k) ?
  ((k+1)*256 | pixel(k)) : 0`. `max` is commutative and associative, so however
  linalg reorders the reduction, the answer is the same.
- **Fuzz** reads the frame buffer so far, so two fuzz jobs in one column would
  be a read-after-write in a single dispatch. K=1 is therefore a contract, not
  a measurement. Its self-reference within a column closes in four unrolled
  steps, because the longest run of -1 in `fuzzoffset` is 4 (check #15).

A full frame is 3 to 9 dispatches: one opaque (walls and sky), one span, and 1
to 7 masked and fuzz batches.

## K is part of the ABI: one entry per K, chosen at run time

A gather costs in proportion to its declared K; an empty slot is still
evaluated. So the table has one row per K, and the host picks, for each frame,
the smallest K that covers that frame's `max_k`:

| Row | K | Frames covered |
|---|---:|---:|
| `plane_spans_k4` / `k16` | 4 / 16 | 84.9% / 100% |
| `masked_columns_k8` / `k16` / `k40` | 8 / 16 / 40 | 84.0% / 98.1% / 100% |
| `opaque_columns_k16` | 16 | 100% |
| `fuzz_columns_k1` | 1 | 100% (the contract) |

`spinel-rastergen mlir --kind every` writes every gather row into one module
(7 entries), and `--entries-out` lists each entry name with its signature. One
`.vmfb` and one session serve a whole game; switching K is choosing a name. A
frame no row covers is **rejected**, never silently truncated.

## The parts

| Part | What it is |
|---|---|
| `spinel-jobtable` | turns the Job IR declaration (the TSV `Doom::Jobs.table_row` writes) into a C header, and checks the table itself. The three signatures (`sig`, `semsig`, `ksig`) are defined here |
| `sp_job_table.h` | **generated**: `sp_job_entry_t`'s 8 rows. It is tracked, and it must be exactly what `spinel-jobtable emit` writes |
| `spinel-rastergen` | Job IR (planar binary) to **gather-shaped linalg MLIR**, with slot packing and checks #1, #4 and #5 |
| `spinel-jobcheck` | the independent checks **#1 to #15** over an exported Job IR, its table, the generated MLIR and the `fuzzoffset` table. Any REJECT exits non-zero |
| `sp_raster_gpu.c` | **the seam Ruby calls** (`examples/doom/lib/doom/render_gpu.rb` declares it one to one): one call per frame from `ffi_func` |
| `sp_raster_shim.c` | the IREE runtime seam underneath it |
| `sp_raster_gpu_stub.c`, `raster_run.c` | spinel-llvm's no-device stub and its C file-driven harness. This repository links `examples/doom/native/sp_rg_stub.c` as its stub. `raster_run` compares with a CPU oracle, so it is kept as a file and not built |

## How DOOM uses it

`examples/doom/build.sh` with `RASTER_GPU=1` links `sp_raster_gpu.c`,
`sp_raster_shim.c` and the IREE runtime (and on macOS, Metal) in place of the
stub. Then:

```sh
examples/doom/bin/dump_jobs.rb <wad> DEMO1 0 jobs/ - <scale>   # one frame's Job IR (built with spinel)
tools/raster/spinel-rastergen mlir --jobs jobs --table jobs/table.tsv --kind every \
    -o every.mlir --entries-out entries.tsv
iree-compile --iree-hal-target-backends=metal-spirv --iree-metal-compile-to-metallib=false \
    every.mlir -o every.metal.vmfb
doom -iwad doom1.wad -playdemo DEMO1 -gpu -jobs -gpuvmfb every.metal.vmfb \
     -gpuentries entries.tsv -gpudev metal [-res 640x400]
```

On an NVIDIA GPU, build the runtime as the installation record's CUDA section
says, compile with `--iree-hal-target-backends=cuda`, and pass `-gpudev cuda`.

The kernels do not depend on the frame, so one tic's Job IR is enough. They do
depend on the internal resolution, so each scale gets its own dump and module.
The 3D view is drawn by the GPU and the status bar and HUD by the CPU. A frame
the GPU rejects is drawn by the CPU executor from the same jobs; at the end the
run reports `gpu frames=... rejects=...`.

IREE is 3.11.0, installed as its
[installation record](../../docs/toolchains/iree-3.11.0/INSTALLATION-RECORD.md)
says. There is no Metal toolchain on the build machine, so the shaders are
embedded as source and compiled on the device.

## Checks

`tests/raster/run.sh` runs the whole path on the Apple GPU:

- the kernels at scales 1, 2, 3, 4 and 6;
- the table's emit and checks, and `spinel-jobcheck` as E071 ran it;
- `gpu_reject`'s broken Ruby-to-C arguments, all refused, with its positive
  controls;
- the `-res` spelling's refusals;
- **DEMO1, DEMO2 and DEMO3 played to their end at 320x200, 640x400, 960x600,
  1280x800 and 1920x1200 with every frame drawn by the GPU and none rejected.** The end is each demo lump's own
  length, read from the IWAD.

Kept as files and not run, because they are oracles:

- `examples/doom/bin/gpu_demo.rb`, which draws sampled frames on the GPU and on
  the CPU executor and compares them;
- `raster_run.c`'s oracle comparison;
- `ab/run_e170.sh` and `ab/test_e170.rb`, which compare these tools byte for
  byte with the retired Python versions.

## Fixed defect: scale 3 and above stopped at tic 321

**Fixed 2026-09-23.** At `-res 960x600` and above, DEMO1 stopped at tic 321 with
`undefined method '*' for nil (NoMethodError)`, on the plain CPU renderer as well
as on this lane. It was a read one past the end of a table in DOOM itself.

**What it was.** `lib/doom/render.rb`'s `render_seg_loop` computes
`angle = ((rw_centerangle + xtoviewangle[x]) & M32) >> ANGLETOFINESHIFT` and
reads `@finetangent[angle]`. When the sum is exactly `0x80000000` (ANG180),
`angle` is 4096, and `finetangent` has 4096 entries. On DEMO1 that happens at
column 735 of a 1280-wide view on tic 321, and only the column geometry at scale
3 and above produces it. The pinned Spinel returns `nil` for the missed read, as
CRuby does (`sp_box_int_or_nil`, which spinel-llvm's older runtime did not
have), and the multiply that follows raises.

**How it was located**, without a debugger (lldb gave nothing on macOS):

1. Generate the C (`spinel -c`). It carries `#line` directives, so
   `__FILE__`/`__LINE__` at a macro expansion name the Ruby file and line.
2. In the generated file only, redefine the nil check (`SP_INT_NIL_CK`) and wrap
   the poly arithmetic (`sp_poly_mul`) to print their location. The poly
   wrapper printed `render.rb:1847` with the left operand `nil`.
3. Put one probe line before that line in a scratch copy of the DOOM tree, to
   print the index, the table length and the angle inputs.

**The fix reproduces vanilla.** Vanilla's `R_RenderSegLoop` makes the same read
in C and gets the next table in memory, `finesine[0]`. At the read site, an
`angle` equal to the table's length now reads `finesine[0]`. The table is not
extended, because the CORE render entry takes it as a buffer of exactly 4096
(`examples/doom/core/catalog.tsv`). The CORE extraction carries the same guard
(`core/src/segs.rb`, and its generated copy in `rvcopies.rb`, which
`tools/doom/core-copies.rb` reproduces byte for byte). At 320x200, CORE's only
resolution, the index never reaches 4096, so nothing observable changes there.

**Checked.** `tests/raster/run.sh` plays all three demos to their end on the GPU
at 960x600, 1280x800 and 1920x1200. The plain CPU renderer, which is not this
lane, is checked by hand; it reaches all 5026 tics:

```sh
doom -iwad doom1.wad -playdemo DEMO1 -nopace -scale 1 -res 1280x800   # "5026 tics on E1M5"
```

## Screenshot visibility check

`sh tests/raster/run.sh` also captures GPU DEMO1 tics 35, 399 and 1000 at
its existing resolutions. Each screenshot must have at least 50% non-black RGB
pixels inside the 3D viewport. The crop excludes the status bar and insets the
view by one logical pixel to exclude its edge. The runner verifies the reported
view geometry; the checker refuses missing/truncated screenshots, wrong screen
sizes and empty/out-of-bounds crops. Alpha alone does not count as visible RGB.

This catches an accepted GPU frame whose readback missed the real screen.
It establishes visible 3D content in selected scenes, not agreement with the CPU
renderer. It does not compare with a CPU rendering or another implementation.
The images and per-image count/area/percentage logs remain in `RASTER_WORK`.

The checker can run without Metal:

```sh
ruby tests/raster/visibility-controls.rb
ruby tests/raster/visibility.rb frame.bmp --screen 320x200 --viewport 1,1,318,166
```

The controls include missing, black, HUD-only, opaque-alpha-only, malformed-size
and truncated images, plus positive and threshold controls. Full screenshot
acceptance requires the Mac Metal lane; a Debian control run alone is not GPU
rendering evidence.

### Mutable String seam

The GPU screen and zone arguments use the explicit `:str_inout` borrow from
[decision 0016](../../docs/decisions/0016-ffi-mutable-string-borrow.md). The screen
is writable for the call; the zone is only read by this seam. WAD remains `:str`.
The boundary republishes String caches after native writes, so the caller needs
no dummy `setbyte`. This requires the recorded vendor patch; it does not enable
`--share-strings`.

Run `sh tests/raster/string-borrow.sh` from the repository root to check the
generated native seam without Metal. Run
`CC="$LLVM_PREFIX/bin/clang" sh vendor/spinel/scripts/ffi-string-borrow-check.sh` for the explicit
write/refusal controls (select the documented Clang toolchain for `CC`). Metal
visibility acceptance remains the screenshot check in `tests/raster/run.sh`.
