#!/bin/sh
#
# tests/app/cross.sh -- decision 0014, Task 2: the kernel cross-builds for
# Cortex-M33.
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/app/cross.sh
#   ... ZEPHYR_BASE=... ZEPHYR_SDK_INSTALL_DIR=... sh tests/app/cross.sh   # with the spike
#
# Everything here is built for thumbv8m.main-none-eabi with the kernel's own
# clang and the flags the tool will pass (0014 plan, "Interfaces" of Task 2):
#
#   1. the per-call overhead row for thumbv8m exists, with its evidence, and a
#      target without a row is still refused;
#   2. the 0010 step 2 fixtures build for thumbv8m: the object of a plain build
#      equals the object of a reporting build byte for byte (and a build with
#      -O0 appended differs, so the comparison can fail); the frame canary is
#      reported; the zero-frame entry reads zero; the deep chain keeps its
#      frames;
#   3. the artifact gate on an ARM ELF object: an extra undefined symbol fails
#      with --extern naming the others, and passes when it is named;
#   4. the header of a thumbv8m build states ptr32; a cross build without
#      --layout, and one with the wrong --layout, are refused; the descriptor
#      of a thumbv8m build is guarded against the 32-bit address width;
#   5. the spike: an adapter compiles against Zephyr's headers with the kernel's
#      clang, using the include paths and defines of compile_commands.json;
#      every flag clang rejects is the recorded one, and the build attributes
#      that govern linking agree with a Zephyr object of the same build (with
#      the two controls that make them disagree). Skipped without ZEPHYR_BASE
#      and ZEPHYR_SDK_INSTALL_DIR; the venv must be first on PATH, as for
#      platform-facts.sh;
#   6. the D1 probe: checked 32-bit arithmetic and shifts, the real bodies of
#      tools/app/lib/spinel/net.rb and core_fixed_div build for thumbv8m; the
#      union of their undefined symbols is printed verbatim and must equal the
#      helper list in tests/app/fixtures/cross/d1-helpers.txt, each helper
#      referenced by at least one object.
#   7. decision 0022 §3: the wrapper's descriptor checks with 32-bit pointers.
#      tests/app/wrapper32.rb runs the positive and negative cases of
#      tests/app/fixtures/cross/wrapper/cases.tsv on wasm32 under node
#      (skipped, with the reason, without a node or a wasm-ld that runs). The thumbv8m wrapper of the
#      two-buffer fixture makes its range and overlap comparisons in 32 bits:
#      its only `sbc` are the two size checks, one per buffer, and it has no
#      `adc`; at_u8's index check is one 32-bit compare, so its one `sbc` is
#      the wrapper's.
#
# KERNEL, STACK_TOOL, SPINEL_TYPEDUMP, CLANG (or LLVM_PREFIX), RUBY and NODE
# select the tools. REQUIRE_ALL=1 turns a skip into a failure.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/app/fixtures/cross"
STACKFIX="$ROOT/tests/core-stack/fixtures"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
STACK_TOOL="${STACK_TOOL:-$ROOT/tools/mlir/native/build/bin/spinel-core-stack}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
GATE="$ROOT/tools/core/core-artifact-gate"
RUBY="${RUBY:-ruby}"

die() { echo "cross: $*" >&2; exit 1; }
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL (build tools/mlir/native first)"
[ -x "$STACK_TOOL" ] || die "no spinel-core-stack at $STACK_TOOL"
[ -x "$READER" ] || die "no contract reader at $READER (build tools/contract or set SPINEL_TYPEDUMP)"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
BIN=$(dirname "$CC_BIN")
NM="${NM:-$BIN/llvm-nm}"; READELF="${READELF:-$BIN/llvm-readelf}"; READOBJ="${READOBJ:-$BIN/llvm-readobj}"
export NM READOBJ

