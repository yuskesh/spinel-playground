#!/usr/bin/env bash
# E077 static rejection table -- the COMPILE-TIME half of the buffer/float
# contract.  The run-time half is trap_probe.mjs (a broken CALLER) and
# gates.tsv (a broken KERNEL, caught by the bounds check).
#
# THE CONTROL GROUP IS IN THE SAME TABLE (E038's rule, kept from E040).  A tool
# that refuses everything passes a table of refusals; it does not pass a table
# that also contains the things it must ACCEPT.
#
#   reject.tsv   the generator: declarations, directions, slots, type face
set -uo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
mkdir -p "$RES"
W=$OUT/reject
PROF=$FSDIR/profiles/cortex-m33-zephyr.yaml

fs_fresh_workdir "$W"; mkdir -p "$W/spinel"
cp "$FSDIR/spinel/freestanding.rb" "$W/spinel/"

pass=0; fail=0
emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RES/reject.tsv"; }

# kase <id> <kind: reject|control> [--flags...] -- <ruby...>
kase() {
  local id=$1 kind=$2; shift 2
  local flags=()
  while [ "$1" != "--" ]; do flags+=("$1"); shift; done
  shift
  local f="$W/$id.rb"
  printf '%s\n' "$@" > "$f"
  local out rc
  # `.o`, not `.mlir`: a control has to survive the WHOLE pipeline, including
  # the undefined-symbol gate that --emit obj runs at the end.
  out=$(cd "$W" && "$MLIRGEN" "$id.rb" --freestanding --profile "$PROF" \
        "${flags[@]}" -o "$W/$id.o" 2>&1)
  rc=$?
  local first
  first=$(printf '%s' "$out" | head -2 | tr '\n' ' ' | cut -c1-190)
  if [ "$kind" = reject ]; then
    if [ "$rc" -ne 0 ]; then emit "$id" "$kind" REJECTED "$first"; pass=$((pass+1))
    else emit "$id" "$kind" "ACCEPTED (should not be)" "$first"; fail=$((fail+1)); fi
  else
    if [ "$rc" -eq 0 ]; then emit "$id" "$kind" ACCEPTED "ok"; pass=$((pass+1))
    else emit "$id" "$kind" "REJECTED (should not be)" "$first"; fail=$((fail+1)); fi
  fi
}

# exports <id> <symbol>: a control row of its own, that <id>.o defines <symbol>
exports() {
  if "$NM" --defined-only --extern-only "$W/$1.o" 2>/dev/null | awk '{print $3}' | grep -qx "$2"; then
    emit "$1.exports" control ACCEPTED "defines $2"; pass=$((pass+1))
  else
    emit "$1.exports" control "REJECTED (should not be)" "$1.o does not define $2"; fail=$((fail+1))
  fi
}

REQ='require_relative "spinel/freestanding"'
printf 'id\tkind\tverdict\tdetail\n' > "$RES/reject.tsv"

# ---------------------------------------------------------------------------
# A. the buffer DECLARATION
# ---------------------------------------------------------------------------
kase a01_badelem   reject -- "$REQ" \
  'freestanding_def :k, params: [[:i7_buf, :in], :len], returns: :i32' \
  'def k(b, n)' '  b[0] + n' 'end'
kase a02_baddir    reject -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :sideways], :len], returns: :i32' \
  'def k(b, n)' '  b[0] + n' 'end'
kase a03_arity1    reject -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in]], returns: :i32' \
  'def k(b, n)' '  b[0] + n' 'end'
kase a04_len_alone reject -- "$REQ" \
  'freestanding_def :k, params: [:len, :i32], returns: :i32' \
  'def k(n, m)' '  n + m' 'end'
kase a05_len_first reject -- "$REQ" \
  'freestanding_def :k, params: [:i32, :len], returns: :i32' \
  'def k(n, m)' '  n + m' 'end'
kase a06_retbuf    reject -- "$REQ" \
  'freestanding_def :k, params: [:i32], returns: [:i32_buf, :out]' \
  'def k(n)' '  n' 'end'
kase a07_buf3      reject -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in, :extra], :len], returns: :i32' \
  'def k(b, n)' '  b[0] + n' 'end'
