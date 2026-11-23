# frozen_string_literal: true
# The pinned analysis classifies target-width literals; no external oracle.
require 'open3'
require 'fiddle'
reader = ARGV.fetch(0) { ENV.fetch('SPINEL_TYPEDUMP', File.expand_path('../../tools/contract/build/spinel-typedump', __dir__)) }
source = File.join(__dir__, 'fixtures/int-width.rb')
checks = 0
check = lambda do |label, condition|
  abort "FAIL #{label}" unless condition
  checks += 1
  puts "pass #{label}"
end
{32 => %w[int bigint int bigint], 64 => %w[int int int int]}.each do |width, types|
  out, err, rc = Open3.capture3(reader, source, 'nodes', "--int-width=#{width}")
  check.call("#{width}-bit analysis succeeds", rc.success? && err.empty?)
  actual = out.lines.drop(1).map { |line| line.chomp.split("\t", -1) }.select { |f| f[1] == 'IntegerNode' }.map { |f| f[2] }
  check.call("#{width}-bit signed literal boundary", actual == types)
end
out, err, rc = Open3.capture3(reader, source, 'nodes')
expected = Fiddle::SIZEOF_VOIDP == 8 ? %w[int int int int] : %w[int bigint int bigint]
actual = out.lines.drop(1).map { |l| l.split("\t") }.select { |f| f[1] == 'IntegerNode' }.map { |f| f[2] }
check.call('default remains the host width', rc.success? && err.empty? && actual == expected)
%w[0 16 128 i32 32junk].each do |width|
  out, err, rc = Open3.capture3(reader, source, 'nodes', "--int-width=#{width}")
  check.call("invalid width #{width} is refused before output", !rc.success? && out.empty? && err.include?('int-width'))
end
puts "contract integer width: #{checks} pass, 0 fail"
