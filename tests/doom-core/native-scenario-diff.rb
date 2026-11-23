# frozen_string_literal: true
#
# tests/doom-core/native-scenario-diff.rb — a synthesised scenario through the
# COMPILED step entry, against the original evolving beside it.
#
#   ruby tests/doom-core/native-scenario-diff.rb WAD SCENARIO LIB HEADERS WORKDIR \
#        [--plant FIELD[IDX]=VALUE@TIC] [--tics N]
#
# LIB links the three generated adapters and the kernel objects
# (tests/doom-core/harness/artifacts.sh); HEADERS is the adapter generator's
# directory; WORKDIR receives the catalog this scenario's map measures and the
# layout generated from it.
#
# WHY IT EXISTS. tests/doom-core/step-diff.rb runs the 19 scenarios of
# tests/doom-core/scenarios.rb against the original, but it runs the port as
# plain Ruby; the compiled objects were exercised by DEMO1-3 alone, which enter
# E1M5, E1M3 and E1M7 and nothing else. The definitions only the scenarios
# reach were therefore compared in CORE-source execution only. This lane
# supplies the same corpus to the compiled step entry, so that EVERY DEFINITION
# EXERCISED BY THE DIFFERENTIAL CORPUS IS EXERCISED AND COMPARED IN BOTH
# CORE-SOURCE AND COMPILED-OBJECT EXECUTION (decision 0009).
#
# HOW IT COMPARES, and it is not step-diff's way. step-diff copies the
# original's state into the port's layout before every tic, so each tic is an
# independent comparison. The compiled entry's state lives in the adapter's
# registry, where that copy would be tens of megabytes of stores per tic; so
# here the two sides EVOLVE INDEPENDENTLY from one prepared start, and the
# first tic whose compared values differ is the divergence. That is the
# stronger arrangement for a regression lane -- a difference persists instead
# of being overwritten -- and the weaker one for locating a cause, which the
# source lane already does.
#
# THE CADENCE (the macOS coordinator's (b), 2026-09-18):
#
#   * EVERY TIC: the gametic the entry answers, and every scalar -- the fields
#     sharing core_state, read back from the registry -- against the original's
#     own ivars through Doom::Core::Reference.
#   * AFTER THE FIRST TIC AND AFTER THE LAST: every field of the generated
#     layout, the buffers included, both sides encoded the same way.
#
# A `scratch` scalar is in neither: the generated layout leaves those rows out
# (tools/doom/state-schema.rb), because a cell that is undefined between calls
# may hold different values on the two sides with neither of them wrong. The
# lane takes that exclusion from the schema's role column, not from how a field
# happened to look before tic 0, and prints how many it left out.
#
# WHAT THAT LEAVES, AND THE LANE SAYS SO IN ITS OWN OUTPUT: an ARRAY-ONLY
# DIVERGENCE -- a buffer cell the compiled side writes differently in a tic
# whose scalars all agree, and which no later tic reads back into a scalar --
# is located by the full comparisons alone. The lane finds it at the end of the
# run and not at the tic that caused it. A divergence any scalar reflects is
# located at its tic.
#
# WHAT A FULL COMPARISON COSTS, AND WHY IT IS NOT MADE CHEAPER. It reads every
# cell of every row back out of the registry, ONE CELL AT A TIME. Measured on
# Debian x86_64 on 2026-09-18 over the layout for E1M1: 15,826,215 buffer cells
# and 231 scalar cells through the registry, 15.6 s per comparison -- 0.99 us a
# cell, which is the route's own per-cell price (route-demo reads 64,000 screen
# cells a tic at the same order). THREE BUFFERS ARE FOUR FIFTHS OF IT:
# hud_data, renderer_wad_data and status_bar_data are 4,196,020 cells each --
# the whole IWAD, three times -- or 12,588,060 of the 15,826,215, 79.5%. Both
# figures are properties of the LAYOUT, so re-measure them rather than quoting
# them if the schema has moved. It has: since decision 0021 the status bar and
# the HUD alias renderer_wad_data, and the IWAD is one buffer, not three.
#
# THE OBVIOUS SAVING IS THE ONE THIS LANE EXISTS TO REFUSE. Skipping those three
# rests on "nothing writes a resource buffer", which is an assumption about the
# compiled entry's behaviour -- and checking the compiled entry's behaviour is
# what this lane is for. If the cost ever has to come down, compare them ONCE
# PER RUN rather than once per comparison AND STATE THAT AS A CLAIM: the saving
# is allowed, the silence is not.
#
# A SCENARIO THAT STOPS (scenarios.rb's `stops:`) ends the run: the original
# raises, and the compiled entry must refuse in the same tic -- CAPACITY
# through the adapter, with its mutable participants poisoned, which ends the
# route -- or, for `full_refuses:`, Full refuses before the call. Nothing is
# read back after a refusal, so the final full comparison cannot be taken
# there; the lane then runs the scenario a SECOND time with that comparison
# after the last tic that completed -- or, when the first tic is the one that
# stops, at session open, which is then the only state the two sides ever
# shared. Either way the second run must stop in the same tic as the first.
ROOT = File.expand_path("../..", __dir__)
%w[wad texnames texture level random info sprites game render statusbar hud jobs executor input record
   demo bytes].each { |f| require File.join(ROOT, "examples/doom/lib/doom", f) }
