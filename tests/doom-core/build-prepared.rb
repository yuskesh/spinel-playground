# frozen_string_literal: true
#
# tests/doom-core/build-prepared.rb — the prepared side, produced by FULL.
#
#   ruby tests/doom-core/build-prepared.rb LAYOUT ACQUIRED SCHEMA OUT_LAYOUT OUT_BIN [WAD [MAP EPISODE]]
#
# With a WAD, Full also builds the objects it makes BEFORE any game exists --
# the wad itself and the texture set -- and produces the fields that come from
# those. Without one it produces only what the packed tables give.
#
# `tests/doom-core/build-session.rb` fills the prepared fields by slicing them
# out of the reference snapshot, so comparing its output against that snapshot
# evidences TRANSPORT and nothing else -- the same bytes on both sides.
#
# This produces them the other way: `Doom::Core::Resources.prepared` builds
# each field from the WAD and the configuration -- including, now, by
# constructing the level, the game and the renderer in the order their own
# signatures require -- rather than by slicing them out of the answer.
# so the two sides of the comparison have different origins.
#
# THIS IS A PRODUCER COMPARISON, NOT THE WHOLE OF PLAN 310-313. These bytes go
# straight to the comparator; they do not pass through `Session.open` and the
# session's own snapshot, and the session lane beside it is still fed from
# `ref.bin`. What it shows is that Full's producers and the original agree for
# the fields it covers. Connecting these bytes to a real session is the step
# after.
#
# It covers the fields Full can produce today, and writes a LAYOUT naming
# exactly those, so the comparison is over a set the file itself declares
# rather than over whatever happened to be producible.
ROOT = File.expand_path("../..", __dir__)
require_relative File.join(ROOT, "examples/doom/core/full/resources")

PROG = File.basename(__FILE__)
unless [5, 6, 8, 11].include?(ARGV.length)
  abort("usage: #{PROG} LAYOUT ACQUIRED SCHEMA OUT_LAYOUT OUT_BIN " \
        "[WAD [MAP EPISODE [SKILL SETBLOCKS RESSCALE]]]")
end
layout_path, acquired, schema, out_layout, out_bin, wad_path, map_name, episode,
  skill, setblocks, resscale = ARGV
skill ||= "2"
setblocks ||= "10"
resscale ||= "1"

