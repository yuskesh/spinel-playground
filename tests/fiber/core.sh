#!/bin/sh
# tests/fiber/core.sh -- the stackless Fiber of decision 0035 under CORE: the
# slot API (fiber_def, static frames, stage 2) and its Enumerator form
# (enum_def, owner 2026-11-11), and decision 0041 stage 3's slot pool
# (pool_def, owner 2026-11-14).
#
#   sh tests/fiber/core.sh
#
#   1. core/reject/*.rb in core-reject.tsv: tools/fiber/spinel-fiber-core
#      refuses each with one `FILE:LINE:COL: spinel-fiber:` diagnostic that
#      contains the listed text, and writes nothing. The rewrites of poolnest
#      (module calls nested in module calls' arguments) and poolmix (two
#      pools' helpers nested without parentheses) parse, and each tick is
#      the hand-written rewrite.txt beside it. pathcall's constant-path
#      receivers (decision 0045) are rewritten, not taken for buffers.
#   2. core/{reader,limits,unstarted,range,live,u32wide,evens,pastend,pool,
#      poolfull,pooltwice,poolnever,poolfreehi,poolfreeneg,poollivehi,
#      poolliveneg,poolnest,poolmix}: `spinel-core-app admit` takes the
#      rewritten application through the kernel (the hook in spinel-core-app),
#      and `run-host` runs the original under CRuby with the host reference
#      (tools/app/lib/spinel/core.rb, real Fibers and Enumerators, and the
#      pool's own model). The channel payloads of reader, limits, evens
#      (next?, peek, next, the end, a restart), pool (alloc, free, reuse),
#      poolnest and poolmix must decode to their expect.txt, written by hand
#      (limits carries the i32 limits across a suspension); each misuse
#      fixture's stimulus declares its BOUNDS (status 3) failure, and
#      poolfull's the CAPACITY (status 4) of its third alloc, and the runner
#      fails a run whose failures differ. u32wide is not run on the host:
#      CRuby's Integer holds 2^31 there, as it does without a fiber.
#   3. When the Zephyr environment is present: reader, limits, evens, pool,
#      poolnest, poolmix, unstarted, u32wide, pastend, poolfull and pooltwice
#      are built for mps2_an521 and run under the QEMU named in build.json.
#      The UART frames of reader, limits, evens, pool, poolnest and poolmix
#      must decode to their expect.txt; unstarted, u32wide, pastend (next
#      past the end), poolfull and pooltwice, built with --failure-sites,
#      must print SPC_FAILURE_SITE for
#      tick with BOUNDS (3), ARITHMETIC (2), BOUNDS, CAPACITY (4) and BOUNDS:
#      the 32-bit arithmetic that would make 2^31 fails before any frame
#      field could hold it.
#
# KERNEL, SPINEL_TYPEDUMP, CLANG (or LLVM_PREFIX) and RUBY select the tools.
# Part 3 needs ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR and west on PATH; without
# them its checks are skipped by name. QEMU_WAIT (seconds, default 20) bounds
# each QEMU run. Exit 0 when everything passed, 1 on any failure, 2 when only
# skips remain.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/tests/fiber/core"
BOARD="$ROOT/tests/app/fixtures/synthetic-board"
TOOL="$ROOT/tools/app/bin/spinel-core-app"
CORE="$ROOT/tools/fiber/spinel-fiber-core"
RUBY=${RUBY:-ruby}
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else echo "core.sh: set CLANG or LLVM_PREFIX" >&2; exit 2; fi
QEMU_WAIT=${QEMU_WAIT:-20}
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
FW=$(mktemp -d "${TMPDIR:-/tmp}/fiber-core.XXXXXX")
trap 'rm -rf "$FW"' EXIT INT TERM

