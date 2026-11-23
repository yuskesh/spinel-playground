# tests/doom-core/harness/rt1186-host.sh -- sourced by tests/doom-core/rt1186.sh: the
# FRDM-IMXRT1186, written and read through NXP LinkServer on a Linux host
# (decision 0021; the route tests/freestanding/frdm-host.sh takes for
# FRDM-MCXN947, here for this board's CM33 core).
#
#   RT1186_HOST        ssh destination of that host; unset, the board part is
#                      NOT RUN
#   RT1186_LINKSERVER  LinkServer there (default /usr/local/LinkServer/LinkServer)
#   RT1186_TTY         the MCU-Link VCOM there (default /dev/ttyACM0)
#   RT1186_PROBE       LinkServer's probe index or serial (default '#1')
#   RT1186_TIMEOUT     seconds to wait for a demo's last line (default 21600)
#   RT1186_LOCK        the lock directory there (default /tmp/spinel-rt1186.lock)
#   RT1186_OWNER       who holds the board, written into the lock (default the
#                      local user and host)
#   RT1186_RSH         a command that runs a shell string in place of ssh to
#                      RT1186_HOST; only the board-free controls set it
#
# The device is the one Zephyr's runner names for this board
# (boards/nxp/frdm_imxrt1186/board.cmake at the pinned commit:
# MIMXRT1186xxxxx:FRDM-IMXRT1186). The NOR image is written at the start of
# the QSPI NOR's secure alias, 0x14000000, with the flash configuration
# LinkServer has for the device. The owner allows the NOR to be written
# without a further confirmation (0021, "Writing the board"); nothing is read
# out first beyond the four bytes rt_ready reads to identify the board.
#
# The board's on-board MCU-Link names no board in `LinkServer probes`, so the
# probe list cannot say which board a probe is on. rt_ready instead requires
# RT1186_PROBE in that list and a read through it with this device's flash
# driver, which detects this SoC's FlexSPI2 QSPI NOR; on another board the
# read fails or detects another flash.
#
# ONE WRITER AT A TIME. Two lanes writing or reading the board at once corrupt
# each other's runs, so the lane takes the board before it touches the probe:
# rt_lock makes RT1186_LOCK on the host with mkdir, which only one caller can
# win, and writes who, which process, when and a token into it. A lane that
# finds it held fails and names the holder. The EXIT trap removes the lock only
# when the token in it is this run's: a lock left by a run that died is never
# removed here, and its holder or the owner decides.
#
# The caller sets RT1186_RES (where the records go). Files on the host go in
# one mktemp directory per run, which an EXIT trap removes.
RT1186_LINKSERVER=${RT1186_LINKSERVER:-/usr/local/LinkServer/LinkServer}
RT1186_TTY=${RT1186_TTY:-/dev/ttyACM0}
RT1186_PROBE=${RT1186_PROBE:-#1}
RT1186_TIMEOUT=${RT1186_TIMEOUT:-21600}
RT1186_DEVICE=MIMXRT1186xxxxx:FRDM-IMXRT1186
RT1186_NOR=0x14000000
RT1186_LOCK=${RT1186_LOCK:-/tmp/spinel-rt1186.lock}
RT1186_OWNER=${RT1186_OWNER:-$(id -un)@$(hostname)}

rt_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
rt_rsh() {
  if [ -n "${RT1186_RSH:-}" ]; then $RT1186_RSH "$1"; else ssh -o BatchMode=yes -o ConnectTimeout=10 "$RT1186_HOST" "$1"; fi
}

# rt_lock: takes the board (RT1186_LOCK on the host). Answers 0 and sets
# RT1186_LOCK_TOKEN when taken; 1, printing the lock's record, when another
# run holds it; 2 when the host cannot be asked. Call it in the lane's own
# shell, not in $( ), so the token and the trap stay with the lane.
rt_lock() {
  rt_rsh true > /dev/null 2>&1 || { echo "cannot reach RT1186_HOST to take the board's lock"; return 2; }
  tok="$(date +%s)-$$-$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
  rec=$(printf 'owner %s\npid %s\nstarted %s\ntoken %s\n' "$RT1186_OWNER" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tok")
  if rt_rsh "mkdir $(rt_q "$RT1186_LOCK") 2> /dev/null && printf '%s\n' $(rt_q "$rec") > $(rt_q "$RT1186_LOCK/owner")"; then
    RT1186_LOCK_TOKEN=$tok
    trap 'rt_cleanup' EXIT
    trap 'exit 1' INT TERM
    return 0
  fi
  echo "the board is held: $RT1186_LOCK on RT1186_HOST says"
  rt_rsh "cat $(rt_q "$RT1186_LOCK/owner") 2> /dev/null || echo '(no owner record yet)'" | sed 's/^/  /'
  return 1
}

# rt_unlock: removes the lock if the token in it is this run's, and only then.
rt_unlock() {
  [ -n "${RT1186_LOCK_TOKEN:-}" ] || return 0
  rt_rsh "[ \"\$(sed -n 's/^token //p' $(rt_q "$RT1186_LOCK/owner") 2> /dev/null)\" = $(rt_q "$RT1186_LOCK_TOKEN") ] && rm -rf $(rt_q "$RT1186_LOCK")" > /dev/null 2>&1
  RT1186_LOCK_TOKEN=
}

# rt_cleanup: the EXIT trap: the run's directory on the host, then the lock.
rt_cleanup() {
  [ -n "${RT1186_RD:-}" ] && { rt_rsh "rm -rf $(rt_q "$RT1186_RD")" > /dev/null 2>&1 || true; }
  rt_unlock
}

# rt_ready: prints nothing and answers 0 when the host, LinkServer, the console
# and a probe on this board are there; otherwise prints why and answers 1.
# Leaves LinkServer's probe list and the identifying read in
# $RT1186_RES/probes.txt.
rt_ready() {
  [ -n "${RT1186_HOST:-}" ] || { echo "RT1186_HOST is not set (the ssh destination of a Linux host with LinkServer and the board's MCU-Link)"; return 1; }
  rt_rsh true > /dev/null 2>&1 || { echo "cannot reach RT1186_HOST over ssh without a prompt"; return 1; }
  rt_rsh "test -x $(rt_q "$RT1186_LINKSERVER")" || { echo "no LinkServer at $RT1186_LINKSERVER on RT1186_HOST"; return 1; }
  rt_rsh "test -c $(rt_q "$RT1186_TTY")" || { echo "no character device $RT1186_TTY on RT1186_HOST"; return 1; }
  rt_rsh "stty --version > /dev/null 2>&1 && command -v timeout > /dev/null" || { echo "RT1186_HOST has no GNU stty and timeout (it must be Linux)"; return 1; }
  rt_rsh "$(rt_q "$RT1186_LINKSERVER") probes" > "$RT1186_RES/probes.txt" 2>&1
  # A '#N' probe is the row numbered N; anything else, as LinkServer takes it,
  # a substring of a row's serial.
  awk -v p="$RT1186_PROBE" '$1 ~ /^[0-9]+$/ && (substr(p, 1, 1) == "#" ? "#" $1 == p : index($0, p) > 0) { f = 1 }
    END { exit !f }' "$RT1186_RES/probes.txt" ||
    { echo "LinkServer on RT1186_HOST lists no probe $RT1186_PROBE (see $RT1186_RES/probes.txt)"; return 1; }
  echo "== the identifying read: 4 bytes at 0x14000400 through probe $RT1186_PROBE as $RT1186_DEVICE" >> "$RT1186_RES/probes.txt"
  rt_rsh "d=\$(mktemp -d) || exit 1
    $(rt_q "$RT1186_LINKSERVER") flash --probe $(rt_q "$RT1186_PROBE") $RT1186_DEVICE dump 0x14000400 4 \"\$d/id.bin\" 2>&1
    rc=\$?; od -A x -c \"\$d/id.bin\" 2>&1; rm -rf \"\$d\"; echo \"dump exit \$rc\"" >> "$RT1186_RES/probes.txt" 2>&1
  if ! grep -q '^dump exit 0$' "$RT1186_RES/probes.txt" ||
     ! grep -q "Flash variant 'RT1180_FlexSPI2_.*detected" "$RT1186_RES/probes.txt"; then
    echo "probe $RT1186_PROBE does not read an FRDM-IMXRT1186's QSPI NOR as $RT1186_DEVICE (see $RT1186_RES/probes.txt)"; return 1
  fi
}

# rt_open: the run's directory on the host (RT1186_RD) and rt1186.txt.
rt_open() {
  RT1186_RD=$(rt_rsh 'mktemp -d "${TMPDIR:-/tmp}/spinel-rt1186.XXXXXX"') || RT1186_RD=
  case $RT1186_RD in /*) ;; *) echo "rt1186: could not make a directory on RT1186_HOST" >&2; return 1 ;; esac
  trap 'rt_cleanup' EXIT
  trap 'exit 1' INT TERM
  { rt_rsh "$(rt_q "$RT1186_LINKSERVER") --version" 2>&1 | head -1; cat "$RT1186_RES/probes.txt"; } > "$RT1186_RES/rt1186.txt"
}

# rt_flash TAG NOR: copies NOR to the host, checks the copy's sha256, and
# writes it at 0x14000000. Answers LinkServer's exit status; the log is
# $RT1186_RES/flash_TAG.log.
rt_flash() {
  echo "image $1 $(sha256sum "$2" | cut -d' ' -f1)" >> "$RT1186_RES/rt1186.txt"
  scp -q -o BatchMode=yes "$2" "$RT1186_HOST:$RT1186_RD/$1.bin" || return 1
  [ "$(rt_rsh "sha256sum $(rt_q "$RT1186_RD/$1.bin")" | cut -d' ' -f1)" = "$(sha256sum "$2" | cut -d' ' -f1)" ] || return 1
  rt_rsh "$(rt_q "$RT1186_LINKSERVER") flash --probe $(rt_q "$RT1186_PROBE") $RT1186_DEVICE \
      load --addr $RT1186_NOR $(rt_q "$RT1186_RD/$1.bin")" > "$RT1186_RES/flash_$1.log" 2>&1
}

# rt_console TAG [N [END]]: the console from the lane's own reset after the write, into
# $RT1186_RES/serial_TAG.log, and the console's length in bytes just before
# that reset into $RT1186_RES/serial_TAG.reset. The write's own reset starts
# the image before the console is open, so the log can begin inside that
# earlier run; tools/doom/board-frames.rb reads from the first boot after the
# recorded length (its --from) and nothing before it.
#
# It waits until, after that length, the run has written its `D ` or `X `
# line (the payload of a 0014 frame: 0xA5, channel, length, then the line),
# or, given N (rt1186.sh's TICS), its N-th `F ` line, or, given END, a
# plain console line that starts with END (a program that prints with printk
# rather than through a channel), or it writes
# SPC_SESSION_REFUSED, a Zephyr fault (`***** ... FAULT *****` or
# `>>> ZEPHYR FATAL ERROR`) or a second `*** Booting Zephyr`, or until
# RT1186_TIMEOUT, then two seconds more: a run that faulted or rebooted ends
# at once instead of at the timeout. This test only decides when to stop
# reading; board-frames.rb decodes the frames and judges them. As on
# FRDM-MCXN947, the console is opened only after the write and the core is
# reset on the probe's wire, so the image read is the one just written.
# The reset's own output goes to serial_<demo>.wire. A reset that fails, or
# one after which no `*** Booting Zephyr` appears within 60 s, ends the
# reading at once rather than at RT1186_TIMEOUT: the console read is then not
# this image's run, and board-frames.rb says so.
RT1186_CONSOLE='log=$1; tty=$2; ls=$3; probe=$4; t=$5; n=$6; e=$7
( stty -F "$tty" 115200 cs8 -cstopb -parenb raw -echo && exec timeout "$t" cat "$tty" ) > "$log" 2>&1 &
c=$!
sleep 1
wc -c < "$log" | tr -d " " > "$log.reset"
"$ls" probe "$probe" wiretimedreset 100 > "$log.wire" 2>&1
w=$?
echo "rc=$w" >> "$log.wire"
off=$(cat "$log.reset")
sof=$(printf "\245")
i=0
[ "$w" -eq 0 ] || i=$t
while [ $i -lt "$t" ]; do
  tail -c +$((off + 1)) "$log" | LC_ALL=C tr -d "\r\000" | LC_ALL=C awk -v sof="$sof" -v n="$n" -v e="$e" -v i="$i" "
    /[*][*][*] Booting Zephyr/ { if (++b >= 2) s = 1; on = 1 }
    END { if (!on && i >= 60) s = 1 }
    on && index(\$0, sof) && substr(\$0, index(\$0, sof) + 2, 2) ~ /^(D|X) / { f = 1 }
    on && n > 0 && index(\$0, sof) && substr(\$0, index(\$0, sof) + 2, 2) == \"F \" { if (++nf >= n) f = 1 }
    on && e != \"\" && index(\$0, e) == 1 { f = 1 }
    /^SPC_SESSION_REFUSED/ || /^SPC_CHANNEL_REFUSED/ || /^SPC_M7_FATAL/ { s = 1 }
    /FAULT [*][*][*][*][*]/ || />>> ZEPHYR FATAL ERROR/ { s = 1 }
    END { exit !(f || s) }" && break
  sleep 5; i=$((i + 5))
done
sleep 2
kill $c 2> /dev/null; wait $c 2> /dev/null; true'
rt_console() {
  rt_rsh "sh -c $(rt_q "$RT1186_CONSOLE") rt_console $(rt_q "$RT1186_RD/serial_$1.log") $(rt_q "$RT1186_TTY") \
    $(rt_q "$RT1186_LINKSERVER") $(rt_q "$RT1186_PROBE") $RT1186_TIMEOUT ${2:-0} $(rt_q "${3:-}")"
  scp -q -o BatchMode=yes "$RT1186_HOST:$RT1186_RD/serial_$1.log" "$RT1186_RES/serial_$1.log" || : > "$RT1186_RES/serial_$1.log"
  scp -q -o BatchMode=yes "$RT1186_HOST:$RT1186_RD/serial_$1.log.reset" "$RT1186_RES/serial_$1.reset" || : > "$RT1186_RES/serial_$1.reset"
  scp -q -o BatchMode=yes "$RT1186_HOST:$RT1186_RD/serial_$1.log.wire" "$RT1186_RES/serial_$1.wire" || echo "the reset's log was not fetched" > "$RT1186_RES/serial_$1.wire"
}
