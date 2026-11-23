# frozen_string_literal: true
#
# tests/core-eligibility/run.rb -- black-box checks of source eligibility,
# never of an emitted object's ABI.
#
#   ruby tests/core-eligibility/run.rb [NAME...]
#
# Each case writes a source to a fresh directory, runs spinel-core-check on
# it and checks the exit status, the verdict and the reason. NAME runs only
# the cases of that name. Prints one line per case and a summary; exits 0
# when every case passed, 1 otherwise.
#
# The checker is $SPINEL_CORE_BUILD/bin/spinel-core-check (default
# tools/mlir/native/build), the reader $SPINEL_TYPEDUMP (default
# tools/contract/build/spinel-typedump).
#
# Each checker run has CAP seconds. One that runs longer, a hung reader
# under it included, is killed with its process group, and its case fails
# naming the cap.
#
# Written for CRuby. Apart from that watchdog (threads, a process group and
# a timed join), it is in the Ruby the pinned Spinel accepts.

require "fileutils"
require "open3"
require "tmpdir"

ROOT = File.expand_path("../..", __dir__)
BUILD = File.expand_path(ENV.fetch("SPINEL_CORE_BUILD", ROOT + "/tools/mlir/native/build"))
TOOL = BUILD + "/bin/spinel-core-check"
READER = File.expand_path(ENV.fetch("SPINEL_TYPEDUMP", ROOT + "/tools/contract/build/spinel-typedump"))

# Seconds one checker run may take.
CAP = 30

# The admitted output form's refusal text, shared by several cases.
SHARED = "top level supports only definitions and calls into the selected closure"

class CaseFailure < StandardError
end

# One checker run: its exit status, stdout and stderr.
class Result
  attr_reader :status, :out, :err

  def initialize(status, out, err)
    @status = status
    @out = out
    @err = err
  end
end

def fail_case(message)
  raise CaseFailure, message
end

def run_source(source, method = "pick", reader = READER, cap = CAP)
  fail_case("checker not built: #{TOOL}") unless File.file?(TOOL)
  # The source sits under a directory whose name has spaces. Dir.mktmpdir
  # drops them from its prefix, so they are a subdirectory's.
  dir = Dir.mktmpdir("core-eligibility-")
  begin
    Dir.mkdir(dir + "/core eligibility")
    src = dir + "/core eligibility/input.rb"
    File.write(src, source)
    capped([TOOL, src, "--method", method, "--typedump", reader], cap)
  ensure
    FileUtils.rm_rf(dir)
  end
end

# Runs args in a process group of its own. Past cap seconds the group is
# killed, so a reader the checker started dies with it and the pipes close.
def capped(args, cap)
  Open3.popen3(*args, pgroup: true) do |stdin, stdout, stderr, waiter|
    stdin.close
    out = Thread.new { stdout.read }
    err = Thread.new { stderr.read }
    unless waiter.join(cap)
      Process.kill("KILL", -waiter.pid)
      waiter.join
      out.join
      err.join
      fail_case("#{File.basename(args[0])} ran past the #{cap} s cap and was killed")
    end
    Result.new(waiter.value.exitstatus, out.value, err.value)
  end
end

def expect_status(r, status)
  fail_case("exit #{r.status}, expected #{status}\n#{r.out}#{r.err}") unless r.status == status
end

def expect_in(text, part)
  fail_case("missing #{part.inspect} in:\n#{text}") unless text.include?(part)
end

def expect_not_in(text, part)
  fail_case("unexpected #{part.inspect} in:\n#{text}") if text.include?(part)
end

def checked(source, methods = 1)
  r = run_source(source)
  expect_status(r, 0)
  expect_in(r.out, "CHECKED\tpick\t")
  expect_in(r.out, "#methods\t#{methods}\t#checked\t#{methods}")
  fail_case("stderr not empty:\n#{r.err}") unless r.err == ""
end

def denied(source, reason, verdict = "UNKNOWN", method = "pick")
  r = run_source(source, method)
  expect_status(r, 1)
  expect_in(r.out, verdict + "\t")
  expect_in(r.out, "\t" + reason + "\t")
  expect_not_in(r.out, "CHECKED\tpick\t")
  r
end

# A program the contract reader refuses before the checker gives a verdict:
# exit 2, the reader's reason on stderr, and no CHECKED row.
def unreadable(source, reason, method = "pick")
  r = run_source(source, method)
  expect_status(r, 2)
  expect_in(r.err, reason)
  expect_in(r.err, "invalid analysis contract")
  expect_not_in(r.out, "CHECKED\tpick\t")
  r