# THE TARGET FLAGS THE TOOL PASSES. --target names the triple; -mcpu with
# +nodsp and -mfloat-abi=soft are what make the build attributes agree with
# Zephyr's GCC objects (item 5 measures both); -Os is what compile_commands.json
# records for mps2/an521/cpu0.
TARGET=thumbv8m.main-none-eabi
TFLAGS="--target=$TARGET -mcpu=cortex-m33+nodsp -mfloat-abi=soft -mthumb -Os"
LAYOUT=ptr32-i64-32long

W=$(mktemp -d "${TMPDIR:-/tmp}/app-cross.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0; skip=0
skips=""
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
skipped() { echo "  SKIP $1"; skip=$((skip + 1)); skips="$skips  - $1
"; }

# build ENTRY WORKDIR OUT [kernel args...]: one thumbv8m build, log kept
build() { # entry dir out extra...
  e=$1; d=$2; o=$3; shift 3
  "$KERNEL" "$d/$e.contract" --root "$d" -o "$o" --layout "$LAYOUT" \
    --clang "$CC_BIN" --typedump "$READER" "$@" -- $TFLAGS ${XFLAGS:-} > "$o.log" 2>&1
}
field() { # ir key [tool args...]
  ir=$1; key=$2; shift 2
  "$STACK_TOOL" "$ir" --clang "$CC_BIN" --profile hosted-stage2 "$@" -- $TFLAGS 2>/dev/null |
    sed -n "s/^$key: //p"
}
undefined() { "$NM" -u "$1" | awk '{print $NF}' | LC_ALL=C sort -u; }
# attrs OBJECT: the aeabi build attributes as "Tag=value description" lines
attrs() {
  "$READELF" -A "$1" | awk '/TagName/{n=$2} /Value:/{v=$2} /Description:/{d=$0; sub(/.*Description: /,"",d)}
    /^      }/{ if (n != "") printf "%s=%s %s\n", n, v, d; n=""; v=""; d="" }'
}

# ---------------------------------------------------------------------------
echo "cross: building the step 2 fixtures and the zero-frame entry for $TARGET"
mkdir -p "$W/st"
"$RUBY" "$ROOT/tests/core-report/contracts.rb" --fixture "$STACKFIX/stack.rb" \
  --root-name stack.rb --out "$W/st" --int i32 st_deep st_wide st_leaf
cp "$STACKFIX/stack.rb" "$W/st/"
"$RUBY" "$ROOT/tests/core-report/contracts.rb" --fixture "$FIX/zero.rb" \
  --root-name zero.rb --out "$W/st" --int i32 z_id
cp "$FIX/zero.rb" "$W/st/"
for e in st_deep st_wide st_leaf z_id; do
  build "$e" "$W/st" "$W/st/$e.a.o" --header "$W/st/$e.h" --emit-optimised-ir "$W/st/$e.bc" ||
    die "$e did not build for $TARGET; see $W/st/$e.a.o.log"
  build "$e" "$W/st" "$W/st/$e.b.o" --report "$W/st/$e.json" --profile realtime \
    --fixture-stack-provision 4096 --fixture-interrupt-reserve 0 ||
    die "$e did not build with a report; see $W/st/$e.b.o.log"
done

echo "cross: 1. the per-call overhead row for thumbv8m"
ok "the row exists and is zero" "$(field "$W/st/st_leaf.bc" call_overhead)" 0
ok "the report carries its evidence" \
   "$("$RUBY" -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["properties"]["stack_budget"]["call_overhead"]["evidence"].include?("thumbv8m") ? "yes" : "no"' "$W/st/st_deep.json")" yes
ok "a target without a row is still refused" \
   "$("$STACK_TOOL" "$W/st/st_leaf.bc" --clang "$CC_BIN" --profile hosted-stage2 -- --target=riscv32-unknown-elf -march=rv32imac -mabi=ilp32 2>/dev/null |
      grep -c 'no per-call stack overhead is recorded')" 1

echo "cross: 2. the step 2 fixtures on thumbv8m"
for e in st_deep st_wide st_leaf z_id; do
  ok "$e: the plain object equals the reporting build's" "$(cmp -s "$W/st/$e.a.o" "$W/st/$e.b.o" && echo same || echo differ)" same
