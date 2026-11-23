# tests/gcmon/probe_noninvasive.rb — the probe does not disturb what it watches.
#
#   ruby tests/gcmon/probe_noninvasive.rb        # macOS only (DYLD interposition)
#
# The same source is built two ways and both counters' COUNTS must agree:
#
#   probe on   SPINEL_EXTERN_METHODS + gcmon_probe.o linked (the probe runs)
#   probe off  plain Ruby methods (gcmon_begin/end just return the id)
#
# Both binaries are built by this repository's pinned Spinel; this is the
# instrument checked against itself, not against another implementation.
#
# The two binary paths have the SAME length: malloc's `bytes` reacts to argv
# and environment length. Counts do not move, so the verdict uses counts; bytes
# are checked as well, which holds only because the lengths are equal.
require "open3"
require "tmpdir"

ROOT   = File.expand_path("../..", __dir__)
SPINEL = ENV["SPINEL"] || File.join(ROOT, "vendor/spinel/bin/spinel")
CC     = ENV["CC"] && !ENV["CC"].empty? ? ENV["CC"] : "cc"
PROBE  = File.join(ROOT, "tools/gcmon/gcmon_probe.c")
MALLOC = File.join(ROOT, "tools/gcmon/malloc_count.c")

abort "no spinel at #{SPINEL}" unless File.executable?(SPINEL)
unless RUBY_PLATFORM.include?("darwin")
  puts "---- probe non-invasive: SKIP (DYLD interposition is macOS only)"
  exit 2
end

SUBJECT = <<~RB
  def gcmon_begin(id)
    id
  end

  def gcmon_end(id)
    id
  end

  gcmon_begin(1)
  a = []
  i = 0
  while i < 2000
    a << ("x" * 64)
    i += 1
  end
  gcmon_end(1)
  puts a.length
RB

def measure(d, dylib, bin, tag)
  alc = File.join(d, "#{tag}.alc")   # equal-length names
  mal = File.join(d, "#{tag}.mal")
  gcm = File.join(d, "#{tag}.gcm")
  env = { "SPINEL_ALLOC_REPORT" => alc, "R007_MALLOC_REPORT" => mal,
          "GCMON_OUT" => gcm, "DYLD_INSERT_LIBRARIES" => dylib }
  out, st = Open3.capture2e(env, bin)
  abort "run failed (#{tag}):\n#{out}" unless st.success?
  gc = File.exist?(alc) ? File.readlines(alc).select { |l| l.start_with?("alloc;") }.sort : nil
  mc = File.exist?(mal) ? File.read(mal).scan(/(\w+)=(\d+)/).to_h : nil
  [gc, mc, File.exist?(gcm), out]
end

fails = 0
Dir.mktmpdir do |d|
  dylib = File.join(d, "mc.dylib")
  out, st = Open3.capture2e(CC, "-dynamiclib", "-O2", "-o", dylib, MALLOC)
  abort "malloc_count build failed:\n#{out}" unless st.success?

  obj = File.join(d, "probe.o")
  out, st = Open3.capture2e(CC, "-c", "-O2", "-o", obj, PROBE, "-I", File.dirname(PROBE))
  abort "probe build failed:\n#{out}" unless st.success?

  src = File.join(d, "subj.rb")
  File.write(src, SUBJECT)

  on  = File.join(d, "aa")   # aa / bb: equal length
  off = File.join(d, "bb")
  out, st = Open3.capture2e({ "SPINEL_EXTERN_METHODS" => "gcmon_begin,gcmon_end" },
                            SPINEL, src, "--cc=#{CC}", "--link", obj, "-o", on)
  abort "probe-on build failed:\n#{out}" unless st.success?
  out, st = Open3.capture2e(SPINEL, src, "--cc=#{CC}", "-o", off)
  abort "probe-off build failed:\n#{out}" unless st.success?

  gc_on,  mc_on,  had_probe, out_on  = measure(d, dylib, on,  "aa")
  gc_off, mc_off, no_probe,  out_off = measure(d, dylib, off, "bb")

  say = lambda { |ok, msg| puts((ok ? "PASS  " : "FAIL  ") + msg); fails += 1 unless ok }

  say.call(out_on == "2000\n" && out_off == "2000\n", "both builds print 2000")
  say.call(had_probe, "the probe-on build leaves gcmon output")
  say.call(!no_probe, "the probe-off build leaves none (the control works)")
  say.call(!gc_on.nil? && !gc_off.nil? && !gc_on.empty?, "the GC counter left output on both (not MISSING)")
  say.call(!mc_on.nil? && !mc_off.nil?, "the malloc counter left output on both (not MISSING)")
  say.call(gc_on == gc_off, "the GC counter's lines agree exactly (the probe leaves the GC heap alone)")
  if mc_on && mc_off
    %w[mallocs callocs reallocs frees].each do |k|
      say.call(mc_on[k] && mc_on[k] == mc_off[k], "malloc counter #{k} agrees (#{mc_on[k]} vs #{mc_off[k]})")
    end
    say.call(mc_on["bytes"] == mc_off["bytes"],
             "malloc counter bytes agree (#{mc_on['bytes']}; holds only with equal path lengths)")
  end
end

puts(fails.zero? ? "---- probe non-invasive: PASS" : "---- probe non-invasive: FAIL (#{fails})")
exit(fails.zero? ? 0 : 1)
