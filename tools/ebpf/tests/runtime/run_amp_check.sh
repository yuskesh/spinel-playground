#!/usr/bin/env bash
#
# run_amp_check.sh — P007 S6: amp-m7 配布前 bytecode checker の positive/negative control。
#
# positive: amp codegen が出す probe (blink/heartbeat/phc) は checker を通る。
# negative: Linux helper 入り probe (amp preamble に無い bpf_* を呼ぶ) と、
#           後方分岐 (ループ) を持つ bytecode は REJECT される。
#           [P010 U2] さらに: probe のスタックフレーム外への store、atomic (BPF_ATOMIC)、
#           および checker が解釈できない命令 — いずれも「既定 allow」だった頃は
#           通っていた形。静的コストの算出と上限拒否も併せて検証する。
# = 「未検証の任意 bytecode を M7 が実行する」class を配布前に潰す実証。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

CC="${CC:-clang}"
SPINEL_DIR="${SPINEL_DIR:-$REPO_ROOT/third_party/spinel}"
ICC="$REPO_ROOT/build/codegen_c/spinel-ebpf-cc"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

echo "[s6] building amp_check"
"$CC" -O2 -Wall -Wextra -Werror -I "$REPO_ROOT/include" src/runtime/amp/amp_check.c -o "$TMP/amp_check"

amp_bpf() {   # $1 = ruby probe -> $2 = .bpf.o
  SPNL_AMP_M7=1 "$ICC" "$1" amp 2>/dev/null > "$TMP/p.bpf.c"
  clang -O2 -target bpf -c "$TMP/p.bpf.c" -o "$2"
}

echo "[s6] POSITIVE: amp probes must pass the checker"
for rb in examples/observability/amp/blink.rb examples/observability/amp/heartbeat.rb examples/observability/amp/phc_delta.rb; do
  amp_bpf "$rb" "$TMP/ok.bpf.o"
  if "$TMP/amp_check" "$TMP/ok.bpf.o" 2>"$TMP/e"; then echo "  ok: $(basename "$rb")"; else echo "  FAIL(rejected): $rb -> $(cat "$TMP/e")"; fail=1; fi
done

echo "[s6] NEGATIVE 1: disallowed helper id (a bpf_* the amp runtime never provides) must be REJECTED"
# A hand-crafted probe that calls helper id 6 (not in the amp allowlist {1,2}).
cat > "$TMP/bad.c" <<'C'
static unsigned long long (*bad_helper)(unsigned long long) = (void *)6;
int f(void *ctx){ (void)ctx; return (int)bad_helper(0); }
C
clang -O2 -target bpf -c "$TMP/bad.c" -o "$TMP/bad.bpf.o"
if "$TMP/amp_check" "$TMP/bad.bpf.o" 2>"$TMP/e"; then echo "  FAIL(passed a disallowed-helper prog): $(cat "$TMP/e")"; fail=1
else echo "  ok: rejected -> $(grep -o 'disallowed helper[^)]*)' "$TMP/e" || cat "$TMP/e")"; fi

echo "[s6] NEGATIVE 2: back-edge (loop) bytecode must be REJECTED"
cat > "$TMP/loop.c" <<'C'
int f(void *ctx){ (void)ctx; volatile int i=0; int s=0; while(i<10){ s+=i; i++; } return s; }
C
clang -O2 -target bpf -c "$TMP/loop.c" -o "$TMP/loop.bpf.o"
if "$TMP/amp_check" "$TMP/loop.bpf.o" 2>"$TMP/e"; then echo "  FAIL(passed a looping prog): $(cat "$TMP/e")"; fail=1
else echo "  ok: rejected -> $(grep -o 'backward branch[^)]*)' "$TMP/e" || cat "$TMP/e")"; fi

echo "[s6] NEGATIVE 3 (P008 S4): out-of-ABI memory store must be REJECTED (range check)"
# A hand-crafted probe that writes to a fixed address OUTSIDE the ivar carveout
# (0x20000000 = DTCM base, not in [AMP_IVARS_BASE, +AMP_IVARS_SIZE)). A malicious
# blob "writes to memory via a different immediate" — the range check must catch it.
cat > "$TMP/oob.c" <<'C'
int f(void *ctx){ (void)ctx; *(volatile unsigned int *)0x20000000u = 5u; return 0; }
C
clang -O2 -target bpf -c "$TMP/oob.c" -o "$TMP/oob.bpf.o"
if "$TMP/amp_check" "$TMP/oob.bpf.o" 2>"$TMP/e"; then echo "  FAIL(passed an out-of-ABI store): $(cat "$TMP/e")"; fail=1
else echo "  ok: rejected -> $(grep -o 'outside the fixed ABI[^)]*)' "$TMP/e" || cat "$TMP/e")"; fi

