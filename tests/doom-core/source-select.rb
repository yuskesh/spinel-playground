# frozen_string_literal: true
#
# tests/doom-core/source-select.rb — the source aliases as a selector and a base, running.
#
#   ruby tests/doom-core/source-select.rb IWAD [TICS] [MUTANT]
#
# docs/core/doom-source-alias.md. The schema no longer holds `@dc_srcbuf` or
# `@ds_source`, references to a buffer; it holds a SELECTOR (RES_NONE -1,
# RES_ATLAS 0, RES_WAD 1, RES_ZONE 2, RES_FLAT 3) and a BASE into that
# resource. Full converts the original's choice in `Resources::SourceSelect`,
# the reference converts it separately. This runs the original renderer over
# DEMO1 in the direct CPU path (job mode 0) and checks, with test-side hooks:
#
#   before the first tick  both conversions give RES_NONE and base 0, for the
#                          column and for the span
#   at every consumer      each time `draw_column` or `draw_span` reads a source:
#                          the two conversions agree; the selector is never
#                          RES_NONE; and reading THROUGH the selector and base --
#                          from the resources the schema declares (texture atlas,
#                          WAD data, @zonewin, flat atlas), not from the buffer
#                          the original holds -- gives exactly the bytes the
#                          original reads, all 128 of a column window or 4096 of
#                          a flat
#   at every frame end     the two conversions agree on what the renderer holds
#
# MUTANT shows each is seen: `raw-srcres` has Full read the original's
# `@dc_srcres` as is; `base-off` shifts the transformed read by one byte;
# `res-none` hands one column consumer an empty source; `wrong-res` has Full
# call a texture column WAD data.
ROOT = File.expand_path("../..", __dir__)
%w[wad level texnames texture sprites statusbar hud render info random game demo].each do |f|
  require_relative File.join(ROOT, "examples/doom/lib/doom", f)
end
require_relative File.join(ROOT, "examples/doom/core/full/resources")
require_relative File.join(ROOT, "examples/doom/core/full/reference")

iwad, tics, mutant = ARGV
iwad && File.exist?(iwad) or abort("usage: source-select.rb IWAD [TICS] [none|raw-srcres|base-off|res-none|wrong-res]")
tics = Integer(tics || "60", 10)
mutant ||= "none"
%w[none raw-srcres base-off res-none wrong-res].include?(mutant) or abort("source-select.rb: unknown mutant #{mutant}")
RES = Doom::Core::Resources
REF = Doom::Core::Reference

if mutant == "raw-srcres"
  RES::SourceSelect.prepend(Module.new do
    define_method(:value) { which == "dc" && part == "res" ? renderer.instance_variable_get(:@dc_srcres) : super() }
  end)
elsif mutant == "wrong-res"
  RES::SourceSelect.prepend(Module.new do
    define_method(:value) { which == "dc" && part == "res" && super() == RES::RES_ATLAS ? RES::RES_WAD : super() }
  end)
end

$faults = Hash.new(0)
$first = {}
$count = Hash.new(0)
def fault(kind, where)
  $faults[kind] += 1
  $first[kind] ||= where
end

wad = Doom::Wad.new(iwad)
demo = Doom::Demo.new(wad, "DEMO1", "")
lv = Doom::Level.new(wad, demo.mapname, demo.episode)
tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
rnd = Doom::Random.new
rnd.clear
g = Doom::Game.new(wad, lv, demo.skill, rnd, tx)
sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
r = Doom::Renderer.new(lv, wad, wad.bytes_by_name("COLORMAP"), tx, sp, g, 10, false, 1)
FULL_OBJECTS = { "Doom::Renderer" => r }.freeze
REF_OBJECTS = { "Renderer" => r }.freeze

# Both conversions of one part: [full, reference].
def both(which, part)
  full = RES::SourceSelect.new(FULL_OBJECTS["Doom::Renderer"], which, part).value
  origin = which == "dc" ? (part == "res" ? "Renderer@@dc_srcres" : "Renderer@@dc_srcbase")
                         : (part == "res" ? "Renderer@@ds_source" : "Renderer@@ds_source.base")
  kind, refv = REF.field_value(REF_OBJECTS, origin)
  [full, kind == :ok ? refv : [kind, refv]]
end

