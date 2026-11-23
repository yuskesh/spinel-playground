# Shader lane tools — installation record

`tools/shader` turns a Ruby shader into SPIR-V, WGSL and MSL, and
`tests/shader/run.sh` draws the results on the Apple GPU. The lane needs four
third-party tools. All are user-local or were already on this machine; nothing
shared was changed: no system package, no Xcode component (the Metal toolchain
is not installed, and the lane does not need it).

Recorded on the macOS arm64 build machine (Apple M1 Max), 2026-09-23.

| Tool | Version | Where | How it got there |
|---|---|---|---|
| `mlir-opt`, `mlir-translate`, `clang` | LLVM 23.1.1 | `$LLVM_PREFIX/bin` | the official release this repository already uses ([record](../llvm-23.1.1-macos/INSTALLATION-RECORD.md)) |
| `naga` | naga-cli 29.0.0 | `~/.cargo/bin/naga` | already installed (2026-08-17) with `cargo install naga-cli --version 29.0.0 --locked` |
| `spirv-val` | SPIRV-Tools v2025.5 (Homebrew `spirv-tools` 1.4.335.0) | `/opt/homebrew/bin` | already installed; used as found, not upgraded |
| wgpu-native | v29.0.1.1, `wgpu-macos-aarch64-release.zip` | `~/toolchains/wgpu-native-v29.0.1.1` | **installed for this lane**, below |

naga is pinned at 29.0.0 because wgpu-native v29.0.1.1 carries that naga as its
own shader translator; spinel-llvm pinned the pair for the same reason. MLIR's
SPIR-V serialisation comes from the LLVM release, not from Homebrew's LLVM,
which spinel-llvm used.

## wgpu-native

```sh
D=$HOME/toolchains/wgpu-native-v29.0.1.1
mkdir -p $D.tmp && cd $D.tmp
curl -fsSL -o wgpu.zip \
  https://github.com/gfx-rs/wgpu-native/releases/download/v29.0.1.1/wgpu-macos-aarch64-release.zip
shasum -a 256 wgpu.zip   # a5797a37b1adf720bcd5dcffb291edbbd5b7b14be0a3874c28e6393a655a7a3e
                         # 13733288 bytes
unzip -q wgpu.zip -d extract
mv extract $D && mkdir -p $D/download && mv wgpu.zip $D/download/ && cd && rmdir $D.tmp
cat $D/wgpu-native-meta/wgpu-native-git-tag   # v29.0.1.1
```

The release publishes no checksum; the digest above is the one this machine
downloaded. The tree holds `include/webgpu/{webgpu,wgpu}.h` and
`lib/libwgpu_native.{a,dylib}`. `tests/shader/run.sh` links the static library
through `WGPU_NATIVE=$D`.

Dawn, which spinel-llvm also fetched, is **not** installed: it served only the
wgpu-against-Dawn comparison, which is an oracle and is not run here.

## Use

```sh
export LLVM_PREFIX=...                       # as docs/building.md
export PATH="$HOME/.cargo/bin:$PATH"         # naga
export WGPU_NATIVE=$HOME/toolchains/wgpu-native-v29.0.1.1
sh tests/shader/run.sh
```
