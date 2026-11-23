#!/usr/bin/env bash
# E040 static rejection table -- P003 decision record D-3 stage 1, plus the
# declaration and profile validators.
#
# THE CONTROL GROUP IS IN THE SAME TABLE (E038's rule).  A tool that refuses
# everything passes a table of refusals; it does not pass a table that also
# contains the things it must ACCEPT.  Rows whose `kind` is `control` are
# expected to build, and a control that gets refused is a failure exactly as
# loud as a reject that gets through.
#
#   reject.tsv      the generator: subset (stage 1), declarations, profiles
#   undef_gate.tsv  the undefined-symbol gate (stage 2), including its controls
set -uo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
mkdir -p "$RES"
W=$OUT/reject
PROF=$FSDIR/profiles/cortex-m33-zephyr.yaml

fs_fresh_workdir "$W"; mkdir -p "$W/spinel"
cp "$FSDIR/spinel/freestanding.rb" "$W/spinel/"

pass=0; fail=0

emit() {   # id kind verdict detail
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RES/reject.tsv"
}

# case <id> <kind: reject|control> <profile> <ruby...>
kase() {
  local id=$1 kind=$2 prof=$3; shift 3
  local f="$W/$id.rb"
  printf '%s\n' "$@" > "$f"
  local out rc
  # `.o`, not `.mlir`: a control has to survive the WHOLE pipeline, including
  # the undefined-symbol gate that --emit obj runs at the end.  d10_wrapprof
  # only catches its bug this way.
  out=$(cd "$W" && "$MLIRGEN" "$id.rb" --freestanding --profile "$prof" \
        -o "$W/$id.o" 2>&1)
  rc=$?
  local first
  # Drop the deprecation note about the pre-T5 profile format, in **the one
  # spelling both implementations share** (decided 2026-09-07). The note comes
  # first on stderr and is over 190 characters, so without this the detail
  # column holds only the note and **not one character of the diagnostic**.
  # The tracked record predates the note.
  first=$(printf '%s' "$out" \
          | { grep -v '^spinel-mlirgen: note: profile .* uses the pre-T5 format (deprecated; P008 Phase 2 canonicalizes the platform-first form); accepted unchanged$' || true; } \
          | head -2 | tr '\n' ' ' | cut -c1-190)
  if [ "$kind" = reject ]; then
    if [ "$rc" -ne 0 ]; then emit "$id" "$kind" REJECTED "$first"; pass=$((pass+1))
    else emit "$id" "$kind" "ACCEPTED (should not be)" "$first"; fail=$((fail+1)); fi
  else
    if [ "$rc" -eq 0 ]; then emit "$id" "$kind" ACCEPTED "ok"; pass=$((pass+1))
    else emit "$id" "$kind" "REJECTED (should not be)" "$first"; fail=$((fail+1)); fi
  fi
}

REQ='require_relative "spinel/freestanding"'
DECL='freestanding_def :k, params: [:i32], returns: :i32'

printf 'id\tkind\tverdict\tdetail\n' > "$RES/reject.tsv"

# ---------------------------------------------------------------------------
# A. subset stage 1: constructs that would ALLOCATE (P003 D-3)
# ---------------------------------------------------------------------------
kase a01_string  reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  s = "x"' '  n' 'end'
kase a02_interp  reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  s = "a#{n}"' '  n' 'end'
kase a03_array   reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  a = [1, 2]' '  n' 'end'
kase a04_hash    reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  h = {a: 1}' '  n' 'end'
kase a05_symbol  reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  s = :sym' '  n' 'end'
kase a06_range   reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  r = (1..n)' '  n' 'end'
# Decision 0041 stage 1 admits a literal block on `times`, so this case
# moved from `n.times { |i| i }` (now accepted) to a block on a call that
# stays refused; it still tests what it meant: a block that is not a loop.
kase a07_block   reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  n.tap { |i| i }' '  n' 'end'
# E092/H2: E077/D-4 made finite Float literals additive to the freestanding
# subset, which drifted this case (it used to assert "FloatNode is not in the
# subset" against `1.5`, which now ACCEPTS).  Swapped to a non-finite literal
# so the case keeps testing what it always meant to test -- the Float
# BOUNDARY, not Float's presence -- against the still-live
# fs_f64_lit() rejection of inf/-inf/nan (tools/mlir/spinel-mlirgen).
kase a08_float   reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  f = 1e400' '  n' 'end'
# Decision 0042 stage 3 admits `**` on two Integers, so this case moved from
# `n ** 2` on the i32 parameter (now accepted) to a Float base, whose power
# stays refused; it still tests what it meant: a power outside the subset.
kase a09_pow     reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  f = 1.5 ** n' '  n' 'end'
kase a10_const   reject "$PROF" "$REQ" "$DECL" 'K = 3' 'def k(n)' '  n + K' 'end'
kase a11_ivar    reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  @x = n' '  n' 'end'
kase a12_class   reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  class C; end' '  n' 'end'
kase a13_rescue  reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  begin; n; rescue; 0; end' 'end'
kase a14_index   reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  a = 1' '  a[n]' 'end'
kase a15_nil     reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  x = nil' '  n' 'end'
kase a16_for     reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  for i in 1..n; end' '  n' 'end'
kase a17_case    reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  case n; when 1; 1; else; 2; end' 'end'
kase a18_gvar    reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  $g = n' '  n' 'end'
kase a19_self    reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  self' '  n' 'end'
kase a20_yield   reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  yield' '  n' 'end'
# a callee (not an entry) that allocates: stage 1 has to reach it too
kase a21_callee  reject "$PROF" "$REQ" "$DECL" 'def k(n)' '  helper(n)' 'end' \
                 'def helper(n)' '  s = "x"' '  n' 'end'

