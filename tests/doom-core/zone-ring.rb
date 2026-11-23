# frozen_string_literal: true
#
# tests/doom-core/zone-ring.rb — RES_ZONE's two stores: kept, and actually read.
#
#   ruby tests/doom-core/zone-ring.rb IWAD MODE [TICS]
#   ZONE_RING_LIB=DIR  load the game from DIR instead of examples/doom/lib/doom
#                      (a private copy with one line changed, for a control)
#
# docs/core/doom-source-alias.md, prerequisite C: `RES_ZONE` names two stores,
# chosen by the consumer's context, with two lifetimes. This runs the ORIGINAL
# over DEMO1 with test-side hooks (`prepend`, and `getbyte` observers on the
# source buffers themselves); the game files are not changed.
#
# WHAT IS OBSERVED IS THE CONSUMER'S OWN READS. An earlier version compared the
# ring bytes at the slot a job was PUSHED with, before the executor ran -- which
# an executor reading `@waddata` instead still passed (Mac review of 811ccfa).
# Now each expected consumption is recorded where it is produced, independently
# of which source the consumer then selects, and every source byte the consumer
# reads is seen as it happens:
#
#   queued (job mode 2)  a masked RES_ZONE job, when pushed, expects yh-yl+1
#                        reads, all from the ring, inside [slot, slot + 128),
#                        with the ring still holding the bytes it was pushed
#                        with. While `JobExecutor#exec_masked` runs it, every
#                        `getbyte` on the ring or the WAD data is recorded.
#   direct (job mode 0)  a `Wad#zone_window` call made inside
#                        `Renderer#draw_masked_column` -- the producer, whatever
#                        buffer it passes -- expects the next `draw_column` to
#                        read only the renderer's `@zonewin`, inside [0, 128),
#                        holding what zone_window wrote. A second window before
#                        any consumption is a missed one.
#   paired               both, on fresh objects, and the two consumers against
#                        each other: render.rb's draw_column and the executor's
#                        exec_masked each compute which byte of the window to
#                        read per pixel, so their sequences of indices RELATIVE
#                        TO THE BASE must be identical, consumption by
#                        consumption. That is what a base shifted inside the
#                        window -- invisible to the range check -- changes.
#
# Faults are counted by kind -- wrong-store, out-of-window, wrong-count,
# stale-bytes, not-consumed -- and the first is named by frame/tic and job/slot.
#
#   reset-early / same-slot  queued, with the allocator misbehaving (hooks)
#   capacity                 a fresh Jobs: the 3072nd slot, then JobError
#
# NOT covered: job mode 4, where the GPU reads the ring. Nothing here observes
# the driver.
ROOT = File.expand_path("../..", __dir__)
LIB = ENV["ZONE_RING_LIB"] || File.join(ROOT, "examples/doom/lib/doom")
%w[wad level texnames texture sprites statusbar hud render info random game jobs executor demo].each do |f|
  require File.join(LIB, f)
end

MODES = %w[queued reset-early same-slot direct paired capacity].freeze
iwad, mode, tics = ARGV
(iwad && File.exist?(iwad) && MODES.include?(mode)) or
  abort("usage: zone-ring.rb IWAD #{MODES.join('|')} [TICS]")
tics = Integer(tics || "200", 10)
STRIDE = Doom::Jobs::ZONE_STRIDE
KINDS = %w[wrong-store out-of-window wrong-count stale-bytes not-consumed].freeze

if mode == "capacity"
  jobs = Doom::Jobs.new(320, 200)
  slots = Doom::Jobs::ZONE_SLOTS
  last = nil
  slots.times { last = jobs.alloc_zone_window }
  over = begin
    jobs.alloc_zone_window
    "no error"
  rescue Doom::JobError => e
    e.message
  end
  puts "capacity slots #{slots} last #{last} last-expected #{(slots - 1) * STRIDE} nzone #{jobs.nzone}"
  puts "overflow #{over}"
  exit 0
end

$faults = Hash.new(0)
$first = nil
$count = Hash.new(0)
$seq = { 2 => [], 0 => [] }
$mutant = mode
def fault(kind, where)
  $faults[kind] += 1
  $first ||= "#{kind} #{where}"
end

# THE READ OBSERVER. While `$reads` is an array, every getbyte on a watched
# buffer appends [name, index].
$reads = nil
def watch(buf, name)
  buf.define_singleton_method(:getbyte) do |i|
    $reads << [name, i] if $reads
    super(i)
  end
end

