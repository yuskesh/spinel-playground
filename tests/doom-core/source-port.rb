# frozen_string_literal: true
#
# tests/doom-core/source-port.rb — the CORE source producers and consumers, run in the game.
#
#   ruby tests/doom-core/source-port.rb IWAD MODE [TICS] [CONTROL]
#     MODE     direct (job mode 0) | queued (job mode 2) | frame (job mode 2, the
#              whole executor run compiled, the screen compared after each frame)
#     CONTROL  none | no-sky | no-wall | skip-masked | no-span | no-zone | queued-wrong-store
#              | zone-separate-ring | reset-drop-nzone
#              | frame-order | frame-fuzz-phase | frame-wrong-bank | push-skip-sched
#              | push-kind | push-phase-counter | push-cap-low | check-lo-one
#              | check-skip-span | plane-skip | plane-wrong | plane-wrong-height | clear-skip
#              | clear-drop-counters | clear-drop-clips
#              | sky-skip | sky-texmid | sky-iscale | planes-bound-short
#              (frame mode only)
#
# examples/doom/core/src/source.rb is the port: producers that set a SELECTOR and
# a BASE on every path, and consumers that read only through them. This runs it
# INSIDE the original game over DEMO1 without changing the game's files: a
# private copy of the library is made, and at each of the original's producer
# sites one line is ADDED that calls the port's producer on the port's own state:
# one state buffer, and the indices of its cells as fields.tsv names them:
#
#   Renderer#initialize          dc_src_none, both
#   draw_sky_plane               dc_src_texture_column, the sky's angle
#   set_texture_column           dc_src_texture_column, the wall column
#   draw_masked_column           dc_src_masked_post, after the branch, before the draw
#   draw_planes                  dc_src_span, the plane's flat
#   draw_masked_column           dc_alloc_zone_window and dc_zone_window_into
#                                (src/zone.rb), after each of the original's
#                                Wad#zone_window calls: the port's window, in
#                                the port's store, checked byte for byte and
#                                slot for slot against the original's
#   Jobs#reset                   dc_jobs_reset (src/zone.rb), after the
#                                original's, over the cells it resets, each
#                                checked against the original's field
#
# The column sites also get a marker line naming the site, which a control does
# not remove, so a fault is attributed to the site whose producer is missing.
# Nothing else in the copy changes, and the anchors are checked to be unique.
# Then, at every consumer, with the original's own drawing done first:
#
#   direct  the port's `dc_draw_column` / `dc_draw_span`, reading from the
#           declared resources (atlas, IWAD bytes, @zonewin, flat atlas) through
#           the port's selector and base, must write exactly the pixels the
#           original wrote; must not answer -1; and the port's selector and base
#           must equal the original's buffer choice converted
#           (Resources::SourceSelect).
#   queued  every job pushed must carry the port's selector and base -- a wall or
#           sky job RES_ATLAS at its offset, a span RES_FLAT at its offset, a
#           masked job exactly its srcres and srcofs -- and when the executor
#           runs the job, the port's consumer must write exactly the pixels the
#           executor wrote: `dc_draw_column` over the atlas for a wall job,
#           `dc_draw_span` for a span, `dc_draw_masked_job` -- RES_ZONE meaning
#           the RING in this context -- for a masked job.
#   frame   the job banks and the executor, PORTED END TO END from the pushes:
#           at every one of the original's `Jobs#push_wall`, `#push_span` and
#           `#push_masked` the port's push (src/jobs.rb) runs with the same
#           arguments into the PORT'S banks, schedule and counters, and the
#           record, the schedule entry and both counters must equal what the
#           original just stored (`push-disagree`); at `#mark_phase1` and
#           `#mark_phase3` the port's mark, checked the same way
#           (`phase-disagree`). The plane spans are not pushed that way: the
#           original's `Renderer#draw_planes` loop runs unchanged, and before
#           each sky plane it draws (`#draw_sky_plane`, which stays Full's) and
#           at the loop's end the port catches up -- `dc_draw_plane`
#           (src/planes.rb) for every plane since the last, over the visplane
#           arrays as they were when the original's loop began, which sets the
#           plane's source, height and light, writes its sentinel columns and
#           pushes its spans through make_spans (src/planespan.rb) -- and the
#           spans, schedule entries, counters, plane cells, sentinels, spanstart
#           and row cache must equal the original's (`plane-disagree`). After
#           each `#clear_planes` the port's `dc_clear_planes` runs, and the clip
#           arrays, counters, row cache and base scales must equal the
#           original's (`clear-disagree`). What the unported BSP walk,
#           `#render_player_view`, `#extralight=` and `Textures#animate` set --
#           the visplane arrays, the view, the extra light and flattranslation
#           -- is loaded into the port's storage, and the lane names it. Once per frame, the four interval tables the
#           original's `Jobs#check` builds (src/checks.rb, the `strict`-false
#           path) are built again over the PORT'S banks, and every counter they
#           keep, every count table and every filled slot must equal the
#           original's (`check-disagree`). Then, after the original's run,
#           the executor's WHOLE RUN (src/executor.rb's `dc_exec_run`) draws the
#           port's own banks -- nothing is copied from the original's -- in
#           schedule order, fuzz columns included, onto the port's own screen,
#           which is never reloaded from the original's. After every frame the
#           port's counters must be the original's, all 64000 bytes of the
#           screen must equal the original's (`frame-disagree`), and the fuzz
#           columns drawn must be the number the original's banks schedule
#           (`fuzz-count-disagree`). The push ARGUMENTS are the original's: the
#           renderer's gathering is not ported. `Jobs#check`, which the original
#           runs first, is Full's and not ported. The per-job consumers do not
#           run.
#
# The pre-tick port state is printed beside the original's pre-tick choice
# converted, which is what Task 5's snapshot compares. The masked branch's
# boundary is printed as the game reached it.
#
# The consumers read the PORT'S zone windows, never the original's.
#
# CONTROL leaves one producer line out of the copy (no-zone: both zone producer
# lines), or, queued only, hands the masked consumer the wrong store
# (queued-wrong-store) or has the ring producer write a second ring nothing
# reads (zone-separate-ring); the fault is reported with the first site,
# tic/frame and column. Frame mode's controls change ONE thing on the port's
# side. On the port's banks, just before its run: frame-order reverses the
# schedule, frame-fuzz-phase advances every fuzz column's phase by one, and
# frame-wrong-bank writes the PREVIOUS frame's span bank over the port's from the
# second frame on. At the pushes: push-skip-sched has every wall push write its
# schedule entry into a pair of buffers nothing reads, push-kind issues every
# wall push through the port's SPAN push, push-phase-counter marks phase 1 from
# the span counter instead of the wall counter, and push-cap-low gives the port's
# wall push a capacity of 100. At the checks: check-lo-one starts the phase-0
# wall table at the second wall job instead of the first, and check-skip-span
# leaves the span table unbuilt on every odd frame. At the planes: plane-skip
# loads every plane whose index is 1 more than a multiple of 3 empty,
# plane-wrong draws the next plane's arrays in its place, plane-wrong-height
# loads every plane's height 1.0 higher than the original's array holds, and
# clear-skip leaves the port's clear_planes out on every odd frame;
# clear-drop-counters puts the four plane counters back to what the lane loaded
# before the port's clear_planes, as if its writes were deleted, and
# clear-drop-clips does the same to the two clip arrays; plane-skip,
# plane-wrong and plane-wrong-height change the visplane arrays the lane loads.
# At the sky: sky-skip gives the port a sky flat number no plane has, sky-texmid
# a sky texture middle 1.0 higher, sky-iscale a sky scale 1 higher, and
# planes-bound-short a lastvisplane one lower than the original's.
#
# SOURCE_PORT_NATIVE=LIB runs the COMPILED entries instead of the Ruby
# definitions: LIB is a shared object linking the kernel tool's objects for
# tests/doom-core/fixtures/source/*.contract, and the same names are defined
# over it, so the copy and the hooks are unchanged. Every buffer handed over is
# native storage of exactly its content's length with that length as its count,
# every call's status is counted (`native-status`, which must be 0), and the
# calls per entry are printed.
#
# SOURCE_PORT_SESSION=DIR (with SOURCE_PORT_NATIVE) opens a Doom::Core::Session
# over DIR's generated buffers.tsv and slots.tsv from Full's prepared fields,
# and hands every entry the session's fields as fields.tsv names them: the
# scalar cells are views of one core_state, and the zone producer writes the
# ring the executor reads. Each call is also checked to leave the selector in
# the slots core-representations.tsv names (`slot-disagree`).
#
# SOURCE_PORT_RECORD=PATH additionally writes the run's result record there, as
# one JSON document: decision 0009 item 1. It changes nothing the run does and
# nothing it prints; see the record's own comment below.
ROOT = File.expand_path("../..", __dir__)
# decision 0022's word intrinsics for CRuby (tools/core/intrinsics.rb): CORE
# compiles core_w32_add and the rest itself, and the units call them as
# top-level methods, which plain Ruby needs defined. Never packed.
load File.join(ROOT, "tools/core/intrinsics.rb")
require "tmpdir"
require "fileutils"

iwad, mode, tics, control = ARGV
CONTROLS = %w[none no-sky no-wall skip-masked no-span no-zone queued-wrong-store zone-separate-ring reset-drop-nzone
              frame-order frame-fuzz-phase frame-wrong-bank push-skip-sched push-kind push-phase-counter
              push-cap-low check-lo-one check-skip-span plane-skip plane-wrong plane-wrong-height clear-skip
              clear-drop-counters clear-drop-clips sky-skip sky-texmid sky-iscale planes-bound-short].freeze

# THE RESULT RECORD, decision 0009 item 1. `SOURCE_PORT_RECORD=PATH` writes one
# JSON document there as the process ends, whatever ends it. Its keys are filled
# in beside the report lines at the end of this file, from the values those lines
# print; where a line builds its text from a list, the list is shared with the
# record, so a key and its line cannot disagree. THE TEXT OUTPUT IS UNCHANGED,
# AND SO IS THE EXIT STATUS: the write cannot fail the run, because a run that
# was fine except for where its record went is not a failed run.
#
# `outcome` says how the process ended, which is what tells a killed run from a
# wrong one: `completed` (the whole report was printed, whatever the exit status
# after it), `refused` (one of this file's own aborts, before the report began),
# `aborted-mid-report` (an abort after the first report line: the keys are a
# partial map, not a result), `signal:NAME`, or `exception`.
#
# THE PATH IS EMPTIED FIRST. A killed run must leave no document, so that the
# reader sees an absent record and calls it an error; if an earlier run's
# document were left in place, a killed rerun would be read as that run's
# result. `pid` and `started` identify the run that wrote what is there.
#
# It is registered before this file's own argument checks, so a refused run is
# recorded too; `mode`, `control` and `requested_tics` are then whatever had
# been parsed, and `argv` always says what was actually asked for.
RECORD = ENV["SOURCE_PORT_RECORD"].to_s.empty? ? nil : ENV["SOURCE_PORT_RECORD"]
$rec = {}
$rec_started = false
$rec_reported = false
# One evaluation, two consumers: the report line prints the value and `rec`
# stores it. A key written twice is a defect in this file, not a result -- and
# only a defect of the record, so it cannot end a run that is not recording.
def rec(pairs)
  return unless RECORD
  pairs.each do |k, v|
    $rec.key?(k) and abort("source-port.rb: duplicate record key #{k}")
    $rec[k] = v
  end
end
if RECORD
  require "json"
  rec_argv = ARGV.dup
  rec_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  rec_wall_start = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  rec_signal_name = ->(e) { e.signm.to_s.empty? ? (e.is_a?(Interrupt) ? "SIGINT" : e.class.name) : e.signm }
  File.delete(RECORD) if File.exist?(RECORD)
  at_exit do
    # `$!` is the exception in flight, which need not be this run's ending: a
    # later-registered at_exit -- the library copy's cleanup -- runs first, and
    # anything it raises would be seen here. A finished report settles it.
    ending = $!
    outcome = if $rec_reported && !ending.is_a?(SignalException)
                "completed"
              else
                case ending
                when nil then "completed"
                when SystemExit then $rec_started ? "aborted-mid-report" : "refused"
                # Interrupt, what Ctrl-C raises, is a SignalException whose
                # `signm` and message are both empty.
                when SignalException then "signal:#{rec_signal_name[ending]}"
                else "exception"
                end
              end
    # Peak resident size is exact where /proc has it and an end-of-run sample
    # otherwise; the record says which, so the number is never read as more than
    # it is. Nothing here may raise: this runs while the process is leaving.
    rss, rss_from = begin
      hwm = File.exist?("/proc/self/status") && File.readlines("/proc/self/status").grep(/\AVmHWM:/).first
      if hwm
        [Integer(hwm[/\d+/], 10), "proc-vmhwm"]
      else
        sampled = `ps -o rss= -p #{$$}`[/\d+/]
        sampled ? [Integer(sampled, 10), "ps-at-exit"] : [nil, "unavailable"]
      end
    rescue StandardError
      [nil, "unavailable"]
    end
    # An empty value is not a selected route: `SOURCE_PORT_NATIVE=` is what an
    # unset shell variable expands to, and the run itself treats it as unset.
    set = ->(name) { !ENV[name].to_s.empty? }
    doc = {
      "record" => 1,
      # `requested_tics` is the parsed count, and is absent on a run refused
      # before it was parsed; `argv` always holds what was actually asked for.
      # Neither is the count the run reached: that is `run.frames` / `run.tics`.
      "argv" => rec_argv, "mode" => mode, "control" => control,
      "requested_tics" => (tics if tics.is_a?(Integer)),
      "route" => if set["SOURCE_PORT_ADAPTER"] then "adapter"
                 elsif set["SOURCE_PORT_SESSION"] then "session"
                 elsif set["SOURCE_PORT_NATIVE"] then "compiled"
                 else "ruby"
                 end,
      "outcome" => outcome,
      "keys" => $rec,
      "time" => { "wall_s" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - rec_started_at).round(3),
                  "peak_rss_kb" => rss, "rss_source" => rss_from },
      "env" => { "ruby" => RUBY_VERSION, "json" => JSON::VERSION, "platform" => RUBY_PLATFORM },
      "pid" => $$, "started" => rec_wall_start
    }
    # The status the process leaves with, where this file knows it: a signalled
    # run has none, and its `outcome` is what says so.
    doc["rc"] = case ending
                when nil then 0
                when SystemExit then ending.status
                when SignalException then nil
                else 1 # what Ruby itself exits with for an uncaught exception
                end
    # A field this run cannot answer for is left out, never written as null.
    doc.delete("rc") if doc["rc"].nil?
    doc.delete("requested_tics") if doc["requested_tics"].nil?
    if ending && outcome != "completed"
      # An abort or a signal is its own message; anything else needs its class,
      # or a NoMethodError and a full disk read the same from the record.
      doc["ended"] = case ending
                     when SystemExit then ending.message
                     when SignalException then rec_signal_name[ending]
                     else "#{ending.class}: #{ending.message}"
                     end
    end
    begin
      File.write(RECORD, JSON.pretty_generate(doc) + "\n")
    rescue StandardError => e
      warn "source-port.rb: the result record could not be written to #{RECORD}: #{e.class}: #{e.message}"
    end
  end
end

(iwad && File.exist?(iwad) && %w[direct queued frame].include?(mode)) or
  abort("usage: source-port.rb IWAD direct|queued|frame [TICS] [#{CONTROLS.join('|')}]")
tics = Integer(tics || "60", 10)
control ||= "none"

# The cells the lane loads from the original's objects, which the unported
# render_player_view and extralight= set, before the port's clear_planes; the
# cells the port's plane entries write; and the arrays the lane loads -- the
# visplanes the unported BSP walk builds, and Textures#animate's flattranslation.
LOADED_CELLS = [["i_viewz", :@viewz], ["i_extralight", :@extralight], ["i_viewangle", :@viewangle],
                ["i_viewx", :@viewx], ["i_viewy", :@viewy]].freeze
PLANE_OUT = [["draw-plane", "i_curpicnum", :@curpicnum], ["draw-plane", "i_planeheight", :@planeheight],
             ["draw-plane", "i_planezlight", :@planezlight]].freeze
CLEAR_OUT = [["i_lastvisplane", :@lastvisplane], ["i_lastopening", :@lastopening], ["i_floorplane", :@floorplane],
             ["i_ceilingplane", :@ceilingplane], ["i_basexscale", :@basexscale], ["i_baseyscale", :@baseyscale]].freeze
PL_ONE = %w[pl_minx pl_maxx pl_picnum pl_height pl_lightlevel].freeze
# The column cells draw_sky_plane sets.
DC_CELLS = [["i_dc_x", :@dc_x], ["i_dc_yl", :@dc_yl], ["i_dc_yh", :@dc_yh], ["i_dc_iscale", :@dc_iscale],
            ["i_dc_texturemid", :@dc_texturemid], ["i_dc_colormap", :@dc_colormap], ["i_dc_srcofs", :@dc_srcofs],
            ["i_dc_srcbase", :@dc_srcbase]].freeze
LANE_LOADED_FIELDS = %w[textures_flattranslation renderer_pl_minx renderer_pl_maxx renderer_pl_picnum renderer_pl_height
                        renderer_pl_lightlevel renderer_pl_bottom].freeze
# THE BOUNDARY COPY'S LIST (see boundary_copy below), read here because the
# session's read-only check needs it: a buffer the copy writes every frame is
# not read-only, whatever its render entry's contract says. The second column is
# the first frame of DEMO1 at which leaving that buffer out must show -- written
# down beside the buffer, so a poison that shows late, or at another frame, fails.
COPY_ROWS = File.readlines(File.join(ROOT, "tests/doom-core/fixtures/source/copy.tsv"))
                .reject { |l| l.start_with?("#") || l.strip.empty? }
                .map { |l| n, f = l.chomp.split("\t"); [n, Integer(f, 10)] }.freeze
COPY_BUFFERS = COPY_ROWS.map(&:first).freeze
# The renderer leaves' contexts (fields.tsv), and the buffer the lane loads a
# cell of before each clip_value call -- the unported wall walk writes it.
LEAF_CONTEXTS = %w[leaf-point-to-angle leaf-point-to-dist leaf-scale-from-global-angle leaf-light-index
                   leaf-clip-value leaf-point-on-seg-side leaf-find-plane leaf-check-plane
                   leaf-clear-clip-segs leaf-crunch leaf-check-bbox
                   leaf-sort-vissprites leaf-add-sprites seg-loop].freeze
# renderer_jobmode: Full prepares it with the renderer in job mode 0 (the source
# selector's conversion requires that), and the lane runs mode 2, so the seg
# loop is handed the mode the renderer actually runs.
LEAF_LOADED_FIELDS = %w[renderer_openings renderer_vs_scale renderer_jobmode].freeze
# THE WALLS' SEG LOOP'S CELLS (fields.tsv, context seg-loop): every value its
# unported caller, store_wall_range, set, and the column cells it writes, as
# [parameter, the original's ivar]. The plane marks are booleans there and 0/1
# here. The selector and base are not loaded: see seg_loop_agree.
SEG_CELLS = %w[rw_x rw_stopx topfrac bottomfrac topstep bottomstep pixhigh pixlow pixhighstep pixlowstep rw_scale
               rw_scalestep markceiling markfloor ceilingplane floorplane segtextured rw_centerangle rw_distance
               rw_offset walllights midtexture toptexture bottomtexture maskedtexture rw_midtexturemid
               rw_toptexturemid rw_bottomtexturemid maskedtexturecol dc_x dc_yl dc_yh dc_iscale dc_texturemid
               dc_colormap dc_srcofs].map { |n| ["i_#{n}", :"@#{n}"] }.freeze
# what the loop writes, compared after it
SEG_OUT = %w[i_rw_x i_topfrac i_bottomfrac i_pixhigh i_pixlow i_rw_scale i_dc_x i_dc_yl i_dc_yh i_dc_iscale
             i_dc_texturemid i_dc_colormap i_dc_srcofs].freeze
SEG_BUFS = %w[ceilingclip floorclip pl_top pl_bottom openings xtoviewangle finetangent finesine scalelight resscale
              tex_widthmask tex_atlas_base plw viewheight jobmode scr cmap atlas wad zonewin centery sw viewwindowx
              viewwindowy wall sc_kind sc_idx cap_wall cap_sched].freeze
# A sentinel no producer writes, loaded into the selector and base before the port's loop.
SEG_UNSET = -7
# THE COPY'S POISON for the things: a value no live thing holds where the
# projection reads it, so a copy that does not happen shows. Each is chosen
# against what the projection does with it, and screens.sh shows each skipped
# copy failing at the frame copy.tsv names.
MOBJ_POISON = { "x" => 0x3fff0000, "y" => 0x3fff0000, "z" => 0x3fff0000, "angle" => 0x5a5a5a5a,
                "frame" => 0x7fff, "sprite" => 0, "flags" => 0 }.freeze
# THE FURNITURE -- the status bar and the HUD -- is drawn on every route in
# frame mode unless SOURCE_PORT_FURNITURE=0; see the block that sets it up. Only
# in frame mode: that is where the whole screen is compared at the end of each
# frame. direct and queued compare each column or job as it is drawn, so
# furniture drawn there would be drawn and never checked.
$furniture = mode == "frame" && ENV["SOURCE_PORT_FURNITURE"] != "0"
$control = control
CONTROLS.include?(control) or abort("source-port.rb: unknown control #{control}")
(%w[queued-wrong-store zone-separate-ring reset-drop-nzone].include?(control) && mode == "direct") and
  abort("source-port.rb: #{control} changes the queued ring; it has nothing to change in #{mode}")
