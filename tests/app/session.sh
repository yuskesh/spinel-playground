#!/bin/sh
#
# tests/app/session.sh -- decision 0021: an application with a core_session.
#
#   SESSION_IMAGE=DIR SESSION_OBJECTS=DIR WAD=... ZEPHYR_BASE=... ZEPHYR_SDK_INSTALL_DIR=... \
#     KERNEL=... SPINEL_TYPEDUMP=... CLANG=...|LLVM_PREFIX=... sh tests/app/session.sh [WORKDIR]
#
# SESSION_IMAGE is DEMO1's session image (tools/doom/session-image.rb --demo
# DEMO1) and SESSION_OBJECTS the three DOOM entries built for thumbv8m with
# their headers, reports and contracts. Building those takes most of ten
# minutes, so this lane takes them, as tests/doom-core/bound-resources.sh
# takes a kernel build; the board lane makes them and runs this.
#
# WHAT IT CHECKS
#   1. On the host (CoreApp::SessionHost), examples/doom/core/board/app.rb
#      plays DEMO1's first 200 tics over the image's session with the
#      entries' CORE source in CRuby: every command DoomCore.step is called
#      with is Full's Demo object's for that tic (forward, side, angleturn,
#      buttons, and 0), and every frame's two FNV digests are the recorded
#      ones (tests/doom-core/fixtures/screens/DEMO1.tsv). CONTROL: an image
#      whose demo offset is four bytes on reads other commands.
#   1b. With SESSION_PAIR=1 (the pair lane's, decision 0027 stage 2):
#      examples/doom/core/board/pair.rb with companion.rb in the same
#      process, their `console` contract channel one CoreChannelSim, the
#      companion's relay run after each release. The same 200 tics, read from
#      the companion's console: every command is Full's Demo object's and
#      every frame the recorded one, as in 1, and the channel's counts close
#      (attempted = accepted + refused, accepted = taken + queued, taken =
#      written + malformed + held, none malformed). CONTROL: a companion that
#      never runs leaves the console empty; the ring holds its depth, 16, the
#      later tries are refused, and pair.rb waits on its line (17 steps).
#   2. The application builds for frdm_imxrt1186 with the session. build.json
#      records the claim -- realtime profile, loop_bound unknown through
#      DoomCore: not a realtime claim -- the entry's loop_bound unknown through
#      DoomCore.step and DoomCore.render with their reasons, the runtime
#      helpers each entry's object calls, the code ending below the session
#      area, and the session fitting it.
#   3. Refused, each by its message: the session written from two contexts;
#      an entry that writes a resource of the session; a provider other than
#      session.c calling a DOOM entry; session arguments given to an
#      application that declares no core_session.
#   4. core_session's dtcm: (0021, the screen in DTCM). The board
#      application keeps renderer_screen in the data TCM: its array lies
#      inside the zephyr,dtcm node's range, and build.json records it.
#      fixtures/session/dtcm-screen and dtcm-none differ only in the keyword:
#      only the first has the array, and their session ids differ. Refused:
#      a field that does not fit the data TCM (dtcm-overflow, step 8, with
#      the bytes) and a resource (dtcm-resource, step 1).
#   5. The board's session_itcm_entries (decision 0023: the M7 keeps the
#      render entry's code in its instruction TCM). On such a board the
#      board application's spinel_core_doom_core_render lies inside the
#      zephyr,itcm range and build.json records its bytes; with the render
#      and step entries named together (--mutate-itcm-entries) the build is
#      refused at step 4, naming the bytes; with none named the code stays in
#      the NOR and the session id differs. On a board that names none, the
#      entry is not in the instruction TCM and build.json records none.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export ROOT # the host harness reads it
W=${1:-${TMPDIR:-/tmp}/app-session.$$}
RUBY=${RUBY:-ruby}
TOOL=$ROOT/tools/app/bin/spinel-core-app
F=$ROOT/tests/app/fixtures/session
APP=$ROOT/examples/doom/core/board/app.rb
FRAMES=200
pass=0; fail=0; skip=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
T0=$(date +%s)
summary() {
  echo "session: $((pass + fail)) checked, $pass pass, $fail fail, $skip lane(s) skipped; $(( $(date +%s) - T0 )) s"
  if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -ne 0 ]; then exit 1; fi
  [ "$fail" -eq 0 ]
  exit $?
}
# the skip says which input is missing, by name
missing=""
if [ -z "${SESSION_IMAGE:-}" ]; then missing="$missing; SESSION_IMAGE is not set"
elif [ ! -f "$SESSION_IMAGE/image.tsv" ]; then missing="$missing; $SESSION_IMAGE/image.tsv does not exist"; fi
if [ -z "${SESSION_OBJECTS:-}" ]; then missing="$missing; SESSION_OBJECTS is not set"
elif [ ! -f "$SESSION_OBJECTS/doom_core_step.o" ]; then missing="$missing; $SESSION_OBJECTS/doom_core_step.o does not exist"; fi
if [ -z "${WAD:-}" ]; then missing="$missing; WAD is not set"
elif [ ! -f "$WAD" ]; then missing="$missing; $WAD does not exist"; fi
if [ -n "$missing" ]; then
  echo "  SKIP the session lane: ${missing#; }" >&2
  skip=1
  summary
