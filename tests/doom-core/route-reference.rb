# frozen_string_literal: true
#
# tests/doom-core/route-reference.rb — the original's state at the route's checkpoints.
#
#   ruby tests/doom-core/route-reference.rb WAD DEMO LAYOUT SCHEMA T,T... DIR
#
# Plays DEMO with the unmodified library the way examples/doom/bin/sim_demo.rb
# does, with the renderer in job mode 1, and before each tic T writes
# Doom::Core::Reference's snapshot as DIR/original-T.bin, over the rows
# tests/doom-core/route-lane.rb gives LAYOUT (the route's generated
# snapshot.tsv) for that checkpoint. route-demo.rb writes DIR/route-T.bin over
# the same rows; tests/doom-core/compare-state.rb compares the two.
#
# WHAT IT REFUSES TO WRITE. A field the reference cannot read, or cannot encode,
# is printed and the run fails: its bytes would be the schema's initial on this
# side, and comparing them would say nothing. Of the fields no original holds
# (`added:`), the snapshot layout keeps two, and this side writes what the loop
# it plays gives them: core_frame, the frames drawn, and core_command, the
# command the last tic was given (the route leaves the fifth cell at 0). Both
# sides take the command from the same demo, so core_command catches only a
# step entry that writes it; it is not an independent check of the command.
ROOT = File.expand_path("../..", __dir__)
%w[wad level texnames texture sprites statusbar hud render info random game input record jobs executor
   demo].each { |f| require File.join(ROOT, "examples/doom/lib/doom", f) }
require File.join(ROOT, "examples/doom/core/full/reference")
require_relative "route-lane"
require "tmpdir"
R = Doom::Core::Reference

ARGV.length == 6 or abort("usage: route-reference.rb WAD DEMO LAYOUT SCHEMA T,T... DIR")
wad_path, demo_name, layout_path, schema, list, dir = ARGV
checkpoints = RouteLane.checkpoints(list)
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

wad = Doom::Wad.new(wad_path)
demo = Doom::Demo.new(wad, demo_name, "")
lv = Doom::Level.new(wad, demo.mapname, demo.episode)
tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
rnd = Doom::Random.new
rnd.clear
g = Doom::Game.new(wad, lv, demo.skill, rnd, tx)
cm = wad.bytes_by_name("COLORMAP")
sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
sb = Doom::StatusBar.new(wad)
sb.start(g.pl_weaponowned)
r = Doom::Renderer.new(lv, wad, cm, tx, sp, g, 10, false, 1)
r.job_mode = 1
hud = Doom::Hud.new(wad, r.screenwidth, r.screenheight, 1)
script_path = File.join(Dir.mktmpdir("route-ref"), "s.txt")
File.write(script_path, "0 10 forward\n")
# The objects bin/doom.rb builds for the input step, which a played demo never
# calls: they are read as they were built. The renderer's own Jobs and
# JobExecutor are the ones job mode 1 runs.
objects = { "Game" => g, "Level" => lv, "Random" => rnd, "Renderer" => r, "StatusBar" => sb, "Hud" => hud,
            "Textures" => tx, "Sprites" => sp, "Wad" => wad, "KeyState" => Doom::KeyState.new,
            "TiccmdBuilder" => Doom::TiccmdBuilder.new, "DemoWriter" => Doom::DemoWriter.new(2, 1, 1, 40_000),
            "Jobs" => r.instance_variable_get(:@jobs), "JobExecutor" => r.instance_variable_get(:@exec),
            "KeyScript" => Doom::KeyScript.new(script_path) }
R.check_graph(objects)
origins = R.read_origins(schema)
weapon_ammo = Doom::Info.weapon_ammo

