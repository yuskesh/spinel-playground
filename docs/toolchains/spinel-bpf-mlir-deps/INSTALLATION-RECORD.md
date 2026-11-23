# spinel-bpf-mlir dependencies -- installation record

The bcc tools import (spinel-bpf-mlir v0.7.0, owner's decision of
2026-10-26) needs a newer Go, bpf-mlir's `ebpf-compile`, and the sources the
loader bml builds its static archives from. Everything below is user-local
under `~/toolchains` on the Debian 13 x86_64 host, installed on 2026-10-26
without sudo. Nothing system-wide was changed, and nothing was registered in
`~/.cmake/packages`; the two entries there predate this record.

## Go 1.27.3

spinel-bpf-mlir's `go.mod` declares `go 1.27.0`, which the Go 1.25.14
already recorded here ([its record](../go-1.25.14/INSTALLATION-RECORD.md))
cannot build. Go 1.27.3 is the newest 1.27 release on 2026-10-26, by
go.dev's release list.

| | |
|---|---|
| version | go1.27.3, linux/amd64 |
| archive | `https://go.dev/dl/go1.27.3.linux-amd64.tar.gz`, sha256 `65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40` (the value go.dev publishes) |
| location | `~/toolchains/go-1.27.3` |

```sh
cd ~/toolchains
curl -sSLo go1.27.3.linux-amd64.tar.gz https://go.dev/dl/go1.27.3.linux-amd64.tar.gz
echo "65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40  go1.27.3.linux-amd64.tar.gz" | sha256sum -c -
mkdir go-1.27.3 && tar -xzf go1.27.3.linux-amd64.tar.gz -C go-1.27.3 --strip-components=1
export GO=$HOME/toolchains/go-1.27.3/bin/go GOTOOLCHAIN=local
```

As for Go 1.25.14, Go is called by its full path and is not on `PATH`, and
`GOTOOLCHAIN=local` stops it from downloading another toolchain.

**The bpf-mlir Go module is private.** spinel-bpf-mlir requires
bpf-mlir's Go module at `go/v1.15.0`, then private. The public checksum database
cannot see it (`sum.golang.org` answered 404), so a plain fetch fails. With
a `GOPRIVATE` setting for that repository, Go skips the checksum database for
that path only and checks the module against `go.sum`. On this host the
module was already in the user's module cache, and its sums equal the two
`go.sum` lines of spinel-bpf-mlir v0.7.0 (`h1:cYyVmxDF…DdC=` for the module,
`h1:UOrcxQg0…xO0=` for its `go.mod`). A host without that cache needs the
user's GitHub credentials to fetch it. The other modules (`cilium/ebpf`
v0.22.0, `x/sys` v0.43.0) come from `proxy.golang.org` as before.

## bpf-mlir go/v1.15.0: `ebpf-compile`

| | |
|---|---|
| source | `https://github.com/yuskesh/bpf-mlir`, tag `go/v1.15.0`, commit `99d631a57738730dc9710e656f21e41a0f67da23` |
| checkout | `~/toolchains/bpf-mlir-go-v1.15.0` (clean: no changed or untracked file after the build) |
| build | `~/toolchains/bpf-mlir-go-v1.15.0-build` |
| compilers | LLVM / MLIR 23.1.1 from `/opt/llvm-23.1.1`; CMake 3.31.6, Ninja 1.12.1 |
| result | `bin/ebpf-compile`, sha256 `43456766097913bc656dcb18f46c4a754080fdd3605f16046e0ab4d140d53af8`; `--version` prints `bpf-mlir go/v1.15.0 (commit 99d631a57738730dc9710e656f21e41a0f67da23)` and LLVM 23.1.1 |

The configure line and targets are the ones spinel-mlir's `build.sh` uses
for the same pin, with one change:

```sh
L=/opt/llvm-23.1.1 B=~/toolchains/bpf-mlir-go-v1.15.0-build
git clone https://github.com/yuskesh/bpf-mlir.git ~/toolchains/bpf-mlir-go-v1.15.0
git -C ~/toolchains/bpf-mlir-go-v1.15.0 checkout go/v1.15.0
cmake -G Ninja -S ~/toolchains/bpf-mlir-go-v1.15.0 -B "$B" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=$L/bin/clang -DCMAKE_CXX_COMPILER=$L/bin/clang++ \
  '-DCMAKE_CXX_FLAGS=-fno-rtti -fno-exceptions' \
  -DMLIR_DIR=$L/lib/cmake/mlir -DLLVM_DIR=$L/lib/cmake/llvm \
  -DLLVM_EXTERNAL_LIT=/bin/false -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON
cmake --build "$B" --parallel 4 --target MLIREBPFDialect BpfMLIRKernelABI \
  BpfMLIREBPFSchema ebpf-compile ebpf-schema-test FileCheck count not
cmake --build "$B" --parallel 4 --target ebpf-schema-check ebpf-opt
```