fi
mkdir -p "$W" || exit 2

echo "session: 1. the board application on the host, over DEMO1's session"
host() { # image -> "commands-agree|frames|frames-agree"
  "$RUBY" -I"$ROOT/tools/app/lib" -I"$ROOT/examples/doom/lib" -e '
    require "core_app/session_host"; require "doom/wad"; require "doom/demo"
    image, wad, fix, n, app = ARGV[0], ARGV[1], ARGV[2], Integer(ARGV[3]), ARGV[4]
    r = CoreApp::SessionHost.new(app_path: app, image_dir: image, root: ENV.fetch("ROOT")).run(frames: n)
    demo = Doom::Demo.new(Doom::Wad.new(wad), "DEMO1", "")
    cmds = r.commands.first(n).each_with_index.all? { |c, t| c == [demo.forwardmove[t], demo.sidemove[t], demo.angleturn[t], demo.buttons[t], 0] }
    want = File.readlines(fix).reject { |l| l.start_with?("#") }.first(n).map { |l| l.split("\t")[1, 2].map(&:strip) }
    got = r.lines.select { |l| l.start_with?("F ") }.map { |l| l.split(" ")[2, 2] }
    puts "#{cmds}|#{got.size}|#{got == want}"' "$1" "$WAD" "$ROOT/tests/doom-core/fixtures/screens/DEMO1.tsv" "$FRAMES" "$APP" 2>"$W/host.err"
}
s=$(date +%s)
ok "$FRAMES tics: every command is Full's Demo object's, and every frame the recorded one" \
   "$(host "$SESSION_IMAGE")" "true|$FRAMES|true"