echo "[s6] NEGATIVE 4 (P008 S4): store to the shared ring (0x88400000) must be REJECTED"
# The M7 must never let a probe scribble the A55-facing ring directly (LDDW path,
# bit31 set). spnl_emit goes through the amp_emit helper, never a raw ring write.
cat > "$TMP/ring.c" <<'C'
int f(void *ctx){ (void)ctx; *(volatile unsigned int *)0x88400000ull = 7u; return 0; }
C
clang -O2 -target bpf -c "$TMP/ring.c" -o "$TMP/ring.bpf.o"
if "$TMP/amp_check" "$TMP/ring.bpf.o" 2>"$TMP/e"; then echo "  FAIL(passed a ring-write prog): $(cat "$TMP/e")"; fail=1
else echo "  ok: rejected -> $(grep -o 'outside the fixed ABI[^)]*)' "$TMP/e" || cat "$TMP/e")"; fi

echo "[u2] NEGATIVE 5 (P010 U2): a store outside the probe's own stack frame must be REJECTED"
# r10-relative accesses were allowed with no bound at all. The eBPF frame is 512
# bytes; on the M7 there is no verifier to enforce that and the AOT'd code runs on
# the real stack, so this lands in whatever the RTOS keeps below the probe.
cat > "$TMP/stk.c" <<'C'
int f(void *ctx){ volatile unsigned long long a[4]; (void)ctx;
  __asm__ volatile("r1 = 0x41\n\t*(u64 *)(r10 - 30000) = r1" ::: "r1");
  return (int)a[0]; }
C
clang -O2 -target bpf -c "$TMP/stk.c" -o "$TMP/stk.bpf.o"
if "$TMP/amp_check" "$TMP/stk.bpf.o" 2>"$TMP/e"; then echo "  FAIL(passed an out-of-frame store): $(cat "$TMP/e")"; fail=1
else echo "  ok: rejected -> $(grep -o 'outside the probe[^)]*)' "$TMP/e" || cat "$TMP/e")"; fi

echo "[u2] NEGATIVE 6 (P010 U2): an atomic RMW to an arbitrary address must be REJECTED"
# BPF_ATOMIC is addressing mode 0xc0, so it never matched the BPF_MEM range check
# and fell through to the permissive default: this exact program was accepted.
cat > "$TMP/atom.c" <<'C'
int f(void *ctx){ (void)ctx;
  __asm__ volatile("r1 = 0xdeadbeef\n\tr2 = 7\n\tlock *(u64 *)(r1 + 0) += r2" ::: "r1","r2");
  return 0; }
C
clang -O2 -target bpf -c "$TMP/atom.c" -o "$TMP/atom.bpf.o"
if "$TMP/amp_check" "$TMP/atom.bpf.o" 2>"$TMP/e"; then echo "  FAIL(passed an atomic to an arbitrary address): $(cat "$TMP/e")"; fail=1
else echo "  ok: rejected -> $(grep -o 'addressing mode[^(]*' "$TMP/e" || cat "$TMP/e")"; fi

echo "[u2] COST: the static cost is computed, and a declared ceiling is enforced"
amp_bpf examples/observability/amp/hb_hw.rb "$TMP/cost.bpf.o"
cost=$("$TMP/amp_check" --cost-only "$TMP/cost.bpf.o")
if [ -n "$cost" ] && [ "$cost" -gt 0 ] 2>/dev/null; then echo "  ok: hb_hw.rb = $cost cost units"
else echo "  FAIL(no cost computed): '$cost'"; fail=1; fi
if "$TMP/amp_check" --max-cost "$cost" "$TMP/cost.bpf.o" 2>"$TMP/e" >/dev/null; then echo "  ok: admitted at its own cost ($cost)"
else echo "  FAIL(rejected at its own cost): $(cat "$TMP/e")"; fail=1; fi
if "$TMP/amp_check" --max-cost "$((cost - 1))" "$TMP/cost.bpf.o" 2>"$TMP/e" >/dev/null; then
  echo "  FAIL(admitted above the ceiling)"; fail=1
else echo "  ok: rejected one unit under -> $(grep -o 'exceeds the declared[^(]*' "$TMP/e" || cat "$TMP/e")"; fi

if [ "$fail" -eq 0 ]; then echo "PASS: amp-m7 pre-distribution checker (positive + negative controls)"; else echo "FAIL"; exit 1; fi
