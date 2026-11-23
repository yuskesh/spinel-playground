# frozen_string_literal: true
#
# tools/doom/use-probe.rb — what the use key did, from a recording.
#
#   ruby tools/doom/use-probe.rb --wad FILE --lmp FILE [--tics N] [--out FILE]
#
# WHY THIS EXISTS. A real-key session reports "I pressed use and nothing
# happened", and the import has no sound: grep finds no sfx_noway and no
# S_StartSound anywhere under examples/doom. In vanilla that "oof" is what
# separates "this is not a door" from "the door is broken", so without it those
# two are THE SAME EXPERIENCE at the keyboard and the report cannot distinguish
# them. This replays the session's own `-record` file against the same
# examples/doom/lib the binary is built from and says, for every press, which of
# the two happened.
#
# It was written after a session on E1M1 where nineteen use presses reached zero
# doors: thirteen were at the fake-door recess in the start room (line 0, one
# sided, ML_BLOCKING, special 0, midtexture DOOR3 with LITE3 either side), which
# vanilla ignores as well. The port was correct and looked broken.
#
# WHAT IT EMITS: a TSV, one row per `use_lines` call, seven columns —
#
#   tic       the gametic the press edge landed on
#   x, y      the player's position, in map units
#   angle     the player's facing, in degrees (0 is east, 90 north)
#   line      the linedef the use ray hit, or -1 for none in range
#   special   that linedef's special, so 0 reads as "not a trigger"
#   outcome   one of:
#               no-line-in-range   the 64-unit ray found no linedef at all
#               blocked-wall       a one-sided or closed line; vanilla plays
#                                  sfx_noway here and does nothing else
#               passed-through     a special-0 two-sided line, kept scanning
#               not-a-trigger      a special the vanilla switch does not carry
#               used               P_UseSpecialLine ran for this line
#
# and, on stderr, the summary that turns the trace into an answer: how many
# press edges the recording holds, how many `use_lines` calls they produced, and
# THE CLOSEST THE PLAYER EVER CAME TO A USABLE LINEDEF against USERANGE. A trace
# showing "blocked-wall" nineteen times is an explanation; the distance is what
# settles it without appealing to what the player meant to do.
#
# WHAT IT DOES NOT ANSWER, because both limits have cost a day already:
#
#   * PACING. How long a tic took is not a function of what was pressed, so no
#     replay can recover it. That is `doom -stats FILE`, and a session should
#     carry BOTH flags always — `-record` answers questions nobody had thought
#     of yet, `-stats` answers the only question `-record` cannot.
#   * IT IS AN ORACLE FOR SOURCE SEMANTICS. It runs the library in hosted Ruby,
#     not the compiled program. It is faithful for the use question only while
#     the compiled path is known to agree on that same input, and the second
#     instrument is what establishes that:
#
#       doom -iwad WAD -playdemo @FILE -frames a.tsv        # the original path
#       doom -iwad WAD -core -playdemo @FILE -frames b.tsv  # and CORE
#       cmp a.tsv b.tsv
#
#     Re-establish it per recording rather than carrying it forward: a question
#     specifically about the compiled path goes to -playdemo, never to here.
#
# HOW TO GET A RECORDING:
#
#   doom -iwad build/doom-wad/doom1.wad -core -record k.lmp -stats s.tsv
#
# The instrumentation is a prepended module, so nothing under examples/doom is
# modified or copied to run this.
#
# AND ONE TRAP IN TESTING A PRESS BY HAND, BECAUSE IT FAILS SILENTLY THE SAME WAY
# THE REPORT DOES. Placing the player by assigning mobj_x and mobj_y leaves the
# sector and blockmap links pointing at the old position, and G_Ticker then never
# reaches the use handling at all -- no use_lines call, no refusal, nothing
# moves. A press tested that way is INCONCLUSIVE, NOT NEGATIVE, and it looks
# exactly like a press that did nothing. Either walk the player there with real
# ticcmds through g_ticker, which is what a recording does, or call use_lines
# directly and accept that you are testing the use path rather than the player.

# It replays a recorded session under CRuby; whether that is an oracle is the
# owner's to classify (tests/ORACLES.tsv), so it is gated until then.
require_relative "../oracle/gate"
exit 0 unless OracleGate.allow?("tools/doom/use-probe.rb", "whole")
require "optparse"

ROOT = File.expand_path("../..", __dir__)
LIB = File.join(ROOT, "examples/doom/lib/doom")
%w[wad level texnames texture sprites statusbar hud render info random demo
   game bytes hires].each { |f| require File.join(LIB, f) }

FRAC = 65_536.0
# The manual-door cases of p_switch.c's P_UseSpecialLine, which the port carries
# at examples/doom/lib/doom/specials.rb in use_special_line. Named here only to
# label a row; what counts as usable at all is read from the port's own
# USE_SPECIALS table below rather than copied.
MANUAL_DOORS = [1, 26, 27, 28, 31, 32, 33, 34].freeze

opt = { tics: nil, out: nil }
OptionParser.new do |o|
  o.banner = "usage: ruby tools/doom/use-probe.rb --wad FILE --lmp FILE " \
             "[--tics N] [--out FILE]"
  o.on("--wad FILE", "the IWAD the recording was made against") { |v| opt[:wad] = v }
  o.on("--lmp FILE", "a .lmp written by doom -record") { |v| opt[:lmp] = v }
  o.on("--tics N", Integer, "stop after N tics (default: the whole recording)") { |v| opt[:tics] = v }
  o.on("--out FILE", "write the TSV here instead of stdout") { |v| opt[:out] = v }
end.parse!

def refuse(msg)
  warn "use-probe: #{msg}"
  exit 2
end

