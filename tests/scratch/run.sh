#!/bin/sh
# tests/scratch/run.sh -- decision 0041 stage 2: one bounded data stack per
# context, for arrays that stay in their method (`scratch <bytes>`,
# `Core::Buffer.i32(n, v)` since decision 0045, `a[i]`, CAPACITY when the
# region is short).
#
#   sh tests/scratch/run.sh
#
#   1. The kernel, on the host. kernel/work.rb under version 2 contracts with
#      `scratch 256` (tick, and tick2 whose size comes from its caller) is
#      built for this host and driven by kernel/host.c: the hand-written
#      values, CAPACITY one element past the region, BOUNDS for a negative
#      size and for an index past the end, the region free again after each
#      failure (offset 0), the 64 bytes after the region unchanged, and
#      ARGUMENT for a null region.
#   2. The kernel for thumbv8m: tick2 with i32 buffers (work32.rb, whose
#      buffer is Core::Buffer.i32) is an object with no undefined symbol, and
#      work.rb's Core::Buffer.i64 is refused there with array-element.
#   3. The kernel's report: kernel/outer.rb, every size constant, is
#      static_proof with worst_bytes 72 against 256 bytes, and refused with
#      scratch-capacity against 72; tick2 is runtime_guard.
#   4. An array's size (the review): size.rb, whose loop starts at the
#      size the caller chose, is bounded at 3263, above what out[0] = 1 runs
#      (3132); sizeany.rb, a count that rises and falls with the size, is
#      unknown; huge.rb's 2^60 elements are refused, the total saturating
#      rather than wrapping; room.rb's 31 elements fill the region exactly
#      (static_proof, 248 bytes) and room32.rb's 32 are refused. sameline.rb's
#      two default-fill buffers on one line are built (static_proof, 24 bytes),
#      as is quoted.rb, whose buffer-call text is in a heredoc, a %q and a string.
#   5. Each kernel/reject/*.rb in kernel-reject.tsv is refused with its code
#      at its position and writes no object; arraynew's refusal suggests its
#      Core::Buffer, and table's and element's name the class (decision 0045).
#      parse.rb's and badcount.rb's parse errors name the columns written:
#      a source Prism cannot parse is not rewritten.
#   6. Applications. array, pair and capfull are admitted; each
#      reject/*.rb in app-reject.tsv is refused with its code, arraynew's
#      suggesting Core::Buffer.i32(n, 2). pair's reports
#      are static_proof with worst_bytes 12 for both entries, array's
#      runtime_guard. On the host, array's payloads decode to its expect.txt
#      and capfull fails with its declared CAPACITY at release 1. samename
#      (the review) has an unused method named make, as the host
#      model's own Scratch#make is, and still fails with CAPACITY at
#      release 1. wide has an :i64 state and a 32-bit body: its kernel
#      report has 3 elements in 16 bytes, and on the host its 3 elements
#      fit and out[0] is 21. int64 declares a 64-bit body (decision 0019):
#      listed in a table of the suite's own, its 8-byte element holds 2^40;
#      under this tree's table run-host refuses it by name, as the build
#      does; narrow, its 32-bit twin, fails with ARITHMETIC. narrow spelled
#      Core::Buffer.i64 is refused by run-host with array-element, as the build
#      refuses it. capfull run through a symbolic link to its directory
#      still fails with CAPACITY at release 1.
#   7. When the Zephyr environment is present, array, pair and capfull are
#      built for mps2_an521 and run under the QEMU named in build.json:
#      array's and pair's frames decode to their expect.txt (pair's 1120 says
#      an interrupt entry made its own array between two writes of the
#      thread entry's, and the thread's array is intact), the map holds
#      .bss.spc_scratch_thread, and capfull, built with --failure-sites,
#      prints SPC_FAILURE_SITE for tick with CAPACITY (4).
#
# Every value is written by hand; nothing is compared with CRuby.
# KERNEL, SPINEL_TYPEDUMP, CLANG (or LLVM_PREFIX), NM and RUBY select the
# tools. Part 7 needs ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR and west on PATH;
# without them its checks are skipped by name. QEMU_WAIT (seconds, default
# 20) bounds each QEMU run. Exit 0 when everything passed, 1 on any failure,
# 2 when only skips remain.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/tests/scratch"
BOARD="$ROOT/tests/app/fixtures/synthetic-board"
TOOL="$ROOT/tools/app/bin/spinel-core-app"
RUBY=${RUBY:-ruby}
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else echo "run.sh: set CLANG or LLVM_PREFIX" >&2; exit 2; fi
NM_BIN=${NM:-$(dirname "$CC_BIN")/llvm-nm}
QEMU_WAIT=${QEMU_WAIT:-20}
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
SC=$(mktemp -d "${TMPDIR:-/tmp}/scratch.XXXXXX")
trap 'rm -rf "$SC"' EXIT INT TERM

