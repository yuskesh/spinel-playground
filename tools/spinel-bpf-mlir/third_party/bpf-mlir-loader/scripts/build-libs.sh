#!/bin/bash
# scripts/build-libs.sh — 製品の静的な library を build する: zlib (third_party/zlib) → libelf (third_party/elfutils — zstd・bzip2・lzma・debuginfod 無し)
# → libbpf (third_party/libbpf — その libelf の header で) → libbml.a (src/)。submodule の tree は汚さない。
#
#   scripts/build-libs.sh [OUT]        # 既定の OUT は build/libs
#
# 出力: OUT/lib/{libz.a,libelf.a,libbpf.a,libbml.a,libbml_spinel.a}、OUT/include/ (zlib・libelf・libbpf・bml の header)、OUT/LICENSES・NOTICE。
# 再現: 同じ source → 同じ .a を狙う (E001) — path は -ffile-prefix-map で消し、ar は D (決定的)、SOURCE_DATE_EPOCH は固定。
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HERE/build/libs}"
# Spinel Extended: the three sources are not submodules here; they are
# user-local checkouts at bml's pinned commits (docs/toolchains/
# spinel-bpf-mlir-deps/INSTALLATION-RECORD.md), named by these variables.
ZLIB_DIR="${BML_ZLIB_DIR:-$HERE/third_party/zlib}"
ELFUTILS_DIR="${BML_ELFUTILS_DIR:-$HERE/third_party/elfutils}"
LIBBPF_DIR="${BML_LIBBPF_DIR:-$HERE/third_party/libbpf}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
JOBS="$(nproc)"
export TMPDIR="$HERE/build/tmp"
mkdir -p "$TMPDIR"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$HERE" log -1 --format=%ct -- third_party src include shim)}"
export LC_ALL=C TZ=UTC
export ARFLAGS=crD

rm -rf "$OUT/zlib" "$OUT/elfutils" "$OUT/libbpf" "$OUT/bml" "$OUT/bml_spinel" "$OUT/lib" "$OUT/include" "$OUT/log"
mkdir -p "$OUT/lib" "$OUT/include" "$OUT/log"

# 段の出力は OUT/log/<段>.log に。失敗なら段の名前と出力の末尾を stderr に出して止める (無言の rc 1 にしない — E071)
step() {
  local name="$1" log="$OUT/log/$1.log"
  shift
  if ! "$@" >"$log" 2>&1; then
    echo "build-libs: step '$name' failed: $*" >&2
    echo "build-libs: last 40 lines of $log:" >&2
    tail -n 40 "$log" >&2
    exit 1
  fi
}

# ---- zlib (third_party/zlib) ----
# configure を使わず (zconf.h を生成しない) library の source を直接。_LARGEFILE64_SOURCE は libbpf の gzopen64 のため。
Z="$OUT/zlib"
mkdir -p "$Z"
Z_CFLAGS="-O2 -g -D_LARGEFILE64_SOURCE=1 -DHAVE_HIDDEN -ffile-prefix-map=$ZLIB_DIR=zlib -ffunction-sections -fdata-sections"
for s in adler32 crc32 deflate infback inffast inflate inftrees trees zutil compress uncompr gzclose gzlib gzread gzwrite; do
  gcc $Z_CFLAGS -c "$ZLIB_DIR/$s.c" -o "$Z/$s.o"
