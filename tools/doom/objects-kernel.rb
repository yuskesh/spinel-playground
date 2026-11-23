# frozen_string_literal: true
#
# tools/doom/objects-kernel.rb — reused entry objects were built by this kernel.
#
#   ruby tools/doom/objects-kernel.rb --kernel PATH DIR [DIR ...]
#
# A lane that reuses a previous run's entries (rt1186.sh's THUMB_BUILD and
# CORE_BUILD, rt1186-profile.sh's LANE_DIR) would otherwise measure objects an
# older kernel made, under the current tree's name: on 2026-10-21 a profile and
# a board run on the M7 used objects built before 62975d3, and their numbers
# did not include it. Each DIR must say which kernel built its objects, and it
# must be the sha256 of --kernel:
#
#   * the three entries' report_<entry>.json, each with tools.kernel.sha256
#     (the thumb objects, built with --report); or
#   * kernel.sha256, one digest (the host objects of
#     tests/doom-core/harness/artifacts.sh's dc_core_entries, built without
#     a report).
#
# Otherwise it prints what each names against the kernel given, and exits 1.
# A DIR with neither is refused too: nothing there says which kernel built it.
require "digest"
require "json"
require "optparse"

ENTRIES = %w[doom_core_input doom_core_step doom_core_render].freeze
kernel = nil
OptionParser.new { |o| o.on("--kernel PATH") { |v| kernel = v } }.parse!
abort("objects-kernel: --kernel is required") unless kernel
abort("objects-kernel: no directory given") if ARGV.empty?
abort("objects-kernel: no kernel at #{kernel}") unless File.file?(kernel)
want = Digest::SHA256.file(kernel).hexdigest
bad = []
checked = 0
ARGV.each do |dir|
  stamp = File.join(dir, "kernel.sha256")
  if Dir[File.join(dir, "report_*.json")].empty? && File.file?(stamp)
    got = File.read(stamp).strip
    bad << "#{stamp}: built by kernel #{got}, but the kernel is #{want} (#{kernel})" unless got == want
    checked += 1
    next
  end
  ENTRIES.each do |e|
    path = File.join(dir, "report_#{e}.json")
    unless File.file?(path)
      bad << "#{path}: no report, so nothing says which kernel built #{e}.o"
      next
    end
    got = JSON.parse(File.read(path)).dig("tools", "kernel", "sha256")
    bad << "#{path}: built by kernel #{got || '(none named)'}, but the kernel is #{want} (#{kernel})" unless got == want
    checked += 1
  end
end
if bad.empty?
  puts "objects-kernel: #{checked} record(s) name the kernel #{want}"
else
  bad.each { |b| puts "objects-kernel: #{b}" }
  exit 1
end
