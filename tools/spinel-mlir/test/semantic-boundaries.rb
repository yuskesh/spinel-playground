require "fileutils"
require "open3"
require_relative '../scripts/lib/byte-comparison'
build, src = ARGV
tool = File.join(build, "bin/spinel-mlir")
root = File.join(build, "semantic-boundaries-test")
FileUtils.rm_rf(root)
FileUtils.mkdir_p(root)
base = File.read(File.join(src, "Inputs/xdpcount.spinel.mlir"))
def change_integer(text, id, value, old_end = nil, new_end = nil)
  count = 0
  result = text.lines.map do |line|
    if line.include?('"spinel_facts.node"') && line.include?("id = #{id} : i64,")
      count += 1
      line = line.gsub('= "1"', '= "' + value + '"')
      line = line.sub(old_end, new_end) if old_end
    end
    line
  end.join
  abort "mutation did not reach both tables" unless count == 2
  result
end
negative = change_integer(base.sub("atomic_add(0, 1)", "atomic_add(0, -1)"), 18, "-1", "6 : i64, 24 : i64]", "6 : i64, 25 : i64]")
same_key = change_integer(base.sub("Counts.update(1, p.load)", "Counts.update(0, p.load)"), 32, "0")
cases = [
  ["negative_delta", negative, 'xdpcount.rb:6:24: rejected SB014 (SemanticGap): the delta literal -1 is outside [0, 18446744073709551615] (u64 on the eBPF side; Ruby would not wrap it)' + "\n"],
  ["same_key", same_key, 'xdpcount.rb:9:5: rejected SB019 (SharedReadModifyWrite): `Counts.update` stores a value read from the same map (`p.load`) — concurrent CPUs lose updates; use `Counts.atomic_add` (keys must be different literals to accept this form) (P002 §1.4)' + "\n"],
]
errors = []
cases.each do |name, input, expected|
  path = File.join(root, name + ".mlir")
  File.write(path, input)
  output = File.join(root, name + "-output")
  stdout, stderr, status = Open3.capture3(tool, "--emit-dir", output, path)
  File.binwrite(File.join(root, name + ".stderr"), stderr)
  errors << "#{name}: rc=#{status.exitstatus}: #{stderr}" if status.success? || !ByteComparison.equal?(stderr, expected) || !stdout.empty? || File.exist?(output)
end
abort errors.join("\n") unless errors.empty?
puts "E001 semantic boundaries: negative literal SB014 and same-key SB019 exact bytes; artifacts absent"