done
# XFLAGS is set and cleared as statements, not written as `XFLAGS=-O0 build`.
# POSIX leaves unspecified whether an assignment in front of a FUNCTION call
# outlives it: dash drops it, but bash -- /bin/sh on macOS -- keeps it, and
# there every build below this line ran with -O0 appended. The check after the
# control is what catches that.
XFLAGS=-O0
build st_leaf "$W/st" "$W/st/st_leaf.o1.o" || die "the -O0 control did not build; see $W/st/st_leaf.o1.o.log"
XFLAGS=
ok "control: -O0 appended changes the object" "$(cmp -s "$W/st/st_leaf.a.o" "$W/st/st_leaf.o1.o" && echo same || echo differ)" differ
build st_leaf "$W/st" "$W/st/st_leaf.again.o" --header "$W/st/st_leaf.again.h" \
  --emit-optimised-ir "$W/st/st_leaf.again.bc" || die "st_leaf did not rebuild; see $W/st/st_leaf.again.o.log"
ok "and the build after that control is back at the target flags" \
   "$(cmp -s "$W/st/st_leaf.a.o" "$W/st/st_leaf.again.o" && echo same || echo differ)" same
ok "every object is a 32-bit ARM ELF" \
   "$(for e in st_deep st_wide st_leaf z_id; do "$READOBJ" --file-headers "$W/st/$e.a.o" | sed -n 's/^Format: *//p'; done | sort -u)" elf32-littlearm
ok "no object references an undefined symbol" \
   "$(for e in st_deep st_wide st_leaf z_id; do undefined "$W/st/$e.a.o"; done | wc -l | tr -d ' ')" 0
canary=$(field "$W/st/st_leaf.bc" canary_frame)
if [ "${canary:-0}" -ge 2048 ] 2>/dev/null; then ok "the frame canary is reported ($canary bytes)" yes yes
else ok "the frame canary is reported" "${canary:-none}" ">=2048"; fi
ok "the zero-frame entry reads zero, not unknown" \
   "$(field "$W/st/z_id.bc" evaluated):$(field "$W/st/z_id.bc" kernel_stack)" "true:0"
ok "the deep chain keeps its frames" "$(field "$W/st/st_deep.bc" worst_path | wc -w | tr -d ' ')" 7
ok "kernel_stack is the frame total, the overhead being zero" \
   "$(field "$W/st/st_deep.bc" kernel_stack)" "$(field "$W/st/st_deep.bc" frame_total)"
# The unwind fact of the plan: a CORE function is nounwind and references no
# personality; a function without the attribute would (E040 case e06).
printf 'declare void @ext()\ndefine i32 @f(i32 %%a) { call void @ext()\n ret i32 %%a }\n' > "$W/nounwind.ll"
"$CC_BIN" $TFLAGS -c "$W/nounwind.ll" -o "$W/nounwind.o" 2>/dev/null
ok "control: a function without nounwind references __aeabi_unwind_cpp_pr0" \
   "$(undefined "$W/nounwind.o" | grep -c '^__aeabi_unwind_cpp_pr0$')" 1
# THE KERNEL SAYS nounwind ITSELF. Until 2026-09-22 the attribute was only
# inferred by the optimiser: present at -Os, absent at -O0, where every probe
# object referenced the personality routine (measured on the Mac). So the
# entry is built once more at -O0, where nothing infers anything, and must
# still reference no personality; and every definition in the IR it was built
# from must carry the attribute, through the attribute group it names.
XFLAGS=-O0
build st_leaf "$W/st" "$W/st/st_leaf.o0u.o" --emit-optimised-ir "$W/st/st_leaf.o0u.bc" ||
  die "the -O0 unwind control did not build; see $W/st/st_leaf.o0u.o.log"
XFLAGS=
ok "at -O0 the object still references no personality routine" \
   "$(undefined "$W/st/st_leaf.o0u.o" | grep -c '^__aeabi_unwind_cpp_pr0$')" 0
