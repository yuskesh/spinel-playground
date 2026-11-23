# frozen_string_literal: true
#
# Run: ruby -Isrc -Itests tests/spinel_ebpf/introspect_test.rb
#
# E242 (4): `describe` emit/consumer introspection.

require "minitest/autorun"
require "spinel_ebpf/introspect"

class IntrospectTest < Minitest::Test
  I = SpinelEbpf::Introspect

  def test_emits_detects_kinds_and_ignores_comments
    src = <<~RUBY
      # spnl_emit_pair(a, b) in a comment must NOT count
      def k(ret)
        spnl_emit_pair(0, latency_end)
      end
      def j; spnl_emit(7); end
    RUBY
    es = I.emits(src)
    assert_equal %w[spnl_emit_pair spnl_emit], es.map { |e| e[:name] }
    assert_equal [2, 1], es.map { |e| e[:arity] }
  end

  def test_consumers_capture_params
    src = "on_emit_pair do |svc, dur|\nend\non_emit do |v|\nend\n"
    cs = I.consumers(src)
    assert_equal %w[on_emit_pair on_emit], cs.map { |c| c[:consumer] }
    assert_equal [2, 1], cs.map { |c| c[:nparams] }
  end

  def test_report_binding_ok
    src = "spnl_emit_pair(0, x)\non_emit_pair do |a, b|\nend\n"
    r = I.report(src, "t.rb")
    assert_match(/:pair\s+producers\[spnl_emit_pair@L1\] -> consumers\[on_emit_pair@L2\]\s+OK/, r)
    assert_match(/warnings:\n\s+\(none\)/, r)
  end

  def test_report_warns_arity_mismatch
    src = "spnl_emit_pair(0, x)\non_emit_pair do |a|\nend\n"
    r = I.report(src, "t.rb")
    assert_match(/1 block params != emit arity 2/, r)
  end

  def test_report_warns_missing_consumer_and_producer
    miss_cons = I.report("spnl_emit(1)\n", "t.rb")
    assert_match(/has no matching on_emit/, miss_cons)
    miss_prod = I.report("on_emit do |v|\nend\n", "t.rb")
    assert_match(/on_emit has no matching emit/, miss_prod)
  end

  def test_report_warns_multisite_indistinguishable
    src = "spnl_emit_pair(0, a)\nspnl_emit_pair(1, b)\non_emit_pair do |x, y|\nend\n"
    r = I.report(src, "t.rb")
    assert_match(/2 emits of the same kind/, r)
  end

  # ---------- E242 #3: named events in describe ----------

  # E374: これらの fixture はもともと名前に `:http` を使っていたが、`http` は S4 の
  # 型付き channel として opt-in されたので (ADR-017 D4)、`on_emit :http` は **typed record
  # consumer** の意味になる。E242 named event の検査なので、channel id でない名前を使う
  # (下の test_channel_id_name_is_a_typed_consumer_not_a_named_event がその境界を pin する)。
  def test_named_emits_and_consumers_scanned
    src = "  emit :http_open, dur\non_emit :http_open do |v|\nend\n"
    assert_equal [{ line: 1, name: "http_open", text: "emit :http_open, dur" }], I.named_emits(src)
    assert_equal "http_open", I.named_consumers(src).first[:name]
  end

  def test_report_named_binding_and_tag
    src = "emit :http_open, dur\non_emit :http_open do |v|\nend\n"
    r = I.report(src, "t.rb")
    assert_match(/named events/, r)
    assert_match(/:http_open\s+tag=0x\h+\s+producers\[emit@L1\] -> consumers\[on_emit@L2\]\s+OK/, r)
  end

  def test_report_named_warns_missing
    miss = I.report("on_emit :http_open do |v|\nend\n", "t.rb")
    assert_match(/on_emit :http_open has no matching emit/, miss)
  end

  # E374 の互換境界 (E372 が予告した唯一の破壊面): channel を opt-in した瞬間、その id と
  # 同名の E242 named event は **typed record consumer** の意味になる。describe は named
  # events でなく record channels 側に出す — 黙って別物になるのではなく、表示も contract も
  # 型付き側に切り替わることを pin しておく。
  # E374: 2 channel を consume する probe で、「この consumer が record の何を読んだか」は
  # **ブロック内**だけを見る。ファイル全体を見ると同名 param (`ev`) の別 channel の read を
  # 取り違え、プライバシーレビューの粒度が嘘になる。
  def test_reads_are_scoped_to_each_block
    src = "on_emit :dns do |ev|\n  puts ev.qname\nend\n" \
          "on_emit :http do |ev|\n  puts ev.status\nend\n"
    cs = I.record_consumers(src)
    assert_equal [%w[qname], %w[status]], cs.map { |c| c[:props] }
    assert_equal %w[dns http], cs.map { |c| c[:channel] }
    r = I.report(src, "t.rb")
    assert_match(/consumer: on_emit :dns do \|ev\|@L1  \(ev\.pid.*\)\n\s+reads: ev\.qname\n/, r)
    assert_match(/consumer: on_emit :http do \|ev\|@L4  \(ev\.pid.*\)\n\s+reads: ev\.status\n/, r)
  end

  def test_channel_id_name_is_a_typed_consumer_not_a_named_event
    r = I.report("on_emit :http do |ev|\n  puts ev.path\nend\n", "t.rb")
    assert_match(/consumer: on_emit :http do \|ev\|/, r)
    assert_match(/reads: ev\.path/, r)
    assert_empty I.named_consumers("on_emit :http do |ev|\nend\n"),
                 "channel id は named event として数えない (二重に出る)"
  end

  # ---------- E370 (S3): packed-record channel の egress 要約 ----------

  # 完全な probe (emit + drain) は「何を書き、何の span になるか」が全部出て warning 無し。
  FULL_DNS_PROBE = <<~RUBY
    module Otlp
      ffi_func :spnl_otlp_dns_span_push, [:str], :int
    end
    def kprobe__udp_sendmsg(sk, msg, len)
      emit_dns(msg)
      0
    end
    loop { sleep 2; Otlp.spnl_otlp_dns_span_push("http://127.0.0.1:4318") }
  RUBY

  def test_record_emits_scanned_with_channel
    res = I.record_emits(FULL_DNS_PROBE)
    assert_equal [{ line: 5, name: "emit_dns", channel: "dns" }], res
    assert_empty I.record_emits("hist_observe(1)\n"), "スカラ emit は record channel でない"
    assert_empty I.record_emits("# emit_dns(msg) in a comment\n"), "コメントは拾わない"
  end

  def test_report_shows_record_layout_and_egress_attributes
    r = I.report(FULL_DNS_PROBE, "t.rb")
    assert_match(/record channels/, r)
    assert_match(/dns\s+<unit>_dns_event \(128 B, map <unit>_dns_events\) <- emit_dns@L5/, r)
    assert_match(/@36\s+raw\s+unsigned char\[64\]/, r)   # byte 像 (offset は生成器由来)
    assert_match(/egress: spnl_otlp_dns_span_push -> span "resolve \{dns\.question\.name\}" \(SpanKind INTERNAL\)/, r)
    assert_match(/dns\.question\.name\s+semconv/, r)
    assert_match(/spnl\.dns\.latency_ns\s+spinel/, r)    # 独自属性は semconv と区別して出る
    assert_match(/layer-2 enricher.*k8s, cri/, r)
    assert_match(/warnings:\n\s+\(none\)/, r)
  end

  # E325 の bug class: kernel が record を貯めても drain が無ければ span 0 本。
  # describe は compile を止めない (レビュー surface) が、そこを名指しで警告する。
  # E371 (S4) で drain には 2 形式ができたので、警告は**両方無い**ときだけ出る。
  def test_report_warns_when_record_drain_is_missing
    r = I.report("def kprobe__udp_sendmsg(sk, msg, len)\n  emit_dns(msg)\n  0\nend\n", "t.rb")
    assert_match(/spnl_otlp_dns_span_push/, r)
    assert_match(/on_emit :dns do \|ev\|/, r)          # 明示形も示唆する
    assert_match(/no span is produced \(E325\)/, r)
  end

  # --- E371 (S4): typed record consumer ---------------------------------

  TYPED_DNS_PROBE = <<~RB
    def kprobe__udp_sendmsg(sk, msg, len)
      emit_dns(msg)
      0
    end
    @ep = "http://127.0.0.1:4318"
    on_emit :dns do |ev|
      next unless ev.qname.end_with?(".invalid")
      send_otlp(to_span(ev), @ep)
    end
    loop { sleep 1; consume_records(200) }
  RB

  # 明示形は push FFI を呼ばない。E370 の drain 警告がそのまま残っていると
  # 「正しい probe に嘘の警告」が出る (E370 申し送り 4) — それが消えていること。
  def test_typed_consumer_satisfies_the_drain_requirement
    r = I.report(TYPED_DNS_PROBE, "t.rb")
    refute_match(/no span is produced \(E325\)/, r)
    assert_match(/warnings:\n\s+\(none\)/, r)
  end

  # `on_emit :dns` は record channel id なので E242 named event ではない。
  # 誤分類すると「emit :dns が無い」という嘘の警告が出る。
  def test_typed_consumer_is_not_reported_as_a_named_event
    r = I.report(TYPED_DNS_PROBE, "t.rb")
    refute_match(/named events/, r)
    refute_match(/on_emit :dns has no matching emit/, r)
    assert_empty I.named_consumers(TYPED_DNS_PROBE)
  end

  # consumer の binding と「実際に読んでいるプロパティ」がレビュー surface に出る。
  def test_report_shows_typed_consumer_binding_and_properties_read
    r = I.report(TYPED_DNS_PROBE, "t.rb")
    assert_match(/consumer: on_emit :dns do \|ev\|@L6\s+\(ev\.pid ev\.comm ev\.cgid ev\.duration_ns ev\.qname\)/, r)
    assert_match(/reads: ev\.qname/, r)
    sites = I.record_consumers(TYPED_DNS_PROBE)
    assert_equal 1, sites.length
    assert_equal({ channel: "dns", param: "ev" }, sites[0].slice(:channel, :param))
    assert_equal ["qname"], sites[0][:props]
  end

  # 明示形の E325: block はあるが drain ループ (consume_records) を呼んでいない。
  def test_report_warns_when_typed_consumer_is_never_driven
    src = TYPED_DNS_PROBE.sub(/loop.*\n/, "")
    r = I.report(src, "t.rb")
    assert_match(/consume_records\(timeout_ms\) is never called/, r)
  end

  # 逆向きの穴: consumer だけ書いて producer (emit_dns) が無い = 0 件を drain し続ける。
  def test_report_warns_when_typed_consumer_has_no_producer
    src = "@ep = \"x\"\non_emit :dns do |ev|\n  send_otlp(to_span(ev), @ep)\nend\nconsume_records(1)\n"
    r = I.report(src, "t.rb")
    assert_match(/no builtin that writes the record \(emit_dns \/ dns_emit\)/, r)
  end

  # ---- S4: `# @intent` / `# @expect` — 表示するだけで検査しない -------------

  ANNOTATED = <<~RB
    # @intent  DNS を引いたプロセスと名前を記録する
    # @expect  span 1 本 = query 1 個
    #          A と AAAA は別 query なので 1 解決で 2 本出る
    # ここは普通のコメント (字下げが足りないので続きではない)
    def kprobe__udp_sendmsg(sk, msg, len)
      emit_dns(msg)
    end
  RB

  def test_annotations_are_parsed_with_line_and_tag
    a = I.annotations(ANNOTATED)
    assert_equal 2, a.length
    assert_equal ["intent", "expect"], a.map { |x| x[:tag] }
    assert_equal [1, 2], a.map { |x| x[:line] }
    assert_match(/DNS を引いたプロセス/, a[0][:text])
  end

  # 続き行は取り込む。作者が書いたものが黙って消えるのは、書いていないものを
  # 意図として表示するのと同じくらい悪い。
  def test_indented_continuation_is_folded_into_the_previous_annotation
    a = I.annotations(ANNOTATED)
    assert_match(/A と AAAA は別 query/, a[1][:text])
  end

  # 逆に、字下げの足りない直後のコメントは吸い込まない。
  def test_ordinary_comment_after_an_annotation_is_not_swallowed
    a = I.annotations(ANNOTATED)
    refute(a.any? { |x| x[:text].include?("普通のコメント") },
           "字下げの足りないコメントを意図として取り込んでいる")
  end

  # 隣接していない続き行は拾わない (別の場所のコメントが後から吸われないこと)。
  def test_continuation_must_be_adjacent
    src = "# @intent  foo