done
ar crD "$OUT/lib/libz.a" $(ls "$Z"/*.o | LC_ALL=C sort)
cp "$ZLIB_DIR/zlib.h" "$ZLIB_DIR/zconf.h" "$OUT/include/"

# ---- libelf (elfutils) ----
# git の tree には libdw/known-dwarf.h (gawk で生成) が無く、maintainer mode でない configure はそれを要る。
# 生成の awk は gawk に固有 (match の配列・asorti)。libelf と libeu はこの header を使わない (build の後に .deps で
# 確かめる) — build の側の複写に #error の置き物を置く (libdw を build すれば loud に落ちる)。
EU="$OUT/elfutils"
mkdir -p "$EU/src" "$EU/obj"
git -C "$ELFUTILS_DIR" archive --format=tar HEAD | tar -x -C "$EU/src"
printf '#error "placeholder: libdw is not built by bpf-mlir-loader (scripts/build-libs.sh)"\n' > "$EU/src/libdw/known-dwarf.h"
# autoreconf は autopoint (gettext) を要る
(cd "$EU/src" && step elfutils-autoreconf autoreconf -fi)
EU_CFLAGS="-O2 -g -ffile-prefix-map=$EU/src=elfutils -ffile-prefix-map=$EU/obj=elfutils -ffile-prefix-map=$OUT=out -ffunction-sections -fdata-sections"
# zlib は上の third_party/zlib のもの (system の zlib の header と library を使わない)
(cd "$EU/obj" && step elfutils-configure "$EU/src/configure" --quiet \
   --without-zstd --without-bzlib --without-lzma \
   --disable-debuginfod --disable-libdebuginfod --disable-nls --disable-demangler \
   --disable-textrelcheck --disable-symbol-versioning \
   CFLAGS="$EU_CFLAGS" CPPFLAGS="-I$OUT/include" LDFLAGS="-L$OUT/lib")
step elfutils-libeu make -C "$EU/obj/lib" -j"$JOBS" libeu.a
step elfutils-libelf make -C "$EU/obj/libelf" -j"$JOBS" libelf.a
if grep -rl known-dwarf "$EU/obj/lib/.deps" "$EU/obj/libelf/.deps" >/dev/null 2>&1; then
  echo "build-libs: libelf / libeu included known-dwarf.h (the placeholder)" >&2; exit 1
fi
if grep -rlE "/usr/include/(zlib|zconf)\.h" "$EU/obj/libelf/.deps" >/dev/null 2>&1; then
  echo "build-libs: libelf included the system zlib headers" >&2; exit 1
fi
cp "$EU/obj/libelf/libelf.a" "$OUT/lib/"
cp "$EU/src/libelf/libelf.h" "$EU/src/libelf/gelf.h" "$EU/src/libelf/nlist.h" "$EU/src/libelf/elf.h" "$OUT/include/"

# ---- libbpf ----
LB="$OUT/libbpf"
mkdir -p "$LB/obj"
step libbpf make -C "$LIBBPF_DIR/src" -j"$JOBS" BUILD_STATIC_ONLY=y NO_PKG_CONFIG=1 \
  EXTRA_CFLAGS="-I$OUT/include -ffile-prefix-map=$LIBBPF_DIR=libbpf -ffile-prefix-map=$OUT=out -ffunction-sections -fdata-sections" \
  ARFLAGS=rcsD OBJDIR="$LB/obj" DESTDIR="$LB" PREFIX= LIBDIR=/lib INCLUDEDIR=/include install
cp "$LB/lib/libbpf.a" "$OUT/lib/"
cp -r "$LB/include/bpf" "$OUT/include/"
if [ -n "$(git -C "$LIBBPF_DIR" status --porcelain)" ]; then
  echo "build-libs: third_party/libbpf has uncommitted changes after the build" >&2; exit 1
fi

# ---- libbml ----
B="$OUT/bml"
mkdir -p "$B"
# prefix map は後のものが勝つ — $OUT ($HERE の中) を後に (E004 — libelf の elf.h を含む object の debug の include の dir)
BML_CFLAGS="-O2 -g -std=gnu11 -Wall -Wextra -Werror -ffile-prefix-map=$HERE=bml -ffile-prefix-map=$OUT=out -ffunction-sections -fdata-sections -I$HERE/src -I$HERE/include -I$LIBBPF_DIR/include/uapi -I$OUT/include"
rm -f "$B"/*.o
# src の層の directory (util・json・elf・btf・req・caps・maps …) の全ての .c — object の名前は path から (層で同じ名前の file が在っても衝突しない)
for c in $("$HERE/scripts/srcs.sh" src); do
  obj=$(printf '%s' "${c#"$HERE"/src/}" | tr / _)
  gcc $BML_CFLAGS -c "$c" -o "$B/${obj%.c}.o"
done
ar crD "$OUT/lib/libbml.a" $(ls "$B"/*.o | LC_ALL=C sort)
cp -r "$HERE/include/bml" "$OUT/include/"
rm -f "$OUT/include/bml/bml_testonly.h" # 試験の build だけの口 (E017) — 製品の library に無いので header も配らない

# ---- libbml_spinel (E007 — spinel-bpf-mlir の spinelbpf_* の C ABI の shim、libbml.a と共に link する別の archive) ----
S="$OUT/bml_spinel"
rm -rf "$S"; mkdir -p "$S"
for c in $(find "$HERE/shim/spinel" -name '*.c' | LC_ALL=C sort); do
  gcc $BML_CFLAGS -I"$HERE" -c "$c" -o "$S/spinel_$(basename "${c%.c}").o"
done
ar crD "$OUT/lib/libbml_spinel.a" $(ls "$S"/*.o | LC_ALL=C sort)
cp "$HERE/shim/spinel/spinelbpf.h" "$OUT/include/bml/"

if [ -n "$(git -C "$ELFUTILS_DIR" status --porcelain)$(git -C "$ZLIB_DIR" status --porcelain)" ]; then
  echo "build-libs: third_party/elfutils or zlib has uncommitted changes after the build" >&2; exit 1
fi

# ---- license の文と NOTICE (版を固定した source から毎回作る — 版とずれない。P001 §1) ----
# 配布するか・どの license を選ぶかは利用者の判断。ここは下流の実行 file に静的に入る部品の文を集めるだけ。
L="$OUT/LICENSES"
rm -rf "$L"
mkdir -p "$L"
cp "$LIBBPF_DIR/LICENSE" "$L/libbpf.LICENSE"
cp "$LIBBPF_DIR/LICENSE.BSD-2-Clause" "$L/libbpf.BSD-2-Clause"
cp "$LIBBPF_DIR/LICENSE.LGPL-2.1" "$L/libbpf.LGPL-2.1"
cp "$ELFUTILS_DIR/COPYING-LGPLV3" "$L/elfutils-libelf.LGPL-3.0"
cp "$ELFUTILS_DIR/COPYING-GPLV2" "$L/elfutils-libelf.GPL-2.0"
cp "$ZLIB_DIR/LICENSE" "$L/zlib.LICENSE"
ZH="$ZLIB_DIR/zlib.h"
eu_ver=$(git -C "$ELFUTILS_DIR" describe --tags --exact-match 2>/dev/null || git -C "$ELFUTILS_DIR" rev-parse HEAD)
lb_ver=$(git -C "$LIBBPF_DIR" describe --tags --exact-match 2>/dev/null || git -C "$LIBBPF_DIR" rev-parse HEAD)
z_ver=$(sed -n 's/^#define ZLIB_VERSION "\(.*\)"/\1/p' "$ZH")
cat > "$OUT/NOTICE" <<EOF
bpf-mlir-loader — statically linked components (generated by build-libs.sh; license texts are in LICENSES/)

- libbpf $lb_ver ($(git -C "$LIBBPF_DIR" rev-parse HEAD)) — LGPL-2.1 OR BSD-2-Clause
  (recommended: choose BSD-2-Clause — show LICENSES/libbpf.BSD-2-Clause in the documentation of distributed binaries)
- elfutils libelf $eu_ver ($(git -C "$ELFUTILS_DIR" rev-parse HEAD)) — GPL-2.0-or-later OR LGPL-3.0-or-later
  (choosing LGPL-3.0 with static linking requires giving recipients a way to replace libelf and relink — the executable's object files or source, plus instructions)
  build: --without-zstd --without-bzlib --without-lzma --disable-debuginfod --disable-libdebuginfod --disable-nls
- zlib $z_ver ($(git -C "$ZLIB_DIR" rev-parse HEAD)) — zlib license
- bpf-mlir-loader itself — license not yet decided
EOF
ls -l "$OUT/lib" | awk 'NR>1{print $5, $9}'
