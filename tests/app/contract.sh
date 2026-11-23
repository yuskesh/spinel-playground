#!/bin/sh
#
# tests/app/contract.sh -- decision 0014, Task 3: the application contract
# (core-contract 2) and its admission in the kernel.
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/app/contract.sh
#
# Every fixture under tests/app/fixtures/contract is run through the kernel
# with --admit-only and must end as tests/app/fixtures/contract/expect.tsv
# says: `admitted`, or refused with the named parser category or eligibility
# reason. The table was written from the plan's Interfaces and refusal codes,
# not from a run. Three more things are checked:
#
#   - an admitted entry reports its extern call sites (the count the kernel
#     prints), and the accepted thread fixture has exactly the four its source
#     makes;
#   - the loop that refuses an application entry as `loop-unbounded` is, under
#     a version 1 contract, still built and reported under hosted-stage2 with
#     the loop bound unknown -- refusal is the application form's rule, not a
#     new analysis;
#   - a version 2 contract given to a full build lowers (Task 5): the object
#     exports the entry alone and its undefined set is the declared externs.
#
# KERNEL, SPINEL_TYPEDUMP, CLANG (or LLVM_PREFIX) and RUBY select the tools.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/app/fixtures/contract"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
RUBY="${RUBY:-ruby}"
die() { echo "contract: $*" >&2; exit 1; }
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL"
[ -x "$READER" ] || die "no contract reader at $READER (set SPINEL_TYPEDUMP)"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"

W=$(mktemp -d "${TMPDIR:-/tmp}/app-contract.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }

# admit FIXTURE: the kernel's verdict as one word -- `admitted`, or the first
# refusal category or reason it printed, or `rc=N` when it said nothing usable
admit() {
  dir=$(dirname "$FIX/$1")
  # the kernel's status, taken where it is the last command run: after an
  # `if` without `else`, $? is the if's own 0
  if "$KERNEL" "$FIX/$1.contract" --root "$dir" --admit-only --clang "$CC_BIN" \
       --typedump "$READER" > "$W/$(basename "$1").out" 2>&1; then
    grep -q '^spinel-core-kernel: admitted ' "$W/$(basename "$1").out" && echo admitted || echo "rc=0-silent"
    return
  else
    rc=$?
  fi
  # Every reason it printed, space-separated and sorted; the caller asks
  # whether the expected one is among them.
  all=$(grep -oE 'not-eligible: [a-z-]+|\.contract:[0-9]+: [a-z-]+' "$W/$(basename "$1").out" | sed 's/.*: //; s/^not-eligible: //' | LC_ALL=C sort -u | tr '\n' ' ')
  echo "${all:-rc=$rc}"
}

echo "contract: every fixture ends as expect.tsv says"
n=0
while IFS="$(printf '\t')" read -r name want; do
  case "$name" in ''|'#'*) continue ;; esac
  n=$((n + 1))
  got=$(admit "$name")
  if [ "$want" = admitted ]; then ok "$name is admitted" "$got" admitted
  else
    # A refused fixture must name its reason among what it printed; a cascade
    # of further reasons behind it is allowed and is not what is checked.
    case " $got " in
      *" $want "*) ok "$name is refused as $want (printed: $got)" yes yes ;;
      *) ok "$name is refused as $want" "$got" "$want" ;;
    esac
  fi
done < "$FIX/expect.tsv"
ok "the table names every fixture on disk" \
   "$(ls "$FIX"/*.contract "$FIX"/elig/*.contract | wc -l | tr -d ' ')" "$n"

echo "contract: the admitted entry reports its extern call sites"
ok "ok-thread: two helpers and four extern calls" \
   "$(sed -n 's/^spinel-core-kernel: admitted run (core-contract 2, \(.*\))$/\1/p' "$W/ok-thread.out")" \
   "2 method(s), 4 extern call(s)"