pass=0; fail=0; skip=0
ok() {  # name got want
  if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass + 1))
  else echo "FAIL  $1"; echo "      got:  $(printf '%s' "$2" | head -c 400 | tr '\n' '|')"
       echo "      want: $(printf '%s' "$3" | head -c 400 | tr '\n' '|')"; fail=$((fail + 1)); fi
}
skipped() { echo "SKIP  $1"; skip=$((skip + 1)); }
want() { tr '\n' ' ' < "$HERE/$1/expect.txt"; }

echo "== CORE refusals"
tab=$(printf '\t')
while IFS="$tab" read -r f pos text; do
  case $f in ''|'#'*) continue ;; esac
  out="$FW/rej-${f%.rb}.rb"
  if "$RUBY" "$CORE" "$HERE/reject/$f" -o "$out" > "$out.log" 2>&1; then
    ok "$f is refused" "rewritten" "refused"
    continue
  fi
  [ ! -e "$out" ] || { ok "$f writes nothing" "written" "absent"; continue; }
  line=$(grep -F "$f:$pos: spinel-fiber: " "$out.log" | grep -F -- "$text")
  ok "$f refused once at $pos: $text" "$(grep -c . "$out.log"):${line:+found}" "1:found"
done < "$ROOT/tests/fiber/core-reject.tsv"

echo "== a composed rewrite"
# Module calls nested in module calls' arguments, helpers that gain a
# pool's states inside one, and (poolmix) two pools' helpers nested without
# parentheses: the output parses, and tick is rewritten as rewrite.txt
# says, each call once.
for d in poolnest poolmix; do
  if "$RUBY" "$CORE" "$HERE/$d/app.rb" -o "$FW/$d.rb" > "$FW/$d.rw" 2>&1; then
    ok "$d's rewrite parses" "$("$RUBY" -c "$FW/$d.rb" 2>&1)" "Syntax OK"
    ok "  and its tick is rewrite.txt" "$(sed -n '/^def tick/,/^end/p' "$FW/$d.rb" | cmp - "$HERE/$d/rewrite.txt" > /dev/null 2>&1 && echo same)" "same"
  else
    ok "$d is rewritten" "$(tail -3 "$FW/$d.rw")" "(rewritten)"
  fi
done

# Decision 0045: receivers that are constant paths, in a body and out of
# one, are not buffers; the rewrite runs and keeps each of those calls.
if "$RUBY" "$CORE" "$HERE/pathcall/app.rb" -o "$FW/pathcall.rb" > "$FW/pathcall.rw" 2>&1; then
  ok "pathcall's rewrite parses, with its three constant-path calls" \
     "$("$RUBY" -c "$FW/pathcall.rb" 2>&1):$(grep -c 'Board::Gain.scale\|::Telemetry.put' "$FW/pathcall.rb")" "Syntax OK:3"
else
  ok "pathcall is rewritten" "$(tail -3 "$FW/pathcall.rw")" "(rewritten)"
fi

echo "== admission and the host reference"
# 4-byte little-endian i32 payloads, in order, as decimal
decode_enq() { awk -F '\t' '$2 == "ENQ" { sub(/^payload=/, "", $NF); print $NF }' "$1" |
  "$RUBY" -e 'puts $stdin.read.split.map { |h| [h].pack("H*").unpack1("l<") }.join(" ")'; }
