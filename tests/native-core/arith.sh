#!/bin/sh
# Decision 0015: hand-derived expectations; no CRuby or other runtime oracle.
# Usage: LLVM_PREFIX=/opt/llvm-23.1.1 tests/native-core/arith.sh
# Build vendor/spinel, tools/contract and tools/mlir/native first (docs/building.md).
# SPINEL_CORE_BUILD, SPINEL_TYPEDUMP and SPINEL_SEAM select matching build inputs.
# The product driver handles Mach-O symbol prefixes and platform link libraries.
# RUBY selects the Ruby that runs the checks (default: ruby on PATH).
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "${RUBY:-ruby}" - "$here" <<'RUBY'
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

here = File.expand_path(ARGV[0])
root = File.expand_path("../..", here)
fixtures = File.join(here, "fixtures", "arith")
driver = File.join(root, "tools", "core", "spinel-core-build")
env = ENV.to_h
llvm = env.fetch("LLVM_PREFIX", "/opt/llvm-23.1.1")
[["CLANG", "clang"], ["CC", "clang"], ["NM", "llvm-nm"]].each do |key, tool|
  env[key] ||= File.join(llvm, "bin", tool)
end
File.umask(0o022)

# Wrong arithmetic, wrapping, truncating division or a lost signed boundary
# value must change an observable result; envelope refusals are checked separately.
# Error text/status follow the hosted uncaught RangeError probes at 573aa44
# and the rebased upstream abort-entry tip 3c4984057:
# stderr "integer overflow in + (RangeError)\n", stdout empty, exit 1.
# This is a format characterization, not an independently computed oracle.
# Unary minus uses the pinned operator spelling -@.
CASES = [
  ["add_ok", "42\n", "", 0],
  ["explicit_raise", "42\n", "", 0],
  ["sub_ok", "38\n", "", 0],
  ["mul_ok", "-42\n", "", 0],
  ["neg_ok", "-7\n", "", 0],
  ["add_overflow", "", "integer overflow in + (RangeError)\n", 1],
  ["sub_overflow", "", "integer overflow in - (RangeError)\n", 1],
  ["mul_overflow", "", "integer overflow in * (RangeError)\n", 1],
  ["neg_overflow", "", "integer overflow in -@ (RangeError)\n", 1],
  ["div_pos_neg", "-4\n", "", 0],
  ["div_neg_pos", "-4\n", "", 0],
  ["mod_pos_neg", "-1\n", "", 0],
  ["mod_neg_pos", "1\n", "", 0],
  ["div_zero", "", "divided by 0 (ZeroDivisionError)\n", 1],
  ["mod_zero", "", "divided by 0 (ZeroDivisionError)\n", 1],
  ["div_min_neg_one", "", "integer overflow in / (RangeError)\n", 1],
  ["mod_min_neg_one", "0\n", "", 0],
  ["return_min", "-9223372036854775808\n", "", 0],
  ["intermediate_min", "-9223372036854775807\n", "", 0],
  ["parenthesized", "45\n", "", 0],
  # Decision 0042 stage 1: & | ^ ~ are exact, so a core that uses only them
  # references no failure hook. The fifth field is the core object's
  # undefined symbols, spc_core_fail when it is left out.
  ["and_ok", "2\n", "", 0, []],
  ["and_neg", "244\n", "", 0, []],
  ["and_min", "-9223372036854775808\n", "", 0, []],
  ["or_ok", "15\n", "", 0, []],
  ["or_neg", "-11\n", "", 0, []],
  ["xor_ok", "6\n", "", 0, []],
  ["xor_neg", "-6\n", "", 0, []],
  ["xor_min", "9223372036854775807\n", "", 0, []],
  ["not_ok", "-6\n", "", 0, []],
  ["not_max", "-9223372036854775808\n", "", 0, []],
  ["not_min", "9223372036854775807\n", "", 0, []],
  ["mask32", "4294967295\n", "", 0, []],
  # The mask bounds the value, so the failure arms of / * + are in the core
  # MLIR and gone from the object; with a variable divisor the hook stays.
  ["field", "1007\n", "", 0, []],
  ["field_var", "10\n", "", 0],
  ["set_clear", "192\n", "", 0, []],
  # Decision 0042 stage 2: the shifts under S1. A left shift that loses bits
  # fails with the pinned Spinel's text, `>> -n` included, and the hook stays.
  ["shl_ok", "28\n", "", 0],
  ["shl_values", "4611686018427387904\n-9223372036854775808\n2\n-1\n0\n0\n", "", 0],
  ["shr_values", "-3\n-1\n-1\n0\n10\n-9223372036854775808\n", "", 0],
  ["shl_overflow", "", "integer overflow in << (RangeError)\n", 1],
  ["shl_count", "", "integer overflow in << (RangeError)\n", 1],
  ["shr_neg_count", "", "integer overflow in << (RangeError)\n", 1],
  ["shr_min_count", "", "integer overflow in << (RangeError)\n", 1],
  # A constant count in range cannot fail, and the mask bounds the rest.
  ["field_shift", "1007\n", "", 0, []],
  ["pack", "4660\n", "", 0],
  # Decision 0042 stage 3: `abs` and `**`, the exact result or the pinned
  # Spinel's message for each failure.
  ["abs_ok", "7\n", "", 0],
  ["abs_values", "5\n0\n9223372036854775807\n9223372036854775807\n", "", 0],
  ["abs_min", "", "integer overflow in abs (RangeError)\n", 1],
  ["pow_ok", "49\n", "", 0],
  ["pow_values", "1\n-9223372036854775808\n4052555153018976267\n-4052555153018976267\n-1\n1\n0\n", "", 0],
  ["pow_const", "13\n8999999997000000001\n", "", 0],
  ["pow_const63", "-9223372036854775808\n1\n-1\n0\n", "", 0],
  ["pow_overflow", "", "integer overflow in ** (RangeError)\n", 1],
  ["pow_big_exp", "", "integer overflow in ** (RangeError)\n", 1],
  ["pow_negative", "", "negative exponent (RangeError)\n", 1],
  ["pow_const_overflow", "", "integer overflow in ** (RangeError)\n", 1],
  # Decision 0042 stage 4: the named wrapping and unsigned forms and 0022's
  # intrinsics, against published check values (FNV-1a 32 and 64, CRC-32)
  # and rows by hand. A `w64` form and a `u64` comparison cannot fail, so a
  # core using only them references no hook. The top level passes literals
  # only, so each checksum's starting value is in the root.
  ["fnv32", "-468965076\n-1080231576\n", "", 0],
  ["fnv64", "-5808556873153909620\n-8821353812377114648\n", "", 0, []],
  ["crc32", "-873187034\n", "", 0],
  ["u32_lit", "-559038737\n", "", 0, []],
  ["bom", "8\n", "", 0],
  ["w64_add_values", "-9223372036854775808\n9223372036854775807\n-2\n579\n-2\n", "", 0, []],
  ["w64_mul_values", "1\n-9223372036854775808\n0\n-21\n-5808590958014384161\n", "", 0, []],
  ["w64_shl_values", "-9223372036854775808\n0\n1\n-1\n-1\n", "", 0, []],
  ["u64_shr_values", "9223372036854775807\n1\n1\n-1\n771\n", "", 0],
  ["u64_ge_values", "0\n1\n1\n1\n0\n", "", 0, []],
  ["w32_shl_values", "-2147483648\n0\n-2147483648\n-1\n0\n", "", 0],
  ["intrinsic_operand", "", "core_w32_add: an operand is outside the i32 range (RangeError)\n", 1],
  ["u32_shr_count", "", "core_u32_shr: the count is outside 0..31 (RangeError)\n", 1],
  ["u64_shr_count", "", "core_u64_shr: the count is outside 0..63 (RangeError)\n", 1],
].freeze
REFUSALS = [
  ["wrap", "add_ok", ["--int-overflow", "wrap"], /--int-overflow/],
  ["promote", "add_ok", ["--int-overflow", "promote"], /--int-overflow/],
  ["Array <<", "reject_array_shl", [], /heap-operation/],
  ["reopened Integer#<<", "reject_reopen_shl", [], /binding-environment/],
  ["boolean bitwise operands", "reject_bool_bitwise", [], /type-evidence/],
  ["abort hook envelope", "abort_hooks", [], /binding-environment/],
  ["top-level at_exit", "reject_at_exit", [], /binding-environment/],
  ["rescue around core call", "reject_rescue", [], /binding-environment/],
  # Decision 0042 stage 4: the intrinsics' recognition.
  ["unused intrinsic definition", "reject_def_intrinsic", [], /conflicting-intrinsic/],
  ["core_u32 of a parameter", "reject_u32_param", [], /unsupported-intrinsic-call/],
  ["core_u32 past 32 bits", "reject_u32_wide", [], /unsupported-intrinsic-call/],
  ["intrinsic receiver", "reject_intrinsic_self", [], /unsupported-intrinsic-call/],
  ["intrinsic arity", "reject_intrinsic_arity", [], /arity-mismatch/],
].freeze
# The revised decision keeps abort delivery pending until the envelope grows.
# The same fixture must currently be refused, independently of this pending run.
PENDING = ["abort_hooks: runtime delivery pending until the envelope admits at_exit/rescue/ensure"].freeze
TIMEOUT = 120
$stdout.sync = true
$passed = 0
$failed = 0
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# A value as the failure details have always shown it (Python's repr), so a
# FAIL line reads the same as it did before this runner was Ruby.
def repr(v)
  case v
  when nil then "None"
  when true then "True"
  when false then "False"
  when Array then "[" + v.map { |x| repr(x) }.join(", ") + "]"
  when String
    q = v.include?("'") && !v.include?('"') ? '"' : "'"
    body = v.each_char.map do |c|
      case c
      when "\\" then "\\\\"
      when q then "\\" + q
      when "\n" then "\\n"
      when "\t" then "\\t"
      when "\r" then "\\r"
      else c.ord < 0x20 || c.ord == 0x7f ? format("\\x%02x", c.ord) : c
      end
    end.join
    q + body + q
  else v.to_s
  end