echo "contract: the same loop under a version 1 contract is reported, not refused"
"$KERNEL" "$FIX/elig/v1-loop.contract" --root "$FIX/elig" -o "$W/v1.o" --header "$W/v1.h" \
  --clang "$CC_BIN" --typedump "$READER" --report "$W/v1.json" --profile hosted-stage2 > "$W/v1.log" 2>&1 && rc=0 || rc=$?
ok "the version 1 entry builds" "$rc" 0
ok "and its report says the loop bound is unknown" \
   "$("$RUBY" -rjson -e 'j = JSON.parse(File.read(ARGV[0])); p = j["properties"]["loop_bound"]; puts p["verdict"] || p["mode"]' "$W/v1.json" 2>/dev/null | head -1 | grep -c unknown)" 1

echo "contract: a version 2 contract in a full build lowers"
"$KERNEL" "$FIX/accepted-thread.contract" --root "$FIX" -o "$W/v2.o" --header "$W/v2.h" \
  --clang "$CC_BIN" --typedump "$READER" > "$W/v2.log" 2>&1 && rc=0 || rc=$?
ok "the build succeeds" "$rc:$(grep -c 'not-' "$W/v2.log" || true)" "0:0"
# v2.o is built for the host, so on macOS it is Mach-O, where every C identifier
# carries one ABI underscore. tools/core/object-symbols reads the object's format
# and removes its prefix -- never the host's uname, the rule that stripped ELF
# names on the Mac (Task 2) -- and fails naming an unknown format.
ok "the object exports the entry, and depends on the declared externs and nothing else" \
   "$(LLVM_PREFIX="${LLVM_PREFIX:-$(dirname "$(dirname "$CC_BIN")")}" "$ROOT/tools/core/object-symbols" "$W/v2.o" 2>&1 |
      awk -F'\t' '$1 == "T" || $1 == "U" { print $1 ":" $2 }' | LC_ALL=C sort | tr '\n' ' ')" \
   "T:spinel_core_sample U:spc_board_adc_latest U:spc_channel_telemetry_put "
# The helper on each format it decides, from one C file cross-compiled three
# ways on whichever host runs this: Mach-O loses exactly one underscore, ELF
# loses nothing, and COFF is refused by name. No SDK is needed to emit an
# object for these targets.
# `_spinel_core_u` carries an underscore of its own: an ELF name must keep it,
# and a helper that stripped one unconditionally would fail the ELF arm.
printf 'int spinel_core_x(int a);\nint _spinel_core_u(int a);\nint spinel_core_p_add(int a) { return spinel_core_x(a) + _spinel_core_u(a); }\n' > "$W/sym.c"
SYMS="$ROOT/tools/core/object-symbols"
PFX="${LLVM_PREFIX:-$(dirname "$(dirname "$CC_BIN")")}"
"$CC_BIN" --target=arm64-apple-macos11 -c "$W/sym.c" -o "$W/sym-macho.o" 2>"$W/sym.err" || die "the Mach-O probe did not compile: $(cat "$W/sym.err")"
ok "object-symbols: a Mach-O object loses exactly one underscore" \
   "$(LLVM_PREFIX="$PFX" "$SYMS" "$W/sym-macho.o" 2>&1 | awk -F'\t' '$1 == "T" || $1 == "U" { print $1 ":" $2 }' | LC_ALL=C sort | tr '\n' ' ')" \
   "T:spinel_core_p_add U:_spinel_core_u U:spinel_core_x "
"$CC_BIN" --target=thumbv8m.main-none-eabi -mcpu=cortex-m33 -c "$W/sym.c" -o "$W/sym-elf.o" 2>"$W/sym.err" || die "the ELF probe did not compile: $(cat "$W/sym.err")"
ok "object-symbols: an ELF object loses nothing" \
   "$(LLVM_PREFIX="$PFX" "$SYMS" "$W/sym-elf.o" 2>&1 | awk -F'\t' '$1 == "T" || $1 == "U" { print $1 ":" $2 }' | LC_ALL=C sort | tr '\n' ' ')" \
   "T:spinel_core_p_add U:_spinel_core_u U:spinel_core_x "
