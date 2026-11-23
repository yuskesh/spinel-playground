#!/bin/bash
# scripts/diff-kbtf.sh — kernel の BTF の reader (src/btf/kernel*) を cilium/ebpf v0.22 の btf と比べる (E004 の手順 2)。
#
#   scripts/diff-kbtf.sh [SEED] [N] [TOOLS_DIR]     # 既定 1 30 build/tools
#
# 1. この kernel の /sys/kernel/btf/vmlinux: 名前を持つ全ての型の TypeByName と書式・UnderlyingType・Sizeof・member・引数が byte で一致
# 2. 種 (test/btf/fixtures/kbtf_fixture.c の .BTF — flavor の名前・bitfield・decl / type tag・enum64 — と corpus の ELF の .BTF): 一致
# 3. 種の変異 (mutate -rawbtf) N 個ずつ: 一致、または名指しの既知の差 c_load_strict — C は load の時に全ての型を検めて止め
#    (fail closed)、Go は遅延の inflate で load を通す (問いが壊れた型に当たれば Go も誤り)。Go が load で止め C が通すのは失敗。件数も照合
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/diff-kbtf.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SEED="${1:-1}"
N="${2:-30}"
TOOLS="${3:-$HERE/build/tools}"
LLVM_PREFIX="${LLVM_PREFIX:-/opt/llvm-23.1.1}"
[ -x "$TOOLS/kbtf_case" ] || { echo "diff-kbtf: $TOOLS/kbtf_case が無い (build-tools.sh)" >&2; exit 1; }
export TMPDIR="$HERE/build/tmp"
W="$TMPDIR/diff-kbtf"
rm -rf "$W"
mkdir -p "$W/seeds" "$W/mut"
GO="${GO:-/usr/local/go/bin/go}"
# KBTF_ORACLE と MUTATE: host で build した oracle (VM の中 — Go の module の cache が無い — scripts/run-in-vm.sh)
if [ -n "${KBTF_ORACLE:-}" ] && [ -n "${MUTATE:-}" ]; then
  cp "$KBTF_ORACLE" "$W/kbtf-oracle"; cp "$MUTATE" "$W/mutate"
else
  (cd "$HERE/test/oracle" && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "$GO" build -o "$W/kbtf-oracle" ./cmd/kbtf-oracle &&
    GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "$GO" build -o "$W/mutate" ./cmd/mutate)
fi
O="$W/kbtf-oracle"

# 名前の問いに足す問い (無い名前・flavor・同じ名前の別の kind)
extra() {
  for k in Struct Union Func Typedef Enum Int Fwd Float Var Datasec; do
    for n in thing thing___v1 thing___v3 ___lead a___b a___b___c a ___x _ tagged bits fwd_only float int task_struct sk_buff; do
      echo "$k $n"
    done
  done
}

# 1. kernel
"$O" -names -kernel > "$W/k.q"
extra >> "$W/k.q"
"$O" -kernel "$W/k.q" > "$W/k.go"
"$TOOLS/kbtf_case" -kernel "$W/k.q" > "$W/k.c"
cmp -s "$W/k.go" "$W/k.c" || { echo "diff-kbtf: kernel の BTF で差" >&2; diff "$W/k.go" "$W/k.c" | head -20 >&2 || true; exit 1; }
[ "$(head -1 "$W/k.go")" != "load error" ] || { echo "diff-kbtf: kernel の BTF が読めない" >&2; exit 1; }
kq=$(wc -l < "$W/k.q")

# 2. 種
"$LLVM_PREFIX/bin/clang" -g -O2 --target=bpf -c "$HERE/test/btf/fixtures/kbtf_fixture.c" -o "$W/fx.o"
"$LLVM_PREFIX/bin/llvm-objcopy" --dump-section .BTF="$W/seeds/000.btf" "$W/fx.o" "$W/x.o"
i=1
for o in "$HERE"/third_party/bpf-mlir/conformance/requirements/{cases,maps}/*/object.bpf.o; do
  if "$LLVM_PREFIX/bin/llvm-objcopy" --dump-section .BTF="$W/seeds/$(printf '%03d' $i).btf" "$o" "$W/x.o" 2> /dev/null; then i=$((i + 1)); fi
done
seeds=$i
for s in "$W"/seeds/*.btf; do
  "$O" -names "$s" > "$s.q" 2> /dev/null || : # 読めない種 (corpus の壊れた BTF — E304 の case) は両方が load error を出すことを比べる
  extra >> "$s.q"
  "$O" "$s" "$s.q" > "$s.go"
  "$TOOLS/kbtf_case" "$s" "$s.q" > "$s.c"
  cmp -s "$s.go" "$s.c" || { echo "diff-kbtf: 種 $s で差" >&2; diff "$s.go" "$s.c" | head -20 >&2 || true; exit 1; }
done

# 3. 変異
"$W/mutate" -rawbtf -seed "$SEED" -n "$N" -out "$W/mut" "$W"/seeds/*.btf
total=0 same=0 strict=0 bad=0
: > "$W/bad.txt"
for f in "$W"/mut/*.txt; do
  total=$((total + 1))
  q="$W/seeds/$(basename "$f" | cut -c1-3).btf.q"
  "$O" "$f" "$q" > "$f.go" 2> /dev/null
  "$TOOLS/kbtf_case" "$f" "$q" > "$f.c" 2> "$f.c.err"
  if cmp -s "$f.go" "$f.c"; then same=$((same + 1)); continue; fi
  if [ "$(head -1 "$f.c")" = "load error" ] && [ "$(head -1 "$f.go")" != "load error" ]; then strict=$((strict + 1)); continue; fi
  echo "$f" >> "$W/bad.txt"
  bad=$((bad + 1))
done
echo "diff-kbtf: seed=$SEED kernel_queries=$kq seeds=$seeds inputs=$total same=$same c_load_strict=$strict bad=$bad"
[ "$total" -gt 0 ] && [ $((same + strict + bad)) -eq "$total" ] || { echo "diff-kbtf: 件数が合わない" >&2; exit 1; }
[ "$bad" -eq 0 ] || { echo "diff-kbtf: 差 — $W/bad.txt" >&2; head -5 "$W/bad.txt" >&2; exit 1; }
