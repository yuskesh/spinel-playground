#!/bin/bash
# scripts/diff-strarg.sh — tpfield / sysarg の strptr・strarray の分類の差動 (E053): C (build/tools/strarg_case — src/caps/live_str.c・live_v11.c・
# live_v13.c) と Go (test/oracle/cmd/strarg-live — kload の v11.go・v13.go の機械的な写し — scripts/gen-strarg-copy.sh) の出力を行ごとに比べる。
#
#   scripts/diff-strarg.sh n [TOOLS_DIR] [OUT_DIR]   # 非 root: 作った宣言の表 (tpdepth・sysdepth)、作った tracefs の dir の format の照合 (tp・sys)、
#                                                    #   vmlinux の全ての __do_sys_* の BTF の道 (btfdepth と、tracefs の無い dir での sys × n 1..6)、
#                                                    #   本当の tracefs (非 root は読めない — Unknown) の数行
#   scripts/diff-strarg.sh r [TOOLS_DIR] [OUT_DIR]   # root: 本当の tracefs の全ての syscalls/sys_enter_* × n 1..6 と全ての event の全ての field
#                                                    #   × {strptr, strarray} (gate は rsudo — bpf-mlir の root の lock の中で)
#
# 比べるのは答えの種類 (ok・unknown・error) と食い違いの文・Unknown の文の全て。BML_MUTANT を付けると C の側の変異 (差が出れば rc 1)。
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/diff-strarg.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:?n か r}"
TOOLS="${2:-$HERE/build/tools}"
W="${3:-$HERE/build/tmp/diff-strarg-$MODE}"
GOBIN="${STRARG_LIVE:-$HERE/build/oracles/strarg-live}"
[ -x "$TOOLS/strarg_case" ] || { echo "diff-strarg: $TOOLS/strarg_case が無い (build-tools.sh)" >&2; exit 1; }
[ -x "$GOBIN" ] || { echo "diff-strarg: $GOBIN が無い (scripts/build-oracles.sh)" >&2; exit 1; }
"$HERE/scripts/gen-strarg-copy.sh" --check
rm -rf "$W"
mkdir -p "$W"
D="$HERE/test/caps/fixture/e53/decls.txt"
D54="$HERE/test/caps/fixture/e54/decls.txt" # E054: tpfield の byte の配列 [N]u8 / [N]i8 の宣言 (bpf-mlir E552)
ATYPES="[4]u8 [4]i8 [16]u8"
TYPES="strptr strarray"
cmp_run() { # $1 問いの file、$2 tracefs の root (空は本当の tracefs)
  local q=$1 r=${2:-} b
  b=$(basename "$q" .txt)
  "$TOOLS/strarg_case" "$q" ${r:+"$r"} > "$W/$b.c.txt"
  "$GOBIN" "$q" ${r:+"$r"} > "$W/$b.go.txt"
  if cmp -s "$W/$b.c.txt" "$W/$b.go.txt"; then
    # 答えの種類は問いの field の後の列 (tp は 7、sys は 5、*depth は 3 — field の名前が ok・error でも数え違えない)
    echo "diff-strarg: $b $(wc -l < "$W/$b.c.txt") 行 same ($(awk -F'\t' '{c = $1 == "tp" ? 7 : $1 == "sys" ? 5 : 3; n[$c]++}
      END {printf "ok %d・unknown %d・error %d", n["ok"], n["unknown"], n["error"]}' "$W/$b.c.txt"))"
  else
    echo "diff-strarg: $b DIFF $(diff "$W/$b.c.txt" "$W/$b.go.txt" | grep -c '^<') 行"
    diff "$W/$b.c.txt" "$W/$b.go.txt" | head -6
    return 1
  fi
}
rc=0
if [ "$MODE" = n ]; then
  # 1. 宣言の表 (tab を含む行は問いの区切りと衝突するので format の file でだけ使う)
  # sysdepth は宣言の全体と、最後の識別子を外した型の文字列 (tracefs の syscall の format の型の読みと同じ形) の両方で
  grep -v $'\t' "$D" | while IFS= read -r d; do
    printf 'tpdepth\t%s\nsysdepth\t%s\nsysdepth\t%s\n' "$d" "$d" "$(printf '%s' "$d" | sed -E 's/[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$//')"
  done > "$W/decl.txt"
  # E054: 両方の表の宣言の byte の配列の shape (tpByteArrayShape) と名前 (tpFieldName)
  cat "$D" "$D54" | grep -v $'\t' | while IFS= read -r d; do printf 'tparray\t%s\ntpname\t%s\n' "$d" "$d"; done >> "$W/decl.txt"
  cmp_run "$W/decl.txt" || rc=1
  # 2. 作った tracefs: event ごとに 1 つの宣言 (offset 16・8 byte)、名前は宣言の最後の識別子 (読めない宣言は format の誤り — 名前は x)
  F="$W/tracefs"
  i=0
  : > "$W/fmt.txt"
  while IFS= read -r d; do
    i=$((i + 1))
    nm=$(printf '%s' "$d" | grep -oE '[A-Za-z_][A-Za-z0-9_]*' | tail -1 || true)
    mkdir -p "$F/events/e53/d$i" "$F/events/syscalls/sys_enter_e53d$i"
    printf 'name: d%d\nformat:\n\tfield:unsigned short common_type;\toffset:0;\tsize:2;\tsigned:0;\n\tfield:%s;\toffset:16;\tsize:8;\tsigned:0;\n' "$i" "$d" > "$F/events/e53/d$i/format"
    printf 'name: sys_enter_e53d%d\nformat:\n\tfield:unsigned short common_type;\toffset:0;\tsize:2;\tsigned:0;\n\tfield:int __syscall_nr;\toffset:8;\tsize:4;\tsigned:1;\n\tfield:%s;\toffset:16;\tsize:8;\tsigned:0;\n' "$i" "$d" > "$F/events/syscalls/sys_enter_e53d$i/format"
    for t in $TYPES; do
      printf 'tp\te53/d%d\t%s\t16\t8\t%s\ntp\te53/d%d\t%s\t24\t8\t%s\ntp\te53/d%d\t%s\t16\t4\t%s\n' "$i" "${nm:-x}" "$t" "$i" "${nm:-x}" "$t" "$i" "${nm:-x}" "$t" >> "$W/fmt.txt"
      printf 'sys\te53d%d\t1\t%s\nsys\te53d%d\t2\t%s\n' "$i" "$t" "$i" "$t" >> "$W/fmt.txt"
    done
    printf 'tp\te53/d%d\t%s\t16\t8\tu\nsys\te53d%d\t1\tptr\n' "$i" "${nm:-x}" "$i" >> "$W/fmt.txt"
  done < "$D"
  # 同じ名前の field が 2 つ (最初は合う char *、2 つ目は読めない alias — Unknown は全ての同じ名前を見る)・無い field・無い event
  mkdir -p "$F/events/e53/dup"
  printf 'name: dup\nformat:\n\tfield:const char * f;\toffset:16;\tsize:8;\tsigned:0;\n\tfield:u8 * f;\toffset:24;\tsize:8;\tsigned:0;\n' > "$F/events/e53/dup/format"
  for t in $TYPES; do printf 'tp\te53/dup\tf\t16\t8\t%s\ntp\te53/dup\tnone\t16\t8\t%s\ntp\te53/nope\tf\t16\t8\t%s\nsys\tnope_e53\t1\t%s\n' "$t" "$t" "$t" "$t" >> "$W/fmt.txt"; done
  # E054: 配列の宣言の event (offset 16・size 4、signed 0 と 1 の 2 つ)。名前は Go の tpFieldName (C の名前の読みは 1 の表で比べる)
  i=0
  while IFS= read -r d; do
    i=$((i + 1))
    nm=$(printf 'tpname\t%s\n' "$d" | "$GOBIN" /dev/stdin | cut -f4) # 出力は "tpname<宣言>ok<名前>" — 名前は 4 列目 (E054 の 1 回目は -f3 の誤り)
    for sg in 0 1; do
      mkdir -p "$F/events/e54/a$i-$sg"
      printf 'name: a%d\nformat:\n\tfield:unsigned short common_type;\toffset:0;\tsize:2;\tsigned:0;\n\tfield:%s;\toffset:16;\tsize:4;\tsigned:%d;\n' "$i" "$d" "$sg" > "$F/events/e54/a$i-$sg/format"
      for t in $ATYPES; do
        n=${t#[}; n=${n%%]*}
        printf 'tp\te54/a%d-%d\t%s\t16\t%s\t%s\ntp\te54/a%d-%d\t%s\t20\t%s\t%s\n' "$i" "$sg" "$nm" "$n" "$t" "$i" "$sg" "$nm" "$n" "$t" >> "$W/fmt.txt"
      done
      printf 'tp\te54/a%d-%d\t%s\t16\t4\tu\ntp\te54/a%d-%d\t%s\t16\t4\ti\n' "$i" "$sg" "$nm" "$i" "$sg" "$nm" >> "$W/fmt.txt"
    done
  done < <(grep -v $'\t' "$D54")
  cmp_run "$W/fmt.txt" "$F" || rc=1
  # 3. vmlinux の __do_sys_* (BTF の道): 引数ごとの深度と、tracefs の無い dir での CheckSyscallArg
  "$GOBIN" --list-do-sys | LC_ALL=C sort -u > "$W/do-sys.txt"
  mkdir -p "$W/empty"
  while read -r s; do
    printf 'btfdepth\t%s\n' "$s"
    for n in 1 2 3 4 5 6; do for t in $TYPES; do printf 'sys\t%s\t%d\t%s\n' "$s" "$n" "$t"; done; done
  done < "$W/do-sys.txt" > "$W/btf.txt"
  cmp_run "$W/btf.txt" "$W/empty" || rc=1
  # 4. 本当の tracefs (非 root — 読めない Unknown の文)
  if [ "$(id -u)" != 0 ]; then
    printf 'tp\tsyscalls/sys_enter_openat\tfilename\t24\t8\tstrptr\ntp\tsyscalls/sys_enter_execve\targv\t24\t8\tstrarray\nsys\topenat\t2\tstrptr\nsys\texecve\t2\tstrarray\n' > "$W/real.txt"
    cmp_run "$W/real.txt" || rc=1
  fi
elif [ "$MODE" = r ]; then
  [ "$(id -u)" = 0 ] || { echo "diff-strarg: r は root で" >&2; exit 1; }
  T=/sys/kernel/tracing
  for e in "$T"/events/syscalls/sys_enter_*/; do
    s=$(basename "$e"); s=${s#sys_enter_}
    for n in 1 2 3 4 5 6; do for t in $TYPES; do printf 'sys\t%s\t%d\t%s\n' "$s" "$n" "$t"; done; done
  done > "$W/rsys.txt"
  cmp_run "$W/rsys.txt" || rc=1
  # 全ての event の全ての field (本当の offset — 幅は 8 で問う。名前は C と Go が同じ規則で読むので、ここでは宣言の最後の識別子で問う)
  for f in "$T"/events/*/*/format; do
    ev=${f#"$T"/events/}; ev=${ev%/format}
    grep -E '^[[:space:]]*field:' "$f" | while IFS= read -r l; do
      decl=${l#*field:}; decl=${decl%%;*}
      off=$(printf '%s' "$l" | grep -oE 'offset:[0-9]+' | cut -d: -f2)
      nm=$(printf '%s' "$decl" | sed 's/\[[^]]*\][[:space:]]*$//' | grep -oE '[A-Za-z_][A-Za-z0-9_]*' | tail -1)
      for t in $TYPES; do printf 'tp\t%s\t%s\t%s\t8\t%s\n' "$ev" "$nm" "$off" "$t"; done
    done
  done > "$W/rtp.txt"
  cmp_run "$W/rtp.txt" || rc=1
  # E054 (H4r): 全ての event の全ての field の宣言の名前 (tpFieldName — C と Go)・新旧の正規表現で名前が変わる宣言の数 (Go の側だけ — 旧は E053 の
  # 正規表現)、その名前で本当の size の {[size]u8, [size]i8, u, i} を問う
  for f in "$T"/events/*/*/format; do
    grep -E '^[[:space:]]*field:' "$f" | while IFS= read -r l; do decl=${l#*field:}; printf 'tpname\t%s\n' "${decl%%;*}"; done
  done | grep -v $'\t.*\t' > "$W/rname.txt"
  cmp_run "$W/rname.txt" || rc=1
  sed 's/^tpname/tpnameold/' "$W/rname.txt" | "$GOBIN" /dev/stdin | cut -f4 > "$W/rname-old.txt"
  cut -f4 "$W/rname.go.txt" | paste "$W/rname.txt" - "$W/rname-old.txt" | awk -F'\t' '$3 != $4' > "$W/rname-changed.txt"
  echo "diff-strarg: rname の宣言 $(wc -l < "$W/rname.txt")・新旧の正規表現で名前が変わる $(wc -l < "$W/rname-changed.txt") (rname-changed.txt — 宣言・新・旧)"
  for f in "$T"/events/*/*/format; do
    ev=${f#"$T"/events/}; ev=${ev%/format}
    grep -E '^[[:space:]]*field:' "$f" | while IFS= read -r l; do
      decl=${l#*field:}; decl=${decl%%;*}
      off=$(printf '%s' "$l" | grep -oE 'offset:[0-9]+' | cut -d: -f2)
      sz=$(printf '%s' "$l" | grep -oE 'size:[0-9]+' | cut -d: -f2)
      printf '%s\t%s\t%s\t%s\n' "$ev" "$decl" "$off" "$sz"
    done
  done | grep -v $'\t.*\t.*\t.*\t' > "$W/rfields.txt"
  cut -f2 "$W/rfields.txt" | sed 's/^/tpname\t/' | "$GOBIN" /dev/stdin | cut -f4 | paste "$W/rfields.txt" - |
    awk -F'\t' '$5 != "-" { for (i = 0; i < 4; i++) { t = i == 0 ? "[" $4 "]u8" : i == 1 ? "[" $4 "]i8" : i == 2 ? "u" : "i"; printf "tp\t%s\t%s\t%s\t%s\t%s\n", $1, $5, $3, $4, t } }' > "$W/rarr.txt"
  cmp_run "$W/rarr.txt" || rc=1
else
  echo "diff-strarg: mode は n か r" >&2; exit 2
fi
[ "$(id -u)" != 0 ] || chown -R "${SUDO_UID:-1000}" "$W"
exit $rc
