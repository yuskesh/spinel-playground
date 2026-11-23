# frozen_string_literal: true
#
# tests/doom-core/route-lane.rb — what the route's checkpoints compare.
#
# Loaded by route-demo.rb (the route's side) and route-reference.rb (the
# original's side), so both write the same rows in the same order.
#
# A CHECKPOINT `T` is the state before tic T's step: after the frame of tic
# T-1, or at session open when T is 0. Its rows are the generated layout's
# (tools/doom/state-schema.rb's snapshot.tsv, which already leaves scratch out),
# re-offset from zero, less the cells below after session open.
#
# COMPARED AT SESSION OPEN ONLY: the state lane's category, approved by
# The macOS coordinator on 2026-09-17 with three conditions (the claim stated with its
# measurement; the cells named, not a mode; a wrong value at session open
# fails). These three cells, and no others, leave the rows after session open.
# At session open they are compared like every other field, in both modes,
# through the same conversion (resources.rb's SourceSelect, reference.rb).
#
# THE MEASUREMENT, 2026-09-17, every frame of DEMO1-3 (10996) in job mode 1:
#
#   ruby tests/doom-core/render-diff.rb WAD DEMOn 100000 --stop-after 100000 \
#     --exclude-only core_frame
#
# Taken at 521bd07 with a copy of render-diff.rb whose only differences were that
# list and its ROOT (the option came after), and repeated with the option on the
# landing tree; its summary line names each field that
# disagreed with its frame count, and the per-tic lines give the values:
#   renderer_dc_srcres   38 frames differ (DEMO1 29, DEMO2 5, DEMO3 4): the port
#                        22 times 0 against the original's 1, 16 times 0
#                        against 2
#   renderer_ds_srcres   743 frames (361, 251, 131) of "changed in the original,
#                        and the port does not take it": the port does not
#                        write the cell
#   renderer_dc_srcofs   0 frames differ   -- compared after frames
#   renderer_dc_srcbase  0 frames differ   -- compared after frames
# and every other field agreed on every frame. renderer_ds_srcbase is the base
# half of @ds_source, which render-diff cannot read as it stands; this lane
# records it, with the other two, at every checkpoint after session open:
# route-demo.rb and route-reference.rb write each side's values
# (route-T.open-only.tsv, original-T.open-only.tsv), and verify.sh prints both,
# marking the pairs that differ (OPEN_ONLY lines).
SESSION_OPEN_ONLY = {
  "renderer_dc_srcres" =>
    "The port sets the column selector on every path (source.rb, EVERY PRODUCER SETS BOTH; the " \
    "wall path's RES_ATLAS in rvcopies.rb's dc_rv_sl_src_texture_column), and job mode 1's " \
    "original only on the masked path, so after a wall column the two hold different values. " \
    "In job mode 1 the port reads it only in dc_rv_emit_column's masked branch, reached from " \
    "dc_rv_draw_masked_column after that call has written it; what it selects is compared " \
    "where it lands, in the masked job bank and on the screen.",
  "renderer_ds_srcres" =>
    "A dead store in job mode 1 (entries/not-taken.tsv): the original sets @ds_source for every " \
    "plane and reads it only on the direct path; the port does not write it.",
  "renderer_ds_srcbase" =>
    "The base half of the same dead store (entries/not-taken.tsv)."
}.freeze

module RouteLane
  def self.rows(layout_path, checkpoint)
    at = 0
    File.readlines(layout_path).filter_map do |ln|
      next if ln.start_with?("#") || ln.strip.empty?
      f = ln.chomp.split("\t", -1)
      next if checkpoint.positive? && SESSION_OPEN_ONLY.key?(f[0])
      row = { "field" => f[0], "element" => f[1], "count" => Integer(f[2], 10),
              "bytes" => Integer(f[3], 10), "offset" => at }
      at += row["bytes"]
      row
    end
  end

  # The rows as a layout file tests/doom-core/compare-state.rb reads.
  def self.write_layout(rows, path)
    File.write(path, "#field\telement\tcount\tbytes\toffset\n" +
                     rows.map { |r| r.values_at("field", "element", "count", "bytes", "offset").join("\t") + "\n" }.join +
                     "#total\t-\t-\t#{rows.sum { |r| r['bytes'] }}\t-\n")
  end

  def self.checkpoints(arg) = arg.split(",").map { |v| Integer(v, 10) }.sort.uniq

  # One OPEN_ONLY line per cell: what a side holds there, for the record.
  def self.write_open_only(values, path)
    File.write(path, SESSION_OPEN_ONLY.keys.map { |f| "#{f}\t#{values.fetch(f)}\n" }.join)
  end
end