# BOTH hook sets are installed; each acts only in its own job mode -- the
# executor runs only with jobs, and the masked column calls `zone_window` only
# without them.
$frame = -1
$expect = {}            # masked job index -> [slot, bytes, reads expected]
Doom::Jobs.prepend(Module.new do
  define_method(:reset) do
    $expect.each { |i, (slot, _, _)| fault("not-consumed", "frame #{$frame} job #{i} slot #{slot}") }
    super()
    $frame += 1
    $expect = {}
  end
  define_method(:alloc_zone_window) do
    slot = super()
    $mutant == "same-slot" ? 0 : slot
  end
  define_method(:push_masked) do |x, yl, yh, iscale, texmid, srcres, srcofs, cmap, fuzz|
    i = @nmasked
    super(x, yl, yh, iscale, texmid, srcres, srcofs, cmap, fuzz)
    if srcres == Doom::Jobs::RES_ZONE
      $expect[i] = [srcofs, @zonebuf.byteslice(srcofs, STRIDE), yh - yl + 1]
      $count["zone-jobs"] += 1
      $count["nonzero-slots"] += 1 if srcofs != 0
      @nzone = 0 if $mutant == "reset-early"
    end
  end
end)
Doom::JobExecutor.prepend(Module.new do
  define_method(:exec_masked) do |i, scr|
    exp = $expect.delete(i)
    $reads = [] if exp
    super(i, scr)
    if exp
      slot, bytes, want = exp
      reads = $reads
      $reads = nil
      where = "frame #{$frame} job #{i} slot #{slot}"
      $count["consumed"] += 1
      fault("wrong-store", where) if reads.any? { |name, _| name != "ring" }
      fault("out-of-window", where) if reads.any? { |name, k| name == "ring" && (k < slot || k >= slot + STRIDE) }
      fault("wrong-count", where) if want >= 1 && reads.length != want
      fault("stale-bytes", where) if @jobs.zonebuf.byteslice(slot, STRIDE) != bytes
      $seq[2] << [where, reads.map { |_, k| k - slot }]
    end
  end
end)

$pending = nil          # [bytes, out buffer, tic]
$in_masked = false
Doom::Wad.prepend(Module.new do
  define_method(:zone_window) do |lumpnum, off, out|
    # Only the renderer's masked column produces a source window; Textures also
    # calls zone_window, to compose into its own buffer.
    next super(lumpnum, off, out) unless $in_masked
    fault("not-consumed", "tic #{$tic}") if $pending
    r = super(lumpnum, off, out)
    $pending = [out.byteslice(0, STRIDE), out, $tic]
    $count["windows"] += 1
    r
  end
end)
Doom::Renderer.prepend(Module.new do
  define_method(:draw_masked_column) do |*args|
    $in_masked = true
    super(*args)
  ensure
    $in_masked = false
  end
  define_method(:draw_column) do |use_zone_window = false|
    exp = $pending
    $pending = nil
    if exp && !@dc_fuzz && @dc_yh >= @dc_yl
      $reads = []
      want = @dc_yh - @dc_yl + 1
      zonewin = @zonewin
      x = @dc_x
      super(use_zone_window)
      reads = $reads
      $reads = nil
      where = "tic #{$tic} x #{x}"
      $count["consumed"] += 1
      fault("wrong-store", where) if reads.any? { |name, _| name != "zonewin" }
      fault("out-of-window", where) if reads.any? { |name, k| name == "zonewin" && (k < 0 || k >= STRIDE) }
      fault("wrong-count", where) if reads.length != want
      fault("stale-bytes", where) if !exp[1].equal?(zonewin) || zonewin.byteslice(0, STRIDE) != exp[0]
      $seq[0] << [where, reads.map { |_, k| k }]
    else
      $count["not-drawn"] += 1 if exp
      super(use_zone_window)
    end
  end
end)

def run_demo(iwad, tics, jobmode)
  wad = Doom::Wad.new(iwad)
  demo = Doom::Demo.new(wad, "DEMO1", "")
  lv = Doom::Level.new(wad, demo.mapname, demo.episode)
  tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
  rnd = Doom::Random.new
  rnd.clear
  g = Doom::Game.new(wad, lv, demo.skill, rnd, tx)
  sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
  r = Doom::Renderer.new(lv, wad, wad.bytes_by_name("COLORMAP"), tx, sp, g, 10, false, 1)
  r.job_mode = jobmode
  if jobmode == 2
    ex = r.instance_variable_get(:@exec)
    watch(ex.instance_variable_get(:@jobs).zonebuf, "ring")
    watch(ex.instance_variable_get(:@waddata), "wad")
  else
    watch(r.instance_variable_get(:@zonewin), "zonewin")
    watch(r.instance_variable_get(:@wad_data), "wad")
  end
  $frame = -1
  $expect = {}
  $pending = nil
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
    t += 1
  end
  # The last frame's jobs have run; anything still expected was never consumed.
  $expect.each { |i, (slot, _, _)| fault("not-consumed", "frame #{$frame} job #{i} slot #{slot}") }
  fault("not-consumed", "tic #{$pending[2]}") if $pending
  n
end

def faults_line = "faults " + KINDS.map { |k| "#{k} #{$faults[k]}" }.join(" ")

case mode
when "paired"
  run_demo(iwad, tics, 2)
  run_demo(iwad, tics, 0)
  q = $seq[2]
  d = $seq[0]
  diff = (0...[q.length, d.length].min).select { |k| q[k][1] != d[k][1] }
  puts "paired queued #{q.length} direct #{d.length} differ #{diff.length}"
  puts faults_line
  puts "first " + (diff.empty? ? "none" : "#{q[diff.first][0]} / #{d[diff.first][0]}")
when "direct"
  n = run_demo(iwad, tics, 0)
  puts "tics #{n} windows #{$count['windows']} consumed #{$count['consumed']} fuzz-or-empty #{$count['not-drawn']}"
  puts faults_line
  puts "first #{$first || 'none'}"
else
  run_demo(iwad, tics, 2)
  puts "frames #{$frame + 1} zone-jobs #{$count['zone-jobs']} nonzero-slots #{$count['nonzero-slots']} " \
       "consumed #{$count['consumed']}"
  puts faults_line
  puts "first #{$first || 'none'}"
end