# THE OBJECTS FULL BUILDS BEFORE ANY GAME. `Doom::Wad` and `Doom::Textures`
# are made from the IWAD and the configuration alone. With a MAP they are
# joined by the level, the game, the sprites and the renderer; all of it is
# Full's own preparation, which is what keeps this side of the comparison from
# being the reference's side.
objects = {}
if wad_path
  require_relative File.join(ROOT, "examples/doom/lib/doom/wad")
  require_relative File.join(ROOT, "examples/doom/lib/doom/texnames")
  require_relative File.join(ROOT, "examples/doom/lib/doom/texture")
  wad = Doom::Wad.new(wad_path)
  objects["Doom::Wad"] = wad
  tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
  # AND FULL PRECACHES. `Textures.new` allocates the texture atlas as 1379328
  # zero bytes; `precache_all` composes it, and `Renderer.new` calls it at
  # render.rb:210 before any tick runs. Measured: 0 non-zero bytes after
  # construction, 1331228 after precaching, and the original's first byte is
  # 99, which is what the precached atlas holds.
  #
  # This is Full's own preparation of a resource, not a step of the game, so
  # doing it here keeps the field's value the one it has before the first tick
  # -- the same distinction that makes `th_alloc` 97 rather than the 1 its
  # constructor writes.
  tx.precache_all
  objects["Doom::Textures"] = tx

  # THE LEVEL NEEDS ONLY THE WAD. `Level.new(wad, mapname, episode)` loads the
  # map -- vertexes, sectors, sidedefs, linedefs, subsectors, nodes -- in
  # `P_SetupLevel`'s order, and `level.rb` does not mention `Game` at all.
  #
  # I had assumed the 55 Level fields needed a constructed game and said so;
  # they do not. Loading the map IS Full preparing a resource, the same as
  # reading the WAD and precaching the atlas, so it belongs on this side.
  #
  # The map and the episode are CONFIGURATION: a different map is a different
  # prepared state.
  if map_name && episode
    require_relative File.join(ROOT, "examples/doom/lib/doom/level")
    lv = Doom::Level.new(wad, map_name, Integer(episode, 10))
    objects["Doom::Level"] = lv

    # AND THE REST OF THE CONSTRUCTION ORDER, read rather than assumed.
    # `Game#initialize(wad, level, skill, rnd, textures)` needs nothing Full
    # does not already have. `Renderer#initialize(level, wad, colormap,
    # textures, sprites, things, setblocks, trace, resscale)` needs the game
    # as `things`, so the order is wad -> textures -> level -> random -> game
    # -> sprites -> renderer, with no circularity.
    #
    # THESE ARE THE SCHEMA ROUTE, NOT A SECOND MEASUREMENT, and the two are
    # counted apart. A packed table is a second read of one constant. A field
    # read off a constructed `Game` is read from the object the reference also
    # reads, so what the comparison exercises is the layout, the offsets, the
    # lengths and the binding of a prepared name to one field.
    #
    # WHAT IS AN ARGUMENT AND WHAT IS NOT, precisely -- an earlier version of
    # this comment, and of what I reported, said all of these are "arguments
    # rather than defaults" and that the trace flag is one of them. Neither is
    # true of the code:
    #
    #   MAP, EPISODE    required together to build a level at all
    #   SKILL           optional, DEFAULTS to 2
    #   SETBLOCKS       optional, DEFAULTS to 10
    #   RESSCALE        optional, DEFAULTS to 1
    #   trace           NOT an argument: fixed false here
    #
    # A different skill is a different prepared state, so the defaults are a
    # convenience and not a claim. THE CONFIGURATION THIS IS TESTED AT is
    # E1M1, episode 1, skill 2, setblocks 10, resscale 1, trace false, which
    # is what `build-reference.rb` builds. No other configuration has been
    # compared, and nothing here says one would agree.
    %w[random info sprites game render statusbar hud jobs executor].each do |f|
      require_relative File.join(ROOT, "examples/doom/lib/doom/#{f}")
    end
    rnd = Doom::Random.new
    rnd.clear
    objects["Doom::Random"] = rnd
    game = Doom::Game.new(wad, lv, Integer(skill, 10), rnd, tx)
    objects["Doom::Game"] = game
    sprites = Doom::Sprites.new(wad, Doom::Info.sprnames)
    objects["Doom::Sprites"] = sprites
    colormap = wad.bytes_by_name("COLORMAP")
    renderer = Doom::Renderer.new(lv, wad, colormap, tx, sprites, game,
                                  Integer(setblocks, 10), false, Integer(resscale, 10))
    objects["Doom::Renderer"] = renderer

    # AND THE OBJECTS AROUND THE GAME, in the order `build-reference.rb`
    # builds them. Two things here are INITIALISATION rather than
    # construction, and leaving either out would repeat the atlas mistake:
    #
    #   * `StatusBar#start(pl_weaponowned)` runs after `StatusBar.new`, before
    #     any tick. Constructing without it gives a status bar that has not
    #     been started.
    #   * the key script is a FILE the session is driven by; its contents are
    #     configuration, like the map.
    #
    # FIXED, NOT ARGUMENTS: the script is one line, `0 10 forward`, and the
    # demo writer is `DemoWriter.new(2, 1, 1, 40_000)` -- the same values the
    # reference uses. They are part of the one tested configuration and are
    # not exposed here; nothing says another would agree.
    %w[input record].each do |f|
      require_relative File.join(ROOT, "examples/doom/lib/doom/#{f}")
    end
    statusbar = Doom::StatusBar.new(wad)
    statusbar.start(game.pl_weaponowned)
    objects["Doom::StatusBar"] = statusbar
    objects["Doom::Hud"] = Doom::Hud.new(wad, renderer.screenwidth, renderer.screenheight, 1)
    require "tmpdir"
    script_path = File.join(Dir.mktmpdir("prep-script"), "s.txt")
    File.write(script_path, "0 10 forward\n")
    objects["Doom::KeyScript"] = Doom::KeyScript.new(script_path)
    objects["Doom::KeyState"] = Doom::KeyState.new
    objects["Doom::TiccmdBuilder"] = Doom::TiccmdBuilder.new
    objects["Doom::DemoWriter"] = Doom::DemoWriter.new(2, 1, 1, 40_000)
    # THE RENDERER'S OWN, READ, NOT BUILT. The program has no other Jobs and
    # JobExecutor than `Renderer#initialize`'s (render.rb:465-466), sized by the
    # VIEW. This file used to construct a pair of its own sized by the screen,
    # and so did build-reference.rb: both sides of the comparison read the
    # same object the program does not have, and agreed. Reference.check_graph
    # below refuses that.
    objects["Doom::Jobs"] = renderer.instance_variable_get(:@jobs)
    objects["Doom::JobExecutor"] = renderer.instance_variable_get(:@exec)
  end