end

$only = ARGV
$passed = 0
$failed = []

def check(name)
  return unless $only.empty? || $only.include?(name)
  begin
    yield
    $passed += 1
    puts "ok    #{name}"
  rescue CaseFailure => e
    $failed << name
    puts "FAIL  #{name}"
    e.message.each_line { |l| puts "      #{l}" }
  end
end

check("scalar_comparison") do
  checked("def pick(a,b); a < b ? a : b; end\npick(1,2)\n")
end

check("local_assignment") do
  checked("def pick(a,b); x = a; x > b ? b : x; end\npick(1,2)\n")
end

check("helper_closure_and_unrelated_allocation") do
  checked("def helper(a,b); a < b ? a : b; end\n" \
          "def pick(a,b); helper(a,b); end\n" \
          "def unrelated; [1,2]; end\npick(1,2)\n", 2)
end

check("helper_allocation_path") do
  r = denied("def helper(a); x = [a]; a; end\n" \
             "def pick(a); helper(a); end\npick(1)\n",
             "heap-operation", "REFUSED")
  expect_in(r.out, "pick -> helper")
  fail_case("no input.rb:1:<column> in:\n#{r.out}") unless r.out =~ /input\.rb:1:[0-9]+/
end

check("unobserved_branch_is_checked") do
  denied("def pick(a); if a < 0; x = [a]; end; a; end\npick(1)\n",
         "heap-operation", "REFUSED")
end

check("scalar_addition_is_admitted_under_decision_0015") do
  checked("def pick(a,b); a+b; end\npick(1,2)\n")
end

check("missing_type_evidence") do
  denied("def pick(a); a; end\n", "type-evidence")
end

check("missing_root") do
  denied("def other(a); a; end\nother(1)\n", "missing-method")
end

check("recursion_terminates") do
  denied("def pick(a); a < 0 ? a : pick(a); end\npick(1)\n", "recursive-call")
end

check("duplicate_definition") do
  denied("def pick(a); a; end\ndef pick(a); 1; end\npick(1)\n", "ambiguous-method")
end

check("optional_parameter") do
  denied("def pick(a=1); a; end\npick(1)\n", "parameter-shape")
end

check("heap_parameter") do
  denied("def pick(a); a[0]; end\npick([1])\n", "heap-operation", "REFUSED")
end

check("global_state") do
  denied("$x=1\ndef pick(a); $x=a; a; end\npick(1)\n", "runtime-state", "REFUSED")
end

check("external_runtime_call") do
  denied("def pick(a); puts a; a; end\npick(1)\n", "unresolved-call")
end

# The pinned producer rewrites this call but leaves a node in the type face
# that is absent from the AST. The shared reader must fail closed.
check("send_is_not_assumed_to_be_direct") do
  r = run_source("def helper(a); a; end\ndef pick(a); send(:helper,a); end\npick(1)\n")
  expect_status(r, 2)
  expect_in(r.err, "dangling-reference")
  expect_not_in(r.out, "CHECKED")
end

check("nullable_integer") do
  denied("def pick(a); x = [a][5]; x; end\npick(1)\n", "nullable-integer")
end

# Upstream (a07741ff1) types `a` as a nullable integer, with nil out of band,
# where the pinned producer had no integer type for it at all; the refusal now
# names the nil rather than the missing type.
check("nil_argument_is_not_a_machine_integer") do
  denied("def pick(a); a; end\npick(1)\npick(nil)\n", "nullable-integer")
end

check("zero_argument_constant") do
  checked("def pick; 42; end\npick\n")
end

check("mutual_recursion") do
  denied("def helper(a); a < 0 ? a : pick(a); end\n" \
         "def pick(a); a < 0 ? a : helper(a); end\npick(1)\n", "recursive-call")
end

check("branch_helpers_are_both_checked") do
  r = denied("def yes(a); a; end\ndef no(a); x=[a]; a; end\n" \
             "def pick(a); a < 0 ? no(a) : yes(a); end\npick(1)\n",
             "heap-operation", "REFUSED")
  expect_in(r.out, "pick -> no")
  expect_in(r.out, "#methods\t3\t#checked\t0")
end