- **`LLVM_EXTERNAL_LIT=/bin/false`.** bpf-mlir's `CMakeLists.txt` refuses
  to configure without an existing lit runner. lit is Python, and LLVM
  23.1.1 ships none, so spinel-mlir's `build.sh` makes a Python venv for it.
  bpf-mlir's own lit suite is bpf-mlir's test, not one of ours, and is not
  run here. `/bin/false` satisfies the check, and any `check-*` target run
  against this build fails at once instead of passing silently. No Python
  was installed or run.
- The build took 44 s at `-j4`. `FileCheck`, `count` and `not` come from
  the same build, for RUN-line tests that use them.
- `ebpf-schema-check` (sha256 `1b9e9168c0bd2b3f3378ee6887b892130b54cca52b23a7470675815801f15b8b`)
  and `ebpf-opt` (sha256 `bedae79ea959c00cc0bf68303bdc06e8f8eebb9ac86b18bb7c487ba01402a559`)
  were built after it, for spinel-bpf-mlir's frontend tests, which call them
  beside `ebpf-compile`.

## bpf-mlir go/v1.18.0: `ebpf-compile` (2026-10-27)

spinel-bpf-mlir v0.8.0, bml `a6da571` and spinel-mlir `f96ac6d` pin bpf-mlir
go/v1.18.0. It is installed beside go/v1.15.0 (above), which stays in place,
with the same recipe and targets:

| | |
|---|---|
| source | `https://github.com/yuskesh/bpf-mlir`, tag `go/v1.18.0`, commit `3bdd550e7c9a2c84d0c32c6d9b84bd536fae912e` |
| checkout | `~/toolchains/bpf-mlir-go-v1.18.0` (clean after the build) |
| build | `~/toolchains/bpf-mlir-go-v1.18.0-build`, 43 s at `-j4` |
| result | `bin/ebpf-compile`, sha256 `3cd55671cd590a41e5c50f9891f292cdd4252abebb3988056a52b021e78bbbab`; `--version` prints `bpf-mlir go/v1.18.0 (commit 3bdd550e7c9a2c84d0c32c6d9b84bd536fae912e)` and LLVM 23.1.1 |

```sh
L=/opt/llvm-23.1.1 B=~/toolchains/bpf-mlir-go-v1.18.0-build
git clone https://github.com/yuskesh/bpf-mlir.git ~/toolchains/bpf-mlir-go-v1.18.0
git -C ~/toolchains/bpf-mlir-go-v1.18.0 checkout go/v1.18.0
# then the cmake lines of go/v1.15.0 above, with this source and build
```

- **The Go module.** It is bpf-mlir's Go module at `go/v1.18.0`, fetched with `GOPRIVATE` as above. `go mod verify` reports all modules verified.
  - Its sums are the two `go.sum` lines of spinel-bpf-mlir v0.8.0: `h1:TQjjzxI+…gYk=` for the module and `h1:UOrcxQg0…xO0=` for its `go.mod`.
- `~/.cmake/packages` was unchanged.

## bpf-mlir ab0db4b40, an unreleased development commit: `ebpf-compile` (2026-10-30)

spinel-bpf-mlir 9b914a8 and bml fae2194 pin `ab0db4b40` of bpf-mlir's development
tree (E160), a commit no public release has.
This is the development shape's compiler (`internal/toolchain/pin_dev.go`),
spinel-mlir's consumer is built against it too: spinel-mlir took the same pin in
E081. It is installed beside go/v1.18.0, which no current pin uses and which
stays in place as a record. The recipe and targets are those of go/v1.15.0 above.