# push-kind's span records hold wall fields, which name rows past the screen: the
# compiled span check and executor refuse them (BOUNDS); a Ruby Array would answer nil.
(control == "push-kind" && !ENV["SOURCE_PORT_NATIVE"]) and
  abort("source-port.rb: push-kind needs the compiled entries: the records it makes are outside the screen, which only a compiled entry refuses")
# the wrong store is handed to the per-job masked consumer, which frame mode does not run
(control == "queued-wrong-store" && mode == "frame") and
  abort("source-port.rb: #{control} changes the per-job masked consumer; it has nothing to change in #{mode}")
(control.start_with?("frame-", "push-", "check-", "plane-", "clear-") && mode != "frame") and
  abort("source-port.rb: #{control} changes the port's frame-mode pushes, checks or run; it has nothing to change in #{mode}")

LIBDIR = Dir.mktmpdir("source-port")
at_exit { FileUtils.rm_rf(LIBDIR) }
FileUtils.cp_r(File.join(ROOT, "examples/doom/lib/doom/."), LIBDIR)
render = File.join(LIBDIR, "render.rb")
src = File.read(render)
producers = 0
markers = 0
insert = lambda do |label, anchor, line, site: nil, before: false|
  a = "\n#{anchor}\n"
  src.scan(a).length == 1 or abort("source-port.rb: anchor for #{label} is not unique: #{anchor.strip}")
  lines = []
  if site
    lines << "$src_site = #{site.dump}"
    markers += 1
  end
  unless control == label
    lines << line
    producers += 1
  end
  indent = anchor[/\A */]
  add = lines.map { |l| "#{indent}#{l}\n" }.join
  src = src.sub(a) { before ? "\n#{add}#{anchor}\n" : "\n#{anchor}\n#{add}" }
end
insert.call("init-ds", '      @ds_source = ""', 'dc_src_none(ps, ix("produce-span", "i_res"), ix("produce-span", "i_base"))')
insert.call("init-dc", '      @dc_srcbuf = ""', 'dc_src_none(ps, ix("produce-column", "i_res"), ix("produce-column", "i_base"))')
insert.call("no-sky", "          @dc_srcofs = c",
            "dc_src_texture_column(ps, ix(\"produce-column\", \"i_res\"), ix(\"produce-column\", \"i_base\"), @textures.atlas_base(tex), @textures.widthmask(tex), angle)",
            site: "sky")
insert.call("no-wall", "      @dc_srcofs = c",
            "dc_src_texture_column(ps, ix(\"produce-column\", \"i_res\"), ix(\"produce-column\", \"i_base\"), @textures.atlas_base(tex), @textures.widthmask(tex), col)",
            site: "wall")
# ONE producer line per masked column, after the branch and before the draw,
# in both job modes: it decides the branch itself from `p + 3` and `lend`, and
# takes the ring slot `zb` only when the queued branch just took one.
insert.call("skip-masked", "          @dc_texturemid = (((basetexturemid - (td << 16)) & M32) ^ SGN) - SGN",
            "$src_rem = lend - (p + 3); dc_src_masked_post(ps, ix(\"produce-column\", \"i_res\"), ix(\"produce-column\", \"i_base\"), p + 3, lend, @jobmode != 0 ? 1 : 0, @jobmode != 0 && p + 3 + 128 > lend ? zb : 0)",
            site: "masked", before: true)
insert.call("no-span", "        @ds_source = @textures.flatdata(@pl_picnum[pl])",
            "dc_src_span(ps, ix(\"produce-span\", \"i_res\"), ix(\"produce-span\", \"i_base\"), @textures.flat_atlas_base(@pl_picnum[pl]))")
# THE ZONE WINDOW PRODUCERS, examples/doom/core/src/zone.rb, after the original's
# own: the port writes its window into ITS store -- the direct window, or the
# ring at the slot it allocates itself -- and the consumers read the port's
# stores, not the original's.
insert.call("no-zone", "            @wad.zone_window_into(lnum, p + 3 - lpos, @jobs.zonebuf, zb)",
            "$zone_port.call(1, lnum, p + 3 - lpos, zb)")
insert.call("no-zone", "            @wad.zone_window(lnum, p + 3 - lpos, @zonewin)",
            "$zone_port.call(0, lnum, p + 3 - lpos, 0)")
File.write(render, src)

NATIVE = ENV["SOURCE_PORT_NATIVE"]
if NATIVE
  # THE COMPILED ENTRIES, called instead of the Ruby definitions. The library is
  # the kernel tool's objects for tests/doom-core/fixtures/source/*.contract
  # linked as they are; the test defines the port's own names over them, so the
  # producer lines in the copy and the hooks below do not change. Every buffer
  # is native storage of exactly its content's length, and every count passed
  # is that length.
  require "fiddle"
  File.exist?(NATIVE) or abort("source-port.rb: no library at #{NATIVE}")
  RES_NONE = -1
  RES_ATLAS = 0
  RES_WAD = 1
  RES_ZONE = 2
  RES_FLAT = 3
  class NativeBuf
    attr_reader :ptr, :count
    def initialize(count, width)
      @count = count
      @width = width
      @ptr = count.zero? ? Fiddle::Pointer.new(0) : Fiddle::Pointer.malloc(count * width, Fiddle::RUBY_FREE)
      @ptr[0, count * width] = "\0" * (count * width) unless count.zero?
    end
    def bytes = @count.zero? ? "".b : @ptr[0, @count * @width]
    def length = @count
    def [](i)
      (0...@count).cover?(i) or raise IndexError, "native buffer index #{i} outside 0...#{@count}"
      @width == 1 ? @ptr[i, 1].unpack1("C") : @ptr[i * 8, 8].unpack1("q<")
    end
    def []=(i, v)
      (0...@count).cover?(i) or raise IndexError, "native buffer index #{i} outside 0...#{@count}"
      @ptr[i * @width, @width] = @width == 1 ? [v].pack("C") : [v].pack("q<")
    end
    def load(str)
      str.bytesize == @count * @width or raise ArgumentError, "native buffer holds #{@count * @width} bytes, given #{str.bytesize}"
      @ptr[0, str.bytesize] = str unless str.empty?
      self
    end
  end
  LIB = Fiddle.dlopen(NATIVE)
  I = Fiddle::TYPE_LONG_LONG
  P = Fiddle::TYPE_VOIDP
  B = [P, I].freeze
  SIGS = {
    col: B * 6 + [I] * 12, span: B * 4 + [I] * 13, mjob: B * 4 + [I] * 12,
    none: B + [I] * 2, tex: B + [I] * 5, mask: B + [I] * 6, flat: B + [I] * 3,
    zone: B * 5 + [I] * 3, zalloc: B * 2 + [I], jreset: B * 2 + [I], exec: B * 17 + [I],
    pwall: B * 6 + [I] * 9, pspan: B * 6 + [I] * 9, pmask: B * 6 + [I] * 11, ph1: B + [I] * 2, ph3: B + [I] * 2,
    cdis: B * 6 + [I] * 4, cspan: B * 6 + [I] * 3, cmask: B * 8 + [I] * 4, call: B * 6 + [I] * 3,
    dplanes: B * 34 + [I] * 23, cplanes: B * 9 + [I] * 7,
    # The status bar: one entry, because an entry's closure must be disjoint
    # from every other entry's and the bar's parts share dc_i16 and
    # dc_draw_patch. Twenty-one buffers, five cells and three arguments.
    sbdraw: B * 21 + [I] * 8,
    # The HUD's message line: its own entry, disjoint from the bar's.
    hudraw: B * 9 + [I] * 2,
    # The renderer's leaves (src/leaves.rb), one entry per operation.
    pangle: B * 2 + [I] * 4,
    pdist: B * 3 + [I] * 4,
    sgscale: B * 3 + [I] * 4,
    lindex: B * 1 + [I] * 1,
    absang: [I] * 1,
    clipv: B * 2 + [I] * 3,
    segside: B * 4 + [I] * 3,
    fplane: B * 11 + [I] * 4,
    chplane: B * 9 + [I] * 4,
    ssclear: B * 4 + [I] * 1,
    crunch: B * 3 + [I] * 3,
    chkbbox: B * 8 + [I] * 5,
    vssort: B * 4 + [I] * 1,
    addspr: B * 39 + [I] * 10,
    segloop: B * 30 + [I] * 40
  }.freeze
  FNS = SIGS.to_h { |e, sig| [e, Fiddle::Function.new(LIB["spinel_core_dc_sp_#{e}"], sig + [P], Fiddle::TYPE_INT)] }
  $nresult = NativeBuf.new(1, 8)
  $ncache = {}
  $empty = NativeBuf.new(0, 1)
  def native(entry, *args)
    $count["native:#{entry}"] += 1
    status = FNS.fetch(entry).call(*args, $nresult.ptr)
    if status != 0
      fault("native-status", "#{entry} status #{status}#{{ 1 => ' ARGUMENT', 2 => ' ARITHMETIC', 3 => ' BOUNDS', 4 => ' CAPACITY' }[status]} #{$src_site} tic #{$tic} frame #{$frame}")
      return -2
    end
    $nresult[0]
  end
  # A buffer holding a copy of `str`; the same storage for the same key.
  def port_bytes(str, key = nil)
    buf = key ? ($ncache[key] ||= NativeBuf.new(str.bytesize, 1)) : NativeBuf.new(str.bytesize, 1)
    buf.load(str)
  end
  def port_screen(n) = NativeBuf.new(n, 1)
  def dc_src_none(state, i_res, i_base) = native(:none, state.ptr, state.count, i_res, i_base)
  def dc_src_texture_column(state, *scalars) = native(:tex, state.ptr, state.count, *scalars)
  def dc_src_masked_post(state, *scalars) = native(:mask, state.ptr, state.count, *scalars)
  def dc_src_span(state, *scalars) = native(:flat, state.ptr, state.count, *scalars)
  def dc_draw_column(scr, n_scr, cmap, n_cmap, atlas, n_atlas, wad, n_wad, zonewin, n_zonewin, state, *scalars)
    native(:col, scr.ptr, n_scr, cmap.ptr, n_cmap, atlas.ptr, n_atlas, wad.ptr, n_wad, zonewin.ptr, n_zonewin,
           state.ptr, state.count, *scalars)
  end
  def dc_draw_span(scr, n_scr, cmap, n_cmap, flat, n_flat, state, *scalars)
    native(:span, scr.ptr, n_scr, cmap.ptr, n_cmap, flat.ptr, n_flat, state.ptr, state.count, *scalars)
  end
  # The status bar and the HUD, under the names the Ruby route defines, so the
  # call site does not know which route it is on.
  def dc_draw_statusbar(*a) = native_push(:sbdraw, a[0, 21], a[21..])
  def dc_draw_hud(*a) = native_push(:hudraw, a[0, 9], a[9..])
  # The renderer's leaves, under their Ruby names.
  def dc_render_seg_loop(*a) = native_push(:segloop, a[0, 30], a[30..])
  def dc_add_sprites(*a) = native_push(:addspr, a[0, 39], a[39..])
  def dc_sort_vissprites(*a) = native_push(:vssort, a[0, 4], a[4..])
  def dc_check_bbox(*a) = native_push(:chkbbox, a[0, 8], a[8..])
  def dc_point_to_angle(*a) = native_push(:pangle, a[0, 2], a[2..])
  def dc_point_to_dist(*a) = native_push(:pdist, a[0, 3], a[3..])
  def dc_scale_from_global_angle(*a) = native_push(:sgscale, a[0, 3], a[3..])
  def dc_light_index(*a) = native_push(:lindex, a[0, 1], a[1..])
  def dc_abs_angle(*a) = native(:absang, *a)
  def dc_clip_value(*a) = native_push(:clipv, a[0, 2], a[2..])
  def dc_point_on_seg_side(*a) = native_push(:segside, a[0, 4], a[4..])
  def dc_find_plane(*a) = native_push(:fplane, a[0, 11], a[11..])
  def dc_check_plane(*a) = native_push(:chplane, a[0, 9], a[9..])
  def dc_clear_clip_segs(*a) = native_push(:ssclear, a[0, 4], a[4..])
  def dc_crunch(*a) = native_push(:crunch, a[0, 3], a[3..])
  def dc_draw_masked_job(scr, n_scr, cmap, n_cmap, wad, n_wad, zonebuf, n_zonebuf, *scalars)
    native(:mjob, scr.ptr, n_scr, cmap.ptr, n_cmap, wad.ptr, n_wad, zonebuf.ptr, n_zonebuf, *scalars)
  end
  def dc_zone_window_into(wad, lump_pos, lump_size, next_lump, out, lumpnum, off, base)
    native(:zone, wad.ptr, wad.count, lump_pos.ptr, lump_pos.count, lump_size.ptr, lump_size.count,
           next_lump.ptr, next_lump.count, out.ptr, out.count, lumpnum, off, base)
  end
  def dc_alloc_zone_window(state, i_nzone, zone_slots) = native(:zalloc, state.ptr, state.count, zone_slots.ptr, zone_slots.count, i_nzone)
  def dc_jobs_reset(state, zero_slots, n_zero_slots, i_fuzz_suffix)
    native(:jreset, state.ptr, state.count, zero_slots.ptr, n_zero_slots, i_fuzz_suffix)
  end
  def native_push(entry, bufs, scalars) = native(entry, *bufs.flat_map { |b| [b.ptr, b.count] }, *scalars)
  def dc_push_wall(state, wall, sc_kind, sc_idx, cap, cap_sched, *scalars)
    native_push(:pwall, [state, wall, sc_kind, sc_idx, cap, cap_sched], scalars)
  end
  def dc_push_span(state, span, sc_kind, sc_idx, cap, cap_sched, *scalars)
    native_push(:pspan, [state, span, sc_kind, sc_idx, cap, cap_sched], scalars)
  end
  def dc_push_masked(state, masked, sc_kind, sc_idx, cap, cap_sched, *scalars)
    native_push(:pmask, [state, masked, sc_kind, sc_idx, cap, cap_sched], scalars)
  end
  def dc_check_disjoint(*a) = native_push(:cdis, a[0, 6], a[6..])
  def dc_check_span_disjoint(*a) = native_push(:cspan, a[0, 6], a[6..])
  def dc_check_masked_k(*a) = native_push(:cmask, a[0, 8], a[8..])
  def dc_check_wall_all(*a) = native_push(:call, a[0, 6], a[6..])
  def dc_draw_planes(*a) = native_push(:dplanes, a[0, 34] + a[57, 11], a[34, 22] + [a[68], a[56]])
  def dc_clear_planes(*a) = native_push(:cplanes, a[0, 9], a[9..])
  def dc_mark_phase1(state, *scalars) = native(:ph1, state.ptr, state.count, *scalars)
  def dc_mark_phase3(state, *scalars) = native(:ph3, state.ptr, state.count, *scalars)
  def port_i64s(values) = NativeBuf.new(values.length, 8).load(values.pack("q<*"))
else
  require File.join(ROOT, "examples/doom/core/src/source")
  require File.join(ROOT, "examples/doom/core/src/zone")
  require File.join(ROOT, "examples/doom/core/src/executor")
  require File.join(ROOT, "examples/doom/core/src/jobs")
  require File.join(ROOT, "examples/doom/core/src/checks")
  require File.join(ROOT, "examples/doom/core/src/fixed")
  require File.join(ROOT, "examples/doom/core/src/planespan")
  require File.join(ROOT, "examples/doom/core/src/planes")
  require File.join(ROOT, "examples/doom/core/src/statusbar")
  require File.join(ROOT, "examples/doom/core/src/hud")
  require(ENV["SOURCE_PORT_LEAVES"].to_s.empty? ? File.join(ROOT, "examples/doom/core/src/leaves") : File.expand_path(ENV["SOURCE_PORT_LEAVES"]))
  require(ENV["SOURCE_PORT_SEGS"].to_s.empty? ? File.join(ROOT, "examples/doom/core/src/segs") : File.expand_path(ENV["SOURCE_PORT_SEGS"]))
  # `core_fail(:capacity)` is the CORE boundary's; in CRuby it is a raise the
  # zone producer's caller reports.
  class CoreCapacity < StandardError; end
  def core_fail(category) = raise(CoreCapacity, category.to_s)
  def port_i64s(values) = values.dup
  $empty = [].freeze
  def port_bytes(str, _key = nil) = str.bytes
  def port_screen(n) = Array.new(n, 0)
end

# SOURCE_PORT_ADAPTER=LIB: the same names over the 0007 adapter registry
# (tests/doom-core/source-adapter.rb) -- every field registry storage, every
# call an `invoke` over ids. It needs the compiled entries and a session.
ADAPTER = ENV["SOURCE_PORT_ADAPTER"]
if ADAPTER
  NATIVE && ENV["SOURCE_PORT_SESSION"] or abort("source-port.rb: SOURCE_PORT_ADAPTER needs SOURCE_PORT_NATIVE and SOURCE_PORT_SESSION")
  begin
    verbose = $VERBOSE
    $VERBOSE = nil
    require File.join(ROOT, "tests/doom-core/source-adapter")
  ensure
    $VERBOSE = verbose
  end
  AdapterRoute.open(ADAPTER)
end
# The storage one resident field is given: native memory, or registry storage.
def field_buf(count, element) = ADAPTER ? AdapterRoute::IdBuf.new(count, element) : NativeBuf.new(count, element == "u8" ? 1 : 8)

# WHICH STORAGE EACH CONSUMER PARAMETER IS. Without a session these are the
# test's own copies of the game's resources. With SOURCE_PORT_SESSION they are
# the resident fields of a Doom::Core::Session opened over the generated layout
# in that directory, as tests/doom-core/fixtures/source/fields.tsv (or
# SOURCE_PORT_FIELDS) names them.
SESSION = ENV["SOURCE_PORT_SESSION"]
FIELDS = ENV["SOURCE_PORT_FIELDS"] || File.join(ROOT, "tests/doom-core/fixtures/source/fields.tsv")
SESSION && !NATIVE and abort("source-port.rb: SOURCE_PORT_SESSION needs SOURCE_PORT_NATIVE")
$res = nil
def res(context, param)
  return $res.fetch([context, param]) { abort("source-port.rb: #{FIELDS} names nothing for #{context} #{param}") } if $res
  case param
  when "scr" then $port_scr
  when "cmap" then $cmap
  when "atlas" then $atlas
  when "flat" then $flat
  when "wad" then context == "queued-wall" ? $empty : $wad
  when "zonewin" then context == "queued-wall" ? $empty : $port_zonewin
  when "zonebuf" then $port_ring
  when "out" then context == "produce-zone-queued" ? $port_ring : $port_zonewin
  when "lump_pos" then $lump_pos
  when "lump_size" then $lump_size
  when "next_lump" then $next_lump
  when "zone_slots" then $zone_slots
  when "cap_wall" then $cap_wall
  when "cap_span" then $cap_span
  when "cap_masked" then $cap_masked
  when "cap_sched" then $cap_sched
  when "width" then context.start_with?("check-") ? $jobs_width : $exec_width
  when "height" then $jobs_height
  when "spanstart", "cachedheight", "cacheddistance", "cachedxstep", "cachedystep", "yslope", "distscale",
       "xtoviewangle", "finesine", "zlight", "flattranslation", "pl_minx", "pl_maxx", "pl_picnum", "pl_height",
       "pl_lightlevel", "pl_top", "pl_bottom", "plw", "plempty", "skyflatnum", "floorclip", "ceilingclip",
       "centerxfrac", "viewwidth", "viewheight", "sh", "tex_widthmask", "tex_atlas_base", "skytexture", "pspriteiscale",
       "skytexturemid" then $plane_tables.fetch(param)
  when "xcount", "xyl", "xyh", "ycount", "yx1", "yx2", "mcount", "mlo", "mhi", "mseq", "mfz" then $check_tables.fetch(param)
  when "fuzzoffset" then $fuzzoffset
  when "wall" then $wall_bank
  when "span" then $span_bank
  when "masked" then $masked_bank
  when "sc_kind" then $sc_kind
  when "sc_idx" then $sc_idx
  when "centery" then context == "seg-loop" ? $seg_tables.fetch(param) : $exec_centery
  when "finetangent", "jobmode", "viewwindowx", "viewwindowy" then $seg_tables.fetch(param)
  when "vwx" then $exec_vwx
  when "vwy" then $exec_vwy
  when "screen" then $port_scr
  when "backing" then $port_backing
  when "tantoangle", "openings", "ss_first", "ss_last", "projection", "resscale", "sw", "clipangle", "two_clipangle",
       "viewangletox", "node_bbox", "vs_scale", "vs_taken", "vs_sorted", "vs_mobjflags", "vs_gx", "vs_gy",
       "vs_gz", "vs_gzt", "vs_texturemid", "vs_x1", "vs_x2", "vs_startfrac", "vs_xiscale", "vs_patch", "vs_cmap",
       "scalelight", "numframes", "rotate", "framebase", "sprlump", "sprflip", "spriteoffset", "spritewidth",
       "spritetopoffset", "mobj_x", "mobj_y", "mobj_z", "mobj_angle", "mobj_frame", "mobj_sprite", "mobj_flags", "thing_next", "sector_head", "sector_lightlevel", "sector_validcount",
       "vertex_x", "vertex_y", "seg_v1", "seg_v2" then $leaf_tables.fetch(param)
  when "old_arms", "old_keybox", "keyboxes", "tallnum", "shortnum", "armsgray", "faces", "keys", "tallw", "shortw",
       "sbar", "tallpercent", "armsbg", "font_lump", "text", "text_ofs", "sw", "scale" then $furn_tables.fetch(param)
  else abort("source-port.rb: no storage for #{context} #{param}")
  end
