#!/bin/bash
# scripts/spinel-diff.sh — E007 の差動: spinel の Go の loader (試験の c-archive — scripts/spinel-oracle.sh) と shim (libbml_spinel.a + libbml) に
# 同じ driver (test/shim/spinel_diff.c) を link し、spinel の ELF (commit 済みの例 5 つと docs/experiments/results の ELF) の上の同じ操作の列の
# kind・value・bytes を比べる。
#
#   scripts/spinel-diff.sh build            driver 2 つと elf_maps を build/tmp/e007/ に (root 不要)
#   scripts/spinel-diff.sh gen              ELF ごとの操作の列と名指しの契約の差の表を build/tmp/e007/cases/ に (root 不要)
#   sudo scripts/spinel-diff.sh run <出力>   両方を unshare -n の中で走らせる (root)
#   scripts/spinel-diff.sh compare <出力>    比べる (名指しの差の外の差は失敗)
set -uo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/spinel-diff.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$HERE/build/tmp/e007"
O="$HERE/build/tmp/spinel-oracle"
L="$HERE/build/libs"
SP="$O/src"
mkdir -p "$W"

build() {
  [ -f "$O/libspinelbpf_test.a" ] || { echo "spinel-diff: $O/libspinelbpf_test.a が無い (scripts/spinel-oracle.sh)" >&2; exit 1; }
  local CF=(-O1 -g -std=gnu11 -Wall -Wextra -Werror -I"$HERE" -I"$HERE/src" -I"$HERE/include" -I"$HERE/third_party/libbpf/include/uapi" -I"$L/include")
  gcc "${CF[@]}" -o "$W/drv_go" "$HERE/test/shim/spinel_diff.c" "$O/libspinelbpf_test.a" -lpthread || exit 1
  # shim の側は試験の caps (kind 1 — spinel の試験 archive の denyCaps と同じ) の build
  gcc "${CF[@]}" -DBML_TEST_CAPS -o "$W/drv_shim" "$HERE/test/shim/spinel_diff.c" $(find "$HERE/shim/spinel" -name '*.c' | LC_ALL=C sort) \
    $("$HERE/scripts/srcs.sh" src) "$L/lib/libbpf.a" "$L/lib/libelf.a" "$L/lib/libz.a" -lpthread || exit 1
  gcc "${CF[@]}" -o "$W/elf_maps" "$HERE/test/shim/elf_maps.c" "$L/lib/libbml.a" "$L/lib/libbpf.a" "$L/lib/libelf.a" "$L/lib/libz.a" || exit 1
  echo "spinel-diff: build ok ($(cut -c1-12 "$O/commit"))"
}

# 宣言の JSON (maps.json の要素の形 — flags は 0 でなければ)
decl() { # name kind key value max flags
  if [ "$6" = 0 ]; then printf '{"name":"%s","kind":"%s","key":"%s","value":"%s","max_entries":%s}' "$1" "$2" "$3" "$4" "$5"
  else printf '{"name":"%s","kind":"%s","key":"%s","value":"%s","max_entries":%s,"flags":%s}' "$1" "$2" "$3" "$4" "$5" "$6"; fi
}

