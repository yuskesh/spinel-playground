# tests/doom-core/harness/rt1186-board.sh -- one demo on the board, judged.
#
# Sourced by tests/doom-core/rt1186.sh for its part 5, and by
# tests/doom-core/board-controls.sh, which drives the same function with a
# planted write and a planted console and no board. It expects RUBY, ROOT,
# DIR, FIX, TICS, RT1186_RES, the lane's `ok`, and rt_flash and rt_console
# (tests/doom-core/harness/rt1186-host.sh, or the controls' own).
#
#   rt1186_board_demo DEMO HZ
#
# DIR/fw-DEMO/firmware/build.json is the build the lane made and
# DIR/nor-DEMO.bin its NOR image. In order, each step only after the one
# before it succeeded:
#
#   1. the build's id read from build.json (session.id): without one there is
#      nothing to tell this build's run from another's, and nothing is
#      written;
#   2. the NOR image written (rt_flash answers 0 and its log says the write
#      finished); after a failed write, the board holds whatever was written
#      before, so the console is not read at all;
#   3. the console read from the lane's own reset (rt_console) and judged by
#      tools/doom/board-frames.rb with --identity: the run must print this
#      build's SPC_SESSION_ID before its first frame, and every frame read
#      must be the recorded one (TICS=N: the first N; otherwise every frame
#      and the demo's end); a pair's build (decision 0027) must also print
#      the pair's two ids (--pair). The verdict is board-frames.rb's exit status,
#      taken on the line after it runs.
#
# Each step that fails is one FAIL, named; a step not taken says why.
rt1186_board_demo() { # demo hz
  _d=$1; _hz=$2
  rm -f "$RT1186_RES/serial_$_d.log" "$RT1186_RES/serial_$_d.reset" "$RT1186_RES/serial_$_d.wire" "$RT1186_RES/frames-$_d.out" "$RT1186_RES/flash_$_d.log"
  _id=$("$RUBY" -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("session", "id").to_s' "$DIR/fw-$_d/firmware/build.json" 2> /dev/null)
  case $_id in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) ok "$_d: build.json names the build's id (session.id)" "${_id:-none}" "16 hex digits"
       echo "  $_d: not written, and its console not read: no build id to judge it by"
       return 1 ;;
  esac
  rt_flash "$_d" "$DIR/nor-$_d.bin"
  _frc=$?
  _written=$(grep -ciE 'finished|success' "$RT1186_RES/flash_$_d.log" 2> /dev/null | awk '{ print ($1 > 0) ? "ok" : "no" }')
  ok "$_d: the NOR image is written" "$_frc|${_written:-no}" "0|ok"
  if [ "$_frc|${_written:-no}" != "0|ok" ]; then
    echo "  $_d: its console is not read: the write failed, so the board holds an earlier image"
    return 1
  fi
  # a pair (decision 0027): the ids the M33 companion hands the M7, as build.json records them
  _pair=$("$RUBY" -rjson -e 'p = JSON.parse(File.read(ARGV[0]))["pair"]; puts p ? [p["id"], p["companion"]["id"]].join(",") : ""' \
    "$DIR/fw-$_d/firmware/build.json" 2> /dev/null)
  rt_console "$_d" "${TICS:-0}"
  # read from the lane's own reset on: the length rt_console recorded just before it
  "$RUBY" "$ROOT/tools/doom/board-frames.rb" --console "$RT1186_RES/serial_$_d.log" --from "$(cat "$RT1186_RES/serial_$_d.reset" 2> /dev/null)" \
    --frames "$FIX/$_d.tsv" --identity "$_id" --hz "$_hz" ${TICS:+--tics "$TICS"} ${_pair:+--pair "$_pair"} > "$RT1186_RES/frames-$_d.out" 2>&1
  _rc=$?
  # FAILURE_SITES=1: the first failed call's site, named by its CORE unit and line
  if [ -n "${FAILURE_SITES:-}" ]; then
    "$RUBY" "$ROOT/tools/doom/failure-site.rb" --firmware "$DIR/fw-$_d/firmware" < "$RT1186_RES/serial_$_d.log" | sed 's/^/  failure site: /' ||
      echo "  failure site: the console has no SPC_FAILURE_SITE line"
  fi
  if [ -n "$TICS" ]; then
    ok "  build $_id ran, and the first $TICS frames are the recorded ones, in order" "$_rc" 0
  else
    ok "  build $_id ran, every frame is the recorded one, in order, and the demo ends" "$_rc" 0
  fi
  sed 's/^/  /' "$RT1186_RES/frames-$_d.out"
  # the reset's own output, when the run failed: a probe that could not reset the core is named
  if [ "$_rc" -ne 0 ] && [ -s "$RT1186_RES/serial_$_d.wire" ]; then
    tail -n 3 "$RT1186_RES/serial_$_d.wire" | sed 's/^/  the reset: /'
  fi
  return "$_rc"
}

# NOTHING IS WRITTEN AFTER A FAILURE. The board shows the build the lane made
# only when every check before the board part passed: a failed image,
# firmware or NOR image leaves nothing of this run to write, and reading the
# board then would read an earlier run. Answers 1, with one FAIL, when the
# lane's `fail` is not 0; the caller then takes, writes and reads nothing.
rt1186_board_gate() {
  [ "$fail" -eq 0 ] && return 0
  ok "the board part runs only when every check before it passed" "$fail failure(s) before it" "none"
  echo "  the board is not taken, written or read"
  return 1
}
