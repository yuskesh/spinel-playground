# tests/gcmon/probe_properties.rb — properties of the section probe.
#
#   ruby tests/gcmon/probe_properties.rb
#
# The probe reports the running process's own values, so fixed expected numbers
# are impossible. The checks are PROPERTIES instead:
#   - cycle / full_runs deltas are non-negative (cumulative counters)
#   - entries equals the number of begins
#   - a begin/end that does not pair is reported as unmatched
#   - an out-of-range id is counted as out_of_range, not dropped
#
# The subject is generated and built here; vendor is only read.
# SPINEL (default vendor/spinel/bin/spinel) and CC (default cc) select the tools.
require "open3"
require "tmpdir"

ROOT   = File.expand_path("../..", __dir__)
SPINEL = ENV["SPINEL"] || File.join(ROOT, "vendor/spinel/bin/spinel")
CC     = ENV["CC"] && !ENV["CC"].empty? ? ENV["CC"] : "cc"
PROBE  = File.join(ROOT, "tools/gcmon/gcmon_probe.c")

fails = 0
def check(cond, msg)
  puts((cond ? "PASS  " : "FAIL  ") + msg)
  cond ? 0 : 1
end

abort "no spinel at #{SPINEL}" unless File.executable?(SPINEL)

Dir.mktmpdir do |d|
  obj = File.join(d, "probe.o")
  out, st = Open3.capture2e(CC, "-c", "-O2", "-o", obj, PROBE, "-I", File.dirname(PROBE))
  abort "probe build failed:\n#{out}" unless st.success?

  src = File.join(d, "subj.rb")
  File.write(src, <<~RB)
    def gcmon_begin(id)
      id
    end

    def gcmon_end(id)
      id
    end

    # three well-formed sections
    n = 0
    while n < 3
      gcmon_begin(1)
      a = []
      i = 0
      while i < 200
        a << ("y" * 32)
        i += 1
      end
      gcmon_end(1)
      n += 1
    end

    # an end with no begin
    gcmon_end(2)

    # an out-of-range id
    gcmon_begin(9999)

    puts "done"
  RB

  bin = File.join(d, "subj")
  env = { "SPINEL_EXTERN_METHODS" => "gcmon_begin,gcmon_end" }
  out, st = Open3.capture2e(env, SPINEL, src, "--cc=#{CC}", "--link", obj, "-o", bin)
  abort "subject build failed:\n#{out}" unless st.success?

  tsv = File.join(d, "probe.tsv")
  out, st = Open3.capture2e({ "GCMON_OUT" => tsv }, bin)
  abort "subject run failed:\n#{out}" unless st.success?
  fails += check(out == "done\n", "the subject runs to its end with the probe linked")

  rows = {}
  File.foreach(tsv) do |line|
    next if line.start_with?("#")
    _inst, id, metric, val = line.chomp.split("\t")
    rows["#{id}/#{metric}"] = val.to_i if val
  end

  fails += check(rows["1/entries"] == 3, "entries equals the number of begins (3)")
  fails += check(rows["1/cycle"] && rows["1/cycle"] >= 0, "the cycle delta is non-negative")
  fails += check(rows["1/full_runs"] && rows["1/full_runs"] >= 0, "the full_runs delta is non-negative")
  fails += check(rows["1/bytes"] && rows["1/bytes"] > 0,
                 "a section that allocates has positive bytes (#{rows['1/bytes'].inspect})")
  fails += check(!rows.key?("1/unmatched"), "well-formed sections report no unmatched row")
  fails += check(rows["2/unmatched"] == 1, "an end with no begin is reported as unmatched")
  fails += check(rows["-1/out_of_range"] == 1, "an out-of-range id is reported as out_of_range")
  fails += check(!rows.key?("9999/entries"), "an out-of-range id creates no section row")
end

puts(fails.zero? ? "---- probe properties: PASS" : "---- probe properties: FAIL (#{fails})")
exit(fails.zero? ? 0 : 1)
