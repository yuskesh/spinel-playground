# frozen_string_literal: true
#
# E455: a compilation target as a first-class profile.
#
# E454 measured what "target" meant before this file existed: partition knew a
# single binary verdict (:ebpf | :native) driven by one hardcoded impossibility
# set, and the AMP target rode on top of it -- per-unit CLI flag, an env var
# into codegen, and a SECOND eligibility mechanism (amp_scan_supported's
# builtin allowlist, E356) living in C with no Ruby-side counterpart. Two
# eligibility implementations with no lockstep is the same drift surface E422
# closed for the two partitioners.
#
# A TargetProfile carries the two dimensions eligibility actually has:
#
#   fatal_flags     which MethodFlags kill a method for this target
#                   (floats are fatal on eBPF, fine on a GPU; IO is fatal on both)
#   call_allowlist  for restricted targets (AMP v0), which identifier-shaped
#                   calls the target's codegen can lower at all. nil = the
#                   target has a full builtin surface and flags alone decide.
#
# The C-side AMP check (amp_scan_supported in src/codegen_c/spinel_ebpf_cc.c)
# stays as the backstop on the direct in-process path -- the regression harness
# drives that binary without Ruby in front. The lockstep between this file's
# AMP allowlist and the C source is pinned by
# tests/spinel_ebpf/target_profile_test.rb; change either side and the test
# names the drift.

module SpinelEbpf
  class TargetProfile
    # E465 (ADR-019 Phase C stage 4): the per-target existence axis is declared
    # once in src/codegen_c/builtin_schema.h (the same table the C backstops
    # walk via cc_builtin_on_target) and rendered by `make -C src/codegen_c
    # builtin-schema`. The allowlists below are READ from that artifact --
    # writing them here as literals was the third spelling of one fact
    # (Ruby array / C strcmp chain / E463 g_gpu filter). Prose halves
    # (supported_summary / remedy) stay here: they are not shared facts.
    BUILTIN_SCHEMA = begin
      require "json"
      path = File.expand_path("builtin_schema_gen.json", __dir__)
      unless File.exist?(path)
        raise "builtin schema artifact missing: #{path} " \
              "(run: make -C src/codegen_c builtin-schema)"
      end
      JSON.parse(File.read(path)).freeze
    end

    # Builtins declared to exist on target `tname` ("amp" / "gpu-metal"), in
    # declaration order. Names absent from the table are linux-only (default).
    def self.schema_allowlist(tname)
      BUILTIN_SCHEMA.fetch("targets")
                    .select { |r| r.fetch("targets").include?(tname) }
                    .map { |r| r.fetch("name") }.freeze
    end

    attr_reader :name, :fatal_flags, :call_allowlist, :supported_summary, :remedy

    # remedy: the "how to fix" tail of the unsupported-call message (E435: an
    # actionable error is subject + remedy). Only allowlist-carrying profiles
    # need one -- the CLI enforcement block is profile-generic (E456) and reads
    # it instead of hardcoding per-target advice.
    def initialize(name:, fatal_flags:, call_allowlist: nil, supported_summary: nil, remedy: nil)
      @name = name
      @fatal_flags = fatal_flags.freeze
      @call_allowlist = call_allowlist&.freeze
      @supported_summary = supported_summary
      @remedy = remedy
      freeze
    end

    # Operator calls (`a + b` arrives as a CallNode named "+") are lowered
    # structurally on every target; the allowlist governs identifier-shaped
    # calls only.
    def identifier_call?(name)
      name.match?(/\A[A-Za-z_]/)
    end

    def allows_call?(name)
      return true if @call_allowlist.nil?
      return true unless identifier_call?(name)
      return true if syntax_on_target?(name)   # E466: 構文は語彙 allowlist の外
      @call_allowlist.include?(name)
    end

    # E466: `times` のような SYNTAX 名は builtin ではないが、どの target で lower
    # できるかは per-target の事実 (linux/gpu-metal は可、amp v0 は loop lowering
    # 無しで不可)。正本は builtin_schema.h の cc_syntax_targets — C の scan が同じ
    # 表を歩く (cc_syntax_on_target)。
    def syntax_on_target?(name)
      row = self.class::BUILTIN_SCHEMA.fetch("syntax_targets").find { |r| r["name"] == name }
      row ? row.fetch("targets").include?(@name.sub("linux-ebpf", "linux")) : false
    end

    # The reason strings for MethodFlags#reasons, in their long-standing order.
    # A profile prints only the reasons for flags it actually treats as fatal,
    # so the linux profile reproduces the historical output byte for byte.
    FLAG_REASONS = [
      [:uses_float,                "uses Float arithmetic (no FPU in BPF)"],
      [:uses_regex,                "uses regex (no regex helper in BPF)"],
      [:uses_io,                   "performs I/O (host-side only)"],
      [:uses_thread,               "creates Thread (kernel cannot create threads)"],
      [:uses_fiber,                "uses Fiber (no fiber concept in BPF)"],
      [:uses_closure,              "uses closure with captured outer vars"],
      [:uses_recursion,            "calls itself recursively (BPF call graph is a DAG)"],
      [:uses_bignum,               "uses bignum (BPF integers are 64-bit max)"],
      [:uses_unbounded_loop,       "has loop without static upper bound"],
      [:uses_unsupported_type,     "signature uses non-int type (string/array/hash/...)"],
      [:inherits_unsupported,      "calls another method that is eBPF-impossible"],
    ].freeze

    ALL_FLAGS = FLAG_REASONS.map(&:first).freeze

    # The Linux eBPF target: the historical impossibility set, unchanged.
    LINUX_EBPF = new(
      name: "linux-ebpf",
      fatal_flags: ALL_FLAGS,
    )

    # AMP v0 (--target amp-m7 / amp-m33): same structural constraints as eBPF
    # plus a closed builtin surface. Mirrors amp_scan_supported: CallNodes may
    # be binary operators, spnl_emit or ktime_ns; everything else (including
    # calls to the author's own methods -- v0 handlers have no BPF-to-BPF
    # equivalent) has nothing to lower to on an M-core.
    AMP = new(
      name: "amp",
      fatal_flags: ALL_FLAGS,
      call_allowlist: schema_allowlist("amp"),   # E465: builtin_schema.h が正本
      supported_summary: "ivar RMW (@x/@x += n), integer arithmetic, if/locals, spnl_emit, ktime_ns",
      remedy: "Move this logic to the A55 side, or extend the amp helper set",
    )

    # E456 (P013): gpu-metal v0 (--target gpu-metal). The first profile where a
    # flag STOPS being fatal: floats are the GPU's native domain, so uses_float
    # drops out of fatal_flags (the hook E455 designed for exactly this). The
    # closed builtin surface mirrors gpu_scan_supported (spinel_ebpf_cc.c):
    # binary operators plus the three gpu builtins; ivars are refused separately
    # in the C scan (data race across GPU threads, not a missing feature), so
    # they never reach the allowlist question.
    GPU_METAL = new(
      name: "gpu-metal",
      fatal_flags: ALL_FLAGS - [:uses_float],
      call_allowlist: schema_allowlist("gpu-metal"),   # E465: builtin_schema.h が正本
      supported_summary: "gpu_buffer(:name,:float|:int,slot) declarations, float/integer arithmetic, if/locals, gpu_global_id, gpu_load, gpu_store",
      remedy: "Compute on the CPU side, or extend the gpu builtin set",
    )
  end
end
