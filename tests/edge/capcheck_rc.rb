# frozen_string_literal: true
#
# tests/edge/capcheck_rc.rb -- every case of the capability checker's table
# exits with the code the table declares for it.
#
#   ruby tests/edge/capcheck_rc.rb
#
# The table is tools/platform/ab/e168_cases.tsv, ported from spinel-llvm
# 463d49dd with its fixtures (the E090, E091 and E093 subjects, now under
# tools/platform/ab/fixtures). Each row states its expected exit code: 0 for an
# accepted program, profile or tier; 1 for a refusal (tier or menu violation,
# broken profile); 2 for a usage error. That column is a specification, so
# checking it is an ordinary accept/reject test.
#
# NOT run here: tools/platform/ab/run_e168.sh and test_e168.rb. They compare
# the checker's full output byte for byte with goldens recorded from spinel-llvm's
# frozen Python implementation -- an oracle, run only on the user's instruction.
require "open3"

REPO  = File.expand_path("../..", __dir__)
TABLE = File.join(REPO, "tools/platform/ab/e168_cases.tsv")
CLI   = File.join(REPO, "tools/platform/spinel-capcheck")
COLUMNS = %w[id sub argv expect_rc note os_specific skip_on].freeze

lines = File.readlines(TABLE, chomp: true)
abort "capcheck_rc: the table's header changed" unless lines.first.split("\t") == COLUMNS
rows = lines.drop(1).reject(&:empty?).map { |l| COLUMNS.zip(l.split("\t")).to_h }
abort "capcheck_rc: the table is empty" if rows.empty?

pass = fail = 0
rows.each do |r|
  argv = r["argv"].split(" ").reject(&:empty?).map { |a| a.gsub("@R@", REPO) }
  out, err, st = Open3.capture3({ "LC_ALL" => "C" }, CLI, *argv, chdir: REPO)
  if st.exitstatus.to_s == r["expect_rc"]
    pass += 1
    puts "ok   #{r['id']} (rc #{st.exitstatus}: #{r['note']})"
  else
    fail += 1
    puts "FAIL #{r['id']}: rc #{st.exitstatus}, want #{r['expect_rc']} (#{r['note']})"
    puts (err.empty? ? out : err).lines.first(3).map { |x| "     #{x}" }.join
  end
end
puts "capcheck: #{pass} passed, #{fail} failed (#{rows.size} cases)"
exit(fail.zero? ? 0 : 1)