# 1 つの ELF の操作の列 (ops) と名指しの差 (diffs: 番号 → 名前)
gen_one() { # ELF maps.json|- 出力の dir
  local elf=$1 mj=$2 d=$3
  mkdir -p "$d"
  if ! "$W/elf_maps" "$elf" > "$d/rows"; then # requirements を読めない ELF — load の段だけ
    printf '{"maps":[]}' > "$d/maps.json"; : > "$d/diffs"
    printf 'load\t%s\t%s\t%s\t0\nclose\n' "$elf" 0000000000000000000000000000000000000000000000000000000000000000 "$d/maps.json" > "$d/ops"
    return
  fi
  local sha; sha=$(awk -F'\t' '$1=="sha"{print $2}' "$d/rows")
  if [ "$mj" = - ]; then
    { printf '{"maps":['; awk -F'\t' '$1=="map"' "$d/rows" | while IFS=$'\t' read -r _ n k ke va mx fl _ _; do decl "$n" "$k" "$ke" "$va" "$mx" "$fl"; echo; done | paste -sd, ; printf ']}'; } > "$d/maps.json"
  else cp "$mj" "$d/maps.json"; fi
  printf '{}' > "$d/empty.json"
  local i=0 ops="$d/ops" df="$d/diffs"
  : > "$ops"; : > "$df"
  op() { i=$((i + 1)); printf '%s\n' "$*" | sed 's/ /\t/g' >> "$ops"; }
  named() { echo "$i $1" >> "$df"; }
  op load "$elf" 0000000000000000000000000000000000000000000000000000000000000000 "$d/maps.json" 0
  op load "$elf" "$sha" "$d/empty.json" 0
  op load "$elf" "$sha" "$d/maps.json" 1
  op load "$elf" "$sha" "$d/maps.json" 7
  op load "$elf" "$sha" "$d/maps.json" 0
  op load "$elf" "$sha" "$d/maps.json" 0
  op unmet
  op possible
  local rb="" rsz=0 first_arr="" n k ke va mx fl ks vs pc_ops=()
  while IFS=$'\t' read -r _ n k ke va mx fl ks vs; do
    local D; D=$(decl "$n" "$k" "$ke" "$va" "$mx" "$fl")
    local DX; DX=$(decl "$n" "$k" "$ke" "$va" "$((mx + 1))" "$fl")
    case "$k" in
      array)
        [ -n "$first_arr" ] || first_arr=$n
        if [ "${va#record:}" = "$va" ]; then
          op get "$D" 0; op put "$D" 0 42; op get "$D" 0; op put "$D" 0 -1; op put "$D" 0 -9223372036854775808; op put "$D" 0 4294967296
          op get "$D" "$mx"; op get "$D" -1; op get "$D" 4294967296; op getb "$D" 0 8; op get "$DX" 0
        else
          op getb "$D" 0 "$vs"; op putb "$D" 0 "$vs" 5; op getb "$D" 0 "$vs"; op putb "$D" 0 "$vs" bad; op putb "$D" 0 "$((vs + 1))" 5
          op getb "$D" 0 0; op getb "$DX" 0 "$vs"; op get "$D" 0
        fi ;;
      percpu_array|percpu_hash) # E007 H6 (spinel P009) — n は driver が possible CPU の数から
        local DK; DK=$(decl "$n" array "$ke" "$va" "$mx" "$fl")
        local kz=z; [ "$k" = percpu_hash ] && kz=1
        [ "$k" = percpu_hash ] && op pget "$D" "$ks" "$vs" 1 0
        op pput "$D" "$ks" "$vs" "$kz" 5 0; op pget "$D" "$ks" "$vs" "$kz" 0; op pget "$D" "$ks" "$vs" "$kz" 1; op pput "$D" "$ks" "$vs" "$kz" 5 -1
        op pput "$D" "$ks" "$vs" "$kz" bad 0; op pget "$D" "$((ks + 1))" "$vs" "$kz" 0; op pget "$DK" "$ks" "$vs" "$kz" 0; op pget "$DX" "$ks" "$vs" "$kz" 0
        pc_ops+=("$D	$ks	$vs	$kz")
        if [ "$k" = percpu_hash ]; then
          op pput "$D" "$ks" "$vs" 2 6 0; op hkeys "$D" "$ks" 100; op hget "$D" "$ks" "$vs" 1; op hdel "$D" "$ks" 1; op hdel "$D" "$ks" 1; op hkeys "$D" "$ks" 100
        fi ;;
      hash|lru_hash)
        op hget "$D" "$ks" "$vs" 1; op hput "$D" "$ks" "$vs" 1 2; op hget "$D" "$ks" "$vs" 1; op hput "$D" "$ks" "$vs" 2 3; op hput "$D" "$ks" "$vs" 3 4
        op hkeys "$D" "$ks" 100; op hkeys "$D" "$ks" 2; op hdel "$D" "$ks" 1; op hdel "$D" "$ks" 1; op hget "$D" "$((ks + 1))" "$vs" 1
        op hput "$D" "$ks" "$vs" 1 bad; op hget "$DX" "$ks" "$vs" 2; op hkeys "$D" "$ks" 100 ;;
      ringbuf)
        [ -n "$rb" ] || { rb=$n; rsz=$vs; } ;;
    esac
  done < <(awk -F'\t' '$1=="map"' "$d/rows")
  op ropen nope
  [ -z "$first_arr" ] || op ropen "$first_arr"
  if [ -n "$rb" ]; then op ropen "$rb"; op rread 10 "$rsz"; fi
  local p
  for p in $(awk -F'\t' '$1=="prog" && $3=="xdp"{print $2}' "$d/rows"); do
    op run "$p" 1
    op run "$p" 0; named "run0"
    op run "$p" -1; op run "$p" 4294967296
    op runp "$p" 42 udp; op runp "$p" 10 5; op runp "$p" 42 bad; op runp "$p" 70000 5
  done
  local pco # test run の後の per-CPU の読み (kind だけ — 走った CPU で slot が変わる)
  for pco in "${pc_ops[@]}"; do IFS=$'\t' read -r pd pk pv pz <<< "$pco"; op "~pget" "$pd" "$pk" "$pv" "$pz" 0; done
  if [ -n "$rb" ]; then
    op "~rread" 10 "$rsz"; op rread 10 "$((rsz + 1))"; op rclose; op rclose; named "rclose2"; op rread 0 "$rsz"
  fi
  p=$(awk -F'\t' '$1=="prog" && $3=="xdp"{print $2; exit}' "$d/rows")
  if [ -n "$p" ]; then op attach "$p" lo; op detach; op detach; named "detach2"; op attach "$p" nope0; fi
  op close; op close; named "close2"
  [ -z "$first_arr" ] || op get "$(awk -F'\t' -v n="$first_arr" '$1=="map" && $2==n{printf "{\"name\":\"%s\",\"kind\":\"%s\",\"key\":\"%s\",\"value\":\"%s\",\"max_entries\":%s}", $2,$3,$4,$5,$6}' "$d/rows")" 0
}