"$CC_BIN" --target=x86_64-windows-msvc -c "$W/sym.c" -o "$W/sym-coff.o" 2>"$W/sym.err" || die "the COFF probe did not compile: $(cat "$W/sym.err")"
ok "control: object-symbols refuses a COFF object by name" \
   "$(LLVM_PREFIX="$PFX" "$SYMS" "$W/sym-coff.o" > /dev/null 2>"$W/sym-coff.err" && echo accepted || grep -c "unsupported object format 'COFF" "$W/sym-coff.err")" 1
# EVERY MODE AGAINST EVERY FORMAT, each with its exact set. The helper's controls
# once covered one mode per format, and `--undefined` on Mach-O returned nothing
# for three tasks: `nm -u` prints a Mach-O name one field wide and the helper
# dropped it, so the gate's B check passed every Mach-O object. The sets below
# were written from llvm-nm's own listing of these two probes, not from the
# helper's output. Mach-O keeps its local labels (ltmp0 in text, ltmp1 in its
# data) and records no sizes, so every --addresses size there is 0.
while IFS='|' read -r fmt mode want; do
  case "$mode" in default) opt= ;; *) opt=$mode ;; esac
  case "$mode" in --addresses) fields='$1 ":" $2 ":" $3 ":" $4' ;; *) fields='$1 ":" $2' ;; esac
  got=$(LLVM_PREFIX="$PFX" "$SYMS" $opt "$W/sym-$fmt.o" 2>"$W/sym-$fmt.err" | awk -F'\t' "{ print $fields }" |
        LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
  ok "object-symbols: $fmt $mode lists exactly its set" "$got" "$want"
done <<'TABLE'
macho|default|T:spinel_core_p_add U:_spinel_core_u U:spinel_core_x s:ltmp1 t:ltmp0
macho|--exported|T:spinel_core_p_add
macho|--defined|T:spinel_core_p_add s:ltmp1 t:ltmp0
macho|--undefined|U:_spinel_core_u U:spinel_core_x
macho|--addresses|0000000000000000:0000000000000000:T:spinel_core_p_add 0000000000000000:0000000000000000:t:ltmp0 0000000000000040:0000000000000000:s:ltmp1
elf|default|T:spinel_core_p_add U:_spinel_core_u U:spinel_core_x
elf|--exported|T:spinel_core_p_add
elf|--defined|T:spinel_core_p_add
elf|--undefined|U:_spinel_core_u U:spinel_core_x
elf|--addresses|00000000:0000001e:T:spinel_core_p_add
TABLE
# A line the helper cannot read is refused, naming the line and the mode, in
# every mode -- never skipped, since a skipped line reads as an absent symbol.
printf '#!/bin/sh\necho "00000000 T spinel_core_p_add"\necho "this is not an nm line"\n' > "$W/nm-bad"
chmod +x "$W/nm-bad"
ok "control: object-symbols refuses a listing line it cannot read, naming line and mode" \
   "$(NM="$W/nm-bad" LLVM_PREFIX="$PFX" "$SYMS" --defined "$W/sym-elf.o" > /dev/null 2>"$W/nm-bad.err" && echo accepted ||
      grep -c "line 2 of nm's defined listing is not a shape this mode prints: \[this is not an nm line\]" "$W/nm-bad.err")" 1
ok "control: --admit-only with -o is refused" \
   "$("$KERNEL" "$FIX/accepted-thread.contract" --root "$FIX" --admit-only -o "$W/x.o" --clang "$CC_BIN" --typedump "$READER" > /dev/null 2>&1 && echo accepted || echo refused)" refused

echo
echo "contract: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" = 0 ] || exit 1
