#!/bin/bash
# scripts/abi-target.sh — E006 の C ABI の契約の試験を 1 つの target (host か VM — scripts/run-in-vm.sh) で (root で、全て unshare -n の中 —
# xdp の attach は新しい netns の lo だけ): abi_case all (ASan + UBSan + 試験の caps)、T4 (strace が BPF_PROG_TEST_RUN をちょうど N 数える —
# 変異の build を変異無しで、LSan は ptrace の下で動かない)、T5 (変異 run.fake_eintr_at_3)。
#
#   sudo scripts/abi-target.sh <flow.bpf.o> <schema の sha256> <出力の親> <ASAN_TOOLS_DIR> <MUT_TOOLS_DIR> [<bg.bpf.o> <sha> <percpu.bpf.o> <sha>]
set -uo pipefail
ELF="${1:?}"; SHA="${2:?}"; PARENT="${3:?}"; TA="${4:?}"; TM="${5:?}"
# E007 の H4 (任意): bg の ELF と sha・per-CPU の fixture の ELF と sha — abi_more (ASan + UBSan)
BG="${6:-}"; BGS="${7:-}"; PC="${8:-}"; PCS="${9:-}"
# E006 の後半 (任意): globals の ELF (bpf-mlir kernel/globals/mlir/multi.mlir) と sha — abi_globals と G5 の strace
GL="${10:-}"; GLS="${11:-}"
[ "$(id -u)" = 0 ] || { echo "abi-target: root で走らせる" >&2; exit 2; }
export PATH="$PATH:/usr/sbin:/sbin"
K=$(uname -r); O="$PARENT/$K"
rm -rf "$O"; mkdir -p "$O"
N=20000
rc=0
unshare -n "$TA/abi_case" all "$ELF" "$SHA" > "$O/all.txt" 2>&1 || rc=1
# E006 の後半の追補: close と別の thread の呼び出しの競合の契約 (R1・R2・追補の 2 の R4 — ASan + UBSan)
for m in r1 r2 r3; do unshare -n "$TA/abi_race" "$m" "$ELF" "$SHA" >> "$O/all.txt" 2>&1 || rc=1; done
unshare -n strace -f -qq -e trace=bpf -o "$O/t4.strace" "$TM/abi_case" signals "$ELF" "$SHA" "$N" > "$O/t4.txt" 2>&1 || rc=1
runs=$(grep -c BPF_PROG_TEST_RUN "$O/t4.strace"); bad=$(grep BPF_PROG_TEST_RUN "$O/t4.strace" | grep -vc '= 0$')
echo "T4: strace の BPF_PROG_TEST_RUN $runs (0 でない戻り $bad) — $([ "$runs" = "$N" ] && [ "$bad" = 0 ] && echo ok || echo FAIL)" >> "$O/t4.txt"
[ "$runs" = "$N" ] && [ "$bad" = 0 ] || rc=1
rm -f "$O/t4.strace"
BML_MUTANT=run.fake_eintr_at_3 unshare -n "$TM/abi_case" eintr "$ELF" "$SHA" > "$O/t5.txt" 2>&1 || rc=1
: > "$O/more.txt"
[ -z "$BG" ] || unshare -n "$TA/abi_more" "$BG" "$BGS" "$PC" "$PCS" > "$O/more.txt" 2>&1 || rc=1
: > "$O/globals.txt"
if [ -n "$GL" ]; then
  unshare -n "$TA/abi_globals" all "$GL" "$GLS" > "$O/globals.txt" 2>&1 || rc=1
  unshare -n strace -f -qq -e trace=bpf -o "$O/g5.strace" "$TM/abi_globals" notset "$GL" "$GLS" >> "$O/globals.txt" 2>&1 || rc=1
  nb=$(wc -l < "$O/g5.strace"); rm -f "$O/g5.strace"
  echo "G5t: CONFIG_NOT_SET の load の bpf(2) の呼び出し $nb — $([ "$nb" = 0 ] && echo ok || echo FAIL)" >> "$O/globals.txt"; [ "$nb" = 0 ] || rc=1
fi
{ echo "kernel $(uname -a)"; cat "$O/all.txt" "$O/t4.txt"  "$O/t5.txt" "$O/more.txt" "$O/globals.txt" | grep -E ' — (ok|FAIL)$'; } > "$O/summary.txt"
grep -c ' — ok$' "$O/summary.txt" | sed "s/^/abi-target $K: ok /"
grep ' — FAIL$' "$O/summary.txt"
exit $rc