| | |
|---|---|
| source | bpf-mlir's development repository (private), main, commit `ab0db4b40c0544cf83f551f8998af51f4dde26aa` (`git describe`: `go/v1.19.0-54-gab0db4b40`). The public pin `d3e13842` is an ancestor, which `TestReleasePinSameCompilerSource` reads. |
| checkout | a user-local full clone (clean after the build) |
| build | a user-local build directory, 43 s at `-j4` for both target lists |
| result | `bin/ebpf-compile`, sha256 `05ed6dfd79a7a3c014eb574e6ad77215e2352cbeef6cac38f356c2e47f30bbc0`. `--version` prints `bpf-mlir go/v1.19.0-54-gab0db4b40 (commit ab0db4b40c0544cf83f551f8998af51f4dde26aa)` and LLVM 23.1.1. |

`ebpf-schema-check` has sha256
`2d26770d51b361b4fa04805c5fa356b85945a3b05123228df0c5e5a8874933db`, and
`ebpf-opt` has sha256
`94b22d13e464e0b48b72819387dfa506f10cb5345ea37fa57a69a88776720d95`.

- **The Go module.** It is bpf-mlir's development Go module at
  v1.19.1-0.20261028231217-ab0db4b40c05`, fetched with `GOPRIVATE` as above.
  `go mod verify` in `tools/spinel-bpf-mlir` reports all modules verified.
  - Its sums are the `go.sum` lines of spinel-bpf-mlir 9b914a8: `h1:ok104j+B…2YU=`
    for the module, and `h1:UOrcxQg0…xO0=` for its `go.mod`.
- `~/.cmake/packages` was unchanged.

## bpf-mlir 41b188568, the source of v1.21.0: `ebpf-compile` (2026-11-11)

spinel-bpf-mlir `c56a4915` and bml `41ec56f1`, the sources of the public
releases spinel-bpf-mlir v0.9.0 and bpf-mlir-loader v0.1.0, pin bpf-mlir's
development tree at `41b188568` (E166). The public bpf-mlir v1.21.0 names the same commit as its
`source_commit`. It is installed beside `ab0db4b40`, which spinel-mlir's
consumer still pins. The recipe and targets are those of go/v1.15.0 above, and
both builds ran under `taskset -c 0-3`.

| | |
|---|---|
| source | bpf-mlir's development repository (private), commit `41b188568cb36a15d4c185d5f72027267b3fa544` (`git describe`: `go/v1.19.0-1962-g41b188568`), a full clone of the user's local checkout. The earlier public pin `d3e13842` is an ancestor. |
| checkout | a user-local full clone (clean after the build) |
| build | a user-local build directory, 75 s at `-j4` for configure and both target lists |
| result | `bin/ebpf-compile`, sha256 `32ad55a281c94f91b64946746dd3b45bccd856006dd9c5dcc29768e43ab6f4de`. `--version` prints `bpf-mlir go/v1.19.0-1962-g41b188568 (commit 41b188568cb36a15d4c185d5f72027267b3fa544)` and LLVM 23.1.1. |

`ebpf-schema-check` has sha256
`328cd3f13232e57d6d854a0459018fdefae0ded6390544561b16282fb54f97a7`, and
`ebpf-opt` has sha256
`bd726fd091abf1d5af6419df7aca2943d57691c8c2db8dde11581ae5aecceb06`.

- **The Go module.** It is bpf-mlir's development Go module at
  `v1.19.1-0.20261110080538-41b188568cb3`, which was already in the user's
  module cache. `go mod verify` in `tools/spinel-bpf-mlir` reports all modules
  verified.
  - Its sums are the `go.sum` lines of spinel-bpf-mlir `c56a4915`: `h1:3a5BG17k…maqE=`
    for the module, and `h1:UOrcxQg0…xO0=` for its `go.mod`.
- `~/.cmake/packages` was unchanged.

## spinel-mlir consumer against ab0db4b40 (2026-10-30)

`tools/spinel-mlir` at commit `350108790f8f803b5e8911d9758c194cc5e688fb` is
built against the `ab0db4b40` checkout and build above, with the
cmake lines of `tools/spinel-mlir/README.md`. The build directory is user-local.

| | |
|---|---|
| build | `~/toolchains/spinel-mlir-consumer-3501087-build`, 669/669 steps in 273 s at `-j4`, with 0 `error:` lines |
| `BuildRevision.h` | consumer `350108790f8f803b5e8911d9758c194cc5e688fb`, not dirty; `SPINEL_BPF_MLIR_COMMIT` `ab0db4b40c0544cf83f551f8998af51f4dde26aa` |
| result | `bin/spinel-mlir`, sha256 `061879c356b6a2dd553c54cc18899e07be7b2c427d00ffc2cb38dbfff476f027` |

Pass `SPINEL_MLIR_BUILD` and `BPF_MLIR_BUILD` to `tests/spinel-mlir/run.sh`,
and `CONSUMER=<build>/bin/spinel-mlir` to `tests/bcc-facts/run.sh`.
`~/.cmake/packages` was unchanged.

## Sources for bml: libbpf, zlib, elfutils

bml (bpf-mlir-loader `295df2ad877091826ac98a6778022fcf53b02eb1`) links
static archives of these three, built from its pinned submodules. They are
the same commits, checked out user-local, so no tracked file depends on a
sibling checkout:

| | upstream | commit | tag | location | licence |
|---|---|---|---|---|---|
| libbpf | `https://github.com/libbpf/libbpf.git` | `f5dcbae736e5d7f83a35718e01be1a8e3010fa39` | `v1.7.0` | `~/toolchains/libbpf-1.7.0` | LGPL-2.1 or BSD-2-Clause |
| zlib | `https://github.com/madler/zlib.git` | `da607da739fa6047df13e66a2af6b8bec7c2a498` | `v1.3.2` | `~/toolchains/zlib-1.3.2` | zlib |
| elfutils | `https://sourceware.org/git/elfutils.git` | `62563002d86d182bbf6a9689983629aaa075f505` | `elfutils-0.196` | `~/toolchains/elfutils-0.196` | libelf: LGPL-3.0-or-later or GPL-2.0-or-later |