gen() {
  rm -rf "$W/cases"; mkdir -p "$W/cases"
  local e n=0
  for e in $(ls "$SP/examples" | LC_ALL=C sort); do
    gen_one "$SP/examples/$e/$e.bpf.o" "$SP/examples/$e/$e.maps.json" "$W/cases/ex_$e"; n=$((n + 1))
  done
  while read -r f; do
    gen_one "$SP/$f" - "$W/cases/r_$(echo "${f#docs/experiments/results/}" | tr / _ | sed 's/\.bpf\.o$//')"; n=$((n + 1))
  done < <(git -C "$SP" ls-files 'docs/experiments/results/*.bpf.o' | LC_ALL=C sort)
  echo "spinel-diff: gen $n ELF ($(ls "$W"/cases/*/skip 2>/dev/null | wc -l) は requirements を読めない)"
}

run() {
  local out=${1:?}
  [ "$(id -u)" = 0 ] || { echo "spinel-diff run: root で" >&2; exit 2; }
  rm -rf "$out"; mkdir -p "$out"
  local d
  for d in "$W"/cases/*/; do
    [ -f "$d/skip" ] && continue
    local c; c=$(basename "$d")
    unshare -n "$W/drv_go" < "$d/ops" > "$out/$c.go" 2> "$out/$c.go.err"
    unshare -n "$W/drv_shim" < "$d/ops" > "$out/$c.shim" 2> "$out/$c.shim.err"
  done
  chown -R "${SUDO_UID:-0}:${SUDO_GID:-0}" "$out"
}

compare() {
  local out=${1:?} same=0 named=0 bad=0 msg_same=0 msg_diff=0 total=0 cases=0 nna=0 b2=0
  : > "$out/diffs.txt"; : > "$out/msgs.tsv"
  local d
  for d in "$W"/cases/*/; do
    [ -f "$d/skip" ] && continue
    local c; c=$(basename "$d"); cases=$((cases + 1))
    # 事後の分類 (E007 の結果 — 予測に無かった): Go は load し、shim は guard の btf_dropped (kernel が BTF を拒み libbpf が BTF を捨てる — B2) で
    # 止める ELF。C が厳しい側の既知の差 — 以後の操作は連鎖するので数えず、ELF を別に数える
    if awk -F'\t' '$1==5 && $2=="load"' "$out/$c.go" | grep 'kind=0' > /dev/null && # E050: grep -q は SIGPIPE で外れる
       awk -F'\t' '$1==5 && $2=="load"' "$out/$c.shim" | grep '(btf_dropped)' > /dev/null; then
      b2=$((b2 + 1)); echo "B2 $c" >> "$out/diffs.txt"; continue
    fi
    # 番号・操作・kind・value・bytes で比べる。unmet の行はそのまま
    local r
    r=$(paste <(cut -f1-5 "$out/$c.go") <(cut -f1-5 "$out/$c.shim") | awk -F'\t' -v dfile="$d/diffs" -v c="$c" '
      BEGIN { while ((getline l < dfile) > 0) { split(l, a, " "); nm[a[1]] = a[2] } }
      { t++; g = $1"\t"$2"\t"$3"\t"$4"\t"$5; s = $6"\t"$7"\t"$8"\t"$9"\t"$10
        if (g == s) { if ($1 in nm) na++; else same++ }
        else if ($1 in nm) { n++; print "NAMED " c " " nm[$1] ": go[" g "] shim[" s "]" > "/dev/stderr" }
        else { bad++; print "DIFF " c ": go[" g "] shim[" s "]" > "/dev/stderr" } }
      END { print t+0, same+0, n+0, bad+0, na+0 }' 2>> "$out/diffs.txt")
    set -- $r
    total=$((total + $1)); same=$((same + $2)); named=$((named + $3)); bad=$((bad + $4)); nna=$((nna + $5))
    [ "$(wc -l < "$out/$c.go")" = "$(wc -l < "$out/$c.shim")" ] || { echo "LINES $c" >> "$out/diffs.txt"; bad=$((bad + 1)); }
    # 同じ kind の文の比べ
    paste "$out/$c.go" "$out/$c.shim" | awk -F'\t' -v c="$c" '$3 == $9 && $2 != "unmet" { if ($6 == $12) s++; else { d++; print c "\t" $2 "\t" $3 "\t" $6 "\t" $12 } } END { print "#\t" s+0 "\t" d+0 }' >> "$out/msgs.tsv"
  done
  msg_same=$(awk -F'\t' '$1=="#"{s+=$2} END{print s+0}' "$out/msgs.tsv"); msg_diff=$(awk -F'\t' '$1=="#"{s+=$3} END{print s+0}' "$out/msgs.tsv")
  echo "spinel-diff: ELF $cases・操作 $total — 同じ $same・名指しの差 $named (名指しの操作で同じ — load の失敗の後等 $nna)・名指しの外の差 $bad・shim の guard が btf_dropped で止めた ELF (事後の分類) $b2。同じ kind の文: 同じ $msg_same・違う $msg_diff"
  awk '/^NAMED/{split($0,a,":"); split(a[1],b," "); k[b[3]]++} END{for (x in k) print "  名指し " x ": " k[x]}' "$out/diffs.txt" | sort
  [ "$bad" = 0 ]
}

case "${1:-}" in
  build) build ;;
  gen) gen ;;
  run) run "${2:-}" ;;
  compare) compare "${2:-}" ;;
  *) echo "spinel-diff: build | gen | run <出力> | compare <出力>" >&2; exit 2 ;;
esac