check("captured_local") do
  denied("def pick(a); f = -> { a = 2 }; f.call; a; end\npick(1)\n",
         "runtime-state", "REFUSED")
end

check("implicit_nil_result") do
  denied("def pick(a); if a < 0; 1; end; end\npick(1)\n", "implicit-nil")
end

# A reader that drops the AST's `R 2 ... receiver` lines: the definition field
# the checker needs is missing, and it must refuse rather than guess.
check("missing_definition_field_in_reader_output") do
  dir = Dir.mktmpdir("core-eligibility-reader-")
  begin
    reader = dir + "/reader"
    File.write(reader, "#!/bin/sh\n" \
                       "for last; do :; done\n" \
                       "t=\"#{dir}/out\"\n" \
                       "'#{READER}' \"$@\" > \"$t\"; rc=$?\n" \
                       "if [ \"$last\" = ast ]; then\n" \
                       "  awk '!(/^R 2 / && /receiver/)' \"$t\"\n" \
                       "else\n" \
                       "  cat \"$t\"\n" \
                       "fi\n" \
                       "exit $rc\n")
    File.chmod(0o755, reader)
    ["def pick(a); a; end\npick(1)\n",
     "def other(a); a; end\ndef pick(a); a; end\npick(1)\n"].each do |source|
      r = run_source(source, "pick", reader)
      expect_status(r, 1)
      expect_in(r.out, "\tmissing-field\t")
      expect_not_in(r.out, "CHECKED")
    end
  ensure
    FileUtils.rm_rf(dir)
  end
end

# The cap's control. A reader that never answers must fail its run by the
# cap's name, within the cap, and the hung reader must die with the checker:
# killing the checker alone passes the rest and leaves the reader behind.
# A 2 s cap stands in for the 30 s one, which this shares its code with.
check("a_hung_reader_fails_by_the_cap") do
  dir = Dir.mktmpdir("core-eligibility-hung-")
  begin
    reader = dir + "/reader"
    File.write(reader, "#!/bin/sh\necho $$ > '#{dir}/pid'\nexec sleep 600\n")
    File.chmod(0o755, reader)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    message = nil
    begin
      run_source("def pick; 1; end\npick\n", "pick", reader, 2)
    rescue CaseFailure => e
      message = e.message
    end
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    fail_case("the hung run was not stopped") if message.nil?
    expect_in(message, "spinel-core-check ran past the 2 s cap and was killed")
    fail_case("stopping it took #{took.round(1)} s") if took > 10
    pid = File.read(dir + "/pid").to_i
    alive = true
    20.times do
      begin
        Process.kill(0, pid)
      rescue Errno::ESRCH
        alive = false
        break
      end
      sleep 0.1
    end
    if alive
      Process.kill("KILL", pid)
      fail_case("the hung reader (pid #{pid}) outlived the checker")
    end
  ensure
    FileUtils.rm_rf(dir)
  end
end

check("unsupported_loop") do
  denied("def pick(a); while a < 0; a = 1; end; a; end\npick(1)\n", "unsupported-node")
end

# Decision 0041 stage 1 admits a literal block on a loop in the checked
# scalar mode only. This checker's mode refuses loops, and a block loop is
# refused as a `while` is.
check("unsupported_block_loop") do
  denied("def pick(a); s = 0; a.times { |i| s = i }; s; end\npick(1)\n", "unsupported-node")
end

check("reopened_integer_invalidates_primitive_binding") do
  denied("class Integer; def <(other); true; end; end\n" \
         "def pick(a,b); a < b ? a : b; end\npick(1,2)\n", "binding-environment")
end

# Since the 2026-11-14 upstream synchronisation the analysis writes a top-level
# prepend out as nodes the parse does not have, and the reader refuses them
# before the checker's binding-environment verdict: still refused, one layer
# earlier. The prepend inside a setup method below is not written out so, and
# keeps its verdict.
check("prepend_cannot_rebind_a_primitive_before_the_root") do
  unreadable("Integer.prepend(Module.new { def <(x); false; end })\n" \
             "def pick(a,b); a < b ? a : b; end\npick(1,2)\n", "dangling-reference")
end

check("unchecked_setup_call_cannot_change_the_environment") do
  denied("def setup; Integer.prepend(Module.new { def <(x); false; end }); end\n" \
         "setup\ndef pick(a,b); a < b ? a : b; end\npick(1,2)\n",
         "binding-environment")
end

