# tools/llvm — Spinel programs through clang, with ThinLTO over the runtime

Spinel compiles Ruby to C and links it with `cc` against `libspinel_rt.a`.
These tools take the same generated C through the LLVM release's clang instead,
without modifying `vendor/spinel`: `spinel -c` writes the C, and the driver
rebuilds `src/main.c`'s link line outside it. With the runtime compiled to
bitcode, the program and the runtime optimise together under ThinLTO. Ported
from spinel-llvm `463d49dd` (its P001); see
[provenance](../../docs/provenance.md).

| File | What it is |
|---|---|
| `build_rt_bc.sh` | compiles every runtime source (the vendor Makefile's `RT_MEMBERS` and `RE_SRC`) with `-flto=thin` into two archives of bitcode, `build/libspinel_rt_lto.a` and the threaded `build/libspinel_rt_mt_lto.a` |
| `spinel-llvm` | the driver: `.rb` → `spinel -c` → clang, in one of three modes |
| `cc-lto-shim` | a `CC` for `vendor/spinel`'s test harness that sends every test link through ThinLTO |
| `passes/` | `SpinelGCRoots`, an `opt` pass plugin ([its README](passes/README.md)) |

All of them take the LLVM from `LLVM_PREFIX` (`LLVM=` overrides it): the
official LLVM 23.1.1 release that [building](../../docs/building.md) selects.

## Use

```sh
export LLVM_PREFIX=...                     # as docs/building.md
tools/llvm/build_rt_bc.sh                  # once, and after lib/ changes; -f forces, -jN, -v
tools/llvm/spinel-llvm app.rb -o app                   # --mode thinlto (the default)
tools/llvm/spinel-llvm app.rb -o app --mode clang-O2   # clang -O2 and the stock archive
tools/llvm/spinel-llvm app.rb --mode ir -o app.ll      # stop at LLVM IR
tools/llvm/spinel-llvm app.rb -o app -v                # print each command
```

| Option | Meaning |
|---|---|
| `-o OUT` | output; default the source's basename without `.rb` (`<base>.ll` in `ir` mode) |
| `--mode thinlto` | `-O2 -flto=thin` with the bitcode runtime archive (default) |
| `--mode clang-O2` | `-O2` with the stock `lib/libspinel_rt{,_mt}.a` |
| `--mode ir` | `-O2 -S -emit-llvm`; writes IR and links nothing |
| `-O LEVEL` | optimisation level, default 2 |
| `--int-overflow raise\|wrap\|promote` | passed to `spinel -c` and as the matching `-D`, default `raise` |
| `--link OBJ` / `--link -lfoo` | an extra link input, repeatable (for example a C definition of a method named in `SPINEL_EXTERN_METHODS`) |
| `--keep-c` | keep the temporary directory with the generated C |
| `-- ARGS` | pass the rest to clang |

A failing stage is reported as `spinel-llvm: stage '<stage>' failed (exit N)`
and the driver exits with that code.

## What the driver reproduces from `src/main.c`

Checked against pin `573aa44c`:

- the markers it scrapes from the generated C: `SPINEL_CFLAGS`, `SPINEL_LINK`,
  `SPINEL_LINK_OBJ` and `SPINEL_USES_THREADS` (which selects the threaded
  archive and adds `-DSP_THREADS -ftls-model=initial-exec` and `-lpthread`);
- `-Werror=incompatible-pointer-types -Werror=int-conversion` and an unlimited
  error count;
- the link order: the generated TU, `--link` objects (a threaded program takes
  a `<stem>_mt` variant when there is one), `native_obj` package objects
  (deduplicated against `--link` with the `_mt` marker removed), the runtime
  archive, `-lm`, `-lcrypt` off macOS, `--link -l` flags, `-lpthread`,
  `SPINEL_LINK` libraries not already supplied by `--link`, and section GC
  (`-dead_strip` / `--gc-sections`);
- `--int-overflow`, and the default output name.

Not reproduced, because the driver does not offer them: `-g`, `--debug`,
`--profile`, `--line-map`, 32-bit and wasm32 targets, and the arena runtime.
The driver passes `-Wno-everything` where upstream passes `-Wno-all`.

## `cc-lto-shim`

```sh
make -C vendor/spinel test CC="$PWD/tools/llvm/cc-lto-shim" NO_CCACHE=1
```

The test harness runs `spinel -c` itself and links each test with `$(CC)`
against `lib/libspinel_rt.a` or `lib/libspinel_rt_mt.a`. The shim passes every
command to clang unchanged, except a command naming one of those archives (a
test link) or building a precompiled header: that one gets `-flto=thin`, and
the archive is replaced by its bitcode twin. Compiles that rebuild the
runtime's own objects pass through untouched. `NO_CCACHE=1` is required,
because a compiler cache cannot hash a shell script.

## Checks

`sh tests/llvm/run.sh` builds the bitcode archives and checks every member is
bitcode; builds a sample of the upstream test programs with stock `spinel`,
`--mode clang-O2` and `--mode thinlto`, each of which must print the program's
own `.expected`; checks `--mode ir`, the ThinLTO link line and `--link`; and
checks the driver's refusals. The pass has its own tests (`passes/test/`).