end
%w[wad level texnames texture sprites statusbar hud render info random game jobs executor demo].each do |f|
  require File.join(LIBDIR, f)
end
# Resources requires original library files it reads (wad, texture, ...), which
# are the same bytes as the copy's. render.rb -- the only file changed -- must
# not be among them, or the original's producers would replace the copy's.
begin
  verbose = $VERBOSE
  $VERBOSE = nil
  require_relative File.join(ROOT, "examples/doom/core/full/resources")
ensure
  $VERBOSE = verbose
end
$LOADED_FEATURES.include?(File.join(ROOT, "examples/doom/lib/doom/render.rb")) and
  abort("source-port.rb: the original render.rb was loaded over the copy")

# THE SCALAR FIELDS ARE CELLS OF ONE STATE BUFFER. Every entry takes that buffer
# once and the index of each cell it touches, as fields.tsv names the cell for
# its context. Without a session the buffer is the lane's own, one cell per
# name in the order the names first appear; with one it is the session's
# core_state and the indices are the registry's slots. A job record's two cells
# (`job:`) are a two-cell buffer of their own.
#
# JOBS#RESET IS PORTED (src/zone.rb, dc_jobs_reset), and which cells it resets
# is read off the original: every integer field of a fresh Jobs is set to a
# value reset never writes, reset runs, and the fields it wrote are the table --
# those it set to 0, and the one it set to 1.
probe = Doom::Jobs.new(320, 200)
ints = probe.instance_variables.select { |v| probe.instance_variable_get(v).is_a?(Integer) }
ints.each { |v| probe.instance_variable_set(v, 7777) }
probe.reset
reset_to = ints.reject { |v| probe.instance_variable_get(v) == 7777 }
               .to_h { |v| ["jobs_#{v.to_s.delete_prefix('@')}", probe.instance_variable_get(v)] }
reset_to.values.all? { |v| [0, 1].include?(v) } or abort("source-port.rb: Jobs#reset writes #{reset_to.inspect}")
RESET_ZERO = reset_to.select { |_, v| v.zero? }.keys.sort.freeze
# reset-drop-nzone: the port's table leaves out the ring's counter, as a table
# written by hand could. The lane's own check below still uses every cell.
PORT_RESET_ZERO = (control == "reset-drop-nzone" ? RESET_ZERO - ["jobs_nzone"] : RESET_ZERO).freeze
RESET_ONE = reset_to.select { |_, v| v == 1 }.keys.sort.freeze
$fields_rows = File.readlines(FIELDS).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t", -1) }
$fields_rows.each { |r| [4, 5].include?(r.length) or abort("source-port.rb: #{FIELDS}: #{r.inspect}") }
# [context, param] -> the slot NAME an index parameter names.
$ix_name = {}
$fields_rows.each do |context, _entry, param, field, _use|
  next unless param.start_with?("i_")
  key = [context, param]
  $ix_name.key?(key) && $ix_name[key] != field and abort("source-port.rb: #{FIELDS} gives #{context} #{param} two cells")
  $ix_name[key] = field
end
$ix_name[["reset-jobs", "i_fuzz_suffix"]] == RESET_ONE.first && RESET_ONE.length == 1 or
  abort("source-port.rb: Jobs#reset sets #{RESET_ONE.inspect} to 1 and #{FIELDS} names #{$ix_name[%w[reset-jobs i_fuzz_suffix]].inspect}")
def index_layout(slot_of)
  $ix = $ix_name.to_h { |k, name| [k, name.start_with?("job:") ? (k[1] == "i_res" ? 0 : 1) : slot_of.call(name)] }
  $zero_slots = port_i64s(PORT_RESET_ZERO.map { |n| slot_of.call(n) })
  $reset_cells = (RESET_ZERO + RESET_ONE).to_h { |n| [n, slot_of.call(n)] }
end
def ix(context, param) = $ix.fetch([context, param]) { abort("source-port.rb: #{FIELDS} names no cell for #{context} #{param}") }
def ps = $pstate
plain_names = ($ix_name.values.grep_v(/\Ajob:/) + RESET_ZERO).uniq
index_layout(->(n) { plain_names.index(n) || abort("source-port.rb: no cell for #{n}") })
$pstate = port_i64s(Array.new(plain_names.length, 0))
$jobcells = port_i64s([0, 0])

$faults = Hash.new(0)
$first = {}
# The frame and tic the first fault of each kind was raised at, for the result
# record: taken here, not parsed back out of the printed text.
$first_at = {}
$count = Hash.new(0)
$site_first = {}
$src_site = "none"
$src_rem = nil
# The masked branch's boundary, as the game reached it: the fewest bytes left in
# the lump when the post was read in place, and the most when it was not.
$rem = {}
def note_site(tic_or_frame)
  $count["site:#{$src_site}"] += 1
  $site_first[$src_site] ||= tic_or_frame
end
def note_masked(sel)
  return unless $src_site == "masked" && $src_rem
  k = sel == RES_WAD ? "wad-min" : "zone-max"
  $rem[k] = [$rem[k], $src_rem].compact.send(sel == RES_WAD ? :min : :max)
end
def fault(kind, where)
  $faults[kind] += 1
  return if $first.key?(kind)
  $first[kind] = where
  $first_at[kind] = [$frame, $tic]
end
# With a session: the selector and base the entry just produced must be in the
# core_state slots core-representations.tsv names for them, at THIS call. An
# end-of-run look can agree anyway -- measured, a field map pointing the column
# base at another slot left both end checks agreeing in direct mode.
def slots_agree(which, values, where)
  return unless $session
  got = %w[res base].map { |p| $session[:core][$rep_slots.find { |_f, w, pp| w == which && pp == p }.last] }
  fault("slot-disagree", "#{where} slots #{got.join(' ')}") if got != values
end
def same_pixels(offs, scr, port = $port_scr)
  offs.all? { |o| port[o] == scr.getbyte(o) }
end

if mode == "direct"
  Doom::Renderer.prepend(Module.new do
    define_method(:draw_column) do
      next super() unless @jobmode == 0 && !@dc_fuzz && @dc_yh >= @dc_yl
      super()
      where = "#{$src_site} tic #{$tic} x #{@dc_x}"
      $count["columns"] += 1
      note_site("tic#{$tic}")
      sel = ps[ix("direct-column", "i_res")]
      note_masked(sel)
      conv = [Doom::Core::Resources::SourceSelect.new(self, "dc", "res").value,
              Doom::Core::Resources::SourceSelect.new(self, "dc", "base").value]
      fault("producer-disagree", where) if conv != [sel, ps[ix("direct-column", "i_base")]]
      slots_agree("dc", conv, where)
      offs = (0..(@dc_yh - @dc_yl)).map { |i| (@dc_yl + @viewwindowy + i) * @sw + @dc_x + @viewwindowx }
      zonewin = res("direct-column", "zonewin")
      scr, cm, at, wd = %w[scr cmap atlas wad].map { |p| res("direct-column", p) }
      rc = dc_draw_column(scr, scr.length, cm, cm.length, at, at.length,
                          wd, wd.length, zonewin, zonewin.length, ps, ix("direct-column", "i_res"), ix("direct-column", "i_base"),
                          @dc_x, @dc_yl, @dc_yh, @dc_iscale, @dc_texturemid, @dc_colormap,
                          @centery, @sw, @viewwindowx, @viewwindowy)
      if rc != 1
        fault("unreadable-selector", "#{where} selector #{sel}")
      elsif !same_pixels(offs, @screen, scr)
        fault("pixel-mismatch", where)
      end
    end
    define_method(:draw_span) do |y, x1, x2, xfrac, yfrac, xstep, ystep, cmap|
      super(y, x1, x2, xfrac, yfrac, xstep, ystep, cmap)
      next if @jobmode != 0
      where = "span tic #{$tic} y #{y}"
      $count["spans"] += 1
      conv = [Doom::Core::Resources::SourceSelect.new(self, "ds", "res").value,
              Doom::Core::Resources::SourceSelect.new(self, "ds", "base").value]
      cells = [ps[ix("direct-span", "i_res")], ps[ix("direct-span", "i_base")]]
      fault("producer-disagree", where) if conv != cells
      slots_agree("ds", conv, where)
      scr, cm, fl = %w[scr cmap flat].map { |p| res("direct-span", p) }
      rc = dc_draw_span(scr, scr.length, cm, cm.length, fl, fl.length,
                        ps, ix("direct-span", "i_res"), ix("direct-span", "i_base"), y, x1, x2, xfrac, yfrac, xstep, ystep, cmap,
                        @sw, @viewwindowx, @viewwindowy)
      offs = (0..(x2 - x1)).map { |i| (y + @viewwindowy) * @sw + x1 + i + @viewwindowx }
      if rc != 1
        fault("unreadable-selector", "#{where} selector #{cells[0]}")
      elsif !same_pixels(offs, @screen, scr)
        fault("pixel-mismatch", where)
      end
    end
  end)
else
  $wall_src = {}
  $span_src = {}
  $masked_src = {}
  $span_args = nil
  Doom::Renderer.prepend(Module.new do
    # The job holds the packed position and step; the port's span consumer takes
    # the four fractions, so they are kept from the call that pushes the job.
    define_method(:draw_span) do |y, x1, x2, xfrac, yfrac, xstep, ystep, cmap|
      $span_args = [xfrac, yfrac, xstep, ystep]
      super(y, x1, x2, xfrac, yfrac, xstep, ystep, cmap)
    end
    define_method(:clear_planes) do
      next super() unless $frame_mode
      # what clear_planes is about to overwrite: the port starts from the same
      w = @viewwidth
      pre = { counters: CLEAR_OUT.first(4).map { |_, ivar| instance_variable_get(ivar) },
              floorclip: @floorclip[0, w], ceilingclip: @ceilingclip[0, w] }
      super()
      port_clear_planes(self, pre)
    end
    # The original's loop runs unchanged; the port walks every plane after it.
    define_method(:draw_planes) do
      next super() unless $frame_mode
      port_planes_begin(self)
      $planes[:in_loop] = true
      super()
      $planes[:in_loop] = false
      port_planes_whole(self)
    end
    define_method(:draw_sky_plane) do |pl|
      next super(pl) unless $frame_mode
      jobs = @jobs
      rec = { sky: true, pl: pl, curpicnum: @curpicnum, nwall: jobs.nwall, nsched: jobs.nsched }
      $planes[:recs] << rec
      # This, and only this, is where the original pushes a wall job inside
      # draw_planes; the lane's push_wall leaves the sky's columns to the port's
      # own walk and compares them there.
      $planes[:in_sky] = true
      super(pl)
      $planes[:in_sky] = false
      rec[:nwall_end] = jobs.nwall
      rec[:dc] = DC_CELLS.map { |_, ivar| instance_variable_get(ivar) }
    end
  end)
  # Textures#animate's flattranslation used to be copied HERE, by a prepend onto
  # the original's own method, right after it wrote. That was the harness's
  # answer to a question the BOUNDARY COPY now answers properly: a prepend onto the
  # game is something the playable program cannot do, and a single hand-off
  # between the tick and the render is. The copy lives in boundary_copy below.
  Doom::Jobs.prepend(Module.new do
    define_method(:reset) do
      super()
      $frame = ($frame || -1) + 1
      # The port's Jobs#reset, on the port's cells, and every cell it resets
      # checked against the field the original's reset just wrote.
      dc_jobs_reset(ps, $zero_slots, $zero_slots.length, ix("reset-jobs", "i_fuzz_suffix"))
      $count["resets"] += 1
      $reset_cells.each do |name, cell|
        want = instance_variable_get("@#{name.delete_prefix('jobs_')}")
        next if ps[cell] == want
        fault("reset-disagree", "frame #{$frame} #{name} #{ps[cell]} original #{want}")
        break
      end
      $wall_src = {}
      $span_src = {}
      $masked_src = {}
    end
    define_method(:mark_phase1) do
      super()
      port_mark(1, self) if $frame_mode
    end
    # check_wall_all refills the x tables check_disjoint fills, so what
    # check_disjoint left is kept here, to be compared at the same point.
    define_method(:check_disjoint) do |lo, hi, strict|
      super(lo, hi, strict)
      $disjoint_left = [@xcount.dup, @xyl.dup, @xyh.dup] if $frame_mode
    end
    define_method(:mark_phase3) do
      super()
      port_mark(3, self) if $frame_mode
    end
    define_method(:push_wall) do |x, yl, yh, iscale, texmid, srcofs, cmap|
      i = @nwall
      super(x, yl, yh, iscale, texmid, srcofs, cmap)
      # THE GUARD COVERS THE SKY'S COLUMNS AND NOTHING ELSE. Inside
      # draw_sky_plane the port's own walk pushes the column, and compares it
      # after the walk, so the lane must not push it a second time. Every other
      # wall push is the lane's, walk or no walk -- and one that arrives inside
      # draw_planes from any site but draw_sky_plane is a push the port's walk
      # did not make and this lane does not model, so it is counted and failed
      # as a push-disagree rather than silently skipped. Its count is that
      # kind's fault count, and the first one is that kind's first failure.
      # Inside the walls' seg loop the lane's push still runs, so the push entry
      # stays checked at every push; the port's seg loop then pushes the same
      # records again over it (seg_prepare_call), and those are what is drawn.
      $count["segloop-original-pushes"] += 1 if $in_segloop
      if $frame_mode && !($planes && $planes[:in_sky])
        if $planes && $planes[:in_loop]
          fault("push-disagree", "frame #{$frame} wall push #{i} inside draw_planes at #{$src_site}, outside draw_sky_plane: unported")
        else
          port_push(:wall, self, [x, yl, yh, iscale, texmid, srcofs, cmap])
        end
      end
      port = [ps[ix("produce-column", "i_res")], ps[ix("produce-column", "i_base")]]
      $wall_src[i] = [port, $src_site, x, yl, yh, iscale, texmid, cmap]
      $count["wall-jobs"] += 1
      note_site("frame#{$frame}")
      fault("job-disagree", "#{$src_site} frame #{$frame} wall job #{i}") if port != [RES_ATLAS, srcofs]
      slots_agree("dc", [RES_ATLAS, srcofs], "#{$src_site} frame #{$frame} wall job #{i}")
    end
    define_method(:push_span) do |y, x1, x2, position, step, srcofs, cmap|
      i = @nspan
      super(y, x1, x2, position, step, srcofs, cmap)
      # in frame mode the port's spans are pushed by its own make_spans
      port = [ps[ix("produce-span", "i_res")], ps[ix("produce-span", "i_base")]]
      $span_src[i] = [port, y, x1, x2, $span_args, cmap]
      $count["span-jobs"] += 1
      fault("job-disagree", "span frame #{$frame} span job #{i}") if port != [RES_FLAT, srcofs]
      slots_agree("ds", [RES_FLAT, srcofs], "span frame #{$frame} span job #{i}")
    end
    define_method(:push_masked) do |x, yl, yh, iscale, texmid, srcres, srcofs, cmap, fuzz|
      i = @nmasked
      super(x, yl, yh, iscale, texmid, srcres, srcofs, cmap, fuzz)
      port_push(:masked, self, [x, yl, yh, iscale, texmid, srcres, srcofs, cmap, fuzz]) if $frame_mode
      next if fuzz >= 0
      port = [ps[ix("produce-column", "i_res")], ps[ix("produce-column", "i_base")]]
      $masked_src[i] = [port, $src_site, x, yl, yh, iscale, texmid, cmap]
      $count["masked-jobs"] += 1
      $count["zone-jobs"] += 1 if port[0] == RES_ZONE
      note_site("frame#{$frame}")
      note_masked(port[0])
      fault("job-disagree", "#{$src_site} frame #{$frame} masked job #{i}") if port != [srcres, srcofs]
      slots_agree("dc", [srcres, srcofs], "#{$src_site} frame #{$frame} masked job #{i}")
    end
  end)
  Doom::JobExecutor.prepend(Module.new do
    define_method(:run) do |jobs, strict, scr|
      $zonebuf = res("queued-masked", "zonebuf")
      super(jobs, strict, scr)
      port_frame(jobs, scr) if $frame_mode
    end
    define_method(:exec_wall) do |i, scr|
      super(i, scr)
      next if $frame_mode
      rec = $wall_src[i]
      next unless rec
      (sel, base), site, x, yl, yh, iscale, texmid, cmap = rec
      next if yh < yl
      where = "#{site} frame #{$frame} wall job #{i} x #{x}"
      # A wall job's context names the atlas and nothing else.
      if sel != RES_ATLAS
        fault("unreadable-selector", "#{where} selector #{sel}")
        next
      end
      $jobcells[0] = sel
      $jobcells[1] = base
      sc, cm, at, wd, zw = %w[scr cmap atlas wad zonewin].map { |p| res("queued-wall", p) }
      rc = dc_draw_column(sc, sc.length, cm, cm.length, at, at.length,
                          wd, wd.length, zw, zw.length, $jobcells, ix("queued-wall", "i_res"), ix("queued-wall", "i_base"),
                          x, yl, yh, iscale, texmid, cmap,
                          @centery, @width, @viewwindowx, @viewwindowy)
      offs = (0..(yh - yl)).map { |k| (yl + @viewwindowy + k) * @width + x + @viewwindowx }
      if rc != 1
        fault("unreadable-selector", "#{where} selector #{sel}")
      elsif !same_pixels(offs, scr, sc)
        fault("pixel-mismatch", where)
      end
    end
    define_method(:exec_span) do |i, scr|
      super(i, scr)
      next if $frame_mode
      rec = $span_src[i]
      next unless rec
      (sel, base), y, x1, x2, (xfrac, yfrac, xstep, ystep), cmap = rec
      next if x2 < x1
      where = "span frame #{$frame} span job #{i} y #{y}"
      $jobcells[0] = sel
      $jobcells[1] = base
      sc, cm, fl = %w[scr cmap flat].map { |p| res("queued-span", p) }
      rc = dc_draw_span(sc, sc.length, cm, cm.length, fl, fl.length,
                        $jobcells, ix("queued-span", "i_res"), ix("queued-span", "i_base"), y, x1, x2, xfrac, yfrac, xstep, ystep, cmap,
                        @width, @viewwindowx, @viewwindowy)
      offs = (0..(x2 - x1)).map { |k| (y + @viewwindowy) * @width + x1 + k + @viewwindowx }
      if rc != 1
        fault("unreadable-selector", "#{where} selector #{sel}")
      elsif !same_pixels(offs, scr, sc)
        fault("pixel-mismatch", where)
      end
    end
    define_method(:exec_masked) do |i, scr|
      super(i, scr)
      next if $frame_mode
      rec = $masked_src[i]
      next unless rec
      (sel, base), site, x, yl, yh, iscale, texmid, cmap = rec
      next if yh < yl
      sel = RES_WAD if control == "queued-wrong-store" && sel == RES_ZONE
      where = "#{site} frame #{$frame} masked job #{i} x #{x}"
      sc, cm, wd = %w[scr cmap wad].map { |p| res("queued-masked", p) }
      rc = dc_draw_masked_job(sc, sc.length, cm, cm.length, wd, wd.length,
                              $zonebuf, $zonebuf.length, sel, base, x, yl, yh, iscale, texmid, cmap,
                              @centery, @width, @viewwindowx, @viewwindowy)
      offs = (0..(yh - yl)).map { |k| (yl + @viewwindowy + k) * @width + x + @viewwindowx }
      if rc != 1
        fault("unreadable-selector", "#{where} selector #{sel}")
      elsif !same_pixels(offs, scr, sc)
        fault("pixel-mismatch", where)
      end
    end
  end)
end

wad = Doom::Wad.new(iwad)
# THE DEMO, by name: SOURCE_PORT_DEMO, DEMO1 when unset. Each is a different
# map (DEMO1 E1M5, DEMO2 E1M3, DEMO3 E1M7), so each reaches branches the others
# may not, and a session over it needs that map's layout.
DEMO_NAME = ENV["SOURCE_PORT_DEMO"].to_s.empty? ? "DEMO1" : ENV["SOURCE_PORT_DEMO"]
%w[DEMO1 DEMO2 DEMO3].include?(DEMO_NAME) or abort("source-port.rb: SOURCE_PORT_DEMO=#{DEMO_NAME} is not DEMO1, DEMO2 or DEMO3")
# copy.tsv's frames are where each skipped copy first shows IN DEMO1.
ENV["SOURCE_PORT_COPY_SKIP"].to_s.empty? || DEMO_NAME == "DEMO1" or
  abort("source-port.rb: SOURCE_PORT_COPY_SKIP is judged against DEMO1's frames in copy.tsv, and this run plays #{DEMO_NAME}")