failed = false
snap = lambda do |t|
  rows = RouteLane.rows(layout_path, t)
  res = R.snapshot(layout: rows, origins: origins, objects: objects)
  bad = res.unreachable + res.errors
  bad.each { |b| puts "route-reference: before tic #{t}: cannot speak for #{b}" }
  failed ||= !bad.empty?
  puts "route-reference: before tic #{t}: #{rows.length} field(s), #{res.added.length} added " \
       "(#{res.added.join(' ')}), #{bad.length} unreadable"
  bytes = res.bytes
  rows.each do |row|
    next unless res.added.include?(row["field"])
    cells =
      case row["field"]
      when "core_frame" then [t]
      when "core_command"
        t.zero? ? [0] * 5 : [demo.forwardmove[t - 1], demo.sidemove[t - 1], demo.angleturn[t - 1], demo.buttons[t - 1], 0]
      else
        puts "route-reference: before tic #{t}: #{row['field']} has no original and no value here"
        failed = true
        next
      end
    bytes[row["offset"], row["bytes"]] = cells.pack(R::PACK.fetch(row["element"]) + "*")
  end
  File.binwrite(File.join(dir, "original-#{t}.bin"), bytes)
  # The session-open-only cells, as the original holds them: the column
  # selector as job mode 1 keeps it, and the span pair converted from
  # @ds_source, which every plane sets in either mode (render.rb:1328).
  ds = r.instance_variable_get(:@ds_source)
  k = tx.instance_variable_get(:@flatdata).index { |d| d.equal?(ds) }
  ds.empty? || k or abort("route-reference: @ds_source is none of the flats before tic #{t}")
  # At session open the column selector is the conversion's RES_NONE, which is
  # what the rows compare; after a frame it is job mode 1's own @dc_srcres.
  dc = t.zero? ? -1 : r.instance_variable_get(:@dc_srcres)
  RouteLane.write_open_only({ "renderer_dc_srcres" => dc, "renderer_ds_srcres" => ds.empty? ? -1 : 3,
                              "renderer_ds_srcbase" => ds.empty? ? 0 : k * 4096 },
                            File.join(dir, "original-#{t}.open-only.tsv"))
end

last = checkpoints.max
n = [last, demo.numtics].min
t = 0
while t <= n
  snap.(t) if checkpoints.include?(t)
  break if t == n
  rnd.tic = t
  320.times { rnd.m_random } if t == 2
  g.g_ticker(demo.forwardmove[t], demo.sidemove[t], demo.angleturn[t], demo.buttons[t])
  st_randomnumber = rnd.m_random
  m = g.player_mo
  atk = g.pl_attacker
  kind = atk < 0 ? 0 : (atk == m ? 1 : 2)
  bga = atk >= 0 ? g.point_to_angle2(g.mobj_x[m], g.mobj_y[m], g.mobj_x[atk], g.mobj_y[atk]) : 0
  sb.ticker(st_randomnumber, g.pl_health, g.pl_weaponowned, g.pl_cards, g.pl_damagecount, g.pl_bonuscount,
            g.pl_attackdown, g.pl_powers[0], kind, bga, g.mobj_angle[m])
  hud.ticker(g.take_message)
  r.clear_screen if t.zero?
  r.set_psprite(g.psp_state[0], g.psp_sx[0], g.psp_sy[0])
  r.set_psprite_flash(g.psp_state[1], g.psp_sx[1], g.psp_sy[1])
  r.extralight = g.extralight
  r.render_player_view(g.viewx, g.viewy, g.viewz, g.viewangle)
  ak = weapon_ammo[g.pl_readyweapon]
  sb.draw(r.screen, g.pl_health, g.pl_armorpoints, g.pl_ammo, g.pl_maxammo, g.pl_weaponowned, g.pl_readyweapon, ak)
  hud.draw(r.screen)
  t += 1
end
(checkpoints - (0..n).to_a).each { |c| puts "route-reference: #{demo_name} has #{demo.numtics} tic(s); no checkpoint #{c}" }
printf("route-reference: %s, %d checkpoint(s), %.1f s\n", demo_name, checkpoints.length,
       Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0)
exit(failed || checkpoints.max > n ? 1 : 0)