end

def report(label, good, detail = "")
  if good
    $passed += 1
    puts "ok   " + label
  else
    $failed += 1
    puts "FAIL " + label + (detail.empty? ? "" : "\n     " + detail)
  end
end

class RunTimeout < StandardError; end
Run = Struct.new(:stdout, :stderr, :returncode)

# argv run from the repository root with `env`, its output captured, and
# killed after TIMEOUT seconds.
define_method(:run) do |argv|
  argv = argv.map(&:to_s)
  Open3.popen3(env, *argv, chdir: root) do |i, o, e, t|
    i.close
    out = Thread.new { o.read }
    err = Thread.new { e.read }
    unless t.join(TIMEOUT)
      Process.kill("KILL", t.pid) rescue nil
      t.join
      raise RunTimeout, format("Command %s timed out after %d seconds", repr(repr(argv)), TIMEOUT)
    end
    st = t.value
    Run.new(out.value, err.value, st.exitstatus || -st.termsig)
  end
end

def error_text(error)
  return error.message if error.is_a?(RunTimeout)

  # Errno::ENOENT "No such file or directory - path" as "[Errno 2] ...: 'path'"
  msg, _sep, path = error.message.partition(" - ")
  path.empty? ? format("[Errno %d] %s", error.errno, msg) : format("[Errno %d] %s: %s", error.errno, msg, repr(path))
