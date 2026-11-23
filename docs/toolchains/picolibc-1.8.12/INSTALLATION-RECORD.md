# picolibc 1.8.12 (Cortex-M33, built with LLVM 23.1.1) — installation record

Full on a Cortex-M33 with no RTOS ([decision 0037](../../decisions/0037-bare-metal-full.md))
links the hosted runtime, so it needs a C library: `malloc`, `stdio`'s
formatting, `strtod`, `setjmp` and the math functions. Without an RTOS nothing
supplies one. This is that library: picolibc 1.8.12, built for Cortex-M33 from
its release source with the official LLVM 23.1.1 clang. It is a third-party
dependency, built user-local and pinned. Nothing shared is changed, and nothing
in this repository names its location: spinel-modular's `tools/bare-full` takes the install
prefix as `BAREMETAL_PICOLIBC`. Decision 0037 records why this library and
this build.

## The pin

| | |
|---|---|
| version | picolibc 1.8.12 |
| source | <https://github.com/picolibc/picolibc/releases/download/1.8.12/picolibc-1.8.12.tar.xz> |
| source sha256 | `64e8c412e1c40fa6eb1a72d2b5cdbcbfe6ceca4cbea454edbad54557ffc747fa` (3,205,620 bytes) |
| built with | the official LLVM 23.1.1 (`docs/building.md`), meson and ninja |
| target | `thumbv8m.main-none-eabi`, `-mcpu=cortex-m33+nodsp -mfloat-abi=soft -mthumb` |

The sha256 equals the release's `picolibc-1.8.12.tar.xz.sha256sum` and the
digest GitHub's release API records for the asset. The release publishes no
signature, so none was checked.

## Debian 13 (x86_64), 2026-11-12

```sh
D=~/toolchains/picolibc-1.8.12-llvm23
mkdir -p $D/dl && cd $D/dl
curl -fsSLO https://github.com/picolibc/picolibc/releases/download/1.8.12/picolibc-1.8.12.tar.xz
curl -fsSLO https://github.com/picolibc/picolibc/releases/download/1.8.12/picolibc-1.8.12.tar.xz.sha256sum
sha256sum -c picolibc-1.8.12.tar.xz.sha256sum
cd $D && tar -xJf dl/picolibc-1.8.12.tar.xz && mv picolibc-1.8.12 src
L=/opt/llvm-23.1.1/bin
cat > $D/cross-m33.txt <<EOF
[binaries]
c = ['$L/clang', '--target=thumbv8m.main-none-eabi', '-mcpu=cortex-m33+nodsp', '-mfloat-abi=soft', '-mthumb', '-nostdlib', '-fuse-ld=lld', '-ffile-prefix-map=$D/src=picolibc-1.8.12']
ar = '$L/llvm-ar'
nm = '$L/llvm-nm'
strip = '$L/llvm-strip'

[host_machine]
system = 'none'
cpu_family = 'arm'
cpu = 'arm'
endian = 'little'

[properties]
c_args = ['-Werror=double-promotion', '-Wno-unsupported-floating-point-opt', '-fshort-enums']
c_link_args = ['-Wno-unused-command-line-argument']
skip_sanity_check = true
EOF
LD_LIBRARY_PATH=~/toolchains/icu-70/lib meson setup $D/build $D/src \
  --cross-file $D/cross-m33.txt --prefix=$D/install \
  -Dmultilib=false -Dpicocrt=false -Dsemihost=false -Dtests=false \
  -Dposix-console=true -Dio-long-long=true -Dthread-local-storage=false \
  -Dfreestanding=true -Dspecsdir=none
LD_LIBRARY_PATH=~/toolchains/icu-70/lib ninja -C $D/build install
export BAREMETAL_PICOLIBC=$D/install
```

- `-Dfreestanding=true` is required. Without it clang compiles `bzero`'s loop
  into a call to `__aeabi_memclr`, which picolibc defines as a weak alias of
  `bzero` itself: the first `.bss` clear recurses until the stack overflows,
  and QEMU hangs with no output.
- `-fuse-ld=lld`: without it meson's link checks pick the system linker, which
  does not know the target.
- On this host the LLVM 23.1.1 release's `ld.lld` loads ICU 70, which Debian 13
  does not ship; a user-local ICU 70 under `~/toolchains/icu-70/lib` supplies
  it. The freestanding lanes need the same (`tests/freestanding/README.md`).
- `-Dposix-console=true` sends `stdout` through `write`, which
  spinel-modular's `tools/bare-full`'s platform code puts on the board's UART.
- `-Dthread-local-storage=false`: there is one thread and no TLS set-up.
- `-Dpicocrt=false`, `-Dsemihost=false`: the start-up code and the console
  are spinel-modular's `tools/bare-full`'s own.
- `-ffile-prefix-map` names the sources `picolibc-1.8.12/...` in `__FILE__`
  strings. The DWARF build directory (`DW_AT_comp_dir`) still names `$D/build`;
  it is only in the debug sections, which are not loaded on the target.
- The archive, `lib/libc.a`: 4,021,532 bytes, 1,059 members, sha256
  `bd585de67ecd6003dc34a02dd49c42a1bc9834c8f564c64c03e08589bc82d349`.
  `lib/libm.a` is a 796-byte placeholder: picolibc puts the math functions in
  `libc.a`.

## Notices

picolibc's licences are in `COPYING.picolibc` of the source (BSD-style
licences of its several origins, newlib's among them). Nothing of picolibc is
tracked here; an image spinel-modular's `tools/bare-full` links contains parts of it and carries
those terms.

## Cortex-M0+ (RP2040), Debian 13, 2026-11-12

The same source, the same meson options and the same steps, in
`D=~/toolchains/picolibc-1.8.12-llvm23-m0plus`, with `cross-m0plus.txt` in
place of `cross-m33.txt`. It differs only in the compiler's target and core:

```
c = ['$L/clang', '--target=thumbv6m-none-eabi', '-mcpu=cortex-m0plus', '-mfloat-abi=soft', '-mthumb', '-nostdlib', '-fuse-ld=lld', '-ffile-prefix-map=$D/src=picolibc-1.8.12']
```

- `BAREMETAL_PICOLIBC=$D/install`, for spinel-modular's `tools/bare-full` on a Cortex-M0+ board.
- The archive, `lib/libc.a`: 4,028,046 bytes, 1,059 members, sha256
  `22fa76008b38c0c20424cf4178f5730cf5d216209a8f2f6a4e45a480672a6b37`.
