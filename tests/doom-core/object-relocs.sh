#!/bin/sh
#
# tests/doom-core/object-relocs.sh — the relocation guard, shown refusing.
#
#   CC=/path/to/clang sh tests/doom-core/object-relocs.sh [DIR]
#
# tests/doom-core/object-relocs.rb admits a relocation whose target is defined
# in the same object -- a branch, or a matched address pair -- and refuses
# anything whose resolution depends on another object (decision of 2026-09-18).
# This builds one object per shape and requires the guard's own message for
# each, so the rule is demonstrated rather than asserted.
#
# THE OBJECTS ARE arm64 Mach-O, BUILT ON WHATEVER HOST RUNS THIS. The shapes
# the rule is about -- ADRP/ADD pairs, GOT loads -- are not emitted for
# x86-64, so a lane that only ever saw this host's objects could not show the
# rule working. `clang -target arm64-apple-macos12 -ffreestanding` produces
# them on Debian without an SDK; where it cannot, the lane says so and skips.
#
# x86-64 ELF objects come last: a switch built as a jump table refers to its
# own sections with R_X86_64_PC32, which is admitted, and a PC32 to another
# object's datum, or to a section the object does not have, is refused.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:-${TMPDIR:-/tmp}/object-relocs.$$}
RUBY=${RUBY:-ruby}
if [ -n "${CC:-}" ]; then CC_BIN=$CC
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else CC_BIN=""; fi
LLVM_BIN=${CC_BIN%/*}
GUARD=$ROOT/tests/doom-core/object-relocs.rb
pass=0; fail=0; skip=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
summary() {
  echo "object-relocs: $((pass + fail)) checked, $pass pass, $fail fail, $skip skipped"
  if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -ne 0 ]; then exit 1; fi
  [ "$fail" -eq 0 ]; exit $?
}
mkdir -p "$DIR" || exit 2
if [ -z "$CC_BIN" ] || [ ! -x "$CC_BIN" ]; then
  echo "  SKIP the guard's refusals: no compiler (set CC or LLVM_PREFIX)" >&2
  skip=$((skip + 1)); summary
fi
TARGET=arm64-apple-macos12
printf 'int t(void){return 0;}\n' > "$DIR/probe.c"
if ! "$CC_BIN" -target "$TARGET" -ffreestanding -c "$DIR/probe.c" -o "$DIR/probe.o" > "$DIR/probe.log" 2>&1; then
  echo "  SKIP the guard's refusals: $CC_BIN cannot target $TARGET" >&2
  skip=$((skip + 1)); summary
fi

# The admitted shape: a branch to this object's own code, and an address pair
# whose halves both name this object's own constant.
cat > "$DIR/local.c" <<'EOF'
static const long t[4] = {1, 2, 3, 4};
int helper(void) { return 42; }
int entry(int i) { return helper() + (int)t[i & 3]; }
EOF
"$CC_BIN" -target "$TARGET" -ffreestanding -O1 -c "$DIR/local.c" -o "$DIR/local.o" 2>> "$DIR/probe.log"
out=$("$RUBY" "$GUARD" "$LLVM_BIN" "$DIR/local.o" 2>&1)
ok "a branch and an address pair to this object's own symbols are admitted" \
   "$?|$(printf '%s\n' "$out" | head -1)" "0|local ok"
ok "  and the pair is in the record" \
   "$(printf '%s\n' "$out" | grep -c 'ARM64_RELOC_PAGE21:\|ARM64_RELOC_PAGEOFF12:')" 1

# An external target: the branch is fine, the symbol is another object's.
printf 'int other(void);\nint f(void){return other();}\n' > "$DIR/ext.c"
"$CC_BIN" -target "$TARGET" -ffreestanding -c "$DIR/ext.c" -o "$DIR/ext.o" 2>> "$DIR/probe.log"
out=$("$RUBY" "$GUARD" "$LLVM_BIN" "$DIR/ext.o" 2>&1); rc=$?
ok "a branch to a symbol this object does not define is refused" \
   "$rc|$(printf '%s\n' "$out" | grep -c '^ext refused ARM64_RELOC_BRANCH26 to _other, which this object does not define$')" "1|1"

# Reaching outside indirectly: a GOT load for an external datum.
printf 'extern int g;\nint f(void){return g;}\n' > "$DIR/got.c"
"$CC_BIN" -target "$TARGET" -ffreestanding -c "$DIR/got.c" -o "$DIR/got.o" 2>> "$DIR/probe.log"
out=$("$RUBY" "$GUARD" "$LLVM_BIN" "$DIR/got.o" 2>&1); rc=$?
ok "a GOT load is refused, and the message says another object decides it" \
   "$rc|$(printf '%s\n' "$out" | grep -c 'resolves through a got, so another object decides it')" "1|1"

# A lone half: an ADRP with no matching ADD.
cat > "$DIR/lone.s" <<'EOF'
        .section __TEXT,__text,regular,pure_instructions
        .globl _lone
_lone:
        adrp x0, _pool@PAGE
        ret
        .section __DATA,__data
        .globl _pool
_pool:  .quad 7
EOF
"$CC_BIN" -target "$TARGET" -c "$DIR/lone.s" -o "$DIR/lone.o" 2>> "$DIR/probe.log"
out=$("$RUBY" "$GUARD" "$LLVM_BIN" "$DIR/lone.o" 2>&1); rc=$?
ok "an address pair with no second half is refused" \
   "$rc|$(printf '%s\n' "$out" | grep -c '^lone refused _pool has 1 page relocation(s) and 0 offset(s); an address pair is matched, not counted$')" "1|1"

# Halves that name different targets: each is local, the pair is not a pair.
cat > "$DIR/mismatch.s" <<'EOF'
        .section __TEXT,__text,regular,pure_instructions
        .globl _mismatch
_mismatch:
        adrp x0, _a@PAGE
        add  x0, x0, _b@PAGEOFF
        ret
        .section __DATA,__data
        .globl _a
_a:     .quad 1
        .globl _b
_b:     .quad 2
EOF
"$CC_BIN" -target "$TARGET" -c "$DIR/mismatch.s" -o "$DIR/mismatch.o" 2>> "$DIR/probe.log"
out=$("$RUBY" "$GUARD" "$LLVM_BIN" "$DIR/mismatch.o" 2>&1); rc=$?
ok "an address pair whose halves name different targets is refused" \
   "$rc|$(printf '%s\n' "$out" | grep -c 'an address pair is matched, not counted')" "1|1"

# A private constant-pool label, which is what macOS arm64 produced for
# doom_core_step.o: the target is local and the pair is matched, so it passes.
cat > "$DIR/table.c" <<'EOF'
int f(int x) {
  switch (x) {
  case 0: return 11; case 1: return 22; case 2: return 33; case 3: return 44;
  case 4: return 55; case 5: return 66; case 6: return 77; case 7: return 88;
  case 8: return 99; case 9: return 111; case 10: return 122; case 11: return 133;
  default: return -1;
  }
}
EOF
"$CC_BIN" -target "$TARGET" -ffreestanding -O2 -c "$DIR/table.c" -o "$DIR/table.o" 2>> "$DIR/probe.log"
out=$("$RUBY" "$GUARD" "$LLVM_BIN" "$DIR/table.o" 2>&1)
ok "a private constant-pool label of this object is admitted (the macOS shape)" \
   "$?|$(printf '%s\n' "$out" | head -1)" "0|table ok"

X86=x86_64-linux-gnu
if ! "$CC_BIN" -target "$X86" -ffreestanding -c "$DIR/probe.c" -o "$DIR/probe-x86.o" >> "$DIR/probe.log" 2>&1; then
  echo "  SKIP the x86-64 PC-relative shapes: $CC_BIN cannot target $X86" >&2
  skip=$((skip + 1)); summary
fi
# A jump table, the shape the entries' x86-64 objects carry: the code's PC32
# to the table in .rodata, and the table's relative entries, each a PC32 to
# this object's .text.
cat > "$DIR/jump.c" <<'EOF'
void f(int x, int *p) {
  switch (x) {
  case 0: p[0] = 3; break; case 1: p[1] = 5; p[0] = 1; break; case 2: p[2] = 7; break;
  case 3: p[3] = 9; p[1] = 2; break; case 4: p[4] = 11; break; case 5: p[0] += 13; break;
  case 6: p[6] ^= 17; break; case 7: p[1] -= 19; break;
  default: break;
  }
}
EOF
"$CC_BIN" -target "$X86" -ffreestanding -fPIE -O2 -c "$DIR/jump.c" -o "$DIR/jump.o" 2>> "$DIR/probe.log"
out=$("$RUBY" "$GUARD" "$LLVM_BIN" "$DIR/jump.o" 2>&1)
ok "a jump table's PC32 references to this object's own sections are admitted" \
   "$?|$(printf '%s\n' "$out" | head -1)|$(printf '%s\n' "$out" | grep -c 'R_X86_64_PC32:\.rodata.*R_X86_64_PC32:\.text')" "0|jump ok|1"

# Another object's datum, reached directly: a PC32 the linker resolves against
# whichever object defines g.
printf 'extern int g;\nint f(void){return g;}\n' > "$DIR/extpc.c"
"$CC_BIN" -target "$X86" -ffreestanding -fPIE -fdirect-access-external-data -O2 -c "$DIR/extpc.c" -o "$DIR/extpc.o" 2>> "$DIR/probe.log"
out=$("$RUBY" "$GUARD" "$LLVM_BIN" "$DIR/extpc.o" 2>&1); rc=$?
ok "a PC32 to a symbol this object does not define is refused" \
   "$rc|$(printf '%s\n' "$out" | grep -c '^extpc refused R_X86_64_PC32 to g, which this object does not define$')" "1|1"

# A name that looks like a section and is not one of this object's: the guard
# admits a section by the object's own section list, never by its spelling.
cat > "$DIR/nosec.s" <<'EOF'
        .text
        .globl nosec
nosec:
        movl .bogus(%rip), %eax
        ret
EOF
"$CC_BIN" -target "$X86" -c "$DIR/nosec.s" -o "$DIR/nosec.o" 2>> "$DIR/probe.log"
out=$("$RUBY" "$GUARD" "$LLVM_BIN" "$DIR/nosec.o" 2>&1); rc=$?
ok "a PC32 to a section this object does not have is refused" \
   "$rc|$(printf '%s\n' "$out" | grep -c '^nosec refused R_X86_64_PC32 to .bogus, which this object does not define$')" "1|1"
summary
