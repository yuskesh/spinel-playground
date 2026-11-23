# frozen_string_literal: true
#
# tests/doom-core/scenarios.rb — synthesised starts for code no demo reaches.
#
# V7's bucket 2 and 3 (the owner's decision (c) of 2026-09-17): the
# definitions the shipped IWAD reaches in play and DEMO1-3 do not. Each
# scenario is a level, a skill, a length, a SETUP before tic 0 -- a thing moved
# with the original's own Game#teleport_move, P_CheckPosition and P_CheckSight
# consulted, a player damaged with Game#damage_mobj, and direct stores into the
# original's arrays where it has no method (a z, an angle, a weapon owned, an
# ammo count, a health) -- a key script that bin/doom.rb's input step turns
# into commands,
# and the port definitions it must enter. tests/doom-core/step-diff.rb runs one
# with `scenario:NAME` in place of a demo, compares every tic as it does for a
# demo, and fails a scenario that does not enter every one of its targets: a
# start that misses its target proves nothing about it.
#
# A scenario with `stops: true` is the witness the owner's CAPACITY decision
# asks for: the original raises at some tic, and the port must refuse at that
# same tic, IN THE DEFINITION `stop_in` NAMES (the port's frame nearest the
# refusal); step-diff then ends the run there. What
# makes the label acceptable rather than merely tolerable is the other half,
# which this CRuby lane does not run: called through the 0007 adapter, the entry
# returns CAPACITY with its mutable participants POISONED, so a caller that
# ignores the status reads obviously broken values, not plausible ones. A direct
# C call is not poisoned (docs/core/doom-closure-gaps.md section 9); the native
# program's route decides which it gets, and V6 is where that is run.
require_relative "../../examples/doom/lib/doom/info"
require_relative "../../examples/doom/lib/doom/input"

