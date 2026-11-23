# frozen_string_literal: true
#
# Run: ruby -Isrc -Itests tests/spinel_ebpf/error_quality_test.rb
#
# E317 (ADR-015 原則2「loud failure」+ 投資優先(b)): AI 自己修正のための
# **エラー品質**を機械強制する。わざと壊した 5 種の probe が、cryptic/silent でなく
# **actionable** (何が・なぜ・どこ・どう直すか) なメッセージで落ちることを test で固定。
# silent に通る回帰 (最悪 = thesis 違反) を捕まえる。
#
# fixtures は tests/fixtures/e317/ に隔離 (golden.rb / cgen_oracle / stage2 の
# `tests/fixtures/*.ir` glob に混ざらない)。各 probe は valid Ruby なので spinel が
# .ast/.ir を生成できる (壊れているのは eBPF 適格性であって構文ではない)。

require "minitest/autorun"
require "spinel_ebpf/partition"
require "spinel_ebpf/validate"
require "spinel_ebpf/codegen_bpf"
require "spinel_ebpf/capabilities"

class ErrorQualityTest < Minitest::Test
  # Measured (a model authoring from errors alone, no affordance): the author
  # reached for `parent_is` and the error named no candidate, so it GUESSED
  # `parent_path_eq` and happened to be right. Edit distance cannot bridge that
  # pair -- the names differ by 6 edits -- but they share the token `parent`,
  # and in a snake_case vocabulary a shared token is the signal. An error that
  # says only "no such builtin" sends the author back to guessing, which is the
  # one thing the loud-error contract exists to prevent.
  def test_unknown_builtin_names_candidates_that_share_a_name_part
    err = assert_raises(SpinelEbpf::Validate::Error) do
      SpinelEbpf::Validate.check_unknown_builtins!(
        [{ name: "parent_is", method: "fmod_ret__security_file_open" }]
      )
    end
    assert_includes err.message, "parent_path_eq",
                    "must name the builtin sharing the `parent` token, not just say 'unknown'"
    assert_includes err.message, "capabilities",
                    "must still point at the full list"
  end

  # The suggestion must not fire on a name with nothing in common -- a list of
  # unrelated builtins is noise, and noise trains the reader to skip the line.
  def test_unknown_builtin_with_no_shared_token_stays_generic
    err = assert_raises(SpinelEbpf::Validate::Error) do
      SpinelEbpf::Validate.check_unknown_builtins!(
        [{ name: "zzqqxx", method: "kprobe__vfs_read" }]
      )
    end
    refute_match(/did you mean|share/i, err.message,
                 "nothing is close or related, so claim neither")
  end

  P   = SpinelEbpf::Partition
  V   = SpinelEbpf::Validate
  GEN = SpinelEbpf::CodegenBpf
  CAP = SpinelEbpf::Capabilities
  FIX = File.expand_path("../fixtures/e317", __dir__)

  def load(name)
    ir  = SpinelEbpf::ParseSpinelIR.parse_file("#{FIX}/#{name}.ir")
    ast = SpinelEbpf::ParseSpinelAst.parse_file("#{FIX}/#{name}.ast")
    [ir, ast, P.classify(ir, ast)]
  end

  # validate! が Validate::Error を上げ、その message が全キーワードを含むことを固定。
  def assert_validate_error(name, *keywords)
    _ir, ast, r = load(name)
    err = assert_raises(V::Error, "#{name}: expected a loud Validate::Error") do
      V.validate!(ast, r)
    end
    keywords.each do |kw|
      assert_includes err.message, kw, "#{name}: message missing #{kw.inspect}\n  got: #{err.message}"
    end
    err.message
  end

  # codegen が UnsupportedNode を上げ、その message が全キーワードを含むことを固定。
  def assert_codegen_error(name, *keywords)
    ir, ast, r = load(name)
    err = assert_raises(GEN::UnsupportedNode, "#{name}: expected a codegen UnsupportedNode") do
      GEN.emit(ir, ast, r, base_name: name)
    end
    keywords.each do |kw|
      assert_includes err.message, kw, "#{name}: message missing #{kw.inspect}\n  got: #{err.message}"
    end
    err.message
  end

  # ---------- #1: eBPF-illegal Ruby は loud に落ちる (silent native no-op でなく) ----------

  # float を使う attach ハンドラは、黙って native (= 発火しない no-op) にならず、
  # 構文名 (Float) + 理由 + method 名 + 直し方を含む hard error になる。
  def test_p1_float_attach_handler_is_loud_not_silent_native
    msg = assert_validate_error("p1_float",
                                "kprobe__do_sys_openat2",     # どこ (method)
                                "Float",                       # 何 (構文)
                                "never fire",                  # なぜ silent がまずいか
                                "eBPF subset")                 # どう直すか
    # 「silent に native 化して成功扱い」でないこと = attach 名を名指ししている。
    assert_includes msg, "attach handler"
  end

  def test_p1_regex_attach_handler_is_loud
    assert_validate_error("p1_regex", "kprobe__do_sys_openat2", "regex", "never fire")
  end

  # heap 反復 (`[1,2,3].map`) は cryptic な "not yet ported" でなく、名指し + 直し方。
  def test_p1_heap_iteration_is_named_not_cryptic
    assert_validate_error("p1_heap", ".map", "heap", "eBPF-illegal", "n.times")
  end

  # ---------- #2: builtin を誤った context (gate) — 許可 context を名指す ----------

  def test_p2_gate_names_allowed_hooks
    msg = assert_codegen_error("p2_gate", "emit_path", "kernel-gated")
    # 許可 context (E286 の 3 hook) を `def <hook>` 形 (SEC の / を __ に) で名指す。
    CAP::DPATH_OK_SECS.each do |sec|
      hook = sec.sub("/", "__")   # lsm/file_open -> lsm__file_open
      assert_includes msg, hook, "gate error should name #{sec} (#{hook})"
    end
    # E390: 許可 hook が 3 -> 30 超になったので、ただ並べるのではなく
    # **どの引数がパスを持つか** で束ねる (読み手が選ぶのはそこ)。
    ["file arg", "path arg", "binprm arg"].each { |g| assert_includes msg, g }
    # 理由 (なぜここでは使えないのか) と出典が本文にある。
    assert_includes msg, "sleepable"
    assert_includes msg, "btf_allowlist_d_path"
    assert_includes msg, "E390"
  end

  # ---------- #3: arity ミス — builtin 名 + 期待 arity を名指す ----------

  def test_p3_arity_names_builtin_and_expected
    assert_codegen_error("p3_arity", "hist_observe", "expects 1 arg")
  end

  # ---------- #4: 未知 builtin (typo) — 名指し + did-you-mean 候補 ----------

  def test_p4_typo_offers_did_you_mean
    msg = assert_validate_error("p4_typo",
                                "hist_observ",       # typo を名指す
                                "did you mean",       # 提案がある
                                "hist_observe")       # 正しい候補
    # 候補の signature も見せる (arity/param、affordance 由来)。
    assert_includes msg, "value"
  end

  # ---------- #5 (最重要): 不完全な必須組 — silent でなく loud ----------

  # `http_req_start` だけ書いて相方 (http_resp_stash / http_emit) を書かないと、
  # 現状は span が出ないのに exit 0 (silent)。E317 で loud に。
  def test_p5_http_incomplete_set_is_loud
    msg = assert_validate_error("p5_http",
                                "http_span",          # 契約名
                                "http_req_start",     # 使っているもの
                                "http_emit")          # 欠けている相方
    assert_includes msg, "incomplete builtin set"
  end

  def test_p5_l7_incomplete_pair_is_loud
    assert_validate_error("p5_l7", "req_start", "emit_l7", "incomplete builtin set")
  end

  # ---------- E320 GAP-2 (最重大): attach 名 typo が silent でなく loud ----------

  # `def kprobe_do_sys_openat2` (単一 `_`) は孤児 SEC("syscall") に化けて一生発火
  # しない (E319 で全 4 段 green を実測)。E320 で did-you-mean 付き hard error に。
  def test_g2_attach_name_typo_is_loud_with_did_you_mean
    msg = assert_validate_error("p6_attach_typo",
                                "kprobe_do_sys_openat2",     # typo を名指す (単一 _)
                                "did you mean",               # 提案がある
                                "kprobe__do_sys_openat2",     # 正しい double-__ 形
                                "single underscore",          # なぜ危ういか
                                'SEC("syscall")',             # 何に化けるか
                                "never fires")                # silent の帰結
    # attach handler だと明示し、helper へのリネーム逃げ道も示す (over-strict でない)。
    assert_includes msg, "attach"
  end

  # 別 attach-kind でも 1 例: 検出は capabilities ATTACH_KINDS の word 由来なので汎用。
  def test_g2_typo_suggestion_generalizes_across_kinds
    { "xdp_main"                    => "xdp__main",
      "lsm_file_open"               => "lsm__file_open",
      "sock_ops_observer"           => "sock_ops__observer",
      "fmod_ret_security_file_open" => "fmod_ret__security_file_open" }.each do |typo, want|
      hit = V.attach_name_typo_suggestion(typo)
      refute_nil hit, "#{typo}: expected a typo suggestion"
      assert_equal want, hit[1], "#{typo}: wrong suggestion"
    end
  end

  # 締めすぎ回避: valid な `__` 形は detect_attach が拾う (typo 対象外)。
  def test_g2_valid_double_underscore_is_not_a_typo
    # attach_name_typo_suggestion は「単一 _ → __ で valid になる」ものだけを返す。
    # 正しい `__` 形は rest が `_` 始まりになり除外される (= 誤検出しない)。
    assert_nil SpinelEbpf::Validate.attach_name_typo_suggestion("kprobe__do_sys_openat2")
    # plain helper 風の名前 (attach word で始まらない) も対象外。
    assert_nil SpinelEbpf::Validate.attach_name_typo_suggestion("path_key")
    assert_nil SpinelEbpf::Validate.attach_name_typo_suggestion("record_path_hit")
  end

  # ---------- E320 GAP-1: latency_start/end の余分な引数が loud ----------

  # `latency_start(1)` は arity 0 なのに C codegen は引数を silent に捨てていた
  # (sibling lat_start は arity 検査あり)。E320 で "expects no arguments" に整合。
  def test_g1_latency_start_extra_arg_is_loud
    assert_validate_error("p7_latency_arg",
                          "latency_start",           # どの builtin か
                          "expects no arguments",     # 期待 arity
                          "kprobe__do_sys_openat2")   # どこ (method)
  end

  # E420 (6): `kernel_cache` は本番 codegen に無い。**沈黙の形が最悪だった**ので
  # (partition は eBPF メソッドを 1 本宣言し、codegen は program 0 本の .bpf.c を出し、
  # --build は成功し、binary は "BPF loaded and attached" と印字して何も serve しない)、
  # 作者の書いた綴りがまだ見える層で loud に落とす。
  def test_kernel_cache_directive_is_loud
    msg = assert_validate_error("p6_kernel_cache",
                                "kernel_cache",        # 何が
                                "not implemented",     # なぜ (無い)
                                "E188",                # 出典 (どこで作られたか)
                                "zero programs",       # 何が起きていたか (実測)
                                "xdp__tcp_slice__")    # 直し方 (本番に在る代替)
    assert_includes msg, "/ping", "宣言したパスを名指ししていない (どこ)"
  end

  # ---------- 2 軸ハーネス: 正当な probe は通す (締めすぎない) ----------

  # 完全な http 3-フック probe は validate + codegen を通る (over-strict でない)。
  def test_ok_http_complete_set_passes
    ir, ast, r = load("ok_http")
    V.validate!(ast, r)   # raise しないこと
    assert GEN.emit(ir, ast, r, base_name: "ok_http").length > 0
  end

  # emit_connect は単独で valid (E294) — 必須組に載せていない (2 軸: 正当形を弾かない)。
  def test_emit_connect_is_standalone_valid
    # 契約データに emit_connect の単独必須が無いこと。
    refute CAP.missing_companions(%w[emit_connect]).any? { |g| g[:present].include?("emit_connect") },
           "emit_connect must be standalone-valid (E294); do not require companions"
  end

  # ---------- 契約データの健全性 ----------

  def test_required_sets_members_are_real_builtins
    all = (GEN::BUILTIN_NAMES + GEN::DYNPTR_BUILTINS).to_set
    CAP::REQUIRED_SETS.each do |rule|
      names = rule[:mode] == :all ? rule[:members] : ([rule[:trigger]] + rule[:requires])
      names.each { |n| assert_includes all, n, "REQUIRED_SETS references unknown builtin #{n}" }
    end
  end

  # E325: kernel builtin は span record を map に貯めるだけ。userspace-export 半分
  # (ffi_func + drain ループ) が無いと compile+verify は green でも span 0 本になる。
  # 各 span 組が userspace_export companion を持ち、その push 関数が bin/spinel-ebpf
  # に実在することを固定 (相方 FFI を落とした回帰を捕まえる)。
  def test_span_sets_carry_userspace_export_to_real_push_fn
    bin_src = File.read(File.expand_path("../../bin/spinel-ebpf", __dir__))
    span_sets = CAP::REQUIRED_SETS.select { |r| r[:userspace_export] }
    # 全 :all 組 (span を生む組) は userspace_export を必ず持つ (完全性)。
    CAP::REQUIRED_SETS.select { |r| r[:mode] == :all }.each do |rule|
      refute_nil rule[:userspace_export],
                 "span-producing :all set #{rule[:name]} must carry a userspace_export (E325)"
    end
    refute_empty span_sets, "expected span-producing REQUIRED_SETS with userspace_export"
    span_sets.each do |rule|
      ue = rule[:userspace_export]
      fn = ue[:fn]
      assert_kind_of String, fn, "#{rule[:name]}: userspace_export.fn must be a String"
      refute fn.strip.empty?, "#{rule[:name]}: userspace_export.fn must be non-empty"
      # bin/spinel-ebpf に実際の C 関数定義として現れる。
      assert_includes bin_src, "int #{fn}(",
                      "#{rule[:name]}: userspace_export.fn `#{fn}` not defined in bin/spinel-ebpf"
      # ffi_decl と pattern が同じ fn 名を指す (author が写経する行が整合)。
      assert_includes ue[:ffi_decl], fn, "#{rule[:name]}: ffi_decl must name #{fn}"
      assert_includes ue[:pattern], fn,  "#{rule[:name]}: pattern must call #{fn}"
    end
  end

  # affordance JSON に required_sets が載る (E316 affordance との相乗)。
  def test_affordance_exposes_required_sets
    require "json"
    doc = JSON.parse(CAP.affordance_json)
    assert doc.key?("required_sets"), "affordance must expose required_sets (E317)"
    names = doc["required_sets"].map { |s| s["name"] }
    assert_includes names, "http_span"
    assert_includes names, "l7_latency"
  end

  # did-you-mean の Levenshtein が近傍を選ぶ (依存なし実装の健全性)。
  def test_nearest_builtin_picks_close_match
    best, dist = V.nearest_builtin("hist_observ")
    assert_equal "hist_observe", best
    assert_equal 1, dist
  end
end