pass=0; fail=0; skip=0
ok() {  # name got want
  if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass + 1))
  else echo "FAIL  $1"; echo "      got:  $(printf '%s' "$2" | head -c 400 | tr '\n' '|')"
       echo "      want: $(printf '%s' "$3" | head -c 400 | tr '\n' '|')"; fail=$((fail + 1)); fi
}
skipped() { echo "SKIP  $1"; skip=$((skip + 1)); }
want() { tr '\n' ' ' < "$HERE/$1/expect.txt"; }
ZERO=0000000000000000000000000000000000000000000000000000000000000000

# contract name root entry scratch(bytes or -) element params...
contract() {
  c="$SC/k/$1.contract"; shift
  { echo "core-contract 2"; echo "root $1"; echo "entry $2"; echo "context thread"; echo "result none"
    [ "$3" = - ] || echo "scratch $3"
    el=$4; shift 4
    for p in "$@"; do echo "param $p buffer $el inout count const 1"; done; } > "$c"
}
kernel() {  # name [kernel options...]
  n=$1; shift
  "$KERNEL" "$SC/k/$n.contract" --root "$SC/k" -o "$SC/k/$n.o" --clang "$CC_BIN" --typedump "$READER" "$@" \
    > "$SC/k/$n.log" 2>&1
}
report() {  # name -> evidence:worst_bytes
  "$RUBY" -rjson -e 's = JSON.parse(File.read(ARGV[0])).dig("application", "scratch") || {}
    puts "#{s["evidence"]}:#{s["worst_bytes"].inspect}"' "$1"
}
REPORT_ARGS="--profile realtime --config-binding $ZERO:$ZERO:$ZERO"

mkdir -p "$SC/k"
cp "$HERE"/kernel/*.rb "$HERE"/kernel/reject/*.rb "$SC/k/"

echo "== the kernel on the host"
contract tick work.rb tick 256 i64 out
contract tick2 work.rb tick2 256 i64 inp out
if kernel tick --header "$SC/k/tick.h" && kernel tick2 --header "$SC/k/tick2.h" --report "$SC/k/tick2.json" $REPORT_ARGS; then
  if "$CC_BIN" -std=c11 -I"$SC/k" "$HERE/kernel/host.c" "$SC/k/tick.o" "$SC/k/tick2.o" -o "$SC/k/host" > "$SC/k/host.log" 2>&1; then
    "$SC/k/host" > "$SC/k/host.out" 2>&1
    rc=$?
    sed 's/^/      /' "$SC/k/host.out"
    ok "kernel/host.c: every case as written, the offset 0 and the canary whole after each" \
       "$rc:$(grep -c '^FAIL' "$SC/k/host.out"):$(grep -c '^PASS' "$SC/k/host.out")" "0:0:9"
  else
    ok "kernel/host.c links with tick and tick2" "$(tail -3 "$SC/k/host.log")" "(linked)"
  fi
  ok "tick2's report: runtime_guard, no worst bytes" "$(report "$SC/k/tick2.json")" "runtime_guard:nil"
else
  ok "work.rb's tick and tick2 are built" "$(tail -3 "$SC/k/tick.log" "$SC/k/tick2.log")" "(built)"
fi

echo "== the kernel for thumbv8m"
contract t32 work32.rb tick2 256 i32 inp out
contract t32w work.rb tick2 256 i32 inp out
if kernel t32 --layout ptr32-i64-32long -- --target=thumbv8m.main-none-eabi -mcpu=cortex-m33 -mthumb; then
  ok "tick2 for thumbv8m: no undefined symbol, spinel_core_tick2 defined" \
     "$("$NM_BIN" -u "$SC/k/t32.o" | wc -l | tr -d ' '):$("$NM_BIN" "$SC/k/t32.o" | grep -c ' T spinel_core_tick2$')" "0:1"
else
  ok "tick2 is built for thumbv8m" "$(tail -3 "$SC/k/t32.log")" "(built)"
fi
kernel t32w --layout ptr32-i64-32long -- --target=thumbv8m.main-none-eabi -mcpu=cortex-m33 -mthumb
ok "work.rb's Core::Buffer.i64 at 32 bits is refused with array-element, naming i64 and i32" \
   "$?:$(grep -c 'not-eligible: array-element: Core::Buffer.i64 in a body of 32-bit Integers; .*Core::Buffer.i32 (.*/work.rb:22:6)$' "$SC/k/t32w.log"):$([ -e "$SC/k/t32w.o" ] && echo written)" "1:1:"