check("top_level_assignment_is_not_assumed_harmless") do
  denied("x=1\ndef pick(a); a; end\npick(x)\n", "binding-environment")
end

check("wrong_argument_count") do
  denied("def helper(a,b); a; end\ndef pick(a); helper(a); end\npick(1)\n",
         "arity-mismatch")
end

check("literal_addition_is_admitted_under_decision_0015") do
  checked("def pick; 1+2; end\npick\n")
end

check("reader_failure_and_empty_success") do
  ["/usr/bin/false", "/usr/bin/true", "/no/such/reader"].each do |reader|
    r = run_source("def pick; 1; end\npick\n", "pick", reader)
    expect_status(r, 2)
    expect_not_in(r.out, "CHECKED")
    fail_case("no diagnostic for reader #{reader}") if r.err.strip.empty?
  end
end

# ---- decision 0005 task 3: the admitted output form -------------------
#
# The envelope admits exactly `puts <inference call>` and nothing wider. The
# blanket top-level refusal is UNCHANGED and still sits behind it, so these
# negatives fail for the same rule and the same reason they failed for before
# the change. That is the design: one shape is admitted by construction,
# rather than a list of dangerous shapes being denied. None of these cases
# asserts a reason string as evidence of safety -- each asserts the
# behaviour, that the program is refused and never CHECKED.

# Decision 0005's example. Was refused by the envelope before task 3.
check("acceptance_program_is_admitted") do
  checked("def lower(a, b)\n  a < b ? a : b\nend\n\nputs lower(7, 3)\n".gsub("lower", "pick"))
end

# The control. With no call site there is no inference evidence, so the
# method is refused for types, not for the envelope. Without this pair the
# admission could look like it accepted a method whose types were never
# proved.
check("admission_requires_a_caller_to_infer_from") do
  r = denied("def pick(a, b)\n  a < b ? a : b\nend\n", "type-evidence")
  expect_in(r.out, "parameter a is poly")
  expect_not_in(r.out, "binding-environment")
end

check("primitive_rebinding_is_still_refused_beside_the_admitted_output") do
  denied("class Integer; def <(other); true; end; end\n" \
         "def pick(a,b); a < b ? a : b; end\nputs pick(7,3)\n",
         "binding-environment")
end

check("prepend_is_still_refused_beside_the_admitted_output") do
  unreadable("Integer.prepend(Module.new { def <(x); false; end })\n" \
             "def pick(a,b); a < b ? a : b; end\nputs pick(7,3)\n",
             "dangling-reference")
end

check("rebinding_setup_helper_is_still_refused_beside_the_admitted_output") do
  denied("def setup; Integer.prepend(Module.new { def <(x); false; end }); end\n" \
         "setup\ndef pick(a,b); a < b ? a : b; end\nputs pick(7,3)\n",
         "binding-environment")
end

# 0005 refuses to classify arbitrary hosted calls as harmless because they are
# outside the selected closure. Admitting `puts` must not admit an ordinary
# hosted call that happens to look innocuous.
check("hosted_helper_call_before_the_root_is_still_refused") do
  denied("def setup; 0; end\n" \
         "def pick(a,b); a < b ? a : b; end\nsetup\nputs pick(7,3)\n",
         "binding-environment")
end

check("top_level_assignment_is_still_refused_beside_the_admitted_output") do
  denied("x=1\ndef pick(a,b); a < b ? a : b; end\nputs pick(7,3)\n",
         "binding-environment")
end

# A top-level `def` IS admitted by the envelope, so a program can define its
# own `puts`. The admitted output form must then not apply: otherwise the rule
# would admit a call to an arbitrary user method under the name it was written
# to allow.
check("a_user_defined_puts_does_not_get_admitted") do
  denied("def puts(v); v; end\n" \
         "def pick(a,b); a < b ? a : b; end\nputs pick(7,3)\n",
         "binding-environment")
end

# The admitted form is `puts <inference call>`, not `puts <anything>`.
check("puts_of_a_literal_is_not_admitted") do
  r = run_source("def pick(a,b); a < b ? a : b; end\nputs 7\n")
  expect_status(r, 1)
  expect_not_in(r.out, "CHECKED\tpick\t")
  expect_in(r.out, SHARED)
end

check("puts_of_a_call_outside_the_closure_is_not_admitted") do
  r = run_source("def other(a); a; end\n" \
                 "def pick(a,b); a < b ? a : b; end\nputs other(7)\n")
  expect_status(r, 1)
  expect_not_in(r.out, "CHECKED\tpick\t")
  expect_in(r.out, SHARED)
