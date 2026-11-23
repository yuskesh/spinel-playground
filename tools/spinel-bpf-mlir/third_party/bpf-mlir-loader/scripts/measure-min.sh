#!/bin/bash
# scripts/measure-min.sh — test/min/min.c を build/libs の静的な library で link し、大きさ・NEEDED・signal / thread /
# rlimit の参照を出す (E001)。gate からも呼ぶ — 期待から外れれば rc 1。
#
#   scripts/measure-min.sh [LIBS]     # 既定の LIBS は build/libs (scripts/build-libs.sh の出力)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LIBS="${1:-$HERE/build/libs}"
OUT="$HERE/build/min"
mkdir -p "$OUT"
ZLIB="$LIBS/lib/libz.a"
CFLAGS="-O2 -std=gnu11 -Wall -Wextra -Werror -ffunction-sections -fdata-sections"

gcc $CFLAGS -I"$LIBS/include" -o "$OUT/min" "$HERE/test/min/min.c" \
  "$LIBS/lib/libbml.a" "$LIBS/lib/libbpf.a" "$LIBS/lib/libelf.a" "$ZLIB" -Wl,--gc-sections -Wl,-Map="$OUT/min.map"
strip -o "$OUT/min.stripped" "$OUT/min"

fail=0
echo "== size (bytes: unstripped stripped)"
echo "$(stat -c %s "$OUT/min") $(stat -c %s "$OUT/min.stripped")"
size "$OUT/min" | tail -1
echo "== NEEDED"
needed=$(readelf -d "$OUT/min" | awk '/NEEDED/{print $NF}' | tr -d '[]' | tr '\n' ' ')
echo "$needed"
[ "$needed" = "libc.so.6 " ] || { echo "measure-min: NEEDED が libc.so.6 だけでない" >&2; fail=1; }
echo "== 動的の import の signal / thread / rlimit / atexit"
bad=$(nm -D "$OUT/min" | awk '$1=="U"{print $2}' | sed 's/@.*//' | grep -E '^(sigaction|signal|sigprocmask|sigset|bsd_signal|sysv_signal|pthread_[a-z_]+|atexit|__cxa_atexit|prctl|clone[0-9]*|fork|setrlimit[0-9]*|prlimit[0-9]*)$' | sort -u | tr '\n' ' ' || true)
echo "${bad:-(none)}"
# setrlimit は libbpf の memlock の経路 (libbpf_set_memlock_rlim(0) で実行時は呼ばれない — strace で別に確かめる)
[ "$bad" = "setrlimit64 " ] || { echo "measure-min: 期待 (setrlimit64 だけ) と違う import: $bad" >&2; fail=1; }
echo "== 入力ごとの .text/.rodata/.data (link map — gc の後。併合の文字列の section は最初の入力に付くので別の行に)"
awk 'function hex(s,  i,c,v){v=0;s=tolower(s);sub(/^0x/,"",s);for(i=1;i<=length(s);i++){c=index("0123456789abcdef",substr(s,i,1))-1;v=v*16+c}return v}
/^Linker script and memory map/{on=1} !on{next}
/^ \.(text|rodata|data)[^ ]*$/ {sec=$1; getline; if (NF>=3) {sz=hex($2); f=$3} else next; }
/^ \.(text|rodata|data)[^ ]* +0x/ {sec=$1; sz=hex($3); f=$4}
{ if (f=="") next; if (sec ~ /\.str/) k="(merged strings — 全ての入力の文字列の併合)"; else if (f ~ /libbpf\.a/) k="libbpf.a"; else if (f ~ /libelf\.a/) k="libelf.a"; else if (f ~ /libz\.a/) k="libz.a"; else if (f ~ /libbml\.a/) k="libbml.a"; else k="other (min・crt)"; s[k]+=sz; f=""}
END{for (k in s) print s[k], k}' "$OUT/min.map" | sort -rn
exit $fail