"$BIN/llvm-dis" "$W/st/st_leaf.o0u.bc" -o "$W/st/st_leaf.o0u.ll"
ok "and every definition in its IR is nounwind by the kernel's hand" \
   "$("$RUBY" -e 'ir = File.read(ARGV[0]); groups = ir.scan(/^attributes (#\d+) = \{([^}]*)\}/).to_h
                  defs = ir.scan(/^define .*?(#\d+) \{$/).flatten
                  puts "#{defs.count { |g| groups[g].to_s.include?("nounwind") }}/#{defs.size}"' "$W/st/st_leaf.o0u.ll")" \
   "$(grep -c '^define ' "$W/st/st_leaf.o0u.ll")/$(grep -c '^define ' "$W/st/st_leaf.o0u.ll")"
ok "the CantUnwind index entries remain, and are all there is of .ARM.exidx" \
   "$("$READELF" --unwind "$W/st/st_leaf.a.o" 2>/dev/null | grep -c 'Model: CantUnwind'):$("$READELF" --unwind "$W/st/st_leaf.a.o" 2>/dev/null | grep -c 'Model: ')" "1:1"

echo "cross: 3. the gate on an ARM ELF object"
printf 'extern long spinel_h(long);\nlong spc_x(long a){ return spinel_h(a) + 1; }\n' > "$W/g.c"
"$CC_BIN" $TFLAGS -c "$W/g.c" -o "$W/g.o"
if sh "$GATE" "$W/g.o" spc_x > "$W/g1.out" 2>&1; then ok "an extra undefined symbol fails" accepted refused
else ok "an extra undefined symbol fails, naming it" "$(grep -c 'B: the object depends on \[spinel_h\]' "$W/g1.out")" 1; fi
ok "and passes when it is named with --extern" \
   "$(sh "$GATE" --extern spinel_h "$W/g.o" spc_x > /dev/null 2>&1 && echo pass || echo fail)" pass
if sh "$GATE" --extern __aeabi_ldivmod "$W/g.o" spc_x > "$W/g2.out" 2>&1; then ok "naming another symbol does not admit it" accepted refused
else ok "naming another symbol does not admit it, and the others are named" "$(grep -c 'beyond the named externs' "$W/g2.out")" 1; fi
ok "control: a prefix is not a name" \
   "$(sh "$GATE" --extern spinel_ "$W/g.o" spc_x > /dev/null 2>&1 && echo pass || echo refused)" refused
ok "the ELF name is not stripped (the old host rule would strip its first character)" \
   "$(sh "$GATE" --extern spinel_h "$W/g.o" pc_x > /dev/null 2>&1 && echo pass || echo refused)" refused

echo "cross: 4. the header's layout"
ok "a thumbv8m header states ptr32" \
   "$(sed -n 's/^#define SPINEL_CORE_ENTRY_ST_LEAF_LAYOUT "\(.*\)"$/\1/p' "$W/st/st_leaf.h")" "$LAYOUT"
"$KERNEL" "$W/st/st_leaf.contract" --root "$W/st" -o "$W/st/nolayout.o" --header "$W/st/nolayout.h" \
  --clang "$CC_BIN" --typedump "$READER" -- $TFLAGS > "$W/st/nolayout.log" 2>&1 && rc=0 || rc=$?
ok "control: a cross build without --layout is refused" "$rc:$(grep -c 'pass --layout ptr32-i64-32long' "$W/st/nolayout.log"):$([ -f "$W/st/nolayout.o" ] && echo object || echo no-object)" "2:1:no-object"
"$KERNEL" "$W/st/st_leaf.contract" --root "$W/st" -o "$W/st/wrong.o" --header "$W/st/wrong.h" --layout ptr64-i64-64long \
  --clang "$CC_BIN" --typedump "$READER" -- $TFLAGS > "$W/st/wrong.log" 2>&1 && rc=0 || rc=$?
ok "control: the wrong --layout is refused" "$rc:$(grep -c 'disagrees with the target' "$W/st/wrong.log")" "2:1"
"$KERNEL" "$W/st/st_leaf.contract" --root "$W/st" -o "$W/st/host.o" --header "$W/st/host.h" \
  --clang "$CC_BIN" --typedump "$READER" > "$W/st/host.log" 2>&1 && rc=0 || rc=$?
ok "a host build still needs no --layout" "$rc" 0
# The descriptor audit of Task 2, as decision 0022 §3 lowers it: on a 32-bit
# target the wrapper refuses a count's upper word by comparing the count
# argument itself with 4294967295 (one per buffer; the form LLVM turns into the
# range the body's count receives), checks the size against UINTPTR_MAX - base,
# and reads the buffer's and the result's addresses as i32 for the range and
# overlap comparisons. A host build does neither. The guard is read from the
# MLIR the two builds emit; item 7 runs it.
"$KERNEL" "$W/st/st_leaf.contract" --root "$W/st" -o "$W/st/g32.o" --layout "$LAYOUT" --emit-mlir "$W/st/g32.mlir" \
  --clang "$CC_BIN" --typedump "$READER" -- $TFLAGS > /dev/null 2>&1 || die "the guard build failed"
"$KERNEL" "$W/st/st_leaf.contract" --root "$W/st" -o "$W/st/g64.o" --emit-mlir "$W/st/g64.mlir" \
  --clang "$CC_BIN" --typedump "$READER" > /dev/null 2>&1 || die "the host guard build failed"
upper='arith.cmpi ugt, %arg[0-9]+, %c4294967295_i64'
ok "a thumbv8m build refuses the count argument's upper word and reads its two addresses as i32" \
   "$(grep -cE "$upper" "$W/st/g32.mlir"):$(grep -c 'llvm.ptrtoint .* to i32' "$W/st/g32.mlir")" "1:2"
ok "control: a host build carries neither" \
   "$(grep -cE "$upper" "$W/st/g64.mlir"):$(grep -c 'llvm.ptrtoint .* to i32' "$W/st/g64.mlir")" "0:0"

echo "cross: 5. the spike: clang against Zephyr's headers"
if [ -n "${ZEPHYR_BASE:-}" ] && [ -n "${ZEPHYR_SDK_INSTALL_DIR:-}" ] && command -v west > /dev/null 2>&1; then
  export ZEPHYR_BASE ZEPHYR_SDK_INSTALL_DIR
  Z="$W/zephyr"
  west build -p always -b mps2/an521/cpu0 "$ZEPHYR_BASE/samples/hello_world" -d "$Z" -- \
    -DZEPHYR_SDK_INSTALL_DIR="$ZEPHYR_SDK_INSTALL_DIR" > "$Z.log" 2>&1 || die "hello_world did not build; see $Z.log"
  ok "the SDK the configure used is the one named" \
     "$(sed -n 's/^-- Found toolchain: zephyr \([^ ]*\) (\(.*\))$/\2/p' "$Z.log" | head -1)" "$(CDPATH= cd -- "$ZEPHYR_SDK_INSTALL_DIR" && pwd -P)"
  # The flags of main.c's line, less the compiler, the input and the output.
  "$RUBY" -rjson -e 'cc = JSON.parse(File.read(ARGV[0])); e = cc.find { |c| c["file"].end_with?("hello_world/src/main.c") } or abort "no main.c in compile_commands.json"; puts e["command"]' \
    "$Z/compile_commands.json" > "$W/main.cmd"
  sed 's/^[^ ]* //; s/ -o [^ ]*//; s/ -c [^ ]*$//; s/ -c / /' "$W/main.cmd" | tr ' ' '\n' | grep -v '^$' > "$W/flags.txt"
  ok "the recorded line has no float ABI (soft-float is GCC's default here)" "$(grep -c -e '-mfloat-abi' -e '-mfpu' "$W/flags.txt" || true)" 0
  cp "$FIX/adapter.c" "$W/adapter.c"
  # Every flag clang rejects, verbatim, compared with the list this task recorded.
  "$CC_BIN" --target=$TARGET $(tr '\n' ' ' < "$W/flags.txt") -fno-color-diagnostics -c "$W/adapter.c" -o "$W/adapter.raw.o" > "$W/raw.err" 2>&1 || true
  rejected=$(sed -n "s/^clang: error: unknown argument: '\(.*\)'$/\1/p" "$W/raw.err" | LC_ALL=C sort | tr '\n' ' ')
  ok "the flags clang rejects are the recorded ones" "$rejected" "$(tr '\n' ' ' < "$FIX/rejected-flags.txt")"
  # The translation: drop what clang rejects or ignores, add the float ABI and
  # the enum size GCC's arm-none-eabi assumes (both measured, see the record).
  grep -vxF -f "$FIX/dropped-flags.txt" "$W/flags.txt" > "$W/flags.clang.txt"
  ADD="-mfloat-abi=soft -fshort-enums"
  "$CC_BIN" --target=$TARGET $ADD $(tr '\n' ' ' < "$W/flags.clang.txt") -fno-color-diagnostics -c "$W/adapter.c" -o "$W/adapter.o" > "$W/adapter.err" 2>&1 && rc=0 || rc=$?
  ok "the adapter compiles against Zephyr's headers, with no diagnostic" "$rc:$(grep -c . "$W/adapter.err")" "0:0"
  ok "it defines its function and references the kernel call it makes" \
     "$("$NM" "$W/adapter.o" | awk '{print $(NF-1) " " $NF}' | LC_ALL=C sort | tr '\n' ';')" "T spc_board_probe;U k_is_in_isr;"
  # The build attributes that govern linking, against a Zephyr object of the
  # same build: the tags both objects carry must agree, except the optimisation
  # goal (a -O level, not an ABI) and the FP exception model (clang says none,
  # GCC says IEEE; both soft-float, and the linker takes the union).
  zobj=$(find "$Z/zephyr/CMakeFiles/zephyr.dir/lib/os" -name 'printk.c.obj' | head -1)
  [ -n "$zobj" ] || die "no printk.c.obj under $Z"
  attrs "$zobj" > "$W/attr.zephyr"
  govern() { grep -vE '^(ABI_optimization_goals|ABI_FP_exceptions|CPU_name|conformance|ARM_ISA_use|ABI_PCS_R9_use|ABI_PCS_GOT_use)=' "$1" | LC_ALL=C sort; }
  agree() { # object: the tags present in both, compared
    attrs "$1" > "$W/attr.ours"
    govern "$W/attr.zephyr" | cut -d= -f1 > "$W/tags.z"; govern "$W/attr.ours" | cut -d= -f1 > "$W/tags.o"
    LC_ALL=C comm -12 "$W/tags.z" "$W/tags.o" > "$W/tags.both"
    grep -F -f "$W/tags.both" "$W/attr.zephyr" | LC_ALL=C sort > "$W/z.both"
    grep -F -f "$W/tags.both" "$W/attr.ours" | LC_ALL=C sort > "$W/o.both"
    cmp -s "$W/z.both" "$W/o.both" && echo agree || echo "disagree: $(diff "$W/z.both" "$W/o.both" | grep '^[<>]' | tr '\n' ';')"
  }
  ok "the adapter's build attributes agree with Zephyr's object" "$(agree "$W/adapter.o")" agree
  ok "no FP architecture is stamped on the soft-float adapter" "$(grep -c '^FP_arch=' "$W/attr.ours")" 0
  ok "the CORE object's attributes agree with Zephyr's object too" "$(agree "$W/st/st_leaf.a.o")" agree
  "$CC_BIN" --target=$TARGET -mfloat-abi=soft $(tr '\n' ' ' < "$W/flags.clang.txt") -c "$W/adapter.c" -o "$W/adapter.noshort.o" 2>/dev/null
  ok "control: without -fshort-enums the enum size disagrees" "$(agree "$W/adapter.noshort.o" | cut -d: -f1)" disagree
  # Without the float ABI clang assumes the M33 has an FPU: CMSIS refuses the
  # adapter outright, and a CORE object gets an FP architecture stamped.
  "$CC_BIN" --target=$TARGET -fshort-enums $(tr '\n' ' ' < "$W/flags.clang.txt") -fno-color-diagnostics -c "$W/adapter.c" -o "$W/adapter.nofloat.o" > "$W/nofloat.err" 2>&1 && rc=0 || rc=$?
  ok "control: without -mfloat-abi=soft CMSIS refuses the adapter" "$rc:$(grep -c '#error "Compiler generates FPU instructions for a device without an FPU' "$W/nofloat.err")" "1:1"
  "$CC_BIN" --target=$TARGET -mcpu=cortex-m33+nodsp -mthumb -Os -c "$W/st/st_leaf.bc" -o "$W/st_leaf.nofloat.o" 2>/dev/null
  ok "control: without -mfloat-abi=soft a CORE object gets an FP architecture stamped" "$(attrs "$W/st_leaf.nofloat.o" | grep -c '^FP_arch=')" 1
else
  skipped "the spike against Zephyr's headers (ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR and west on PATH are needed)"
fi

echo "cross: 6. the D1 runtime-helper probe"
mkdir -p "$W/probe"
cat "$ROOT/tools/app/lib/spinel/net.rb" "$FIX/probe.rb" > "$W/probe/probe.rb"
scalars="p_add p_sub p_mul p_div p_mod p_shl p_shr p_mul_c p_div_c p_mod_c p_shl_c p_shr_c"
"$RUBY" "$ROOT/tests/core-report/contracts.rb" --fixture "$W/probe/probe.rb" --root-name probe.rb --out "$W/probe" --int i32 $scalars
printf 'core-contract 1\nroot probe.rb\nentry p_fixed_div\nresult i32\nparam a scalar i32\nparam b scalar i32\n' > "$W/probe/p_fixed_div.contract"
for e in p_put_u8 p_put_u16 p_put_i32 p_put_dec; do
  printf 'core-contract 1\nroot probe.rb\nentry %s\nresult i32\nparam out buffer u8 inout count n_out\nparam n_out scalar u64\nparam pos scalar i32\nparam v scalar i32\n' "$e" > "$W/probe/$e.contract"
done
printf 'core-contract 1\nroot probe.rb\nentry p_put_str\nresult i32\nparam out buffer u8 inout count n_out\nparam n_out scalar u64\nparam pos scalar i32\nparam s buffer u8 in count n_s\nparam n_s scalar u64\n' > "$W/probe/p_put_str.contract"
built=0; failed=""
: > "$W/probe/undefined.txt"
for c in "$W/probe"/*.contract; do
  e=$(basename "$c" .contract)
  if build "$e" "$W/probe" "$W/probe/$e.o"; then
    built=$((built + 1))
    undefined "$W/probe/$e.o" | sed "s/^/$e /" >> "$W/probe/undefined.txt"
  else failed="$failed $e"; fi
done
ok "all 18 probe entries build for $TARGET" "$built:${failed:- none}" "18: none"
echo "  undefined symbols, verbatim (entry symbol):"
if [ -s "$W/probe/undefined.txt" ]; then sed 's/^/    /' "$W/probe/undefined.txt"; else echo "    (none)"; fi
union=$(awk '{print $2}' "$W/probe/undefined.txt" | LC_ALL=C sort -u | tr '\n' ' ')
ok "the union is the recorded D1 helper list" "${union:-none}" "$(LC_ALL=C sort "$FIX/d1-helpers.txt" | tr '\n' ' ')"
ok "every entry passes the gate with that list" \
   "$(for c in "$W/probe"/*.contract; do e=$(basename "$c" .contract); sh "$GATE" $(sed 's/^/--extern /' "$FIX/d1-helpers.txt" | tr '\n' ' ') "$W/probe/$e.o" "spinel_core_$e" > /dev/null 2>&1 || echo "$e"; done | wc -l | tr -d ' ')" 0
# At 32 bits only core_fixed_div calls the helper (decision 0019, revised
# 2026-10-21); the 64-bit / and % of p_div, p_mod, p_div_c, p_mod_c and
# p_put_dec did before it.
ok "control: without the list core_fixed_div's entry fails the gate" \
   "$(for e in p_fixed_div; do sh "$GATE" "$W/probe/$e.o" "spinel_core_$e" > /dev/null 2>&1 || echo "$e"; done | wc -l | tr -d ' ')" 1

# ---------------------------------------------------------------------------
echo "cross: 7. the wrapper's descriptor checks with 32-bit pointers"
NODE_BIN=${NODE:-node}
WASM_LD_BIN=${WASM_LD:-$BIN/wasm-ld}
# A linker that is there but cannot run (a shared library it needs is
# missing) is as absent as one that is not: it is asked for its version, and
# what it said is in the skip's reason.
if ! command -v "$NODE_BIN" > /dev/null 2>&1; then
  skipped "the wrapper's cases on wasm32 (no node at '$NODE_BIN')"
elif ! wasm_ld_said=$("$WASM_LD_BIN" --version 2>&1); then
  skipped "the wrapper's cases on wasm32 ($WASM_LD_BIN does not run: $(printf '%s' "$wasm_ld_said" | head -1))"
else
  KERNEL="$KERNEL" SPINEL_TYPEDUMP="$READER" CLANG="$CC_BIN" NODE="$NODE_BIN" WASM_LD="$WASM_LD_BIN" \
    "$RUBY" "$ROOT/tests/app/wrapper32.rb" > "$W/wrapper32.out" 2>&1 && rc=0 || rc=$?
  sed 's/^/  /' "$W/wrapper32.out"
  ok "tests/app/wrapper32.rb" \
     "$rc:$(awk '/^wrapper32: [0-9]+ checked, / && $2 == $4 && $6 == "0" { n++ } END { print n + 0 }' "$W/wrapper32.out")" "0:1"
fi
WF="$ROOT/tests/app/fixtures/cross/wrapper"
build pair_u8 "$WF" "$W/pair_u8.o" || die "pair_u8 did not build for $TARGET; see $W/pair_u8.o.log"
wrapper_ops() { # object symbol: "sbc adc" counted in that function's disassembly
  "$BIN/llvm-objdump" -d --no-show-raw-insn "$1" |
    awk -v f="<$2>:" '$2 == f { on = 1; next } on && /^$/ { exit }
      on { op = $2; sub(/\.w$/, "", op); if (op ~ /^sbcs?$/) s++; if (op ~ /^adcs?$/) a++ }
      END { print (s + 0) " " (a + 0) }'
}
ok "the thumbv8m wrapper of two buffers: two sbc (the size checks) and no adc" \
   "$(wrapper_ops "$W/pair_u8.o" spinel_core_pair_u8)" "2 0"
# A 32-bit body's index check is one unsigned 32-bit compare against the bound
# min(count, 2^31) (decision 0022 section 3): at_u8's only sbc is its wrapper's
# size check, where a 64-bit index compare would add one.
build at_u8 "$WF" "$W/at_u8.o" || die "at_u8 did not build for $TARGET; see $W/at_u8.o.log"
ok "the thumbv8m at_u8: one sbc (the wrapper's size check) and no adc; the index check is 32-bit" \
   "$(wrapper_ops "$W/at_u8.o" spinel_core_at_u8)" "1 0"

# ---------------------------------------------------------------------------
echo
if [ -n "$skips" ]; then printf 'cross: skipped:\n%s' "$skips"; fi
if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -gt 0 ]; then
  echo "cross: REQUIRE_ALL=1 and $skip check(s) did not run"
  fail=$((fail + skip))
fi
echo "cross: $((pass + fail)) checked, $pass pass, $fail fail, $skip skipped"
[ "$fail" = 0 ] || exit 1
