#!/bin/bash
# scripts/split-fixtures.sh — E055 の分けた DWARF の fixture (bpf-mlir R057 の形: gcc -g -Wl,--build-id → llvm-objcopy --only-keep-debug →
# --strip-debug → --add-gnu-debuglink) と、requirements_format.md の「分離DWARF」の段ごとの不正な形を OUT に作る。gcc だけ (宣言の DIE — E556)。
#
#   scripts/split-fixtures.sh OUT
#
# 本体: whole (埋め込み)・stripped (debuglink 付き)・nolink・noid (build ID 無し)・badlink (debuglink の形の誤り)・altlink (本体の altlink)
# 分けた file: whole.debug (合う)・badid・badcrc・altlink・rel・types・nobits・zdebug・zstd・zlib・machine・dupnote・noinfo・text・big
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
O="${1:?OUT}"
OC=/opt/llvm-23.1.1/bin/llvm-objcopy
F="$HERE/test/dwarf/fixture/e55"
rm -rf "$O"; mkdir -p "$O"
cd "$O"
gcc -g -O0 -Wl,--build-id -o whole "$F/decl.c" "$F/def.c"
gcc -g -O0 -Wl,--build-id=0x0102030405060708090a0b0c0d0e0f1011121314 -o whole-otherid "$F/decl.c" "$F/def.c"
gcc -g -O0 -Wl,--build-id=none -o whole-noid "$F/decl.c" "$F/def.c"
gcc -g -O0 -c -o def.o "$F/def.c"
"$OC" --only-keep-debug whole whole.debug
"$OC" --strip-debug whole nolink
"$OC" --strip-debug --add-gnu-debuglink=whole.debug whole stripped
"$OC" --strip-debug whole-noid noid
printf 'x\0\0\0' > bad-link.bin # 名前の後に CRC の 4 byte が無い
"$OC" --add-section .gnu_debuglink=bad-link.bin --set-section-type .gnu_debuglink=1 nolink badlink
printf 'alt\0' > alt.bin
"$OC" --add-section .gnu_debugaltlink=alt.bin nolink altlink
"$OC" --dump-section .note.gnu.build-id=note.bin whole /dev/null
# 分けた file の不正な形
"$OC" --only-keep-debug whole-otherid badid.debug
printf '0123456789abcdef' > pad.bin
"$OC" --add-section .bml_pad=pad.bin whole.debug badcrc.debug
"$OC" --add-section .gnu_debugaltlink=alt.bin whole.debug altlink.debug
"$OC" --add-section .note.gnu.build-id=note.bin --set-section-type .note.gnu.build-id=7 def.o rel.debug # .rela.debug_* の sh_info が debug の section
"$OC" --add-section .debug_types=pad.bin whole.debug types.debug
"$OC" --set-section-type .debug_str=8 whole.debug nobits.debug
"$OC" --rename-section .debug_abbrev=.zdebug_abbrev whole.debug zdebug.debug # ZLIB の header の無い .zdebug_*
"$OC" --compress-debug-sections=zstd whole.debug zstd.debug
"$OC" --compress-debug-sections=zlib whole.debug zlib.debug
cp whole.debug machine.debug
printf '\xb7\x00' | dd of=machine.debug bs=1 seek=18 count=2 conv=notrunc status=none # e_machine を aarch64 に
"$OC" --add-section .note.gnu.build-id=note.bin --set-section-type .note.gnu.build-id=7 whole.debug dupnote.debug
"$OC" --remove-section .debug_info whole.debug noinfo.debug
printf 'not an ELF\n' > text.debug
truncate -s 268435457 big.debug # 上限 + 1 (sparse)
# build ID の root の配置 (.build-id/<先頭 2 桁>/<残り>.debug)
id=$(od -An -tx1 -v note.bin | tr -d ' \n' | tail -c 40)
mkdir -p "root/.build-id/${id:0:2}"
cp whole.debug "root/.build-id/${id:0:2}/${id:2}.debug"
echo "$id" > build-id.txt
ls