require File.join(ROOT, "examples/doom/core/full/resources")
require File.join(ROOT, "examples/doom/core/full/route")
require File.join(ROOT, "examples/doom/core/full/reference")
require_relative "route-lane"
require_relative "route-prep"
require_relative "scenarios"
require "tmpdir"
require "fileutils"
R = Doom::Core::Reference

usage = "usage: native-scenario-diff.rb WAD SCENARIO LIB HEADERS WORKDIR [--plant FIELD[IDX]=VALUE@TIC] [--tics N]"
# THE CORPUS, from the file that defines it: the lane's shell script asks for
# it here rather than reading scenarios.rb itself, so the names it runs and the
# names that exist are one list.
if ARGV[0] == "--corpus"
  puts "names\t#{Scenarios::ALL.keys.join(' ')}"
  puts "stops\t#{Scenarios::ALL.select { |_, v| v[:stops] }.keys.join(' ')}"
  puts "maps\t#{Scenarios::ALL.values.map { |v| v[:map] }.tally.sort.map { |m, n| "#{m} x#{n}" }.join(', ')}"
  puts "tics\t#{Scenarios::ALL.values.sum { |v| v[:tics] }}"
  exit 0
end
ARGV.length >= 5 or abort(usage)
WAD_PATH, NAME, LIB, HEADERS, WORK = ARGV[0, 5]
PLANT = (i = ARGV.index("--plant")) ? (ARGV[i + 1].match(/\A(\w+)(?:\[(\d+)\])?=(-?\d+)@(\d+)\z/) || abort(usage)) : nil
CAPTICS = (i = ARGV.index("--tics")) ? Integer(ARGV[i + 1], 10) : nil
SC = Scenarios::ALL.fetch(NAME) { abort("native-scenario-diff: no scenario #{NAME}") }
CMDS = Scenarios.commands(SC)
NTICS = CAPTICS ? [CAPTICS, SC[:tics]].min : SC[:tics]
ORIGINS = R.read_origins(File.join(ROOT, "examples/doom/core/state.tsv"))
# field -> the schema's `role` column, which decides what a comparison can say
# about the field: a `scratch` cell is undefined between calls.
ROLES = File.readlines(File.join(ROOT, "examples/doom/core/state.tsv"))
            .reject { |l| l.start_with?("#") || l.strip.empty? }
            .to_h { |l| f = l.chomp.split("\t", -1); [f[0], f[1]] }
EPISODE = SC[:map].scan(/\d/).map(&:to_i).first