echo "== the kernel's report"
contract outer outer.rb outer 256 i64 out
contract outer72 outer.rb outer 72 i64 out
if kernel outer --report "$SC/k/outer.json" $REPORT_ARGS; then
  ok "outer: static_proof, worst 72 bytes against 256" "$(report "$SC/k/outer.json")" "static_proof:72"
else
  ok "outer is built" "$(tail -3 "$SC/k/outer.log")" "(built)"
fi
kernel outer72 --report "$SC/k/outer72.json" $REPORT_ARGS
ok "outer against 72 bytes is refused with scratch-capacity, naming 72 and 64" \
   "$?:$(grep -c 'not-eligible: scratch-capacity: its worst call path holds up to 72 bytes .* has 64 (72 declared' "$SC/k/outer72.log"):$([ -e "$SC/k/outer72.o" ] && echo written)" "1:1:"

echo "== an array's size, and the region's room"
# The review of 0041 stage 2. A size the caller chooses is only known
# to lie in [0, 31]: each count takes its worst end of that range, or is
# unknown when it moves both ways. A constant total is exact, saturates
# rather than wraps, and is refused past the room.
loops() {  # report -> verdict:work:term reasons
  "$RUBY" -rjson -e 'l = JSON.parse(File.read(ARGV[0]))["properties"]["loop_bound"]
    puts "#{l["verdict"]}:#{l["work_bound"]["expression"]}:#{l["work_bound"]["terms"].map { |t| t["reason"] }.compact.join(",")}"' "$1"
}
contract size size.rb tick 256 i64 out
contract sizeany sizeany.rb tick 256 i64 out
contract huge huge.rb tick 256 i64 out
contract room room.rb tick 256 i64 out
contract room32 room32.rb tick 256 i64 out
if kernel size --report "$SC/k/size.json" $REPORT_ARGS; then
  # the fill 31, the loop from a.size at a.size = 0, 32, and 32 x 100 inside
  ok "size.rb: pass, work 3263 (out[0] = 1 runs 3132)" "$(loops "$SC/k/size.json")" "pass:3263:"
else
  ok "size.rb is built" "$(tail -3 "$SC/k/size.log")" "(built)"
fi
if kernel sizeany --report "$SC/k/sizeany.json" $REPORT_ARGS; then
  ok "sizeany.rb: unknown, the term named array-size" "$(loops "$SC/k/sizeany.json")" "unknown::array-size"
else
  ok "sizeany.rb is built" "$(tail -3 "$SC/k/sizeany.log")" "(built)"
fi
contract sameline sameline.rb tick 256 i64 out
if kernel sameline --report "$SC/k/sameline.json" $REPORT_ARGS; then
  ok "sameline.rb, two default fills on one line: built, static_proof, worst 24 bytes" "$(report "$SC/k/sameline.json")" "static_proof:24"
else
  ok "sameline.rb is built" "$(tail -3 "$SC/k/sameline.log")" "(built)"
