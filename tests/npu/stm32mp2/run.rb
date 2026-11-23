#!/usr/bin/env ruby
# frozen_string_literal: true
# tests/npu/stm32mp2/run.rb -- the Ruby to IREE to VX delegate lane (decision 0034).
#
#   IREE_COMPILE, IREE_SRC, IREE_STM32MP2_BUILD, STM32MP2_CROSS, STM32MP2_SYSROOT
#                          the build; without them only the refusals run
#   NPU_STM32_CONSOLE_LOG  the capture of tests/npu/stm32mp2/board.sh on the board,
#                          for the program this run builds
#   NPU_WORK               scratch directory (default: a new one under TMPDIR). The
#                          build tag depends on it, so a capture needs the same one
#
# The expected values are by hand (tests/npu/sides.rb). Nothing is compared with
# another implementation. Exit 0 when all passed, 1 on a failure, 2 on a skip.
require "fileutils"
require "open3"
require "tmpdir"
REPO = File.expand_path("../../..", __dir__)
NPU = File.join(REPO, "tools/npu/spinel-npu")
require File.join(REPO, "tools/npu/tflite")

$pass = $fail = $skip = 0
def ok(m) = ($pass += 1; puts "PASS  #{m}")
def bad(m) = ($fail += 1; puts "FAIL  #{m}")
def skp(m) = ($skip += 1; puts "SKIP  #{m}")
def check(cond, m) = cond ? ok(m) : bad(m)
def finish
  puts "npu-stm32mp2: #{$pass} passed, #{$fail} failed, #{$skip} skipped"
  exit($fail.positive? ? 1 : $skip.positive? ? 2 : 0)
end

WORK = ENV["NPU_WORK"] || Dir.mktmpdir("npu-stm32", ENV["TMPDIR"] || "/tmp")
FIX = File.join(WORK, "fix")
FileUtils.mkdir_p(FIX)
SIDES = File.read(File.join(REPO, "tests/npu/sides.rb"))

def tool(*args) = Open3.capture2e(NPU, "--board", "stm32mp257f-dk", *args)

def refused(name, source, needle, model: nil)
  File.write(File.join(FIX, "#{name}.rb"), source)
  File.binwrite(File.join(FIX, "#{name}.tflite"), model) if model
  out, st = tool(File.join(FIX, "#{name}.rb"), "-o", File.join(WORK, name), "--check-only")
  check(st.exitstatus == 1 && out.include?(needle), "refused: #{name} (exit #{st.exitstatus}): #{out.lines.last.to_s.strip}")
end

# The model the declaration writes, for the npu_extern variants below.
out, st = tool(File.join(REPO, "tests/npu/sides.rb"), "-o", File.join(WORK, "plain"), "--check-only")
check(st.success? && out.include?("input [1, 8, 8, 1], output [1, 2]"), "npu_def passes the checks")
bytes = File.binread(File.join(WORK, "plain/generated.tflite"))

extern = lambda do |name, input: "[:i8, 1, 8, 8, 1]", output: "[:i8, 1, 2]", extra: ""|
  %(npu_extern :sides, tflite: "#{name}.tflite", input: #{input}, output: #{output}#{extra}\nrequire_relative "npu.gen"\n)
end

refused("partial", extern["partial", extra: ", partial: true"], "partial: true has no meaning", model: bytes)
refused("input_shape", extern["input_shape", input: "[:i8, 1, 4, 4, 1]"], "the declaration says input:", model: bytes)
refused("output_shape", extern["output_shape", output: "[:i8, 1, 3]"], "the declaration says output:", model: bytes)
refused("float_decl", extern["float_decl", input: "[:f32, 1, 8, 8, 1]"], "int8 only", model: bytes)

# The same model with its input retyped as uint8: one byte of the flatbuffer.
m = TFLite::Model.new(bytes)
t = m.send(:table_vec, m.send(:field, m.send(:ind, 0), 2)).first
tensor = m.send(:table_vec, m.send(:field, t, 0))[m.inputs[0]]
at = m.send(:field, tensor, 1)
uint8 = bytes.dup
uint8.setbyte(at, TFLite::UINT8)
refused("uint8_model", extern["uint8_model"], "is type 3, not int8", model: uint8)

_, st = tool(File.join(REPO, "tests/npu/sides.rb"), "--board", "nope", "-o", File.join(WORK, "x"))
check(st.exitstatus == 2, "refused: an unknown board (exit #{st.exitstatus})")

needed = %w[IREE_COMPILE IREE_SRC IREE_STM32MP2_BUILD STM32MP2_CROSS STM32MP2_SYSROOT]
if needed.any? { |v| ENV[v].to_s.empty? }
  skp("the build: #{needed.select { |v| ENV[v].to_s.empty? }.join(", ")} not set")
  finish
end

build = File.join(WORK, "sides")
out, st = tool(File.join(REPO, "tests/npu/sides.rb"), "-o", build)
check(st.success? && File.exist?(File.join(build, "app")), "the program builds: #{out.lines.last.to_s.strip}")
finish unless File.exist?(File.join(build, "app"))
head = File.binread(File.join(build, "app"), 20)
check(head.start_with?("\x7FELF".b) && head[18, 2].unpack1("v") == 183, "the program is an aarch64 executable")
cross = ENV["STM32MP2_CROSS"]
env = { "PATH" => "#{File.dirname(cross)}:#{ENV["PATH"]}" }
%w[nodelegate onenode].each do |n|
  o, st = Open3.capture2e(env, "#{cross}gcc", "--sysroot=#{ENV["STM32MP2_SYSROOT"]}", "-shared", "-fPIC", "-o", File.join(build, "#{n}.so"),
                          File.join(REPO, "tests/npu/stm32mp2/#{n}.c"))
  check(st.success?, "the stand-in delegate #{n} builds #{o.lines.last.to_s.strip}")
end

log = ENV["NPU_STM32_CONSOLE_LOG"].to_s
if log.empty?
  skp("NPU_STM32_CONSOLE_LOG is not set; the board run was not checked")
  finish
end
text = File.read(log)
tag = File.read(File.join(build, "build.tag")).strip
sections = text.split(/^=== /).drop(1).to_h { |s| n, b = s.split("\n", 2); [n, b.to_s] }
run, missing, none, one = sections.values_at("run", "missing", "nodelegate", "onenode").map(&:to_s)
check(run.include?("spinel-npu: build #{tag}\n"), "the capture is of the program this run built")
check(run.include?("spinel-npu: delegate libvx_delegate.so.2\n"), "the run used the default delegate")
check(run =~ /nodes 4, delegated partitions 1, cpu nodes 0\n/, "the delegate took the whole model")
%w[left\ 27\ 0 right\ 0\ 27 dark\ 0\ 0 done rc=0].each { |l| check(run.lines.map(&:strip).include?(l), "the board printed: #{l}") }
check(missing.include?("cannot load the delegate") && missing.include?("rc=1") && missing !~ /^left /, "an absent delegate stops the program")
check(none.include?("cpu nodes 4") && none.include?("did not take the whole model") && none.include?("rc=1") && none !~ /^left /,
      "a delegate that takes nothing stops the program")
check(one.include?("delegated partitions 1, cpu nodes 3") && one.include?("did not take the whole model") && one.include?("rc=1") && one !~ /^left /,
      "a delegate that takes one operator stops the program")
finish
