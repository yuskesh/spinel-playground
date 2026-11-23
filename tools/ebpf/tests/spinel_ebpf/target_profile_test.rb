# frozen_string_literal: true
#
# E455: TargetProfile — eligibility を target 相対にした最初の一歩の契約。
#
# 固定するもの:
#   (1) linux-ebpf profile は歴史的な ebpf_impossible?/reasons と完全同値
#       (delegator 経由の全既存呼び手が 1 文字も変わらない)
#   (2) AMP profile の call_allowlist は C 側 backstop (amp_scan_supported、
#       src/codegen_c/spinel_ebpf_cc.c) と **lockstep** — どちらかを変えると
#       このテストが drift を名指しする (E422 の two_partitioners と同じ型)
#   (3) allowlist は識別子形の呼び出しだけを対象にする (演算子 CallNode は構造)
#   (4) E456: GPU_METAL profile — uses_float だけ非致命 (初の「flag が fatal で
#       なくなる」profile)、allowlist は C 側 gpu_scan_supported と lockstep

require "minitest/autorun"
require "spinel_ebpf/partition"

class TargetProfileTest < Minitest::Test
  P = SpinelEbpf::TargetProfile
  Flags = SpinelEbpf::Partition::MethodFlags

  # ---- (1) linux profile ≡ 歴史的挙動 ----

  def test_linux_profile_covers_every_flag
    assert_equal P::FLAG_REASONS.map(&:first), P::LINUX_EBPF.fatal_flags
  end

  def test_each_flag_is_fatal_on_linux_and_delegator_agrees
    P::ALL_FLAGS.each do |flag|
      f = Flags.default
      f[flag] = true
      assert f.impossible_for?(P::LINUX_EBPF), "#{flag} should be fatal on linux-ebpf"
      assert f.ebpf_impossible?, "delegator should agree for #{flag}"
      assert_equal f.reasons_for(P::LINUX_EBPF), f.reasons, "reasons delegator for #{flag}"
      assert_equal 1, f.reasons.length
    end
  end

  def test_clean_flags_are_eligible_on_linux
    f = Flags.default
    refute f.ebpf_impossible?
    assert_empty f.reasons
  end

  def test_linux_has_no_call_allowlist
    f = Flags.default
    f.calls.concat(%w[hist_observe pkt_len anything_at_all])
    refute f.impossible_for?(P::LINUX_EBPF)
    assert_empty f.unsupported_calls_for(P::LINUX_EBPF)
  end

  # ---- (2) AMP allowlist は C 側 backstop と lockstep ----
  #
  # E465 以降、allowlist の正本は builtin_schema.h の cc_builtin_targets で、
  # Ruby profile は生成 JSON から読み、C backstop は cc_builtin_on_target() で
  # 同じ表を歩く。よってこの test が守るのは 2 点に変わる:
  #   (a) profile の allowlist == 表の該当 target 行 (JSON 供給の再リテラル化を検出)
  #   (b) backstop が本当に表を参照している (機構の witness — strcmp チェーンへの
  #       退行は、表を広げても backstop が古い集合で die し続ける乖離になる)

  C_SOURCE = File.expand_path("../../src/codegen_c/spinel_ebpf_cc.c", __dir__)
  SCHEMA_H = File.expand_path("../../src/codegen_c/builtin_schema.h", __dir__)

  def schema_side_allowlist(tgt_macro)
    src = File.read(SCHEMA_H)
    table = src[/static const CcBuiltinTargets cc_builtin_targets\[\] = \{(.*?)\n\};/m, 1]
    refute_nil table, "cc_builtin_targets が builtin_schema.h に見当たらない (構造が変わった?)"
    table.scan(/\{\s*"(\w+)",\s*([^}]+)\}/)
         .select { |_, bits| bits.include?(tgt_macro) }
         .map(&:first).sort
  end

  def assert_backstop_walks_the_table(scan_fn, tgt_macro)
    src = File.read(C_SOURCE)
    fn = src[/static void #{scan_fn}.*?\n\}/m]
    refute_nil fn, "#{scan_fn} not found in spinel_ebpf_cc.c — the C backstop moved; update this test AND the profile together"
    assert_includes fn, "cc_builtin_on_target(nm, #{tgt_macro})",
                    "#{scan_fn} が cc_builtin_on_target(#{tgt_macro}) を参照していない — " \
                    "backstop が表以外の綴りに退行すると、表を広げても die し続ける"
  end

  def test_amp_allowlist_lockstep_with_c_backstop
    assert_equal schema_side_allowlist("CC_TGT_AMP"), P::AMP.call_allowlist.sort,
                 "AMP profile と builtin_schema.h の allowlist が乖離 — 片方だけ変えた"
    assert_backstop_walks_the_table("amp_scan_supported", "CC_TGT_AMP")
  end

  def test_amp_supported_summary_matches_c_message
    src = File.read(C_SOURCE)
    # C の die 文面が列挙する supported セットと profile の要約が同じ内容を指す
    assert_includes src, "Supported: #{P::AMP.supported_summary}",
                    "amp_scan_supported の die 文面と profile.supported_summary が乖離"
  end

  # ---- (3) allowlist の意味論 ----

  def test_amp_rejects_identifier_calls_outside_allowlist
    f = Flags.default
    f.calls.concat(%w[hist_observe spnl_emit])
    assert f.impossible_for?(P::AMP)
    assert_equal %w[hist_observe], f.unsupported_calls_for(P::AMP)
    reason = f.reasons_for(P::AMP).join("; ")
    assert_includes reason, "hist_observe"
    assert_includes reason, "amp"
  end

  def test_amp_accepts_allowlisted_and_operator_calls
    f = Flags.default
    f.calls.concat(["spnl_emit", "ktime_ns", "+", "<<", ">=", "=="])
    refute f.impossible_for?(P::AMP)
  end

  def test_amp_still_applies_structural_flags
    f = Flags.default
    f.uses_float = true
    f.calls << "spnl_emit"
    assert f.impossible_for?(P::AMP)
  end

  # ---- (4) E456: GPU_METAL — float 非致命 + C backstop lockstep ----

  def test_gpu_profile_drops_only_uses_float
    assert_equal [:uses_float], P::ALL_FLAGS - P::GPU_METAL.fatal_flags,
                 "gpu-metal の非致命 flag は uses_float だけのはず"
  end

  def test_gpu_float_is_eligible_but_structure_still_fatal
    f = Flags.default
    f.uses_float = true
    f.calls.concat(%w[gpu_load gpu_store gpu_global_id])
    refute f.impossible_for?(P::GPU_METAL), "float は GPU では適格"
    assert f.ebpf_impossible?, "同じ flags が linux では不適格のまま"
    f2 = Flags.default
    f2.uses_float = true
    f2.uses_io = true
    assert f2.impossible_for?(P::GPU_METAL), "IO は GPU でも致命"
  end

  def test_gpu_allowlist_lockstep_with_c_backstop
    assert_equal schema_side_allowlist("CC_TGT_GPU_METAL"), P::GPU_METAL.call_allowlist.sort,
                 "GPU_METAL profile と builtin_schema.h の allowlist が乖離 — 片方だけ変えた"
    assert_backstop_walks_the_table("gpu_scan_supported", "CC_TGT_GPU_METAL")
  end

  def test_gpu_supported_summary_matches_c_message
    src = File.read(C_SOURCE)
    assert_includes src, "Supported: #{P::GPU_METAL.supported_summary}",
                    "gpu_scan_supported の die 文面と profile.supported_summary が乖離"
  end

  def test_gpu_rejects_identifier_calls_outside_allowlist
    f = Flags.default
    f.calls.concat(%w[spnl_emit gpu_load])   # spnl_emit は AMP では OK / GPU では不可
    assert f.impossible_for?(P::GPU_METAL)
    assert_equal %w[spnl_emit], f.unsupported_calls_for(P::GPU_METAL)
  end

  def test_allowlist_profiles_carry_a_remedy
    [P::AMP, P::GPU_METAL].each do |prof|
      refute_nil prof.remedy, "#{prof.name}: allowlist profile は remedy (直し方) を持つ (E435)"
    end
  end

  # ---- classify が target を運ぶ (Result 経由) ----

  def test_result_carries_target_default_linux
    assert SpinelEbpf::Partition::Result.members.include?(:target)
  end
end