fi
contract quoted quoted.rb tick 256 i64 out
kernel quoted
ok "quoted.rb, buffer-call text in a heredoc (after =begin), a %q and a string: built" "$?:$(tail -1 "$SC/k/quoted.log")" "0:spinel-core-kernel: wrote $SC/k/quoted.o"
kernel huge
ok "huge.rb (2^60 elements) is refused with scratch-capacity, past 2^63 - 1" \
   "$?:$(grep -c 'not-eligible: scratch-capacity: its worst call path holds more than 2^63 - 1 bytes' "$SC/k/huge.log"):$([ -e "$SC/k/huge.o" ] && echo written)" "1:1:"
if kernel room --report "$SC/k/room.json" $REPORT_ARGS; then
  ok "room.rb, 31 elements: static_proof, worst 248 bytes, the whole room" "$(report "$SC/k/room.json")" "static_proof:248"
else
  ok "room.rb is built" "$(tail -3 "$SC/k/room.log")" "(built)"
fi
kernel room32
ok "room32.rb, 32 elements, is refused with scratch-capacity, 256 against 248" \
   "$?:$(grep -c 'not-eligible: scratch-capacity: its worst call path holds up to 256 bytes .* has 248 (256 declared' "$SC/k/room32.log"):$([ -e "$SC/k/room32.o" ] && echo written)" "1:1:"

echo "== kernel refusals"
tab=$(printf '\t')
while IFS="$tab" read -r f code pos; do
  case $f in ''|'#'*) continue ;; esac
  n=rej-${f%.rb}
  case $f in
    missing.rb) contract "$n" "$f" tick - i64 out ;;
    v1.rb) printf 'core-contract 1\nroot %s\nentry tick\nresult i64\nparam out buffer i64 inout count n_out\nparam n_out scalar u64\n' \
             "$f" > "$SC/k/$n.contract" ;;
    *) contract "$n" "$f" tick 256 i64 out ;;
  esac
  kernel "$n"
  ok "$f is refused with $code at $pos" \
     "$?:$(grep -c "not-eligible: $code: .*/$f:$pos)\$" "$SC/k/$n.log"):$([ -e "$SC/k/$n.o" ] && echo written)" "1:1:"
done < "$HERE/kernel-reject.tsv"
# A source with a parse error is not rewritten (the review), so the
# reader's own diagnostics stand: parse.rb's are at 1:48 and 1:50, as the raw
# reader says, not at the copy's 1:51 and 1:53; badcount.rb's broken count is
# 2:27, an unexpected ')', and no comma the rewrite would have added.
contract parse parse.rb tick 256 i64 out
kernel parse
ok "parse.rb's parse errors are at 1:48 and 1:50, the columns written" \
   "$?:$(grep -c ':1:48: expected an expression after' "$SC/k/parse.log"):$(grep -c ":1:50: unexpected ')'" "$SC/k/parse.log"):$(grep -c ':1:5[13]: ' "$SC/k/parse.log")" "1:1:2:0"
contract badcount badcount.rb tick 256 i64 out
kernel badcount
ok "badcount.rb's broken count is 2:27, an unexpected ')', and no comma" \
   "$?:$(grep -c ":2:27: unexpected ')'" "$SC/k/badcount.log"):$(grep -ci comma "$SC/k/badcount.log")" "1:1:0"
words() {  # name words -> how many refusal lines hold the words
  grep -F 'not-eligible: ' "$SC/k/rej-$1.log" | grep -cF "$2"; }
ok "arraynew's refusal suggests its rewrite" \
   "$(words arraynew '`a = Array.new(2, 5)`: a scratch array is `a = Core::Buffer.i64(2, 5)`')" 1
ok "nofill's suggests Core::Buffer.i64(2)" "$(words nofill '`a = Core::Buffer.i64(2)`')" 1
ok "element's names Core::Buffer.i32 and the body's i64" \
   "$(words element 'Core::Buffer.i32 in a body of 64-bit Integers; a scratch array')" 1
ok "table's names Core::Table.i64" "$(words table 'Core::Table.i64 is an instrument')" 1
ok "push's says Core::Buffer has no push" "$(words push 'Core::Buffer has no push')" 1
# the scratch route's own refusals say Core::Buffer; "scratch array" and the
# refused Array.new are the only arrays they name
ok "no scratch refusal calls a buffer an array" \
   "$(cat "$SC"/k/rej-*.log | grep -E 'not-eligible: (array|scratch)-[a-z]*: ' | sed -e 's/not-eligible: [a-z-]*: //' -e 's/scratch array//g' -e 's/Array\.new//g' -e 's/ ([^()]*:[0-9]*:[0-9]*)$//' | grep -ci array)" 0