# ---------------------------------------------------------------------------
# B. the declaration itself
# ---------------------------------------------------------------------------
kase b01_nodecl  reject "$PROF" 'def k(n)' '  n' 'end'
kase b02_badty   reject "$PROF" "$REQ" 'freestanding_def :k, params: [:f32], returns: :i32' \
                 'def k(n)' '  n' 'end'
kase b03_noret   reject "$PROF" "$REQ" 'freestanding_def :k, params: [:i32]' \
                 'def k(n)' '  n' 'end'
kase b04_unknown reject "$PROF" "$REQ" \
                 'freestanding_def :k, params: [:i32], returns: :i32, dtype: :f32' \
                 'def k(n)' '  n' 'end'
kase b05_arity   reject "$PROF" "$REQ" \
                 'freestanding_def :k, params: [:i32, :i32], returns: :i32' \
                 'def k(n)' '  n' 'end'
kase b06_raise   reject "$PROF" "$REQ" \
                 'freestanding_def :k, params: [:i32], returns: :i32, overflow: :raise' \
                 'def k(n)' '  n' 'end'
kase b07_dupexp  reject "$PROF" "$REQ" \
                 'freestanding_def :k, params: [:i32], returns: :i32, export: :dup' \
                 'freestanding_def :k2, params: [:i32], returns: :i32, export: :dup' \
                 'def k(n)' '  n' 'end' 'def k2(n)' '  n' 'end'
kase b08_badexp  reject "$PROF" "$REQ" \
                 'freestanding_def :k, params: [:i32], returns: :i32, export: :"a b"' \
                 'def k(n)' '  n' 'end'
kase b09_nomethod reject "$PROF" "$REQ" 'freestanding_def :missing, params: [], returns: :i32' \
                 'def k(n)' '  n' 'end'
kase b10_positional reject "$PROF" "$REQ" 'freestanding_def :k, 3' 'def k(n)' '  n' 'end'
# Two entries with DIFFERENT overflow policies sharing one callee (E022 s5's
# hazard, made detectable by the profile being the single source of truth).
kase b11_mixmode reject "$PROF" "$REQ" \
                 'freestanding_def :t, params: [:i32], returns: :i32, overflow: :trap' \
                 'freestanding_def :w, params: [:i32], returns: :i32, overflow: :wrap' \
                 'def t(n)' '  shared(n)' 'end' 'def w(n)' '  shared(n)' 'end' \
                 'def shared(n)' '  n + 1' 'end'

# ---------------------------------------------------------------------------
# C. the profile
# ---------------------------------------------------------------------------
mk_profile() {  # $1 = name, $2.. = lines replacing the abi/runtime bits
  local name=$1; shift
  { cat "$PROF" | sed '/^abi:/,$d'; printf '%s\n' "$@"; } > "$W/$name.yaml"
}
mk_profile p_raise 'abi:' '  boundary: c-abi' '  int_width: i32-internal' \
                   '  overflow: raise' '  trap_hook: spinel_trap' \
                   'runtime:' '  libc: none' '  libm: none' '  compiler_rt: allow' \
                   'platform:' '  type: zephyr'
mk_profile p_i32   'abi:' '  boundary: c-abi' '  int_width: i32' \
                   '  overflow: trap' '  trap_hook: spinel_trap' \
                   'runtime:' '  libc: none' '  libm: none' '  compiler_rt: allow' \
                   'platform:' '  type: zephyr'