echo "  time host: $(( $(date +%s) - s )) s"
rm -rf "$W/shifted"; cp -R "$SESSION_IMAGE" "$W/shifted"
"$RUBY" -e 'd = ARGV[0]; t = File.join(d, "image.tsv"); s = File.read(t)
  s = s.sub(/^#demo\t(\S+)\toffset (\d+)\t/) { "#demo\t#{$1}\toffset #{$2.to_i + 4}\t" }
  File.write(t, s)
  sums = File.read(File.join(d, "image.sha256")).sub(/^\h{64}  image\.tsv$/) { "#{require "digest"; Digest::SHA256.file(t).hexdigest}  image.tsv" }
  File.write(File.join(d, "image.sha256"), sums)' "$W/shifted"
ok "control: an image whose demo offset is four bytes on reads other commands" \
   "$(host "$W/shifted" | cut -d'|' -f1)" false

# decision 0027 stage 2: the pair on the host (SESSION_PAIR=1, the pair lane's)
if [ "${SESSION_PAIR:-}" = 1 ]; then
  echo "session: 1b. the pair on the host: pair.rb with companion.rb, their console channel one CoreChannelSim"
  pairhost() { # image [stopped] -> "commands-agree|frames|frames-agree|steps|attempted accepted refused taken queued written malformed held"
    "$RUBY" -I"$ROOT/tools/app/lib" -I"$ROOT/examples/doom/lib" -e '
      require "core_app/session_host"; require "doom/wad"; require "doom/demo"
      image, wad, fix, n, root, stopped = ARGV[0], ARGV[1], ARGV[2], Integer(ARGV[3]), ARGV[4], ARGV[5] == "stopped"
      board = File.join(root, "examples/doom/core/board")
      r = CoreApp::SessionHost.new(app_path: File.join(board, "pair.rb"), image_dir: image, root: root)
            .run(frames: n, companion: File.join(board, "companion.rb"), consumer_stopped: stopped, limit: stopped ? 100 : 100_000)
      demo = Doom::Demo.new(Doom::Wad.new(wad), "DEMO1", "")
      cmds = r.commands.each_with_index.all? { |c, t| c == [demo.forwardmove[t], demo.sidemove[t], demo.angleturn[t], demo.buttons[t], 0] }
      want = File.readlines(fix).reject { |l| l.start_with?("#") }.first(n).map { |l| l.split("\t")[1, 2].map(&:strip) }
      got = r.lines.select { |l| l.start_with?("F ") }.map { |l| l.split(" ")[2, 2] }
      s = r.channels["console"]; c = r.companion_states
      puts [cmds, got.size, got == want, r.calls["step"],
            [s.attempted, s.accepted, s.refused, s.taken, s.queue.size, c["written"][0], c["malformed"][0], c["held"][0]].join(" ")].join("|")' \
      "$1" "$WAD" "$ROOT/tests/doom-core/fixtures/screens/DEMO1.tsv" "$FRAMES" "$ROOT" "${2:-}" 2> "$W/pairhost.err"
  }
  s=$(date +%s)
  r=$(pairhost "$SESSION_IMAGE")
  ok "$FRAMES tics relayed through the M33's console: every command is Full's Demo object's, and every frame the recorded one" \
     "$(echo "$r" | cut -d'|' -f1-3)" "true|$FRAMES|true"
  set -- $(echo "$r" | cut -d'|' -f5)
  ok "  the counts close: attempted = accepted + refused, accepted = taken + queued, taken = written + malformed + held, and nothing malformed" \
     "$([ "${1:-x}" = "$(( ${2:-0} + ${3:-0} ))" ] && echo a)$([ "${2:-x}" = "$(( ${4:-0} + ${5:-0} ))" ] && echo b)$([ "${4:-x}" = "$(( ${6:-0} + ${7:-0} + ${8:-0} ))" ] && echo c)|${7:-x}" "abc|0"
  echo "  pair counts: attempted $1 accepted $2 refused $3 taken $4 queued $5 written $6 malformed $7 held $8; time host pair: $(( $(date +%s) - s )) s"
  r=$(pairhost "$SESSION_IMAGE" stopped)
  set -- $(echo "$r" | cut -d'|' -f5)
  ok "control: a companion that never runs leaves the console empty; the ring holds its depth, 16, the later tries refused, and pair.rb waits on its line" \
     "$(echo "$r" | cut -d'|' -f2,4)|${2:-x}|$([ "${3:-0}" -gt 0 ] && echo refused)|${4:-x}" "0|17|16|refused|0"
fi
BOARD=${SESSION_BOARD:-frdm_imxrt1186_cm7} # the board's Cortex-M7 (decision 0023); the M33 is the network's (0024's amendment)
# the board application's frames channel needs a network file: the fixture's
# switches it off (port 0), SESSION_NET names another
NETF=${SESSION_NET:-$ROOT/tests/app/fixtures/session/port0.net}
echo "session: 2. the board application, built for $BOARD"
build() { # name app [args] -> exit status; output in $W/name.out
  n=$1; a=$2; shift 2
  rm -rf "$W/$n"
  if [ "$a" = "$APP" ]; then set -- --net "$NETF" "$@"; fi
  "$RUBY" "$TOOL" build --app "$a" --board "$BOARD" --out "$W/$n" "$@" > "$W/$n.out" 2>&1
  echo $?
}
s=$(date +%s)
rc=$(build board "$APP" --session-image "$SESSION_IMAGE" --session-objects "$SESSION_OBJECTS")
ok "the board application builds and publishes firmware" "$rc:$([ -f "$W/board/firmware/zephyr.elf" ] && echo elf)" "0:elf"
echo "  time build: $(( $(date +%s) - s )) s"
J=$W/board/firmware/build.json
field() { "$RUBY" -rjson -e 'j = JSON.parse(File.read(ARGV[0])); puts(eval(ARGV[1]))' "$J" "$1" 2>/dev/null; }
ok "  build.json states the claim: not a realtime claim" \
   "$(field 'j["session"]["claim"]')" "realtime profile, loop_bound unknown through DoomCore: not a realtime claim"
ok "  the entry's loop_bound is unknown through DoomCore.step and DoomCore.render, each with its reason" \
   "$(field 'l = j["session"]["loop_bound"]["tic"]; "#{l["verdict"]}|" + l["through"].map { |u| "#{u["extern"]}:#{u["reason"].match?(/loop\(s\) without a derived bound/)}" }.join(",")')" \
   "unknown|DoomCore.step:true,DoomCore.render:true"
ok "  the runtime helpers each entry's object calls are recorded" \
   "$(field 'h = j["session"]["helpers"]; %w[doom_core_input doom_core_step doom_core_render].map { |e| "#{e}=#{h[e].join("+")}" }.join(" ")')" \
   "doom_core_input= doom_core_step=__aeabi_ldivmod doom_core_render=__aeabi_ldivmod+__aeabi_uldivmod"
ok "  the code ends below the session area, and the session fits it" \
   "$(field 'a = j["session"]["area"]; i = j["session"]["image"]; "#{a["code_end"].to_i(16) < a["base"].to_i(16)}|#{i["writable_offset"] + i["writable_bytes"] <= a["bytes"]}"')" "true|true"

echo "session: 3. refused, each by its message"
ok "the session written from two contexts" \
   "$(build two "$F/two-contexts/app.rb" --session-image "$SESSION_IMAGE" --session-objects "$SESSION_OBJECTS"):$(grep -c 'step 7: core_session: the session is written from one context, and tic (thread), poke (interrupt)' "$W/two.out")" "1:1"
ok "an entry that writes a resource of the session" \
   "$(build res "$F/writes-resource/app.rb" --session-image "$SESSION_IMAGE" --session-objects "$SESSION_OBJECTS"):$(grep -c 'step 7: core_session: entry tic writes renderer_jobmode, a resource of the session, which is read-only' "$W/res.out")" "1:1"
ok "a provider other than session.c calling a DOOM entry" \
   "$(build sneak "$F/foreign-provider/app.rb" --session-image "$SESSION_IMAGE" --session-objects "$SESSION_OBJECTS"):$(grep -c 'step 5: the provider sneak.c calls spinel_core_doom_core_step (entry: a call back into CORE' "$W/sneak.out")" "1:1"
ok "session arguments for an application with no core_session" \
   "$(build plain "$ROOT/tests/app/fixtures/build/rt1186/app.rb" --session-image "$SESSION_IMAGE" --session-objects "$SESSION_OBJECTS"):$(grep -c 'step 1: --session-image and --session-objects belong to an application with a core_session' "$W/plain.out")" "1:1"

echo "session: 4. core_session dtcm: (0021, the screen in DTCM)"
NM_BIN=$("$RUBY" -e 'puts File.join(File.dirname(ARGV[0]), "llvm-nm")' "${CLANG:-${LLVM_PREFIX:-}/bin/clang}")
# the image's address of a symbol against the zephyr,dtcm node's range, read
# from the published devicetree: in, out, or absent
chosen_where() { # firmware-dir symbol chosen-property
  "$NM_BIN" "$1/zephyr.elf" 2>/dev/null | awk -v s="$2" '$3 == s { print $1 }' | head -1 > "$W/chosen.addr"
  "$RUBY" -I"$ROOT/tools/app/lib" -e 'require "core_app/dts"
    a = File.read(ARGV[1]).strip; (puts "absent"; exit) if a.empty?
    t = CoreApp::Dts.read(ARGV[0]); r = t.by_path("/chosen")[ARGV[2]]; (puts "none"; exit) unless r
    n = t.resolve(r.flatten.first, ARGV[2]); b, z = n.cells("reg")
    puts (b...(b + z)).cover?(a.to_i(16)) ? "in" : "out"' "$1/zephyr.dts" "$W/chosen.addr" "$3"
}
dtcm_where() { chosen_where "$1" "$2" zephyr,dtcm; }
ok "the board application's screen is in the data TCM, and build.json records it" \
   "$(dtcm_where "$W/board/firmware" spc_dtcm_renderer_screen):$("$RUBY" -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["session"]["dtcm"].to_a.flatten.join("=")' "$W/board/firmware/build.json" 2>/dev/null)" \
   "in:renderer_screen=64000"
r1=$(build dscreen "$F/dtcm-screen/app.rb" --session-image "$SESSION_IMAGE" --session-objects "$SESSION_OBJECTS")
r2=$(build dnone "$F/dtcm-none/app.rb" --session-image "$SESSION_IMAGE" --session-objects "$SESSION_OBJECTS")
sid() { "$RUBY" -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["session"]["id"]' "$1/firmware/build.json" 2>/dev/null; }
ok "with the keyword the screen is in the data TCM, without it there is no such array, and the two session ids differ" \
   "$r1:$r2:$(dtcm_where "$W/dscreen/firmware" spc_dtcm_renderer_screen):$(dtcm_where "$W/dnone/firmware" spc_dtcm_renderer_screen):$([ -n "$(sid "$W/dscreen")" ] && [ "$(sid "$W/dscreen")" != "$(sid "$W/dnone")" ] && echo differ)" \
   "0:0:in:absent:differ"
ok "refused: a field that does not fit the data TCM, at step 8 with the bytes" \
   "$(build dover "$F/dtcm-overflow/app.rb" --session-image "$SESSION_IMAGE" --session-objects "$SESSION_OBJECTS"):$(grep -c "step 8: the data TCM holds [0-9]* B; the scheduler stack ([0-9]* B) and the session's dtcm: fields (jobs_zonebuf 393216 B) need [0-9]* B" "$W/dover.out")" "1:1"
ok "refused: a resource, at step 1" \
   "$(build dres "$F/dtcm-resource/app.rb" --session-image "$SESSION_IMAGE" --session-objects "$SESSION_OBJECTS"):$(grep -c 'step 1: core_session dtcm: renderer_colormap is in part resource; only a writable field can be kept in the data TCM' "$W/dres.out")" "1:1"

echo "session: 5. the board's session_itcm_entries (decision 0023)"
itcm_json() { "$RUBY" -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["session"]["itcm"].to_a.flatten.join("=")' "$1/firmware/build.json" 2>/dev/null; }
if grep -q '^session_itcm_entries	doom_core_render' "$ROOT/tools/app/zephyr/v4.4.2/boards/$BOARD.tsv"; then
  ok "$BOARD keeps the render entry's code in the instruction TCM, and build.json records its bytes" \
     "$(chosen_where "$W/board/firmware" spinel_core_doom_core_render zephyr,itcm):$(itcm_json "$W/board" | sed 's/=[1-9][0-9]*$/=bytes/')" "in:doom_core_render=bytes"
  ok "refused: the render and step entries together, at step 4 with the bytes" \
     "$(build itover "$APP" --session-image "$SESSION_IMAGE" --session-objects "$SESSION_OBJECTS" --mutate-itcm-entries "doom_core_render doom_core_step"):$(grep -c "step 4: the instruction TCM holds [0-9]* B; the entries' code (doom_core_render [0-9]* B, doom_core_step [0-9]* B) needs [0-9]* B" "$W/itover.out")" "1:1"
  r=$(build itnone "$APP" --session-image "$SESSION_IMAGE" --session-objects "$SESSION_OBJECTS" --mutate-itcm-entries "")
  ok "with none named the code stays in the NOR, build.json records none, and the session id differs" \
     "$r:$(chosen_where "$W/itnone/firmware" spinel_core_doom_core_render zephyr,itcm):$(itcm_json "$W/itnone"):$([ -n "$(sid "$W/board")" ] && [ "$(sid "$W/board")" != "$(sid "$W/itnone")" ] && echo differ)" \
     "0:out::differ"
else
  ok "$BOARD names no session_itcm_entries: the render entry's code is not in the instruction TCM, and build.json records none" \
     "$(chosen_where "$W/board/firmware" spinel_core_doom_core_render zephyr,itcm | sed 's/^none$/out/'):$(itcm_json "$W/board")" "out:"
fi
summary