end

define_method(:inspect_captured) do |label, capture, expected|
  obj = File.join(capture, "core.o")
  unless File.file?(obj)
    report(label + " undefined symbols", false, "driver did not hand core.o to the linker")
    next
  end
  symbols = run([env["NM"], "--undefined-only", "--format=just-symbols", obj])
  names = symbols.stdout.split
  names = names.map { |n| n.start_with?("_") ? n[1..] : n } if RbConfig::CONFIG["host_os"] =~ /darwin/
  report(label + " undefined symbols", symbols.returncode.zero? && names.sort == expected,
         format("expected %s; got %s; nm status=%s stderr=%s",
                repr(expected), repr(names), repr(symbols.returncode), repr(symbols.stderr)))
end

# shutil.which: the command if it names a path, else its first executable
# match on env's PATH.
def which(cmd, path)
  return (File.executable?(cmd) ? cmd : nil) if cmd.include?("/")

  path.to_s.split(File::PATH_SEPARATOR).map { |d| File.join(d, cmd) }
      .find { |f| File.file?(f) && File.executable?(f) }
end

Dir.mktmpdir("core-arith-") do |work|
  # Forward every compiler argument unchanged. At the actual final link,
  # preserve the exact core.o operand before the driver cleans its staging.
  # This observes the product artifact; it generates no substitute object.
  real_cc = which(env["CC"], env["PATH"]) || env["CC"]
  wrapper = File.join(work, "capture-cc")
  File.write(wrapper, "#!" + RbConfig.ruby + "\n" \
    "require 'fileutils'\n" \
    "ARGV.each do |a|\n" \
    "  if File.basename(a) == 'core.o' && File.file?(a)\n" \
    "    FileUtils.cp(a, File.join(ENV['ARITH_CAPTURE'], 'core.o'))\n" \
    "  end\n" \
    "end\n" \
    "exec(#{real_cc.inspect}, *ARGV)\n")
  File.chmod(0o755, wrapper)
  env["CC"] = wrapper
  CASES.each do |name, stdout, stderr, status, symbols = ["spc_core_fail"]|
    binary = File.join(work, name)
    capture = File.join(work, name + "-artifacts")
    Dir.mkdir(capture)
    env["ARITH_CAPTURE"] = capture
    begin
      built = run([driver, "--source", File.join(fixtures, name + ".rb"),
                   "--core", "calculate", "-o", binary] +
                  (name == "explicit_raise" ? ["--int-overflow", "raise"] : []))
      unless built.returncode.zero?
        report(name, false, format("build exit %d: %s", built.returncode,
                                   (built.stdout + built.stderr).strip))
        next
      end
      inspect_captured(name, capture, symbols)
      actual = run([binary])
      stderr_ok = actual.stderr == stderr
      report(name, actual.returncode == status && actual.stdout == stdout && stderr_ok,
             format("expected status=%s stdout=%s stderr=%s; got status=%s stdout=%s stderr=%s",
                    repr(status), repr(stdout), repr(stderr),
                    repr(actual.returncode), repr(actual.stdout), repr(actual.stderr)))
    rescue SystemCallError, RunTimeout => error
      report(name, false, error_text(error))
    end
  end
  # Negative control: the product's non-arithmetic core has no failure hook.
  capture = File.join(work, "lower-artifacts")
  Dir.mkdir(capture)
  env["ARITH_CAPTURE"] = capture
  begin
    built = run([driver, "--source", File.join(here, "fixtures", "lower.rb"),
                 "--core", "lower", "-o", File.join(work, "lower")])
    if built.returncode.zero?
      inspect_captured("lower", capture, [])
    else
      report("lower undefined symbols", false, built.stdout + built.stderr)
    end
  rescue SystemCallError, RunTimeout => error
    report("lower undefined symbols", false, error_text(error))
  end
  REFUSALS.each do |label, name, flags, diagnostic|
    binary = File.join(work, "refused-" + label)
    begin
      built = run([driver, "--source", File.join(fixtures, name + ".rb"),
                   "--core", "calculate", "-o", binary] + flags)
      output = built.stdout + built.stderr
      mode_diagnostic = !%w[wrap promote].include?(label) ||
                        (!output.downcase.include?("unknown argument") &&
                         output.gsub("spinel-core-build:", "").match?(/\bcore\b/i) &&
                         output.include?("--int-overflow") && output.include?(label))
      report("refuses " + label,
             mode_diagnostic && !built.returncode.zero? && !File.exist?(binary) &&
             diagnostic.match?(built.stdout + built.stderr),
             format("status=%s published=%s diagnostic=%s",
                    repr(built.returncode), repr(File.exist?(binary)), repr(built.stdout + built.stderr)))
    rescue SystemCallError, RunTimeout => error
      report("refuses " + label, false, error_text(error))
    end
  end
end
PENDING.each { |reason| puts "PENDING " + reason }
printf("\ncore scalar arithmetic: %d passed, %d failed, %d pending (%.3f s)\n",
       $passed, $failed, PENDING.size, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
exit($failed.zero? ? 0 : 1)
RUBY
