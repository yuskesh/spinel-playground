# frozen_string_literal: true
#
# tests/doom-core/route-prep.rb — the session a route runs over, prepared once.
#
# Two lanes take the same three steps between the objects Full constructs and
# the session the route opens: tests/doom-core/route-demo.rb (a recorded demo)
# and tests/doom-core/native-scenario-diff.rb (a synthesised scenario). The
# steps are
#
#   * the catalog THIS map and THIS key script measure -- a different map is a
#     different catalog (examples/doom/core/catalog.tsv's header);
#   * the layout generated from it, each prepared row's length being what Full
#     produced, which tools/doom/state-schema.rb then checks against the count
#     the measured catalog gives the field;
#   * the session opened over Full's prepared bytes, with core_state built from
#     the generated slots.
#
# They are here rather than in each lane because a difference between the two
# would be a difference in what the compared state IS, and the lane that
# drifted would be the one nobody re-read.
module RoutePrep
  WIDTH = { "u8" => 1, "i8" => 1, "u16" => 2, "i16" => 2, "i32" => 4, "u32" => 4, "i64" => 8 }.freeze

  # Answers the opened session. `work` receives catalog.tsv, full-catalog.tsv
  # and gen/ (buffers.tsv, slots.tsv, snapshot.tsv); `label` names the caller in
  # a diagnosis, so a refusal says which lane could not prepare.
  def self.session(root:, work:, wad:, map:, script:, objects:, label:)
    Dir.mkdir(work) unless Dir.exist?(work)
    Doom::Core::Resources.write_catalog(
      Doom::Core::Resources.catalog(wad: wad, map: map, width: 320, height: 200, script: script),
      File.join(work, "catalog.tsv"))
    made, unsupported, = Doom::Core::Resources.prepared(
      acquired: File.join(root, "tools/doom/core-acquired.tsv"),
      schema: File.join(root, "examples/doom/core/state.tsv"), objects: objects)
    unsupported.empty? or abort("#{label}: Full cannot prepare #{unsupported.map(&:first).first(5).join(', ')}")

    element = {}
    File.foreach(File.join(root, "examples/doom/core/state.tsv")) do |l|
      next if l.start_with?("#")
      f = l.chomp.split("\t")
      element[f[4].delete_prefix("prepared:")] = f[2] if f[4].to_s.start_with?("prepared:")
    end
    rows = File.readlines(File.join(root, "examples/doom/core/prepared.tsv"))
               .reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.split("\t")[1] }.map do |name|
      bytes = made.fetch(name) { abort("#{label}: Full did not prepare #{name}") }.bytesize
      "prepared\t#{name}\t#{bytes / WIDTH.fetch(element.fetch(name))}\n"
    end
    File.write(File.join(work, "full-catalog.tsv"), File.read(File.join(work, "catalog.tsv")) + rows.join)
    system(RbConfig.ruby, File.join(root, "tools/doom/state-schema.rb"),
           "--schema", File.join(root, "examples/doom/core/state.tsv"),
           "--access", File.join(root, "examples/doom/core/access.tsv"),
           "--catalog", File.join(work, "full-catalog.tsv"), "--output", File.join(work, "gen"),
           out: File.join(work, "gen.out"), err: File.join(work, "gen.err")) or
      abort("#{label}: the layout did not generate; see #{work}/gen.err")

    buffers = File.join(work, "gen", "buffers.tsv")
    slots = File.join(work, "gen", "slots.tsv")
    count = Doom::Core::Session.read_buffers(buffers).find { |r| r["name"] == "core_state" }["count"]
    made["core_state"] = Doom::Core::Resources.core_state(slots: slots, count: count, prepared: made)
    Doom::Core::Session.open(buffers: buffers, slots: slots, prepared: made)
  end
end
