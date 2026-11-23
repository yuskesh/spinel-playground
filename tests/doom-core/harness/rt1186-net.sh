# tests/doom-core/harness/rt1186-net.sh -- sourced by tests/doom-core/rt1186.sh
# for its part 5, after rt1186-host.sh and rt1186-gdb.sh, with the board's lock
# held: the M33 network firmware's counts after a demo (decision 0024).
#
#   rt1186_net_counts DEMO
#
# The board application's frames channel goes through the OCRAM ring to the
# M33 (tools/app/launcher as the network firmware), which forwards each
# message. Its counts (spc_net in launcher.elf, tools/app/launcher/net/forward.c)
# and the ring's header (OCRAM2's first 160 bytes in the M33's view, 0x3050_0000,
# tools/app/ring/ring_abi.h) are read with the debugger, twice in one session
# 100 ms apart:
#
#   * after the demo's end (TICS unset, the console has its `D`): the M7 puts
#     nothing more, so the counts are the run's once the ring has drained --
#     head == tail, nothing pending, nothing in a send, and both reads alike.
#     The lane waits for that, up to RT1186_NET_DRAIN seconds (default 30),
#     and then requires no send error, no fault, and every message taken to
#     be sent or (with the network file's port 0) discarded;
#   * with TICS=N the demo is still running when the console stops being
#     read, so nothing has drained: one pair of reads, which must show no send
#     error and no fault, and the counts are printed as they stood.
#
# The console must hold no SPC_RING_REFUSED line in either case.
RT1186_NET_DRAIN=${RT1186_NET_DRAIN:-30}

# the 13 words of spc_net and the ring's words 16 (head), 24 (tail), 9
# (consumer_state), 8 (boot_id), from the files of one read
rt1186_net_words() { # counts.bin ring.bin
  printf '%s %s\n' "$(od -A n -t u4 -v "$1" | tr -s ' \n' '  ')" \
    "$(od -A n -t u4 -v -j 64 -N 4 "$2" | tr -d ' ') $(od -A n -t u4 -v -j 96 -N 4 "$2" | tr -d ' ') $(od -A n -t u4 -v -j 36 -N 4 "$2" | tr -d ' ') $(od -A n -t u4 -v -j 32 -N 4 "$2" | tr -d ' ')"
}

rt1186_net_counts() { # demo
  _d=$1
  _elf=$DIR/fw-$_d/firmware/launcher.elf
  _addr=$("${LLVM_BIN:-}/llvm-nm" "$_elf" 2> /dev/null | awk '$3 == "spc_net" { print $1 }')
  if [ -z "$_addr" ]; then
    ok "$_d: the M33's network firmware carries its counts (spc_net in launcher.elf)" "none" "spc_net"
    return 1
  fi
  _log=$RT1186_RES/serial_$_d.log
  ok "$_d: the console holds no SPC_RING_REFUSED" "$(tail -c +$(($(cat "$RT1186_RES/serial_$_d.reset" 2> /dev/null || echo 0) + 1)) "$_log" | LC_ALL=C grep -a -c SPC_RING_REFUSED)" 0
  _ended=$([ -z "${TICS:-}" ] && echo yes || echo no)
  _t0=$(date +%s)
  while :; do
    RT1186_GDB_CORE= RT1186_GDB_TAG=$_d rt_gdb_read "$RT1186_RES/net1-$_d.bin" "0x$_addr" 52 "$RT1186_RES/ring1-$_d.bin" 0x30500000 160 sleep 0.1 - \
      "$RT1186_RES/net2-$_d.bin" "0x$_addr" 52 "$RT1186_RES/ring2-$_d.bin" 0x30500000 160 > "$RT1186_RES/net_read-$_d.txt" 2>&1
    _rc=$?
    _a=$(rt1186_net_words "$RT1186_RES/net1-$_d.bin" "$RT1186_RES/ring1-$_d.bin" 2> /dev/null)
    _b=$(rt1186_net_words "$RT1186_RES/net2-$_d.bin" "$RT1186_RES/ring2-$_d.bin" 2> /dev/null)
    # magic errors taken sent discarded retries pending in_send fault boot state dhcp_ms tail | head tail consumer_state boot
    set -- $_b
    [ "$_rc" = 0 ] && [ "$_ended" = no ] && break
    [ "$_rc" = 0 ] && [ "$_a" = "$_b" ] && [ "${14:-x}" = "${15:-y}" ] && [ "$7" = 0 ] && [ "$8" = 0 ] && break
    [ $(($(date +%s) - _t0)) -ge "$RT1186_NET_DRAIN" ] && break
    sleep 1
  done
  ok "$_d: the M33's counts are read (spc_net, magic SPNC)" "$_rc|${1:-none}" "0|1129205843"
  [ "$_rc" = 0 ] || return 1
  echo "  net $_d: taken $3 sent $4 discarded $5 errors $2 retries $6 pending $7 in_send $8 fault $9 state ${11} boot $(printf '%08x' "${10}") head ${14} tail ${15} consumer ${16} dhcp ${12} ms"
  ok "$_d: no send error and no fault on the M33 (spc_transport_udp_errors, spc_net.fault)" "$2|$9|${11}" "0|0|1"
  if [ "$_ended" = yes ]; then
    ok "$_d: the ring drained: head == tail, nothing pending or in a send, two reads 100 ms apart alike" \
       "$([ "${14}" = "${15}" ] && echo drained)|$7|$8|$([ "$_a" = "$_b" ] && echo stable)" "drained|0|0|stable"
    ok "$_d: every message taken was sent or discarded" "$(($4 + $5))" "$3"
  else
    echo "  net $_d: TICS=$TICS, the demo still running: the counts as they stood, not a drained total"
  fi
}