demo = Doom::Demo.new(wad, DEMO_NAME, "")
lv = Doom::Level.new(wad, demo.mapname, demo.episode)
tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
rnd = Doom::Random.new
rnd.clear
g = Doom::Game.new(wad, lv, demo.skill, rnd, tx)
sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
r = Doom::Renderer.new(lv, wad, wad.bytes_by_name("COLORMAP"), tx, sp, g, 10, false, 1)
# THE RECORDED SCREENS, compared against the PORT's own screen per frame when
# SOURCE_PORT_GOLDEN names one. This is the check that survives the cutover: the
# live comparison below needs the original running beside the port, and the
# milestone removes it, so the port is also checked against what the original
# PRODUCED -- recorded by tests/doom-core/screens.sh while the original is still
# here. Having it green BEFORE the original goes means the cutover is a deletion
# rather than a new oracle stood up when nothing else is watching.
#
# THE VIEW IS COMPARED AND THE FULL SCREEN IS NOT, and the reason is a measured
# difference between the two routes rather than a preference. sim_demo.rb draws
# the status bar and the HUD into the screen before hashing it; THIS ROUTE NEVER
# DRAWS THEM -- it builds a StatusBar and a Hud for the session registry and
# leaves the rows below the view untouched. Measured on DEMO1's first 60 frames:
# every view digest agrees and every full digest differs. So the full column is
# recorded and is not this route's to check; it becomes checkable when the
# furniture is drawn, which the playable program does and the milestone will
# need.
#
# THE DIGEST IS THE SAME CODE ON THE SAME KIND OF INPUT. The golden is written by
# sim_demo.rb calling Doom::Bytes.fnv1a64_hex_range on the original's screen
# String; this calls the identical function on the port's screen, which
# port_screen_bytes has already materialised as a String for the live
# comparison. So a difference is in the screens and not in two hashers -- which
# would otherwise show as a divergence that is in neither the port nor the
# golden.
$golden_sw = r.screenwidth
$golden_vh = r.viewheight
$golden = nil
if (gp = ENV["SOURCE_PORT_GOLDEN"]).to_s != ""
  $golden = {}
  File.foreach(gp) do |ln|
    next if ln.start_with?("#")
    f = ln.chomp.split("\t")
    next if f.length < 3
    $golden[f[0].to_i] = [f[1], f[2]]
  end
  $golden.empty? and abort("source-port.rb: #{gp} holds no recorded frames")
end
pre = [%w[produce-column i_res], %w[produce-column i_base], %w[produce-span i_res], %w[produce-span i_base]]
      .map { |c, p| ps[ix(c, p)] }
