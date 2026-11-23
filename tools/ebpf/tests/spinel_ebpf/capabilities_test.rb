# frozen_string_literal: true
#
# Run: ruby -Isrc -Itests tests/spinel_ebpf/capabilities_test.rb
#
# E314 (ADR-014 層1): ドメイン capability registry。
# 分類の完全性 (ガバナンス) + E286 context gate の中央化一致 + 内省配線を守る。

require "minitest/autorun"
require "json"
require "ripper"
require "spinel_ebpf/capabilities"
require "spinel_ebpf/codegen_bpf"
require "spinel_ebpf/introspect"

class CapabilitiesTest < Minitest::Test
  CAP = SpinelEbpf::Capabilities
  GEN = SpinelEbpf::CodegenBpf
  I   = SpinelEbpf::Introspect

  # 全 builtin の権威集合 = **affordance が宣伝しているもの** (Capabilities 自身)。
  #
  # E406 まではここが `GEN::BUILTIN_NAMES + GEN::DYNPTR_BUILTINS` (= 退役した Ruby
  # oracle codegen_bpf.rb の一覧) だった。つまり ADR-014 の「完全分割」ガバナンスは
  # affordance を **死んだ実装** に固定しており、本番 C codegen に無い 18 個を
  # 「載っていて当然」と要求し続けていた (= 正直に降ろそうとすると test が落ちる、
  # という向きに働いていた)。実測は docs/experiments/E406。
  #
  # 権威は affordance に移した。Ruby oracle との差分は
  # test_withdrawn_is_exactly_the_retired_oracle_delta が **WITHDRAWN と一致すること**
  # として保つ (歴史との接続は切らないが、authority ではなくする)。
  # 「宣伝しているものが本当に動くか」は tools/affordance_gate.rb が本番 codegen で測る
  # (この test は Ruby だけで回るので、そこまでは見られない)。
  ALL_BUILTINS = CAP.all_builtins.freeze
  RETIRED_ORACLE_BUILTINS = (GEN::BUILTIN_NAMES + GEN::DYNPTR_BUILTINS).uniq.freeze

  # ---------- 完全分割 (ADR-014 ガバナンスの核) ----------

  # すべての builtin が「ちょうど 1 つの」ドメインに分類される。未分類の新 builtin を
  # 足すとこの test が落ちる = capability マトリクスを更新せよ、という強制。
  def test_every_builtin_classified_exactly_once
    classified = CAP::DOMAINS.values.flat_map { |d| d[:builtins] }
    missing = ALL_BUILTINS - classified
    extra   = classified - ALL_BUILTINS
    assert_empty missing, "未分類の builtin (capabilities.rb に足せ): #{missing.inspect}"
    assert_empty extra,   "存在しない builtin を分類している: #{extra.inspect}"
    dups = classified.tally.select { |_, n| n > 1 }
    assert_empty dups, "複数ドメインに重複した builtin: #{dups.keys.inspect}"
    assert_equal ALL_BUILTINS.length, classified.length
    assert_equal ALL_BUILTINS.length, CAP.all_builtins.length
  end

  # (E406) 退役 Ruby oracle との差分は「降ろした 16 個」ちょうど。
  #
  # 片方向でなく両方向を見る: oracle にあって affordance に無い = WITHDRAWN、
  # affordance にあって oracle に無い = C codegen で新規に足した builtin (これは
  # 増えてよい)。前者がずれたら、黙って消したか黙って足したかのどちらかである。
  def test_withdrawn_is_exactly_the_retired_oracle_delta
    lost = (RETIRED_ORACLE_BUILTINS - ALL_BUILTINS).sort
    assert_equal CAP::WITHDRAWN.keys.sort, lost,
                 "Ruby oracle にあって affordance に無い builtin は WITHDRAWN と一致するべき " \
                 "(黙って消さない・黙って戻さない)"
    assert_empty(CAP::WITHDRAWN.keys & ALL_BUILTINS,
                 "WITHDRAWN と advertised に同じ名前がある (どちらかにする)")
    CAP::WITHDRAWN.each do |name, rec|
      assert rec[:edoc].is_a?(String) && !rec[:edoc].empty?, "#{name}: 出典 Edoc が要る"
      assert rec[:why].is_a?(String) && rec[:why].length > 20, "#{name}: 降ろした理由が要る"
      assert rec[:ctx].is_a?(Symbol), "#{name}: gate が最小 probe を組むための ctx が要る"
      assert rec[:arity].is_a?(Integer), "#{name}: 同 arity が要る"
    end
  end

  def test_domains_are_the_four_layer1_plus_core
    assert_equal %i[observability enforcement net l7 core], CAP::DOMAINS.keys
  end

  def test_domain_of_and_builtins_for
    assert_equal :observability, CAP.domain_of("hist_observe")
    assert_equal :enforcement,   CAP.domain_of("emit_path")
    assert_equal :net,           CAP.domain_of("pkt_l4_proto")
    assert_equal :l7,            CAP.domain_of("http_emit")
    assert_equal :core,          CAP.domain_of("cgroup_id")
    assert_nil   CAP.domain_of("definitely_not_a_builtin")
    assert_includes CAP.builtins_for(:l7), "ssl_req_start"
  end

  # ---------- E286 context gate の中央化 (単一の権威) ----------

  # registry の CONTEXT_GATES と codegen (Ruby oracle) の DPATH_OK_SECS が同一の
  # allowlist を指すこと。両者は同じ定数 (Capabilities::DPATH_OK_SECS) を参照する。
  def test_dpath_gate_is_centralized_and_consistent
    # E286/E284 の起点 3 hook は先頭に据え置き (後方互換 — 生成コードも byte-identical)。
    assert_equal %w[lsm/file_open fmod_ret/security_file_open fmod_ret/security_file_permission],
                 CAP::DPATH_OK_SECS.first(3)
    # E390 で実測拡張。allowlist は DPATH_HOOKS (SEC -> path 供給形) の keys そのもの。
    assert_equal CAP::DPATH_HOOKS.keys, CAP::DPATH_OK_SECS
    assert_includes CAP::DPATH_OK_SECS, "lsm/path_unlink"
    assert_includes CAP::DPATH_OK_SECS, "lsm/bprm_check_security"
    assert_includes CAP::DPATH_OK_SECS, "lsm/mmap_file"
    # codegen oracle が registry を参照している (同一オブジェクト)。
    assert_same CAP::DPATH_OK_SECS, GEN::MethodEmitter::DPATH_OK_SECS
    # 4 つの d_path builtin が gate 対象で、同じ allowlist を持つ。
    %w[emit_path emit_parent_path path_eq parent_path_eq].each do |b|
      g = CAP.gate_for(b)
      refute_nil g, "#{b} が context gate に無い"
      assert_equal :enforcement, g[:domain]
      assert_equal CAP::DPATH_OK_SECS, g[:valid_secs]
    end
    assert_nil CAP.gate_for("hist_observe"), "非 gate builtin は gate_for が nil"
  end

  # E390: allowlist は「SEC -> どの引数がパスを持つか」の表になった。表の健全性 +
  # 「実測で落ちた hook は絶対に入っていない」を固定 (ADR-003: 推測で足さない)。
  def test_e390_dpath_hooks_table_is_well_formed_and_measured
    CAP::DPATH_HOOKS.each do |sec, spec|
      assert_includes %i[file path binprm], spec[:form], "#{sec}: 未知の path 供給形"
      assert_includes [true, false], spec[:guard], "#{sec}: guard は true/false"
      refute_empty spec[:measured].to_s, "#{sec}: どの測定で LOAD_OK だったかが要る"
      assert_match(%r{\A(lsm|fmod_ret|fentry|fexit)/}, sec, "#{sec}: SEC の形が違う")
    end
    # 起点の 3 hook は file 形・guard 無し = 生成コードが E286 と byte-identical。
    %w[lsm/file_open fmod_ret/security_file_open fmod_ret/security_file_permission].each do |sec|
      assert_equal :file, CAP::DPATH_HOOKS[sec][:form]
      refute CAP::DPATH_HOOKS[sec][:guard], "#{sec} に guard を足すと出力が変わる"
    end
    # lsm/mmap_file の引数は BTF 上 file__nullable。guard は防御でなく load 必須 (c12 vs c10)。
    assert CAP::DPATH_HOOKS["lsm/mmap_file"][:guard]
    assert_equal :path,   CAP::DPATH_HOOKS["lsm/path_unlink"][:form]
    assert_equal :binprm, CAP::DPATH_HOOKS["lsm/bprm_check_security"][:form]
    # 実測で落ちた側 (E390) は allowlist と交わらない。
    refute_empty CAP::DPATH_MEASURED_REJECTED
    CAP::DPATH_MEASURED_REJECTED.each do |sec, why|
      refute_includes CAP::DPATH_OK_SECS, sec, "#{sec} は実測 REJECTED"
      refute_empty why.to_s, "#{sec}: 落ちた理由 (verifier の文言) を残すこと"
    end
  end

  # E418: gate に入っている = 「compile が通る」でしかない。E390 は 32 本のうち 4 本しか
  # **発火**を測っておらず、残り 28 本は「load できる」だけで平らに宣伝されていた
  # (E409 が map で見つけた「affordance が黙っている」と同型)。発火 tier を足したので、
  # **弱い tier ほど出典を必須にする** (E409 の `measured` と同じ規則) を test で強制する。
  def test_e418_dpath_hooks_carry_measured_firing_behaviour
    CAP::DPATH_HOOKS.each do |sec, spec|
      assert_includes %i[deny observe load_only], spec[:fire], "#{sec}: 未知の発火 tier"
      refute_empty spec[:by].to_s,    "#{sec}: **何をすれば踏めるか**が要る (load 実測とは別)"
      refute_empty spec[:fired].to_s, "#{sec}: その発火を測った Edoc の case id が要る"
      # 弱い tier (load しか確かめていない) は理由を書かないと載せられない。
      if spec[:fire] == :load_only
        refute_empty spec[:caveat].to_s,
                     "#{sec}: load_only で載せるなら「なぜ発火を測れなかったか」が要る"
      end
    end
    # E418 後は load 実測どまりの hook は 1 本も無い。
    assert_empty CAP::DPATH_HOOKS.select { |_, v| v[:fire] == :load_only }.keys
  end

  # E418 の中心的な不変量: **fentry/fexit は verdict を持たない**ので、そこに書いた
  # `-1` は codegen のラッパが捨てる ((void)inner(...); return 0;)。registry が
  # そこを :deny と名乗ったら「遮断できます」という嘘になり、しかも compile も load も
  # verifier も通ってしまう (= 誰も止められない沈黙の嘘)。表の側で構造的に禁じる。
  def test_e418_tracing_hooks_never_claim_deny
    # 「どの attach 種別が verdict を持つか」を test に手書きしない — **production の
    # 宣言テーブルから読む**。E461 以降、wrapper の分岐 (`a->verdict`) は
    # attach_schema.h の単一宣言から来る (cc_detect_attach はそれを歩くだけ) ので、
    # そこを読む。registry がそれと食い違ったら「遮断できます」という嘘になるため。
    src = File.read(File.expand_path("../../src/codegen_c/attach_schema.h", __dir__))
    verdict_by_prefix = %w[lsm fmod_ret fentry fexit].to_h { |p|
      row = src[/\{ \.ruby_kind = "#{p}",.*?\}/m]
      refute_nil row, "#{p} の行が attach_schema.h に見当たらない (構造が変わった?)"
      [p, row.include?(".verdict = 1")]
    }
    # 前提そのものが崩れていないか (C 側の事実) を先に固定する。
    assert_equal({ "lsm" => true, "fmod_ret" => true, "fentry" => false, "fexit" => false },
                 verdict_by_prefix, "verdict を持つ attach 種別が C codegen 側で変わった")

    CAP::DPATH_HOOKS.each do |sec, spec|
      prefix = sec.split("/").first
      next if spec[:fire] != :deny

      assert verdict_by_prefix[prefix],
             "#{sec}: #{prefix} は C codegen で verdict を持たない (戻り値は捨てられる) ので :deny を名乗れない"
    end
    # 明示: fentry/fexit は 1 本も :deny でない。
    assert_empty CAP::DPATH_HOOKS.select { |s, v|
      s.start_with?("fentry/", "fexit/") && v[:fire] == :deny
    }.keys
    # void hook も同じ理由 (creds 確定後なので戻り値が効かない)。E418 h07 で実測。
    assert_equal :observe, CAP::DPATH_HOOKS["lsm/bprm_committed_creds"][:fire]
    # 逆向き: verdict を持つ種別で実際に遮断まで測れた hook は :deny のまま据え置く。
    assert_equal :deny, CAP::DPATH_HOOKS["lsm/path_unlink"][:fire]
    assert_equal :deny, CAP::DPATH_HOOKS["fmod_ret/security_file_open"][:fire]
  end

  # E418: 「素直に思いつく操作では踏めない」hook は**沈黙する誤解**の巣なので、
  # caveat を落としたら test が落ちる。ここが本 Edoc の一番の成果物。
  def test_e418_silently_unreachable_hooks_keep_their_caveat
    {
      "fentry/filp_close"  => "close(2)",   # close(2) は filp_flush を直接呼ぶ
      "fexit/filp_close"   => "close(2)",
      "fentry/vfs_getattr" => "stat(2)",    # stat は vfs_getattr_nosec を直接呼ぶ
      "fexit/vfs_getattr"  => "stat(2)",
      "fentry/dentry_open" => "open(2)",    # open は do_filp_open 経路
      "fexit/dentry_open"  => "open(2)",
      "lsm/path_truncate"  => "ftruncate(2)", # E390 が空振りした実例
      "fmod_ret/security_path_truncate" => "ftruncate(2)",
    }.each do |sec, obvious|
      cav = CAP::DPATH_HOOKS[sec][:caveat].to_s
      refute_empty cav, "#{sec}: 「#{obvious} では踏めない」は書いておかないと誰も気づけない"
      assert_includes cav, obvious, "#{sec}: caveat が #{obvious} を名指ししていない"
      assert_includes cav, "does not fire", "#{sec}: caveat は「発火しない」と言い切ること"
    end
  end

  # E420: E418 の caveat のうち **「ここでパス選別を書いてはいけない」** の 4 本は
  # compile 時 die になった。拒否するのは **C 側** (`CcDpathHook.no_select`) で、
  # ここ (Ruby) は「利用者に何と言うか」。**集合が食い違うと、affordance が
  # 「書ける」と言っている綴りが die する / その逆**になるので、両表を突き合わせる。
  # 散文は言語ごとに違うので比較しない (E409 の `measured` と同じ規則)。
  def test_e420_no_select_set_matches_the_c_codegen
    src = File.read(File.expand_path("../../src/codegen_c/spinel_ebpf_cc.c", __dir__))
    table = src[/static const CcDpathHook CC_DPATH_OK\[\] = \{(.*?)\n\};/m]
    refute_nil table, "CC_DPATH_OK が C codegen に見当たらない (構造が変わった?)"
    # `no_select` を持つ entry = 4 番目の文字列 (measured) の後にもう 1 つ文字列が続くもの。
    # CC_DP_NOSEL_OVL マクロで書かれているので、SEC 名の行に `CC_DP_NOSEL_OVL(` が続く。
    c_secs = table.scan(/\{\s*"([^"]+)",\s*CC_DP_\w+,\s*\d,\s*"[^"]*",\s*\n?\s*CC_DP_NOSEL_OVL\(/m).flatten
    assert_equal CAP::DPATH_NO_SELECT_SECS.sort, c_secs.sort,
                 "affordance の no_select と C codegen の拒否集合が食い違っている " \
                 "(片方だけ動かすと「書ける」と言っている綴りが die する / その逆になる)"
    # 空になったら「非対称 gate が丸ごと消えた」ので、それも落とす (E415: 在庫に
    # 依存した control は枯れる ⇒ ここは在庫そのものについての主張なので空を禁じる)。
    assert_equal 4, CAP::DPATH_NO_SELECT_SECS.length
    CAP::DPATH_NO_SELECT_SECS.each do |sec|
      why = CAP::DPATH_HOOKS[sec][:no_select].to_s
      assert_includes why, "emit_path", "#{sec}: **何なら書けるか** が無いと hook ごと降りたと読まれる" \
        if sec.include?("fentry")   # 代表 2 本にだけ全文を要求 (残りは "同じ" で参照)
      refute_empty why, "#{sec}: 選別が成立しない理由が要る"
    end
    # 非対称そのもの: 拒否される綴りと許される綴りが重ならないこと。
    assert_empty(CAP::DPATH_SELECT_BUILTINS & CAP::DPATH_NONSELECT_BUILTINS)
    # 許可側は本当に d_path gate の builtin であること (綴りを間違えたら意味が消える)。
    (CAP::DPATH_SELECT_BUILTINS + CAP::DPATH_NONSELECT_BUILTINS).each do |b|
      refute_nil CAP.gate_for(b), "#{b} は d_path gate の builtin ではない"
    end
  end

  # E418: `lsm/*` は active LSM に bpf が無いと **attach しても沈黙する**。これは
  # hook 個別でなく種別の性質 (E390 負の対照 / E418 で 605 回 vs 0 回を実測)。
  def test_e418_lsm_active_dependency_is_by_kind_not_by_hook
    assert CAP.lsm_active_required?("lsm/file_open")
    refute CAP.lsm_active_required?("fmod_ret/security_file_open")
    refute CAP.lsm_active_required?("fentry/vfs_truncate")
    assert_equal 18, CAP::DPATH_HOOKS.keys.count { |s| CAP.lsm_active_required?(s) }
    # 1 行表現に tier / 踏み方 / 注意が全部載る (describe と capabilities が共有する)。
    line = CAP.dpath_fire_line("fentry/vfs_getattr")
    assert_includes line, "the return value is ignored"
    assert_includes line, "does not fire for stat(2)"
    assert_nil CAP.dpath_fire_line("kprobe/do_sys_openat2"), "gate 外は nil"
  end

  # gate は 2 箇所にある (production の C codegen と Ruby 側の registry)。片方だけ
  # 広げると「C では通るが Ruby fallback では死ぬ」になるので、C ソースの表を
  # parse して突き合わせる (E390)。
  def test_e390_c_codegen_gate_table_matches_the_registry
    src = File.read(File.expand_path("../../src/codegen_c/spinel_ebpf_cc.c", __dir__))
    table = src[/static const CcDpathHook CC_DPATH_OK\[\] = \{(.*?)\n\};/m, 1]
    refute_nil table, "C 側の CC_DPATH_OK テーブルが見つからない (構造が変わった?)"
    c_hooks = table.scan(/\{\s*"([^"]+)",\s*CC_DP_(FILE|PATH|BINPRM),\s*([01])\s*,/)
                   .to_h { |sec, form, guard| [sec, { form: form.downcase.to_sym, guard: guard == "1" }] }
    assert_equal CAP::DPATH_HOOKS.keys, c_hooks.keys, "gate の hook 集合が C と Ruby でずれている"
    c_hooks.each do |sec, spec|
      assert_equal CAP::DPATH_HOOKS[sec][:form],  spec[:form],  "#{sec}: path 供給形が C と Ruby でずれている"
      assert_equal CAP::DPATH_HOOKS[sec][:guard], spec[:guard], "#{sec}: NULL guard が C と Ruby でずれている"
    end
  end

  # E460: hook × builtin gate の :kinds 軸にも E390 と同じ lockstep を置く。この軸は
  # 「The kinds mirror cc_task_ctx_kind_ok exactly」という散文宣言だけで自動照合が無く、
  # 実測したら 2 箇所とも exact でなかった (kprobe_multi 欠落 / xdp_tail 欠落 — どちらも
  # claim が実装より狭い = affordance が合法手を隠す向き)。散文の mirror 宣言は測定ではない。
  def test_e460_task_ctx_kinds_mirror_the_c_switch
    src = File.read(File.expand_path("../../src/codegen_c/spinel_ebpf_cc.c", __dir__))
    body = src[/static int cc_task_ctx_kind_ok\(.*?\n\}/m]
    refute_nil body, "cc_task_ctx_kind_ok が C codegen に見当たらない (構造が変わった?)"
    ak_map = { "AK_KPROBE" => :kprobe, "AK_KRETPROBE" => :kretprobe,
               "AK_KPROBE_MULTI" => :kprobe_multi, "AK_TRACEPOINT" => :tracepoint,
               "AK_RAW_TP" => :raw_tp, "AK_FENTRY" => :fentry, "AK_FEXIT" => :fexit,
               "AK_UPROBE" => :uprobe, "AK_URETPROBE" => :uretprobe, "AK_USDT" => :usdt,
               "AK_PERF_EVENT" => :perf_event, "AK_LSM" => :lsm, "AK_FMOD_RET" => :fmod_ret }
    c_kinds = body.scan(/case (AK_\w+):/).flatten.filter_map { |ak| ak_map[ak] }
    # AK_SK_VERDICT は 9 SEC を共有するので kname で絞られる: strcmp 対象がそのまま kind 名
    c_kinds += body.scan(/strcmp\(kname, "(\w+)"\)/).flatten.map(&:to_sym)
    claimed = CAP::CONTEXT_REQUIREMENTS["has_cap"][:kinds]
    assert_equal c_kinds.sort, claimed.sort,
                 "task-ctx gate の kind 集合が C と Ruby でずれている " \
                 "(片方だけ動かすと、合法な手が claim から消える / 死ぬ手が claim に残る)"
    %w[has_cap has_cap_permitted has_cap_inheritable cap_effective ns_id in_host_ns].each do |b|
      assert_equal claimed, CAP::CONTEXT_REQUIREMENTS[b][:kinds],
                   "#{b}: 同じ cc_require_task_ctx を通るのに claim の集合が違う"
    end
  end

  # E460: `xdp_tail__` は C 側で AK_XDP を共有する (tail の着地先は XDP プログラム
  # そのもの) ので、C の CC_CTX_XDP gate は :xdp と :xdp_tail を区別できない。よって
  # :xdp を claim する mask は :xdp_tail も claim しなければ、合法手を隠す。逆に
  # :xdp_tcp_slice は body が discarded なので「allowed」が嘘になる — 含めたら落とす。
  def test_e460_xdp_masks_include_the_tail_kind
    src = File.read(File.expand_path("../../src/codegen_c/attach_schema.h", __dir__))
    row = src[/\{ \.ruby_kind = "xdp_tail",.*?\}/m]
    refute_nil row, "attach_schema.h の xdp_tail 行が見当たらない (構造が変わった?)"
    assert_includes row, ".kind = AK_XDP",
                    "xdp_tail が AK_XDP を共有しなくなった — この規則ごと見直すこと"
    xdp_masks = CAP::CONTEXT_REQUIREMENTS.select { |_, r| r[:kinds]&.include?(:xdp) }
    refute_empty xdp_masks, ":xdp を claim する mask が 1 つも無い (語彙が変わった?)"
    xdp_masks.each do |b, req|
      assert_includes req[:kinds], :xdp_tail,
                      "#{b}: C は xdp_tail__ でも受理する (AK_XDP 共有、E460 実測) のに claim が隠している"
      refute_includes req[:kinds], :xdp_tcp_slice,
                      "#{b}: tcp_slice の body は discarded — allowed は嘘になる"
    end
  end

  # E462: 中央 arity 表 (builtin_schema.h の CC_DECLARED_ARITY) は「handler が自前の
  # arity 検査を持たない builtin」だけを持つ。表の各行は Ruby 側の宣言 signature と
  # 一致しなければならない — 食い違うと「C は N を要求するのに affordance は M と教える」
  # になり、どちらかが嘘になる (E390/E460 と同じ lockstep の形)。
  def test_e462_declared_arity_table_matches_signatures
    src = File.read(File.expand_path("../../src/codegen_c/builtin_schema.h", __dir__))
    rows = src.scan(/\{ "([a-z0-9_]+)", (\d+) \}/).map { |n, a| [n, a.to_i] }
    refute_empty rows, "CC_DECLARED_ARITY が見つからない (構造が変わった?)"
    rows.each do |name, arity|
      sig = begin
        CAP.signature_for(name)
      rescue StandardError
        nil
      end
      refute_nil sig, "#{name}: 表にあるが SIGNATURES に無い (存在しない builtin の arity を守っている)"
      assert_equal sig[:arity], arity, "#{name}: C の宣言 arity と Ruby signature が食い違っている"
    end
    dup = rows.map(&:first).tally.select { |_, c| c > 1 }.keys
    assert_empty dup, "CC_DECLARED_ARITY に重複行: #{dup.join(', ')}"
  end

  # E468: targets 表の全行に probe 用の構文見本があること。gate も同じ理由で abort
  # するが、こちらは suite の速い層で同じ完全性を固定する (E407: 書けない claim は
  # 誰も検査していない claim)。
  def test_e468_every_target_row_has_a_probe_example
    CAP::BUILTIN_SCHEMA_JSON.fetch("targets").each do |row|
      name = row.fetch("name")
      ok = CAP::TARGET_BUILTIN_EXAMPLES.key?(name) ||
           (CAP.all_builtins.include?(name) && !CAP.example_for(name).nil?)
      assert ok, "#{name}: targets 表に居るが probe 用の見本が無い -- " \
                 "TARGET_BUILTIN_EXAMPLES に足すこと (gate はこれ無しでは claim を書けない)"
    end
    # 見本の側の孤児も禁じる (表に無い名前の見本は、何も主張していない死データ)
    orphan = CAP::TARGET_BUILTIN_EXAMPLES.keys -
             CAP::BUILTIN_SCHEMA_JSON.fetch("targets").map { |r| r["name"] }
    assert_empty orphan, "targets 表に無い見本: #{orphan.join(', ')}"
  end

  def test_gated_builtins_are_all_enforcement_domain
    CAP::CONTEXT_GATES.each_key do |b|
      assert_equal :enforcement, CAP.domain_of(b), "#{b} は enforcement ドメインのはず"
    end
  end

  # ---------- krew (E307) カタログとの整合 ----------

  def test_krew_probe_domains_align
    assert_equal %i[l7 enforcement l7 net],
                 %w[dns file l7 net].map { |p| CAP::KREW_PROBE_DOMAINS[p] }
    CAP::KREW_PROBE_DOMAINS.each_value do |dom|
      assert_includes CAP::DOMAINS.keys, dom, "krew が未知ドメイン #{dom} を指す"
    end
  end

  # ---------- 内省配線 (Introspect / catalog) ----------

  def test_domains_used_filters_to_present_names
    used = CAP.domains_used(%w[hist_observe emit_path pkt_len])
    assert_equal %i[observability enforcement net], used.keys
    assert_equal %w[emit_path], used[:enforcement]
  end

  def test_introspect_builtin_domains_scans_source
    src = <<~RUBY
      def lsm__file_open(file, ret)
        emit_path(file)          # enforcement
        hist_observe(latency_end) # observability + core-ish
      end
      def xdp__main
        @rx += 1 if pkt_l4_proto == IPPROTO_TCP
        XDP_PASS
      end
    RUBY
    doms = I.builtin_domains(src)
    assert_includes doms[:enforcement], "emit_path"
    assert_includes doms[:observability], "hist_observe"
    assert_includes doms[:net], "pkt_l4_proto"
  end

  # path_eq must NOT match inside parent_path_eq (lookbehind on `_`).
  def test_builtin_domains_word_boundary
    doms = I.builtin_domains("parent_path_eq(\"/x\")\n")
    assert_includes doms[:enforcement], "parent_path_eq"
    refute_includes(doms[:enforcement] || [], "path_eq")
  end

  def test_describe_report_shows_capability_domains
    src = "def kprobe__do_sys_openat2(dfd)\n  spnl_emit(dfd)\nend\n"
    r = I.report(src, "t.rb")
    assert_match(/capability domains \(ADR-014 layer 1\):/, r)
    assert_match(/observability\s+spnl_emit/, r)
  end

  def test_catalog_report_lists_all_domains_and_gates
    r = CAP.catalog_report
    %i[observability enforcement net l7 core].each { |d| assert_match(/#{d}/, r) }
    assert_match(/context gates/, r)
    # E390: allowlist を共有する builtin は 1 グループ、hook は「どの引数がパスを
    # 持つか」で束ねて出す (6 builtin × 30+ hook をベタ並べすると読めない)。
    assert_match(%r{emit_path.*path_eq.*\n.*lsm/file_open}, r)
    assert_match(%r{argument is struct path \*.*lsm/path_unlink}, r)
    assert_match(%r{measured REJECTED.*\n.*lsm/file_permission}, r)
    assert_match(/--probe file\s+-> enforcement/, r)
  end

  # ================================================================
  # E316 (ADR-015 原則4): 機械可読 affordance の完全性 + codegen drift 検出。
  # ================================================================

  CODEGEN_SRC = File.expand_path("../../src/spinel_ebpf/codegen_bpf.rb", __dir__)
  PARTITION_SRC = File.expand_path("../../src/spinel_ebpf/partition.rb", __dir__)

  # (完全性) 全 builtin に signature entry がある。未網羅の新 builtin は落とす。
  def test_every_builtin_has_a_signature
    missing = ALL_BUILTINS - CAP::SIGNATURES.keys
    extra   = CAP::SIGNATURES.keys - ALL_BUILTINS
    assert_empty missing, "signature 未登録の builtin: #{missing.inspect}"
    assert_empty extra,   "存在しない builtin の signature: #{extra.inspect}"
    assert_equal ALL_BUILTINS.length, CAP::SIGNATURES.length
  end

  # (完全性) --json が valid JSON で、全 builtin と attach kind を含む。
  def test_affordance_json_is_valid_and_complete
    require "json"
    doc = JSON.parse(CAP.affordance_json)
    assert_equal "spinel-ebpf.affordance/1", doc["schema"]
    assert_equal "ADR-015", doc["adr"]
    names = doc["builtins"].map { |b| b["name"] }
    assert_equal ALL_BUILTINS.sort, names.sort, "JSON builtins != 全 builtin (affordance が不完全)"
    # 各 builtin entry の必須フィールド。
    doc["builtins"].each do |b|
      assert b.key?("domain") && !b["domain"].nil?, "#{b['name']} に domain 無し"
      assert b.key?("arity"),          "#{b['name']} に arity 無し"
      assert b.key?("params"),         "#{b['name']} に params 無し"
      assert b.key?("opaque"),         "#{b['name']} に opaque 無し"
      assert b.key?("valid_contexts"), "#{b['name']} に valid_contexts 無し"
      # opaque のときだけ params が null (正直な印)。
      assert_nil b["params"], "opaque builtin #{b['name']} の params は null であるべき" if b["opaque"]
      refute_nil b["params"], "非 opaque builtin #{b['name']} は params を持つべき" unless b["opaque"]
    end
    assert_equal CAP.all_builtins.count { |x| CAP.signature_for(x)[:opaque] },
                 doc["summary"]["opaque_builtins"]
  end

  # ================================================================
  # E419 非対称 2: **降格の記録が JSON だけ読む消費者に見えていなかった**。
  #
  # `withdrawn_sugar` / `withdrawn_maps` は出ていたのに `withdrawn` (builtin) と
  # `withdrawn_attach` が無かった。定数としては在り、tools/affordance_gate.rb は
  # それを直読するのでゲートは効いていた — 沈黙していたのは **出荷物の側**だけで、
  # E409 が map で見つけたのと同型 (嘘ではなく不在)。
  #
  # 不変量は **両方向**: 定数を足して JSON への配線を忘れたら落ち、JSON のキーを
  # 消しても落ちる。さらに中身も突き合わせるので、キーだけ在って別の定数に
  # 繋がっている (`withdrawn_attach: WITHDRAWN` のような取り違え) も落ちる。
  # ================================================================
  def test_e419_every_withdrawn_constant_is_published_in_the_json
    require "json"
    doc = JSON.parse(CAP.affordance_json)
    consts = CAP.constants.grep(/\AWITHDRAWN/).sort
    refute_empty consts, "WITHDRAWN* 定数が 1 つも無い (この test は何も守っていない)"
    expected = consts.map { |c| c.to_s.downcase }.sort
    assert_equal expected, doc.keys.grep(/\Awithdrawn/).sort,
                 "JSON の withdrawn* キー集合が Ruby の WITHDRAWN* 定数と一致しない " \
                 "(片方だけ足した/消した)"
    # キーが在るだけでは足りない — 中身が **その定数** であること。
    consts.each do |c|
      assert_equal CAP.const_get(c).keys.map(&:to_s).sort, doc[c.to_s.downcase].keys.sort,
                   "#{c} と JSON の #{c.to_s.downcase} が別の中身を指している"
    end
  end

  # 降格は行き止まりにしない (ADR-003)。E407 が WITHDRAWN_ATTACH に課していた
  # 契約を、E419 で builtin 側にも揃えた:「使えない」だけは半分の情報でしかない。
  def test_e419_withdrawn_builtins_carry_reason_and_alternative
    CAP::WITHDRAWN.each do |name, rec|
      assert rec[:why] && rec[:why].length > 20, "#{name}: why が短すぎる"
      assert rec[:instead] && rec[:instead].length > 20,
             "#{name}: instead 無し (代わりに何を書くかが無いと降格は行き止まり)"
    end
  end

  # (完全性) attach_kinds の作法フィールドが埋まり、主要 kind を含む。
  #
  # E407: 権威は **affordance 自身** (ATTACH_KINDS) であって退役 Ruby oracle の
  # ATTACH_PATTERNS ではない。E406 が builtin 側で見つけたのと同じ構図で、この
  # test は「Ruby oracle に在る kind は affordance にも在って当然」を要求しており、
  # **実測で死んでいる 4 種を正直に降ろすと落ちる**向きに働いていた
  # (= 沈黙する未移植 attach が 1 年生き延びた構造的理由)。
  # 歴史との接続は切らない: 差分が WITHDRAWN_ATTACH と一致することを下の test が守る。
  def test_attach_kinds_are_well_formed
    json_kinds = CAP::ATTACH_KINDS.map { |a| a[:kind] }
    assert_equal json_kinds.length, json_kinds.uniq.length, "attach kind の重複"
    # 主要 kind の網羅 (ADR-015: affordance が「打てる attach」を見せる)。
    # timer は E407 で降格 (WITHDRAWN_ATTACH)。
    %i[kprobe kretprobe tracepoint fentry fexit lsm fmod_ret uprobe uretprobe usdt
       xdp tc_ingress tc_egress sk_reuseport sk_msg sock_ops tcp_cc sched_ext qdisc
       cgroup_connect4 iter_task raw_tp perf_event].each do |k|
      assert_includes json_kinds, k, "主要 attach kind #{k} が affordance に無い"
    end
    CAP::ATTACH_KINDS.each do |a|
      assert a[:method_prefix], "#{a[:kind]} に method_prefix 無し"
      assert a[:args_convention], "#{a[:kind]} に args_convention 無し"
      # E414: exactly one of the two promises. `sec:` is a program SEC; `emits:`
      # is a C symbol, for the one kind that emits no program at all (a
      # USER_RINGBUF callback). Writing "syscall" there would have been worse
      # than useless -- that is the exact string E407 measured the SILENT
      # degradation producing, so a SEC comparison would have been satisfied by
      # the failure it exists to catch.
      assert a[:sec] || a[:emits],
             "#{a[:kind]} に sec も emits も無し (affordance_gate がこれを期待値に使う)"
      # E416: 両方持てるのは `body: :discarded` の kind **だけ**。
      # gate の 2 段目は「書いた body が出力に届いたか」を見るが (E407)、
      # body を捨てる kind ではそれが構造的に成り立たない ⇒ 代わりに何を
      # 探すかを affordance が名指しする、というのが `emits:` の 2 つ目の用途。
      # `body: :discarded` を宣言せずに両方載せるのは、gate がどちらを読むか
      # 決められない状態なので従来どおり禁止。
      if a[:sec] && a[:emits]
        assert_equal :discarded, a[:body],
                     "#{a[:kind]} が sec と emits の両方を主張しているが body: :discarded を宣言していない"
      end
      # 逆向き: body を捨てると言う以上、代わりに探すものを持っていること。
      if a[:body] == :discarded
        assert a[:emits], "#{a[:kind]} は body: :discarded なのに emits 無し (gate の 2 段目が空振りする)"
        assert_match(/body|使われない|捨て/, a[:args_convention].to_s + a[:context_note].to_s,
                     "#{a[:kind]} は body を捨てるのに、それを人間向けに書いていない")
      end
    end
  end

  # (E407) 退役 Ruby oracle との差分は WITHDRAWN_ATTACH ちょうど。
  # 歴史は authority ではないが、記録として繋いでおく — 一方向にしか動けない
  # (oracle に在って affordance に無い = 降ろしたもの、その逆は存在しない)。
  def test_withdrawn_attach_is_exactly_the_retired_oracle_delta
    oracle = GEN::ATTACH_PATTERNS.map { |_re, kind| kind }.uniq
    advertised = CAP::ATTACH_KINDS.map { |a| a[:kind] }
    assert_equal CAP::WITHDRAWN_ATTACH.keys.sort, (oracle - advertised).sort,
                 "WITHDRAWN_ATTACH が「Ruby oracle に在って affordance に無い」集合と一致しない"
    assert_empty advertised - oracle,
                 "oracle に無い attach kind を宣伝している (歴史に無い新種なら本 test を更新)"
    assert_empty advertised & CAP::WITHDRAWN_ATTACH.keys,
                 "同じ kind を宣伝と降格の両方に載せている"
  end

  # (E407) 降ろした attach kind は「なぜ」「代わりに何を」まで書いてある。
  # 黙って消すのは不可 (ADR-003) — WITHDRAWN (builtin) と同じ契約。
  #
  # E415: 「非空であること」はもう要求しない。P011 Phase A/B は降格を巻き戻すので、
  # その要求は**ゲートを armed に保つために出荷物へ嘘を残せ**という圧力になる
  # (ADR-015 が出荷物と呼んでいる affordance に、ゲートの都合で架空の名前を置く)。
  # 検出力は tools/affordance_gate.rb の self-check (生きた claim を memory 内で
  # 壊す) と、C の CC_WITHDRAWN_ATTACH との対応検査に移した。
  def test_withdrawn_attach_entries_carry_reason_and_alternative
    CAP::WITHDRAWN_ATTACH.each do |kind, w|
      assert w[:edoc], "#{kind}: 出典 Edoc 無し"
      assert w[:method_prefix], "#{kind}: method_prefix 無し"
      assert w[:probe], "#{kind}: probe 無し (gate が最小 probe を書けない)"
      assert w[:why] && w[:why].length > 40, "#{kind}: why が短すぎる"
      assert w[:instead], "#{kind}: instead 無し (代わりに何を書くかが無いと降格は行き止まり)"
    end
  end

  # (drift) SIGNATURES の arity が codegen (expects N / expect_no_args) と一致。
  # codegen の arity チェックを単一の権威とし、affordance が古びたら test が落ちる。
  def test_signature_arity_matches_codegen
    src = File.read(CODEGEN_SRC)
    checked = 0
    # 0-arity: expect_no_args(node, "NAME")
    src.scan(/expect_no_args\(node, "([a-z_0-9]+)"\)/) do |(name)|
      next unless CAP::SIGNATURES.key?(name)
      assert_equal 0, CAP::SIGNATURES[name][:arity], "#{name}: codegen は 0-arity (expect_no_args)"
      checked += 1
    end
    # N-arity: "NAME expects N arg(s)" (interpolated #{name} は数字を持たず対象外)
    src.scan(/"([a-z_0-9]+) expects (\d+) args?/) do |(name, n)|
      next unless CAP::SIGNATURES.key?(name)
      assert_equal n.to_i, CAP::SIGNATURES[name][:arity], "#{name}: codegen は #{n}-arity"
      checked += 1
    end
    assert_operator checked, :>=, 50, "codegen から取れた arity が少なすぎ (parse 破綻の疑い)"
  end

  # (drift) SIGNATURES の param 名が codegen の "expects (a, b, c)" と一致。
  def test_signature_params_match_codegen_named
    src = File.read(CODEGEN_SRC)
    checked = 0
    src.scan(/"([a-z_0-9]+) expects \(([a-z0-9_, ]+)\), got/) do |(name, plist)|
      next unless CAP::SIGNATURES.key?(name)
      params = plist.split(",").map(&:strip)
      assert_equal params, CAP::SIGNATURES[name][:params],
                   "#{name}: param 名が codegen と乖離 (codegen=#{params.inspect})"
      checked += 1
    end
    assert_operator checked, :>=, 15, "param 名を取れた builtin が少なすぎ"
  end

  # (正直さ) opaque は scx_*/qdisc_* の kfunc passthrough のみ (arity は既知)。
  def test_opaque_builtins_are_kfunc_passthroughs_with_known_arity
    opaque = ALL_BUILTINS.select { |b| CAP.signature_for(b)[:opaque] }
    assert_equal CAP::OPAQUE_KFUNC_BUILTINS.sort, opaque.sort
    opaque.each do |b|
      assert_nil CAP.signature_for(b)[:params], "#{b}: opaque は params=nil"
      refute_nil CAP.signature_for(b)[:arity], "#{b}: arity は既知のはず"
      assert_match(/\A(scx|qdisc)_/, b)
    end
    # opaque 比率が過大でない (affordance の価値が薄れる目安)。
    assert_operator opaque.length.to_f / ALL_BUILTINS.length, :<, 0.10
  end

  # (E286 gate) d_path builtin の valid_contexts。
  #
  # **E435 が直したのはこの test でもある。** 元は 6 つ全部について
  # `valid_contexts == DPATH_OK_SECS` を固定していたが、それは E420 が
  # `dpath_no_select` を足した後も**そのまま通り続けた** — 同じ JSON の中で
  # 「path_eq はこの 32 hook で書ける」と「そのうち 4 hook では path_eq を拒否する」が
  # 併記され、実際 `fentry__dentry_open` の path_eq は compile 時に die する。
  # test が「全部同じ集合」を主張していたので、非対称が入った瞬間に嘘になった。
  # ⇒ **選別する 3 つと観測する 3 つを分けて固定する** (差は no_select の 4 SEC ちょうど)。
  def test_context_gates_expose_valid_secs
    %w[emit_path emit_parent_path parent_path_eq].each do |b|
      assert_equal CAP::DPATH_OK_SECS, CAP.context_strings(b), "#{b} の valid_contexts が d_path allowlist でない"
      assert CAP.builtin_entry(b)[:gated], "#{b} は gated であるべき"
    end
    # 選別する 3 つは no_select の 4 SEC を**引いた**集合しか宣伝しない。
    refute_empty CAP::DPATH_NO_SELECT_SECS
    CAP::DPATH_SELECT_BUILTINS.each do |b|
      got = CAP.context_strings(b)
      assert_equal CAP::DPATH_OK_SECS - CAP::DPATH_NO_SELECT_SECS, got,
                   "#{b}: 拒否される hook を「書ける」と宣伝している"
      CAP::DPATH_NO_SELECT_SECS.each do |sec|
        refute_includes got, sec, "#{b}: #{sec} は compile 時に die するのに valid_contexts に居る"
      end
      assert CAP.builtin_entry(b)[:gated], "#{b} は gated であるべき"
    end
    # attach-kind gate も valid_contexts に出る (機械的に読める)。
    assert_equal %w[iter_task], CAP.context_strings("iter_task")
    assert_equal %w[tcp_cc], CAP.context_strings("tcp_sock_snd_cwnd")
    assert_equal %w[cgroup_connect4 cgroup_bind4], CAP.context_strings("sock_addr_ip4")
    # (E406) E405 の packet-context gate も valid_contexts に出る。codegen は
    # E405 以来これらを packet prog の外で die させていたが、affordance は
    # gated: false と言っていた (= 制約の過少申告、E406 の逆向きの drift)。
    assert_equal %w[xdp xdp_tail tc_ingress tc_egress], CAP.context_strings("fib_lookup")   # E460: xdp_tail は AK_XDP 共有
    assert_equal %w[tc_ingress tc_egress], CAP.context_strings("l4_offset")
    assert_equal %w[tc_ingress], CAP.context_strings("sk_assign_tcp")
    assert CAP.builtin_entry("l4_offset")[:gated]
    # 非 gate builtin は valid_contexts=nil + best-effort note。
    assert_nil CAP.context_strings("hist_observe")
    refute CAP.builtin_entry("hist_observe")[:gated]
    refute_nil CAP.builtin_entry("hist_observe")[:context_note]
  end

  # (E325) DNS builtin の context_note は canonical hook (udp_*) を名指す。
  # l7 domain の "tcp_*/SSL_*" は DNS には誤誘導なので CONTEXT_NOTE_OVERRIDES で正す。
  def test_dns_builtins_context_note_names_udp_hooks
    { "dns_req_start" => "udp_sendmsg", "dns_resp_stash" => "udp_recvmsg",
      "dns_emit" => "udp_recvmsg", "emit_dns" => "udp_sendmsg" }.each do |b, hook|
      note = CAP.context_note(b)
      assert_includes note, hook, "#{b} の context_note が canonical hook #{hook} を名指していない (E325)"
      refute_includes note, "tcp_*", "#{b} の context_note が誤誘導 tcp_* を含む (E325 override 済のはず)"
      # builtin_entry (affordance に出る形) にも反映される。
      assert_includes CAP.builtin_entry(b)[:context_note], hook
    end
    # override は DNS family 限定 — l7 domain note (http/ssl 用) は tcp_*/SSL_* のまま。
    assert_includes CAP::DOMAIN_CONTEXT_NOTE[:l7], "tcp_*"
  end

  # (E328) LSM の非 deny 分岐は prior verdict (末尾 param) を返す作法を affordance が示す。
  # リテラル 0 (=allow) への誘導は (1) prior deny を握り潰す合成バグ、(2) path_eq/emit_path
  # 併用時に verifier state 爆発 (実測 1M insn) を招く。fmod_ret は末尾 param=ret なので不変。
  def test_lsm_attach_kind_guides_prior_verdict_not_literal_zero
    lsm = CAP::ATTACH_KINDS.find { |a| a[:kind] == :lsm }
    refute_nil lsm, "lsm attach_kind が無い"
    note = lsm[:context_note]
    assert_includes note, "prior verdict", "lsm note が allow=prior verdict を示していない (E328)"
    refute_includes note, "0=allow", "lsm note が誤誘導 '0=allow' を残している (E328 fold 済のはず)"
    assert_includes note, "deny", "lsm note が deny 規約を欠く"
  end

  # (E328 GAP-2) lsm/* enforcement は boot の lsm=…,bpf が無いと silent no-op (attach 成功
  # するが発火しない = 最悪の沈黙失敗)。affordance は (a) lsm note でその危険を警告し
  # fmod_ret へ誘導、(b) fmod_ret note が boot 非依存の portable deny だと明示する。
  def test_enforcement_deny_warns_lsm_silent_noop_and_prefers_fmod_ret
    lsm = CAP::ATTACH_KINDS.find { |a| a[:kind] == :lsm }
    fmr = CAP::ATTACH_KINDS.find { |a| a[:kind] == :fmod_ret }
    refute_nil lsm; refute_nil fmr
    # lsm: silent no-op の危険 + lsm=,bpf 前提 + fmod_ret への誘導。
    assert_includes lsm[:context_note], "silent no-op", "lsm note が silent no-op の危険を警告していない (E328 GAP-2)"
    assert_includes lsm[:context_note], "lsm=", "lsm note が boot 前提 (lsm=…,bpf) を示していない (E328 GAP-2)"
    assert_includes lsm[:context_note], "fmod_ret", "lsm note が portable な fmod_ret へ誘導していない (E328 GAP-2)"
    # fmod_ret: portable = boot 非依存を明示。
    assert_includes fmr[:context_note], "portable", "fmod_ret note が portable deny だと明示していない (E328 GAP-2)"
  end

  # (E329) over-reach 防止: path_eq / parent_path_eq は「用途中立の述語」として記述され、
  # 特定 USE (deny 専用) に framing しない。E329 の A/B 実測で、path_eq を deny 特化に書くと
  # ambiguous タスクで AI の USE 選択を hijack (observe すべき audit を block) することを確認 →
  # 記述は builtin の TYPE/契約 (述語) を書き USE (deny) を書かない (辞書 vs 百科事典の線)。
  def test_path_predicates_are_use_neutral_not_deny_framed
    %w[path_eq parent_path_eq].each do |b|
      e = CAP.builtin_entry(b)
      s = e[:summary].to_s
      assert_includes s, "predicate", "#{b} summary が述語 (predicate) だと示していない (E329)"
      assert_includes s, "purpose-neutral", "#{b} summary が用途中立だと示していない (E329)"
      # USE=deny への over-reach framing を禁じる (述語を「deny 専用/ブロックするため」と書かない)。
      # 注: 「用途中立: deny/audit/routing」のように deny を複数用途の一つとして列挙するのは中立で OK。
      # 禁じるのは USE=deny に特定する framing 句のみ。
      ["deny only", "deny-only", "only to deny", "in order to deny", "for denying", "to block", "blocking predicate"].each do |bad|
        refute_includes s, bad, "#{b} summary が deny 特化 framing '#{bad}' を含む (E329 over-reach)"
      end
      # example も action を埋め込まない (deny の -1 を見せない) = 用途中立。
      refute_match(/-\s*1/, e[:example].to_s, "#{b} example が deny action (-1) を埋め込んでいる (E329 over-reach)")
    end
  end

  # (E333) IP 集合メンバシップ builtin (blocklist_match / cidr_blocklist_match) は
  # 用途中立の述語として記述する。E333 で同じ map+builtin を allowlist egress に流用
  # (match→allow) し、blocklist (match→deny) と allowlist (match→allow) は戻り値=logic で
  # 決まると実測 → 名前が "blocklist" でも USE を frame しない (E329 の線引きを network に適用)。
  def test_ip_set_predicates_are_use_neutral
    %w[blocklist_match cidr_blocklist_match].each do |b|
      e = CAP.builtin_entry(b)
      s = e[:summary].to_s
      assert_includes s, "predicate", "#{b} summary が述語 (predicate) だと示していない (E333)"
      assert_includes s, "purpose-neutral", "#{b} summary が用途中立だと示していない (E333)"
      assert_includes s, "allowlist", "#{b} summary が allowlist 用途も示していない (E333、blocklist-only framing)"
      # (E337) userspace が集合を seed する FFI を surface する (author-agent が off-limits example を
      # 覗かず policy を書けるように)。re-verify が「ffi_func 断片だけでは class/module や引数型を
      # 誤る」と示した (agent が `class` を使い build 失敗) ので、完全な invocation パターン
      # (`module` 明示 + FFI 名 + 整数リテラル呼出) を要求する。
      assert_includes s, "ffi_func", "#{b} summary が集合を seed する userspace FFI を示していない (E337)"
      assert_includes s, "sp_bpf", "#{b} summary が FFI 名 (sp_bpf_*) を示していない (E337)"
      assert_includes s, "module", "#{b} summary が module (class 不可) の宣言場所を示していない (E337 re-verify)"
    end
  end

  # (E337) enforcement の主要 hook fmod_ret/security_file_open の handler arity を affordance が
  # 具体例で示す。author-agent が (file, ret) の arity を off-limits fixture から推測せずに済むように。
  def test_fmod_ret_surfaces_security_file_open_arity
    fmr = CAP::ATTACH_KINDS.find { |a| a[:kind] == :fmod_ret }
    refute_nil fmr
    assert_includes fmr[:args_convention], "security_file_open", "fmod_ret が security_file_open の例を示していない (E337)"
    assert_includes fmr[:args_convention], "(file, ret)", "fmod_ret が (file, ret) の arity を示していない (E337)"
  end

  # (E330 / E330-2) struct_ops (tcp_cc/sched_ext/qdisc) は class 継承を推奨する。
  # 当初 (E330) flat `def <kind>__<member>` は SEC("syscall") に落ち登録されなかった
  # (Haiku 全 iteration 失敗) → class 形を明示 + qdisc の必須 member/skb-ref 制約を surface。
  # E330-2 で codegen が flat も struct_ops として register するようにした ⇒ affordance は
  # class を推奨しつつ「flat は登録されない」の誤った警告を残さない (honest)。
  def test_struct_ops_attach_kinds_guide_class_form
    %i[tcp_cc sched_ext qdisc].each do |k|
      a = CAP::ATTACH_KINDS.find { |x| x[:kind] == k }
      refute_nil a, "#{k} attach_kind が無い"
      blob = "#{a[:method_prefix]} #{a[:args_convention]} #{a[:context_note]}"
      assert_includes blob, "class", "#{k} が class 継承形を示していない (E330)"
      assert_includes blob, "BPF::", "#{k} が親クラス (BPF::...) を示していない (E330)"
      refute_match(/not (be |get )?registered/, blob, "#{k} が flat の誤った失敗警告を残している (E330-2 で flat も register)")
    end
    # qdisc は必須 member + skb-ref 解放を具体的に示す。
    q = CAP::ATTACH_KINDS.find { |x| x[:kind] == :qdisc }
    %w[enqueue dequeue init reset destroy].each do |m|
      assert_includes q[:args_convention], m, "qdisc が必須 member #{m} を示していない (E330)"
    end
    assert_includes q[:args_convention], "skb", "qdisc が skb-ref 解放制約を示していない (E330)"
    assert_match(/qdisc_skb_drop|queue_push/, q[:args_convention], "qdisc が skb 解放 builtin を示していない (E330)")
  end

  # (loud failure) rejected リストが空でなく、partition の impossible flag と一致。
  def test_ruby_subset_rejected_matches_partition_flags
    refute_empty CAP::RUBY_SUBSET[:supported]
    refute_empty CAP::RUBY_SUBSET[:rejected]
    # E455: 不可能集合の正本は TargetProfile::LINUX_EBPF.fatal_flags に移った
    # (ebpf_impossible? は profile への delegator)。ソース regex 走査ではなく
    # 実オブジェクトを内省する — 測る対象 (rejected リストとの lockstep) は不変。
    partition_flags = SpinelEbpf::TargetProfile::LINUX_EBPF.fatal_flags
    # inherits_unsupported は派生 (他 method 伝播) なので rejected の直接構文からは除く。
    construct_flags = partition_flags - [:inherits_unsupported]
    rejected_flags = CAP::RUBY_SUBSET[:rejected].map { |r| r[:flag] }
    assert_equal construct_flags.sort, rejected_flags.sort,
                 "rejected の loud-failure が partition の impossible flag と乖離"
    # 各 rejected flag が実在 (drift ガード) + 人間可読な reason を持つ。
    CAP::RUBY_SUBSET[:rejected].each do |r|
      assert_includes partition_flags, r[:flag], "#{r[:flag]} は partition に無い flag"
      assert r[:reason] && !r[:reason].empty?, "#{r[:flag]} に reason 無し"
    end
  end

  # (層2 参考) enricher が「probe 無変更で属性が付く」を機械可読に示す。
  def test_enrichers_reference_present
    names = CAP::ENRICHERS.map { |e| e[:name] }
    assert_includes names, "k8s"
    assert_includes names, "peer"
    CAP::ENRICHERS.each do |e|
      assert_equal 2, e[:layer]
      refute_empty e[:attributes]
      assert e[:signal_scope]
    end
  end

  # affordance の各 domain が JSON にも出る (発見可能性)。
  def test_affordance_domains_present
    doc = JSON.parse(CAP.affordance_json)
    %w[observability enforcement net l7 core].each do |d|
      assert doc["domains"].key?(d), "JSON domains に #{d} 無し"
    end
  end

  # ================================================================
  # E322 (ADR-015 投資優先(a)、E321 GAP を畳む): 呼び出しコード例 + 関連 builtin。
  # ================================================================

  # (完全性) 全 non-opaque builtin に example があり、opaque は example=nil。
  # example.nil? iff opaque = 省略は意図的 (params と同じ正直さ)、勝手な穴でない。
  def test_every_non_opaque_builtin_has_example
    ALL_BUILTINS.each do |b|
      opaque = CAP.signature_for(b)[:opaque]
      ex = CAP.example_for(b)
      if opaque
        assert_nil ex, "opaque builtin #{b} は example=nil であるべき (嘘の例より省略)"
      else
        refute_nil ex, "非 opaque builtin #{b} に example 無し (GAP-1 未充足)"
        assert_kind_of String, ex
        assert ex.start_with?(b), "#{b} の example は builtin 名で始まるべき: #{ex.inspect}"
      end
    end
  end

  # (正直さ) example を省略した builtin = ちょうど opaque kfunc の集合 (意図的リスト)。
  def test_omitted_examples_are_exactly_opaque
    omitted = ALL_BUILTINS.select { |b| CAP.example_for(b).nil? }
    assert_equal CAP::OPAQUE_KFUNC_BUILTINS.sort, omitted.sort,
                 "example を省略する builtin は opaque kfunc だけであるべき"
  end

  # (正しさの floor) 全 example が valid な Ruby 構文断片 (Ripper で parse、嘘の例を禁止)。
  def test_examples_are_valid_ruby_syntax
    checked = 0
    ALL_BUILTINS.each do |b|
      ex = CAP.example_for(b)
      next if ex.nil?
      refute_nil Ripper.sexp(ex), "example が valid Ruby でない: #{b} -> #{ex.inspect}"
      checked += 1
    end
    assert_operator checked, :>=, 140, "example を parse できた builtin が少なすぎ"
  end

  # (機械生成の妥当性) arity 0 は bare、arity N は name(params) 形。
  def test_generated_examples_match_arity
    # arity 0 (params 空、非 opaque、override 無し) は bare `name`。
    assert_equal "pid",           CAP.example_for("pid")
    assert_equal "latency_start", CAP.example_for("latency_start")
    assert_equal "emit_comm",     CAP.example_for("emit_comm")
    # arity N は params を placeholder にした呼び出し。
    assert_equal "hist_observe_by(key, value)", CAP.example_for("hist_observe_by")
    assert_equal "spnl_emit(value)",            CAP.example_for("spnl_emit")
    assert_equal "emit_path(file)",             CAP.example_for("emit_path")
  end

  # (手書き override) symbol / string リテラル / struct 名の特殊構文が正しく出る。
  def test_example_overrides_apply
    assert_equal "flow_get(:conn, :backend_ip)",           CAP.example_for("flow_get")
    assert_equal 'path_eq(file, "/usr/bin/curl")',         CAP.example_for("path_eq")
    assert_equal 'parent_path_eq("/usr/bin/curl")',        CAP.example_for("parent_path_eq")
    assert_equal 'kfield(sk, "sock", "sk_sndbuf")',        CAP.example_for("kfield")
    assert_equal 'path_starts_with(file, "/etc/secret/")',  CAP.example_for("path_starts_with")
    # override は必ず実在の非 opaque builtin を指す (drift ガード)。
    CAP::EXAMPLE_OVERRIDES.each_key do |b|
      assert_includes ALL_BUILTINS, b, "override #{b} は存在しない builtin"
      refute CAP.signature_for(b)[:opaque], "override #{b} が opaque"
    end
  end

  # (JSON 完全性) 各 builtin entry に example + related。opaque は example=null。
  def test_affordance_json_has_example_and_related
    doc = JSON.parse(CAP.affordance_json)
    doc["builtins"].each do |b|
      assert b.key?("example"), "#{b['name']} に example キー無し"
      assert b.key?("related"), "#{b['name']} に related キー無し"
      assert_kind_of Array, b["related"], "#{b['name']} の related は配列"
      if b["opaque"]
        assert_nil b["example"], "opaque #{b['name']} の example は null であるべき"
      else
        assert_kind_of String, b["example"], "非 opaque #{b['name']} は example を持つべき"
      end
    end
    # builtin_groups も JSON に出る (発見可能性)。
    assert doc.key?("builtin_groups"), "JSON に builtin_groups 無し"
    assert_equal CAP::BUILTIN_GROUPS.length, doc["builtin_groups"].length
  end

  # (整合) builtin_groups の members は実在 builtin、group 内重複無し、group 名一意、note 有り。
  def test_builtin_groups_well_formed
    refute_empty CAP::BUILTIN_GROUPS
    names = CAP::BUILTIN_GROUPS.map { |g| g[:name] }
    assert_equal names.length, names.uniq.length, "group 名が重複"
    CAP::BUILTIN_GROUPS.each do |g|
      assert g[:note] && !g[:note].empty?, "#{g[:name]} に note 無し"
      assert_operator g[:members].length, :>=, 2, "#{g[:name]} は 2 メンバ以上 (関連の意味)"
      assert_equal g[:members].length, g[:members].uniq.length, "#{g[:name]} 内で member 重複"
      g[:members].each do |m|
        assert_includes ALL_BUILTINS, m, "#{g[:name]} の member #{m} は存在しない builtin"
      end
    end
  end

  # (導出) related は BUILTIN_GROUPS から導出される (単一の権威)。
  def test_related_is_derived_from_groups
    # グループ member は同グループの他メンバを related に持つ。
    assert_equal %w[tgid tid], CAP.related_for("pid")
    assert_equal %w[latency_end], CAP.related_for("latency_start")
    assert_includes CAP.related_for("hist_observe"), "hist_observe_by"
    # どのグループにも属さない builtin は related=[]。
    assert_equal [], CAP.related_for("cgroup_id")
    assert_equal [], CAP.related_for("divu")
    # related は対称 (a in related_for(b) <=> b in related_for(a))。
    CAP::BUILTIN_GROUPS.each do |g|
      g[:members].combination(2).each do |a, b|
        assert_includes CAP.related_for(a), b
        assert_includes CAP.related_for(b), a
      end
    end
  end

  # (E321 GAP-3 の畳込) pid/tgid/tid の pack 関係が affordance から引ける。
  def test_pid_tgid_tid_group_closes_e321_gap
    grp = CAP::BUILTIN_GROUPS.find { |g| g[:name] == "process_thread_identity" }
    refute_nil grp, "process_thread_identity グループが無い (E321 GAP-3 未充足)"
    assert_equal %w[pid tgid tid], grp[:members]
    # 「どれが process 粒度か」が note から読める (選択に必要な事実、ロジックでない)。
    assert_match(/process granularity/, grp[:note])
    assert_match(/thread granularity/, grp[:note])
  end

  # (人間可読) catalog に builtin groups セクションが出る (呼び出し例 + note つき)。
  def test_catalog_report_shows_builtin_groups
    r = CAP.catalog_report
    assert_match(/builtin groups/, r)
    assert_match(/process_thread_identity/, r)
    assert_match(/hist_observe_by\(key, value\)/, r) # 呼び出し例が出る
    assert_match(/process granularity/, r)                    # 関係 note が出る
  end

  # ===================================================================
  # E370 (S3): packed-record 契約の surface。
  #
  # ここが守るのは「**Ruby 側が独自に契約を持っていない**」こと。JSON は
  # src/codegen_c/record_schema.h の生成物で、offset は生成器 (layout()) 由来。
  # 以下の test はそれぞれ別の desync を落とす:
  #   (a) 表を編集して JSON を再生成し忘れた   -> フィールド名/型の突合
  #   (b) 2 つの生成物が別世代になった         -> mirror header の enum と突合
  #   (c) runtime が属性キーを自前で書いた     -> ベタ書き literal の不在検査
  # ===================================================================

  SCHEMA_TABLE_SRC = File.expand_path("../../src/codegen_c/record_schema.h", __dir__)
  MIRROR_GEN_SRC   = File.expand_path("../../src/runtime/otlp/record_mirror_gen.h", __dir__)
  OTLP_AGENT_SRC   = File.expand_path("../../src/runtime/otlp/otlp_agent.c", __dir__)

  # E372 (S5): 宣言済みの channel 一覧。DNS 以外 (conn/l7/http/redis/offcpu/l7stream)
  # も S5 で宣言化されたので、ここは「どれが載っているか」の pin も兼ねる。
  DECLARED_CHANNELS = %w[dns conn l7 http redis offcpu l7stream].freeze

  def test_record_channels_load_from_the_generated_artifact
    chans = CAP.record_channels
    assert_equal DECLARED_CHANNELS, chans.map { |c| c[:id] },
                 "宣言済み channel の集合が変わった (record_schema.h の cc_rec_all)"
    dns = CAP.record_channel("dns")
    refute_nil dns, "dns channel が無い"
    assert_equal "<unit>_dns_event", dns[:record_struct]
    assert_equal "<unit>_dns_events", dns[:ringbuf_map]
    assert_equal 128, dns[:record_bytes]
    assert_equal %w[emit_dns dns_emit], dns[:producers]
    # 各 channel は record struct / ringbuf map / producer を必ず持つ (契約の最小形)
    chans.each do |c|
      assert_equal "<unit>_#{c[:id]}_event", c[:record_struct], "#{c[:id]}: struct 名の規約"
      assert_equal "<unit>_#{c[:id]}_events", c[:ringbuf_map], "#{c[:id]}: map 名の規約"
      refute_empty Array(c[:producers]), "#{c[:id]}: producer が無い"
      assert_operator c[:record_bytes], :>, 0, "#{c[:id]}: record_bytes"
      assert_operator c[:record_min_bytes], :<=, c[:record_bytes], "#{c[:id]}: min <= size"
    end
  end

  # (a) 生成 JSON と宣言表 (record_schema.h) のフィールドが一致。offset は**比べない**
  # (Ruby が align 規則を持たない = E369 申し送りの禁じ手を踏まない)。名前/型/count だけ。
  def test_record_json_fields_match_the_declaration_table
    src = File.read(SCHEMA_TABLE_SRC)
    DECLARED_CHANNELS.each do |id|
      body = src[/cc_rec_#{id}_fields\[\]\s*=\s*\{(.*?)\n\};/m, 1]
      refute_nil body, "record_schema.h の cc_rec_#{id}_fields が読めない"
      declared = body.scan(/\{\s*"([^"]+)",\s*"([^"]+)",\s*(\d+),\s*(\d+),\s*(\d+),/)
                     .map { |n, t, c, _s, _a| [n, t, c.to_i] }
      from_json = CAP.record_channel(id)[:fields].map { |f| [f[:name], f[:ctype], f[:count]] }
      assert_equal declared, from_json,
                   "#{id}: record_schema.h と record_schema_gen.json が乖離 (make -C src/codegen_c mirror)"
    end
  end

  # (b) 2 つの生成物 (Ruby が読む JSON / runtime が読む header) が同じ世代。
  # header の enum は生成器が計算した offset そのもの。
  def test_record_json_offsets_match_the_generated_mirror_header
    hdr = File.read(MIRROR_GEN_SRC)
    DECLARED_CHANNELS.each do |id|
      up = id.upcase
      CAP.record_channel(id)[:fields].each do |f|
        macro = "SPNL_REC_#{up}_OFF_#{f[:name].upcase}"
        m = hdr[/#{Regexp.escape(macro)}\s*=\s*(\d+)/, 1]
        refute_nil m, "#{macro} が mirror header に無い"
        assert_equal f[:offset], m.to_i, "#{id}.#{f[:name]} の offset が JSON と header で不一致"
      end
      assert_equal CAP.record_channel(id)[:record_bytes],
                   hdr[/SPNL_REC_#{up}_SIZE\s*=\s*(\d+)/, 1].to_i, "#{id}: SIZE"
      assert_equal CAP.record_channel(id)[:record_min_bytes],
                   hdr[/SPNL_REC_#{up}_MIN\s*=\s*(\d+)/, 1].to_i, "#{id}: MIN (append-only 読取)"
    end
  end

  # --- E400: metrics, and the cardinality facts the surface must carry -------

  def test_metrics_are_published_with_their_series_bound
    ms = CAP.record_metrics
    refute_empty ms, "metric が 1 つも publish されていない"
    ms.each do |m|
      assert_includes %w[counter histogram], m[:kind]
      refute_empty m[:name].to_s
      refute_empty m[:unit].to_s
      assert_operator m[:series_bound].to_i, :>, 0,
                      "#{m[:name]}: series の上限が無い = 代金が読めない"
    end
  end

  def test_every_metric_label_says_where_its_bound_comes_from
    # E400 の要求そのもの: 「bound 3」だけでは、その 3 が **宣言された粗視化** の結果
    # (集合外は fallback に畳まれ、span だけが正確な値を持つ) なのか、元から閉じている
    # のか読めない。読めないと `_OTHER` をダッシュボードで見て初めて気づくことになる。
    CAP.record_metrics.each do |m|
      Array(m[:labels]).each do |l|
        assert_includes %w[declared_set value_map], l[:bound_from],
                        "#{m[:name]} / #{l[:key]}: bound の出所が無い"
        assert_operator l[:bound].to_i, :>, 0
        if l[:bound_from] == "declared_set"
          refute_empty l[:fallback].to_s, "#{l[:key]}: 集合外の行き先が無い"
          assert_equal Array(l[:values]).length + 1, l[:bound]
        end
      end
    end
  end

  def test_capabilities_json_carries_the_cardinality_ceiling
    j = JSON.parse(CAP.affordance_json, symbolize_names: true)
    assert_operator j[:summary][:record_metric_count], :>, 0
    assert_equal CAP.record_metrics.sum { |m| m[:series_bound].to_i },
                 j[:summary][:record_metric_series_bound]
    refute_empty Array(j[:record_bounds_sets]), "histogram の bucket 境界が publish されていない"
  end

  def test_metric_report_shows_the_bound_and_the_coarsening
    r = CAP.record_channels_report
    assert_includes r, "metrics (E400)"
    assert_includes r, "series <="
    assert_match(/the span keeps the exact value/, r,
                 "粗視化していることが人間可読な面に出ていない")
  end

  def test_metric_value_and_labels_are_consumer_properties
    CAP.record_metrics.each do |m|
      props = Array(CAP.record_properties(m[:channel])).map { |p| p[:name].to_s }
      Array(m[:labels]).each { |l| assert_includes props, l[:from].to_s }
      next if m[:value_from].to_s.empty?
      assert_includes props, m[:value_from].to_s
    end
  end

  def test_record_producers_are_registered_builtins
    prods = CAP.record_producers
    assert_equal %w[dns_emit emit_connect emit_dns emit_l7 emit_tcp_payload emit_tcp_stream
                    http_emit offcpu_emit redis_emit ssl_emit], prods
    (prods - ALL_BUILTINS).tap { |x| assert_empty x, "未登録 builtin が producer: #{x.inspect}" }
    assert_equal "dns", CAP.record_channel_for("emit_dns")[:id]
    assert_equal "dns", CAP.record_channel_for("dns_emit")[:id]
    assert_nil CAP.record_channel_for("hist_observe"), "スカラ emit は record channel を持たない"
  end

  # (c) 属性キーの正本は宣言表。runtime は生成マクロの**消費者**であって作者ではない。
  # E372 (S5): DNS だけだった検査を **egress を宣言した全 channel** に広げた。各 channel の
  # 「1 record を span にする関数」を名指しし、(1) 宣言された全キーが生成マクロとして存在、
  # (2) その関数がマクロを使っている、(3) 同じキーのベタ書きが残っていない、を要求する。
  # (3) が肝: ベタ書きが 1 つでも残ると宣言と wire が黙って分岐できる。
  CHANNEL_CONSUMER_FNS = {
    "dns"    => %w[dns_fill_span otlp_tree_fill_dns],
    # E375: conn も builder に切り出した (簡潔形 push は conn_fill_span を呼ぶだけになった)
    "conn"   => %w[conn_fill_span otlp_tree_fill_conn],
    # E374: l7/http も dns と同じく「1 record を span にする」builder に切り出した
    # (簡潔形 push と typed consumer の `to_span` が同じ 1 箇所を通る)。
    "l7"     => %w[l7_fill_span],
    "http"   => %w[http_fill_span],
    "redis"  => %w[spnl_otlp_redis_span_push_obj],
    "offcpu" => %w[spnl_otlp_offcpu_span_push_obj spnl_otlp_request_tree_push_obj],
  }.freeze

  # 関数本体 (先頭が桁 0 の定義行 -> 桁 0 の `}` まで) を取り出す。
  def consumer_fn_text(src, names)
    names.map do |n|
      m = src[/^[a-z ]*int #{Regexp.escape(n)}\(.*?\n\}\n/m]
      refute_nil m, "runtime に #{n}() が見つからない (名前が変わった?)"
      m
    end.join("\n")
  end

  def test_egress_keys_are_generated_macros_the_runtime_consumes
    hdr = File.read(MIRROR_GEN_SRC)
    src = File.read(OTLP_AGENT_SRC)
    checked = 0
    CAP.record_channels.each do |c|
      e = c[:egress]
      next unless e
      id  = c[:id]
      up  = id.upcase
      fns = consumer_fn_text(src, CHANNEL_CONSUMER_FNS.fetch(id))
      e[:attributes].each do |a|
        macro = "SPNL_EGRESS_#{up}_ATTR_#{a[:key].upcase.gsub(/[^A-Z0-9]/, '_')}"
        assert_match(/#define\s+#{Regexp.escape(macro)}\s+"#{Regexp.escape(a[:key])}"/, hdr,
                     "#{macro} が生成 header に無い")
        assert_includes fns, macro, "#{id} consumer が #{macro} を使っていない"
        refute_match(/"#{Regexp.escape(a[:key])}"/, fns,
                     "#{id} consumer に #{a[:key]} のベタ書きが残っている (宣言が正本でなくなる)")
        checked += 1
      end
      # span 名も同じ経路 (fmt はマクロ、JSON は {arg} 展開した可読版)。
      fmt_macro = "SPNL_EGRESS_#{up}_SPAN_NAME_FMT"
      assert_match(/#define\s+#{Regexp.escape(fmt_macro)}\s+"/, hdr, "#{fmt_macro} が無い")
      assert_includes fns, fmt_macro, "#{id} consumer が span 名マクロを使っていない"
    end
    total = CAP.record_channels.sum { |c| Array(c.dig(:egress, :attributes)).length }
    assert_equal total, checked, "egress を宣言した channel の一部が検査から漏れた"
    assert_operator checked, :>=, 39, "検査した属性キーが少なすぎる (channel が外れた?)"
    # DNS の具体形は E370 からの pin として残す
    assert_equal %w[dns.question.name process.executable.name spnl.dns.latency_ns],
                 CAP.record_channel("dns")[:egress][:attributes].map { |a| a[:key] }
    assert_equal "resolve {dns.question.name}", CAP.record_channel("dns")[:egress][:span_name]
    assert_equal "connect {network.peer.address}:{network.peer.port}",
                 CAP.record_channel("conn")[:egress][:span_name]
  end

  # E372 (S5): S4 (型付き consumer) は channel ごとの **opt-in**。宣言しただけの channel で
  # `on_emit :<id>` の意味が変わってはいけない (E242 named event のまま)。
  # E374 (ADR-017 D4): opt-in を l7 / http に広げた。E375: conn も (宛先 `ev.peer` が
  # record 全体を見る derivation を要し、3 つ目の impl_form record_to_str が入って解けた)。
  # E379: offcpu も (egress 属性の 3 つが **フィールドそのままでは出せない** — clamp
  # (spnl.offcpu_ns) / 計算値 (spnl.oncpu_ns) / record 外の kallsyms 分類 (spnl.wait.kind)
  # — ので、それらを derivation にして初めて「Ruby が見る値 == span に出る値」が成立した)。
  # redis / l7stream は宣言のみ (S1-S3) のままで、`on_emit :redis` 等は E242 named event。
  # この一覧は**意図の pin**であって派生ではない — 増やすときは「既存プログラムの
  # `on_emit :<id>` の意味が変わらないか」を考えた上でここを更新する。
  TYPED_CHANNELS = %w[dns conn l7 http offcpu].freeze

  def test_typed_consumer_is_opt_in_per_channel
    assert_equal TYPED_CHANNELS, CAP.typed_record_channel_ids,
                 "型付き consumer を公開している channel が変わった"
    CAP.record_channels.each do |c|
      next if TYPED_CHANNELS.include?(c[:id])
      assert_nil c[:consumer],
                 "#{c[:id]} が consumer 契約を publish している — `on_emit :#{c[:id]}` の意味が変わる"
    end
  end

  # ===================================================================
  # E371 (S4): 型付き consumer の契約。`ev.<prop>` の集合が宣言由来であること、
  # 生成 accessor が実在すること、runtime が生成ブロックの要求を満たすことを守る
  # (どれか 1 つでも欠けると「Ruby から見える型」と実体がずれる)。
  # ===================================================================

  def test_record_consumer_contract_is_published
    cons = CAP.record_channel("dns")[:consumer]
    refute_nil cons, "consumer 契約が JSON に無い (make -C src/codegen_c mirror)"
    assert_equal "on_emit :dns do |ev| ... end", cons[:form]
    assert_equal "spnl_rec_dns_drain",   cons[:drain_fn]
    assert_equal "spnl_rec_dns_to_span", cons[:to_span_fn]
    assert_equal "spnl_otlp_span_send",  cons[:send_fn]
    assert_equal "spnl_otlp_span_flush", cons[:flush_fn]
    assert_equal %w[pid comm cgid duration_ns qname], CAP.record_properties("dns").map { |p| p[:name] }
    # E374: 横展開した channel も同じ形 (form/*_fn は id から派生、send/flush は channel 非依存)。
    TYPED_CHANNELS.each do |id|
      c = CAP.record_channel(id)[:consumer]
      refute_nil c, "#{id} の consumer 契約が JSON に無い"
      assert_equal "on_emit :#{id} do |ev| ... end", c[:form]
      assert_equal "spnl_rec_#{id}_drain",   c[:drain_fn]
      assert_equal "spnl_rec_#{id}_to_span", c[:to_span_fn]
      assert_equal "spnl_otlp_span_send",    c[:send_fn]   # 送信は channel 非依存 (1 バッチ)
      assert_equal "spnl_otlp_span_flush",   c[:flush_fn]
      refute_empty CAP.record_properties(id)
    end
    # E374: HTTP は L7 の判断材料 (method/path/status) が derived プロパティとして出る。
    assert_equal %w[pid comm dport duration_ns cgid method path status],
                 CAP.record_properties("http").map { |p| p[:name] }
    assert_equal "int", CAP.record_properties("http").find { |p| p[:name] == "status" }[:expose]
  end

  # 露出は宣言 (record_schema.h の expose 列 + derived 表) が正本。JSON がそこから
  # ずれたら「Ruby に見える型」と「宣言」が食い違う。
  # E374: dns 固定だった検査を **opt-in した全 channel** に広げた。
  def test_record_consumer_properties_match_the_declaration_table
    src = File.read(SCHEMA_TABLE_SRC)
    TYPED_CHANNELS.each do |id|
      body = src[/cc_rec_#{id}_fields\[\]\s*=\s*\{(.*?)\n\};/m, 1]
      refute_nil body, "record_schema.h の cc_rec_#{id}_fields が読めない"
      # `{ name, ctype, count, size, align, note, expose[, kfilter] }` — the
      # trailing kfilter column (E398) is optional, so the row shape here is
      # "note, expose, and possibly one more literal".
      declared_fields = body.scan(/\{\s*"([^"]+)",.*?,\s*(?:"(?:[^"\\]|\\.)*"|NULL)\s*,\s*(NULL|"int"|"str")\s*(?:,\s*(?:NULL|"[^"]*")\s*)?\}/m)
                            .reject { |_n, e| e == "NULL" }.map { |n, e| [n, e.delete('"')] }
      dbody = src[/cc_rec_#{id}_derived\[\]\s*=\s*\{(.*?)\n\};/m, 1]
      declared_derived = dbody ? dbody.scan(/\{\s*"([^"]+)",\s*"([^"]+)",/).map { |n, e| [n, e] } : []

      props = CAP.record_properties(id)
      assert_equal declared_fields,
                   props.select { |p| p[:kind] == "field" }.map { |p| [p[:name], p[:expose]] },
                   "#{id}: 公開フィールドが宣言表とずれた"
      assert_equal declared_derived,
                   props.select { |p| p[:kind] == "derived" }.map { |p| [p[:name], p[:expose]] },
                   "#{id}: 派生プロパティが宣言表とずれた"
    end
  end

  # 宣言された各プロパティに、生成 accessor が **正しい C 型で** 実在すること
  # (:long -> long、:str -> const char *)。spinel が出す extern 宣言と食い違えば
  # そもそも C コンパイルが通らないので、この対応がハーネスの土台。
  def test_record_consumer_accessors_are_generated_with_matching_types
    hdr = File.read(MIRROR_GEN_SRC)
    TYPED_CHANNELS.each do |id|
      CAP.record_properties(id).each do |p|
        ctype = { "int" => "long", "str" => "const char *" }.fetch(p[:expose])
        assert_match(/#{Regexp.escape(ctype)}\s*#{Regexp.escape(p[:ffi])}\(int i\)/, hdr,
                     "#{p[:ffi]} の生成 accessor が無い / C 型が #{ctype} でない")
        assert_equal({ "int" => ":long", "str" => ":str" }.fetch(p[:expose]), p[:ffi_ret])
      end
    end
    assert_match(/#ifdef SPNL_REC_CONSUME_IMPL/, hdr, "accessor が単一 TU 限定になっていない")
  end

  # 生成ブロックが要求する関数 (record lookup + 宣言された derivation) を runtime が
  # 実際に定義しているか。欠けると link error になる = 静かには壊れないが、
  # 「宣言したのに誰も実装していない」を commit させないためにここで落とす。
  # E374: derivation の呼び出し規約は 2 種 (bytes_to_str / bytes_to_int) — 宣言された
  # impl_form どおりの **C シグネチャ**で実装されていることまで見る。
  # E375: 3 種目 record_to_str (record 丸ごとを受ける = 単一フィールドでは書けない導出)。
  # E376: 4 種目 record_to_int — 2 軸 (何を渡すか × 何を返すか) の残り 1 マス。
  DERIV_PROTO = { "bytes_to_str"  => /^void %s\(const unsigned char \*/,
                  "bytes_to_int"  => /^long %s\(const unsigned char \*/,
                  "record_to_str" => /^void %s\(const spnl_rec_[a-z0-9]+_t \*/,
                  "record_to_int" => /^long %s\(const spnl_rec_[a-z0-9]+_t \*/ }.freeze

  # E397: 5 種目 code_to_name は上の 4 つと**質が違う**。impl 列が名指すのは runtime の
  # 関数ではなく宣言された値マップで、lookup は生成物。だから探す先が agent ではなく
  # 生成ヘッダで、しかも「runtime がそれを持っていないこと」まで見る (表が 2 つあったら
  # 宣言と実際に引かれる表が別物になりうる = このレイヤが消しに来た形そのもの)。
  DERIV_GENERATED = { "code_to_name" => "static inline void spnl_valmap_%s(long v, char *out, int cap)" }.freeze

  # E434: 6 種目 int_expr も「生成される body」側だが、code_to_name と違って impl 列が
  # 名指すのは表の id ですらなく **式そのもの**。だから探し方も違う — 生成ヘッダに
  # `/* declared: <式> */` 付きの helper が在り、runtime にはその名前の関数が無いこと。
  DERIV_EXPR_FORM = "int_expr"

  def test_runtime_provides_what_the_generated_consumer_requires
    agent = File.read(OTLP_AGENT_SRC)
    src   = File.read(SCHEMA_TABLE_SRC)
    assert_includes agent, "#define SPNL_REC_CONSUME_IMPL"
    assert_match(/int spnl_otlp_span_send\(int handle, const char \*endpoint\)/, agent)
    assert_match(/int spnl_otlp_span_flush\(void\)/, agent)
    TYPED_CHANNELS.each do |id|
      assert_match(/const spnl_rec_#{id}_t \*spnl_rec_#{id}_at\(int i\)\s*\{/, agent)
      assert_match(/int spnl_rec_#{id}_drain_obj\(/, agent)
      assert_match(/int spnl_rec_#{id}_to_span\(int i\)/, agent)
      # 宣言された derivation の実装 (impl 列の関数) が非 static で、宣言した form の型で在ること
      dbody = src[/cc_rec_#{id}_derived\[\]\s*=\s*\{(.*?)\n\};/m, 1]
      next unless dbody
      dbody.scan(/\{\s*"[^"]+",\s*"[^"]+",\s*"[^"]+",\s*"([^"]+)",\s*"([^"]+)"/).each do |impl, form|
        if (gen = DERIV_GENERATED[form])
          hdr = File.read(MIRROR_GEN_SRC)
          assert_includes hdr, format(gen, impl),
                          "値マップ #{impl} (#{form}) の lookup が生成ヘッダに無い"
          refute_match(/^\s*(static\s+)?\w[\w \*]*\bspnl_valmap_#{Regexp.escape(impl)}\s*\(/, agent,
                       "runtime が値マップ #{impl} を手書きで持っている (表が 2 つある)")
          next
        end
        if form == DERIV_EXPR_FORM
          hdr  = File.read(MIRROR_GEN_SRC)
          prop = dbody[/\{\s*"([^"]+)",\s*"[^"]+",\s*"[^"]+",\s*"#{Regexp.escape(impl)}"/, 1]
          refute_nil prop, "int_expr derivation のプロパティ名が読めない"
          assert_includes hdr, "static inline long spnl_recd_#{id}_#{prop}_val(const spnl_rec_#{id}_t *r)",
                          "int_expr derivation #{prop} の helper が生成ヘッダに無い"
          assert_includes hdr, "/* declared: #{impl} */",
                          "生成された body に宣言した式が刻まれていない (式と body が別物になりうる)"
          refute_match(/^\s*(static\s+)?\w[\w \*]*\bspnl_#{id}_#{prop}\s*\(/, agent,
                       "runtime が int_expr derivation #{prop} を手書きでも持っている (作者が 2 人)")
          next
        end
        pat = DERIV_PROTO.fetch(form) { flunk "未知の impl_form #{form} (生成器が die するはず)" }
        assert_match(Regexp.new(format(pat.source, Regexp.escape(impl))), agent,
                     "derivation #{impl} (#{form}) の実装が runtime に無い / シグネチャが違う")
      end
    end
  end

  # 簡潔形と明示形が **同じ span builder** を通ること (「糖衣を剥がすと明示形」の構造保証)。
  # どちらかが独自に span を組み始めたら属性がこっそり分岐しうる。
  # E374: channel を増やすたびにこの強制が効く (E371 申し送り 5)。
  def test_both_consumer_forms_share_one_span_builder
    agent = File.read(OTLP_AGENT_SRC)
    TYPED_CHANNELS.each do |id|
      assert_match(/static int #{id}_fill_span\(/, agent, "#{id}: 共通 builder が無い")
      ["spnl_otlp_#{id}_span_push_obj", "spnl_rec_#{id}_to_span"].each do |fn|
        body = agent[/^(?:static )?(?:int|const char \*) #{Regexp.escape(fn)}\(.*?\n\}\n/m]
        refute_nil body, "#{fn} が読めない"
        assert_includes body, "#{id}_fill_span", "#{fn} が共通 builder を通っていない"
      end
    end
  end

  # E374: Ruby が読む値と span に載る値が **同じ関数の出力**であること (E371 の qname 性質を
  # 横展開)。http の method/path/status は derived 宣言の impl であり、span builder も
  # その impl を呼ぶ — 別々にパースし始めたら `ev.status` と http.response.status_code が
  # 黙ってずれうる。
  def test_derived_property_and_span_attribute_share_one_parser
    agent = File.read(OTLP_AGENT_SRC)
    src   = File.read(SCHEMA_TABLE_SRC)
    dbody = src[/cc_rec_http_derived\[\]\s*=\s*\{(.*?)\n\};/m, 1]
    impls = dbody.scan(/\{\s*"[^"]+",\s*"[^"]+",\s*"[^"]+",\s*"([^"]+)"/).flatten
    assert_equal %w[spnl_http_method spnl_http_path spnl_http_status], impls
    builder = agent[/static int http_fill_span\(.*?\n\}\n/m]
    refute_nil builder
    impls.each { |i| assert_includes builder, "#{i}(", "span builder が derivation #{i} を通っていない" }
  end

  # E375: conn の 2 つの derivation は **record 全体を見る** (record_to_str)。同じ「1 つの
  # 出力を共有する」性質を、conn の形に合わせて pin する:
  #   - `ev.direction` は span 属性 spnl.conn.direction と **同じ関数の出力** (builder が呼ぶ)
  #   - `ev.peer` は "<address>:<port>" で、そのアドレス部は network.peer.address を作るのと
  #     **同じアドレス整形関数**を通る (ポート部は同じ dport)。span 名は宣言された
  #     "connect %s:%u" が同じ 2 値を並べたもの = ev.peer と同一文字列。
  #   - v4/v6 の選択は agent 内に 1 箇所しかない (2 箇所になったら黙ってずれうる)
  def test_conn_derivations_share_one_renderer_with_the_span
    agent   = File.read(OTLP_AGENT_SRC)
    builder = agent[/static int conn_fill_span\(.*?\n\}\n/m]
    peer    = agent[/^void spnl_conn_peer\(.*?\n\}\n/m]
    refute_nil builder, "conn_fill_span() が読めない"
    refute_nil peer,    "spnl_conn_peer() が読めない"
    # E397: `direction` の写像は手書きの switch から**宣言された値マップ**になった。
    # 見たい不変条件は変わらない (span builder が ev.direction と同じ実装を通ること) が、
    # その実装の名前は宣言から導く — テストが実装名を決め打ちすると、宣言を動かした
    # ときにテストの方が古い実装を要求する。
    dir_prop = SpinelEbpf::Capabilities.record_properties("conn").find { |p| p[:name] == "direction" }
    refute_nil dir_prop, "conn に ev.direction が無い"
    assert_equal "conn_direction", dir_prop[:value_map],
                 "ev.direction が値マップ由来でない (E397 で code_to_name になったはず)"
    assert_includes builder, "spnl_valmap_#{dir_prop[:value_map]}(",
                    "span が ev.direction の impl (生成された値マップ) を通っていない"
    assert_includes peer,    "conn_peer_addr(",      "ev.peer が独自にアドレスを整形している"
    assert_includes builder, "conn_peer_addr(",      "span が独自にアドレスを整形している"
    assert_equal 1, agent.scan(/inet_ntop\(AF_INET6/).length,
                 "IPv6 の整形が 2 箇所以上ある (v4/v6 の選択は 1 箇所であるべき)"
  end

  # E377: **出力容量も derivation の契約の一部**。同じ関数でも渡す cap が違えば、長い値で
  # 切り詰め位置が食い違う (実測: 空白を含まない 64B の HTTP head で `ev.method` は 64 文字、
  # span 属性は 15 文字だった — kernel 側 filter spnl_is_http_req は先頭 4 byte しか見ないので
  # 到達可能)。
  #
  # E378: その容量を **derivation ごとに宣言**するようにした (1 つの共有定数だと、数字は
  # 誰の上限でもない — 生成器がたまたま使っていた値)。pin する不変条件は 2 つ:
  #   (1) str derivation はすべて自分の cap マクロを持ち、accessor がそれを使う (数値リテラル無し)
  #   (2) runtime の呼び出しが渡すバッファは、**その derivation の cap マクロ**で宣言されている
  #       (別の derivation の cap を借りるのも不可 — 幅がその関数の上限でなくなる)
  def test_derived_string_capacity_has_one_author
    hdr   = File.read(MIRROR_GEN_SRC)
    agent = File.read(OTLP_AGENT_SRC)
    src   = File.read(SCHEMA_TABLE_SRC)
    refute_match(/SPNL_REC_DERIVED_STR_CAP/, hdr,
                 "共有 cap 定数が残っている (E378: cap は derivation ごとの宣言)")
    assert_equal 0, hdr.scan(/static char buf\[\d+\]/).length,
                 "accessor が数値リテラルの幅を持っている (宣言 1 箇所の原則が破れている)"
    # 宣言された str derivation を (channel, name, impl) で集める。
    derived = TYPED_CHANNELS.flat_map { |id|
      body = src[/cc_rec_#{id}_derived\[\]\s*=\s*\{(.*?)\n\};/m, 1] || ""
      body.scan(/\{\s*"([^"]+)",\s*"str",\s*"[^"]+",\s*"([^"]+)"/).map { |name, impl|
        [id, name, impl, "SPNL_REC_DERIVED_#{id.upcase}_#{name.upcase}_CAP"]
      }
    }
    assert_equal 10, derived.length,
                 "str derivation の数が変わった (期待: qname/peer/direction/conn.tcp_state/http.method/" \
                 "http.path/offcpu.method/offcpu.path/offcpu.wait_kind/offcpu.wait_stack_trace)"
    caps = {}
    derived.each do |id, name, _impl, macro|
      m = hdr[/^#define #{macro}\s+(\d+)$/, 1]
      refute_nil m, "生成ヘッダに #{macro} が無い (#{id}.#{name} の出力容量が宣言されていない)"
      caps[macro] = m.to_i
      assert_includes hdr, "static char buf[#{macro}];",
                      "accessor spnl_rec_#{id}_#{name}() が #{macro} を使っていない"
    end
    # cap は「返しうる最大長 + NUL」以上であるべき。ここでは弱い形 (正の値、属性値バッファ
    # otlp_kv_t.val に収まる) だけ pin する — 真の上限そのものは C 側の _Static_assert と
    # tests/runtime/run_record_span_parity.sh (源の幅いっぱいの入力) が見ている。
    val_cap = File.read(File.expand_path("../../src/runtime/otlp/otlp_http.h", __dir__))[
      /char val\[(\d+)\]/, 1].to_i
    assert_operator val_cap, :>, 0
    caps.each { |macro, n|
      assert_operator n, :>, 1, "#{macro} が容量になっていない"
      assert_operator n, :<=, val_cap, "#{macro} は属性値バッファ (#{val_cap}B) に入らない"
    }
    # E379: **1 つの impl を 2 つの channel が共有しうる** (offcpu の method/path は http の
    # derivation そのもの)。その場合、各 channel が自分の bound を宣言するのは正しい (cap は
    # その derivation の上限であって共有定数ではない、E378) が、共有された関数に違う幅が
    # 渡ると E377 の「同じ関数・違う幅」が戻る。よって
    #   (a) 同じ impl を指す cap は **同じ値** でなければならない (C 側の _Static_assert と対)
    #   (b) 呼び出し側のバッファは、その impl の cap マクロのいずれか (= 同値) で宣言されている
    by_impl = derived.group_by { |_id, _name, impl, _macro| impl }
    by_impl.each do |impl, group|
      values = group.map { |_id, _n, _i, macro| caps[macro] }.uniq
      assert_equal 1, values.length,
                   "#{impl}() を共有する channel が違う cap を宣言している " \
                   "(#{group.map { |id, n, _i, m| "#{id}.#{n}=#{m}(#{caps[m]})" }.join(' / ')})"
    end
    # 関数単位で見る (同名の局所バッファが別の関数にもあるため)。E378 以降は offcpu も
    # http の derivation を共有するので、そこも同じ検査の対象になる。
    seen = 0
    agent.split(/^\}$/).each do |body|
      widths = {}   # `char a[N] = {0}, b[M];` の 2 つ目の宣言子まで拾う
      body = body.gsub(%r{/\*.*?\*/}m, "")   # コメント中の "method[16]" 等を拾わない
      body.scan(/\bchar\s+([^;]+);/) do |decl|
        Array(decl).first.split(",").each do |d|
          widths[$1] = $2 if d =~ /(\w+)\s*\[\s*([^\]]+?)\s*\]/
        end
      end
      by_impl.each do |impl, group|
        macros = group.map { |_id, _n, _i, macro| macro }
        names  = group.map { |id, n, _i, _m| "#{id}.#{n}" }
        body.scan(/#{Regexp.escape(impl)}\(\s*[^;]*?,\s*(\w+),\s*(?:\(int\))?sizeof \1/).flatten.each do |buf|
          seen += 1
          assert_includes macros, widths[buf],
                          "#{impl}() に幅 #{widths[buf].inspect} の #{buf} を渡している " \
                          "(accessor は #{macros.join(' / ')} = ev.#{names.join(' / ev.')} の宣言容量 " \
                          "— 長い値で切り詰めがずれる)"
        end
      end
    end
    assert_operator seen, :>=, 6,
                    "span builder の derivation 呼び出しを 1 つも見つけられていない (検査が空振り)"
  end

  # E378: **同じ record 形を読む 2 つ目の消費者にも同じ derivation を使わせる**。
  # offcpu channel の req[64]/resp[16] の読み方は http と同じ — E377 時点では otlp_agent.c に
  # HTTP head パースのコピーがあり、(a) 幅が古く (method[16] vs 宣言 cap)、(b) path の開始位置を
  # 切り詰め済み method の strlen から求めていたため、**同じ head から http span と offcpu span で
  # 違う値**が出得た。コピーが戻ってこないよう、「HTTP head の低レベル走査は宣言された
  # derivation の中だけ」を pin。
  # E379: offcpu の簡潔形 push は共通 builder (offcpu_fill_span) 経由になったので、
  # 「derivation を通っている」を見る場所は builder + request tree の 2 つ。
  def test_http_head_is_parsed_only_by_the_declared_derivations
    agent = File.read(OTLP_AGENT_SRC).gsub(%r{/\*.*?\*/}m, "")
    owners = %w[spnl_http_method spnl_http_path spnl_http_status]
    # 低レベル走査 http_token() を呼んでよいのは宣言された derivation だけ (+ 自身の定義)。
    # それ以外の関数から呼ばれていたら「2 つ目のパーサ」が生えている。
    agent.split(/^\}$/).each do |body|
      fn = body[/^(?:static\s+)?\w[\w \*]*?\b(\w+)\(/m, 1]
      next unless body.include?("http_token(")
      next if owners.include?(fn) || fn == "http_token"
      flunk "#{fn}() が http_token() を直接呼んでいる (HTTP head のパースは " \
            "宣言された derivation #{owners.join(' / ')} の中だけであるべき)"
    end
    # offcpu の 2 つの span 経路が derivation を通っていること
    # (E300 push は E379 で共通 builder 経由 + E312 request tree)。
    { "offcpu_fill_span"                => /^static int offcpu_fill_span\(.*?\n\}\n/m,
      "spnl_otlp_request_tree_push_obj" => /^int spnl_otlp_request_tree_push_obj\(.*?\n\}\n/m }.each do |fn, re|
      body = agent[re]
      refute_nil body, "#{fn}() が読めない"
      owners.each { |i| assert_includes body, "#{i}(", "#{fn}() が derivation #{i} を通っていない" }
    end
  end

  # E379: offcpu 固有の 3 derivation — **フィールドをそのまま出すと span と食い違う**もの。
  # ここが pin するのは「食い違いようがない」構造:
  #   - clamp (min(offcpu_ns, duration_ns)) の作者が 1 つ = 宣言された int_expr だけ
  #     (2 箇所になれば `ev.offcpu_ns` と spnl.offcpu_ns が黙ってずれうる — E376 の `>> 3` と同型)。
  #     E434 でその 1 箇所は手書き C から宣言に移り、手書き側の clamp は 0 になった
  #   - oncpu が「フィールドの差」でなく clamp 済の差 (= 属性 spnl.oncpu_ns) であること
  #   - wait.kind の分類が agent 全体で 1 関数 (_oc_wait_kind) にしかなく、span も ev も
  #     宣言された derivation spnl_offcpu_wait_kind を通ること
  def test_offcpu_derivations_have_one_author
    agent = File.read(OTLP_AGENT_SRC)
    bare  = agent.gsub(%r{/\*.*?\*/}m, "")
    gen   = File.read(MIRROR_GEN_SRC).gsub(%r{/\*.*?\*/}m, "")
    # E434: clamp と差は **手書きの C から消えた** (宣言 int_expr → 生成)。E379 が pin した
    # 不変量は残る — 「clamp は 1 箇所」— が、その 1 箇所は生成ヘッダの helper になった。
    # 手書き側に 1 つでも clamp が生えていたら、それは 2 つ目の作者である。
    hand_clamp = bare.scan(/offcpu_ns\s*[<>]\s*[\w>()-]*duration_ns/)
    assert_equal 0, hand_clamp.length,
                 "off-CPU の clamp が otlp_agent.c に #{hand_clamp.length} 箇所ある " \
                 "(宣言 int_expr が唯一の作者であるべき — E434 D3)"
    impl = gen[/^static inline long spnl_recd_offcpu_offcpu_ns_val\(const spnl_rec_offcpu_t \*r\).*?\n\}\n/m]
    refute_nil impl, "生成された offcpu_ns の helper が無い"
    assert_match(/offcpu_ns\)\s*<\s*\(r->duration_ns/, impl, "clamp が生成 helper の中に無い")
    on = gen[/^static inline long spnl_recd_offcpu_oncpu_ns_val\(const spnl_rec_offcpu_t \*r\).*?\n\}\n/m]
    refute_nil on, "生成された oncpu_ns の helper が無い"
    assert_includes on, "spnl_recd_offcpu_offcpu_ns_val(",
                    "oncpu が clamp 済の値でなく生フィールドを引いている " \
                    "(宣言は `duration_ns - derived(offcpu_ns)` であるべき)"
    # 分類器は 1 つ、そこを通る窓口 (derivation) も 1 つ。
    assert_equal 1, bare.scan(/^static const char \*_oc_wait_kind\(/).length
    kind = bare[/^void spnl_offcpu_wait_kind\(const spnl_rec_offcpu_t \*r.*?\n\}\n/m]
    refute_nil kind, "spnl_offcpu_wait_kind() が宣言どおりの C シグネチャで無い"
    assert_includes kind, "_oc_wait_kind(", "derivation が分類器を通っていない"
    # span を組む側 (簡潔形/明示形の共通 builder) と E312 の子 span が同じ derivation 経由。
    builder = bare[/^static int offcpu_fill_span\(.*?\n\}\n/m]
    %w[spnl_recd_offcpu_offcpu_ns_val( spnl_recd_offcpu_oncpu_ns_val( spnl_offcpu_wait_kind(].each do |i|
      assert_includes builder, i, "span builder が derivation #{i} を通っていない"
    end
    tree = bare[/^int spnl_otlp_request_tree_push_obj\(.*?\n\}\n/m]
    %w[spnl_recd_offcpu_offcpu_ns_val( spnl_recd_offcpu_oncpu_ns_val( spnl_offcpu_wait_kind(].each do |i|
      assert_includes tree, i, "E312 の request tree が独自に計算している (#{i} 未経由)"
    end
    # 宣言側: 3 つとも derived (フィールドの生 expose ではない)。
    props = CAP.record_properties("offcpu")
    %w[offcpu_ns oncpu_ns wait_kind].each do |n|
      p = props.find { |x| x[:name] == n }
      refute_nil p, "ev.#{n} が無い"
      assert_equal "derived", p[:kind], "ev.#{n} がフィールドの生 expose になっている"
    end
    # 生フィールドのうち「Ruby に出しても判断に使えないもの」は非公開のまま (E379 D3)。
    %w[wait_stack start_ktime hdr_ext req resp].each do |n|
      assert_nil props.find { |x| x[:name] == n }, "ev.#{n} が公開された (最小主義の意図に反する)"
    end
  end

  # E402: **場所 (frames) と種類 (kind) は 1 回の fetch の 2 つの読み方**。
  #
  # E397 が値について取り除いた失敗を、stack で作り直さないための構造を pin する。分類器の
  # 隣にもう 1 本フレーム走査を書けば、2 つの読みは**どのスタックを読んだかについて**食い違え
  # てしまう (map lookup は生きた BPF map で、2 回引けば 2 つの瞬間)。だから:
  #   - フレームの取得 (_oc_frames) は agent 全体で 1 関数、
  #   - 分類 (_oc_classify) と描画 (_oc_render) はどちらもその出力を受ける、
  #   - span builder と子 span (E312 の「待ち」span) は宣言された derivation を通る、
  #   - 深さの上限 (SPNL_STACK_FRAMES) は 1 箇所からしか読まない
  #     (2 箇所になれば ev と span で本数が違う = E377 の cap 問題の深さ版)。
  def test_offcpu_wait_stack_shares_one_frame_fetch
    agent = File.read(OTLP_AGENT_SRC)
    bare  = agent.gsub(%r{/\*.*?\*/}m, "")
    assert_equal 1, bare.scan(/^static int _oc_frames\(/).length,
                 "フレーム取得が 1 関数でない (kind と frames が別のスタックを読みうる)"
    kind = bare[/^static const char \*_oc_wait_kind\(.*?\n\}\n/m]
    refute_nil kind, "_oc_wait_kind() が読めない"
    assert_includes kind, "_oc_frames(", "分類器が共通のフレーム取得を通っていない"
    stack = bare[/^void spnl_offcpu_wait_stack\(const spnl_rec_offcpu_t \*r.*?\n\}\n/m]
    refute_nil stack, "spnl_offcpu_wait_stack() が宣言どおりの C シグネチャで無い"
    assert_includes stack, "_oc_frames(", "描画側が共通のフレーム取得を通っていない"
    assert_includes stack, "_oc_render(", "描画が共通の renderer を通っていない"
    # 深さの上限を読む場所は 1 つ (_oc_render の中)。
    assert_equal 1, bare.scan(/getenv\("SPNL_STACK_FRAMES"\)/).length,
                 "SPNL_STACK_FRAMES を 2 箇所以上で読んでいる (ev と span で本数が違いうる)"
    # 親 span (共通 builder) と E312 の待ち子 span、どちらも宣言された derivation 経由。
    builder = bare[/^static int offcpu_fill_span\(.*?\n\}\n/m]
    assert_includes builder, "spnl_offcpu_wait_stack(", "span builder が derivation を通っていない"
    push = bare[/^int spnl_otlp_offcpu_span_push_obj\(.*?\n\}\n/m]
    assert_includes push, "spnl_offcpu_wait_stack(",
                    "待ちの子 span が親と別経路でフレームを作っている"
    # 宣言側: derived であり、生の stack id は非公開のまま。
    props = CAP.record_properties("offcpu")
    p = props.find { |x| x[:name] == "wait_stack_trace" }
    refute_nil p, "ev.wait_stack_trace が無い"
    assert_equal "derived", p[:kind]
    assert_nil props.find { |x| x[:name] == "wait_stack" },
               "stack id (map の index) が公開された"
    # egress: 属性は spnl.wait.kind の兄弟として宣言され、opt-in であることが condition に出る。
    attrs = CAP.record_channels.find { |c| c[:id] == "offcpu" }[:egress][:attributes]
    st = attrs.find { |a| a[:key] == "spnl.wait.stack" }
    refute_nil st, "spnl.wait.stack が egress 宣言に無い"
    assert_match(/SPNL_STACK_FRAMES/, st[:condition],
                 "opt-in であることが condition に書かれていない (既定で出ると読まれる)")
    refute_nil attrs.find { |a| a[:key] == "spnl.wait.kind" }, "兄弟の spnl.wait.kind が消えた"
  end

  # E376: **単位も「同じ関数の出力」に含まれる**。srtt は wire が kernel の 1/8 us、span は
  # us なので、フィールドを生で expose すると `ev.srtt_us` だけが span 属性と別の値になる
  # (E375 の honest boundary)。derivation にしたので、
  #   - span builder (簡潔形 + 明示形 to_span) が derivation の impl を通ること
  #   - E312 の request tree (同じ record を子 span にする 2 つ目の消費者) も同じ impl を通ること
  #   - **`>> 3` が agent 全体で 1 箇所しかない** こと (2 箇所になれば黙ってずれうる)
  # を pin する。3 つ目が本命: 「割る場所が 1 つ」= 単位が 1 つ、を機械が守る。
  # E434: その「1 箇所」が **手書き C から宣言に移った** (impl_form int_expr)。不変量は同じ
  # で、探す場所が変わる: 換算は宣言に 1 回だけ書かれ、agent には `>> 3` が 1 つも無い。
  def test_conn_srtt_scaling_has_one_author
    # 散文の言及は換算ではない (E428 の msg_buffer test と同じ規律): コメントを外してから数える。
    agent = File.read(OTLP_AGENT_SRC).gsub(%r{/\*.*?\*/}m, "")
    hdr   = File.read(MIRROR_GEN_SRC)
    table = File.read(SCHEMA_TABLE_SRC)
    assert_equal 0, agent.scan(/srtt_us\s*>>\s*3/).length,
                 "srtt の単位換算が otlp_agent.c に残っている (宣言が唯一の作者であるべき)"
    assert_equal 1, table.scan(/"srtt_us >> 3"/).length,
                 "宣言側の換算が 1 箇所でない"
    impl = hdr[/^static inline long spnl_recd_conn_srtt_us_val\(const spnl_rec_conn_t \*r\).*?\n\}\n/m]
    refute_nil impl, "生成された srtt_us の helper が無い"
    assert_match(/srtt_us\)\s*>>\s*\(3\)/, impl, "生成 body が 1/8 us -> us の換算をしていない")
    builder = agent[/static int conn_fill_span\(.*?\n\}\n/m]
    assert_includes builder, "spnl_recd_conn_srtt_us_val(", "span が ev.srtt_us の実体を通っていない"
    tree = agent[/static int otlp_tree_fill_conn\(.*?\n\}\n/m]
    refute_nil tree, "otlp_tree_fill_conn() が読めない"
    assert_includes tree, "spnl_recd_conn_srtt_us_val(", "E312 の子 span が独自に換算している"
    # 宣言側: srtt_us は derived (フィールドの生 expose ではない) で Integer
    p = CAP.record_properties("conn").find { |x| x[:name] == "srtt_us" }
    refute_nil p, "ev.srtt_us が消えた (既存 consumer が壊れる)"
    assert_equal "derived", p[:kind]
    assert_equal "int",     p[:expose]
    assert_equal "spnl_rec_conn_srtt_us", p[:ffi], "FFI シンボルは field 形と同一のまま"
    assert_match(/MICROSECONDS/, p[:note], "単位が契約に書かれていない")
  end

  # egress の push_fn = E317 の userspace_export companion (同じ相方を 2 箇所で名指すので一致必須)。
  def test_egress_push_fn_matches_required_set_companion
    rule = CAP::REQUIRED_SETS.find { |r| r[:name] == "dns_span" }
    refute_nil rule
    assert_equal rule[:userspace_export][:fn], CAP.record_channel("dns")[:egress][:push_fn]
  end

  # 層2 enricher (E304/E315) は channel でなく env が付ける -> id で名指すだけ。
  # 名指した id が ENRICHERS registry に実在すること。
  def test_egress_enrichers_reference_registry_entries
    known = CAP::ENRICHERS.map { |e| e[:name] }
    CAP.record_channels.each do |c|
      Array(c.dig(:egress, :enrichers)).each do |id|
        assert_includes known, id, "未知の enricher id: #{id}"
      end
    end
  end

  # affordance JSON に record 契約が載る (追加のみ = 既存 schema は不変)。
  def test_affordance_json_carries_record_schema
    require "json"
    doc = JSON.parse(CAP.affordance_json)
    assert_equal "spinel-ebpf.affordance/1", doc["schema"], "既存 schema 名を変えていない"
    assert_equal DECLARED_CHANNELS.length, doc["summary"]["record_channel_count"]
    dns = doc["record_channels"].find { |c| c["id"] == "dns" }
    refute_nil dns, "affordance に record_channels が無い"
    assert_equal 128, dns["record_bytes"]
    e = doc["builtins"].find { |b| b["name"] == "emit_dns" }
    assert_equal "dns", e["record_channel"]
    assert_equal %w[hdr pid comm raw cgid duration_ns raw_status], e["record_schema"]["fields"].map { |f| f["name"] }
    assert_equal "spnl_otlp_dns_span_push", e["record_schema"]["egress"]["push_fn"]
    # record を書かない builtin は null (嘘の契約を作らない)。
    assert_nil doc["builtins"].find { |b| b["name"] == "hist_observe" }["record_channel"]
  end

  # E408 (ADR-015): surface sugar は **機械可読な等価性の主張** として affordance に
  # 載る。ruby_subset の散文だけだった間、`pkt.l4.proto` は本番 codegen に無いのに
  # 1 年間宣伝され続けた (E407 が実測) — 散文には検査すべき対象が定義されていない。
  def test_affordance_json_carries_surface_sugar_claims
    require "json"
    doc = JSON.parse(CAP.affordance_json)
    sugar = doc["surface_sugar"]
    refute_nil sugar, "affordance に surface_sugar が無い"
    assert_equal CAP.surface_sugar.size, sugar.size

    chain = sugar.find { |s| s["sugar"] == "pkt.l4.proto" }
    refute_nil chain, "pkt.* chain が載っていない (E407 が死を実測した当の surface)"
    assert_equal "pkt_l4_proto", chain["flat"]
    assert_equal "identical", chain["equiv"], "E071 の主張は byte-identical"

    # 「等価物のある綴り」であることが全エントリの不変量 = gate にかけられる形。
    sugar.each do |s|
      refute_nil s["sugar"]; refute_nil s["flat"]
      assert_includes %w[identical compiles], s["equiv"], "#{s['id']}: equiv 不明"
      refute_nil s["edoc"], "#{s['id']}: 出典 Edoc が無い"
    end

    # E060/E410: `pkt.byte_at(off)` は chain の唯一の 1 引数メンバで、flat 名が
    # `pkt_byte_at` でないため上の派生規則には載らない。E406/E408 で一度降ろされ
    # E410 で戻った surface なので、**戻っていること**を明示的に測る。
    ba = sugar.find { |s| s["sugar"] == "pkt.byte_at(14)" }
    refute_nil ba, "pkt.byte_at が sugar 主張に無い (E410 で戻した surface)"
    assert_equal "pkt_dynptr_byte_at(14)", ba["flat"]
    assert_equal "identical", ba["equiv"]
    assert_includes CAP.all_builtins, "pkt_dynptr_byte_at",
                    "chain 側だけ戻して flat 側を宣伝し忘れている"

    # 降ろした綴りも出す (黙って消さない、E406/E407 と同じ規約)。
    #
    # **E414 で「空でないこと」の要求を外した。** E410 が入れたその assertion は
    # E415 以前の gate の abort と同じ前提に立っていた —— 降格集合が negative
    # control を兼ねるという前提で、E415 はそれを「直すほどゲートが弱くなる」
    # 問題として切り離した (検出力は合成された self-check が持つ)。E414 が最後の
    # エントリ (`on :user_cmd`) を移植したので、ここは**空が正解**である。
    # 残す不変量は形だけ: 在るものは `instead` を持ち、戻したものは残っていない。
    wd = doc["withdrawn_sugar"]
    refute_nil wd, "affordance に withdrawn_sugar が無い"
    refute wd.key?("pkt.byte_at(0)"), "pkt.byte_at は E410 で戻したので降格表に残ってはいけない"
    refute wd.key?("on :user_cmd do |cmd| ... end"),
           "on :user_cmd は E414 で戻したので降格表に残ってはいけない"
    wd.each_value { |v| refute_nil v["instead"] }
  end

  # E374 (ADR-017 D3-5): `to_span` の解決規則は **機械可読** に出る (emit_path の
  # context gate と同型)。AI が「なぜ落ちたか / どう書けばよいか」を affordance から
  # 読めなければ、loud error は「行番号なし syntax error」と同類になる。
  def test_consumer_dsl_surface_publishes_the_to_span_resolution_rule
    require "json"
    doc = JSON.parse(CAP.affordance_json)
    dsl = doc["consumer_dsl"]
    refute_nil dsl, "affordance に consumer_dsl が無い"
    assert_equal TYPED_CHANNELS, dsl["typed_channels"]
    verbs = dsl["verbs"].to_h { |v| [v["name"], v] }
    assert_equal %w[on_emit :<channel>].join(" "), verbs.keys.first   # 語彙の先頭 = 受け口
    ts = verbs.fetch("to_span")
    assert_match(/on_emit :<channel>/, ts["context_note"], "解決スコープが書かれていない")
    assert_match(/compile error/, ts["context_note"], "解決できない場合の帰結が書かれていない")
    assert_match(/<channel>_span/, ts["context_note"], "escape hatch が案内されていない")
    # ADR-017 D2: span の中身を Ruby から足す API は無い、と明言する
    assert_match(/the egress declaration is authoritative/, ts["gotcha"])
    assert_match(/an escape hatch, not the main form/, verbs.fetch("<channel>_span")["context_note"])
    # E325 の bug class (drain 忘れ) は consume_records の context に残す
    assert_match(/if it is not called, the handlers are never called/, verbs.fetch("consume_records")["context_note"])
    # 人間可読側にも同じ内容が出る
    r = CAP.catalog_report
    assert_match(/userspace consumer DSL/, r)
    assert_match(/typed channels .*: dns, conn, l7, http/, r)
  end

  # ---------- E409: map 語彙 ----------

  # ADR-015 の出荷物は affordance である。map について 1 語も無い状態では、AI は
  # 「@x += 1 と書くと map が 1 本出来る」ことも「ringbuf が溢れたら黙って捨てる」
  # ことも読めない (E409 以前がその状態だった)。JSON に出ていることを固定する。
  def test_affordance_json_carries_the_map_vocabulary
    a = JSON.parse(CAP.affordance_json)
    maps = a.fetch("maps")
    refute_empty maps
    assert_equal maps.size, a["summary"]["map_count"]
    assert_equal maps.map { |m| m["type"] }.uniq.size, a["summary"]["map_type_count"]
    # 1 エントリ = 「どの surface が、どの map を、どんな形で作るか」
    hist = maps.find { |m| m["id"] == "hist" }
    assert_equal "bpf_hist", hist["map"]
    assert_equal "ARRAY", hist["type"]
    assert_equal "64", hist["max_entries"]
    assert_includes hist["created_by"], "hist_observe"
    # 容量だけでは判断できない。溢れたときどうなるかが本体
    maps.each { |m| refute_nil m["when_full"], "#{m['id']}: 満杯時の挙動が無い" }
    # ringbuf の「黙って捨てる」は E393 の実測と結線して書く
    rb = maps.find { |m| m["id"] == "dns_events" }
    assert_equal "RINGBUF", rb["type"]
    assert_match(/lost/, rb["when_full"])
    # per-CPU は「userspace が足す」まで言わないと読めない
    lost = maps.find { |m| m["id"] == "ringbuf_lost" }
    assert_equal true, lost["per_cpu"]
    assert_match(/per-CPU/, lost["note"])
    # E414: `withdrawn_maps` は**空になった** (USER_RINGBUF を戻したため)。
    # E409 が入れた refute_empty は降格在庫を negative control 扱いする前提で、
    # E415 がその前提を外している ⇒ 要求するのは「キーが在ること」だけ。
    wm = a.fetch("withdrawn_maps")
    refute_nil wm, "affordance に withdrawn_maps が無い"
    refute wm.key?("USER_RINGBUF"), "USER_RINGBUF は E414 で戻したので降格表に残ってはいけない"
  end

  # ---------- E426: 構文語彙 ----------
  #
  # 5 つ目の語彙。E408 が「散文は gate にかけられない」と診断したあと、
  # `RUBY_SUBSET[:supported]` そのものは 14 個の文字列のまま残り、その中で
  # **2 構文が死んだまま宣伝され続けた** (literal `n.times` / `x = if ... end`)。
  # JSON にも出す — 出さないと、affordance を JSON でしか読まない消費者から見て
  # 「書ける構文」は依然として散文だけになる (E419 が withdrawn builtin で
  # 見つけたのと同型)。
  def test_affordance_json_carries_the_syntax_vocabulary
    a = JSON.parse(CAP.affordance_json)
    syn = a.fetch("syntax")
    refute_empty syn
    assert_equal syn.size, a["summary"]["syntax_count"]
    # 1 エントリ = 「この綴りは、この C になる」+「その構文を外した twin」
    syn.each do |s|
      refute_empty s["lowers_to"].to_s, "#{s['id']}: lowers_to が無い = 主張が「通る」だけになる"
      refute_nil s["without"], "#{s['id']}: twin が無い = needle が定型で満たされても分からない"
      refute_equal s["syntax"], s["without"], "#{s['id']}: twin が本体と同じ"
    end
    # E426 が移植した 2 件は名指しで載っている (両方 lowering の主張つき)
    lit = syn.find { |s| s["id"] == "times_literal" }
    assert_match(/bpf_iter_num/, lit["lowers_to"])
    dyn = syn.find { |s| s["id"] == "times_dynamic" }
    assert_match(/bpf_loop/, dyn["lowers_to"])
    refute_equal lit["lowers_to"], dyn["lowers_to"],
                 "両方 compile し両方宣伝されている 2 つが同じ機械に落ちるなら、" \
                 "open-coded 経路が消えても誰も気づかない"
    ifv = syn.find { |s| s["id"] == "if_value" }
    refute_nil ifv, "E426 が移植した式位置の if が宣伝されていない"
    # 逆向きの検査の権威も出す (どこを読めば「codegen が何を受理するか」が分かるか)
    auth = a.fetch("syntax_coverage_authorities")
    assert auth.key?("node_types") && auth.key?("binary_ops")
    refute_nil a["withdrawn_syntax"]
  end

  # 散文は残してよいが正本ではない、と affordance 自身が言うこと。
  # これが書いていないと、次に構文を足す人は 15 個目の文字列を足して終わる。
  def test_the_prose_subset_says_it_is_not_the_authority
    src = File.read(File.expand_path("../../src/spinel_ebpf/capabilities.rb", __dir__), encoding: "UTF-8")
    block = src[/RUBY_SUBSET = \{(.*?)supported:/m]
    refute_nil block
    assert_match(/正本/, block, "散文が正本でないことが RUBY_SUBSET の直上に書かれていない")
    assert_match(/SYNTAX/, block, "どこが正本かが書かれていない")
  end

  # rejected 側は最初から機械可読だったが、**測られていなかった** (E426 D3)。
  # 各行は「入力」と「期待する拒否理由」を自分で持つ。
  def test_rejected_rows_carry_their_own_probe_and_expected_refusal
    a = JSON.parse(CAP.affordance_json)
    rej = a["ruby_subset"]["rejected"]
    assert_equal rej.size, a["summary"]["syntax_rejected_count"]
    rej.each do |r|
      refute_empty r["probe"].to_s, "#{r['flag']}: probe が無い = この拒否は測られない"
      refute_empty r["refusal"].to_s, "#{r['flag']}: 期待する拒否理由が無い"
    end
    big = rej.find { |r| r["flag"] == "uses_bignum" }
    assert_match(/E426/, big["note"].to_s,
                 "E426 まで exit 0 だった唯一の flag なので、その事実が affordance に残ること")
  end

  # `SEC(".maps")` に現れない 4 形 (struct_ops / .rodata / private(A) / libbpf
  # ヘッダ) も載っている。ここが抜けると「宣言が無い = map が無い」という、
  # E409 の text scanner が最初に踏んだ誤解をそのまま出荷することになる。
  def test_affordance_covers_maps_that_are_not_declared_as_maps
    forms = CAP::MAPS.group_by { |m| m[:declared_as] }
    %i[maps struct_ops rodata data_section libbpf_header].each do |f|
      refute_nil forms[f], "declared_as: #{f} のエントリが無い"
    end
    assert_equal %w[param filter_by], forms[:rodata].first[:created_by]
    # usdt を 1 個書くと map が 3 本増える (生成 C に宣言は無い)
    assert_equal 3, forms[:libbpf_header].size
    forms[:libbpf_header].each { |m| assert_equal %w[usdt], m[:created_by] }
  end

  # 「この probe が使う builtin の集合 -> 出来る map」を引ける (describe 用の口)。
  def test_maps_created_by_resolves_surfaces_to_maps
    ids = CAP.maps_created_by(%w[emit_dns]).map { |m| m[:id] }
    assert_includes ids, :dns_events
    assert_includes ids, :ringbuf_lost, "emit 系は lost counter も作る"
    assert_empty CAP.maps_created_by(%w[pid])
  end

  # (人間可読) catalog に maps セクションが出る。
  def test_catalog_report_shows_maps
    r = CAP.catalog_report
    assert_match(/maps \(E409/, r)
    assert_match(/bpf_hist\s+ARRAY\s+max_entries=64/, r)
    assert_match(/\[struct_ops\]/, r)
    assert_match(/when full: /, r)
  end

  # (人間可読) catalog に record channel セクション (byte 像 + egress) が出る。
  def test_catalog_report_shows_record_channels
    r = CAP.catalog_report
    assert_match(/record channels/, r)
    assert_match(/<unit>_dns_event \(128 B\)/, r)
    assert_match(/@112\s+duration_ns/, r)
    assert_match(/egress: spnl_otlp_dns_span_push -> span "resolve \{dns\.question\.name\}"/, r)
    assert_match(/spnl\.dns\.latency_ns\s+spinel/, r)
  end
end
