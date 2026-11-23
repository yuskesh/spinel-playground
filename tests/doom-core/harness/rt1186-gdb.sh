# tests/doom-core/harness/rt1186-gdb.sh -- sourced after rt1186-host.sh, with
# the board's lock held: memory of the running FRDM-IMXRT1186 read through
# LinkServer's gdbserver on RT1186_HOST and a gdb here.
#
#   RT1186_GDB       the gdb that speaks ARM (default arm-none-eabi-gdb, else
#                    gdb-multiarch)
#   RT1186_GDB_PORT  the port, the same on both ends of an ssh tunnel
#                    (default 3333)
#   RT1186_GDB_CORE  the core LinkServer attaches to (unset: the primary,
#                    the M33; cm7 for the Cortex-M7's memory, decision 0023)
#   RT1186_GDB_LISTEN seconds to wait for the server's `listening on port`
#                    (default 30)
#
# The server attaches without halting and without running a connect script,
# so the board keeps running and nothing is reset; the reads go through the
# debug access port while the core runs.

RT1186_GDB_PORT=${RT1186_GDB_PORT:-3333}
RT1186_GDB_LISTEN=${RT1186_GDB_LISTEN:-30}
if [ -z "${RT1186_GDB:-}" ]; then
  if command -v arm-none-eabi-gdb > /dev/null 2>&1; then RT1186_GDB=arm-none-eabi-gdb; else RT1186_GDB=gdb-multiarch; fi
fi

# rt_gdb_idle: waits on the host, up to 20 s, until no LinkServer gdbserver
# and no redlink server of RT1186_PROBE is left. A server that was killed
# keeps the probe until it has exited, and one started before then never
# listens (seen on the board, 0028-results.md). 0 when none is left; 1,
# naming it, when one still runs. The patterns' first letter in brackets
# keeps them from matching the host's own shell, whose command line holds
# them.
rt_gdb_pattern() { printf '%s' "[L]inkServer gdbserver --probe $RT1186_PROBE"; }
rt_gdb_redlink() { printf '%s' "[c]rt_emu_cm_redlink.*$RT1186_PROBE"; }
rt_gdb_idle() {
  rt_rsh "i=0; while pgrep -f $(rt_q "$(rt_gdb_pattern)") > /dev/null || pgrep -f $(rt_q "$(rt_gdb_redlink)") > /dev/null; do \
    if [ \$i -ge 20 ]; then echo 'a gdbserver of probe $RT1186_PROBE still runs after 20 s'; exit 1; fi; sleep 1; i=\$((i + 1)); done"
}

# rt_gdb_read OUT ADDR BYTES [OUT ADDR BYTES ...]: each range of target memory
# into its file, in one gdb session. BYTES may be a gdb expression evaluated
# on the target, quoted (e.g. '4 * *(unsigned int *)0x38000004'), in which
# case the file's size is not checked. The triple `sleep SECONDS -` pauses
# between two reads of the one session. Answers 0 when every file was
# written by this read and every checked file has its size: each OUT is
# removed first, so a read that fails never leaves an earlier read's file
# to pass for its own. RT1186_GDB_TAG (a demo's name, say) names the logs,
# gdb-TAG.log and gdbserver-TAG.log, so one demo's do not replace another's.
# Each read starts when no earlier server of the probe is left
# (rt_gdb_idle), and waits for its own to end after it; a server that never
# says it listens fails the read, named, and no gdb is run against it.
rt_gdb_read() {
  command -v "$RT1186_GDB" > /dev/null 2>&1 || { echo "no gdb at '$RT1186_GDB' (set RT1186_GDB)"; return 2; }
  rt_gdb_log=$RT1186_RES/gdb${RT1186_GDB_TAG:+-$RT1186_GDB_TAG}.log
  rt_gdb_srv=$RT1186_RES/gdbserver${RT1186_GDB_TAG:+-$RT1186_GDB_TAG}.log
  # every OUT of the call removed before the read: what is there after it is this read's
  k=0
  for a in "$@"; do
    [ $((k % 3)) -ne 0 ] || [ "$a" = sleep ] || rm -f "$a"
    k=$((k + 1))
  done
  rt_gdb_idle || return 1
  ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -L "$RT1186_GDB_PORT:127.0.0.1:$RT1186_GDB_PORT" "$RT1186_HOST" \
    "exec $(rt_q "$RT1186_LINKSERVER") gdbserver --probe $(rt_q "$RT1186_PROBE") ${RT1186_GDB_CORE:+--core $RT1186_GDB_CORE} --attach --gdb-port $RT1186_GDB_PORT --semihost-port -1 $RT1186_DEVICE" \
    > "$rt_gdb_srv" 2>&1 &
  rt_gdb_ssh=$!
  i=0
  while [ $i -lt "$RT1186_GDB_LISTEN" ] && ! grep -q 'listening on port' "$rt_gdb_srv" 2> /dev/null; do sleep 1; i=$((i + 1)); done
  if ! grep -q 'listening on port' "$rt_gdb_srv" 2> /dev/null; then
    kill "$rt_gdb_ssh" 2> /dev/null; wait "$rt_gdb_ssh" 2> /dev/null
    echo "the gdbserver did not listen within $RT1186_GDB_LISTEN s (see $rt_gdb_srv)"
    return 1
  fi
  cmds=""
  want=""
  while [ $# -ge 3 ]; do
    # `sleep SECONDS -`: a pause between two reads of the same session
    if [ "$1" = sleep ]; then cmds="$cmds -ex $(rt_q "shell sleep $2")"; shift 3; continue; fi
    case $3 in
      *[!0-9]*) cmds="$cmds -ex $(rt_q "eval \"dump binary memory $1 %u %u\", $(($2)), $(($2)) + ($3)")"; want="$want $1:-" ;;
      *) cmds="$cmds -ex $(rt_q "dump binary memory $1 $(($2)) $(($2 + $3))")"; want="$want $1:$3" ;;
    esac
    shift 3
  done
  eval "\"\$RT1186_GDB\" -q -batch -nx -ex 'set pagination off' -ex 'set mem inaccessible-by-default off' \
    -ex 'target extended-remote :$RT1186_GDB_PORT' $cmds -ex detach" > "$rt_gdb_log" 2>&1
  kill "$rt_gdb_ssh" 2> /dev/null; wait "$rt_gdb_ssh" 2> /dev/null
  rt_rsh "pkill -f $(rt_q "$(rt_gdb_pattern)") 2> /dev/null; pkill -f $(rt_q "$(rt_gdb_redlink)") 2> /dev/null; true"
  rt_gdb_idle > /dev/null || echo "a gdbserver of probe $RT1186_PROBE still runs after the read; the next read waits for it"
  for w in $want; do
    f=${w%:*}; n=${w##*:}
    [ -f "$f" ] || { echo "the read wrote no $f (see $rt_gdb_log)"; return 1; }
    [ "$n" = - ] || [ "$(wc -c < "$f" 2> /dev/null | tr -d ' ')" = "$n" ] || { echo "the read of $f did not give $n bytes (see $rt_gdb_log)"; return 1; }
  done
}
