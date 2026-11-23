# frozen_string_literal: true
#
# tools/oracle/gate.rb -- the Ruby form of tools/oracle/gate.
#
#   require_relative ".../tools/oracle/gate"
#   OracleGate.allow?("tools/app/bin/spinel-core-app", "replay") or ...
#
# true when ALLOW_ORACLE=1 and tests/ORACLES.tsv lists the path and section as
# a gated section; otherwise prints "NOT RUN (oracle): <path> <section>: <what
# it compares with>" and returns false. An unlisted section is refused either
# way. tools/oracle/gate says why.
module OracleGate
  LIST = File.expand_path("../../tests/ORACLES.tsv", __dir__)
  GATED = %w[owner definition confirm].freeze

  module_function

  def allow?(path, section, io: $stdout)
    row = File.file?(LIST) && File.foreach(LIST).map { |l| l.chomp.split("\t") }.find do |c|
      !c[0].to_s.start_with?("#") && c[0] == path && c[1] == section && GATED.include?(c[2])
    end
    unless row
      io.puts "NOT RUN (oracle): #{path} #{section}: not a gated section in tests/ORACLES.tsv"
      return false
    end
    return true if ENV["ALLOW_ORACLE"] == "1"
    io.puts "NOT RUN (oracle): #{path} #{section}: #{row[3]}"
    false
  end
end
