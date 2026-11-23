# frozen_string_literal: true
#
# tests/native-core/macos-probe.rb -- the native stage-by-stage probe on
# macOS arm64. It does not exercise the product build driver.
#
#   LLVM_PREFIX=... ruby tests/native-core/macos-probe.rb
#
# For each of nine fixtures: the pinned compiler writes the hosted C and the
# core map, spinel-core-emit lowers the closure to a Mach-O object, the two
# link into an executable that must run. The object exports exactly the mapped
# symbol, with the leading underscore, and has no undefined symbol. Then a
# stub object takes over the body (routing), a link without the object fails
# (missing body), and the minimum host integer prints as itself.
#
# Each executable's answer is compared with CRuby's in the gated section
# `cruby-answers` (tests/ORACLES.tsv). Without ALLOW_ORACLE=1 the executables
# still run and must exit 0; their answers are not compared.
#
# LLVM_PREFIX is required. SPINEL_SEAM (default vendor/spinel),
# SPINEL_CORE_BUILD (default tools/mlir/native/build) and RUBY (default ruby)
# select the parts; SPINEL_PROBE_LOG names a file for every command's
# arguments, status and output, as JSON. Stops at the first
# failed check with exit 1, and refuses another host; prints one PASS line
# otherwise.
#
# Written in the Ruby the pinned Spinel accepts, and run with CRuby.

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../../tools/oracle/gate"

ROOT = File.expand_path("../..", __dir__)

class ProbeFailure < StandardError
end

def need(cond, message)
  raise ProbeFailure, message unless cond
end

$log = []

def run(args)
  out, err, st = Open3.capture3(*args)
  $log << { "args" => args, "rc" => st.exitstatus, "stdout" => out, "stderr" => err }
  [st.exitstatus, out, err]
end

def ok(args)
  rc, out, err = run(args)
  need(rc == 0, "#{args[0]} exited #{rc}: #{err}")
  out
end

uname = ok(["uname", "-s", "-m"]).strip
abort "macos-probe: macOS arm64 probe only (this is #{uname})" unless uname == "Darwin arm64"
abort "macos-probe: set LLVM_PREFIX" if ENV.fetch("LLVM_PREFIX", "").empty?
p = File.expand_path(ENV.fetch("LLVM_PREFIX", ""))
seam = File.expand_path(ENV.fetch("SPINEL_SEAM", ROOT + "/vendor/spinel"))
build = File.expand_path(ENV.fetch("SPINEL_CORE_BUILD", ROOT + "/tools/mlir/native/build"))
ruby = ENV.fetch("RUBY", "ruby")
reader = ROOT + "/tools/contract/build/spinel-typedump"
clang = p + "/bin/clang"
nm = p + "/bin/llvm-nm"
fx = ROOT + "/tests/native-core/fixtures"
cruby = OracleGate.allow?("tests/native-core/macos-probe.rb", "cruby-answers")

out = Dir.mktmpdir("spinel-macos-probe-")
status = 0
begin
  link = lambda do |c, obj, dst|
    FileUtils.rm_f(dst)
    run([clang, "-O2", "-DSP_INT_OVERFLOW_MODE_RAISE", "-I" + seam + "/lib", c, obj,
         seam + "/lib/libspinel_rt.a", "-lm", "-o", dst])[0]
  end
  # The hosted C, the map and the core object of one fixture.
  lower = lambda do |src, method, id, stem|
    File.write(out + "/" + stem + ".c",
               ok([seam + "/bin/spinel", src, "--core", method, "--core-id=" + id,
                   "--core-map=" + out + "/" + stem + ".map", "--no-line-map", "-S"]))
    ok([build + "/bin/spinel-core-emit", "--typedump", reader, "--source", src,
        "--core-map", out + "/" + stem + ".map", "-o", out + "/" + stem + ".o", "--clang", clang])
  end
  mapped = lambda do |stem|
    File.read(out + "/" + stem + ".map").lines[1].split("\t")[1]
  end

  %w[lower lower_reversed lower_equal lower_negative two_call_sites lower_max
     lower_min_plus_one lower_span helper_closure].each do |name|
    method = name == "helper_closure" ? "pick3" : "lower"
    src = fx + "/" + name + ".rb"
    obj = out + "/" + name + ".o"
    app = out + "/" + name + ".bin"
    lower.call(src, method, "macprobe", name)
    rc = link.call(out + "/" + name + ".c", obj, app)
    need(rc == 0, "#{name}: link exited #{rc}")
    got = ok([app])
    need(got == ok([ruby, src]), "#{name}: core=[#{got}] differs from CRuby") if cruby
    sym = mapped.call(name)
    exported = ok([nm, "--defined-only", "--extern-only", obj])
    need(exported.split[-1] == "_" + sym, "#{name}: does not export _#{sym}: #{exported}")
    need(exported.lines.size == 1, "#{name}: exports more than one symbol: #{exported}")
    need(ok([nm, "-u", obj]).strip == "", "#{name}: has an undefined symbol")
    need(ok([p + "/bin/llvm-objdump", "-dr", obj]).include?("mach-o arm64"), "#{name}: not a Mach-O arm64 object")
  end

  sym = mapped.call("lower")
  File.write(out + "/stub.c", "long " + sym + "(long a,long b) { return 999; }\n")
  ok([clang, "-c", out + "/stub.c", "-o", out + "/stub.o"])
  need(link.call(out + "/lower.c", out + "/stub.o", out + "/stub.bin") == 0, "the stub core does not link")
  need(ok([out + "/stub.bin"]).strip == "999", "the call does not route to the stub core")
  rc = run([clang, "-O2", "-DSP_INT_OVERFLOW_MODE_RAISE", "-I" + seam + "/lib", out + "/lower.c",
            seam + "/lib/libspinel_rt.a", "-lm", "-o", out + "/missing.bin"])[0]
  need(rc != 0, "the hosted C links without its core object")

  # Upstream a07741ff1 and decision 0015 make INT64_MIN an ordinary value;
  # ecbe5eb removed the source checker's old literal reservation.
  lower.call(fx + "/lower_sentinel.rb", "lower", "sentinel", "sentinel")
  rc = link.call(out + "/sentinel.c", out + "/sentinel.o", out + "/sentinel.bin")
  need(rc == 0, "sentinel: link exited #{rc}")
  need(ok([out + "/sentinel.bin"]) == "-9223372036854775808\n", "sentinel: does not print the minimum")

  puts "PASS: 9 native fixtures, exports/undefined checks, stub routing, missing body, minimum integer admission"
rescue ProbeFailure => e
  puts "FAIL: #{e.message}"
  status = 1
ensure
  log = ENV.fetch("SPINEL_PROBE_LOG", "")
  File.write(log, JSON.pretty_generate($log)) unless log.empty?
  FileUtils.rm_rf(out)
end
exit status