module Scenarios
  ANG = 4_294_967_296
  FRAC = 65_536
  module_function

  def type_of(dn) = Doom::Info.mobj_doomednum.index(dn) or raise "no mobj type for doomednum #{dn}"

  # the live mobjs of doomednum `dn`, in slot order
  def things(g, dn)
    t = type_of(dn)
    th = g.instance_variable_get(:@mobj_th)
    (0...g.mobj_type.length).select { |m| th[m] >= 0 && g.mobj_type[m] == t }
  end

  # move `m` with the original's P_TeleportMove, onto the floor, facing `angle`
  def put(g, m, x, y, angle)
    g.teleport_move(m, x, y) or raise "teleport_move refused #{m} at #{x >> 16},#{y >> 16}"
    g.mobj_z[m] = g.mobj_floorz[m]
    g.mobj_angle[m] = angle % ANG
  end

  # the player standing on thing `it`: P_TeleportMove stomps only shootable
  # things, so nothing is picked up until the player's first move checks its
  # position -- which touches the item before any line can block the move
  def onto(g, it)
    put(g, g.player_mo, g.mobj_x[it], g.mobj_y[it], 0)
  end

  # the player `dist` units in front of line `ln` (its right side), facing it
  def face_line(g, ln, dist)
    lv = g.level
    v1 = lv.line_v1[ln]
    v2 = lv.line_v2[ln]
    x1, y1, x2, y2 = lv.vertex_x[v1], lv.vertex_y[v1], lv.vertex_x[v2], lv.vertex_y[v2]
    mx = (x1 + x2) / 2
    my = (y1 + y2) / 2
    len = Math.hypot(x2 - x1, y2 - y1)
    px = mx + ((y2 - y1) / len * dist * FRAC).to_i
    py = my - ((x2 - x1) / len * dist * FRAC).to_i
    put(g, g.player_mo, px, py, g.point_to_angle2(px, py, mx, my))
  end

  # a point inside a sector with `special`: the centre of one of its subsectors,
  # which are convex
  def inside_sector(g, special)
    lv = g.level
    sec = (0...lv.sector_special.length).find { |k| lv.sector_special[k] == special } or raise "no sector with special #{special}"
    ss = (0...lv.ss_sector.length).find { |k| lv.ss_sector[k] == sec } or raise "no subsector of sector #{sec}"
    first = lv.ss_firstline[ss]
    n = lv.ss_numlines[ss]
    vs = (first...first + n).map { |k| lv.seg_v1[k] }
    [vs.sum { |v| lv.vertex_x[v] } / vs.length, vs.sum { |v| lv.vertex_y[v] } / vs.length]
  end

  # the `nth` line (from 0) carrying `special`
  def line_with(g, special, nth = 0)
    lv = g.level
    (0...lv.line_special.length).select { |l| lv.line_special[l] == special }[nth] or
      raise "no line #{nth} with special #{special}"
  end

  def give(g, weapon, ammo_kind, ammo)
    g.pl_weaponowned[weapon] = true
    g.pl_ammo[ammo_kind] = ammo if ammo_kind
  end

  # weapons (d_items), ammo kinds (clip, shell, cell, missile)
  WP_CHAINGUN = 3
  WP_CHAINSAW = 7

  ALL = {
    "punch" => { map: "E1M1", skill: 2, tics: 60, targets: %w[dc_st_kp_a_punch],
                 script: "0 2 w1\n10 50 fire" },
    "saw" => { map: "E1M2", skill: 2, tics: 60, targets: %w[dc_st_kp_a_saw],
               setup: ->(g) { give(g, WP_CHAINSAW, nil, nil) }, script: "0 2 w1\n20 50 fire" },
    "chaingun" => { map: "E1M1", skill: 2, tics: 60, targets: %w[dc_st_kp_a_fire_cgun],
                    setup: ->(g) { give(g, WP_CHAINGUN, 0, 100) }, script: "0 2 w4\n20 50 fire" },
    "backpack" => { map: "E1M2", skill: 2, tics: 40, targets: %w[dc_st_give_backpack],
                    setup: ->(g) { onto(g, things(g, 8).first) }, script: "0 3 forward" },
    "soulsphere" => { map: "E1M2", skill: 2, tics: 40, targets: %w[dc_st_sprite_soul],
                      setup: ->(g) { onto(g, things(g, 2013).first) }, script: "0 3 forward" },
  }
  # the four powers the shipped IWAD places: invisibility, suit, map, visor
  { "invisibility" => ["E1M3", 2024], "suit" => ["E1M5", 2025], "allmap" => ["E1M5", 2026],
    "visor" => ["E1M5", 2045] }.each do |name, (map, dn)|
    ALL["power-#{name}"] = { map: map, skill: 2, tics: 40, targets: %w[dc_st_give_power],
                             setup: ->(g) { onto(g, things(g, dn).first) }, script: "0 3 forward" }
  end
  ALL.merge!(
    # an SR switch (70, SW1BRNGN in E1M5): used, it starts the button timer
    "switch" => { map: "E1M5", skill: 2, tics: 40, targets: %w[dc_st_start_button],
                  setup: ->(g) { face_line(g, line_with(g, 70), 32) }, script: "2 4 use" },
    # a WR teleporter (97): walked across from its front side
    "teleport" => { map: "E1M5", skill: 2, tics: 40,
                    targets: %w[dc_st_kp_ev_teleport dc_st_kp_teleport_move dc_st_kp_block_things_iterator_stomp],
                    setup: ->(g) { face_line(g, line_with(g, 97), 24) }, script: "0 20 forward" },
    # the same, with an imp standing on the destination: the teleport stomps it
    "telefrag" => { map: "E1M5", skill: 2, tics: 40,
                    targets: %w[dc_st_kp_ev_teleport dc_st_kp_pit_stomp_thing],
                    setup: lambda { |g|
                      d = things(g, 14).first
                      imp = things(g, 3001).first
                      put(g, imp, g.mobj_x[d], g.mobj_y[d], 0)
                      face_line(g, line_with(g, 97), 24)
                    },
                    script: "0 20 forward" },
    # E1M8's barons stand behind doors a W1 open-door line (special 2) opens:
    # the player walks over it, the doors open, and a baron that sees the player
    # attacks it
    "baron-attack" => { map: "E1M8", skill: 2, tics: 120, targets: %w[dc_st_kp_a_bruis_attack],
                        setup: ->(g) { face_line(g, line_with(g, 2), 24) }, script: "0 25 forward" },
    # THE CAPACITY WITNESS: a baron that dies reaches A_BossDeath, which the
    # original does not implement; both must stop at the same tic. Both barons
    # open at one hit point, and the player has a shotgun.
    "baron-death" => { map: "E1M8", skill: 2, tics: 200, targets: %w[dc_st_a_boss_death], stops: true,
                       stop_in: "dc_st_a_boss_death",
                       setup: lambda { |g|
                         things(g, 3003).each { |b| g.mobj_health[b] = 1 }
                         give(g, 2, 1, 50)
                         # the second cage line: from the first, no shot reaches a baron
                         face_line(g, line_with(g, 2, 1), 24)
                       },
                       script: "0 2 w3\n0 25 forward\n30 180 fire" },
    # THE OTHER ORIGINAL RAISES SHIPPED CONTENT REACHES, each ported as
    # core_fail(:capacity) with its reason at the port's site: an
    # unimplemented walk-over special (36, E1M1), an unimplemented switch (9,
    # E1M2), a gun-activated line (46, E1M2), E1M8's exit sector at low health,
    # and a dead player pressing use (G_DoReborn)
    "walk-36" => { map: "E1M1", skill: 2, tics: 40, targets: %w[dc_st_kp_cross_special_line], stops: true,
                   stop_in: "dc_st_kp_cross_special_line",
                   setup: ->(g) { face_line(g, line_with(g, 36), 24) }, script: "0 30 forward" },
    "use-9" => { map: "E1M2", skill: 2, tics: 40, targets: %w[dc_st_use_special_line], stops: true,
                 stop_in: "dc_st_use_special_line",
                 setup: ->(g) { face_line(g, line_with(g, 9), 32) }, script: "2 4 use" },
    "shoot-46" => { map: "E1M2", skill: 2, tics: 60, targets: %w[dc_st_shoot_special_line], stops: true,
                    stop_in: "dc_st_shoot_special_line",
                    setup: ->(g) { face_line(g, line_with(g, 46), 96) }, script: "20 40 fire" },
    "exit-11" => { map: "E1M8", skill: 2, tics: 10, targets: %w[dc_st_kp_player_in_special_sector], stops: true,
                   stop_in: "dc_st_kp_player_in_special_sector",
                   setup: lambda { |g|
                     g.instance_variable_set(:@pl_health, 10)
                     g.mobj_health[g.player_mo] = 10
                     x, y = inside_sector(g, 11)
                     put(g, g.player_mo, x, y, 0)
                   },
                   script: "0 1 forward" },
    # REBIRTH TWO WAYS (the owner's decision of 2026-09-17). The shipped
    # program refuses it BEFORE the step, in Full (Session#before_step!):
    # `reborn` shows Full refusing at the tic the original raises, with the
    # entry not entered. `reborn` run with --no-full-guard calls the entry
    # anyway and shows only that CORE's backstop refuses if it is ever reached
    # -- which is narrower, and is not evidence for the first.
    "reborn" => { map: "E1M1", skill: 2, tics: 80, targets: %w[dc_st_kp_g_ticker], stops: true,
                  stop_in: "dc_st_kp_g_ticker", full_refuses: true,
                  setup: ->(g) { g.damage_mobj(g.player_mo, -1, -1, 1000) }, script: "30 70 use" },
  )

  # the commands bin/doom.rb's input step makes from a scenario's key script
  def commands(sc)
    script = Dir.mktmpdir("scenario") do |d|
      path = File.join(d, "keys.txt")
      File.write(path, sc[:script] + "\n")
      Doom::KeyScript.new(path)
    end
    ks = Doom::KeyState.new
    tc = Doom::TiccmdBuilder.new
    Array.new(sc[:tics]) do |t|
      script.apply(ks, t)
      tc.build(ks.down)
      [tc.forwardmove, tc.sidemove, tc.angleturn, tc.buttons]
    end
  end
end
