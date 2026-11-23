# tests/freestanding/frdm-host.sh -- sourced, after lane-env.sh, by the lanes
# that run on an NXP FRDM-MCXN947 board: e040/run_frdm.sh and bm040-frdm.
# The board's MCU-Link (J17) is plugged into a Linux host that has NXP
# LinkServer, and these functions drive that host over ssh: they check what it
# needs, write an image to the board's flash, read the board's console, and
# read the core's PC.
#
#   FRDM_HOST        ssh destination of that host; unset, the lane is NOT RUN
#   FRDM_LINKSERVER  LinkServer there (default /usr/local/LinkServer/LinkServer,
#                    where NXP's Linux package links the installed version)
#   FRDM_TTY         the MCU-Link VCOM there (default /dev/ttyACM0)
#   FRDM_PROBE       LinkServer's probe index or serial (default '#1')
#   FRDM_TIMEOUT     seconds to wait for each console's terminator (default 60)
#
# The host must be Linux: the console is read with GNU stty and timeout. On
# macOS arm64, LinkServer 26.6.137 and 26.9.130 list the MCU-Link but cannot
# open it ("Error: Probe not open"), so such a host is reported as one whose
# LinkServer opens no probe on an MCXN947. ssh runs with BatchMode, so the host
# must accept a key without a prompt.
#
# The caller sets FRDM_LABEL (the prefix of its messages) and FRDM_RES (where
# the records go). Files on the host go in one mktemp directory per run, which
# an EXIT trap removes.
FRDM_LINKSERVER=${FRDM_LINKSERVER:-/usr/local/LinkServer/LinkServer}
FRDM_TTY=${FRDM_TTY:-/dev/ttyACM0}
FRDM_PROBE=${FRDM_PROBE:-#1}
FRDM_TIMEOUT=${FRDM_TIMEOUT:-60}
FRDM_DEVICE=MCXN947:FRDM-MCXN947

# Single-quotes one word for the remote shell.
frdm_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
frdm_rsh() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$FRDM_HOST" "$1"; }
frdm_sha() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# A prerequisite is missing: NOT RUN (exit 3), or a failure under REQUIRE_ALL=1.
frdm_not_run() {
  echo "$*" > "$FRDM_RES/not_run.txt"
  if [ "${REQUIRE_ALL:-0}" = 1 ]; then
    echo "$FRDM_LABEL: FAIL: not run, and REQUIRE_ALL=1: $*" >&2
    exit 1
  fi
  echo "$FRDM_LABEL: NOT RUN: $*"
  exit 3
}

# Calls frdm_not_run unless the host, LinkServer, the console and the probe
# are all there. Leaves LinkServer's probe list in $FRDM_RES/probes.txt.
frdm_require() {
  [ -n "${FRDM_HOST:-}" ] ||
    frdm_not_run "FRDM_HOST is not set (the ssh destination of a Linux host with LinkServer and the board's MCU-Link)"
  frdm_rsh true > /dev/null 2>&1 || frdm_not_run "cannot reach FRDM_HOST over ssh without a prompt"
  frdm_rsh "test -x $(frdm_q "$FRDM_LINKSERVER")" ||
    frdm_not_run "no LinkServer at $FRDM_LINKSERVER on FRDM_HOST"
  frdm_rsh "test -c $(frdm_q "$FRDM_TTY")" || frdm_not_run "no character device $FRDM_TTY on FRDM_HOST"
  frdm_rsh "stty --version > /dev/null 2>&1 && command -v timeout > /dev/null" ||
    frdm_not_run "FRDM_HOST has no GNU stty and timeout (it must be Linux)"
  frdm_rsh "$(frdm_q "$FRDM_LINKSERVER") probes" > "$FRDM_RES/probes.txt" 2>&1
  # The Device and Board columns are filled only when LinkServer could open
  # the probe; the description alone also names the board.
  grep -Eq ' MCXN947 +FRDM-MCXN947 ' "$FRDM_RES/probes.txt" ||
    frdm_not_run "LinkServer on FRDM_HOST opens no probe on an MCXN947 (see $FRDM_RES/probes.txt)"
}

# Makes the run's directory on the host (FRDM_RD) and starts frdm.txt.
frdm_open() {
  FRDM_RD=$(frdm_rsh 'mktemp -d "${TMPDIR:-/tmp}/spinel-frdm.XXXXXX"') || FRDM_RD=
  case $FRDM_RD in
    /*) ;;
    *) echo "$FRDM_LABEL: could not make a directory on FRDM_HOST" >&2; exit 1 ;;
  esac
  trap 'frdm_rsh "rm -rf $(frdm_q "$FRDM_RD")" > /dev/null 2>&1 || true' EXIT
  trap 'exit 1' INT TERM
  {
    frdm_rsh "$(frdm_q "$FRDM_LINKSERVER") --version" 2>&1 | head -1
    grep -E ' MCXN947 +FRDM-MCXN947 ' "$FRDM_RES/probes.txt"
  } > "$FRDM_RES/frdm.txt"
}

# frdm_flash TAG BIN: copies BIN to the host and writes it at the start of the
# secure flash alias, with the flash driver and location Zephyr's board.cmake
# gives LinkServer. Sets FRDM_SUM_<TAG> (the copy's sha256 on the host) and
# FRDM_RC_<TAG> (LinkServer's exit status); the log is $FRDM_RES/flash_TAG.log.
frdm_flash() {
  echo "image $1 $(frdm_sha "$2")" >> "$FRDM_RES/frdm.txt"
  scp -q -o BatchMode=yes "$2" "$FRDM_HOST:$FRDM_RD/$1.bin"
  _sum=$(frdm_rsh "sha256sum $(frdm_q "$FRDM_RD/$1.bin")" | cut -d' ' -f1)
  eval "FRDM_SUM_$1=\$_sum"
  frdm_rsh "$(frdm_q "$FRDM_LINKSERVER") flash --probe $(frdm_q "$FRDM_PROBE") \
      -o /device/memory/1/flash-driver=MCXN9xx_S.cfx \
      -o /device/memory/1/location=0x10000000 \
      $FRDM_DEVICE load --addr 0x10000000 $(frdm_q "$FRDM_RD/$1.bin")" > "$FRDM_RES/flash_$1.log" 2>&1
  _rc=$?
  eval "FRDM_RC_$1=\$_rc"
}

# frdm_flashed TAG: the write exited 0 and LinkServer reported it finished.
frdm_flashed() {
  eval "_rc=\$FRDM_RC_$1"
  [ "$_rc" = 0 ] && grep -q 'Finished writing Flash successfully' "$FRDM_RES/flash_$1.log"
}

# frdm_console TAG TERM SETTLE: the console from a reset, into
# $FRDM_RES/serial_TAG.log, until a line after its last E040 BEGIN matches TERM
# (or FRDM_TIMEOUT), then SETTLE seconds more.
#
# LinkServer resets the target before it writes, so the image already in flash
# boots once and prints into a console opened then; when it is an E040 image
# its whole run, END included, would pass for the new one. So the console is
# opened only after the write, and a reset on the probe's wire starts the new
# image from its first line. The run LinkServer starts after the write may
# still be printing when the console opens, and its END would end the wait
# early, so the terminator counts only after the last BEGIN; readers take a
# console from there too.
frdm_console() {
  frdm_rsh "log=$(frdm_q "$FRDM_RD/serial_$1.log")
    ( stty -F $(frdm_q "$FRDM_TTY") 115200 cs8 -cstopb -parenb raw -echo &&
      exec timeout $FRDM_TIMEOUT cat $(frdm_q "$FRDM_TTY") ) > \"\$log\" 2>&1 &
    c=\$!
    sleep 1
    $(frdm_q "$FRDM_LINKSERVER") probe $(frdm_q "$FRDM_PROBE") wiretimedreset 100 > /dev/null 2>&1
    i=0
    while [ \$i -lt $FRDM_TIMEOUT ]; do
      LC_ALL=C awk -v t=$(frdm_q "$2") '/^E040\tBEGIN\t/ { f = 0; on = 1 } on && \$0 ~ t { f = 1 }
        END { exit !f }' \"\$log\" && break
      sleep 1; i=\$((i + 1))
    done
    sleep $3
    kill \$c 2> /dev/null; wait \$c 2> /dev/null; true"
  scp -q -o BatchMode=yes "$FRDM_HOST:$FRDM_RD/serial_$1.log" "$FRDM_RES/serial_$1.log" ||
    : > "$FRDM_RES/serial_$1.log"
}

# frdm_pc TAG: halts the core and prints its PC (0x...), with LinkServer's
# script language; the script's output is $FRDM_RES/pc_TAG.log. The core is
# left halted.
frdm_pc() {
  frdm_rsh "printf '%s\n' '10 p% = 1' '20 wireswdconnect p%' '30 selectprobecore p% 0' \
      '40 cminitapdp this' '50 cmhalt this' '60 c% = CmReadReg this 15' \
      '70 print \"PC: \";~c%' '80 end' > $(frdm_q "$FRDM_RD/pc.scp") &&
    $(frdm_q "$FRDM_LINKSERVER") probe $(frdm_q "$FRDM_PROBE") runscript $(frdm_q "$FRDM_RD/pc.scp")" \
    > "$FRDM_RES/pc_$1.log" 2>&1
  sed -n 's/^PC: *\(0x[0-9A-Fa-f]*\).*/\1/p' "$FRDM_RES/pc_$1.log" | tail -1
}

# frdm_last_run FILE: a console's lines from its last E040 BEGIN on, without
# CRs or NULs (bytes, whatever the locale).
frdm_last_run() {
  LC_ALL=C tr -d '\r\000' < "$1" |
    LC_ALL=C awk '/^E040\tBEGIN\t/ { b = ""; on = 1 } on { b = b $0 "\n" } END { printf "%s", b }'
}
