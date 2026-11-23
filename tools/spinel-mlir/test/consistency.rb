require "fileutils"
require "open3"
require_relative '../scripts/lib/byte-comparison'
build, src = ARGV
tool = File.join(build, "bin/spinel-mlir")
root = File.join(build, "consistency-test")
FileUtils.rm_rf(root)
FileUtils.mkdir_p(root)
base = File.read(File.join(src, "Inputs/import-minimal.mlir"))
diag = '  "spinel_facts.diagnostic"() {severity = "error", file = "xdpcount.rb", line = 1 : i64, col = 0 : i64, message = "fixture refusal"} : () -> ()'
success_error = base.sub(/}\s*\z/, diag + "\n}\n")
inconsistent = base.sub('integers = {value = "1"}', 'integers = {value = "2"}')
rejected = base.lines.first.sub('status = "success"', 'status = "rejected"').sub('refusal_count = 0', 'refusal_count = 1') + diag + "\n}\n"
cases = [
  ["success_error", success_error, "--verify-only", "success module contains error diagnostic", false],
  ["backend_record", inconsistent, "--verify-only", "integers.value disagrees with backend_decimal", false],
  ["span_text", base.sub('literal_text = "1"', 'literal_text = "2"'), "--verify-only", "literal_text differs from source span", false],
  ["source_path", base.sub('loc("xdpcount.rb":6:24)', 'loc("other.rb":6:24)'), "--verify-only", "loc filename differs from source path", false],
  ["rejected", rejected, "--emit-dir", 'xdpcount.rb:1:1: rejected SB000 (Spinel): spinel refused the program: fixture refusal' + "\n", true],
]
errors = []
cases.each do |name, input, mode, expected, exact|
  path = File.join(root, name + ".mlir")
  File.write(path, input)
  output = File.join(root, name + "-output")
  args = [tool, mode]
  args << output if mode == "--emit-dir"
  args << path
  stdout, stderr, status = Open3.capture3(*args)
  File.binwrite(File.join(root, name + ".stderr"), stderr)
  correct = exact ? ByteComparison.equal?(stderr, expected) : ByteComparison.include?(stderr, expected)
  errors << "#{name}: rc=#{status.exitstatus}, #{stderr}" if status.success? || !correct || !stdout.empty? || File.exist?(output)
end
["width", "overflow", "rejected"].each do |name|
  input = name == "width" ? base.sub("integer_bits = 64", "integer_bits = 32") :
          name == "overflow" ? base.sub('overflow = "raise"', 'overflow = "wrap"') : rejected
  path = File.join(root, "facts-" + name + ".mlir")
  File.write(path, input)
  stdout, stderr, status = Open3.capture3(tool, "--verify-only", path)
  errors << "#{name}: facts rejected #{stderr}" unless status.success? && stdout.empty? && stderr.empty?
  next if name == "rejected"
  output = File.join(root, "policy-" + name)
  stdout, stderr, status = Open3.capture3(tool, "--emit-dir", output, path)
  File.binwrite(File.join(root, "policy-" + name + ".stderr"), stderr)
  errors << "#{name}: BPF policy not refused" if status.success? || !stdout.empty? ||
    !ByteComparison.include?(stderr, "unsupported BPF policy: requires integer_bits=64 and overflow=raise") || File.exist?(output)
end
abort errors.join("\n") unless errors.empty?
puts "E001 consistency: declared success/error, backend record, source binding, rejected SB000 all named RED"