kase a08_bounds_bad reject -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in], :len], returns: :i32, bounds: :off' \
  'def k(b, n)' '  b[0] + n' 'end'
kase a09_bounds_nobuf reject -- "$REQ" \
  'freestanding_def :k, params: [:i32], returns: :i32, bounds: :unchecked' \
  'def k(n)' '  n' 'end'
kase a10_nolen     reject -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in], :i32], returns: :i32' \
  'def k(b, n)' '  b[0] + n' 'end'

# ---------------------------------------------------------------------------
# B. the DIRECTION contract -- the half of D-5 that is decided in the text
# ---------------------------------------------------------------------------
kase b01_write_in  reject -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in], :len], returns: :i32' \
  'def k(b, n)' '  b[0] = 1' '  n' 'end'
kase b02_read_out  reject -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :out], :len], returns: :i32' \
  'def k(b, n)' '  b[0] + n' 'end'
kase b03_reassign_buf reject -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in], :len], returns: :i32' \
  'def k(b, n)' '  b = b' '  n' 'end'
kase b04_reassign_len reject -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in], :len], returns: :i32' \
  'def k(b, n)' '  n = 99' '  b[0]' 'end'
# Decision 0044 lifts what these two cases were written to refuse: a helper now
# takes a buffer its caller lends it, as the address and the length the caller
# holds, so both are controls. Each must build through the undefined-symbol
# gate and export the entry; the values of lent buffers are run by
# tests/fs-helper-buffers. The limits that remain (a lent buffer stored,
# returned, written through when lent from :in, or given two element types)
# are refused there, each by its words.
kase b05_pass_buf  control -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in], :len], returns: :i32' \
  'def k(b, n)' '  h(b, n)' 'end' \
  'def h(b, n)' '  n' 'end'
exports b05_pass_buf spinel_k
kase b05b_callee_index control -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in], :len], returns: :i32' \
  'def k(b, n)' '  h(b, n)' 'end' \
  'def h(b, n)' '  b[0] + n' 'end'
exports b05b_callee_index spinel_k
kase b06_buf_as_value reject -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in], :len], returns: :i32' \
  'def k(b, n)' '  b + n' 'end'
kase b07_index_local reject -- "$REQ" \
  'freestanding_def :k, params: [:i32], returns: :i32' \
  'def k(n)' '  n[0]' 'end'

# ---------------------------------------------------------------------------
# C. floats and slots
# ---------------------------------------------------------------------------
kase c01_fmod      reject -- "$REQ" \
  'freestanding_def :k, params: [:f64, :f64], returns: :f64' \
  'def k(a, b)' '  a % b' 'end'
kase c02_ret_kind  reject -- "$REQ" \
  'freestanding_def :k, params: [:i32], returns: :f32' \
  'def k(n)' '  n + 1' 'end'
kase c03_int_ret_float reject -- "$REQ" \
  'freestanding_def :k, params: [:f64], returns: :i32' \
  'def k(x)' '  x * 2.0' 'end'
kase c04_slot_mix  reject -- "$REQ" \
  'freestanding_def :k, params: [:i32], returns: :i32' \
  'def k(n)' '  s = 0' '  s = 1.5' '  n' 'end'
kase c05_arm_mix   reject -- "$REQ" \
  'freestanding_def :k, params: [:i32], returns: :f64' \
  'def k(n)' '  if n > 0' '    1.0' '  else' '    2' '  end' 'end'
kase c06_math      reject -- "$REQ" \
  'freestanding_def :k, params: [:f64], returns: :f64' \
  'def k(x)' '  Math.sqrt(x)' 'end'

# ---------------------------------------------------------------------------
# D. the TYPE FACE (E077's second half: P001 increment 4)
# ---------------------------------------------------------------------------
kase d01_emit_types_buf reject --types-from emit-types -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in], :len], returns: :i32' \
  'def k(b, n)' '  b[0] + n' 'end'
kase d02_emit_types_f32 reject --types-from emit-types -- "$REQ" \
  'freestanding_def :k, params: [:f32], returns: :f32' \
  'def k(x)' '  x * 2.0' 'end'