# --- one run of the scenario ----------------------------------------------------
# `full_after` names the tics after which every field is compared; a tic the run
# does not reach takes no comparison. Answers
# [disagreements, the tic the run stopped at or nil, the tics that ran,
#  the tics whose full comparison was taken].
def play(work:, full_after:, announce:)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  # --- the original, built as tests/doom-core/step-diff.rb builds it and as
  # route-demo.rb builds Full's: the SETUP runs on the game before anything
  # else reads it, because the state it writes is the start this scenario is
  # about -- the status bar is started from the weapons it may have given.
  wad = Doom::Wad.new(WAD_PATH)
  FileUtils.mkdir_p(work)
  script = File.join(work, "script.txt")
  File.write(script, SC[:script] + "\n")
  tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
  tx.precache_all
  lv = Doom::Level.new(wad, SC[:map], EPISODE)
  rnd = Doom::Random.new
  rnd.clear
  game = Doom::Game.new(wad, lv, SC[:skill], rnd, tx)
  SC[:setup]&.call(game)
  sprites = Doom::Sprites.new(wad, Doom::Info.sprnames)
  renderer = Doom::Renderer.new(lv, wad, wad.bytes_by_name("COLORMAP"), tx, sprites, game, 10, false, 1)
  renderer.job_mode = 1
  statusbar = Doom::StatusBar.new(wad)
  statusbar.start(game.pl_weaponowned)
  objects = {
    "Doom::Wad" => wad, "Doom::Textures" => tx, "Doom::Level" => lv, "Doom::Random" => rnd,
    "Doom::Game" => game, "Doom::Sprites" => sprites, "Doom::Renderer" => renderer,
    "Doom::StatusBar" => statusbar,
    "Doom::Hud" => Doom::Hud.new(wad, renderer.screenwidth, renderer.screenheight, 1),
    "Doom::KeyScript" => Doom::KeyScript.new(script), "Doom::KeyState" => Doom::KeyState.new,
    "Doom::TiccmdBuilder" => Doom::TiccmdBuilder.new, "Doom::DemoWriter" => Doom::DemoWriter.new(2, 1, 1, 40_000),
    # the renderer's own, which job mode 1 runs: not objects of this file's making
    "Doom::Jobs" => renderer.instance_variable_get(:@jobs),
    "Doom::JobExecutor" => renderer.instance_variable_get(:@exec)
  }
  R.check_graph(objects)
  ref = objects.to_h { |k, o| [k.delete_prefix("Doom::"), o] }
  hud = ref.fetch("Hud")
  session = RoutePrep.session(root: ROOT, work: work, wad: wad, map: SC[:map], script: script,
                              objects: objects, label: "native-scenario-diff")
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  route = Doom::Core::Route.open(lib: LIB, headers: HEADERS, session: session)
  t2 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # --- what is compared, and what is not ------------------------------------
  # THE SCALARS: the fields that share core_state, less two kinds.
  #
  #   * those no original holds (`added:`), which have nothing to compare;
  #   * those the schema gives the role `scratch`. THE LAYOUT LEAVES THEM OUT
  #     BY THE SAME RULE (tools/doom/state-schema.rb: `role == "scratch"` rows
  #     are not in snapshot.tsv), because a scratch cell is undefined between
  #     calls: the two sides may leave different values there and neither is
  #     wrong. Excluded here by the role rather than by how they looked before
  #     tic 0 -- the original creates such an ivar at its first write, and
  #     reading "the reference has no @bombdamage" as "do not compare it" would
  #     drop a persistent field the same way if one were ever unset.
  #
  # Everything else is read EVERY TIC. A field the reference cannot read in a
  # tic is counted out of THAT tic and named at the end with its count.
  silent = []
  scalars = session.slots.keys.select do |f|
    o = ORIGINS[f]
    if o.nil?
      silent << "#{f} (the schema gives it no origin)"
      false
    elsif o.start_with?("added:")
      silent << "#{f} (#{o}: no original holds it)"
      false
    elsif ROLES[f] == "scratch"
      false
    else
      true
    end
  end
  scratch = session.slots.keys.count { |f| ROLES[f] == "scratch" }
  skipped = Hash.new(0)
  # THE FULL STATE: the generated layout's rows, less the three cells compared
  # at session open only (tests/doom-core/route-lane.rb). Neither side draws a
  # frame in this lane, so neither renderer has left the direct path's
  # references behind; they are left out all the same, because what this lane
  # is for is the step.
  rows = RouteLane.rows(File.join(work, "gen", "snapshot.tsv"), 1)
  if announce
    puts "native-scenario-diff: #{NAME}: #{SC[:map]}, skill #{SC[:skill]}, #{NTICS} tic(s); " \
         "targets #{Array(SC[:targets]).join(' ')}#{SC[:stops] ? '; it stops' : ''}"
    puts "native-scenario-diff: cadence: the gametic and #{scalars.length} scalar(s) after every tic, " \
         "and all #{rows.length} field(s) after the first tic and after the last; #{scratch} scratch " \
         "scalar(s) are left out of both, as the generated layout leaves them out"
    puts "native-scenario-diff: an ARRAY-ONLY DIVERGENCE -- a buffer cell that differs in a tic whose " \
         "scalars all agree, and that no later tic reads into a scalar -- is located by the full " \
         "comparisons alone, so at the end of the run and not at the tic that caused it"
    silent.empty? or puts "native-scenario-diff: #{silent.length} scalar(s) no original holds, " \
                          "compared in no tic: #{silent.join(', ')}"
  end

  # One full comparison: every row of the layout, both sides in the same bytes.
  taken = []
  full = lambda do |t|
    s0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    res = R.snapshot(layout: rows, origins: ORIGINS, objects: ref)
    bad = res.unreachable + res.errors
    bad.each { |b| puts "  the reference cannot speak for #{b}" }
    want = res.bytes.dup
    rows.each do |row|
      next unless res.added.include?(row["field"])
      cells =
        case row["field"]
        # NO FRAME IS DRAWN in this lane, so the frame counter stands where the
        # session opened it, and the command is the one the last tic was given.
        when "core_frame" then [0]
        when "core_command" then t.negative? ? [0] * 5 : [*CMDS[t], 0]
        else
          puts "  #{row['field']} has no original and no value here"
          bad << row["field"]
          next
        end
      want[row["offset"], row["bytes"]] = cells.pack(R::PACK.fetch(row["element"]) + "*")
    end
    got = route.snapshot(rows)
    differ = rows.filter_map do |row|
      a = got.byteslice(row["offset"], row["bytes"])
      b = want.byteslice(row["offset"], row["bytes"])
      next if a == b
      pk = R::PACK.fetch(row["element"]) + "*"
      av = a.unpack(pk)
      bv = b.unpack(pk)
      k = (0...row["count"]).find { |i| av[i] != bv[i] }
      "#{row['field']}[#{k}]: compiled #{av[k]}, original #{bv[k]} " \
        "(#{(0...row['count']).count { |i| av[i] != bv[i] }} cell(s) of #{row['count']})"
    end
    taken << t
    printf("native-scenario-diff: full state %s: %d field(s), %d differ (%.1f s)\n",
           t.negative? ? "at session open" : "after tic #{t}", rows.length, differ.length,
           Process.clock_gettime(Process::CLOCK_MONOTONIC) - s0)
    differ.first(8).each { |d| puts "  #{d}" }
    differ.length + bad.length
  end

  # --- the tics -------------------------------------------------------------
  bad_tics = 0
  stopped = nil
  ran = 0
  # AT SESSION OPEN: the state the two sides start from, which for a scenario
  # is the one its setup wrote. Taken only when it is asked for -- for a
  # scenario whose first tic stops, it is the only full state there is.
  bad_tics += full.(-1) if full_after.include?(-1)
  NTICS.times do |t|
    if PLANT && Integer(PLANT[4], 10) == t
      route.write(PLANT[1], Integer(PLANT[3], 10), PLANT[2] ? Integer(PLANT[2], 10) : 0)
      warn "native-scenario-diff: planted #{PLANT[1]}#{PLANT[2] ? "[#{PLANT[2]}]" : ''} = #{PLANT[3]} before tic #{t}"
    end
    answered = nil
    refusal = nil
    begin
      answered = route.step(CMDS[t], t == 2 ? 320 : 0)
    rescue Doom::Core::SessionError => e
      # Full's pre-step condition, or a status the adapter answered: either
      # ends the route, and nothing is read back after it.
      refusal = "#{e.class.name.split('::').last}: #{e.message}"
    end
    rnd.tic = t
    320.times { rnd.m_random } if t == 2
    begin
      game.g_ticker(*CMDS[t])
    rescue Doom::LevelError => e
      stopped = t
      if SC[:stops] && refusal
        puts "tic #{t}: both stopped -- the original raised #{e.message.inspect}, " \
             "the compiled side refused with #{refusal}"
      else
        puts "tic #{t}: the original raised #{e.message.inspect} and the compiled side " \
             "#{refusal ? "refused with #{refusal}, which this scenario does not declare" : 'did not stop'}"
        bad_tics += 1
      end
      break
    end
    st_randomnumber = rnd.m_random
    m = game.player_mo
    atk = game.pl_attacker
    kind = atk.negative? ? Doom::StatusBar::ATTACKER_NONE :
           (atk == m ? Doom::StatusBar::ATTACKER_SELF : Doom::StatusBar::ATTACKER_OTHER)
    bga = atk >= 0 ? game.point_to_angle2(game.mobj_x[m], game.mobj_y[m], game.mobj_x[atk], game.mobj_y[atk]) : 0
    statusbar.ticker(st_randomnumber, game.pl_health, game.pl_weaponowned, game.pl_cards,
                     game.pl_damagecount, game.pl_bonuscount, game.pl_attackdown,
                     game.pl_powers[0], kind, bga, game.mobj_angle[m])
    hud.ticker(game.take_message)
    if refusal
      # The original ran the tic and the compiled side did not: the two states
      # have parted, and a route that refused is not read back from.
      puts "tic #{t}: the compiled side refused with #{refusal}, and the original ran the tic"
      bad_tics += 1
      stopped = t
      break
    end
    ran = t + 1
    lines = []
    lines << "the entry answered gametic #{answered.inspect}, the original is at #{game.gametic}" if answered != game.gametic
    scalars.each do |f|
      state, v = R.field_value(ref, ORIGINS[f])
      if state != :ok
        skipped[f] += 1
        next
      end
      got = route.read(f)
      want = v == true ? 1 : (v == false ? 0 : v)
      lines << "#{f}: compiled #{got.inspect}, original #{want.inspect}" unless got == want
    end
    unless lines.empty?
      bad_tics += 1
      puts "tic #{t}: #{lines.length} disagreement(s)"
      lines.first(8).each { |l| puts "  #{l}" }
    end
    bad_tics += full.(t) if full_after.include?(t)
  end
  t3 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  # A refused route holds poisoned participants; its ids are released all the
  # same, and only a live route is asked to account for them.
  refused = route.failed? ? 0 : route.close
  session.close
  unless skipped.empty?
    # A NON-SCRATCH SCALAR THE REFERENCE COULD NOT READ IN SOME TIC. Not a
    # disagreement, and not nothing either: those tics did not compare it.
    whole = skipped.select { |_, c| c == ran }.keys
    puts "native-scenario-diff: #{skipped.length} scalar(s) the reference could not read in some tic, " \
         "uncompared there: #{skipped.sort_by { |k, v| [-v, k] }.map { |k, v| "#{k} x#{v}" }.join(' ')}" \
         "#{whole.empty? ? '' : "; of these #{whole.length} were compared in no tic of this scenario"}"
  end
  printf("native-scenario-diff: %s %d tic(s) ran, %d disagreement(s); prepare %.1f s, bind %.1f s, " \
         "run %.1f s; %d release(s) refused\n", NAME, ran, bad_tics, t1 - t0, t2 - t1, t3 - t2, refused)
  [bad_tics + refused, stopped, ran, taken]
end

# --- the run, and a second one for a scenario that stops -------------------------
bad, stopped, ran, taken = play(work: File.join(WORK, "first"), full_after: [0, NTICS - 1], announce: true)
if stopped && ran.positive? && !taken.include?(ran - 1)
  # The stop ended the first run before its last full comparison. The same
  # scenario again, with that comparison after the last tic that completed --
  # and it must stop in the same tic as before.
  puts "native-scenario-diff: #{NAME} stopped in tic #{stopped}; the full state after tic #{ran - 1} is " \
       "taken in a second run, which must stop in the same tic"
  bad2, stopped2, ran2, taken2 = play(work: File.join(WORK, "second"), full_after: [ran - 1], announce: false)
  bad += bad2
  unless stopped2 == stopped && ran2 == ran
    puts "native-scenario-diff: the second run stopped in tic #{stopped2.inspect} after #{ran2} tic(s), " \
         "and the first in tic #{stopped.inspect} after #{ran} tic(s)"
    bad += 1
  end
  taken += taken2
elsif stopped && ran.zero?
  # NOTHING COMPLETED: the only state the two sides ever shared is the one they
  # started from, so that is what the second run compares -- the scenario's
  # setup, prepared into the session and read back out of the registry.
  puts "native-scenario-diff: #{NAME} stopped in its first tic; no tic completed, so the full state " \
       "compared is the one at session open, in a second run that must stop in the same tic"
  bad2, stopped2, ran2, taken2 = play(work: File.join(WORK, "second"), full_after: [-1], announce: false)
  bad += bad2
  unless stopped2 == stopped && ran2.zero?
    puts "native-scenario-diff: the second run stopped in tic #{stopped2.inspect} after #{ran2} tic(s), " \
         "and the first in tic #{stopped.inspect} after #{ran} tic(s)"
    bad += 1
  end
  taken += taken2
end
where = taken.sort.map { |t| t.negative? ? "session open" : "tic #{t}" }
puts "native-scenario-diff: #{NAME}: #{ran} tic(s) compared, #{bad} disagreement(s); " \
     "full state at #{where.empty? ? 'no point of the run' : where.join(', ')}"
exit(bad.zero? ? 0 : 1)