mk_profile p_unk   'abi:' '  boundary: c-abi' '  int_width: i32-internal' \
                   '  overflow: trap' '  trap_hook: spinel_trap' '  bogus: 1' \
                   'runtime:' '  libc: none' '  libm: none' '  compiler_rt: allow' \
                   'platform:' '  type: zephyr'
mk_profile p_nort  'abi:' '  boundary: c-abi' '  int_width: i32-internal' \
                   '  overflow: trap' '  trap_hook: spinel_trap' \
                   'platform:' '  type: zephyr'
kase c01_prof_raise reject "$W/p_raise.yaml" "$REQ" "$DECL" 'def k(n)' '  n' 'end'
kase c02_prof_i32   reject "$W/p_i32.yaml"   "$REQ" "$DECL" 'def k(n)' '  n' 'end'
kase c03_prof_unk   reject "$W/p_unk.yaml"   "$REQ" "$DECL" 'def k(n)' '  n' 'end'
kase c04_prof_nort  reject "$W/p_nort.yaml"  "$REQ" "$DECL" 'def k(n)' '  n' 'end'

# ---------------------------------------------------------------------------
# D. CONTROLS -- these must all build.  Without them the table above proves
#    nothing except that the tool can say no.
# ---------------------------------------------------------------------------
kase d01_plain   control "$PROF" "$REQ" "$DECL" 'def k(n)' '  n + 1' 'end'
# `a, b = b, a % b` desugars to a MultiWriteNode whose value is an ArrayNode.
# a03 above rejects ArrayNode; this row is why that rejection has an exemption.
kase d02_multi   control "$PROF" "$REQ" \
                 'freestanding_def :k, params: [:i32, :i32], returns: :i32' \
                 'def k(a, b)' '  while b != 0' '    a, b = b, a % b' '  end' '  a' 'end'
kase d03_wrap    control "$PROF" "$REQ" \
                 'freestanding_def :k, params: [:i32], returns: :i32, overflow: :wrap' \
                 'def k(n)' '  n * n' 'end'
# A 64-bit body on a 32-bit target is refused (decision 0019, revised
# 2026-10-21); it was a control while `# spinel: int64` kept one.
kase d04_i64     reject  "$PROF" '# spinel: int64' "$REQ" \
                 'freestanding_def :k, params: [:i64, :i64], returns: :i64' \
                 'def k(a, b)' '  a * b' 'end'
kase d05_noargs  control "$PROF" "$REQ" 'freestanding_def :k, params: [], returns: :u16' \
                 'def k' '  7' 'end'
kase d06_shared  control "$PROF" "$REQ" \
                 'freestanding_def :t, params: [:i32], returns: :i32' \
                 'freestanding_def :u, params: [:i32], returns: :i32' \
                 'def t(n)' '  shared(n)' 'end' 'def u(n)' '  shared(n) + 1' 'end' \
                 'def shared(n)' '  n + 1' 'end'
kase d07_riscv   control "$FSDIR/profiles/riscv32-zephyr.yaml" "$REQ" "$DECL" \
                 'def k(n)' '  n + 1' 'end'
kase d08_bool    control "$PROF" "$REQ" "$DECL" 'def k(n)' '  return 1 if n < 2' '  0' 'end'
kase d09_full    control "$PROF" "$(cat "$HERE/e040_kern.rb")"
# A profile whose DEFAULT is wrap.  This control exists because it failed the
# first time it was run: `wrap` fell through to the host arm of div_guard and
# the object imported sp_raise_cls / sp_raise_nil_int_op, which the undefined-
# symbol gate refused (E040 s7).  The control is the regression test.
mk_profile p_wrap  'abi:' '  boundary: c-abi' '  int_width: i32-internal' \
                   '  overflow: wrap' '  trap_hook: spinel_trap' \
                   'runtime:' '  libc: none' '  libm: none' '  compiler_rt: allow' \
                   'platform:' '  type: zephyr' '  externs:' '    - spinel_trap'
kase d10_wrapprof control "$W/p_wrap.yaml" "$(cat "$HERE/e040_kern.rb")"

echo "reject.tsv: $pass as expected / $fail unexpected"

