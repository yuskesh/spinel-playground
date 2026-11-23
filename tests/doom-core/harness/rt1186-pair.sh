# tests/doom-core/harness/rt1186-pair.sh -- sourced by tests/doom-core/rt1186.sh
# for its part 5, after rt1186-host.sh and rt1186-gdb.sh, with the board's lock
# held: the pair's console channel counts after a demo (decision 0027 stage 2).
#
#   rt1186_pair_counts DEMO
#
# pair.rb puts each console line into the `console` channel and companion.rb
# relays it. After the run, the region's header (its first header_bytes in the
# M33's view, 0x3050_0000, tools/app/ring/ring_abi.h version 5) and the
# relay's counters (spc_state_held, spc_state_written and spc_state_malformed
# in the companion's image, the firmware's launcher.elf) are read with the
# debugger, twice in one session 100 ms apart, and tools/doom/pair-counts.rb
# judges them with the console, and reports the wait from put to get
# (line M and the get's histogram, spc_channel_console_wait_hist, converted at
# the companion's CYCLES_PER_SECOND; a measurement, from RC24M, written to
# wait-<demo>.json beside the results):
#
#   - without TICS the demo has ended: the lane waits up to RT1186_NET_DRAIN
#     seconds (rt1186-net.sh's, default 30) for two reads alike, and then the
#     four equations of 0027's Stage 2's choices must hold, each one checked;
#   - with TICS the demo is still running and putting: the counts are printed
#     as they stood, not checked as a drained total.
#
# A pair whose console channel has a doorbell (build.json's notify, decision
# 0028) must also show it working, drained or not: the M33's
# `SPC_DOORBELL console MU1 GIR0 enabled 0`, and in the header the M7's
# rings and the M33's wake-ups, rung above 0 and woken from 1 to rung (a
# ring is never repeated while GIR0 is set, so it raises one interrupt at
# most).
#
# Nothing here writes to the board.
rt1186_pair_counts() { # demo
  _d=$1
  _fw=$DIR/fw-$_d/firmware
  _elf=$_fw/launcher.elf
  _syms=$("${LLVM_BIN:-}/llvm-nm" "$_elf" 2> /dev/null | awk '$3 ~ /^spc_state_(held|written|malformed)$/ { a[$3] = $1 } END { if (a["spc_state_held"] != "" && a["spc_state_written"] != "" && a["spc_state_malformed"] != "") print a["spc_state_held"], a["spc_state_written"], a["spc_state_malformed"] }')
  _hist=$("${LLVM_BIN:-}/llvm-nm" "$_elf" 2> /dev/null | awk '$3 == "spc_channel_console_wait_hist" { print $1 }')
  _hz=$(sed -n 's/^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=//p' "$_fw/companion/config" 2> /dev/null)
  _n=$("$RUBY" -rjson -e 'puts((JSON.parse(File.read(ARGV[0])).dig("pair", "channels") || []).size)' "$_fw/build.json" 2> /dev/null)
  if [ -z "$_syms" ] || [ -z "$_n" ] || [ "$_n" = 0 ]; then
    ok "$_d: the companion carries its relay counters and build.json the pair's channels" "${_syms:-no counters}|${_n:-none}" "counters|1+"
    return 1
  fi
  set -- $_syms
  _held=$1; _written=$2; _malformed=$3
  _hb=$(( (16 + 6 * _n) * 32 )) # lines 0-15 and six a channel (version 5)
  _ended=$([ -z "${TICS:-}" ] && echo yes || echo no)
  _t0=$(date +%s)
  while :; do
    RT1186_GDB_CORE= RT1186_GDB_TAG=$_d rt_gdb_read "$RT1186_RES/pair-h1-$_d.bin" 0x30500000 "$_hb" \
      "$RT1186_RES/pair-c1h-$_d.bin" "0x$_held" 4 "$RT1186_RES/pair-c1w-$_d.bin" "0x$_written" 4 "$RT1186_RES/pair-c1m-$_d.bin" "0x$_malformed" 4 sleep 0.1 - \
      "$RT1186_RES/pair-h2-$_d.bin" 0x30500000 "$_hb" \
      "$RT1186_RES/pair-c2h-$_d.bin" "0x$_held" 4 "$RT1186_RES/pair-c2w-$_d.bin" "0x$_written" 4 "$RT1186_RES/pair-c2m-$_d.bin" "0x$_malformed" 4 \
      ${_hist:+"$RT1186_RES/pair-hist-$_d.bin" "0x$_hist" 128} \
      > "$RT1186_RES/pair_read-$_d.txt" 2>&1
    _rc=$?
    for k in 1 2; do
      cat "$RT1186_RES/pair-c${k}h-$_d.bin" "$RT1186_RES/pair-c${k}w-$_d.bin" "$RT1186_RES/pair-c${k}m-$_d.bin" > "$RT1186_RES/pair-c$k-$_d.bin" 2> /dev/null
    done
    "$RUBY" "$ROOT/tools/doom/pair-counts.rb" --header "$RT1186_RES/pair-h1-$_d.bin,$RT1186_RES/pair-h2-$_d.bin" \
      --counters "$RT1186_RES/pair-c1-$_d.bin,$RT1186_RES/pair-c2-$_d.bin" --console "$RT1186_RES/serial_$_d.log" \
      --from "$(cat "$RT1186_RES/serial_$_d.reset" 2> /dev/null || echo 0)" --build-json "$_fw/build.json" \
      ${_hz:+--consumer-hz "$_hz"} ${_hist:+--hist "$RT1186_RES/pair-hist-$_d.bin"} --wait-json "$RT1186_RES/wait-$_d.json" ${TICS:+--not-judged} > "$RT1186_RES/pair-counts-$_d.out" 2>&1
    _crc=$?
    [ "$_rc" = 0 ] && [ "$_ended" = no ] && break
    [ "$_rc" = 0 ] && [ "$_crc" = 0 ] && break
    [ $(($(date +%s) - _t0)) -ge "${RT1186_NET_DRAIN:-30}" ] && break
    sleep 1
  done
  ok "$_d: the pair's header and the relay's counters are read" "$_rc" 0
  [ "$_rc" = 0 ] || return 1
  sed 's/^/  /' "$RT1186_RES/pair-counts-$_d.out"
  _notify=$("$RUBY" -rjson -e 'c = (JSON.parse(File.read(ARGV[0])).dig("pair", "channels") || []).find { |x| x["name"] == "console" } || {}; puts c["notify"].to_i' "$_fw/build.json" 2> /dev/null)
  if [ "${_notify:-0}" != 0 ]; then
    _bell=$(tail -c +$(( $(cat "$RT1186_RES/serial_$_d.reset" 2> /dev/null || echo 0) + 1 )) "$RT1186_RES/serial_$_d.log" | LC_ALL=C tr -d '\r\000' | LC_ALL=C grep -a '^SPC_DOORBELL ' | head -1)
    ok "$_d: the M33 enabled the console channel's doorbell" "$_bell" "SPC_DOORBELL console MU1 GIR0 enabled 0"
    # rung is line P's word 5 (word 141), woken line C's (word 149), descriptor 0
    _rw=$("$RUBY" -e 'w = File.binread(ARGV[0]).unpack("V*"); r, k = w[141].to_i, w[149].to_i; puts "rung #{r} woken #{k} #{r.positive? && k.positive? && k <= r ? "wakes" : "silent"}"' "$RT1186_RES/pair-h2-$_d.bin" 2> /dev/null)
    echo "  pair $_d: doorbell ${_rw% *}"
    ok "$_d: the doorbell rings and wakes: rung above 0, woken from 1 to rung" "${_rw##* }" wakes
  fi
  if [ "$_ended" = yes ]; then
    ok "$_d: the console channel's counts close after the drain (tools/doom/pair-counts.rb)" "$_crc" 0
  else
    echo "  pair $_d: TICS=$TICS, the demo still running: the counts as they stood, not a drained total"
  fi
}
