#!/usr/bin/env bash
# E063 measurements.  build.sh first.
#
#   gates.tsv    the differential oracle: host (bin/spinel, C back end) vs wasm
#                (node/V8) vs the MCU answers E040 already recorded
#   trap.tsv     the three trap codes, and what a trap looks like on wasm
#   reject.tsv   the refusals: subset, profile and gate, all on wasm32
#   node.tsv     the raw wasm results
#   host.tsv     the raw host results
#
# NOTHING IS TIMED (the predecessor's verification rules).
set -uo pipefail
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/tools/oracle/gate" tests/freestanding/e063/oracle/run_gates.sh whole || exit 0

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../../../.." && pwd)
SCRATCH=${SCRATCH:-/tmp/spinel-llvm-scratch/session-a}
OUT=${OUT:-$SCRATCH/e063/work}
E040=$REPO/docs/experiments/results/E040
SPINEL=${SPINEL:-$REPO/vendor/spinel/bin/spinel}
MLIRGEN=${MLIRGEN:-$REPO/tools/mlir/spinel-mlirgen}
FSDIR=$REPO/tools/freestanding
PROFILE=$FSDIR/profiles/wasm32-worker.yaml

# --- 0. the case table -----------------------------------------------------
ruby "$HERE/mkcases_wasm.rb" "$HERE/spinel_freestanding.h" > "$OUT/gen/cases.json"
cp "$OUT/gen/cases.json" "$HERE/cases.json"
echo "cases: $(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).size' \
    "$OUT/gen/cases.json") (from E040's table, types from the generated header)"

# --- 1. the host oracle ----------------------------------------------------
# E040's host driver, built from E040's kernel file by E040's own script.  It is
# regenerated rather than copied so that the Ruby BODIES compiled by bin/spinel
# are provably the same text spinel-mlirgen compiled.  mkcases.rb's `--host`
# sub-command is make_host on its own (rather than the whole of mkcases.rb) so
# that nothing is written into results/E040/.
echo "== host oracle =="
ruby "$E040/mkcases.rb" --host "$E040/e040_kern.rb" "$OUT/host/e040_host.rb"
(cd "$OUT/host" && "$SPINEL" e040_host.rb -o e040_host) || exit 1
: > "$OUT/host.tsv"
n=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).size' "$OUT/gen/cases.json")
i=0
while [ "$i" -lt "$n" ]; do
  o=$(cd "$OUT/host" && ./e040_host "$i" 2>&1); rc=$?
  name=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))[Integer(ARGV[1])]["case"]' \
         "$OUT/gen/cases.json" "$i")
  if [ "$rc" -ne 0 ]; then
    printf '%s\traise:%s\n' "$name" "$(echo "$o" | head -1)" >> "$OUT/host.tsv"
  else
    echo "$o" | head -1 >> "$OUT/host.tsv"
  fi
  i=$((i + 1))
done
cp "$OUT/host.tsv" "$HERE/host.tsv"

# --- 2. the wasm side, under node -----------------------------------------
echo "== node (V8) =="
node "$HERE/run_node.mjs" "$HERE/kern.wasm" "$OUT/gen/cases.json" > "$HERE/node.tsv"
# The reactor variant has to answer identically -- if crt1-reactor.o changed an
# answer, the "the reactor contract is optional" claim would be false.
node "$HERE/run_node.mjs" "$OUT/gen/kern.reactor.wasm" "$OUT/gen/cases.json" \
    > "$OUT/node.reactor.tsv"
if cmp -s "$HERE/node.tsv" "$OUT/node.reactor.tsv"; then
  echo "bare vs wasip1-reactor: byte-identical results"
else
  echo "bare vs wasip1-reactor: DIFFER (see $OUT/node.reactor.tsv)"
fi

# --- 3. the join -----------------------------------------------------------
# Three columns of answers: the host (native, C back end, 64-bit Integer then
# bignum), wasm (this experiment) and the Cortex-M33 (E040's recorded QEMU
# output, read out of gates.tsv).  The MCU column is what makes this a
# THREE-way check: `same` means the same characters on all three.
{
printf 'idx\tcase\texpect\thost\twasm\tm33\tverdict\n'
ruby "$HERE/e063_gates.rb" "$OUT/gen/cases.json" "$OUT/host.tsv" "$HERE/node.tsv" \
    "$E040/gates.tsv"
} > "$HERE/gates.tsv"
awk -F'\t' 'NR>1{n[$7]++} END{for (k in n) printf "%s=%d ", k, n[k]; print ""}' "$HERE/gates.tsv"

# --- 4. the trap path ------------------------------------------------------
# On the MCU a trap was a k_panic() and the run stopped.  On wasm the hook is an
# IMPORT, so the host decides -- and the interesting question is what happens if
# the host tries to CONTINUE.  The generator puts `llvm.unreachable` after the
# call (E022's shape), so a returning hook must produce a wasm trap and never a
# wrong answer.  That is measured, not assumed.
node "$HERE/trap_probe.mjs" "$HERE/kern.wasm" > "$HERE/trap.tsv"
cat "$HERE/trap.tsv"