end

# Exactly one argument. Two would be two ingresses and a different output
# operation than the one decision 0005 admits.
check("puts_of_two_calls_is_not_admitted") do
  denied("def pick(a,b); a < b ? a : b; end\n" \
         "puts pick(7,3), pick(1,2)\n", "binding-environment")
end

check("puts_with_a_block_is_not_admitted") do
  denied("def pick(a,b); a < b ? a : b; end\n" \
         "puts pick(7,3) { 1 }\n", "binding-environment")
end

# The minimum host integer is an ordinary value. The pin reserved it as the
# nil of an Integer slot, so a literal at it made the closure bigint;
# upstream a07741ff1 moved nil out of band and decision 0015 admits the whole
# host range, so the closure is checked like any other.
check("minimum_host_integer_literal_argument_is_admitted") do
  checked("def pick(a,b); a < b ? a : b; end\n" \
          "puts pick(-9223372036854775808, 3)\n")
end

# History, kept deliberately.
#
# Before task 3 the rebinding negatives and the program task 3 had to admit
# were refused by the same rule and the same reason string, so those
# negatives were not protected by anything aimed at rebinding. The change did
# not fix that by adding a rebinding detector -- it left the blanket rule
# alone and admitted one shape in front of it. So the negatives are still
# held by the blanket rule, and this records that, rather than letting a
# future reader assume a targeted protection exists.
#
# What changed is only that the admitted program no longer shares their fate.
check("the_blanket_refusal_is_what_still_holds_the_negatives") do
  rebinding = run_source("class Integer; def <(other); true; end; end\n" \
                         "def pick(a,b); a < b ? a : b; end\nputs pick(7,3)\n")
  admitted = run_source("def pick(a, b)\n  a < b ? a : b\nend\n\nputs pick(7, 3)\n")
  expect_in(rebinding.out, SHARED)
  expect_status(rebinding, 1)
  expect_not_in(admitted.out, SHARED)
  expect_status(admitted, 0)
end

# ---- ingress enumeration (task 2 report 4b) ---------------------------
#
# The closure is computed root-downwards, so it records who the root CALLS
# and nothing about who calls IT. These pin the other direction.

# `unused` is never called, so this program runs correctly today -- the top
# level admits no call to a non-member, so `unused` is unreachable. It is
# refused anyway, because that safety comes from the envelope being narrow
# rather than from anything checking it, and the argument `unused` would pass
# has no established domain.
check("a_method_outside_the_closure_calling_the_root_is_refused") do
  denied("def pick(a, b)\n  a < b ? a : b\nend\n\n" \
         "def unused(x)\n  pick(x, 3)\nend\n\n" \
         "puts pick(7, 3)\n", "unaccounted-ingress")
end

# The same thing one level in: the ingress is into a HELPER, which the root's
# own walk has even less reason to notice.
check("a_method_outside_the_closure_calling_a_helper_is_refused") do
  denied("def lower(a, b)\n  a < b ? a : b\nend\n\n" \
         "def pick(a, b, c)\n  lower(lower(a, b), c)\nend\n\n" \
         "def other(y)\n  lower(y, 1)\nend\n\n" \
         "puts pick(7, 3, 5)\n", "unaccounted-ingress", "UNKNOWN", "pick")
end

# The control that keeps the rule from being 'refuse any other def'.
# `unrelated` calls nothing in the closure, so it is not ingress -- and the
# integer literals in its body are not node references, which an earlier
# version of this walk read them as.
check("an_unrelated_definition_is_not_an_ingress") do
  checked("def helper(a,b); a < b ? a : b; end\n" \
          "def pick(a,b); helper(a,b); end\n" \
          "def unrelated; [1,2]; end\npick(1,2)\n", 2)
end

check("calls_between_closure_members_are_not_ingress") do
  checked("def lower(a, b)\n  a < b ? a : b\nend\n\n" \
          "def pick(a, b, c)\n  lower(lower(a, b), c)\nend\n\n" \
          "puts pick(7, 3, 5)\n", 2)
end

check("syntax_error") do
  r = run_source("def pick(\n")
  expect_status(r, 2)
  expect_not_in(r.out, "CHECKED")
end

puts "#{$passed} passed, #{$failed.size} failed"
exit($failed.empty? ? 0 : 1)