for d in reader limits unstarted range live u32wide evens pastend pool poolfull pooltwice poolnever \
         poolfreehi poolfreeneg poollivehi poolliveneg poolnest poolmix; do
  app="$HERE/$d/app.rb"
  if "$RUBY" "$TOOL" admit --app "$app" --board "$BOARD/board.rb" --board-tsv "$BOARD/board.tsv" \
       --out "$FW/adm-$d" --kernel "$KERNEL" --clang "$CC_BIN" --typedump "$READER" > "$FW/adm-$d.log" 2>&1; then
    ok "$d is admitted" "$(tail -1 "$FW/adm-$d.log")" "admitted 1 entry: tick"
  else
    ok "$d is admitted" "$(tail -3 "$FW/adm-$d.log")" "admitted 1 entry: tick"
  fi
  [ "$d" != u32wide ] || continue
  "$RUBY" "$TOOL" run-host --app "$app" --board "$BOARD/board.rb" --board-host "$BOARD/board_host.rb" \
    --stimulus "$HERE/$d/stimulus.tsv" --trace "$FW/$d.trace" > "$FW/$d.sum" 2>&1
  rc=$?
  case $d in
    reader|limits|evens|pool|poolnest|poolmix) ok "$d on the host: rc 0, no failure, payloads $(want $d)" \
              "$rc:$(grep -c 'failures as declared: 0' "$FW/$d.sum"):$(decode_enq "$FW/$d.trace") " "0:1:$(want $d)" ;;
    poolfull) ok "$d on the host: rc 0, the declared CAPACITY at release 3 and no other failure" \
          "$rc:$(grep -c 'failures as declared: 1' "$FW/$d.sum"):$(grep -c "$(printf 'FAIL\t0\t0\tstatus=4\trelease=3')" "$FW/$d.trace")" "0:1:1" ;;
    *) ok "$d on the host: rc 0, the declared BOUNDS and no other failure" \
          "$rc:$(grep -c 'failures as declared: 1' "$FW/$d.sum"):$(grep -c "$(printf 'FAIL\t0\t0\tstatus=3\t')" "$FW/$d.trace")" "0:1:1" ;;
  esac
done

echo "== mps2_an521 under QEMU"
if [ -z "${ZEPHYR_BASE:-}" ] || [ -z "${ZEPHYR_SDK_INSTALL_DIR:-}" ] || ! command -v west > /dev/null 2>&1; then
  skipped "reader and limits on mps2_an521 (ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR or west missing)"
  skipped "the BOUNDS and ARITHMETIC sites on mps2_an521 (ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR or west missing)"
