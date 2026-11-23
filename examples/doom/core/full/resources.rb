# frozen_string_literal: true
#
# examples/doom/core/full/resources.rb — decision 0008 task 5's preparation.
#
# What Full does BEFORE a session is live: read the WAD and the configuration,
# measure everything the schema's counts name, and produce the prepared bytes.
#
#   cat = Doom::Core::Resources.catalog(wad: wad, map: "E1M1", width: 320, height: 200)
#
# THE CATALOG IS A MEASUREMENT, NOT A TABLE. Every count here is read off the
# loaded map or computed the way the renderer computes it, so a different map
# or resolution gives a different catalog and nothing in the schema has to
# change. That is the point of 0008's `level:`, `screen:`, `limit:` and
# `table:` grammar: a count is NAMED in the schema and MEASURED here.
#
# Nothing in this file is a build dependency of anything: it reads an IWAD the
# caller supplies and the IWAD is not in this repository.

require_relative "../../lib/doom/wad"
require_relative "../../lib/doom/level"
require_relative "../../lib/doom/texnames"
require_relative "../../lib/doom/texture"
require_relative "../../lib/doom/sprites"
require_relative "../../lib/doom/info"
require_relative "../../lib/doom/hud"
require_relative "../../lib/doom/tables"
require_relative "../../lib/doom/specials"
require_relative "../../lib/doom/demo"
require_relative "../../lib/doom/input"