# --- 5. the refusals -------------------------------------------------------
# E018/E038/E040's discipline: the rejections are a TABLE, with controls mixed
# in, and every row is on THIS profile (wasm32-worker.yaml) -- a refusal that
# only happens on a Cortex-M would prove nothing about wasm.
echo "== rejections =="
REJ=$OUT/rej; rm -rf "$REJ"; mkdir -p "$REJ/spinel"
cp "$FSDIR/spinel/freestanding.rb" "$REJ/spinel/"

emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

try_gen() {   # $1 = id, $2 = profile, $3 = expected verdict, $4 = what it probes
  local id=$1 prof=$2 want=$3 what=$4
  local err="$REJ/$id.err"
  if (cd "$REJ" && "$MLIRGEN" "$id.rb" --freestanding --profile "$prof" \
        -o "$id.o" >/dev/null 2>"$err"); then
    emit "$id" "ACCEPT" "$want" "$what: (no message)"
  else
    emit "$id" "REFUSE" "$want" \
      "$what: $(grep -m1 -o 'spinel-mlirgen: .*' "$err" | cut -c1-160)"
  fi
}

{
printf 'id\tverdict\texpected\tnote\n'

# R1: a construct outside the allocation-free subset (stage 1, syntactic).
cat > "$REJ/r1_string.rb" <<'RB'
require_relative "spinel/freestanding"
freestanding_def :greet, params: [:i32], returns: :i32
def greet(n)
  s = "n=" + n.to_s
  s.length
end
RB
try_gen r1_string "$PROFILE" REFUSE "a String in a freestanding body (stage 1)"

# R2: an Array, i.e. the other half of "the freestanding subset is the
# allocation-free subset" -- and the one E040's control d02_multi shows is NOT
# refused when it is the multiple-assignment idiom.
cat > "$REJ/r2_array.rb" <<'RB'
require_relative "spinel/freestanding"
freestanding_def :total, params: [:i32], returns: :i32
def total(n)
  xs = [1, 2, 3]
  xs.sum + n
end
RB
try_gen r2_array "$PROFILE" REFUSE "an Array literal in a freestanding body (stage 1)"

# R3: the profile itself.  `overflow: raise` needs longjmp and the string heap;
# on wasm those are not even theoretically available in a module with no
# runtime, and the refusal is decision record D-2 (not a wasm fact).
sed 's/^  overflow: trap$/  overflow: raise/' "$PROFILE" > "$REJ/raise.yaml"
cp "$REJ/r1_string.rb" "$REJ/r3_raise.rb" 2>/dev/null
cat > "$REJ/r3_raise.rb" <<'RB'
require_relative "spinel/freestanding"
freestanding_def :add, params: [:i32, :i32], returns: :i32
def add(a, b)
  a + b
end
RB
try_gen r3_raise "$REJ/raise.yaml" REFUSE "profile: overflow: raise on a wasm32 profile (D-2)"

# --- controls: the same machinery must ACCEPT these -----------------------
cat > "$REJ/c1_ok.rb" <<'RB'
require_relative "spinel/freestanding"
freestanding_def :add, params: [:i32, :i32], returns: :i32
def add(a, b)
  a + b
end
RB
try_gen c1_ok "$PROFILE" ACCEPT "control: the same declaration, unmodified profile"

# --- the gate, run by hand against doctored profiles ----------------------
# Same object, different allowances: this is what makes the wasm rules
# load-bearing rather than decorative (undef-check.py's --libc/--compiler-rt
# flags exist for exactly this experiment shape -- E040 s8).
gate() {   # $1 = id, $2 = expected, $3 = note, rest = flags
  local id=$1 want=$2 note=$3; shift 3
  # The native standalone undef gate (its command line is the same as the
  # frozen Python tool's).
  if "${UNDEF:-$REPO/tools/mlir/native/build/bin/spinel-fs-check}" --undef \
       --profile "$PROFILE" "$@" \
       "$OUT/gen/kern.o" > "$REJ/$id.out" 2>&1; then
    emit "$id" "ALLOW-ALL" "$want" "$note"
  else
    emit "$id" "DENY" "$want" \
      "$note: $(grep -m1 '^DENY' "$REJ/$id.out" | cut -f3 | tr '\n' ' ')"
  fi
}
gate g1_rt_deny   DENY      "gate: compiler_rt=deny refuses __multi3 (the i64 * helper)" \
                            --compiler-rt deny
gate g2_wrong_tgt DENY      "gate: told the object is RISC-V, __stack_pointer is unknown again" \
                            --triple riscv32-none-elf
gate g3_default   ALLOW-ALL "control: the profile as shipped"
} > "$HERE/reject.tsv"
cat "$HERE/reject.tsv"
bad=$(awk -F'\t' 'NR>1 && $2!=$3 {n++} END{print n+0}' "$HERE/reject.tsv")
echo "reject.tsv: $bad row(s) disagreed with the expectation"

echo
echo "run_gates: done."
