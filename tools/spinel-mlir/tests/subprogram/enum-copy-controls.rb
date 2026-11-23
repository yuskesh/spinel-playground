require 'json'
require 'zlib'
require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'
tool, fixture, work = ARGV
abort 'usage: controls TOOL FACTS_GZ WORK' unless work
FileUtils.mkdir_p(work)
work = Dir.mktmpdir('run-', work)
source = Zlib::GzipReader.open(fixture, &:read)
# The fixture's source paths were renamed (2026-11-16): the capture's
# directory /src/spinel-mlir-<call-sign>/ became /src/spinel-mlir/, so that
# the published tree names no agent. The old golden still binds the content:
# putting the old prefix back must give the captured text's hash. The old
# prefix is built from parts so that this file names no call-sign either.
NEW_HASH = 'e2d34989dc4512048b362ac02e3f3d8e0ccba451eb2e544e7ef001a632a13528'
CAPTURED_HASH = 'e6312c3bc1be77c4e39f49685c138832e2dd344e9730968f7d76974c8a6498a4'
CAPTURED_PREFIX = '/src/spinel-mlir-' + 'viper' + '-16/'
def fixture_error(text, new_hash)
  return 'E063 fixture hash' unless Digest::SHA256.hexdigest(text) == new_hash
  return 'E063 fixture prefix' if text.include?(CAPTURED_PREFIX)
  captured = text.gsub('/src/spinel-mlir/', CAPTURED_PREFIX)
  return 'E063 captured fixture hash' unless Digest::SHA256.hexdigest(captured) == CAPTURED_HASH
  nil
end
error = fixture_error(source, NEW_HASH)
abort error if error
# Control: one byte changed outside the prefix, with the new hash made to
# match, must still be refused by the captured hash.
at = source.index('"enum_copy" = "10915"') or abort 'E063 control site'
altered = source.dup; altered[at + 16] = '2'
abort 'E063 control: altered text not refused by the captured hash' unless
  fixture_error(altered, Digest::SHA256.hexdigest(altered)) == 'E063 captured fixture hash'
other = source.scan(/"spinel_facts.node"\(\) \{id = (\d+) : i64, kind = "DefNode", strings = \{"name" = "on_access"/).flatten.uniq
stamp = '"enum_copy" = "10915"'
evidence = /^.*"spinel_facts.evidence"\(\) \{node_id = 4132 : i64,.*\n/
abort 'E063 unique witness' unless other.size == 1 && source.scan(stamp).size == 1 && source.scan(evidence).size == 1
controls = {
  'clone-other-callee' => source.sub(stamp, '"enum_copy" = "' + other.fetch(0) + '"'),
  'missing-evidence' => source.sub(evidence, ''),
  'unknown-analysis-key' => source.sub(stamp, '"e076_unknown_metadata" = "10915"')
}
controls.each do |name, text|
  dir = File.join(work, name); FileUtils.mkdir_p(dir)
  facts = File.join(dir, 'facts.mlir'); File.binwrite(facts, text)
  argv = [tool, '--emit-dir', File.join(dir, 'artifacts'), facts]
  out, err, status = Open3.capture3(*argv)
  File.binwrite(File.join(dir, 'stdout'), out); File.binwrite(File.join(dir, 'stderr'), err)
  File.binwrite(File.join(dir, 'execution.json'), JSON.pretty_generate({argv: argv, rc: status.exitstatus, signal: status.termsig}) + "\n")
  artifacts = Dir[File.join(dir, 'artifacts', '*')]
  if name == 'clone-other-callee'
    abort "E076 #{name}: analysis-only stamp must not select a callee" unless
      status.exitstatus == 0 && !status.termsig && out.empty? && err.empty? &&
      artifacts.size == 3 && artifacts.all? { |p| File.size(p) > 0 }
    puts "PASS E076 #{name}: ignored stamp / rc0 / artifact3"
  else
    message = name == 'missing-evidence' ? 'call evidence does not match the explicit callee policy' : 'cannot prove identity'
    abort "E076 #{name}: expected named rejection" unless status.exitstatus == 1 && !status.termsig && out.empty? &&
      err.include?('cachestat.rb:25:7: rejected SB001') && err.include?(message) && artifacts.empty?
    puts "PASS E076 #{name}: named SB001 / rc1 / artifact0"
  end
end