echo "== applications: admission and the host"
decode_enq() { awk -F '\t' '$2 == "ENQ" { sub(/^payload=/, "", $NF); print $NF }' "$1" |
  "$RUBY" -e 'puts $stdin.read.split.map { |h| [h].pack("H*").unpack1("l<") }.join(" ")'; }
admit() {  # app out
  "$RUBY" "$TOOL" admit --app "$1" --board "$BOARD/board.rb" --board-tsv "$BOARD/board.tsv" \
    --out "$2" --kernel "$KERNEL" --clang "$CC_BIN" --typedump "$READER" > "$2.log" 2>&1
}
for c in "array 1 tick" "pair 2 tick, beat" "capfull 1 tick" "samename 1 tick" "wide 1 tick"; do
  d=${c%% *}; rest=${c#* }; k=${rest%% *}; names=${rest#* }
  admit "$HERE/$d/app.rb" "$SC/adm-$d"
  ok "$d is admitted" "$?:$(tail -1 "$SC/adm-$d.log")" "0:admitted $k entr$([ "$k" = 1 ] && echo y || echo ies): $names"
done
ok "pair's reports: static_proof, worst 12 bytes, for tick and beat" \
   "$(report "$SC/adm-pair/reports/tick.json") $(report "$SC/adm-pair/reports/beat.json")" "static_proof:12 static_proof:12"
ok "array's report: runtime_guard" "$(report "$SC/adm-array/reports/tick.json")" "runtime_guard:nil"
ok "wide's report (an :i64 state, a 32-bit body): 3 elements in 16 bytes, static_proof at 12" \
   "$("$RUBY" -rjson -e 's = JSON.parse(File.read(ARGV[0]))["application"]["scratch"]
      puts "#{s["elements"]}:#{s["evidence"]}:#{s["worst_bytes"]}"' "$SC/adm-wide/reports/tick.json")" "3:static_proof:12"
while IFS="$tab" read -r f code; do
  case $f in ''|'#'*) continue ;; esac
  admit "$HERE/reject/$f" "$SC/rej-${f%.rb}"
  ok "reject/$f is refused with $code" \
     "$?:$(grep -E "/$f:[0-9]+(:[0-9]+)?: $code: " "$SC/rej-${f%.rb}.log" | head -1 | grep -c .)" "1:1"
done < "$HERE/app-reject.tsv"
ok "reject/arraynew.rb's refusal suggests Core::Buffer.i32(n, 2)" \
   "$(grep -cF '`a = Array.new(n, 2)`: a scratch array is `a = Core::Buffer.i32(n, 2)`' "$SC/rej-arraynew.log")" 1
host() {  # name [run-host options...]
  _n=$1; shift
  rm -f "$SC/$_n.trace"
  "$RUBY" "$TOOL" run-host --app "$HERE/$_n/app.rb" --board "$BOARD/board.rb" --board-host "$BOARD/board_host.rb" \
    --stimulus "$HERE/$_n/stimulus.tsv" --trace "$SC/$_n.trace" "$@" > "$SC/$_n.sum" 2>&1
}
host array
ok "array on the host: rc 0, no failure, payloads $(want array)" \
   "$?:$(grep -c 'failures as declared: 0' "$SC/array.sum"):$(decode_enq "$SC/array.trace") " "0:1:$(want array)"
host capfull
ok "capfull on the host: rc 0, the declared CAPACITY at release 1 and no other failure" \
   "$?:$(grep -c 'failures as declared: 1' "$SC/capfull.sum"):$(grep -c "$(printf 'FAIL\t0\t0\tstatus=4\trelease=1')" "$SC/capfull.trace")" "0:1:1"

host samename
ok "samename on the host (an unused method named make): the declared CAPACITY at release 1" \
   "$?:$(grep -c 'failures as declared: 1' "$SC/samename.sum"):$(grep -c "$(printf 'FAIL\t0\t0\tstatus=4\trelease=1')" "$SC/samename.trace")" "0:1:1"