%i[wad lmp].each { |k| opt[k] or refuse("--#{k} is required") }
File.file?(opt[:wad]) or refuse("no IWAD at #{opt[:wad]}")
File.file?(opt[:lmp]) or refuse("no recording at #{opt[:lmp]}")

# --- the instrumentation ------------------------------------------------------
# One row per use_lines call. ptr_use_traverse fires once per linedef the ray
# crosses, so the row keeps the LAST line considered and the outcome that ended
# the traverse -- which is what the player experienced.
#
# The position and facing are read INSIDE use_lines, which is the state that
# actually aimed the ray. A per-tic dump taken after G_Ticker returns can differ
# by a few units for the same tic, because the player has moved since; neither
# is wrong, and this is the one that explains the row.
$rows = []
$row = nil

module UseProbe
  def use_lines
    m = @player_mo
    $row = { tic: $tic, x: @mobj_x[m] / FRAC, y: @mobj_y[m] / FRAC,
             angle: @mobj_angle[m] * 360.0 / 2**32, line: -1, special: 0,
             outcome: "no-line-in-range" }
    super
    $rows << $row
    $row = nil
  end

  def ptr_use_traverse(idx)
    li = @ic_thing[idx]
    sp = @level.line_special[li]
    keep = super
    return keep if $row.nil?

    $row[:line] = li
    $row[:special] = sp
    $row[:outcome] =
      if sp != 0
        Doom::Game::USE_SPECIALS.include?(sp) ? "used" : "not-a-trigger"
      elsif keep
        "passed-through"
      else
        "blocked-wall"
      end
    keep
  end
end
Doom::Game.prepend(UseProbe)

# --- replay -------------------------------------------------------------------
wad = Doom::Wad.new(opt[:wad])
demo = Doom::Demo.new(wad, opt[:lmp], opt[:lmp])
lv = Doom::Level.new(wad, demo.mapname, demo.episode)
tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
rnd = Doom::Random.new
rnd.clear
g = Doom::Game.new(wad, lv, demo.skill, rnd, tx)

ntics = opt[:tics] && opt[:tics] < demo.numtics ? opt[:tics] : demo.numtics

# Every linedef a use press could trigger at all, read from the port's own table
# so this cannot drift from what use_special_line implements.
usable = (0...lv.num_lines).select { |i| Doom::Game::USE_SPECIALS.include?(lv.line_special[i]) }

def seg_dist(px, py, ax, ay, bx, by)
  dx = bx - ax
  dy = by - ay
  len2 = (dx * dx) + (dy * dy)
  t = len2.zero? ? 0.0 : (((px - ax) * dx) + ((py - ay) * dy)) / len2
  t = t.clamp(0.0, 1.0)
  Math.sqrt(((px - (ax + (t * dx)))**2) + ((py - (ay + (t * dy)))**2))
end

nearest = { dist: Float::INFINITY, line: -1, tic: -1 }
edges = 0
prev = 0
$tic = 0
while $tic < ntics
  rnd.tic = $tic
  # The reference harness's melt wipe draws 320 M_Random values once, between
  # gametic 1's draw and gametic 2's G_Ticker. Gameplay uses P_Random only, but
  # keeping it makes this replay's random stream the recording's own.
  320.times { rnd.m_random } if $tic == 2
  b = demo.buttons[$tic]
  edges += 1 if (b & 2) != 0 && (prev & 2) == 0
  prev = b
  g.g_ticker(demo.forwardmove[$tic], demo.sidemove[$tic], demo.angleturn[$tic], b)
  rnd.m_random

  m = g.player_mo
  px = g.mobj_x[m] / FRAC
  py = g.mobj_y[m] / FRAC
  usable.each do |li|
    d = seg_dist(px, py,
                 lv.vertex_x[lv.line_v1[li]] / FRAC, lv.vertex_y[lv.line_v1[li]] / FRAC,
                 lv.vertex_x[lv.line_v2[li]] / FRAC, lv.vertex_y[lv.line_v2[li]] / FRAC)
    nearest = { dist: d, line: li, tic: $tic } if d < nearest[:dist]
  end
  $tic += 1
end

# --- report -------------------------------------------------------------------
out = opt[:out] ? File.open(opt[:out], "w") : $stdout
out.puts "#tic\tx\ty\tangle\tline\tspecial\toutcome"
$rows.each do |r|
  out.puts format("%d\t%.1f\t%.1f\t%.1f\t%d\t%d\t%s",
                  r[:tic], r[:x], r[:y], r[:angle], r[:line], r[:special], r[:outcome])
end
out.close unless out.equal?($stdout)

userange = Doom::USERANGE / 65_536
by_outcome = $rows.group_by { |r| r[:outcome] }.transform_values(&:length).sort.to_h

warn "use-probe: #{demo.mapname} skill #{demo.skill}, #{ntics} of #{demo.numtics} tic(s) replayed"
warn "use-probe: #{edges} use press edge(s) in the recording, #{$rows.length} use_lines call(s)"
warn "use-probe: outcomes #{by_outcome.inspect}"
warn "use-probe: #{usable.length} linedef(s) on this map can be used at all; " \
     "#{usable.count { |i| MANUAL_DOORS.include?(lv.line_special[i]) }} are manual doors"
if nearest[:line] >= 0
  warn format("use-probe: closest the player EVER came to a usable linedef: " \
              "%.1f unit(s) (line %d, special %d) at tic %d, against USERANGE %d",
              nearest[:dist], nearest[:line], lv.line_special[nearest[:line]],
              nearest[:tic], userange)
  if nearest[:dist] > userange
    warn "use-probe: so NOTHING USABLE WAS EVER IN RANGE -- every press correctly " \
         "did nothing, and the report is about the map rather than the port"
  end
else
  warn "use-probe: this map has no usable linedef, so use does nothing anywhere on it"
end