```sh
cd ~/toolchains
git clone https://github.com/libbpf/libbpf.git libbpf-1.7.0 && git -C libbpf-1.7.0 checkout f5dcbae736e5d7f83a35718e01be1a8e3010fa39
git clone https://github.com/madler/zlib.git zlib-1.3.2 && git -C zlib-1.3.2 checkout da607da739fa6047df13e66a2af6b8bec7c2a498
git clone https://sourceware.org/git/elfutils.git elfutils-0.196 && git -C elfutils-0.196 checkout 62563002d86d182bbf6a9689983629aaa075f505
```

They are sources only so far. bml's archives are built from them when bml
itself is imported. bml links libelf statically; the relinking terms of the
LGPL matter once binaries are distributed, which is for the licence review
at publication.

## Privileges

- Nothing above needed sudo.
- One privileged command was run while the tests were sorted, on 2026-10-26:

  ```text
  sudo -n true        (whether sudo asks for a password: it does not)
  ```

  It answered 0. The shared root lock `/run/lock/bpf-mlir-root.lock` that the ported tests take (`cmd/spinelbpf/rootlock_test.go`) also exists on this host.
- So a plain `go test` of the ported tree would load and attach BPF programs as root. About 20 tests call `sudoCmd` without the `SPINELBPF_NO_ROOT` skip.
- `tests/spinel-bpf-mlir/run.sh` therefore:
  - puts a `sudo` first on `PATH` that records the call and fails;
  - points the root lock at a file of its own;
  - fails the suite if any test reached `sudo`.
- No test has been run as root here.

## The public pair

The published tree does not use the development Go module above. Its
tools/spinel-bpf-mlir builds against a published pair, which
`tools/dist/p4-inputs.tsv` records:

- **bpf-mlir v1.20.0 source release:** `bpf-mlir-1.20.0-source.tar.gz`,
  sha256 `838c0be6ffc0315bb56ea934191f9300e7166ddd109b6c648b0a99c5049ed2e7`.
  Its SOURCE_VERSION names `source_commit=d3e13842326f4dd2006b2f5528a3c9b6f409caf7`,
  the `public/bpf-mlir` row of `tools/spinel-bpf-mlir/third_party/PINS`.
- **go-bpf-mlir v0.18.0:** go.sum `h1:LAKx81MvjJmhd1XydQIB7cQBKDPzlZDxzdZ7ID3y5BI=`
  for the module and `h1:sFMCJqXQgwJdEcyX1sZ7doZS/gLMmrG2djtHwNxGLBA=` for
  its `go.mod`. P4 took it from the approved archive
  `go-bpf-mlir-0.18.0-1.tar.gz`, sha256
  `d9cc80634e493c879b51096b487ea2dfd33d579c56d09f11406ad4ea0643355f`.
- Once go-bpf-mlir is published, the module is fetched through the module
  proxy and checked against `sum.golang.org`; until then that check waits.
