# Focused import/semantic controls. No Ruby source parser lives in this test.
require "fileutils"
require "open3"
require_relative '../scripts/lib/byte-comparison'
build, src = ARGV
tool = File.join(build, "bin/spinel-mlir")
abort "E001 import: frontend not built" unless File.executable?(tool)
out = File.join(build, "import-test")
FileUtils.mkdir_p(out)
base = File.read(File.join(src, "Inputs/import-minimal.mlir"))
def run_case(tool, dir, name, text, flag, expected)
  path = File.join(dir, "#{name}.mlir")
  File.write(path, text)
  output = File.join(dir, name + "-output")
  args = name == "literal" ? [tool, "--emit-dir", output, path] : [tool, flag, path]
  stdout, stderr, status = Open3.capture3(*args)
  File.write(File.join(dir, "#{name}.stderr"), stderr)
  if expected
    abort "#{name}: expected named refusal, got rc=#{status.exitstatus}: #{stderr}" if status.success? || !ByteComparison.include?(stderr, expected)
    abort "#{name}: diagnostic bytes differ" if name == "literal" && !ByteComparison.equal?(stderr, expected)
    abort "#{name}: published success output" unless stdout.empty? && !File.exist?(output)
  else
    abort "#{name}: #{stderr}" unless status.success?
  end
end
run_case(tool, out, "valid", base, "--verify-only", nil)
node = base.lines.find { |line| line.include?('"spinel_facts.node"') }
duplicate = base.sub(node, node + node)
run_case(tool, out, "duplicate", duplicate, "--verify-only", "duplicate node ID 1 in pristine")
run_case(tool, out, "unchecked", base.sub("refusal_checked = true", "refusal_checked = false"), "--verify-only", "codegen refusal was not checked")
literal = base.sub('backend_decimal = "1"', 'backend_decimal = "0"').sub('integers = {value = "1"}', 'integers = {value = "0"}')
diagnostic = 'xdpcount.rb:6:24: rejected SB014 (SemanticGap): integer literal 1 is not an Integer Spinel can hold (Spinel reads it as "0") — literals must be within [-2^63+1, 2^63-1] (P001 §3.8)'
run_case(tool, out, "literal", literal, "--check", diagnostic + "\n")
phase = base.sub('phase = "analyzed", kind = "Integer"', 'phase = "pristine", kind = "Integer"')
run_case(tool, out, "phase", phase, "--verify-only", "metadata requires analyzed phase")
missing = base.sub(', literal_text = "1"', '')
run_case(tool, out, "literal_missing", missing, "--verify-only", "source-backed pristine IntegerNode requires literal_text")
source = base.lines.find { |line| line.include?('"spinel_facts.source"') }
splice = %(  "spinel_facts.splice"() {before_line = 1 : i64, file_id = 0 : i64, origin = "enumerable", path = "builtins/enumerable.rb"} : () -> ()\n)
run_case(tool, out, "splice", base.sub(source) { source + splice }, "--verify-only", nil)
run_case(tool, out, "splice_line0", base.sub(source) { source + splice.sub("before_line = 1", "before_line = 0") }, "--verify-only", "splice requires file_id >= 0, before_line >= 1")
run_case(tool, out, "splice_nosource", base.sub(source) { source + splice.sub("file_id = 0", "file_id = 7") }, "--verify-only", "splice file_id has no preceding source")
puts "E001 import: valid/splice GREEN; duplicate/unchecked/SB014/phase/literal_missing/splice_line0/splice_nosource named RED"
