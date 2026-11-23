# frozen_string_literal: true

# E416 (P011 Phase B): the pure-XDP TCP slice -- the `xdp__tcp_slice__` attach
# kind and the seven builtins E406 withdrew with it.
#
# What these tests are for, and what they deliberately are NOT for:
#
#   * the generated C is pinned by tests/golden/{144_tcp_slice,
#     174_tcp_slice_builtins}.bpf.c, and whether it BUILDS AND LOADS is pinned by
#     tests/golden/compile_status.tsv. Neither is re-done here.
#   * what is here is the set of facts that live in TWO places and that no gate
#     compiles together -- the ones E412/E413/E414 each found a drift in.
#
# The load-bearing one is the syncookie asymmetry: `gen` must resize the frame
# and `check` must not. It is invisible in the golden (both are just C), it is
# invisible to the affordance gate (both compile), and getting it backwards
# produces a program that either does not load at all or silently damages the
# handshake ACK. E416 measured all three variants; this test pins the outcome.
require "minitest/autorun"
require "spinel_ebpf/capabilities"

class TcpSliceTest < Minitest::Test
  CAP = SpinelEbpf::Capabilities
  ROOT = File.expand_path("../..", __dir__)
  TPL  = File.join(ROOT, "src/codegen_c/templates")
  CC   = File.join(ROOT, "src/codegen_c/spinel_ebpf_cc.c")

  def tpl(name) = File.read(File.join(TPL, "#{name}.template.c"))
  def cc_src    = (@cc ||= File.read(CC))

  BUILTINS = %w[tcp_syncookie_gen tcp_syncookie_check tcp_reply_header
                tcp_reply_synack tcp_synack_cookie tcp_reply_data payload_starts].freeze

  # ---------------------------------------------------------------- the seven

  def test_all_seven_are_advertised_and_none_is_withdrawn
    BUILTINS.each do |b|
      assert_includes CAP.all_builtins, b, "#{b} が affordance に無い"
      refute_includes CAP::WITHDRAWN.keys, b, "#{b} が advertised と withdrawn の両方にある"
      assert CAP.signature_for(b), "#{b} に signature 無し"
    end
  end

  # E406 withdrew the seven AS A SET, on the stated ground that they only made
  # sense with the bundle. Coming back as a set is therefore part of the claim --
  # six-of-seven would leave the affordance describing a machine that cannot be
  # written. (A partial port is exactly what E406/E407/E408 kept finding.)
  def test_the_set_is_whole_in_the_codegen
    BUILTINS.each do |b|
      assert_includes cc_src, "\"#{b}\"", "#{b} が C codegen に無い"
    end
  end

  # All seven touch or resize the frame through `struct xdp_md`. The gate is not
  # decoration: in TC the same names would reach clang and die naming a C
  # identifier instead of the hook the author chose (ADR-003 / the E405 rule).
  # E460: :xdp_tail is in the mask too -- a tail-call target IS an XDP program
  # (AK_XDP is shared, the C gate cannot and need not tell them apart), and a
  # claim narrower than the implementation hides a legal move (measured).
  def test_all_seven_are_gated_to_xdp
    BUILTINS.each do |b|
      req = CAP::CONTEXT_REQUIREMENTS[b]
      refute_nil req, "#{b} に context requirement 無し"
      assert_equal %i[xdp xdp_tail], req[:kinds], "#{b} の gate が xdp 系以外を許している"
    end
  end

  # The slice attach kind discards the body, so a builtin written INSIDE it would
  # be dropped without a diagnostic. "Allowed there" would be the one context
  # where the affordance's answer is a lie, which is why xdp_tcp_slice is absent
  # from every mask above.
  def test_the_gate_does_not_admit_the_bundle_kind
    BUILTINS.each do |b|
      refute_includes CAP::CONTEXT_REQUIREMENTS[b][:kinds], :xdp_tcp_slice,
                      "#{b} が body を捨てる kind の中で許可されている"
    end
  end

  # The two literal-taking builtins cannot be called with a placeholder, so the
  # affordance has to publish a real literal -- the gate compiles `example_for`
  # verbatim, and a positional stand-in would make the gate test the refusal
  # instead of the feature.
  def test_literal_taking_builtins_publish_a_compilable_example
    { "payload_starts" => /payload_starts\(".+"\)/,
      "tcp_reply_data" => /tcp_reply_data\(.+, ".+"\)/ }.each do |b, re|
      ex = CAP.example_for(b)
      refute_nil ex, "#{b} に example 無し (gate が呼び出せない)"
      assert_match re, ex, "#{b} の example が文字列リテラルを渡していない"
    end
  end

  # ------------------------------------------------- the syncookie asymmetry

  # E416's central measurement, in the form that can rot silently.
  #
  # bpf_tcp_raw_gen_syncookie_ipv4 demands TCP_MAXLEN (60) bytes readable
  # whatever the actual header length is, so `gen` must grow the frame first.
  # bpf_tcp_raw_check_syncookie_ipv4 does not, so `check` must NOT -- it runs on
  # the handshake ACK, a frame that has to be passed on undisturbed.
  #
  # Measured on 7.1.5 (results/E416/d1_syncookie_gen_fix.txt): the un-grown form
  # -- which is what the retired Ruby oracle emitted -- does not load at all.
  def test_syncookie_gen_grows_the_frame_and_check_does_not
    gen   = tpl("bi_syncookie_gen")
    check = tpl("bi_syncookie_check")
    assert_includes gen, "bpf_xdp_adjust_tail",
                    "gen が frame を広げていない — kfunc は 60 バイト読めることを要求する (E416)"
    refute_includes check, "bpf_xdp_adjust_tail",
                    "check が frame を触っている — handshake ACK を壊す"
    assert_includes gen, "bpf_tcp_raw_gen_syncookie_ipv4"
    assert_includes check, "bpf_tcp_raw_check_syncookie_ipv4"
  end

  # The grow ALONE is not enough: variant B (grow + re-read, no explicit bound)
  # also fails to load. Two more things are load-bearing and both are one line,
  # i.e. both are the kind of thing a later tidy-up removes.
  def test_gen_keeps_the_barrier_and_the_explicit_sixty_byte_bound
    gen = tpl("bi_syncookie_gen")
    assert_includes gen, 'asm volatile("" ::: "memory")',
                    "E161 の barrier が無い — clang が data_end を ctx+4 で読み直し verifier が拒否する"
    assert_match(/\(char \*\)tcp \+ 60 > \(char \*\)data_end/, gen,
                 "grow 後の明示 60 バイト境界が無い — adjust_tail だけでは verifier は学ばない (E416 variant B)")
  end

  # The reason the two are separate templates at all. If they ever merge back
  # into one parameterised template, one of the two behaviours is wrong.
  def test_gen_and_check_are_separate_templates
    assert File.exist?(File.join(TPL, "bi_syncookie_gen.template.c"))
    assert File.exist?(File.join(TPL, "bi_syncookie_check.template.c"))
    refute File.exist?(File.join(TPL, "bi_syncookie.template.c")),
           "gen と check が 1 つの template に戻っている — 片方は frame を広げ、片方は広げてはいけない"
  end

  # The caller-visible consequence of the grow, which is why it is documented
  # rather than hidden: gen leaves a 60-byte TCP header behind and reply_synack
  # is what shrinks it. Both halves have to say so.
  def test_the_resize_is_stated_where_a_caller_would_look
    assert_match(/tcp_synack_cookie/, CAP.signature_for("tcp_syncookie_gen")[:summary],
                 "gen の説明が、1 呼出で済む代替を指していない")
    assert_match(/60|広げ/, CAP.signature_for("tcp_syncookie_gen")[:summary],
                 "gen の説明が frame の resize に触れていない")
  end

  # ------------------------------------------------------- the attach kind

  def test_attach_kind_is_advertised_and_not_withdrawn
    e = CAP::ATTACH_KINDS.find { |a| a[:kind] == :xdp_tcp_slice }
    refute_nil e, "xdp_tcp_slice が ATTACH_KINDS に無い"
    assert_equal "xdp", e[:sec]
    refute_includes CAP::WITHDRAWN_ATTACH.keys, :xdp_tcp_slice
  end

  # The one attach kind whose body is thrown away. It has to be MACHINE-READABLE
  # (the affordance gate's stage 2 asks "did the body reach the C?", which is
  # false here by design) and it has to be readable by a person, because nothing
  # downstream will ever tell them: the compile succeeds and the slice works.
  def test_the_discarded_body_is_declared_not_just_documented
    e = CAP::ATTACH_KINDS.find { |a| a[:kind] == :xdp_tcp_slice }
    assert_equal :discarded, e[:body]
    assert_equal "spnl_tcp_slice_main", e[:emits],
                 "body を捨てる以上、gate が代わりに探すシンボルを名指しする必要がある"
    assert_includes tpl("tcp_slice"), "spnl_tcp_slice_main",
                    "affordance が名指しするシンボルを template が出していない"
  end

  # The codegen and the affordance must agree that this prefix is checked BEFORE
  # the plain `xdp__` one -- "xdp__tcp_slice__health" starts with "xdp__", and
  # answering from the shorter prefix is E407's false negative exactly.
  def test_the_bundle_prefix_is_matched_before_plain_xdp
    # E461: match order は attach_schema.h のテーブル行順が正本 (cc_detect_attach は
    # first-match で歩くだけ)。shadow の一般則は tools/attach_gate.rb が守り、ここは
    # tcp_slice の固有の順序 (E407 の false negative の再演防止) を名指しで固定する。
    schema = File.read(File.expand_path("../../src/codegen_c/attach_schema.h", __dir__))
    i_slice = schema.index('.prefix = "xdp__tcp_slice__"')
    i_plain = schema.index('.prefix = "xdp__"')
    refute_nil i_slice, "xdp__tcp_slice__ の行が無い"
    refute_nil i_plain
    assert i_slice < i_plain,
           "xdp__ の行が先に来ている — tcp_slice が普通の XDP として lower される"
  end

  # ------------------------------------------------------------- the maps

  def test_both_maps_are_claimed_with_what_happens_when_they_fill
    %w[bpf_conntab bpf_ts_counters].each do |m|
      claim = CAP::MAPS.find { |x| x[:map] == m }
      refute_nil claim, "#{m} の claim が無い"
      assert_equal %w[xdp_tcp_slice], claim[:created_by]
      refute_empty claim[:when_full].to_s, "#{m} に when_full 無し"
    end
    conntab = CAP::MAPS.find { |x| x[:map] == "bpf_conntab" }
    # The one that matters operationally: an LRU does not fail, it forgets, and
    # the forgetting shows up as requests that are never answered.
    assert_match(/LRU|追い出/, conntab[:when_full])
  end

  # ------------------------------------------------------- the kernel floor

  # The slice raises the floor to 6.8 -- higher than SEC("xdp") (5.9), higher
  # than the bpf_timer it embeds (5.15), higher than USER_RINGBUF (6.1, which was
  # the previous maximum). Under-reporting a floor is the one direction the
  # portability contract may never take (E401), so both kfunc markers are listed.
  def test_both_syncookie_kfuncs_raise_the_floor_to_6_8
    require "spinel_ebpf/portability"
    mk = SpinelEbpf::Portability::MIN_KERNEL
    %w[bpf_tcp_raw_gen_syncookie_ipv4 bpf_tcp_raw_check_syncookie_ipv4].each do |sym|
      f = mk[sym]
      refute_nil f, "#{sym} が MIN_KERNEL に無い (下限の過小申告になる)"
      assert_equal "6.8", f.kernel
    end
    # The bundle uses both; a hand-written slice may use only one. Either alone
    # has to produce the same floor, which is why they are two entries and not
    # one -- E401's lesson about a missing marker under-reporting.
    assert_equal mk["bpf_tcp_raw_gen_syncookie_ipv4"].kernel,
                 mk["bpf_tcp_raw_check_syncookie_ipv4"].kernel
  end
end