#     これは離れているので続きではない
"
    a = I.annotations(src)
    assert_equal 1, a.length
    assert_equal "foo", a[0][:text]
  end

  def test_report_shows_stated_intent_and_says_it_is_not_checked
    r = I.report(ANNOTATED, "t.rb")
    assert_match(/stated intent/, r)
    assert_match(/not checked/, r)
    assert_match(/@intent/, r)
  end

  # 無いときも節は出す (見つけてもらうため) が、warnings には**入れない**。
  # 警告にすると「書けば安全」という読まれ方をする。
  def test_missing_intent_is_a_hint_not_a_warning
    src = "def kprobe__x(a)\n  spnl_emit(a)\nend\n"
    r = I.report(src, "t.rb")
    assert_match(/stated intent .*:\n  \(none\)/, r)
    warn_section = r[/\nwarnings:\n.*/m]
    refute_match(/@intent/, warn_section)
  end
  # --- E400: describe must say what a probe's metrics COST --------------------

  E400_SRC = <<~RUBY
    def kprobe__tcp_sendmsg(sk, msg, size)
      http_req_start(sk, msg)
      0
    end
    def kretprobe__tcp_recvmsg(ret)
      http_emit(ret)
      0
    end
    on_emit :http do |ev|
      send_otlp(to_span(ev), @ep)
    end
    consume_records(300)
  RUBY

  def test_describe_shows_the_metric_and_its_series_bound
    out = I.report(E400_SRC, "e400.rb")
    assert_match(/metric: spnl\.http\.client\.request\.duration/, out)
    assert_match(/series <= 180/, out, "series の上限が describe に出ていない")
  end

  def test_describe_names_the_coarsening_a_label_performs
    # 「bound 10」だけ出して「集合外は _OTHER になる」を出さないと、読者は
    # ダッシュボードで _OTHER を見るまで気づけない。
    out = I.report(E400_SRC, "e400.rb")
    assert_match(/label http\.request\.method/, out)
    assert_match(/declared set \(9\) \+ "_OTHER"/, out)
    assert_match(/the span keeps the exact value/, out)
  end

  def test_describe_says_how_to_push_the_metric
    out = I.report(E400_SRC, "e400.rb")
    assert_match(/spnl_otlp_record_metrics_push\(endpoint\)/, out)
  end

  def test_a_probe_touching_no_metric_channel_gets_no_metric_lines
    src = <<~RUBY
      def kprobe__udp_sendmsg(sk, msg, len)
        emit_dns(msg)
        0
      end
      on_emit :dns do |ev|
        send_otlp(to_span(ev), @ep)
      end
      consume_records(300)
    RUBY
    out = I.report(src, "e400b.rb")
    refute_match(/metric: /, out, "metric を持たない channel に metric の話をさせている")
  end


  # E418: `describe` は「この probe が書いている hook は本当に発火するか」を言う。
  # gate を通ること (compile OK) と発火することは別で、両者の混同こそが E390 の
  # truncate 空振りの正体だった。**32 本の一覧ではなくこの probe の hook だけ**を出す。
  def test_e418_describe_reports_firing_for_the_hooks_this_probe_writes
    src = "def fentry__vfs_getattr(p0)\n  emit_path(p0)\n  0\nend\n"
    r = I.report(src, "t.rb")
    assert_includes r, "fentry/vfs_getattr"
    assert_includes r, "the return value is ignored", "verdict を持たない hook だと言うこと"
    assert_includes r, "does not fire for stat(2)", "一番踏みやすい誤解を名指しすること"
    assert_includes r, "E418 h27", "発火を測った出典"
  end

  # 逆向き: 遮断まで測れている hook では「観測専用」と言わない (過剰警告は無視される)。
  def test_e418_describe_reports_deny_tier_without_the_observe_warning
    src = "def lsm__path_mkdir(dir)\n  if path_eq(dir, \"/tmp/g\")\n    -1\n  else\n    0\n  end\nend\n"
    r = I.report(src, "t.rb")
    assert_includes r, "lsm/path_mkdir"
    assert_includes r, "fire + block measured"
    refute_includes r, "the return value is ignored"
    # lsm/* だけの落とし穴 (active LSM に bpf が無いと沈黙する) は出す。
    assert_includes r, "stays silent"
  end

  # gate 外の hook しか書いていない probe に d_path の話をさせない。
  def test_e418_describe_stays_quiet_when_no_path_builtin_is_used
    src = "def kprobe__do_sys_openat2(dfd)\n  spnl_emit(dfd)\nend\n"
    r = I.report(src, "t.rb")
    refute_includes r, "fire + block measured"
  end

  # ===================================================================
  # E419 非対称 1: **推奨している綴りの方が affordance が空**だった。
  #
  # E408 は「2 つの綴りが同じ生成 C になる」を 60 主張で毎回実測しているのに、
  # 内省はその等価性を一度も見ていなかった (`pkt.l4.proto` → `(none)` /
  # `pkt_l4_proto` → `net pkt_l4_proto`)。ここはその等価性の **内省への延長**で、
  # 主張の一覧は surface_sugar から導出されるので、族にメンバが増えれば
  # 検査対象も自動で増える (期待値をテストに書かない = E407 の設計)。
  # ===================================================================
  CAP = SpinelEbpf::Capabilities

  # sugar の形に合った最小 source。`:expr` は読み値、`:stmt` はそのまま 1 文。
  def sugar_src(text, form)
    body = form == :stmt ? text.to_s : "x = #{text}"
    "def probe_e419\n  #{body}\nend\n"
  end

  def test_e419_every_sugar_alias_reports_the_same_domain_as_its_flat_spelling
    aliases = CAP.sugar_builtin_aliases
    refute_empty aliases, "sugar→builtin の導出が空 = 内省は chain 綴りを一切見ていない"
    aliases.each do |a|
      s = CAP.surface_sugar.find { |x| x[:id] == a[:id] }
      dom_sugar = I.builtin_domains(sugar_src(a[:sugar], s[:form]))
      dom_flat  = I.builtin_domains(sugar_src(s[:flat], s[:form]))
      refute_empty dom_flat, "#{a[:sugar]}: flat 側 (#{a[:flat]}) すら domain を出していない"
      assert_equal dom_flat, dom_sugar,
                   "#{a[:sugar]} と #{s[:flat]} は同じ C になる (E408) のに domain が違う"
    end
  end

  # 導出が **黙って縮む** のを止める。surface_sugar 側に「ドット付きの 1 式で、
  # flat が builtin」の主張があるのに alias に載っていなければ、その綴りは
  # また内省から消える (それが E419 で見つかった状態そのもの)。
  def test_e419_alias_derivation_covers_every_dotted_builtin_sugar_claim
    covered = CAP.sugar_builtin_aliases.map { |a| a[:id] }.sort
    expected = CAP.surface_sugar.select { |s|
      next false unless %i[expr stmt].include?(s[:form])
      next false unless s[:sugar].to_s.include?(".")
      CAP.all_builtins.include?(s[:flat].to_s[/\A[a-z_]\w*/].to_s)
    }.map { |s| s[:id] }.sort
    assert_equal expected, covered,
                 "ドット綴りの builtin sugar 主張と、内省が解決できる集合が一致しない"
    # pkt.* の 15 reader は E410/E419 が名指しで数えた面なので、数も固定する。
    pkt = CAP.sugar_builtin_aliases.count { |a| a[:dotted].start_with?("pkt.") && a[:op].nil? }
    assert_equal CAP::SUGAR_PKT_CHAIN.size + 1, pkt,
                 "pkt.* chain 15 reader + pkt.byte_at の 16 個が解決されるべき"
  end

  # 読み形と書き形は **別の builtin** に落ちる (E070)。同じ綴りの前半を共有するので、
  # 素朴な文字列置換だと書きを読みと報告する — 生成 C は正しいまま内省だけがずれる、
  # E419 が閉じたのとまったく同じ形の沈黙になる。
  def test_e419_dot_write_forms_are_not_reported_as_reads
    w = I.builtin_domains("def tcp_cc__cong_avoid(sk, ack, acked)\n  sk.snd_cwnd = 10\nend\n")
    assert_equal({ net: ["tcp_sock_snd_cwnd_set"] }, w)
    a = I.builtin_domains("def tcp_cc__cong_avoid(sk, ack, acked)\n  sk.snd_cwnd += 1\nend\n")
    assert_equal({ net: ["tcp_sock_snd_cwnd_add"] }, a)
    # `==` は代入ではない (比較を書いた reader が消えては困る)。
    c = I.builtin_domains("def xdp__p\n  if pkt.l4.proto == 1\n    @a = @a + 1\n  end\nend\n")
    assert_equal({ net: ["pkt_l4_proto"] }, c)
  end

  # E412 の罠 (describe の text scan が **コメントを読んでいた**) を chain 側でも塞ぐ。
  # 併せて `pkt` を root としない綴りを拾わないこと (codegen の cc_pkt_chain_name は
  # root が裸の `pkt` であることを要求する)。
  def test_e419_chain_scan_ignores_comments_and_non_pkt_roots
    assert_empty I.builtin_domains("# pkt.l4.proto と書いた説明文\ndef xdp__p\n  XDP_PASS\nend\n")
    assert_empty I.builtin_domains("def xdp__p\n  foo.pkt.len\nend\n")
  end
end