# The original's own pre-tick choice, converted: what Task 5's snapshot holds.
# Read before the job mode is set -- the conversion names the direct CPU path.
pre_orig = [%w[dc res], %w[dc base], %w[ds res], %w[ds base]].map { |w, p| Doom::Core::Resources::SourceSelect.new(r, w, p).value }
if SESSION
  # THE RESIDENT LAYOUT. Full prepares every prepared field from the objects it
  # has just built -- the same Resources.prepared the state lane compares with
  # the original -- and opens a Session over the generated buffers.tsv and
  # slots.tsv, which checks every length. The consumers then read and write the
  # session's own fields, copied once into native storage of their declared
  # counts: core_state is ONE allocation, handed over once, and each cell an
  # entry touches is an index into it -- the registry's slot. The objects around
  # the game are built as
  # tests/doom-core/build-prepared.rb builds them, for the one tested script.
  require_relative File.join(ROOT, "examples/doom/core/full/session")
  # Unchanged files; Resources has already loaded the original input.rb, so
  # only the redefinition warnings are silenced.
  begin
    verbose = $VERBOSE
    $VERBOSE = nil
    %w[input record].each { |f| require File.join(LIBDIR, f) }
  ensure
    $VERBOSE = verbose
  end
  script = File.join(LIBDIR, "session-script.txt")
  File.write(script, "0 10 forward\n")
  statusbar = Doom::StatusBar.new(wad)
  statusbar.start(g.pl_weaponowned)
  objects = {
    "Doom::Wad" => wad, "Doom::Textures" => tx, "Doom::Level" => lv, "Doom::Random" => rnd, "Doom::Game" => g,
    "Doom::Sprites" => sp, "Doom::Renderer" => r, "Doom::StatusBar" => statusbar,
    "Doom::Hud" => Doom::Hud.new(wad, r.screenwidth, r.screenheight, 1),
    "Doom::KeyScript" => Doom::KeyScript.new(script), "Doom::KeyState" => Doom::KeyState.new,
    "Doom::TiccmdBuilder" => Doom::TiccmdBuilder.new, "Doom::DemoWriter" => Doom::DemoWriter.new(2, 1, 1, 40_000),
    "Doom::Jobs" => r.instance_variable_get(:@jobs), "Doom::JobExecutor" => r.instance_variable_get(:@exec)
  }
  made, unsupported, = Doom::Core::Resources.prepared(acquired: File.join(ROOT, "tools/doom/core-acquired.tsv"),
                                                      schema: File.join(ROOT, "examples/doom/core/state.tsv"),
                                                      objects: objects)
  unsupported.empty? or abort("source-port.rb: Full could not prepare #{unsupported.first(3).join(', ')}")
  buffers_tsv = File.join(SESSION, "buffers.tsv")
  slots_tsv = File.join(SESSION, "slots.tsv")
  shared = Doom::Core::Session.read_buffers(buffers_tsv).find { |x| x["name"] == "core_state" }
  made["core_state"] = Doom::Core::Resources.core_state(slots: slots_tsv, count: shared["count"], prepared: made)
  session = Doom::Core::Session.open(buffers: buffers_tsv, prepared: made, slots: slots_tsv)
  width = { "u8" => 1, "i8" => 1, "u16" => 2, "i16" => 2, "i32" => 4, "u32" => 4, "i64" => 8 }
  as_bytes = ->(b) { b.store.is_a?(String) ? b.store : b.store.pack({ "u8" => "C*", "i64" => "q<*" }.fetch(b.element)) }
  cs = session.id(:core_state)
  core = field_buf(cs.count, "i64").load(as_bytes.(cs))
  natives = {}
  $res = {}
  in_fields = []
  # A field some entry's contract writes is not read-only, in any context; nor is
  # one the lane loads from the original's objects (named in the output).
  written_fields = $fields_rows.select do |_c, entry, param, field, _u|
    File.foreach(File.join(ROOT, "tests/doom-core/fixtures/source/#{entry}.contract"))
        .any? { |l| l =~ /\Aparam #{Regexp.escape(param)} buffer \S+ inout / } && !field.start_with?("job:", "derived:")
  end.map { |r| r[3] }.uniq
  # Through the adapter every element is a call, so only the contexts this mode
  # calls are given storage.
  mode_contexts = mode == "direct" ? %w[direct-column direct-span produce-column produce-span produce-zone-direct] :
                                    %w[queued-wall queued-span queued-masked produce-column produce-span produce-zone-queued alloc-zone reset-jobs]
  mode_contexts += %w[queued-frame push-wall push-span push-masked mark-phase1 mark-phase3
                     check-disjoint check-span check-masked check-wall-all draw-plane clear-planes] if mode == "frame"
  mode_contexts += %w[draw-statusbar draw-hud] if $furniture
  mode_contexts += LEAF_CONTEXTS if mode == "frame"
  $fields_rows.each do |context, _entry, param, field, _use|
    # `arg:` names no storage: the lane fills its own buffer from the caller.
    next if field.start_with?("job:", "derived:", "arg:") || param.start_with?("i_")
    next if ADAPTER && !mode_contexts.include?(context)
    # The furniture's fields are given storage only where it is drawn, and the
    # leaves' only where they run beside the original, in frame mode.
    next if !$furniture && %w[draw-statusbar draw-hud].include?(context)
    next if mode != "frame" && LEAF_CONTEXTS.include?(context)
    buf =
      if field == "none" then $empty
      elsif field == "core_state" then core
      else
        b = session.id(field)
        in_fields << field unless written_fields.include?(field) || LANE_LOADED_FIELDS.include?(field) ||
                                  COPY_BUFFERS.include?(field) || LEAF_LOADED_FIELDS.include?(field)
        natives[field] ||= field_buf(b.count, b.element).load(as_bytes.(b))
      end
    key = [context, param]
    $res.key?(key) && !$res[key].equal?(buf) and abort("source-port.rb: #{FIELDS} gives #{context} #{param} two fields")
    $res[key] = buf
  end
  # The zone producers' stores ARE the consumers': the direct window, and the ONE ring
  # the executor reads.
  !(ADAPTER && mode != "direct") && !res("produce-zone-direct", "out").equal?(res("direct-column", "zonewin")) and
    abort("source-port.rb: #{FIELDS} gives the direct zone producer and the column different windows")
  !(ADAPTER && mode == "direct") && !res("produce-zone-queued", "out").equal?(res("queued-masked", "zonebuf")) and
    abort("source-port.rb: #{FIELDS} gives the ring producer and the executor different rings")
  # A cell Jobs#reset writes is one the render entry writes: its access says so.
  render_access = File.readlines(File.join(ROOT, "examples/doom/core/access.tsv")).map { |l| l.chomp.split("\t") }
                      .select { |e, _, _| e == "doom_core_render" }.to_h { |_, fl, m| [fl, m] }
  (RESET_ZERO + RESET_ONE).each do |n|
    render_access[n] == "inout" or abort("source-port.rb: Jobs#reset writes #{n}, which doom_core_render has as #{render_access[n].inspect}")
  end
  # The indices are the registry's from here on, and the state is core_state.
  index_layout(->(n) { session.slots.fetch(n) { abort("source-port.rb: #{n} is not a slot of the layout") } })
  $pstate = core
  # The producers' cells ARE the consumers' cells.
  [%w[column i_res], %w[column i_base], %w[span i_res], %w[span i_base]].each do |ctx, p|
    ix("produce-#{ctx}", p) == ix("direct-#{ctx}", p) or
      abort("source-port.rb: #{FIELDS} gives produce-#{ctx} and direct-#{ctx} different #{p}")
  end
  # WHICH SLOTS HOLD THE SELECTOR, from core-representations.tsv and slots.tsv --
  # not from fields.tsv, so a field map pointing at the wrong slot is seen.
  $rep_slots = []
  File.foreach(File.join(ROOT, "tools/doom/core-representations.tsv")) do |ln|
    next if ln.start_with?("#") || ln.strip.empty?
    f = ln.chomp.split("\t", -1)
    next unless f.length == 6 && f[5] =~ /\Asource-select:(dc|ds):(res|base)\z/
    $rep_slots << [f[1], $1, $2, session.slots.fetch(f[1])]
  end
  $rep_slots.length == 4 or abort("source-port.rb: #{$rep_slots.length} source-select fields, want 4")
  $written_slots = [ix("alloc-zone", "i_nzone")] + RESET_ZERO.map { |n| session.slots.fetch(n) } + [ix("reset-jobs", "i_fuzz_suffix")]
  # The pushes' counters, the phase marks and the checks' statistics are among
  # the cells Jobs#reset writes.
  mode == "frame" and %w[push-wall:i_nwall push-span:i_nspan push-masked:i_nmasked push-wall:i_nsched
                         mark-phase1:i_wall_phase0_n mark-phase3:i_masked_phase2_n
                         check-disjoint:i_max_k check-disjoint:i_overlaps check-span:i_span_max_kx
                         check-span:i_span_overlaps check-masked:i_fuzz_n check-masked:i_masked_max_kx
                         check-masked:i_fuzz_max_kx check-wall-all:i_wall_all_max_k
                         check-wall-all:i_wall_all_overlaps].each do |cp|
    $written_slots.include?(ix(*cp.split(":"))) or abort("source-port.rb: #{cp} is not a cell Jobs#reset writes")
  end
  # The cells the lane loads from the original's objects, and the ones the plane entries write.
  if mode == "frame"
    $written_slots += LOADED_CELLS.map { |p, _| ix("draw-plane", p) } + PLANE_OUT.map { |c, p, _| ix(c, p) } +
                      CLEAR_OUT.map { |p, _| ix("clear-planes", p) } + DC_CELLS.map { |p, _| ix("draw-plane", p) } +
                      [ix("draw-plane", "i_lastvisplane")]
  end
  # The cells the leaves write or have loaded before a call.
  if mode == "frame"
    $written_slots += [ix("leaf-crunch", "i_newend"), ix("leaf-sort-vissprites", "i_vis_n"),
                       *%w[i_validcount i_extralight i_viewz i_viewcos i_viewsin i_spritelights
                          i_vis_n].map { |p| ix("leaf-add-sprites", p) },
                       *%w[i_viewangle i_rw_normalangle i_rw_distance].map { |p| ix("leaf-scale-from-global-angle", p) }]
    # the seg loop's: every cell it is handed is loaded before the call or written by it
    $written_slots += SEG_CELLS.map { |p, _| ix("seg-loop", p) } + %w[i_nwall i_nsched].map { |p| ix("seg-loop", p) }
  end
  # The furniture's cells: the widget memory the bar writes, and the game's
  # cells the boundary copy writes.
  if $furniture
    $written_slots += %w[i_firsttime i_old_armsbg i_old_face i_faceindex i_notdeathmatch].map { |p| ix("draw-statusbar", p) } +
                      %w[i_message i_message_on].map { |p| ix("draw-hud", p) }
  end
  $session = { session: session, core: core, core_before: core.bytes, natives: natives, in_fields: in_fields.uniq,
               pre: $rep_slots.map { |_f, _w, _p, idx| core[idx] } }
end
r.job_mode = mode == "direct" ? 0 : 2
$frame_mode = mode == "frame"
# THE PUSHES, PORTED (frame mode). The port's push runs after the original's,
# with its arguments, into the port's own bank, schedule and counters, and what
# it stored is compared with what the original just stored.
PUSHES = {
  wall: ["push-wall", "wall", "cap_wall", "i_nwall", 7, :dc_push_wall, :wall_bank, :nwall],
  span: ["push-span", "span", "cap_span", "i_nspan", 7, :dc_push_span, :span_bank, :nspan],
  masked: ["push-masked", "masked", "cap_masked", "i_nmasked", 9, :dc_push_masked, :masked_bank, :nmasked]
}.freeze
def port_push(kind, jobs, fields)
  ctx, bank, cap, icount, nf, fn, orig_bank, orig_count = PUSHES.fetch(kind)
  i = jobs.send(orig_count) - 1
  s = jobs.nsched - 1
  where = "frame #{$frame} #{kind} push #{i} schedule #{s}"
  $count["pushes-#{kind}"] += 1
  call_ctx, call_bank, call_cap, call_icount, call_fn = ctx, bank, cap, icount, fn
  # push-kind: the wall push issued through the port's span push
  if $control == "push-kind" && kind == :wall
    call_ctx, call_bank, call_cap, call_icount, _, call_fn = PUSHES[:span]
  end
  sk = res(call_ctx, "sc_kind")
  si = res(call_ctx, "sc_idx")
  sk, si = $sched_sink if $control == "push-skip-sched" && kind == :wall
  capbuf = $control == "push-cap-low" && kind == :wall ? $cap_low : res(call_ctx, call_cap)
  begin
    send(call_fn, ps, res(call_ctx, call_bank), sk, si, capbuf, res(call_ctx, "cap_sched"),
         ix(call_ctx, call_icount), ix(call_ctx, "i_nsched"), *fields)
  rescue StandardError => e
    raise unless defined?(CoreCapacity) && e.is_a?(CoreCapacity)
    fault("push-capacity", where)
  end
  pb = res(ctx, bank)
  got = (0...nf).map { |k| pb[i * nf + k] } + [res(ctx, "sc_kind")[s], res(ctx, "sc_idx")[s], ps[ix(ctx, icount)], ps[ix(ctx, "i_nsched")]]
  want = jobs.send(orig_bank)[i * nf, nf] + [jobs.sched_kind_bank[s], jobs.sched_idx_bank[s], i + 1, s + 1]
  fault("push-disagree", "#{where} port #{got.join(',')} original #{want.join(',')}") if got != want
end
def port_mark(phase, jobs)
  ctx = "mark-phase#{phase}"
  from, to, fn, orig = phase == 1 ? ["i_nwall", "i_wall_phase0_n", :dc_mark_phase1, :wall_phase0_n] :
                                    ["i_nmasked", "i_masked_phase2_n", :dc_mark_phase3, :masked_phase2_n]
  i_from = $control == "push-phase-counter" && phase == 1 ? ix("push-span", "i_nspan") : ix(ctx, from)
  send(fn, ps, i_from, ix(ctx, to))
  $count["marks"] += 1
  got = ps[ix(ctx, to)]
  want = jobs.send(orig)
  fault("phase-disagree", "frame #{$frame} mark #{phase} port #{got} original #{want}") if got != want
end
# THE INTERVAL TABLES, PORTED (frame mode): the four checks the original's
# `Jobs#check` runs after its own per-job checks, over the port's banks, in the
# original's order -- and every statistic, every count table and every filled
# slot compared with the original's.
CHECK_COUNTERS = [["check-disjoint", "i_max_k", :@max_k], ["check-disjoint", "i_overlaps", :@overlaps],
                  ["check-span", "i_span_max_kx", :@span_max_kx], ["check-span", "i_span_overlaps", :@span_overlaps],
                  ["check-masked", "i_fuzz_n", :@fuzz_n], ["check-masked", "i_masked_max_kx", :@masked_max_kx],
                  ["check-masked", "i_fuzz_max_kx", :@fuzz_max_kx], ["check-wall-all", "i_wall_all_max_k", :@wall_all_max_k],
                  ["check-wall-all", "i_wall_all_overlaps", :@wall_all_overlaps]].freeze
# [context, count table, slots per entry, slot tables]
$check_stats = {}
CHECK_TABLES = [["check-wall-all", "xcount", 64, %w[xyl xyh]], ["check-span", "ycount", 256, %w[yx1 yx2]],
                ["check-masked", "mcount", 256, %w[mlo mhi mseq mfz]]].freeze
def port_check_call(where)
  yield
rescue StandardError => e
  raise unless defined?(CoreCapacity) && e.is_a?(CoreCapacity)
  fault("check-capacity", where)
end
def port_checks(jobs)
  c = "check-disjoint"
  lo = $control == "check-lo-one" ? 1 : 0
  port_check_call("frame #{$frame} check_disjoint") do
    dc_check_disjoint(ps, res(c, "wall"), res(c, "xcount"), res(c, "xyl"), res(c, "xyh"), res(c, "width"),
                      lo, ix(c, "i_hi"), ix(c, "i_max_k"), ix(c, "i_overlaps"))
  end
  xc, xl, xh = $disjoint_left
  compare_table("check-disjoint", "xcount", 64, %w[xyl xyh], xc, { "xyl" => xl, "xyh" => xh }, "after check_disjoint")
  c = "check-span"
  port_check_call("frame #{$frame} check_span_disjoint") do
    next if $control == "check-skip-span" && $frame.odd?
    dc_check_span_disjoint(ps, res(c, "span"), res(c, "ycount"), res(c, "yx1"), res(c, "yx2"), res(c, "height"),
                           ix(c, "i_nspan"), ix(c, "i_span_max_kx"), ix(c, "i_span_overlaps"))
  end
  c = "check-masked"
  port_check_call("frame #{$frame} check_masked_k") do
    dc_check_masked_k(ps, res(c, "masked"), *%w[mcount mlo mhi mseq mfz].map { |p| res(c, p) }, res(c, "width"),
                      ix(c, "i_nmasked"), ix(c, "i_fuzz_n"), ix(c, "i_masked_max_kx"), ix(c, "i_fuzz_max_kx"))
  end
  c = "check-wall-all"
  xt = %w[xcount xyl xyh].map { |p| res(c, p) }
  port_check_call("frame #{$frame} check_wall_all") do
    dc_check_wall_all(ps, res(c, "wall"), *xt, res(c, "width"), ix(c, "i_nwall"), ix(c, "i_wall_all_max_k"),
                      ix(c, "i_wall_all_overlaps"))
  end
  $count["checks"] += 4
  CHECK_COUNTERS.each do |ctx, p, ivar|
    got = ps[ix(ctx, p)]
    want = jobs.instance_variable_get(ivar)
    name = ivar.to_s.delete_prefix("@")
    # what the original's statistics reached, so equal values are not all zeros
    $check_stats[name] = [$check_stats[name] || 0, want].max
    fault("check-disagree", "frame #{$frame} #{name} port #{got} original #{want}") if got != want
  end
  CHECK_TABLES.each do |ctx, count_name, per, slot_names|
    compare_table(ctx, count_name, per, slot_names, jobs.instance_variable_get("@#{count_name}"),
                  slot_names.to_h { |sn| [sn, jobs.instance_variable_get("@#{sn}")] }, "after check")
  end
end
# The count table whole, and in each column or row the slots it filled.
def compare_table(ctx, count_name, per, slot_names, oc, originals, point)
  pc = res(ctx, count_name)
  bad = (0...oc.length).find { |x| pc[x] != oc[x] }
  if bad
    fault("check-disagree", "frame #{$frame} #{point} #{count_name}[#{bad}] port #{pc[bad]} original #{oc[bad]}")
    return
  end
  $count["check-slots"] += oc.sum * slot_names.length
  slot_names.each do |sn|
    pt = res(ctx, sn)
    ot = originals.fetch(sn)
    at = nil
    (0...oc.length).each do |x|
      k = (0...oc[x]).find { |a| pt[x * per + a] != ot[x * per + a] }
      next unless k
      at = x * per + k
      break
    end
    fault("check-disagree", "frame #{$frame} #{point} #{sn}[#{at}] port #{pt[at]} original #{ot[at]}") if at
  end
end
# THE PLANES, PORTED (frame mode). The original's draw_planes loop runs; the port
# draws every plane since the last before each sky plane and at the loop's end,
# over the visplane arrays as the original's loop found them.
def port_load_ints(buf, values)
  load_prefix(buf, values, values.length)
end
# Before the port's clear_planes the lane loads what the original's clear_planes
# found -- the four plane counters and the two clip arrays as the previous frame's
# walls and planes left them -- so each write it makes is seen on every frame,
# not only against the port's initial zeros.
$clear_loaded = Hash.new(0)
$clear_mismatch = Hash.new(0)
def load_pre_clear(c, pre)
  CLEAR_OUT.first(4).each_with_index { |(p, _), k| ps[ix(c, p)] = pre[:counters][k] }
  load_prefix(res(c, "floorclip"), pre[:floorclip], pre[:floorclip].length)
  load_prefix(res(c, "ceilingclip"), pre[:ceilingclip], pre[:ceilingclip].length)
end
def port_clear_planes(r, pre)
  c = "clear-planes"
  LOADED_CELLS.each { |p, ivar| ps[ix("draw-plane", p)] = r.instance_variable_get(ivar) }
  load_pre_clear(c, pre)
  $count["plane-clears"] += 1
  # per field, the clears where what the lane loaded is not what clear_planes writes:
  # there, a deleted write would leave a difference
  CLEAR_OUT.first(4).each_with_index do |(_, ivar), k|
    $clear_loaded[ivar.to_s.delete_prefix("@")] += 1 if pre[:counters][k] != r.instance_variable_get(ivar)
  end
  %i[floorclip ceilingclip].each do |t|
    $clear_loaded[t.to_s] += 1 if pre[t] != r.instance_variable_get("@#{t}")[0, pre[t].length]
  end
  unless $control == "clear-skip" && $frame.to_i.odd?
    begin
      dc_clear_planes(ps, *%w[floorclip ceilingclip cachedheight finesine centerxfrac viewwidth viewheight sh].map { |p| res(c, p) },
                      *%w[i_viewangle i_lastvisplane i_lastopening i_floorplane i_ceilingplane i_basexscale i_baseyscale].map { |p| ix(c, p) })
    rescue StandardError => e
      raise unless defined?(CoreCapacity) && e.is_a?(CoreCapacity)
      fault("clear-disagree", "frame #{$frame} capacity")
    end
  end
  # clear-drop-counters / clear-drop-clips: as if the port's writes were deleted
  if $control == "clear-drop-counters"
    CLEAR_OUT.first(4).each_with_index { |(p, _), k| ps[ix(c, p)] = pre[:counters][k] }
  elsif $control == "clear-drop-clips"
    load_prefix(res(c, "floorclip"), pre[:floorclip], pre[:floorclip].length)
    load_prefix(res(c, "ceilingclip"), pre[:ceilingclip], pre[:ceilingclip].length)
  end
  where = "frame #{$frame} after clear_planes"
  # every field is compared, and each mismatching field counted by name; the
  # clear's fault is its first
  first = nil
  CLEAR_OUT.each do |p, ivar|
    got = ps[ix(c, p)]
    want = r.instance_variable_get(ivar)
    next if got == want
    $clear_mismatch[ivar.to_s.delete_prefix("@")] += 1
    first ||= "#{ivar.to_s.delete_prefix('@')} port #{got} original #{want}"
  end
  [["floorclip", r.instance_variable_get(:@viewwidth)], ["ceilingclip", r.instance_variable_get(:@viewwidth)],
   ["cachedheight", r.instance_variable_get(:@sh)]].each do |t, n|
    pb = res(c, t)
    ob = r.instance_variable_get("@#{t}")
    bad = (0...n).find { |i| pb[i] != ob[i] }
    next unless bad
    $clear_mismatch[t] += 1
    first ||= "#{t}[#{bad}] port #{pb[bad]} original #{ob[bad]}"
  end
  fault("clear-disagree", "#{where} #{first}") if first
end
# Before the original's loop: the visplane arrays it will walk, and its counters.
def port_planes_begin(r)
  jobs = r.instance_variable_get(:@jobs)
  plw = r.instance_variable_get(:@plw)
  n = r.instance_variable_get(:@lastvisplane)
  $planes = {
    next: 0, nspan: jobs.nspan, nsched: jobs.nsched, nwall: jobs.nwall, recs: [],
    one: PL_ONE.to_h { |t| [t, r.instance_variable_get("@#{t}")[0, n]] },
    top: r.instance_variable_get(:@pl_top)[0, n * plw].dup, bottom: r.instance_variable_get(:@pl_bottom)[0, n * plw].dup
  }
end
PLANE_BUFS = %w[pl_minx pl_maxx pl_picnum pl_height pl_lightlevel pl_top pl_bottom spanstart cachedheight cacheddistance
                cachedxstep cachedystep yslope distscale xtoviewangle finesine zlight flattranslation span sc_kind sc_idx
                cap_span cap_sched plw plempty skyflatnum tex_widthmask tex_atlas_base wall cap_wall skytexture
                pspriteiscale skytexturemid].freeze
PLANE_IDX = %w[i_viewz i_extralight i_planeheight i_planezlight i_curpicnum i_basexscale i_baseyscale i_viewangle i_viewx
               i_viewy i_nspan i_nsched i_lastvisplane i_nwall i_dc_x i_dc_yl i_dc_yh i_dc_iscale i_dc_texturemid
               i_dc_colormap i_dc_srcofs i_dc_srcbase].freeze
# job mode 0's direct path: the span and the sky column are drawn into the screen
PLANE_DIRECT = %w[jobmode scr cmap flat atlas wad zonewin centery sw viewwindowx viewwindowy].freeze
# Plane pl's arrays as the original's loop found them, changed only by a plane control.
def load_plane(pl)
  c = "draw-plane"
  st = $planes
  plw = $renderer.instance_variable_get(:@plw)
  src = $control == "plane-wrong" && pl % 3 == 1 && pl + 1 < st[:one]["pl_minx"].length ? pl + 1 : pl
  PL_ONE.each { |t| res(c, t)[pl] = st[:one][t][src] }
  res(c, "pl_minx")[pl] = st[:one]["pl_maxx"][pl] + 1 if $control == "plane-skip" && pl % 3 == 1
  res(c, "pl_height")[pl] = st[:one]["pl_height"][src] + 65_536 if $control == "plane-wrong-height"
  load_rows(res(c, "pl_top"), st[:top], pl * plw, plw, src * plw)
  load_rows(res(c, "pl_bottom"), st[:bottom], pl * plw, plw, src * plw)
end
def call_draw_planes(pl_from, where)
  c = "draw-plane"
  bufs = PLANE_BUFS.map { |p| $sky_private && $sky_private[0] == p ? $sky_private[1] : res(c, p) }
  dc_draw_planes(ps, *bufs, *PLANE_IDX.map { |p| ix(c, p) }, pl_from, *PLANE_DIRECT.map { |p| res(c, p) },
                 ix(c, "i_dc_srcres"))
rescue StandardError => e
  raise unless defined?(CoreCapacity) && e.is_a?(CoreCapacity)
  fault("plane-disagree", "#{where} capacity")
  0
end
# THE WALK: after the original's loop, one call walks every plane; then
# everything it pushed and set is compared.
def port_planes_whole(r)
  c = "draw-plane"
  st = $planes
  n = st[:one]["pl_minx"].length
  (0...n).each { |pl| load_plane(pl) }
  last = r.instance_variable_get(:@lastvisplane)
  ps[ix(c, "i_lastvisplane")] = $control == "planes-bound-short" ? last - 1 : last
  skies = call_draw_planes(0, "frame #{$frame} planes")
  $count["planes"] += n
  # THE PORT'S OWN SKY COUNT, and the only one on this line that is: `skies` is
  # what `dc_draw_planes` answered, the planes ITS walk recognized as sky by
  # testing each plane's picnum against the prepared sky flat. It is not a count
  # of what was drawn -- a recognized plane whose columns all had empty runs
  # pushes nothing -- and it is not `sky-planes`, which counts the same planes in
  # the ORIGINAL's records. A port that stops recognizing the sky moves this one
  # and leaves that one where it was.
  $count["sky-planes-recognized"] += skies
  sky_recs = st[:recs].count { |x| x[:sky] }
  $count["sky-planes"] += sky_recs
  $count["sky-planes-with-columns"] += st[:recs].count { |x| x[:sky] && x[:nwall_end] > x[:nwall] }
  fault("plane-disagree", "frame #{$frame} the walk drew #{skies} sky planes, the original #{sky_recs}") if skies != sky_recs
  # the column cells are the sky's only if a sky plane pushed a column; otherwise
  # they hold what the unported wall loop left in the original
  compare_planes_after(r, 0...n, dc: st[:recs].any? { |x| x[:sky] && x[:nwall_end] > x[:nwall] })
end
def compare_walls(r, w0, w1, where)
  c = "draw-plane"
  jobs = r.instance_variable_get(:@jobs)
  wb = res(c, "wall")
  ob = jobs.wall_bank
  k = (w0...w1).find { |i| (0...7).any? { |f| wb[i * 7 + f] != ob[i * 7 + f] } }
  $count["sky-columns"] += w1 - w0
  return true unless k
  fault("plane-disagree", "#{where} sky column job #{k} port #{(0...7).map { |f| wb[k * 7 + f] }.join(',')} original #{ob[k * 7, 7].join(',')}")
  false
end
# AFTER THE WALK: the counters, every span, wall and schedule entry the loop
# pushed, curpicnum, planeheight and planezlight, the sentinel columns of every
# drawn plane, spanstart and the row cache -- and, when a sky plane was drawn, the
# column cells it left.
def compare_planes_after(r, range, dc:)
  c = "draw-plane"
  st = $planes
  jobs = r.instance_variable_get(:@jobs)
  plw = r.instance_variable_get(:@plw)
  where = "frame #{$frame} after the walk"
  got = %w[i_nspan i_nsched i_nwall].map { |p| ps[ix(c, p)] }
  want = [jobs.nspan, jobs.nsched, jobs.nwall]
  if got != want
    fault("plane-disagree", "#{where} counters nspan/nsched/nwall port #{got.join(',')} original #{want.join(',')}")
    return
  end
  $count["spans-emitted"] += jobs.nspan - st[:nspan]
  sb = res(c, "span")
  ob = jobs.span_bank
  k = (st[:nspan]...jobs.nspan).find { |i| (0...7).any? { |f| sb[i * 7 + f] != ob[i * 7 + f] } }
  if k
    fault("plane-disagree", "#{where} span #{k} port #{(0...7).map { |f| sb[k * 7 + f] }.join(',')} original #{ob[k * 7, 7].join(',')}")
    return
  end
  return unless compare_walls(r, st[:nwall], jobs.nwall, where)
  kb = res(c, "sc_kind")
  ib = res(c, "sc_idx")
  k = (st[:nsched]...jobs.nsched).find { |i| [kb[i], ib[i]] != [jobs.sched_kind_bank[i], jobs.sched_idx_bank[i]] }
  if k
    fault("plane-disagree", "#{where} schedule #{k} port #{kb[k]},#{ib[k]} original #{jobs.sched_kind_bank[k]},#{jobs.sched_idx_bank[k]}")
    return
  end
  PLANE_OUT.each do |ctx, p, ivar|
    g = ps[ix(ctx, p)]
    w = r.instance_variable_get(ivar)
    next if g == w
    fault("plane-disagree", "#{where} #{ivar.to_s.delete_prefix('@')} port #{g} original #{w}")
    return
  end
  if dc
    d = DC_CELLS.map { |p, _| ps[ix(c, p)] }
    o = DC_CELLS.map { |_, ivar| r.instance_variable_get(ivar) }
    if d != o
      fault("plane-disagree", "#{where} dc cells port #{d.join(',')} original #{o.join(',')}")
      return
    end
  end
  one = st[:one]
  ot = r.instance_variable_get(:@pl_top)
  pt = res(c, "pl_top")
  cells = range.reject { |pl| one["pl_minx"][pl] > one["pl_maxx"][pl] || one["pl_picnum"][pl] == $plane_sky }
               .flat_map { |pl| [pl * plw + 1 + one["pl_maxx"][pl] + 1, pl * plw + one["pl_minx"][pl]] }
  $count["sentinels"] += cells.length
  bad = cells.find { |i| pt[i] != ot[i] }
  if bad
    fault("plane-disagree", "#{where} pl_top[#{bad}] port #{pt[bad]} original #{ot[bad]}")
    return
  end
  %w[spanstart cachedheight cacheddistance cachedxstep cachedystep].each do |t|
    pb = res(c, t)
    obt = r.instance_variable_get("@#{t}")
    y = (0...obt.length).find { |i| pb[i] != obt[i] }
    next unless y
    fault("plane-disagree", "#{where} #{t}[#{y}] port #{pb[y]} original #{obt[y]}")
    return
  end
end
def load_rows(buf, values, from, n, src = from)
  n.times { |k| buf[from + k] = values[src + k] }
end
# THE WHOLE EXECUTOR RUN (frame mode). The port's screen starts as the resident
# screen and is never reloaded from the original: every frame the original's
# executor runs, the port's `dc_exec_run` runs over the PORT'S banks and
# schedule, which only the port's pushes wrote, over the port's own ring and
# reset counter, and then ALL of the port's screen must equal all of the
# original's.
def port_frame(jobs, scr)
  ctx = "queued-frame"
  nsched = jobs.nsched
  counts = [ps[ix("push-wall", "i_nwall")], ps[ix("push-span", "i_nspan")], ps[ix("push-masked", "i_nmasked")], ps[ix(ctx, "i_nsched")]]
  want_counts = [jobs.nwall, jobs.nspan, jobs.nmasked, nsched]
  fault("push-disagree", "frame #{$frame} counters port #{counts.join(',')} original #{want_counts.join(',')}") if counts != want_counts
  port_checks(jobs)
  # The frame controls change the port's banks just before its run, and nothing else.
  if $control == "frame-order"
    kb = res(ctx, "sc_kind")
    ib = res(ctx, "sc_idx")
    kinds = (0...nsched).map { |k| kb[k] }.reverse
    idx = (0...nsched).map { |k| ib[k] }.reverse
    load_prefix(kb, kinds, nsched)
    load_prefix(ib, idx, nsched)
  elsif $control == "frame-fuzz-phase"
    mb = res(ctx, "masked")
    (0...jobs.nmasked).each { |m| f = mb[m * 9 + 8]; mb[m * 9 + 8] = (f + 1) % 50 if f >= 0 }
  elsif $control == "frame-wrong-bank"
    # From the second frame on, the span records the port reads are the PREVIOUS
    # frame's span bank -- records the game really issued, every index in range,
    # and the wrong frame's. The wall bank itself cannot stand in: a wall record
    # read as a span names a screen row past the screen.
    load_prefix(res(ctx, "span"), $prev_span_bank, jobs.nspan * 7) if $prev_span_bank
    $prev_span_bank = jobs.span_bank.dup
  end
  sc = res(ctx, "scr")
  fuzz = port_exec(ctx)
  # The fuzz columns the ORIGINAL's schedule names -- masked jobs with a fuzz
  # phase and at least one row (exec_masked returns before the fuzz branch for
  # none), counted from its banks, not from the port -- and the port's own count
  # must be the same number, so a nonzero total is the path running.
  want = (0...nsched).count do |k|
    b = jobs.sched_idx_bank[k] * 9
    jobs.sched_kind_bank[k] == 2 && jobs.masked_bank[b + 8] >= 0 && jobs.masked_bank[b + 2] >= jobs.masked_bank[b + 1]
  end
  fault("fuzz-count-disagree", "frame #{$frame} port #{fuzz} original #{want}") if fuzz != want
  $count["frames-run"] += 1
  $count["jobs-run"] += nsched
  $count["fuzz-columns"] += want
  got = port_screen_bytes(sc)
  return if got == scr
  at = (0...scr.bytesize).find { |o| got.getbyte(o) != scr.getbyte(o) }
  fault("frame-disagree", "frame #{$frame} pixel #{at} (x #{at % 320} y #{at / 320}) port #{got.getbyte(at)} original #{scr.getbyte(at)}")
end
# THE END-OF-FRAME COMPARISON, after the status bar and the HUD are drawn.
#
# port_frame compares DURING the render, which is before the furniture is drawn,
# and the next render overwrites the HUD's row before the next comparison. So
# nothing drawn after the render was ever on the screen when a comparison ran:
# measured, the port's HUD could be made wrong on every frame -- its copied
# message switched on from frame 0 -- and frame-disagree stayed at zero. The HUD
# port was a pass that could not have failed until this existed.
#
# THIS IS ALSO WHERE THE RECORDER HASHES. sim_demo.rb takes its digests after
# hud.draw, so the golden comparison belongs here and not mid-render; mid-render
# it could only ever compare the bare view, and the recording is not a bare view.
#
# IT HASHES THE SCREEN THE PORT ACTUALLY DRAWS INTO, which is `res`'s and not
# necessarily $port_scr. On the session and adapter routes the port's screen is
# the session's own storage; the first version of this hashed $port_scr there, a
# buffer those routes never write, and reported every frame from 0 as different.
# port_frame has always asked `res`, and this now asks the same thing.
def end_of_frame(r)
  got = port_screen_bytes(res("queued-frame", "scr"))
  scr = r.screen
  if $furniture
    $count["screens-end"] += 1
    if got != scr
      at = (0...scr.bytesize).find { |o| got.getbyte(o) != scr.getbyte(o) }
      fault("screen-disagree", "frame #{$frame} pixel #{at} (x #{at % 320} y #{at / 320}) port #{got.getbyte(at)} original #{scr.getbyte(at)}")
    end
  end
  return unless $golden
  want = $golden[$frame]
  if want.nil?
    fault("golden-disagree", "frame #{$frame} has no recorded screen")
    return
  end
  vh = Doom::Bytes.fnv1a64_hex_range(got, 0, $golden_sw * $golden_vh)
  fh = Doom::Bytes.fnv1a64_hex_range(got, 0, got.bytesize)
  $count["golden-frames"] += 1
  $count["golden-full-agree"] += 1 if fh == want[1]
  fault("golden-disagree", "frame #{$frame} port view #{vh}, recorded view #{want[0]}") if vh != want[0]
  # THE FULL SCREEN TOO, now that the port draws the status bar and the HUD. It
  # was recorded all along and was not this route's to check until the port drew
  # what lies outside the view; measured before it was switched on, all 5026
  # frames of DEMO1 agree. The view is checked first so a difference inside the
  # view is reported as one, and a difference only in the furniture as the other.
  # Only where this route draws the furniture: without it the rows under the view
  # are never written, and the recording's are, so the full screen differs on
  # every frame for a reason that is the route's and not the port's.
  if $furniture && vh == want[0] && fh != want[1]
    fault("golden-disagree", "frame #{$frame} port full #{fh}, recorded full #{want[1]} (the view agrees)")
  end
end
def port_screen_bytes(b) = b.is_a?(Array) ? b.pack("C*") : b.bytes
def load_prefix(buf, values, n)
  if buf.is_a?(Array)
    n.times { |k| buf[k] = values[k] }
  elsif defined?(AdapterRoute) && buf.is_a?(AdapterRoute::IdBuf)
    n.times { |k| buf[k] = values[k] }
  else
    buf.ptr[0, n * 8] = values[0, n].pack("q<*") if n.positive?
  end
end
# The executor entry: the Ruby port with values, or the compiled entry with buffers.
def port_exec(ctx)
  names = %w[scr cmap atlas flat wad zonebuf fuzzoffset wall span masked sc_kind sc_idx]
  bufs = names.map { |p| res(ctx, p) }
  frame = %w[width centery vwx vwy].map { |p| res(ctx, p) }
  i_nsched = ix(ctx, "i_nsched")
  if ADAPTER
    adapter_call(:exec, *bufs.map(&:id), ps.id, *frame.map(&:id), i_nsched)
  elsif NATIVE
    native(:exec, *bufs.flat_map { |b| [b.ptr, b.count] }, ps.ptr, ps.count, *frame.flat_map { |b| [b.ptr, b.count] }, i_nsched)
  else
    dc_exec_run(*bufs, ps[i_nsched], *frame.map { |b| b[0] })
  end
end
$renderer = r
$plane_ready = true
$plane_sky = lv.skyflatnum
# sky-skip, sky-texmid, sky-iscale: the port's walk is given a private buffer in place of the prepared one
$sky_private = case control
               when "sky-skip" then ["skyflatnum", port_i64s([-1])]
               when "sky-texmid" then ["skytexturemid", port_i64s([r.instance_variable_get(:@skytexturemid) + 65_536])]
               when "sky-iscale" then ["pspriteiscale", port_i64s([r.instance_variable_get(:@pspriteiscale) + 1])]
               end
$port_scr = port_screen(r.screen.bytesize)
# The status bar's backing store, the port's copy. 320x32, which 0008's roles
# put under `persistent`: the record names HUD/status-bar state there, and it
# survives every frame while CORE writes it. Only where the lane holds its own
# copies and draws the furniture: a session hands over status_bar_backing, and a
# run that draws nothing needs no store -- through the adapter it would be one
# more registry id in every run's count.
$port_backing = port_screen(320 * 32) if $furniture && !SESSION

# THE BOUNDARY COPY, once per frame, between the tickers and the render.
#
# WHAT IS IN IT is exactly the step-written state a PORTED CORE reader needs,
# and nothing else. A buffer enters in the same commit as its first CORE reader,
# because a buffer nothing on the port side reads cannot be left out in a way
# that turns anything red -- so it would be a copy that could not fail, inside
# the mechanism meant to survive the cutover. The list is copy.tsv (COPY_ROWS):
#   textures_flattranslation    read by the plane entry
#   status_bar_faceindex        a core_state cell the status bar entry reads
#   status_bar_keyboxes         read by the status bar entry
#   status_bar_notdeathmatch    a core_state cell the status bar entry reads
#   hud_message, hud_message_on core_state cells the HUD entry reads
#
# EACH TARGET IS THE STORAGE ITS ENTRY IS HANDED -- res() for a buffer, the
# fields.tsv cell of `ps` for a scalar -- so on the session route the copy writes
# the resident field itself, and on the others the lane's copy of it.
#
# THE TARGETS START POISONED, so an omitted copy is visible even for a buffer
# that never changes. status_bar_notdeathmatch is constant in all three demos;
# without a poisoned target, leaving it out would be indistinguishable from
# copying it. A POISON IS CHOSEN AGAINST THE VALUE AT THE READ, and copy.tsv
# says at which frame its absence first shows; see the furniture block.
#
# AND A PLANTED DEFECT MUST CHANGE A VALUE, NOT ONLY THE TEXT. render-diff.rb's
# first spine control moved the weapon's colormap index from MAXLIGHTSCALE-1
# to -2 on a line coverage showed running every frame, and nothing disagreed:
# scalelight holds the same colormap at indices 46 and 47 at all sixteen light
# levels. A control that runs and changes nothing observable cannot be told
# apart from a check that cannot fail -- print the values either side before
# trusting the silence.
#
# SOURCE_PORT_COPY_SKIP names one buffer to leave out. It is the failing input:
# each, skipped, must turn the comparison red at its frame.
# READ FROM THE SAME LIST copy-check.rb checks, so the copy this file performs and
# the copy that check certifies cannot become two lists that look like one.
# Each buffer the list names must be one this file knows how to copy; a name
# added to the list without a copy here would be a claim with nothing under it.
COPY_HANDLED = %w[textures_flattranslation status_bar_faceindex status_bar_keyboxes status_bar_notdeathmatch
                  hud_message hud_message_on
                  game_mobj_x game_mobj_y game_mobj_z game_mobj_angle game_mobj_frame game_mobj_sprite
                  game_mobj_flags game_thing_next game_sector_head level_sector_lightlevel].freeze
# THE THINGS THE SPRITE PROJECTION READS, copied up to the tick's high-water mark.
# Game#alloc_mobj hands out slots below @mobj_alloc and recycles freed ones
# there, so [0, mobj_alloc) holds every slot that was ever live and the tail up
# to limit:maxmobjs was never written; a freed slot below the mark holds stale
# data on both sides, which the projection never reads. So the copy is the
# prefix, and what it costs is counted (`copy mobj` line) rather than assumed.
MOBJ_COPY = %w[x y z angle frame sprite flags].freeze
(COPY_BUFFERS - COPY_HANDLED).empty? or
  abort("source-port.rb: copy.tsv names #{(COPY_BUFFERS - COPY_HANDLED).join(' ')}, which boundary_copy does not copy")
$copy_skip = ENV["SOURCE_PORT_COPY_SKIP"].to_s
($copy_skip.empty? || COPY_BUFFERS.include?($copy_skip)) or
  abort("source-port.rb: SOURCE_PORT_COPY_SKIP=#{$copy_skip} is not a buffer the copy carries: #{COPY_BUFFERS.join(' ')}")
($copy_skip.empty? || $furniture || $copy_skip == "textures_flattranslation" ||
 $copy_skip.start_with?("game_mobj_", "game_thing_next", "game_sector_head", "level_sector_lightlevel")) or
  abort("source-port.rb: SOURCE_PORT_COPY_SKIP=#{$copy_skip} is read by the furniture, which SOURCE_PORT_FURNITURE=0 leaves undrawn")
def boundary_copy(tx, sb, g)
  copy = ->(name) { $copy_skip != name }
  if copy.call("textures_flattranslation") && $frame_mode && $plane_ready
    port_load_ints(res("draw-plane", "flattranslation"), tx.instance_variable_get(:@flattranslation))
  end
  if $frame_mode
    n = g.instance_variable_get(:@mobj_alloc)
    $count["mobj-alloc-max"] = n if n > $count["mobj-alloc-max"]
    MOBJ_COPY.each do |f|
      next unless copy.call("game_mobj_#{f}")
      load_prefix(res("leaf-add-sprites", "mobj_#{f}"), g.public_send("mobj_#{f}"), n)
      $count["copy-mobj-cells"] += n
    end
    # the things' links, per thing and so under the same mark, and the sectors'
    # list heads and lights, per sector and so copied whole
    if copy.call("game_thing_next")
      load_prefix(res("leaf-add-sprites", "thing_next"), g.thing_next, n)
      $count["copy-mobj-cells"] += n
    end
    if copy.call("game_sector_head")
      load_prefix(res("leaf-add-sprites", "sector_head"), g.sector_head, g.sector_head.length)
      $count["copy-sector-cells"] += g.sector_head.length
    end
    if copy.call("level_sector_lightlevel")
      ll = g.instance_variable_get(:@level).sector_lightlevel
      load_prefix(res("leaf-add-sprites", "sector_lightlevel"), ll, ll.length)
      $count["copy-sector-cells"] += ll.length
    end
  end
  return unless sb
  ps[ix("draw-statusbar", "i_faceindex")] = sb.instance_variable_get(:@faceindex) if copy.call("status_bar_faceindex")
  load_prefix(res("draw-statusbar", "keyboxes"), sb.instance_variable_get(:@keyboxes), 3) if copy.call("status_bar_keyboxes")
  ps[ix("draw-statusbar", "i_notdeathmatch")] = sb.instance_variable_get(:@notdeathmatch) ? 1 : 0 if copy.call("status_bar_notdeathmatch")
  ps[ix("draw-hud", "i_message")] = $hud.message if copy.call("hud_message")
  ps[ix("draw-hud", "i_message_on")] = $hud.message_on ? 1 : 0 if copy.call("hud_message_on")
end

# THE FURNITURE, DRAWN BY BOTH SIDES AND BY DIFFERENT CODE. The original draws
# the status bar through Doom::StatusBar and the message line through Doom::Hud;
# the port draws the same pixels into its own screen through
# examples/doom/core/src/statusbar.rb and hud.rb, called after the original's
# #draw by the prepends below -- the same shape as the producers inserted into
# render.rb, done with a prepend because the furniture lives in other files and
# the copy only ever patches render.rb.
#
# UNTIL THIS EXISTED THE BAR WAS NEVER COMPARED. Measured in the live comparison
# at frames 0 and 59: of the 64000 bytes it reports per frame, the 10240 below
# the view were ZERO ON BOTH SIDES. They matched because neither side wrote them.
#
# EVERY ROUTE DRAWS IT, through one call site. Each parameter is the storage
# fields.tsv names for the draw-statusbar and draw-hud contexts: on the session
# and adapter routes the resident fields, prepared by Full; on the Ruby and
# compiled routes the lane's own copies below, read off the same objects Full
# reads. The session and adapter routes were bounded at frame 59 until those
# rows existed, because they had nothing to draw with.
#
# health, armorpoints, ammokind and the ammo, maxammo and weaponowned buffers are
# the CALLER'S ARGUMENTS -- the hand-off at the call site, the same mechanism as
# the view's position handed to render_player_view. fields.tsv names them `none`:
# no resident field backs them, and the lane fills its own buffers per call.
if $furniture
  $statusbar = Doom::StatusBar.new(wad)
  $statusbar.start(g.pl_weaponowned)
  $weapon_ammo = Doom::Info.weapon_ammo
  $hud = Doom::Hud.new(wad, r.screenwidth, r.screenheight, 1)
  sbv = ->(n) { $statusbar.instance_variable_get(n) }
  hudv = ->(n) { $hud.instance_variable_get(n) }
  flag = ->(v) { v == true ? 1 : (v == false ? 0 : v) }
  unless SESSION
    # THE LANE'S OWN COPIES of what Full prepares on the session route, read off
    # the same objects: the tables of lump numbers, the prepared scalars as
    # one-element buffers, the widget memory as StatusBar#start leaves it, and the
    # HUD's glyphs and joined messages with where each starts.
    texts = hudv.call(:@texts)
    ofs = [0]
    texts.each { |t| ofs << ofs.last + t.bytesize }
    $furn_tables = {
      "tallnum" => port_i64s(sbv.call(:@tallnum)), "shortnum" => port_i64s(sbv.call(:@shortnum)),
      "armsgray" => port_i64s(sbv.call(:@armsgray)), "faces" => port_i64s(sbv.call(:@faces)),
      "keys" => port_i64s(sbv.call(:@keys)),
      "tallw" => port_i64s([sbv.call(:@tallw)]), "shortw" => port_i64s([sbv.call(:@shortw)]),
      "sbar" => port_i64s([sbv.call(:@sbar)]), "tallpercent" => port_i64s([sbv.call(:@tallpercent)]),
      "armsbg" => port_i64s([sbv.call(:@armsbg)]),
      "old_arms" => port_i64s(sbv.call(:@old_arms)), "old_keybox" => port_i64s(sbv.call(:@old_keybox)),
      "keyboxes" => port_i64s(Array.new(3, 0)),
      "font_lump" => port_i64s(hudv.call(:@font_lump)), "text" => port_bytes(texts.join.b),
      "text_ofs" => port_i64s(ofs), "sw" => port_i64s([hudv.call(:@sw)]), "scale" => port_i64s([hudv.call(:@scale)])
    }
    %w[firsttime old_armsbg old_face].each { |f| ps[ix("draw-statusbar", "i_#{f}")] = flag.(sbv.call(:"@#{f}")) }
  end
  # The per-frame arguments the game computes and the port only reads.
  $sb_ammo = port_i64s(Array.new(4, 0))
  $sb_maxammo = port_i64s(Array.new(4, 0))
  $sb_weaponowned = port_i64s(Array.new(g.pl_weaponowned.length, 0))
  # THE COPY'S TARGETS, POISONED, on every route: a value the original does not
  # hold where the port reads it, so a copy that does not happen shows.
  #
  # POISONED AGAINST THE VALUE AT THE READ, NOT AT THE START. StatusBar#start
  # sets notdeathmatch false, but the ticker sets it TRUE on every frame -- single
  # player is never deathmatch -- and the ticker runs before the copy. A poison of
  # 1 was chosen against the start value, equalled the truth, and made the
  # omitted copy invisible. Measured: skipping it gave zero disagreements.
  #
  # message_on was first poisoned ON, reasoned from its START value -- off until
  # the first pickup. But in DEMO1 the message comes on at frame 60 and pickups
  # keep it on until frame 408, so for most of the frames that matter the
  # original is ON, the poison equalled the truth, and the index poison below
  # made the poisoned-on line empty for the rest. Measured: skipping the copy gave
  # zero disagreements over 400 frames -- eight short of the first frame it could
  # have shown. Poisoned OFF, it shows from frame 60.
  #
  # The index is poisoned to 0, the empty line; a message is never switched on
  # with index 0, so an omitted index copy draws nothing where the original draws
  # text.
  load_prefix(res("draw-statusbar", "keyboxes"), [0, 0, 0], 3)   # the original starts at -1
  ps[ix("draw-statusbar", "i_faceindex")] = 41                    # the original starts at 0
  ps[ix("draw-statusbar", "i_notdeathmatch")] = 0                 # the original holds true here
  ps[ix("draw-hud", "i_message")] = 0
  ps[ix("draw-hud", "i_message_on")] = 0
  SB_BUFS = %w[screen backing wad lump_pos].freeze
  SB_TABLES = %w[old_arms old_keybox keyboxes tallnum shortnum armsgray faces keys
                 tallw shortw sbar tallpercent armsbg].freeze
  SB_CELLS = %w[i_firsttime i_old_armsbg i_old_face i_faceindex i_notdeathmatch].freeze
  HUD_BUFS = %w[screen wad lump_pos font_lump text text_ofs sw scale].freeze
  HUD_CELLS = %w[i_message i_message_on].freeze
  Doom::Hud.prepend(Module.new do
    define_method(:draw) do |screen|
      drew = super(screen)
      st = dc_draw_hud(*HUD_BUFS.map { |p| res("draw-hud", p) }, ps, *HUD_CELLS.map { |p| ix("draw-hud", p) })
      fault("furniture-status", "frame #{$frame} tic #{$tic} hud core status #{st}") unless st == 0
      drew
    end
  end)
  # ONE MIRROR, AT THE OPERATION RATHER THAN AT EACH PRIMITIVE. The kernel
  # refuses a definition inside one entry's closure being called from outside
  # it, so the bar cannot be reached through six entries that share dc_i16 and
  # dc_draw_patch -- it is one operation and one closure. Mirroring at #draw is
  # the same shape: the original draws the bar, then the port draws it.
  Doom::StatusBar.prepend(Module.new do
    define_method(:draw) do |screen, health, armorpoints, ammo, maxammo, weaponowned, readyweapon, ammokind|
      # WHICH OF THE BAR'S RARE BRANCHES THIS FRAME TAKES, read off the
      # original's own state before it draws: the ready weapon's "n/a", and a
      # key box erased because the key it showed changed. A demo that never
      # takes one has not exercised the port's copy of it either.
      $count["sb-na"] += 1 if ammokind < 0 || ammokind >= 4
      old_kb = instance_variable_get(:@old_keybox)
      instance_variable_get(:@keyboxes).each_with_index do |v, i|
        $count["sb-key-erase"] += 1 if v != -1 && old_kb[i] != -1 && (old_kb[i] != v || instance_variable_get(:@firsttime))
      end
      drew = super(screen, health, armorpoints, ammo, maxammo, weaponowned, readyweapon, ammokind)
      load_prefix($sb_ammo, ammo, 4)
      load_prefix($sb_maxammo, maxammo, 4)
      load_prefix($sb_weaponowned, weaponowned, weaponowned.length)
      st = dc_draw_statusbar(*SB_BUFS.map { |p| res("draw-statusbar", p) }, ps,
                             *SB_TABLES.map { |p| res("draw-statusbar", p) },
                             $sb_ammo, $sb_maxammo, $sb_weaponowned,
                             *SB_CELLS.map { |p| ix("draw-statusbar", p) },
                             health, armorpoints, ammokind)
      fault("furniture-status", "frame #{$frame} tic #{$tic} core status #{st}") unless st == 0
      drew
    end
  end)
end
jobs = r.instance_variable_get(:@jobs)
unless ADAPTER # the lane's own copies; a session's fields replace them, and through the adapter they would cost a call per byte
  $cmap = port_bytes(r.instance_variable_get(:@colormap))
  $atlas = port_bytes(tx.tex_atlas)
  $flat = port_bytes(tx.flat_atlas)
  $wad = port_bytes(r.instance_variable_get(:@wad_data))
  # The lump directory as Full prepares it: each entry's position and size, and
  # the lump the zone holds next.
  $lump_pos = port_i64s(Array.new(wad.count) { |i| wad.lump(i).pos })
  $lump_size = port_i64s(Array.new(wad.count) { |i| wad.lump(i).size })
  $next_lump = port_i64s(wad.instance_variable_get(:@next_lump))
  $port_zonewin = port_screen(128)
  exe = r.instance_variable_get(:@exec)
  $fuzzoffset = port_i64s(exe.instance_variable_get(:@fuzzoffset))
  $exec_width, $exec_centery, $exec_vwx, $exec_vwy = %w[@width @centery @viewwindowx @viewwindowy].map { |v| port_i64s([exe.instance_variable_get(v)]) }
  $wall_bank = port_i64s(Array.new(jobs.wall_bank.length, 0))
  $span_bank = port_i64s(Array.new(jobs.span_bank.length, 0))
  $masked_bank = port_i64s(Array.new(jobs.masked_bank.length, 0))
  $sc_kind = port_i64s(Array.new(jobs.sched_kind_bank.length, 0))
  $sc_idx = port_i64s(Array.new(jobs.sched_idx_bank.length, 0))
  $port_ring = port_screen(jobs.zonebuf.bytesize)
  $zone_slots = port_i64s([jobs.instance_variable_get(:@zone_slots)])
  $cap_wall, $cap_span, $cap_masked, $cap_sched = %w[@cap_wall @cap_span @cap_masked @cap_sched].map { |v| port_i64s([jobs.instance_variable_get(v)]) }
end
unless ADAPTER
  $plane_tables = %w[spanstart cachedheight cacheddistance cachedxstep cachedystep yslope distscale xtoviewangle finesine zlight
                     pl_minx pl_maxx pl_picnum pl_height pl_lightlevel pl_top pl_bottom floorclip ceilingclip]
                  .to_h { |t| [t, port_i64s(r.instance_variable_get("@#{t}"))] }
  $plane_tables["flattranslation"] = port_i64s(tx.instance_variable_get(:@flattranslation))
  %w[plw plempty centerxfrac viewwidth viewheight sh].each { |t| $plane_tables[t] = port_i64s([r.instance_variable_get("@#{t}")]) }
  $plane_tables["skyflatnum"] = port_i64s([lv.skyflatnum])
  $plane_tables["tex_widthmask"] = port_i64s(tx.instance_variable_get(:@tex_widthmask))
  $plane_tables["tex_atlas_base"] = port_i64s(tx.instance_variable_get(:@tex_atlas_base))
  $plane_tables["skytexture"] = port_i64s([lv.skytexture])
  %w[pspriteiscale skytexturemid].each { |t| $plane_tables[t] = port_i64s([r.instance_variable_get("@#{t}")]) }
  $jobs_width, $jobs_height = %w[@width @height].map { |v| port_i64s([jobs.instance_variable_get(v)]) }
  $check_tables = %w[xcount xyl xyh ycount yx1 yx2 mcount mlo mhi mseq mfz]
                  .to_h { |t| [t, port_i64s(Array.new(jobs.instance_variable_get("@#{t}").length, 0))] }
end
# The leaves' own copies of what they read, off the session route.
unless SESSION
  $leaf_tables = %w[tantoangle openings ss_first ss_last].to_h { |t| [t, port_i64s(r.instance_variable_get("@#{t}"))] }
  %w[projection resscale sw clipangle two_clipangle].each { |t| $leaf_tables[t] = port_i64s([r.instance_variable_get("@#{t}")]) }
  $leaf_tables["viewangletox"] = port_i64s(r.instance_variable_get(:@viewangletox))
  $leaf_tables["node_bbox"] = port_i64s(lv.node_bbox)
  %w[vs_scale vs_taken vs_sorted vs_mobjflags vs_gx vs_gy vs_gz vs_gzt vs_texturemid vs_x1 vs_x2 vs_startfrac
     vs_xiscale vs_patch vs_cmap scalelight].each { |t| $leaf_tables[t] = port_i64s(r.instance_variable_get("@#{t}")) }
  spr = sp
  { "numframes" => :@numframes, "rotate" => :@rotate, "framebase" => :@framebase, "sprlump" => :@lump,
    "sprflip" => :@flip, "spriteoffset" => :@spriteoffset, "spritewidth" => :@spritewidth,
    "spritetopoffset" => :@spritetopoffset }.each { |t, v| $leaf_tables[t] = port_i64s(spr.instance_variable_get(v)) }
  MOBJ_COPY.each { |f| $leaf_tables["mobj_#{f}"] = port_i64s(Array.new(g.public_send("mobj_#{f}").length, 0)) }
  $leaf_tables["thing_next"] = port_i64s(Array.new(g.thing_next.length, 0))
  $leaf_tables["sector_head"] = port_i64s(Array.new(g.sector_head.length, 0))
  $leaf_tables["sector_lightlevel"] = port_i64s(Array.new(lv.sector_lightlevel.length, 0))
  $leaf_tables["sector_validcount"] = port_i64s(r.instance_variable_get(:@sector_validcount))
  %w[vertex_x vertex_y seg_v1 seg_v2].each { |t| $leaf_tables[t] = port_i64s(lv.public_send(t)) }
  $seg_tables = { "finetangent" => port_i64s(r.instance_variable_get(:@finetangent)) }
  %w[jobmode centery viewwindowx viewwindowy].each { |t| $seg_tables[t] = port_i64s([r.instance_variable_get("@#{t}")]) }
end
# THE RENDERER'S LEAVES, RUN BESIDE THE ORIGINAL AT EACH CALL (frame mode).
# examples/doom/core/src/leaves.rb holds thirteen definitions whose callers are
# not ported yet, so nothing the port draws depends on them and THE SCREEN
# CANNOT SEE THEM: the original computes every pixel from its own copies. Their
# oracle is the call itself. Each call of the original is followed by the port's,
# with the same arguments, and the result and every cell the port writes are
# compared with what the original returned and wrote. (The status bar and the
# HUD were different: those routes draw, so the screen saw them.)
#
# WHAT IS LOADED AND WHAT IS NOT. A value the original's UNPORTED code set --
# the view position and angle, the seg's normal angle and distance, the openings
# cell a clip reads, the solid-seg list the clip walk edits -- is loaded from the
# original before the call, as the planes' lane loads what the unported BSP walk
# built. The visplane records and lastvisplane are NOT loaded: find_plane and
# check_plane are their only writers before the planes are drawn, so the port's
# copies evolve on their own, from the ported clear_planes, and are compared at
# every call. The one exception is a plane's top row, which the unported wall
# loop also marks: check_plane is given the row it reads, as the original had it.
#
# SOURCE_PORT_LEAVES names another leaves.rb for the Ruby route, which is how
# tests/doom-core/leaves-check.sh shows each comparison failing.
# The things' copy targets start poisoned, on every route.
if mode == "frame"
  MOBJ_COPY.each do |f|
    buf = res("leaf-add-sprites", "mobj_#{f}")
    load_prefix(buf, Array.new(buf.length, MOBJ_POISON.fetch(f)), buf.length)
  end
  # an empty list everywhere, a thing with no successor, and a dark sector
  { "thing_next" => -1, "sector_head" => -1, "sector_lightlevel" => 0 }.each do |t, v|
    buf = res("leaf-add-sprites", t)
    load_prefix(buf, Array.new(buf.length, v), buf.length)
  end
end
# These checks run in job mode 2 and the program's default is mode 0;
# tests/doom-core/leaf-modes.rb reads this list, derives every leaves.rb
# definition it reaches, and asserts the original's calls of each are the same
# in both modes -- which is what lets these checks stand for the default.
LEAF_CALLS = %w[pangle pdist sgscale lindex absang clipv segside fplane chplane ssclear crunch chkbbox vssort addspr
                segloop].freeze
def leaf_fault(e, what)
  fault("leaf-disagree", "frame #{$frame} #{e} #{what}")
end
def leaf_call(e)
  $count["leaf:#{e}"] += 1
  yield
rescue StandardError => err
  raise unless defined?(CoreCapacity) && err.is_a?(CoreCapacity)
  leaf_fault(e, "capacity")
  nil
end
def leaf_load(ctx, pairs)
  pairs.each { |p, v| ps[ix(ctx, p)] = v }
end
Doom::Renderer.prepend(Module.new do
  define_method(:point_to_angle) do |px, py|
    want = super(px, py)
    next want unless $frame_mode
    c = "leaf-point-to-angle"
    leaf_load(c, "i_viewx" => @viewx, "i_viewy" => @viewy)
    got = leaf_call("pangle") { dc_point_to_angle(ps, res(c, "tantoangle"), ix(c, "i_viewx"), ix(c, "i_viewy"), px, py) }
    leaf_fault("pangle", "(#{px}, #{py}) port #{got} original #{want}") if got != want
    want
  end
  define_method(:point_to_dist) do |px, py|
    want = super(px, py)
    next want unless $frame_mode
    c = "leaf-point-to-dist"
    leaf_load(c, "i_viewx" => @viewx, "i_viewy" => @viewy)
    got = leaf_call("pdist") do
      dc_point_to_dist(ps, res(c, "tantoangle"), res(c, "finesine"), ix(c, "i_viewx"), ix(c, "i_viewy"), px, py)
    end
    leaf_fault("pdist", "(#{px}, #{py}) port #{got} original #{want}") if got != want
    want
  end
  define_method(:scale_from_global_angle) do |visangle|
    want = super(visangle)
    next want unless $frame_mode
    c = "leaf-scale-from-global-angle"
    leaf_load(c, "i_viewangle" => @viewangle, "i_rw_normalangle" => @rw_normalangle, "i_rw_distance" => @rw_distance)
    got = leaf_call("sgscale") do
      dc_scale_from_global_angle(ps, res(c, "finesine"), res(c, "projection"),
                                 *%w[i_viewangle i_rw_normalangle i_rw_distance].map { |p| ix(c, p) }, visangle)
    end
    leaf_fault("sgscale", "(#{visangle}) port #{got} original #{want}") if got != want
    want
  end
  define_method(:light_index) do |scale|
    want = super(scale)
    next want unless $frame_mode
    got = leaf_call("lindex") { dc_light_index(res("leaf-light-index", "resscale"), scale) }
    leaf_fault("lindex", "(#{scale}) port #{got} original #{want}") if got != want
    want
  end
  define_method(:abs_angle) do |u|
    want = super(u)
    next want unless $frame_mode
    got = leaf_call("absang") { dc_abs_angle(u) }
    leaf_fault("absang", "(#{u}) port #{got} original #{want}") if got != want
    want
  end
  define_method(:clip_value) do |kind, base, x|
    want = super(kind, base, x)
    next want unless $frame_mode
    c = "leaf-clip-value"
    # the one openings cell the call may read, as the unported wall walk left it
    o = res(c, "openings")
    o[base + x] = @openings[base + x] if base + x >= 0 && base + x < o.length
    got = leaf_call("clipv") { dc_clip_value(o, res(c, "viewheight"), kind, base, x) }
    leaf_fault("clipv", "(#{kind}, #{base}, #{x}) port #{got} original #{want}") if got != want
    want
  end
  define_method(:point_on_seg_side) do |x, y, seg|
    want = super(x, y, seg)
    next want unless $frame_mode
    c = "leaf-point-on-seg-side"
    got = leaf_call("segside") { dc_point_on_seg_side(*%w[vertex_x vertex_y seg_v1 seg_v2].map { |p| res(c, p) }, x, y, seg) }
    leaf_fault("segside", "(#{x}, #{y}, #{seg}) port #{got} original #{want}") if got != want
    want
  end
  define_method(:find_plane) do |height, picnum, lightlevel|
    before = @lastvisplane
    want = super(height, picnum, lightlevel)
    next want unless $frame_mode
    c = "leaf-find-plane"
    got = leaf_call("fplane") do
      dc_find_plane(ps, *%w[pl_height pl_picnum pl_lightlevel pl_minx pl_maxx pl_top skyflatnum sw plw plempty].map { |p| res(c, p) },
                    ix(c, "i_lastvisplane"), height, picnum, lightlevel)
    end
    leaf_planes_agree("fplane", c, self, got, want, [want], want == before)
    want
  end
  define_method(:check_plane) do |pl, start, stop|
    before = @lastvisplane
    # plane pl's top row as the unported wall loop left it: it marks the rows it
    # draws there, and check_plane reads them
    row = $frame_mode ? @pl_top[pl * @plw, @plw] : nil
    want = super(pl, start, stop)
    next want unless $frame_mode
    c = "leaf-check-plane"
    pt = res(c, "pl_top")
    row.each_with_index { |v, k| pt[pl * @plw + k] = v }
    got = leaf_call("chplane") do
      dc_check_plane(ps, *%w[pl_height pl_picnum pl_lightlevel pl_minx pl_maxx pl_top plw plempty].map { |p| res(c, p) },
                     ix(c, "i_lastvisplane"), pl, start, stop)
    end
    leaf_planes_agree("chplane", c, self, got, want, [pl, want].uniq, want == before)
    want
  end
  define_method(:clear_clip_segs) do
    want = super()
    next want unless $frame_mode
    c = "leaf-clear-clip-segs"
    leaf_call("ssclear") do
      dc_clear_clip_segs(ps, res(c, "ss_first"), res(c, "ss_last"), res(c, "viewwidth"), ix(c, "i_newend"))
    end
    leaf_segs_agree("ssclear", c, self)
    want
  end
  define_method(:check_bbox) do |n, child|
    want = super(n, child)
    next want unless $frame_mode
    c = "leaf-check-bbox"
    # the view, and the solid-seg list as the unported clip walk has built it
    leaf_load(c, "i_viewx" => @viewx, "i_viewy" => @viewy, "i_viewangle" => @viewangle)
    k = @newend
    load_prefix(res(c, "ss_first"), @ss_first[0, k], k)
    load_prefix(res(c, "ss_last"), @ss_last[0, k], k)
    got = leaf_call("chkbbox") do
      dc_check_bbox(ps, *%w[node_bbox tantoangle clipangle two_clipangle viewangletox ss_first ss_last].map { |p| res(c, p) },
                    *%w[i_viewx i_viewy i_viewangle].map { |p| ix(c, p) }, n, child)
    end
    leaf_fault("chkbbox", "(#{n}, #{child}) port #{got.inspect} original #{want}") if got != (want ? 1 : 0)
    want
  end
  define_method(:sort_vissprites) do
    want = super()
    next want unless $frame_mode
    c = "leaf-sort-vissprites"
    # the sprites the unported projection built: their count and scales
    n = @vis_n
    leaf_load(c, "i_vis_n" => n)
    # the ported projection wrote these scales too; loading them keeps the sort's
    # check apart from the projection's
    load_prefix(res(c, "vs_scale"), @vs_scale[0, n], n)
    leaf_call("vssort") do
      dc_sort_vissprites(ps, *%w[vs_scale vs_taken vs_sorted].map { |p| res(c, p) }, ix(c, "i_vis_n"))
    end
    %w[vs_taken vs_sorted].each do |t|
      pb = res(c, t)
      ob = instance_variable_get("@#{t}")
      bad = (0...n).find { |i| pb[i] != ob[i] }
      leaf_fault("vssort", "#{t}[#{bad}] port #{pb[bad]} original #{ob[bad]}") if bad
    end
    want
  end
  # THE SPRITES' PER-SECTOR WALK, projection included: project_sprite is reached
  # only from add_sprites, so it runs inside the port's add_sprites and is
  # compared once per sector walk -- every vissprite the walk appended -- not once
  # per projection.
  define_method(:add_sprites) do |sec|
    c = "leaf-add-sprites"
    if $frame_mode
      # the frame's validcount, the light and view the unported walk set, and the
      # vissprite count the unported render_player_view resets each frame
      leaf_load(c, "i_validcount" => @validcount, "i_extralight" => @extralight, "i_viewx" => @viewx,
                   "i_viewy" => @viewy, "i_viewz" => @viewz, "i_viewcos" => @viewcos, "i_viewsin" => @viewsin,
                   "i_spritelights" => @spritelights, "i_vis_n" => @vis_n)
    end
    want = super(sec)
    next want unless $frame_mode
    before = ps[ix(c, "i_vis_n")]
    leaf_call("addspr") do
      dc_add_sprites(ps, *%w[sector_validcount sector_lightlevel sector_head thing_next mobj_x mobj_y mobj_z
                             mobj_angle mobj_frame mobj_sprite mobj_flags numframes rotate framebase sprlump
                             sprflip spriteoffset spritewidth spritetopoffset tantoangle projection centerxfrac
                             viewwidth scalelight resscale vs_mobjflags vs_scale vs_gx vs_gy vs_gz vs_gzt
                             vs_texturemid vs_x1 vs_x2 vs_startfrac vs_xiscale vs_patch vs_cmap].map { |p| res(c, p) },
                     *%w[i_validcount i_extralight i_viewx i_viewy i_viewz i_viewcos i_viewsin i_spritelights
                         i_vis_n].map { |p| ix(c, p) },
                     sec)
    end
    n = ps[ix(c, "i_vis_n")]
    if n != @vis_n
      leaf_fault("addspr", "(#{sec}) vis_n port #{n} original #{@vis_n}")
    elsif res(c, "sector_validcount")[sec] != @sector_validcount[sec]
      leaf_fault("addspr", "(#{sec}) sector_validcount port #{res(c, 'sector_validcount')[sec]} original #{@sector_validcount[sec]}")
    elsif ps[ix(c, "i_spritelights")] != @spritelights
      leaf_fault("addspr", "(#{sec}) spritelights port #{ps[ix(c, 'i_spritelights')]} original #{@spritelights}")
    else
      bad = nil
      (before...n).each do |v|
        %w[vs_mobjflags vs_scale vs_gx vs_gy vs_gz vs_gzt vs_texturemid vs_x1 vs_x2 vs_startfrac vs_xiscale vs_patch
           vs_cmap].each do |t|
          a = res(c, t)[v]
          b = instance_variable_get("@#{t}")[v]
          next if a == b
          bad ||= "(#{sec}) #{t}[#{v}] port #{a} original #{b}"
        end
      end
      leaf_fault("addspr", bad) if bad
      $count["leaf-new-vissprite"] += n - before
    end
    want
  end
  define_method(:crunch) do |start, nx|
    c = "leaf-crunch"
    if $frame_mode
      # the list as the unported clip walk left it, loaded before the original edits it
      n = @newend
      load_prefix(res(c, "ss_first"), @ss_first[0, n + 1], n + 1)
      load_prefix(res(c, "ss_last"), @ss_last[0, n + 1], n + 1)
      ps[ix(c, "i_newend")] = n
    end
    want = super(start, nx)
    next want unless $frame_mode
    leaf_call("crunch") { dc_crunch(ps, res(c, "ss_first"), res(c, "ss_last"), ix(c, "i_newend"), start, nx) }
    leaf_segs_agree("crunch", c, self)
    want
  end
end)
# THE WALLS' SEG LOOP, RUN BESIDE THE ORIGINAL AT EACH CALL (frame mode).
# examples/doom/core/src/segs.rb ports render_seg_loop; its caller,
# store_wall_range, is not ported. Before the original's loop the lane loads
# every value store_wall_range set (SEG_CELLS), the job mode the renderer runs,
# and the cells the loop reads over its column range -- the two clip arrays, the
# marked planes' top and bottom rows, the masked column's openings; after it the
# port's loop runs, and every cell it wrote is compared with the original's,
# with the wall jobs it pushed. THE PORT'S PUSHES ARE THE ONES DRAWN: the lane's
# push hook runs inside the original's loop as everywhere else, so the push
# entry is still checked at every push, and then the bank's two counters are set
# back to where the loop began and the port's loop pushes over those records. A
# record it got wrong is the one the port's executor draws, so the recorded
# screens see these.
def seg_load(r, c)
  SEG_CELLS.each { |p, v| x = r.instance_variable_get(v); ps[ix(c, p)] = x == true ? 1 : (x == false ? 0 : x) }
  res(c, "jobmode")[0] = r.job_mode
  jobs = r.instance_variable_get(:@jobs)
  x0 = r.instance_variable_get(:@rw_x)
  x1 = r.instance_variable_get(:@rw_stopx)
  w = r.instance_variable_get(:@plw)
  rows = seg_rows(r, w)
  %w[ceilingclip floorclip].each do |t|
    pb = res(c, t)
    ob = r.instance_variable_get("@#{t}")
    (x0...x1).each { |x| pb[x] = ob[x] }
  end
  %w[pl_top pl_bottom].each do |t|
    pb = res(c, t)
    ob = r.instance_variable_get("@#{t}")
    rows.each { |b| (x0...x1).each { |x| pb[b + x] = ob[b + x] } }
  end
  mc = seg_masked_base(r)
  if mc
    pb = res(c, "openings")
    ob = r.instance_variable_get(:@openings)
    (x0...x1).each { |x| pb[mc + x] = ob[mc + x] }
  end
  { x0: x0, x1: x1, rows: rows, mc: mc, nwall: jobs.nwall, nsched: jobs.nsched, fuzz: r.instance_variable_get(:@dc_fuzz) }
end
# the first cell of each marked plane's row, as the loop indexes it
# After the original's loop, before the port's: the cells the lane's own push and
# the original's producer lines wrote meanwhile -- the counters, the selector --
# are set to what the port's loop must start from. The selector gets a sentinel
# no producer writes, so a loop that sets up no column is seen leaving it.
def seg_prepare_call(c, pre)
  ps[ix(c, "i_nwall")] = pre[:nwall]
  ps[ix(c, "i_nsched")] = pre[:nsched]
  ps[ix(c, "i_dc_srcres")] = SEG_UNSET
  ps[ix(c, "i_dc_srcbase")] = SEG_UNSET
end
def seg_rows(r, w)
  rows = []
  rows << r.instance_variable_get(:@ceilingplane) * w + 1 if r.instance_variable_get(:@markceiling)
  rows << r.instance_variable_get(:@floorplane) * w + 1 if r.instance_variable_get(:@markfloor)
  rows.uniq
end
def seg_masked_base(r)
  return nil if r.instance_variable_get(:@maskedtexture).zero? || !r.instance_variable_get(:@midtexture).zero?
  r.instance_variable_get(:@maskedtexturecol)
end
def seg_loop_agree(r, c, pre, got)
  e = "segloop"
  jobs = r.instance_variable_get(:@jobs)
  pushed = jobs.nwall - pre[:nwall]
  return leaf_fault(e, "drew #{got.inspect} columns, the original pushed #{pushed}") if got != pushed
  # walls never fuzz, by construction (segs.rb); a fuzzing wall would be the port's missing path
  return leaf_fault(e, "the original's loop ran with @dc_fuzz set") if pre[:fuzz]
  SEG_OUT.each do |p|
    want = r.instance_variable_get(:"@#{p.delete_prefix('i_')}")
    return leaf_fault(e, "#{p.delete_prefix('i_')} port #{ps[ix(c, p)]} original #{want}") if ps[ix(c, p)] != want
  end
  # the selector: untouched when no column was set up, else the atlas at the last column's base
  sel = [ps[ix(c, "i_dc_srcres")], ps[ix(c, "i_dc_srcbase")]]
  want = pushed.zero? ? [SEG_UNSET, SEG_UNSET] : [RES_ATLAS, r.instance_variable_get(:@dc_srcbase)]
  return leaf_fault(e, "selector port #{sel.join(',')} original #{want.join(',')}") if sel != want
  x0, x1 = pre.values_at(:x0, :x1)
  %w[ceilingclip floorclip].each do |t|
    pb = res(c, t)
    ob = r.instance_variable_get("@#{t}")
    bad = (x0...x1).find { |x| pb[x] != ob[x] }
    return leaf_fault(e, "#{t}[#{bad}] port #{pb[bad]} original #{ob[bad]}") if bad
  end
  %w[pl_top pl_bottom].each do |t|
    pb = res(c, t)
    ob = r.instance_variable_get("@#{t}")
    pre[:rows].each do |b|
      bad = (x0...x1).find { |x| pb[b + x] != ob[b + x] }
      return leaf_fault(e, "#{t}[#{b + bad}] port #{pb[b + bad]} original #{ob[b + bad]}") if bad
    end
  end
  if pre[:mc]
    pb = res(c, "openings")
    ob = r.instance_variable_get(:@openings)
    bad = (x0...x1).find { |x| pb[pre[:mc] + x] != ob[pre[:mc] + x] }
    return leaf_fault(e, "openings[#{pre[:mc] + bad}] port #{pb[pre[:mc] + bad]} original #{ob[pre[:mc] + bad]}") if bad
    $count["segloop-masked-calls"] += 1
  end
  # every wall job it pushed, record and schedule entry, and the two counters
  pw = res(c, "wall")
  ow = jobs.wall_bank
  (pre[:nwall]...jobs.nwall).each do |i|
    got_rec = (0...7).map { |k| pw[i * 7 + k] }
    return leaf_fault(e, "wall job #{i} port #{got_rec.join(',')} original #{ow[i * 7, 7].join(',')}") if got_rec != ow[i * 7, 7]
  end
  (pre[:nsched]...jobs.nsched).each do |k|
    got_s = [res(c, "sc_kind")[k], res(c, "sc_idx")[k]]
    want_s = [jobs.sched_kind_bank[k], jobs.sched_idx_bank[k]]
    return leaf_fault(e, "schedule #{k} port #{got_s.join(',')} original #{want_s.join(',')}") if got_s != want_s
  end
  counters = [ps[ix(c, "i_nwall")], ps[ix(c, "i_nsched")]]
  return leaf_fault(e, "nwall/nsched port #{counters.join(',')} original #{jobs.nwall},#{jobs.nsched}") if counters != [jobs.nwall, jobs.nsched]
  $count["segloop-columns"] += got
end
Doom::Renderer.prepend(Module.new do
  define_method(:render_seg_loop) do
    next super() unless $frame_mode
    # (block locals are named apart: this block closes over the script's scope)
    sl_ctx = "seg-loop"
    sl_pre = seg_load(self, sl_ctx)
    $in_segloop = true
    begin
      super()
    ensure
      $in_segloop = false
    end
    seg_prepare_call(sl_ctx, sl_pre)
    sl_got = leaf_call("segloop") do
      dc_render_seg_loop(ps, *SEG_BUFS.map { |b| res(sl_ctx, b) },
                         *SEG_CELLS.map { |p, _| ix(sl_ctx, p) }.take(29),
                         *%w[i_dc_x i_dc_yl i_dc_yh i_dc_iscale i_dc_texturemid i_dc_colormap i_dc_srcofs
                             i_dc_srcres i_dc_srcbase i_nwall i_nsched].map { |p| ix(sl_ctx, p) })
    end
    seg_loop_agree(self, sl_ctx, sl_pre, sl_got) unless sl_got.nil?
  end
end)
# A plane call's result, the visplane count, and every cell of the planes it
# may have written. A new plane's top row is compared too: that is where
# clear_plane_top wrote.
def leaf_planes_agree(e, c, r, got, want, planes, created)
  return leaf_fault(e, "returned #{got.inspect}, original #{want}") if got != want
  n = ps[ix(c, "i_lastvisplane")]
  return leaf_fault(e, "lastvisplane port #{n} original #{r.instance_variable_get(:@lastvisplane)}") if n != r.instance_variable_get(:@lastvisplane)
  planes.each do |pl|
    %w[pl_height pl_picnum pl_lightlevel pl_minx pl_maxx].each do |t|
      a = res(c, t)[pl]
      b = r.instance_variable_get("@#{t}")[pl]
      return leaf_fault(e, "#{t}[#{pl}] port #{a} original #{b}") if a != b
    end
  end
  return unless created
  $count["leaf-new-plane:#{e}"] += 1
  w = r.instance_variable_get(:@plw)
  pt = res(c, "pl_top")
  ot = r.instance_variable_get(:@pl_top)
  bad = (0...w).find { |x| pt[want * w + x] != ot[want * w + x] }
  leaf_fault(e, "pl_top[#{want * w + bad}] port #{pt[want * w + bad]} original #{ot[want * w + bad]}") if bad
end
# The solid-seg list: its end, and every entry up to it.
def leaf_segs_agree(e, c, r)
  n = ps[ix(c, "i_newend")]
  want = r.instance_variable_get(:@newend)
  return leaf_fault(e, "newend port #{n} original #{want}") if n != want
  %w[ss_first ss_last].each do |t|
    pb = res(c, t)
    ob = r.instance_variable_get("@#{t}")
    bad = (0...n).find { |i| pb[i] != ob[i] }
    return leaf_fault(e, "#{t}[#{bad}] port #{pb[bad]} original #{ob[bad]}") if bad
  end
end
# push-skip-sched: the schedule entries of the wall pushes go to buffers nothing reads.
$sched_sink = [port_i64s(Array.new(jobs.sched_kind_bank.length, 0)), port_i64s(Array.new(jobs.sched_idx_bank.length, 0))] if control == "push-skip-sched"
# push-cap-low: the port's wall push is given its own capacity buffer, holding 100.
$cap_low = port_i64s([100]) if control == "push-cap-low"
# zone-separate-ring: the producer writes a SECOND ring, which nothing reads.
$zone_separate = port_screen(jobs.zonebuf.bytesize) if control == "zone-separate-ring"
$zone_port = lambda do |queued, lumpnum, off, zb|
  ctx = queued == 1 ? "produce-zone-queued" : "produce-zone-direct"
  where = "#{$src_site} tic #{$tic} lump #{lumpnum} off #{off}"
  base = 0
  if queued == 1
    base = begin
      dc_alloc_zone_window(ps, ix("alloc-zone", "i_nzone"), res("alloc-zone", "zone_slots"))
    rescue NameError, StandardError => e
      raise unless defined?(CoreCapacity) && e.is_a?(CoreCapacity)
      fault("zone-capacity", where)
      -1
    end
    fault("zone-slot-disagree", "#{where} slot #{base} original #{zb}") if base != zb ||
      ps[ix("alloc-zone", "i_nzone")] != jobs.instance_variable_get(:@nzone)
  end
  out = res(ctx, "out")
  out = $zone_separate if queued == 1 && control == "zone-separate-ring"
  if base >= 0
    dc_zone_window_into(res(ctx, "wad"), res(ctx, "lump_pos"), res(ctx, "lump_size"), res(ctx, "next_lump"),
                        out, lumpnum, off, base)
    want = queued == 1 ? jobs.zonebuf.byteslice(zb, 128) : r.instance_variable_get(:@zonewin)
    fault("zone-disagree", where) if (0...128).map { |k| out[base + k] } != want.bytes
  end
  $count["zone-windows"] += 1
end

n = [tics, demo.numtics].min
t = 0
failed = nil
begin
while t < n
  $tic = t
  rnd.tic = t
  320.times { rnd.m_random } if t == 2
  g.g_ticker(demo.forwardmove[t], demo.sidemove[t], demo.angleturn[t], demo.buttons[t])
  # ST_Ticker draws M_Random once a tic. The recorder (sim_demo.rb) and the
  # playable program (doom.rb) keep the value for the status bar's ticker; this
  # used to discard it, because nothing here ran the ticker.
  st_randomnumber = rnd.m_random
  # THE TICKERS, at the place the other two programs run them: G_Ticker's order
  # is P_Ticker, ST_Ticker, AM_Ticker, HU_Ticker. They write the status bar's and
  # the HUD's own state. Until they ran here, faceindex and the key boxes never
  # changed, so the branches that draw them could not be reached in this harness
  # at any length -- a pass that could not fail, inside a definition that passed
  # as a whole.
  if $furniture
    m = g.player_mo
    atk = g.pl_attacker
    kind = atk < 0 ? Doom::StatusBar::ATTACKER_NONE :
           (atk == m ? Doom::StatusBar::ATTACKER_SELF : Doom::StatusBar::ATTACKER_OTHER)
    bga = atk >= 0 ? g.point_to_angle2(g.mobj_x[m], g.mobj_y[m], g.mobj_x[atk], g.mobj_y[atk]) : 0
    $statusbar.ticker(st_randomnumber, g.pl_health, g.pl_weaponowned, g.pl_cards,
                      g.pl_damagecount, g.pl_bonuscount, g.pl_attackdown,
                      g.pl_powers[0], kind, bga, g.mobj_angle[m])
    $hud.ticker(g.take_message)
    # THE BOUNDARY COPY. Step has written everything it will write this frame and
    # render has read nothing yet: this is the gap that already holds
    # set_psprite and extralight= below, and the copy is the same job at a
    # different width. It carries the step-written state a PORTED reader needs
    # into the port's own buffers -- today the three the status bar entry reads.
    # A buffer enters here in the same commit as its first CORE reader, so every
    # buffer in the copy has something that goes wrong without it.
  end
  boundary_copy(tx, $furniture ? $statusbar : nil, g)
  r.clear_screen if t == 0
  r.set_psprite(g.psp_state[0], g.psp_sx[0], g.psp_sy[0])
  r.set_psprite_flash(g.psp_state[1], g.psp_sx[1], g.psp_sy[1])
  r.extralight = g.extralight
  r.render_player_view(g.viewx, g.viewy, g.viewz, g.viewangle)
  # D_Display's order after the view: ST_Drawer, then HU_Drawer. THE ORIGINAL
  # DRAWS THE BAR AND THE PORT DRAWS IT TOO, by different code -- the original
  # through Doom::StatusBar, the port through src/statusbar.rb at the same sites
  # (the prepend below). Until this existed neither side wrote the 10240 bytes
  # under the view and they matched because they were both zero; now the frame
  # comparison covers them.
  if $furniture
    ak = $weapon_ammo[g.pl_readyweapon]
    $statusbar.draw(r.screen, g.pl_health, g.pl_armorpoints, g.pl_ammo, g.pl_maxammo,
                    g.pl_weaponowned, g.pl_readyweapon, ak)
    # HU_Drawer after ST_Drawer. The message line is at y = 0, inside the view,
    # which is why the recorded oracle stopped at frame 59 until this drew it.
    $hud.draw(r.screen)
  end
  end_of_frame(r) if $frame_mode
  t += 1
end
rescue StandardError => e
  raise unless ADAPTER && e.is_a?(AdapterRoute::SessionFailed)
  failed = e.message
end

# From here the report is being printed: an abort after this point leaves a
# partial key map, which the record must not offer as a refusal or a result.
$rec_started = true
pre_port, pre_original = pre.join(" "), pre_orig.join(" ")
puts "producers added #{producers} markers #{markers} pre-tick port #{pre_port} original #{pre_original}"
# What was played, stated, so a run over one demo cannot read as a run over all.
puts "demo #{DEMO_NAME} map #{demo.mapname} tics #{demo.numtics}"
rec("run.demo" => DEMO_NAME, "run.map" => demo.mapname, "run.demo_tics" => demo.numtics)
rec("run.producers" => producers, "run.markers" => markers,
    "run.pre_port" => pre_port, "run.pre_original" => pre_original)
if mode == "direct"
  puts "tics #{n} columns #{$count['columns']} spans #{$count['spans']}"
  rec("run.tics" => n, "run.columns" => $count["columns"], "run.spans" => $count["spans"])
  kinds = %w[producer-disagree unreadable-selector pixel-mismatch]
else
  # `frames` is the truncation key: a run that ended early says so here.
  nframes = ($frame || -1) + 1
  reset_cells = "#{RESET_ZERO.length}+#{RESET_ONE.length}"
  puts "frames #{nframes} wall-jobs #{$count['wall-jobs']} span-jobs #{$count['span-jobs']} " \
       "masked-jobs #{$count['masked-jobs']} zone-jobs #{$count['zone-jobs']} resets #{$count['resets']} of #{reset_cells} cells"
  rec("run.frames" => nframes, "run.wall_jobs" => $count["wall-jobs"], "run.span_jobs" => $count["span-jobs"],
      "run.masked_jobs" => $count["masked-jobs"], "run.zone_jobs" => $count["zone-jobs"],
      "run.resets" => $count["resets"], "run.reset_cells" => reset_cells)
  kinds = %w[job-disagree unreadable-selector pixel-mismatch reset-disagree]
  if mode == "frame"
    puts "frame pushes wall #{$count['pushes-wall']} masked #{$count['pushes-masked']} marks #{$count['marks']} checks #{$count['checks']}"
    rec("pushes.wall" => $count["pushes-wall"], "pushes.masked" => $count["pushes-masked"],
        "pushes.marks" => $count["marks"], "pushes.checks" => $count["checks"])
    loaded = "#{LOADED_CELLS.map { |p, _| p.delete_prefix('i_') }.join(' ')} lastvisplane " \
             "#{LANE_LOADED_FIELDS.map { |f| f.sub(/\A(renderer|textures)_/, '') }.join(' ')} pl_top"
    puts "frame planes: drawn #{$count['planes']} (sky #{$count['sky-planes']}) spans emitted #{$count['spans-emitted']} sky columns #{$count['sky-columns']} (sky planes with columns #{$count['sky-planes-with-columns']}) sky planes recognized by the port #{$count['sky-planes-recognized']} planes compared #{$count['planes-compared']} sentinels compared #{$count['sentinels']} clears #{$count['plane-clears']}; " \
         "loaded from the original #{loaded}"
    rec("planes.drawn" => $count["planes"], "planes.sky" => $count["sky-planes"],
        "planes.spans_emitted" => $count["spans-emitted"], "planes.sky_columns" => $count["sky-columns"],
        "planes.sky_planes_with_columns" => $count["sky-planes-with-columns"],
        "planes.sky_planes_recognized" => $count["sky-planes-recognized"],
        "planes.compared" => $count["planes-compared"],
        "planes.sentinels" => $count["sentinels"], "planes.clears" => $count["plane-clears"],
        "planes.loaded" => loaded)
    # The two field lists are shared with the record, so a field can be added to
    # the line only by adding its key.
    cl_loaded = %w[lastvisplane lastopening floorplane ceilingplane floorclip ceilingclip]
    cl_mismatch = %w[lastvisplane lastopening floorplane ceilingplane basexscale baseyscale floorclip ceilingclip cachedheight]
    puts "clears #{$count['plane-clears']}: the port loaded with the original's pre-clear values, differing from what clear_planes writes at " +
         cl_loaded.map { |k| "#{k}=#{$clear_loaded[k]}" }.join(" ") +
         "; mismatches after the port's clear " + cl_mismatch.map { |k| "#{k}=#{$clear_mismatch[k]}" }.join(" ")
    rec("clears.count" => $count["plane-clears"])
    cl_loaded.each { |k| rec("clears.loaded.#{k}" => $clear_loaded[k]) }
    cl_mismatch.each { |k| rec("clears.mismatch.#{k}" => $clear_mismatch[k]) }
    stats_text = $check_stats.map { |k, v| "#{k}=#{v}" }.join(" ")
    puts "frame check statistics reached " + stats_text + " slots compared #{$count['check-slots']}"
    # A truncated session reaches no statistic, so these keys are present only
    # when the line names them; the text the line printed is a key of its own,
    # and is the same string, not a second rendering of it.
    $check_stats.each { |k, v| rec("checks.#{k}" => v) }
    rec("checks.stats_text" => stats_text, "checks.slots_compared" => $count["check-slots"])
    if $golden
      puts "frames compared against the recording #{$count['golden-frames']}, full screen agreeing #{$count['golden-full-agree']}"
      rec("golden.frames" => $count["golden-frames"], "golden.full_agree" => $count["golden-full-agree"])
    end
    if $furniture
      puts "screens compared at the end of the frame #{$count['screens-end']}"
      rec("furniture.screens_end" => $count["screens-end"])
    end
    # How often each leaf ran beside the original, and how many of the plane
    # calls made a new plane (where clear_plane_top wrote): a leaf that never ran
    # was compared on nothing.
    puts "leaves calls " + LEAF_CALLS.map { |e| "#{e}=#{$count["leaf:#{e}"]}" }.join(",") +
         " new-planes fplane=#{$count['leaf-new-plane:fplane']},chplane=#{$count['leaf-new-plane:chplane']}"
    LEAF_CALLS.each { |e| rec("leaves.#{e}" => $count["leaf:#{e}"]) }
    # What the things' copy cost: the high-water mark it copied up to, and the
    # cells it wrote, over the run.
    puts "copy mobj alloc-max #{$count['mobj-alloc-max']} cells #{$count['copy-mobj-cells']} new-vissprites #{$count['leaf-new-vissprite']}"
    puts "copy sectors cells #{$count['copy-sector-cells']}"
    # What the seg loop's check compared: the columns it pushed (each pushed by
    # the original's loop too), the calls that wrote a masked column's openings,
    # and the original's pushes inside the loop, which the lane left to the port.
    puts "segloop columns #{$count['segloop-columns']} masked-calls #{$count['segloop-masked-calls']} " \
         "original-pushes #{$count['segloop-original-pushes']}"
    rec("segloop.columns" => $count["segloop-columns"], "segloop.masked_calls" => $count["segloop-masked-calls"],
        "segloop.original_pushes" => $count["segloop-original-pushes"])
    rec("copy.sector_cells" => $count["copy-sector-cells"])
    rec("copy.mobj_alloc_max" => $count["mobj-alloc-max"], "copy.mobj_cells" => $count["copy-mobj-cells"],
        "leaves.new_vissprites" => $count["leaf-new-vissprite"])
    rec("leaves.new_planes.fplane" => $count["leaf-new-plane:fplane"],
        "leaves.new_planes.chplane" => $count["leaf-new-plane:chplane"])
    puts "furniture drawn #{$furniture ? 'yes' : 'no'}"
    if $furniture
      puts "furniture branches na #{$count['sb-na']} key-erase #{$count['sb-key-erase']}"
      rec("furniture.na" => $count["sb-na"], "furniture.key_erase" => $count["sb-key-erase"])
    end
    rec("furniture.drawn" => $furniture ? "yes" : "no")
    # A SKIPPED COPY IS JUDGED BY WHERE IT FIRST SHOWS, not only by whether it
    # does: the earliest frame any live comparison disagreed at, beside the
    # frame copy.tsv expects.
    unless $copy_skip.empty?
      shown = %w[frame-disagree plane-disagree screen-disagree leaf-disagree].filter_map { |k| $first_at[k]&.first }.min
      puts "copy skipped #{$copy_skip} first disagreement frame #{shown || 'none'} " \
           "expected #{COPY_ROWS.to_h.fetch($copy_skip)}"
      rec("copy.skipped" => $copy_skip, "copy.first_frame" => shown || -1,
          "copy.expected" => COPY_ROWS.to_h.fetch($copy_skip))
    end
    puts "frame executor runs #{$count['frames-run']} jobs #{$count['jobs-run']} fuzz-columns #{$count['fuzz-columns']} screens compared #{$count['frames-run']} x #{r.screen.bytesize} bytes"
    rec("exec.runs" => $count["frames-run"], "exec.jobs" => $count["jobs-run"],
        "exec.fuzz_columns" => $count["fuzz-columns"], "exec.screens" => $count["frames-run"],
        "exec.screen_bytes" => r.screen.bytesize)
    kinds = %w[job-disagree reset-disagree push-disagree push-capacity phase-disagree clear-disagree plane-disagree
               check-disagree check-capacity frame-disagree fuzz-count-disagree
               furniture-status screen-disagree leaf-disagree]
    # Only where a recording is named: without one nothing can raise it, and a
    # zero printed for a comparison that never ran is a count asserting nothing.
    kinds += %w[golden-disagree] if $golden
  end
end
site_keys = $count.keys.grep(/\Asite:/).sort
puts "sites " + site_keys.map { |k| s = k.delete_prefix("site:"); "#{s}=#{$count[k]}@#{$site_first[s]}" }.join(",")
site_keys.each do |k|
  s = k.delete_prefix("site:")
  rec("sites.#{s}.count" => $count[k], "sites.#{s}.first" => $site_first[s])
end
puts "masked remaining wad-min #{$rem['wad-min'] || '-'} zone-max #{$rem['zone-max'] || '-'} zone-windows #{$count['zone-windows']}"
rec("remaining.wad_min" => $rem["wad-min"] || "-", "remaining.zone_max" => $rem["zone-max"] || "-",
    "remaining.zone_windows" => $count["zone-windows"])
kinds += %w[zone-disagree zone-slot-disagree zone-capacity]
kinds += %w[native-status] if NATIVE
kinds += %w[slot-disagree] if SESSION
if NATIVE
  native_keys = $count.keys.grep(/\Anative:/).sort
  puts "native calls " + native_keys.map { |k| "#{k.delete_prefix('native:')}=#{$count[k]}" }.join(",")
  native_keys.each { |k| rec("native.#{k.delete_prefix('native:')}" => $count[k]) }
end
# One `kinds` list drives the counts, the first failures and their keys.
puts "faults " + kinds.map { |k| "#{k} #{$faults[k]}" }.join(" ")
kinds.each { |k| rec("faults.#{k}" => $faults[k]) }
kinds.each do |k|
  where = $first[k] || "none"
  puts "first #{k} #{where}"
  # The verbatim text keeps exact parity with the pins; the frame and tic are
  # taken from where the fault was raised, not parsed back out of the text.
  # Splitting field, port and original out of the text is stage 2's (0009 item 1).
  # They go under `first_at.` rather than under `first.<kind>.`, which is a
  # string of its own and cannot also be the parent of two numbers.
  rec("first.#{k}" => where)
  at = $first_at[k]
  next unless at
  # A kind raised outside a frame records -1, the same "not here" spelling the
  # report lines use; the record holds no nulls. THE SITE IS NOT RECORDED as a
  # key: `$src_site` is the last source site the run passed, which for a kind
  # raised away from one -- clear, plane, frame, check -- names a site that has
  # nothing to do with the fault. The kinds that do have a site carry it inside
  # the verbatim text above.
  rec("first_at.#{k}.frame" => at[0] || -1, "first_at.#{k}.tic" => at[1] || -1)
end
if SESSION && !failed
  s = $session
  core = s[:core]
  names = s[:session].slots.invert
  puts "session fields #{s[:natives].length} pre-tick " + $rep_slots.each_with_index.map { |(f), i| "#{f}=#{s[:pre][i]}" }.join(" ")
  rec("session.fields" => s[:natives].length)
  $rep_slots.each_with_index { |(f), i| rec("session.pre.#{f}" => s[:pre][i]) }
  if mode == "direct"
    held = $rep_slots.map { |_f, w, p, idx| core[idx] == Doom::Core::Resources::SourceSelect.new(r, w, p).value }
    puts "session selector slots hold the original's converted choice at the end #{held.all? ? 'yes' : 'no'}"
    rec("session.selectors_held" => held.all? ? "yes" : "no")
  end
  # The selector slots, the ring's counter the allocator writes, and the cells
  # Jobs#reset writes.
  rep_idx = $rep_slots.map(&:last) + $written_slots
  after = core.bytes
  changed = (0...core.count).reject { |i| rep_idx.include?(i) }
                            .select { |i| after.byteslice(i * 8, 8) != s[:core_before].byteslice(i * 8, 8) }
  puts "session other core_state slots changed #{changed.length}" + (changed.empty? ? "" : " first #{names[changed.first]}")
  rec("session.other_slots_changed" => changed.length,
      "session.other_slots_first" => changed.empty? ? "-" : names[changed.first])
  # Through the adapter a field is read back one call per element, so there the
  # fields longer than 65536 elements are not read back, and the line says so.
  compared = s[:in_fields].select { |f| !ADAPTER || s[:natives][f].count <= 65_536 }
  moved = compared.reject { |f| s[:natives][f].bytes == s[:session].id(f).store }
  puts "session read-only fields changed #{moved.length} of #{compared.length}" +
       (compared.length == s[:in_fields].length ? "" : " read back, of #{s[:in_fields].length}") +
       (moved.empty? ? "" : " first #{moved.first}")
  rec("session.readonly_changed" => moved.length, "session.readonly_read_back" => compared.length,
      "session.readonly_total" => s[:in_fields].length,
      "session.readonly_first" => moved.empty? ? "-" : moved.first)
end
if ADAPTER
  # Whether the session failed is recorded on both paths, so that an expectation
  # never has to read "the key is missing" as "the session was fine".
  rec("adapter.session_failed" => failed || "-")
  if failed
    # THE SESSION FAILED AT ITS FIRST REFUSED STEP: nothing after it was invoked,
    # and no buffer is read back -- the end-of-run checks above were not run.
    puts "adapter session failed at #{failed}: no further invoke, no poisoned buffer read"
  else
    # THE LIFECYCLE, as a diagnostic after a session that succeeded. A refused
    # invoke POISONS its MUTABLE participants and leaves its read-only ones: a
    # column naming a selector cell past core_state is refused, and then its
    # screen refuses a load and any step naming it, while the state and the
    # colormap it only read still load.
    core = $session[:core]
    ctx = mode == "direct" ? "direct-column" : "queued-wall"
    scr, cm, at, wd, zw = %w[scr cmap atlas wad zonewin].map { |p| res(ctx, p) }
    bad, = AdapterRoute.invoke(:col, AdapterRoute::TYPES[:col], scr.id, cm.id, at.id, wd.id, zw.id, core.id,
                               core.count, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0)
    scr_load = AdapterRoute.load(scr.id, 0)
    cm_load = AdapterRoute.load(cm.id, 0)
    state_load, = AdapterRoute.load_i64(core.id, 0)
    again, = AdapterRoute.invoke(:col, AdapterRoute::TYPES[:col], scr.id, cm.id, at.id, wd.id, zw.id, core.id,
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0)
    puts "adapter a refused column answers #{bad}; its screen then answers a load #{scr_load} and a step #{again}; " \
         "its read-only colormap and state still load #{cm_load >= 0 ? 'yes' : cm_load} #{state_load}"
    rec("adapter.refused_column_answers" => bad, "adapter.screen_load" => scr_load, "adapter.screen_step" => again,
        "adapter.readonly_colormap" => cm_load >= 0 ? "yes" : cm_load.to_s, "adapter.readonly_state" => state_load)
    # ONE ID IS NOT TWO PARTICIPANTS: core_state as the reset's state and as its
    # table is refused before the kernel runs.
    dup, = AdapterRoute.invoke(:jreset, AdapterRoute::TYPES[:jreset], core.id, core.id, 0)
    puts "adapter core_state passed as both the reset's state and its table answers #{dup}"
    rec("adapter.duplicate_participant" => dup)
  end
  allocated, released, leaked = AdapterRoute.release_all
  puts "adapter ids allocated #{allocated}, released once #{released}, " +
       (leaked.empty? ? "every id then refuses a second release" : "a second release is accepted by #{leaked.join(',')}, never released")
  rec("adapter.ids_allocated" => allocated, "adapter.ids_released_once" => released,
      "adapter.second_release" => leaked.empty? ? "refused" : leaked.join(","))
  adapter_failed = failed || !leaked.empty?
end
# The report is complete: an exit from here on is a result, not a refusal.
$rec_reported = true
exit 1 if adapter_failed