module Doom
  module Core
    module Resources
      class PreparationError < StandardError; end

      # The limits the source declares. Named here so the catalog says where
      # each number came from; they are not re-derived from the source text.
      LIMITS = {
        "maxmobjs" => 4096,      # game.rb MAXMOBJS
        "maxthinkers" => 4096,   # game.rb MAXTHINKERS
        "demotics" => 40_000,    # bin/doom.rb's recording default
        "jobsched" => 12_288,    # jobs.rb CAP_SCHED
        "jobwallfields" => 4096 * 7,    # CAP_WALL * WC_NF
        "jobspanfields" => 3072 * 7,    # CAP_SPAN * SP_NF
        "jobmaskedfields" => 8192 * 9,  # CAP_MASKED * MC_NF
        "jobzonecells" => 3072 * 128    # ZONE_SLOTS * ZONE_STRIDE
      }.freeze

      # Measured from the loaded map and the configuration. `width` and
      # `height` are the INTERNAL drawing resolution, which bin/doom.rb's
      # `-res` selects and which sizes every render buffer.
      # The largest byte length a buffer may have: the bound `state-schema.rb`
      # and `Session` already apply to a field's bytes.
      U64_MAX = 18_446_744_073_709_551_615
      NAME_WIDTH = 8

      # `table:lumpnamebytes`: eight name bytes per directory entry. Checked
      # BEFORE multiplying. Ruby integers do not overflow, so a check written
      # after the product -- `(n * 8) / 8 == n` -- holds for every n and checks
      # nothing; the bound has to be stated on the count.
      def self.lump_name_bytes(count)
        count.is_a?(Integer) && count >= 0 or
          raise PreparationError, "a lump count must be a non-negative Integer, not #{count.inspect}"
        count <= U64_MAX / NAME_WIDTH or
          raise PreparationError, "#{count} lumps need #{NAME_WIDTH} * #{count} name bytes, " \
                                  "more than #{U64_MAX}; the most is #{U64_MAX / NAME_WIDTH}"
        count * NAME_WIDTH
      end

      I64_RANGE = (-9_223_372_036_854_775_808..9_223_372_036_854_775_807).freeze

      # THE SHARED SCALAR BUFFER, assembled once. `slots` is the generator's
      # `slots.tsv`: each scalar's index in `core_state` and its initial, a fill
      # or `prepared:NAME`. `prepared` maps a prepared name to the bytes Full
      # has for it. The result is `count` little-endian i64s in index order,
      # for the session to receive as `prepared:core_state`.
      #
      # Everything is checked before a byte is packed: the table itself (by
      # Session.read_slots), that it lists exactly `count` slots, each fill in
      # i64, each prepared scalar present, exactly eight bytes and named by one
      # slot only. Nothing is defaulted: a slot with no value is an error, not a
      # zero.
      def self.core_state(slots:, count:, prepared:)
        require_relative "session"
        rows = Doom::Core::Session.read_slots(slots)
        count.is_a?(Integer) && count >= 0 or
          raise PreparationError, "core_state count must be a non-negative Integer, not #{count.inspect}"
        rows.length == count or
          raise PreparationError, "core_state holds #{count} and #{slots} lists #{rows.length} slot(s)"
        claimed = {}
        values = Array.new(count)
        rows.each do |field, r|
          init = r["initial"]
          values[r["index"]] =
            if init.start_with?("prepared:")
              name = init.delete_prefix("prepared:")
              claimed.key?(name) and
                raise PreparationError, "prepared:#{name} is claimed by #{claimed[name]} and #{field}"
              claimed[name] = field
              data = prepared[name] or
                raise PreparationError, "#{field} (slot #{r['index']}) wants prepared:#{name}, which Full did not prepare"
              data.is_a?(String) && data.bytesize == 8 or
                raise PreparationError, "#{field} (slot #{r['index']}): prepared:#{name} is " \
                                        "#{data.respond_to?(:bytesize) ? data.bytesize : data.class} " \
                                        "byte(s), and a scalar slot is 8"
              data.b.unpack1("q<")
            else
              v = Integer(init, 10)
              I64_RANGE.cover?(v) or
                raise PreparationError, "#{field} (slot #{r['index']}): #{v} is outside i64"
              v
            end
        end
        values.pack("q<*")
      end

      # Reading a length off an object that has no accessor for it. Named so
      # the places that do it are visible rather than scattered as
      # `instance_variable_get` calls: these are fields the game grows and does
      # not publish, and the alternative is to guess their lengths.
      def self.ivar_length(obj, name)
        v = obj.instance_variable_get(name)
        v.respond_to?(:length) or
          raise PreparationError, "#{obj.class}#{name} is #{v.class}, which has no length"
        v.length
      end

      # The screen size the catalog is measured at leaves the view to this.
      # Below 11, render.rb:228 applies; at 11 the view is the whole screen.
      SETBLOCKS = 10
      KNOT_FRAME_CELLS = 21
      KNOT_FRAMES_DEBT = 256

      def self.catalog(wad:, map:, width:, height:, script: nil)
        (width % 320).zero? && width / 320 >= 1 && width / 320 <= 8 or
          raise PreparationError, "width #{width} must be 320*s with s in 1..8"
        height == 200 * (width / 320) or
          raise PreparationError, "#{width}x#{height} is not 8:5; DOOM's aspect wants " \
                                  "#{width}x#{200 * (width / 320)}"
        episode = map =~ /\AE(\d)M\d\z/ ? Integer($1, 10) : 1
        lv = Doom::Level.new(wad, map, episode)
        texnames = Doom::TextureNames.new(wad)
        tx = Doom::Textures.new(wad, texnames)
        sp = Doom::Sprites.new(wad, Doom::Info.sprnames)

        plw = width + 2
        out = {}
        # The level, read off the loaded map.
        out["numsectors"] = lv.num_sectors
        out["numlines"] = lv.num_lines
        out["numsides"] = lv.num_sides
        out["numsegs"] = lv.num_segs
        out["numsubsectors"] = lv.num_subsectors
        out["numnodes"] = lv.num_nodes
        out["numvertexes"] = lv.num_vertexes
        out["blockmapcells"] = lv.bmapwidth * lv.bmapheight
        out["sectorboxes"] = lv.num_sectors * 4
        out["nodeboxes"] = lv.num_nodes * 8
        # The screen, computed the way the renderer computes it.
        out["screenwidth"] = width
        out["screenheight"] = height
        out["screenpixels"] = width * height
        out["screenwidthplus1"] = width + 1
        out["openings"] = width * 64
        out["visplanecells"] = 128 * plw
        out["jobwallcells"] = width * 64
        out["jobmaskedcells"] = width * 256
        # THE VIEW, NOT THE SCREEN. The program's Jobs is the renderer's own,
        # `Jobs.new(@sw, @viewheight)` (render.rb:465), and the view is
        # `((setblocks * 168 / 10) & ~7) * s` rows (render.rb:228) at the
        # setblocks every lane runs, SETBLOCKS. These counts were the screen's,
        # which is a Jobs the program does not have.
        view = ((SETBLOCKS * 168 / 10) & ~7) * (width / 320)
        out["viewheight"] = view
        out["viewpixels"] = width * view
        out["jobspancells"] = view * 256
        out["statusbarbytes"] = 320 * 32
        # THE ENTRIES' OWN STORAGE (tools/doom/core-added.tsv), from the counts
        # above: the sight and BSP work stacks are three cells per node frame,
        # the sound stack six per sector frame, and the status bar's shadow is a
        # 320x200 surface only when the screen is scaled.
        out["sightcells"] = 3 * (lv.num_nodes + 1)
        out["bspcells"] = 3 * (lv.num_nodes + 2)
        out["soundcells"] = 6 * (lv.num_sectors + 1)
        out["sbshadowpixels"] = width == 320 ? 1 : 320 * 200
        # THE KNOT STACK IS A DEBT, NOT A MEASUREMENT: 256 frames of the knot's
        # 21 cells (KN_FRAME in examples/doom/core/src/stepknot.rb), which the
        # step harness chose and nothing derived. 0008 requires a bound derived
        # from the visited/state rules; until it exists this is a declared
        # limit, stated here as one.
        out["knotcells"] = KNOT_FRAME_CELLS * KNOT_FRAMES_DEBT
        # The prepared tables.
        out["textures"] = tx.numtextures
        out["flats"] = tx.numflats
        out["sprites"] = sp.numsprites
        out["spritelumps"] = sp.numspritelumps
        out["lumps"] = wad.lumps.length
        # Eight bytes of NAME per directory entry, resolved from the real count
        # rather than written inline in the schema.
        out["lumpnamebytes"] = lump_name_bytes(out["lumps"])
        # THE TABLES FULL HANDS OVER WHOLE, measured from the objects that hold
        # them. These are the counts of fields the game ACQUIRES rather than
        # allocates -- `@finesine = Tables.finesine`, `@info_damage =
        # Info.mobj_damage`, `@collump` grown one push at a time while the
        # texture set is read -- and until they were measured here the schema
        # declared every one of them a single element long.
        #
        # Two different things are being measured, and the difference is what
        # decides whether a number belongs to THIS configuration:
        #
        #   * the trig and info tables are packed binary constants in the
        #     source. Their lengths do not change with the map or the
        #     resolution. They are measured rather than written down so that
        #     editing a table cannot leave the schema behind.
        #   * everything else is a property of THIS WAD and THIS MAP. `lumps`
        #     is 1264 for one IWAD and something else for another; `texcolumns`
        #     is the column count of this texture set. Writing today's numbers
        #     into the schema as fixed counts is exactly what this catalog
        #     exists to prevent.
        # SIX NAMES THAT WERE IN THE CATALOG AND NOT IN THIS MEASUREMENT.
        # `catalog.tsv` is checked by state.sh against what this method
        # returns, and that check only ever asked whether every MEASURED name
        # agrees -- never whether the committed file holds a name nobody
        # measures. Six did, and three of them disagreed with the objects:
        # `blockmapwords` said 5322 against 3461, `sectorlinetotal` said 1710
        # against 642, `switchnames` said 40 against 38. Those three are three
        # of the shape refusals the reference lane has been reporting, and they
        # were not mis-mapped rows at all -- they were hand-written numbers
        # that nothing compared with the game.
        out["blockmapwords"] = ivar_length(lv, :@blockmap)
        out["sectorlinetotal"] = ivar_length(lv, :@sector_lines)
        out["flatatlas"] = tx.flat_atlas.bytesize
        out["pnames"] = tx.numpatches
        out["switchnames"] = Doom::Specials::SWITCH_NAMES.length
        # The recording buffer, which DemoWriter computes from the tic limit.
        out["demobytes"] = Doom::Demo::HEADER + LIMITS["demotics"] * 4 + 1
        out["finesine"] = Doom::Tables.finesine.length
        out["finetangent"] = Doom::Tables.finetangent.length
        out["tantoangle"] = Doom::Tables.tantoangle.length
        out["mobjinfo"] = Doom::Info.mobj_damage.length
        out["states"] = Doom::Info.state_tics.length
        out["weaponinfo"] = Doom::Info.weapon_ammo.length
        # `sprnames` is stored as bytes, not as entries: the schema types it
        # `u8` and the encoder joins the names, so its count is the byte length
        # and not the 138 names.
        out["sprnamebytes"] = Doom::Info.sprnames.join.bytesize
        # BYTES, not entries. `Hud@texts` is typed `u8` and the encoder joins
        # the strings, exactly as `sprnames` does; counting the 41 messages
        # declared a 1046-byte field 41 bytes long.
        out["hudmessages"] = Doom::Hud::MESSAGES.join.bytesize
        # The whole-WAD and whole-table buffers several fields are handed.
        out["waddata"] = wad.data.bytesize
        out["texatlas"] = tx.tex_atlas.bytesize
        out["colormap"] = wad.bytes_by_name("COLORMAP").bytesize
        # Grown by appending while the WAD is read. `@lump` and `@flip` are one
        # per sprite frame; `@rotate` is one per frame ENTRY and is a different
        # number, which a single "sprites" count would have quietly merged.
        out["spriteframes"] = ivar_length(sp, :@lump)
        out["spriterotations"] = ivar_length(sp, :@rotate)
        out["texcolumns"] = ivar_length(tx, :@collump)
        out["animations"] = ivar_length(tx, :@anim_basepic)
        LIMITS.each { |k, v| out[k] = v }
        # The level's own grown list: the lines with special 48, which
        # `Specials#spawn_specials` collects as it walks the level. Computed
        # here the way the screen products above are computed -- the catalog
        # works out what the game works out -- and a drift between the two
        # does not hide, because a schema count that disagrees with what the
        # reference actually holds is refused as a shape error rather than
        # reshaped.
        out["linespecials"] = (0...lv.num_lines).count { |i| lv.line_special[i] == 48 }
        # The REJECT lump, one bit per sector pair, which the map carries and
        # nothing allocates -- so it had the invented `fixed:1` while holding
        # 904 bytes for E1M1. A different map is a different size.
        out["rejectbytes"] = lv.instance_variable_get(:@reject).bytesize
        # The key script is a configuration input like the map and the
        # resolution, so its counts are measured only when one is supplied.
        # Omitted rather than defaulted: a catalog that invents a script length
        # would be describing a session nobody asked for.
        if script
          ks = Doom::KeyScript.new(script)
          out["scriptlines"] = ivar_length(ks, :@from)
        end
        out
      end

      # --- the prepared BYTES, and not only their lengths ---------------------
      #
      # `catalog` above says how long each prepared field is. This produces
      # what is IN one, for the fields Full can produce without constructing a
      # game: the packed tables in `Doom::Info` and `Doom::Tables`. That
      # independence is the point -- `tests/doom-core/build-reference.rb`
      # builds a real `Doom::Game` and reads its ivars, so a prepared side
      # that also read that game would be comparing one path with itself, and
      # 0008-doom-core-migration-plan.md:310-313 asks for the old Full setup
      # and the new prepared state built from the same WAD and configuration.
      #
      # WHICH PRODUCER EACH FIELD HAS IS NOT WRITTEN TWICE. It is the `origin`
      # column of tools/doom/core-acquired.tsv, already reviewed there, and
      # this reads it rather than keeping a second list that could disagree
      # with the first. Three producer forms are dispatched -- a module function
      # on a packed table, an instance method on one of the objects Full builds
      # before any game exists, and an ivar on one of those objects -- and an
      # origin in any other form is a field this cannot produce yet, reported
      # by name rather than guessed at. (This said "only Info and Tables",
      # which was true when it was written and stopped being true when the
      # dispatch widened.)
      # A producer is either a MODULE FUNCTION on a packed table, or an
      # INSTANCE METHOD on one of the objects Full builds from the WAD before
      # any game exists. The `origin` column spells which:
      #
      #   Doom::Info.mobj_damage              module function
      #   Doom::Wad#data                      instance method on the wad
      #   Doom::Textures#tex_atlas            instance method on the textures
      #   Doom::Wad#bytes_by_name:COLORMAP    instance method with one argument
      #
      # THE LAST FORM REPLACED PROSE. That row said "COLORMAP lump", which
      # tells a reader what it is and tells this nothing, so the field could
      # not be produced and was counted as unsupported for a reason that was
      # really "nobody wrote down the call".
      MODULE_PRODUCERS = { "Doom::Info" => Doom::Info, "Doom::Tables" => Doom::Tables }.freeze

      # element -> the pack directive for one canonical little-endian value.
      PACK = { "u8" => "C", "i8" => "c", "u16" => "S<", "i16" => "s<", "i32" => "l<", "u32" => "L<", "i64" => "q<" }.freeze

      # element -> the inclusive range a value must lie in to be that element.
      #
      # WRITTEN OUT HERE, NOT BORROWED FROM `Reference`. `pack` does not check
      # a range, it WRAPS: `[-1].pack("C")` is `ff` and 2**63 packed as `q<` is
      # `00 00 00 00 00 00 00 80`. An earlier version of this file said it used
      # "the same representation rules as the encoder" and then copied only the
      # TYPE mapping -- Integer, true, false -- without the range check, so a
      # value the encoder refuses was quietly turned into a different number.
      #
      # The reference is the other side of the comparison; if both sides shared
      # one domain table, a wrong bound in it would agree with itself. So the
      # bounds are stated here from the element widths, and the suite checks
      # the two sides decide the same way at every edge.
      # THE i32-bits FIELDS (examples/doom/core/widths-repr.tsv, decision 0022
      # section 2.4): an angle Full holds as a word 0..2**32-1 goes into its i32
      # cell as the signed pattern. Converted here, apart from Reference.
      I32_BITS = File.readlines(File.expand_path("../widths-repr.tsv", __dir__), chomp: true)
                     .reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.split("\t") }
                     .select { |row| row[1] == "i32-bits" }.map(&:first).freeze

      DOMAIN = {
        "u8"  => [0, (1 << 8) - 1],
        "i8"  => [-(1 << 7), (1 << 7) - 1],
        "u16" => [0, (1 << 16) - 1],
        "i16" => [-(1 << 15), (1 << 15) - 1],
        "i32" => [-(1 << 31), (1 << 31) - 1],
        "u32" => [0, (1 << 32) - 1],
        "i64" => [-(1 << 63), (1 << 63) - 1]
      }.freeze

      # `acquired` is tools/doom/core-acquired.tsv; `schema` is
      # examples/doom/core/state.tsv. Returns { field name => bytes } for what
      # it can produce, and the reasons for what it cannot.
      # `origin` -> [receiver, method, argument or nil], or nil when Full has no
      # way to call it here. Nothing is guessed: a form this does not know is
      # reported as unsupported with the origin as written.
      # THE `origin` COLUMN ANSWERS TWO QUESTIONS AND THIS WANTS ONE OF THEM.
      # For `Doom::Info.mobj_damage` the call gives the field's VALUE. For
      # `Doom::Textures#numtextures` it gives the field's LENGTH -- that row
      # explains where a count comes from, and `Textures@@tex_theight`'s bytes
      # are the ivar, not the count. Treating the second as a producer asked
      # `numtextures` for an array and got an Integer.
      #
      # So an ivar form is spelled out separately, `Doom::Textures @collump`,
      # which several rows already use, and an origin that yields something
      # other than bytes is reported as not a producer rather than raising.
      # AN ORIGIN THAT NEEDS A TRANSFORMATION SAYS SO, IN ADVANCE.
      #
      # `Game@@linespecials`'s data comes from `Doom::Level#line_special`, but
      # the field is not that array: `Specials#spawn_specials` walks it and
      # keeps the INDICES where the special is 48 (specials.rb:58-67). Reading
      # the accessor gives 475 entries where the field holds 8.
      #
      # An earlier version of this decided that from the LENGTH -- a producer
      # that disagreed with the declaration and was not the field's own ivar
      # became "provenance, not a producer". That rule hides defects: a
      # CORRECT producer disagrees too when the schema's count is wrong, which
      # is exactly how `textures_flatdata` and `level_reject` were found. A
      # comparison result cannot classify its own inputs.
      #
      # So the rule has two halves and neither is a measurement of the other:
      #
      #   * a transformation is DECLARED in core-acquired.tsv with
      #     `derived-from:`, from the construction code, and the field is
      #     reported unsupported for the missing transformation;
      #   * a DIRECT producer whose length disagrees with the layout is the
      #     named error `tests/doom-core/build-prepared.rb` raises, and stays
      #     one. That is what found `textures_flatdata` and `level_reject`.
      #
      # Nothing here compares a length to decide which half applies.
      DERIVED = "derived-from:"

      # ONE VALUE PER WAD DIRECTORY ENTRY, read off the wad Full already has.
      # `per-entry:Doom::Wad:pos` is `wad.lump(i).pos` for every i in
      # 0...wad.count. `per-entry:Doom::Wad:name:8` is each entry's NAME -- what
      # `Bytes.name8` read, which stops at the first NUL -- zero-padded to 8
      # bytes and joined in entry order. It is NOT the raw directory slot: a
      # slot `ab\0XyZ\0Q` stores `ab` and six zero bytes, because the bytes
      # after the NUL are not part of the name.
      # THE SOURCE ALIASES AS NUMBERS (docs/core/doom-source-alias.md). The
      # original renderer holds a REFERENCE to the buffer a column or span reads
      # -- `@dc_srcbuf`, `@ds_source` -- and the representation holds which
      # resource it is and a base into it. `source-select:dc:res` answers the
      # column's selector, `...:base` its base; `ds` the span's. Worked out from
      # the renderer's own objects by identity, and anything that is not one of
      # the declared resources is an error, not a default.
      SOURCE_SELECT = "source-select:"
      RES_NONE = -1
      RES_ATLAS = 0
      RES_WAD = 1
      RES_ZONE = 2
      RES_FLAT = 3
      SourceSelect = Struct.new(:renderer, :which, :part) do
        def value
          r = renderer
          # JOB MODE 1 ONLY AT SESSION OPEN. The conversion reads the direct
          # path's buffer references. Job mode 1 sets them on some paths and not
          # others (render.rb's masked zone window sets @dc_srcres and leaves
          # @dc_srcbuf), so after a frame they are not the selector the port
          # holds. Before any frame both are empty in either mode, and the
          # conversion is the same one; that is the only state it accepts here.
          unless r.job_mode.zero?
            r.job_mode == 1 or
              raise PreparationError, "source-select converts job modes 0 and 1; job mode is #{r.job_mode}"
            r.instance_variable_get(:@dc_srcbuf).empty? && r.instance_variable_get(:@ds_source).empty? or
              raise PreparationError, "source-select converts job mode 1 only before the first frame, " \
                                      "and this renderer has set a source"
          end
          tx = r.instance_variable_get(:@textures)
          sel, base =
            if which == "dc"
              buf = r.instance_variable_get(:@dc_srcbuf)
              ofs = r.instance_variable_get(:@dc_srcofs)
              if buf.bytesize.zero? then [RES_NONE, 0]
              elsif buf.equal?(r.instance_variable_get(:@wad_data)) then [RES_WAD, ofs]
              elsif buf.equal?(r.instance_variable_get(:@zonewin)) then [RES_ZONE, ofs]
              elsif (t = (0...tx.numtextures).find { |k| tx.texdata(k).equal?(buf) })
                [RES_ATLAS, tx.atlas_base(t) + ofs]
              else
                raise PreparationError, "@dc_srcbuf is none of the column resources"
              end
            else
              buf = r.instance_variable_get(:@ds_source)
              flats = tx.instance_variable_get(:@flatdata)
              if buf.bytesize.zero? then [RES_NONE, 0]
              elsif (k = flats.index { |fd| fd.equal?(buf) }) then [RES_FLAT, k * 4096]
              else
                raise PreparationError, "@ds_source is none of the flats"
              end
            end
          part == "res" ? sel : base
        end
      end

      # WHERE EACH PART OF A JOINED BYTE RESOURCE STARTS. `offsets-of:Hud@@texts`
      # is the field `hud_text_ofs`: `hud_texts` holds every HUD message end to
      # end, and this holds where message m starts, with one more entry, the end
      # of the last -- so message m is the bytes from ofs[m] to ofs[m + 1].
      #
      # THE PARTS ARE READ THROUGH THE ORIGIN THE JOINED FIELD ITSELF HAS
      # (core-acquired.tsv's row for Hud@@texts), not through a second spelling
      # of it, so the offsets and the bytes cannot come from two lists.
      #
      # AND THEY ARE CHECKED HERE, WHERE THEY ARE MADE: the first offset is 0,
      # no offset is below the one before it, and the last is the byte count of
      # the parts joined, which is measured rather than written down. Offsets
      # summed from those same parts satisfy all three by construction, so this
      # guards the summing code, not the data; `check_offsets` is separate so
      # its refusals can be shown refusing. The INDEPENDENT check is the
      # reference: full/reference.rb sums the original Hud's own @texts, and
      # state.sh compares every prepared field with it, cell for cell.
      OFFSETS_OF = "offsets-of:"
      OffsetsOf = Struct.new(:name, :holder, :meth, :arg) do
        def offsets
          parts = arg ? holder.public_send(meth, arg) : holder.public_send(meth)
          (parts.is_a?(Array) && parts.all? { |t| t.is_a?(String) }) or
            raise PreparationError, "#{name}: the parts are not an array of strings"
          ofs = [0]
          parts.each { |t| ofs << ofs.last + t.bytesize }
          Resources.check_offsets(name, ofs, parts.join.b.bytesize)
          ofs
        end
      end
      def self.check_offsets(name, ofs, total)
        ofs.first == 0 or raise PreparationError, "#{name}[0] is #{ofs.first.inspect}, not 0"
        ofs.each_cons(2).with_index do |(a, b), i|
          b >= a or raise PreparationError, "#{name}[#{i + 1}] is #{b}, below #{name}[#{i}] #{a}"
        end
        ofs.last == total or
          raise PreparationError, "#{name}'s last offset is #{ofs.last}, the joined bytes are #{total}"
        ofs
      end

      PER_ENTRY = "per-entry:"
      PerEntry = Struct.new(:wad, :field, :width) do
        def entries
          n = wad.count
          if field == "name"
            (0...n).map do |i|
              nm = wad.lump(i).name.b
              nm.bytesize <= width or
                raise PreparationError, "lump #{i} name #{nm.inspect} is longer than #{width}"
              nm + ("\0" * (width - nm.bytesize))
            end.join
          else
            (0...n).map { |i| wad.lump(i).public_send(field) }
          end
        end
      end

      def self.resolve_producer(org, objects)
        return nil if org.start_with?(DERIVED)
        # ANCHORED, not split on ":". The class is `Doom::Wad`, and splitting the
        # whole origin on ":" cut `Doom::Wad` itself into "Doom", "", "Wad" --
        # so this form never resolved, and the three fields were reported as
        # having no single Lump to read, which was true and was not the reason.
        if (m = org.match(/\Aper-entry:((?:[A-Z]\w*)(?:::[A-Z]\w*)*):(name|pos|size)(?::(\d+))?\z/))
          obj = objects[m[1]]
          return nil unless obj
          return [PerEntry.new(obj, m[2], m[3] && Integer(m[3], 10)), :entries, nil, :object]
        end
        if (m = org.match(/\Asource-select:(dc|ds):(res|base)\z/))
          r = objects["Doom::Renderer"]
          return nil unless r
          return [SourceSelect.new(r, m[1], m[2]), :value, nil, :object]
        end
        # A CONSTANT on a class Full has loaded -- `Doom::Hud::MESSAGES`. It is
        # a packed literal like the Info tables, so it is a second read of one
        # constant and is counted with those, not with the object reads.
        if org =~ /\A((?:[A-Z]\w*::)+)([A-Z][A-Z0-9_]*)\z/
          owner = $1.chomp("::").split("::").inject(Object) do |m, c|
            m.const_defined?(c, false) ? m.const_get(c, false) : (break nil)
          end
          return nil unless owner && owner.const_defined?($2, false)
          return [owner, :const_get, $2, :module]
        end
        # `Game@@mobj_x`, the schema's own spelling for a field on a class
        # Full constructs.
        if org =~ /\A([A-Za-z]+)@@(\w+)\z/
          obj = objects["Doom::#{$1}"]
          return nil unless obj
          ivar = "@#{$2}"
          return nil unless obj.instance_variables.include?(ivar.to_sym)
          return [obj, :instance_variable_get, ivar, :object]
        end
        if org =~ /\A([A-Za-z:]+)\s*@(\w+)\z/
          obj = objects[$1]
          return nil unless obj
          ivar = "@#{$2}"
          return nil unless obj.instance_variables.include?(ivar.to_sym)
          return [obj, :instance_variable_get, ivar, :object]
        end
        if org.include?("#")
          cls, _, rest = org.partition("#")
          meth, _, arg = rest.partition(":")
          obj = objects[cls]
          return nil unless obj && !meth.empty? && obj.respond_to?(meth)
          [obj, meth, (arg.empty? ? nil : arg), :object]
        else
          mod, _, meth = org.partition(".")
          holder = MODULE_PRODUCERS[mod]
          return nil unless holder && !meth.empty? && holder.respond_to?(meth)
          [holder, meth, nil, :module]
        end
      end

      # `objects` are the things Full builds from the WAD BEFORE any game
      # exists -- the wad itself and the texture set. A field produced from one
      # of these is produced on Full's own side of the comparison. With a map
      # the caller also supplies the level, the game, the sprites and the
      # renderer; constructing them is Full's preparation, not the game
      # running, and the two kinds of producer are reported apart.
      def self.prepared(acquired:, schema:, objects: {})
        origin_of = {}
        File.foreach(acquired) do |ln|
          next if ln.start_with?("#") || ln.strip.empty?
          f = ln.chomp.split("\t", -1)
          origin_of[f[0]] = f[2]
        end
        # A FIELD WHOSE VALUE IS A CONVERSION names its producer in
        # core-representations.tsv, by FIELD NAME: `renderer_dc_srcres` keeps the
        # origin `Renderer@@dc_srcres`, and reading that ivar would give the
        # original's masked-path value, not the selector.
        producer_of = {}
        reps = File.join(File.dirname(acquired), "core-representations.tsv")
        if File.exist?(reps)
          File.foreach(reps) do |ln|
            next if ln.start_with?("#") || ln.strip.empty?
            f = ln.chomp.split("\t", -1)
            producer_of[f[1]] = f[5] if f.length == 6 && !f[5].to_s.empty?
          end
        end
        out = {}
        from_table_names = []
        from_object_names = []
        # PER FIELD, NOT PER REASON. This returned `Hash.new(0)` counts keyed
        # by the reason -- `skipped 159: not an acquired field` -- and I
        # described it as naming every field it could not produce. It did not.
        # A count by reason cannot be checked against the prepared set, so
        # there was no way to see a field falling out of both halves.
        unsupported = []
        File.foreach(schema) do |ln|
          next if ln.start_with?("#") || ln.strip.empty?
          name, _role, element, _count, initial, source, = ln.chomp.split("\t", -1)
          next unless initial.to_s.start_with?("prepared:")
          # THE SCHEMA ALREADY NAMES THE CLASS AND THE IVAR. `source` is
          # `Game@@mobj_x`, so a field Full ALLOCATES needs no row in the
          # acquired table -- that table records where an UNALLOCATED field
          # comes from, and 159 fields were reported as having no row when the
          # schema had said all along where they live.
          #
          # THIS IS WEAKER EVIDENCE AND IT IS COUNTED APART. For a packed
          # table, Full building it is a second path to the same bytes. For
          # `Level@@sector_floorheight` there is no second path: Full obtains
          # it by loading the level, which is what the reference does. That
          # comparison exercises the SCHEMA AND SESSION ROUTE -- layout,
          # offsets, lengths, the binding of a prepared name to one field --
          # and not the value. Reporting the two together would claim the
          # stronger thing for both.
          org = producer_of[name] || origin_of[source] || source
          holder, meth, arg, kind =
            if org.start_with?(OFFSETS_OF)
              of = org.delete_prefix(OFFSETS_OF)
              ph, pm, pa, pk = resolve_producer(origin_of[of] || of, objects)
              ph && [OffsetsOf.new(name, ph, pm, pa), :offsets, nil, pk]
            else
              resolve_producer(org, objects)
            end
          unless holder
            why =
              if org.start_with?(DERIVED)
                "#{org.sub(DERIVED, '')} is the SOURCE, and the field is a transformation " \
                "of it that Full does not implement here"
              elsif source =~ /\A([A-Za-z]+)@@/ && !objects.key?("Doom::#{$1}")
                # SAY WHICH OBJECT IS MISSING. "Not one Full can call" is true
                # and tells a reader nothing; the useful fact is that Full
                # builds no single object of that class. `Doom::Lump` is the
                # case: it is one WAD directory entry per lump, not a singleton,
                # and the reference cannot read these fields either -- they are
                # unreachable on BOTH sides, so there is nothing to compare.
                "Full constructs no single Doom::#{$1} to read #{source} from"
              else
                "producer #{org} is not one Full can call here"
              end
            unsupported << [name, source, why]
            next
          end
          pack = PACK[element] or
            raise PreparationError, "#{name}: element #{element.inspect} has no encoding"
          value = arg ? holder.public_send(meth, arg) : holder.public_send(meth)
          # THE SAME REPRESENTATION RULES AS THE ENCODER, not new ones. A
          # prepared SCALAR -- `Level@@num_sectors`, `Renderer@@viewwidth` --
          # is one element, and a flag is stored numerically, 0 for false and
          # 1 for true, which is the conversion 0008 approves and the one
          # `Reference.encode` applies (reference.rb: `when Integer then
          # [value]`, `when true then [1]`, `when false then [0]`).
          #
          # nil IS NOT IN THAT LIST ON PURPOSE. The encoder refuses a present
          # nil rather than turning it into 0, and so does this: it falls
          # through to "not this field's bytes" below instead of becoming a
          # zero nobody measured.
          items =
            if value.is_a?(String) then value.bytes
            elsif value.is_a?(Array) && value.first.is_a?(String) then value.join.bytes
            elsif value.is_a?(Array) then value.map { |v| v == true ? 1 : (v == false ? 0 : v) }
            elsif value.is_a?(Integer) then [value]
            elsif value == true then [1]
            elsif value == false then [0]
            end
          # A DIRECT PRODUCER THAT RETURNS SOMETHING THAT IS NOT BYTES IS A
          # DEFECT, and it is an ERROR -- not an unsupported field.
          #
          # This used to move such a field into the unsupported set, which
          # took it out of the comparison. That is the wrong half. "Unsupported"
          # is for what Full is known not to do yet, decided BEFORE the producer
          # runs: no row, no object of that class, a declared `derived-from:`
          # transformation. A producer Full DID call that answered with a nil,
          # or anything else no element can hold, has told us something is
          # wrong, and removing the field would hide it. The reference raises
          # on a present nil for the same reason.
          unless items
            raise PreparationError,
                  "#{name}: #{org} gave a #{value.class}, which no element can hold"
          end
          if I32_BITS.include?(name)
            element == "i32" or raise PreparationError, "#{name}: i32-bits in element #{element}, not i32"
            items = items.each_with_index.map do |v, i|
              (v.is_a?(Integer) && v >= 0 && v <= 4_294_967_295) or
                raise PreparationError, "#{name}[#{i}] is #{v.inspect}, not a 32-bit word"
              v >= 2_147_483_648 ? v - 4_294_967_296 : v
            end
          end
          range = DOMAIN[element] or
            raise PreparationError, "#{name}: element #{element.inspect} has no domain"
          lo, hi = range
          items.each_with_index do |v, i|
            v.is_a?(Integer) or
              raise PreparationError, "#{name}[#{i}] is a #{v.class}, not an Integer"
            (v >= lo && v <= hi) or
              raise PreparationError, "#{name}[#{i}] is #{v}, outside #{element} " \
                                      "(#{lo}..#{hi}); refusing to wrap it"
          end
          out[name] = items.pack("#{pack}*")
          # CLASSIFIED BY WHAT ACTUALLY PRODUCED IT, not by whether a table
          # happened to name it. This asked `origin_of[source].nil?`, so every
          # field with an acquired row counted as a packed table -- the IWAD,
          # the atlases, the COLORMAP lump among them -- and 57 were reported
          # as a second path when 40 are. (This said "when 2 were", which was
          # neither number: 57/2 was the wrong split it produced and 40/19 is
          # the measured one. A comment carrying a number nobody measured is
          # the same fault as a schema carrying one.) Appearing in a table is
          # not evidence of anything; the producer's KIND is.
          (kind == :module ? from_table_names : from_object_names) << name
        end
        [out, unsupported, { "table" => from_table_names, "object" => from_object_names }]
      end

      # The catalog as `state-schema.rb` reads it.
      def self.write_catalog(counts, path)
        File.open(path, "w") do |io|
          io.puts("# Generated by examples/doom/core/full/resources.rb -- a MEASUREMENT")
          io.puts("# of one configuration, not a table about DOOM in general.")
          io.puts("#kind\tname\tvalue")
          counts.sort.each { |k, v| io.puts("count\t#{k}\t#{v}") }
        end
      end
    end
  end
end