host wide
ok "wide on the host: rc 0, no failure, out[0] = 21 as an i64 at both releases" \
   "$?:$(grep -c 'failures as declared: 0' "$SC/wide.sum"):$(grep -c "$(printf 'PRIVATE\t0\t0\tstate=0\tbytes=8\tpayload=1500000000000000')" "$SC/wide.trace")" "0:1:2"
# The body's width as the build has it (decision 0019): int64 declares a
# 64-bit body, listed here in a table of the suite's own, so 2^40 fits its
# 8-byte element; this tree's table does not list it, and run-host refuses
# it by name as the build does; narrow, its 32-bit twin, fails with
# ARITHMETIC storing 2^40 in an i32 element.
mkdir -p "$SC/t/tools/core" "$SC/t/int64"
cp "$HERE/int64/app.rb" "$SC/t/int64/app.rb"
printf 'int64/app.rb\tthe host model at 64 bits (tests/scratch)\n' > "$SC/t/tools/core/int64-allow.tsv"
host int64 --mutate-int64-allow "$SC/t/tools/core/int64-allow.tsv"
ok "int64, listed: rc 0, no failure, out[0] = 2^40 at both releases" \
   "$?:$(grep -c 'failures as declared: 0' "$SC/int64.sum"):$(grep -c "$(printf 'PRIVATE\t0\t0\tstate=0\tbytes=8\tpayload=0000000000010000')" "$SC/int64.trace")" "0:1:2"
host int64
ok "int64 under this tree's table is refused by name before any release" \
   "$?:$(grep -c '^spinel-core-app: .*/int64/app.rb:1: int-width-int64-refused: ' "$SC/int64.sum"):$([ -s "$SC/int64.trace" ] && echo traced)" "1:1:"
host narrow
ok "narrow, its 32-bit twin: the declared ARITHMETIC at release 1" \
   "$?:$(grep -c 'failures as declared: 1' "$SC/narrow.sum"):$(grep -c "$(printf 'FAIL\t0\t0\tstatus=2\trelease=1')" "$SC/narrow.trace")" "0:1:1"
# The model is the application's own file however it is named: capfull
# reached through a symbolic link to its directory still fails with the
# declared CAPACITY at release 1 (the coordinator, 0045; the run-host paths are
# compared resolved).
ln -s "$HERE/capfull" "$SC/linked"
"$RUBY" "$TOOL" run-host --app "$SC/linked/app.rb" --board "$BOARD/board.rb" --board-host "$BOARD/board_host.rb" \
  --stimulus "$SC/linked/stimulus.tsv" --trace "$SC/linked.trace" > "$SC/linked.sum" 2>&1
ok "capfull through a symbolic link: the declared CAPACITY at release 1" \
   "$?:$(grep -c 'failures as declared: 1' "$SC/linked.sum"):$(grep -c "$(printf 'FAIL\t0\t0\tstatus=4\trelease=1')" "$SC/linked.trace")" "0:1:1"
# decision 0045: the element name is the body's width on the host too
# (a physical path: the model is applied only to the application's own
# file, which it names unresolved, and macOS's TMPDIR is behind a symlink)
WRONG=$(cd "$SC" && pwd -P)/wrong
mkdir -p "$WRONG"
sed 's/Core::Buffer\.i32(/Core::Buffer.i64(/' "$HERE/narrow/app.rb" > "$WRONG/app.rb"
"$RUBY" "$TOOL" run-host --app "$WRONG/app.rb" --board "$BOARD/board.rb" --board-host "$BOARD/board_host.rb" \
  --stimulus "$HERE/narrow/stimulus.tsv" --trace "$SC/wrong.trace" > "$SC/wrong.sum" 2>&1
ok "narrow spelled Core::Buffer.i64 is refused by run-host with array-element" \
   "$?:$(grep -c '/wrong/app.rb:[0-9]*: array-element: Core::Buffer.i64 in a body of 32-bit Integers' "$SC/wrong.sum")" "1:1"

echo "== mps2_an521 under QEMU"
if [ -z "${ZEPHYR_BASE:-}" ] || [ -z "${ZEPHYR_SDK_INSTALL_DIR:-}" ] || ! command -v west > /dev/null 2>&1; then
  skipped "array, pair and capfull on mps2_an521 (ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR or west missing)"