else
  build() {  # name [flag]
    KERNEL=$KERNEL SPINEL_TYPEDUMP=$READER CLANG=$CC_BIN \
      "$RUBY" "$TOOL" build --app "$HERE/$1/app.rb" --board mps2_an521 --out "$FW/fw-$1" ${2:+"$2"} > "$FW/fw-$1.log" 2>&1
  }
  qemu() {  # name pattern-to-wait-for
    q=$("$RUBY" -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["qemu"].to_s' "$FW/fw-$1/firmware/build.json")
    [ -n "$q" ] && [ -x "$q" ] || return 1
    "$q" -cpu cortex-m33 -machine mps2-an521 -m 16 -vga none -net none -nographic -icount shift=7,align=off,sleep=off -rtc clock=vm \
      -chardev stdio,id=con,mux=on -serial chardev:con -mon chardev=con,mode=readline -chardev null,id=hostS0 -serial chardev:hostS0 \
      -kernel "$FW/fw-$1/firmware/zephyr.elf" < /dev/null > "$FW/$1.console" 2>&1 &
    qpid=$!
    i=0
    while [ "$i" -lt "$QEMU_WAIT" ] && ! "$2" "$FW/$1.console"; do sleep 1; i=$((i + 1)); done
    kill "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null
    return 0
  }
  # frames are 0xA5, channel, length, payload; the first five 4-byte ones
  frames() { "$RUBY" -e 'b = File.binread(ARGV[0]).bytes; v = []; i = 0
    while i + 7 <= b.size && v.size < 5
      if b[i] == 0xA5 && b[i + 2] == 4 then v << b[i + 3, 4].pack("C*").unpack1("l<"); i += 7 else i += 1 end
    end
    puts v.join(" ")' "$1"; }
  five_frames() { [ "$(frames "$1" | wc -w)" -ge 5 ]; }
  site_line() { grep -aq SPC_FAILURE_SITE "$1"; }
  if ! build reader; then
    ok "reader builds for mps2_an521" "$(tail -3 "$FW/fw-reader.log")" "(built)"
  else
    # 2 frames of 4 i32 fields (st, limit, i, got): 2 x 4 x 4 = 32 bytes
    ok "the build reports reader's frames" \
       "$(grep -c '^fiber_def :reader: 2 frame(s) x 4 i32 field(s) (st, limit, i, got), [0-9]* states, 32 bytes of state$' "$FW/fw-reader.log")" "1"
    ok "  and the linked image holds them: 4 .bss states of 8 bytes" \
       "$("$RUBY" -e 'l = File.readlines(ARGV[0]); s = l.each_index.select { |i| l[i] =~ /\A \.bss\.spc_state_sfb_reader_\w+\s*\z/ }
          puts "#{s.size}:#{s.sum { |i| l[i + 1].split[1].to_i(16) }}"' "$FW/fw-reader/firmware/zephyr.map")" "4:32"
  fi
  build limits || ok "limits builds for mps2_an521" "$(tail -3 "$FW/fw-limits.log")" "(built)"
  build evens || ok "evens builds for mps2_an521" "$(tail -3 "$FW/fw-evens.log")" "(built)"
  if ! build pool; then
    ok "pool builds for mps2_an521" "$(tail -3 "$FW/fw-pool.log")" "(built)"
  else
    # 3 slots: live and free of 3 i32 each, top of 2: (2 x 3 + 2) x 4 = 32 bytes
    ok "the build reports the pool's state" "$(grep -c '^pool_def :node: 3 slot(s), 32 bytes of state$' "$FW/fw-pool.log")" "1"
    ok "  and the linked image holds it: 3 .bss states of 32 bytes in all" \
       "$("$RUBY" -e 'l = File.readlines(ARGV[0]); s = l.each_index.select { |i| l[i] =~ /\A \.bss\.spc_state_spl_node_\w+\s*\z/ }
          puts "#{s.size}:#{s.sum { |i| l[i + 1].split[1].to_i(16) }}"' "$FW/fw-pool/firmware/zephyr.map")" "3:32"
  fi
  build poolnest || ok "poolnest builds for mps2_an521" "$(tail -3 "$FW/fw-poolnest.log")" "(built)"
  build poolmix || ok "poolmix builds for mps2_an521" "$(tail -3 "$FW/fw-poolmix.log")" "(built)"
  for d in reader limits evens pool poolnest poolmix; do
    if [ ! -f "$FW/fw-$d/firmware/zephyr.elf" ]; then :
    elif qemu "$d" five_frames; then
      ok "$d under QEMU: SPC_RUNNING once, frames $(want $d)" \
         "$(grep -ac 'SPC_RUNNING app' "$FW/$d.console"):$(frames "$FW/$d.console") " "1:$(want $d)"
    else
      skipped "$d under QEMU (no QEMU in build.json)"
    fi
  done
  for c in "unstarted 3 BOUNDS" "u32wide 2 ARITHMETIC" "pastend 3 BOUNDS" "poolfull 4 CAPACITY" "pooltwice 3 BOUNDS"; do
    set -- $c
    if ! build "$1" --failure-sites; then
      ok "$1 builds for mps2_an521 with --failure-sites" "$(tail -3 "$FW/fw-$1.log")" "(built)"
    elif qemu "$1" site_line; then
      ok "$1 under QEMU: the first failure is tick's $3 (status $2)" \
         "$(grep -a -o 'SPC_FAILURE_SITE [^ ]* [0-9]*' "$FW/$1.console" | head -1)" "SPC_FAILURE_SITE tick $2"
      [ "$1" != u32wide ] ||
        ok "  at big[0] += 1, before Reader.start (the site is a checked +)" \
           "$("$RUBY" "$ROOT/tools/doom/failure-site.rb" --firmware "$FW/fw-$1/firmware" < "$FW/$1.console" | grep -c 'ARITHMETIC: checked + ')" "1"
    else
      skipped "$1 under QEMU (no QEMU in build.json)"
    fi
  done
fi

echo "---- fiber core: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ] || exit 1
[ "$skip" -eq 0 ] || exit 2
exit 0