end
require_relative File.join(ROOT, "examples/doom/core/full/reference")
Doom::Core::Reference.check_graph(objects)

made, unsupported, by_kind = Doom::Core::Resources.prepared(acquired: acquired, schema: schema,
                                                            objects: objects)
made.empty? and abort("#{PROG}: produced nothing; the comparison would be empty")

# The canonical layout, restricted to what was produced and RE-OFFSET from
# zero, so the projection of the reference can be taken with the same file.
rows = []
File.foreach(layout_path) do |ln|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  next unless made.key?(f[0])
  rows << f
end
missing = made.keys - rows.map(&:first)
missing.empty? or
  abort("#{PROG}: produced #{missing.length} field(s) the layout does not describe: " +
        missing.first(3).join(", "))

# EVERYTHING IS CHECKED BEFORE ANYTHING IS WRITTEN.
#
# This opened the layout for writing and validated each field's length inside
# that loop, so a refusal left the layout TRUNCATED to the rows it had reached
# -- 112 bytes of partial layout -- beside a binary and an unsupported list
# still holding the previous run's bytes. The diagnostic was right and the
# directory was wrong, and the check beside it only looked at the binary,
# which that run had never created.
#
# So the three outputs are built in memory, every length is verified, and only
# then is anything opened. A refusal here leaves all three exactly as they
# were, and creates none of them where there were none. This is about
# VALIDATION FAILURE; it promises nothing about a disk error part way through
# the writes below.
offset = 0
bytes = +"".b
layout = +"# Generated by #{PROG} -- the prepared fields Full produces itself.\n"
layout << "#field\telement\tcount\tbytes\toffset\n"
rows.each do |f|
  name, element, count, want, = f
  got = made[name]
  # A FIELD THAT DOES NOT COME OUT THE DECLARED LENGTH IS REFUSED, not
  # padded: a length fixed here would make the comparison agree about a
  # field neither side holds.
  got.bytesize == Integer(want, 10) or
    abort("#{PROG}: #{name}: Full produced #{got.bytesize} byte(s) and the " \
          "layout declares #{want}")
  layout << [name, element, count, want, offset].join("\t") << "\n"
  bytes << got
  offset += got.bytesize
end
layout << "#total\t-\t-\t#{offset}\t-\n"

unsupported_text = +"# Generated by #{PROG} -- prepared fields Full cannot produce yet.\n"
unsupported_text << %w[field origin reason].join("\t") << "\n"
unsupported.sort.each { |r| unsupported_text << r.join("\t") << "\n" }

File.write(out_layout, layout)
File.binwrite(out_bin, bytes)
File.write("#{out_layout}.unsupported", unsupported_text)

warn("#{PROG}: #{rows.length} field(s), #{offset} byte(s) produced by Full")
# THE TWO KINDS ARE NOT THE SAME EVIDENCE, so they are counted apart -- BY
# WHAT PRODUCED THEM, not by whether a table names them.
#
# A module function on a packed constant (`Doom::Info.mobj_damage`) is a
# second path to the same bytes, though not a derivation of the constant
# itself: both sides read the same literal.
#
# A field read off an object Full constructs is the path the reference takes
# too, so comparing it exercises the schema and session route -- layout,
# offsets, lengths, the binding of a prepared name to one field -- and not the
# value.
warn("#{PROG}: #{by_kind['table'].length} from a packed table (a second read of one constant), " \
     "#{by_kind['object'].length} read off an object Full constructs (the schema route)")
File.write("#{out_layout}.kinds",
           "# Generated by #{PROG} -- which producer kind each field came from.\n" +
           "kind\tfield\n" +
           by_kind["table"].sort.map { |n| "table\t#{n}\n" }.join +
           by_kind["object"].sort.map { |n| "object\t#{n}\n" }.join)
# EVERY PREPARED FIELD IS IN EXACTLY ONE OF THE TWO HALVES, and the file says
# which by name. A count by reason cannot be compared with the prepared set,
# so a field that fell out of both would not have shown up; this is checkable
# against examples/doom/core/prepared.tsv and the suite checks it.
warn("#{PROG}: #{unsupported.length} field(s) Full cannot produce yet, named in " \
     "#{File.basename(out_layout)}.unsupported")
