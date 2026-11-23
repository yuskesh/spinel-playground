#!/usr/bin/env bash
# E063 gates -- the wasm32 module under node (V8), its traps, and its
# rejections. Ported from spinel-llvm 463d49dd
# docs/experiments/results/E063/run_gates.sh. build.sh first.
#
# Not run here: the join of node's results against the host build and E040's
# recorded M33 results (e063_gates.rb) -- an oracle; see oracle/. What stays:
# node runs every case of the table on BOTH the bare module and the wasip1
# reactor link and the two agree byte for byte (our module, linked two ways --
# not another implementation), the trap probe, and the rejection table.
#
# Writes, in $RES: cases.json, node.tsv, ran.tsv, trap.tsv, reject.tsv.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
need_wasm
PROFILE=$FSDIR/profiles/wasm32-worker.yaml
mkdir -p "$RES"

# The case table: E040's CASES, with the types taken from the generated header.
ruby "$HERE/mkcases_wasm.rb" "$OUT/gen/spinel_freestanding.h" > "$OUT/gen/cases.json"
cp "$OUT/gen/cases.json" "$RES/cases.json"
ncases=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).size' "$OUT/gen/cases.json")
echo "cases: $ncases (from E040's table, types from the generated header)"

echo "== node (V8) =="
"$NODE" "$HERE/run_node.mjs" "$OUT/gen/kern.wasm" "$OUT/gen/cases.json" > "$RES/node.tsv"
"$NODE" "$HERE/run_node.mjs" "$OUT/gen/kern.reactor.wasm" "$OUT/gen/cases.json" \
    > "$OUT/node.reactor.tsv"
rows=$(tail -n +2 "$RES/node.tsv" | sed '/^$/d' | wc -l | tr -d ' ')  # node.tsv starts with a header row
{
  printf 'check\tverdict\tnote\n'
  [ "$rows" = "$ncases" ] && v=PASS || v=FAIL
  printf 'node_ran_every_case\t%s\t%s of %s cases printed\n' "$v" "$rows" "$ncases"
  cmp -s "$RES/node.tsv" "$OUT/node.reactor.tsv" && v=PASS || v=FAIL
  printf 'bare_equals_reactor\t%s\tthe bare module and the wasip1 reactor link give byte-identical results\n' "$v"
} > "$RES/ran.tsv"
cat "$RES/ran.tsv"

"$NODE" "$HERE/trap_probe.mjs" "$OUT/gen/kern.wasm" > "$RES/trap.tsv"
cat "$RES/trap.tsv"

# --- rejections (the profile is not a way around stage 1 or D-2) ------------
echo "== rejections =="
REJ=$OUT/rej; fs_fresh_workdir "$REJ"; mkdir -p "$REJ/spinel"
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
      "$what: $(grep -v 'pre-T5 format' "$err" | grep -m1 -o 'spinel-mlirgen: .*' | cut -c1-160)"
  fi
}
{
printf 'id\tverdict\texpected\tnote\n'
cat > "$REJ/r1_string.rb" <<'RB'
require_relative "spinel/freestanding"
freestanding_def :greet, params: [:i32], returns: :i32
def greet(n)
  s = "n=" + n.to_s
  s.length
end
RB
try_gen r1_string "$PROFILE" REFUSE "a String in a freestanding body (stage 1)"
cat > "$REJ/r2_array.rb" <<'RB'
require_relative "spinel/freestanding"
freestanding_def :total, params: [:i32], returns: :i32
def total(n)
  xs = [1, 2, 3]
  xs.sum + n
end
RB
try_gen r2_array "$PROFILE" REFUSE "an Array literal in a freestanding body (stage 1)"
sed 's/^  overflow: trap$/  overflow: raise/' "$PROFILE" > "$REJ/raise.yaml"
cat > "$REJ/r3_raise.rb" <<'RB'
require_relative "spinel/freestanding"
freestanding_def :add, params: [:i32, :i32], returns: :i32
def add(a, b)
  a + b
end
RB
try_gen r3_raise "$REJ/raise.yaml" REFUSE "profile: overflow: raise on a wasm32 profile (D-2)"
cat > "$REJ/c1_ok.rb" <<'RB'
require_relative "spinel/freestanding"
freestanding_def :add, params: [:i32, :i32], returns: :i32
def add(a, b)
  a + b
end
RB
try_gen c1_ok "$PROFILE" ACCEPT "control: the same declaration, unmodified profile"
gate() {   # $1 = id, $2 = expected, $3 = note, rest = flags; GATE_OBJ= another object
  local id=$1 want=$2 note=$3; shift 3
  if "$UNDEF" --undef --profile "$PROFILE" "$@" \
       "${GATE_OBJ:-$OUT/gen/kern.o}" > "$REJ/$id.out" 2>&1; then
    emit "$id" "ALLOW-ALL" "$want" "$note"
  else
    emit "$id" "DENY" "$want" \
      "$note: $(grep -m1 '^DENY' "$REJ/$id.out" | cut -f3 | tr '\n' ' ')"
  fi
}
# The 32-bit kernel needs no compiler-rt helper (decision 0019, revised
# 2026-10-21), so the helper is planted: a 128-bit multiply, which clang lowers
# to __multi3 on wasm32, as the i64 body's checked multiply did.
printf '__int128 m(__int128 a, __int128 b){ return a * b; }\n' > "$REJ/multi3.c"
"$CLANG" --target=wasm32-unknown-unknown -O2 -ffreestanding -fno-builtin \
    -c "$REJ/multi3.c" -o "$REJ/multi3.o" >/dev/null 2>&1
GATE_OBJ=$REJ/multi3.o gate g1_rt_deny DENY \
                            "gate: compiler_rt=deny refuses __multi3 (a planted 128-bit *)" \
                            --compiler-rt deny
GATE_OBJ=$REJ/multi3.o gate g1_rt_allow ALLOW-ALL \
                            "control: the same object under the profile as shipped"
# The 32-bit kernel uses no stack and imports no __stack_pointer; the planted
# object does, and g1_rt_allow is its control under the wasm32 profile.
GATE_OBJ=$REJ/multi3.o gate g2_wrong_tgt DENY "gate: told the object is RISC-V, __stack_pointer is unknown again" \
                            --triple riscv32-none-elf
gate g3_default   ALLOW-ALL "control: the profile as shipped"
} > "$RES/reject.tsv"
cat "$RES/reject.tsv"

bad=0
grep -q 'FAIL' "$RES/ran.tsv" && { echo "ran.tsv has failures" >&2; bad=1; }
grep -q '^FAIL' "$RES/trap.tsv" && { echo "trap.tsv has failures" >&2; bad=1; }
awk -F'\t' 'NR>1 && $2!=$3' "$RES/reject.tsv" | grep -q . && { echo "reject.tsv has rows whose verdict is not the expected one" >&2; bad=1; }
[ "$bad" = 0 ] || exit 1
echo "run_gates: done"
