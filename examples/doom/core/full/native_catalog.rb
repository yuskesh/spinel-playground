# examples/doom/core/full/native_catalog.rb — the catalog, measured by the playable program.
#
# Doom::Core::Resources.catalog (resources.rb) measures the counts a schema
# names from the objects Full builds, in CRuby. The playable program is
# compiled by the pinned Spinel and cannot run that method: it reads ivars by
# computed names, which this pin refuses at run time. This is the same
# measurement written for that compiler, from the objects bin/doom.rb already
# builds, one literal read per count. tests/doom-core's native lane compares
# every count it answers with Resources.catalog's for the same configuration,
# count by count, so the two cannot drift silently.
#
# ONE COUNT HAS A DIFFERENT PRODUCER HERE, ON PURPOSE: `rejectbytes`.
# Resources.catalog measures the REJECT value Level holds (`bytesize`); this
# measures the REJECT lump's size in the WAD directory, which is what
# Level#load_reject's byteslice is sized by. The pin cannot call `bytesize` on
# that value (docs/doom.md, "Known compiler defects on this pin"), and the two
# producers are DELIBERATELY DIFFERENT: they are two witnesses to one
# quantity, and the lane's comparison is the check. Do not unify them. They
# can differ only if the lump runs past the end of the file, which would be a
# finding about the WAD, not a defect of the port.
module Doom
  module Core
    module NativeCatalog
      SETBLOCKS = 10
      KNOT_FRAME_CELLS = 21
      KNOT_FRAMES_DEBT = 256

      def self.measure(wad, lv, tx, sp, width, height, script_lines)
        out = {}
        plw = width + 2
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
        out["screenwidth"] = width
        out["screenheight"] = height
        out["screenpixels"] = width * height
        out["screenwidthplus1"] = width + 1
        out["openings"] = width * 64
        out["visplanecells"] = 128 * plw
        out["jobwallcells"] = width * 64
        out["jobmaskedcells"] = width * 256
        view = ((SETBLOCKS * 168 / 10) & ~7) * (width / 320)
        out["viewheight"] = view
        out["viewpixels"] = width * view
        out["jobspancells"] = view * 256
        out["statusbarbytes"] = 320 * 32
        out["sightcells"] = 3 * (lv.num_nodes + 1)
        out["bspcells"] = 3 * (lv.num_nodes + 2)
        out["soundcells"] = 6 * (lv.num_sectors + 1)
        out["sbshadowpixels"] = width == 320 ? 1 : 320 * 200
        out["knotcells"] = KNOT_FRAME_CELLS * KNOT_FRAMES_DEBT
        out["textures"] = tx.numtextures
        out["flats"] = tx.numflats
        out["sprites"] = sp.numsprites
        out["spritelumps"] = sp.numspritelumps
        out["lumps"] = wad.count
        out["lumpnamebytes"] = wad.count * 8
        out["blockmapwords"] = lv.blockmap.length
        out["sectorlinetotal"] = lv.sector_lines.length
        out["flatatlas"] = tx.flat_atlas.bytesize
        out["pnames"] = tx.numpatches
        out["switchnames"] = Doom::Specials::SWITCH_NAMES.length
        out["demobytes"] = Doom::Demo::HEADER + 40_000 * 4 + 1
        out["finesine"] = Doom::Tables.finesine.length
        out["finetangent"] = Doom::Tables.finetangent.length
        out["tantoangle"] = Doom::Tables.tantoangle.length
        out["mobjinfo"] = Doom::Info.mobj_damage.length
        out["states"] = Doom::Info.state_tics.length
        out["weaponinfo"] = Doom::Info.weapon_ammo.length
        n = 0
        Doom::Info.sprnames.each { |s| n += s.bytesize }
        out["sprnamebytes"] = n
        n = 0
        Doom::Hud::MESSAGES.each { |s| n += s.bytesize }
        out["hudmessages"] = n
        out["waddata"] = wad.data.bytesize
        out["texatlas"] = tx.tex_atlas.bytesize
        out["colormap"] = wad.bytes_by_name("COLORMAP").bytesize
        spl = sp.instance_variable_get(:@lump)
        out["spriteframes"] = spl.length
        spr = sp.instance_variable_get(:@rotate)
        out["spriterotations"] = spr.length
        tcl = tx.instance_variable_get(:@collump)
        out["texcolumns"] = tcl.length
        tab = tx.instance_variable_get(:@anim_basepic)
        out["animations"] = tab.length
        out["maxmobjs"] = 4096
        out["maxthinkers"] = 4096
        out["demotics"] = 40_000
        out["jobsched"] = 12_288
        out["jobwallfields"] = 4096 * 7
        out["jobspanfields"] = 3072 * 7
        out["jobmaskedfields"] = 8192 * 9
        out["jobzonecells"] = 3072 * 128
        specials = 0
        i = 0
        while i < lv.num_lines
          specials += 1 if lv.line_special[i] == 48
          i += 1
        end
        out["linespecials"] = specials
        # The directory's size, not the value's bytesize: see the header.
        out["rejectbytes"] = wad.lump(wad.map_lump(lv.mapname, "REJECT")).size
        out["scriptlines"] = script_lines
        out
      end
    end
  end
end