# What a consumer reads through a selector and base, from the declared resources.
RESOURCE = {
  RES::RES_ATLAS => ->(rr) { rr.instance_variable_get(:@textures).tex_atlas },
  RES::RES_WAD => ->(rr) { rr.instance_variable_get(:@wad_data) },
  RES::RES_ZONE => ->(rr) { rr.instance_variable_get(:@zonewin) },
  RES::RES_FLAT => ->(rr) { rr.instance_variable_get(:@textures).flat_atlas }
}.freeze
def through(rr, sel, base, len)
  src = RESOURCE[sel] or return nil
  shift = $mutant == "base-off" ? 1 : 0
  src.call(rr).byteslice(base + shift, len)
end
$mutant = mutant

pre = %w[dc ds].flat_map { |w| %w[res base].map { |p| both(w, p) } }
puts "pre-tick #{pre.map { |f, x| f == x ? f : "#{f}/#{x}" }.join(' ')}"

Doom::Renderer.prepend(Module.new do
  define_method(:draw_column) do |use_zone_window = false|
    # The direct renderer consumes its reusable zone window without publishing
    # it in @dc_srcbuf. Expose the actual source only while the independent
    # selector probes run, and restore the renderer's stored source afterward.
    stored_source = @dc_srcbuf
    @dc_srcbuf = @zonewin if use_zone_window
    if !@dc_fuzz && @dc_yh >= @dc_yl
      if $mutant == "res-none" && $count["columns"] == 100
        saved = @dc_srcbuf
        @dc_srcbuf = ""
      end
      where = "tic #{$tic} x #{@dc_x}"
      (fs, rs), (fb, rb) = both("dc", "res"), both("dc", "base")
      $count["columns"] += 1
      fault("disagree", where) if fs != rs || fb != rb
      if fs == RES::RES_NONE
        # A consumer reached with nothing selected is REPORTED, and not drawn.
        fault("res-none-consumer", where)
        @dc_srcbuf = saved if saved
        next nil
      end
      $count["read-dc:#{fs}"] += 1
      window = @dc_srcbuf.byteslice(@dc_srcofs, 128)
      fault("read-mismatch", where) if through(self, fs, fb, window.bytesize) != window
    end
    super(use_zone_window)
  ensure
    @dc_srcbuf = stored_source if use_zone_window
  end
  define_method(:draw_span) do |y, x1, x2, xfrac, yfrac, xstep, ystep, cmap|
    where = "tic #{$tic} y #{y}"
    (fs, rs), (fb, rb) = both("ds", "res"), both("ds", "base")
    $count["spans"] += 1
    fault("disagree", where) if fs != rs || fb != rb
    if fs == RES::RES_NONE
      fault("res-none-consumer", where)
    elsif ($count["read-ds:#{fs}"] += 1) && through(self, fs, fb, 4096) != @ds_source.byteslice(0, 4096)
      fault("read-mismatch", where)
    end
    super(y, x1, x2, xfrac, yfrac, xstep, ystep, cmap)
  end
end)

selectors = Hash.new(0)
n = [tics, demo.numtics].min
t = 0
while t < n
  $tic = t
  rnd.tic = t
  320.times { rnd.m_random } if t == 2
  g.g_ticker(demo.forwardmove[t], demo.sidemove[t], demo.angleturn[t], demo.buttons[t])
  rnd.m_random
  r.clear_screen if t == 0
  r.set_psprite(g.psp_state[0], g.psp_sx[0], g.psp_sy[0])
  r.set_psprite_flash(g.psp_state[1], g.psp_sx[1], g.psp_sy[1])
  r.extralight = g.extralight
  r.render_player_view(g.viewx, g.viewy, g.viewz, g.viewangle)
  # THE ENTRY BOUNDARY: what the renderer holds after the frame, both ways.
  %w[dc ds].each do |w|
    (fs, rs), (fb, rb) = both(w, "res"), both(w, "base")
    fault("boundary-disagree", "tic #{t} #{w}") if fs != rs || fb != rb
    selectors["#{w}:#{fs}"] += 1
  end
  t += 1
end

puts "tics #{n} columns #{$count['columns']} spans #{$count['spans']} " \
     "boundary #{selectors.sort.map { |k, v| "#{k}=#{v}" }.join(',')}"
puts "reads " + $count.keys.grep(/\Aread-/).sort.map { |k| "#{k.delete_prefix(%q(read-))}=#{$count[k]}" }.join(",")
kinds = %w[disagree res-none-consumer read-mismatch boundary-disagree]
puts "faults " + kinds.map { |k| "#{k} #{$faults[k]}" }.join(" ")
puts "first " + (kinds.map { |k| $first[k] && "#{k} #{$first[k]}" }.compact.first || "none")