# ---------------------------------------------------------------------------
# E. the undefined-symbol gate (stage 2), with its own controls
# ---------------------------------------------------------------------------
upass=0; ufail=0
uemit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RES/undef_gate.tsv"; }
ukase() {  # id kind(deny|allow) description  -- rest: undef-check args
  local id=$1 kind=$2 desc=$3; shift 3
  local out rc
  out=$("$UNDEF" --undef "$@" 2>&1); rc=$?
  local n
  n=$(printf '%s' "$out" | grep -c '^DENY' || true)
  if [ "$kind" = deny ]; then
    if [ "$rc" -ne 0 ]; then uemit "$id" "$kind" "DENIED ($n)" "$desc"; upass=$((upass+1))
    else uemit "$id" "$kind" "ALLOWED (should not be)" "$desc"; ufail=$((ufail+1)); fi
  else
    if [ "$rc" -eq 0 ]; then uemit "$id" "$kind" ALLOWED "$desc"; upass=$((upass+1))
    else uemit "$id" "$kind" "DENIED (should not be)" "$desc"; ufail=$((ufail+1)); fi
  fi
}

printf 'id\tkind\tverdict\tdescription\n' > "$RES/undef_gate.tsv"
OUTW=$OUT
KO="$OUTW/gen/kern.cortex-m33-zephyr.o"
KR="$OUTW/gen/kern.riscv32-zephyr.o"

ukase e01_profile allow "the shipped M33 profile against the M33 object" \
      --profile "$PROF" "$KO"
ukase e02_riscv   allow "the shipped RV32 profile against the RV32 object" \
      --profile "$FSDIR/profiles/riscv32-zephyr.yaml" "$KR"
# The 32-bit kernel needs no compiler-rt helper, so the helper is planted: a
# hand-written 64-bit remainder, which clang lowers to __aeabi_ldivmod.
printf 'long long r(long long a, long long b){ return a %% b; }\n' > "$W/ldiv.c"
"$LLVM_PREFIX/bin/clang" --target=thumbv8m.main-none-eabi -mcpu=cortex-m33 -O2 \
    -ffreestanding -fno-builtin -c "$W/ldiv.c" -o "$W/ldiv.o" >/dev/null 2>&1
ukase e03_nortdeny deny "compiler_rt=deny: __aeabi_ldivmod (a planted i64 %) is refused" \
      --profile "$PROF" --compiler-rt deny "$W/ldiv.o"
ukase e03_rtallow allow "control: the same object under the shipped profile" \
      --profile "$PROF" "$W/ldiv.o"
ukase e04_nohook  deny "the trap hook is not declared as a platform extern" \
      --libc none --compiler-rt allow "$KO"

# e05-e07 are NOT PORTED. They built a HOST-mode object (--int-overflow=raise,
# importing sp_raise_cls / sp_raise_nil_int_op) through spinel-llvm's hosted
# MLIR importer, `spinel-mlirgen -m blow --int-overflow raise`, which this
# repository does not have. spinel-llvm guarded them with `[ -f host_raise.o ]`,
# which would skip them without a word here; they are named instead.
for r in e05_raiseobj e06_unwind e07_forced; do
  uemit "$r" not-ported NOT-PORTED "needs the hosted MLIR importer (spinel-mlirgen -m), not in this repository"
done
echo "undef gate: e05_raiseobj, e06_unwind, e07_forced not ported (hosted importer)"

# A malloc importer: stage 2's allocation-free half, on a hand-written object.
printf 'extern void *malloc(unsigned long);\nint f(void){ return malloc(8) != 0; }\n' > "$W/mal.c"
"$LLVM_PREFIX/bin/clang" --target=thumbv8m.main-none-eabi -mcpu=cortex-m33 -O2 \
    -ffreestanding -fno-builtin -c "$W/mal.c" -o "$W/mal.o" >/dev/null 2>&1
ukase e08_malloc deny "an object that reached malloc (stage 2 of the allocation-free proof)" \
      --profile "$PROF" "$W/mal.o"
# A memcpy importer under libc=none, and the same one under libc=picolibc.
printf 'struct B { char b[512]; };\nvoid g(struct B *d, struct B *s){ *d = *s; }\n' > "$W/mem.c"
"$LLVM_PREFIX/bin/clang" --target=thumbv8m.main-none-eabi -mcpu=cortex-m33 -O2 \
    -ffreestanding -fno-builtin -c "$W/mem.c" -o "$W/mem.o" >/dev/null 2>&1
ukase e09_memnone deny "libc=none but the object needs memcpy (R006 s3.3's leak)" \
      --profile "$PROF" "$W/mem.o"
ukase e10_mempico allow "the same object with libc=picolibc" \
      --profile "$PROF" --libc picolibc "$W/mem.o"

echo "undef_gate.tsv: $upass as expected / $ufail unexpected"

# The byte comparison of reject.tsv with spinel-llvm's tracked record
# (tools/freestanding/reject_compare.rb) compares with another implementation's
# recorded output: an oracle, run only on the user's instruction.
[ "$fail" = 0 ] && [ "$ufail" = 0 ] && [ -z "${cmp_bad:-}" ]