# ---------------------------------------------------------------------------
# E. CONTROLS -- every one of these must build
# ---------------------------------------------------------------------------
kase e01_read      control -- "$REQ" \
  'freestanding_def :k, params: [[:u8_buf, :in], :len], returns: :i32' \
  'def k(b, n)' '  s = 0' '  i = 0' '  while i < n' '    s = s + b[i]' '    i += 1' '  end' '  s' 'end'
kase e02_write     control -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :out], :len], returns: :i32' \
  'def k(b, n)' '  i = 0' '  while i < n' '    b[i] = i' '    i += 1' '  end' '  n' 'end'
kase e03_inout     control -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :inout], :len], returns: :i32' \
  'def k(b, n)' '  i = 0' '  while i < n' '    b[i] = b[i] + 1' '    i += 1' '  end' '  n' 'end'
kase e04_two_bufs  control -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in], [:i32_buf, :out], :len], returns: :i32' \
  'def k(a, b, n)' '  i = 0' '  while i < n' '    b[i] = a[i]' '    i += 1' '  end' '  n' 'end'
kase e05_two_runs  control -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in], :len, [:u8_buf, :out], :len], returns: :i32' \
  'def k(a, n, b, m)' '  b[0] = a[0]' '  n + m' 'end'
kase e06_unchecked control -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in], :len], returns: :i32, bounds: :unchecked' \
  'def k(b, n)' '  b[0] + n' 'end'
kase e07_f32       control -- "$REQ" \
  'freestanding_def :k, params: [:f32, :f32], returns: :f32' \
  'def k(a, b)' '  a * b + 1.0' 'end'
kase e08_f64buf    control -- "$REQ" \
  'freestanding_def :k, params: [[:f64_buf, :in], :len], returns: :f64' \
  'def k(a, n)' '  s = 0.0' '  i = 0' '  while i < n' '    s = s + a[i]' '    i += 1' '  end' '  s' 'end'
kase e09_mixed     control -- "$REQ" \
  'freestanding_def :k, params: [[:f32_buf, :in], :len, :f64], returns: :f64' \
  'def k(a, n, k2)' '  a[0] * k2 + n' 'end'
kase e10_int_only  control -- "$REQ" \
  'freestanding_def :k, params: [:i32, :i32], returns: :i32' \
  'def k(a, b)' '  a + b' 'end'
# e11_int_emit_types is NOT PORTED: `--types-from emit-types` was spinel-llvm's
# Python typing path. The native emitter accepts only `--types-from contract`
# ("emit-types is left to Python by D-6"), in both repositories.
printf '%s\t%s\t%s\t%s\n' e11_int_emit_types not-ported NOT-PORTED \
  "needs --types-from emit-types, spinel-llvm's retired Python typing path" >> "$RES/reject.tsv"
kase e12_callee    control -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in], :len], returns: :i32' \
  'def k(b, n)' '  h(b[0]) + n' 'end' \
  'def h(x)' '  x * 2' 'end'
kase e13_float_cmp control -- "$REQ" \
  'freestanding_def :k, params: [:f64, :f64], returns: :i32' \
  'def k(a, b)' '  if a < b' '    1' '  else' '    0' '  end' 'end'
# recsum's shape at the target's width, as e077_kern.rb now has it (decision
# 0019, revised 2026-10-21; e040's d04_i64 is the refused declaration).
kase e14_stride    control -- "$REQ" \
  'freestanding_def :k, params: [[:i32_buf, :in], :len, :i32], returns: :i32' \
  'def k(r, n, f)' '  s = 0' '  i = 0' '  while i + 2 < n' '    s = s + r[i + f]' '    i += 3' '  end' '  s' 'end'

nr=$(awk -F'\t' 'NR>1 && $2=="reject"' "$RES/reject.tsv" | wc -l | tr -d ' ')
nc=$(awk -F'\t' 'NR>1 && $2=="control"' "$RES/reject.tsv" | wc -l | tr -d ' ')
echo "reject.tsv: $nr rejections + $nc controls, pass=$pass fail=$fail"
[ "$fail" = 0 ] || exit 1