else
  build() {  # name [flag]
    KERNEL=$KERNEL SPINEL_TYPEDUMP=$READER CLANG=$CC_BIN \
      "$RUBY" "$TOOL" build --app "$HERE/$1/app.rb" --board mps2_an521 --out "$SC/fw-$1" ${2:+"$2"} > "$SC/fw-$1.log" 2>&1
  }
  qemu() {  # name test-to-stop-on
    q=$("$RUBY" -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["qemu"].to_s' "$SC/fw-$1/firmware/build.json")
    [ -n "$q" ] && [ -x "$q" ] || return 1
    "$q" -cpu cortex-m33 -machine mps2-an521 -m 16 -vga none -net none -nographic -icount shift=7,align=off,sleep=off -rtc clock=vm \
      -chardev stdio,id=con,mux=on -serial chardev:con -mon chardev=con,mode=readline -chardev null,id=hostS0 -serial chardev:hostS0 \
      -kernel "$SC/fw-$1/firmware/zephyr.elf" < /dev/null > "$SC/$1.console" 2>&1 &
    qpid=$!
    i=0
    while [ "$i" -lt "$QEMU_WAIT" ] && ! "$2" "$1"; do sleep 1; i=$((i + 1)); done
    kill "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null
    return 0
  }
  # frames are 0xA5, channel, length, payload; the 4-byte ones, as i32
  frames() { "$RUBY" -e 'b = File.binread(ARGV[0]).bytes; v = []; i = 0
    while i + 7 <= b.size
      if b[i] == 0xA5 && b[i + 2] == 4 then v << b[i + 3, 4].pack("C*").unpack1("l<"); i += 7 else i += 1 end
    end
    puts v.join(" ")' "$SC/$1.console"; }
  all_frames() { [ "$(frames "$1" | wc -w)" -ge "$(wc -w < "$HERE/$1/expect.txt")" ]; }
  site_line() { grep -aq SPC_FAILURE_SITE "$SC/$1.console"; }
  for d in array pair; do
    if ! build "$d"; then
      ok "$d builds for mps2_an521" "$(tail -3 "$SC/fw-$d.log")" "(built)"
    elif qemu "$d" all_frames; then
      ok "$d under QEMU: SPC_RUNNING once, frames $(want $d)" \
         "$(grep -ac 'SPC_RUNNING app' "$SC/$d.console"):$(frames "$d") " "1:$(want $d)"
    else
      skipped "$d under QEMU (no QEMU in build.json)"
    fi
  done
  if [ -f "$SC/fw-pair/firmware/zephyr.map" ]; then
    ok "pair's image holds both regions in .bss, 64 bytes each" \
       "$("$RUBY" -e 'l = File.readlines(ARGV[0])
          puts %w[thread interrupt].map { |c| i = l.index { |x| x =~ /\A \.bss\.spc_scratch_#{c}\s*\z/ }; i ? l[i + 1].split[1].to_i(16) : "-" }.join(" ")' \
          "$SC/fw-pair/firmware/zephyr.map")" "64 64"
    ok "  and build.json reports them with the kernel's evidence" \
       "$("$RUBY" -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["scratch"].map { |s|
          "#{s["context"]}:#{s["bytes"]}:" + s["entries"].map { |e, v| "#{e}=#{v["evidence"]}/#{v["worst_bytes"]}" }.join(",") }.join(" ")' \
          "$SC/fw-pair/firmware/build.json")" "thread:64:tick=static_proof/12 interrupt:64:beat=static_proof/12"
  fi
  if ! build capfull --failure-sites; then
    ok "capfull builds for mps2_an521 with --failure-sites" "$(tail -3 "$SC/fw-capfull.log")" "(built)"
  elif qemu capfull site_line; then
    ok "capfull under QEMU: the first failure is tick's CAPACITY (status 4)" \
       "$(grep -a -o 'SPC_FAILURE_SITE [^ ]* [0-9]*' "$SC/capfull.console" | head -1)" "SPC_FAILURE_SITE tick 4"
  else
    skipped "capfull under QEMU (no QEMU in build.json)"
  fi
fi

echo "---- scratch: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ] || exit 1
[ "$skip" -eq 0 ] || exit 2
exit 0
