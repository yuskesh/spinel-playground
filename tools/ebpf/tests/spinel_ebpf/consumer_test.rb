# frozen_string_literal: true
#
# Run: ruby -Isrc -Itests tests/spinel_ebpf/consumer_test.rb
#
# E242: userspace consumer DSL (on_emit / on_emit_pair) source transform.

require "minitest/autorun"
require "spinel_ebpf/consumer"

class ConsumerTest < Minitest::Test
  C = SpinelEbpf::Consumer

  DSL_INT = <<~RUBY
    @sum = 0
    def produce(n)
      n.times { |i| spnl_emit(i) }
    end
    on_emit do |v|
      @sum = @sum + v
    end
    produce(5)
    consume_events(200)
    puts @sum
  RUBY

  DSL_PAIR = <<~RUBY
    @reqs = 0
    on_emit_pair do |svc, dur|
      @reqs = @reqs + 1
    end
    consume_events(100)
  RUBY

  def test_present_kinds
    assert_equal({ "" => 1 }, C.present(DSL_INT))            # suffix => nparams
    assert_equal({ "_pair" => 2 }, C.present(DSL_PAIR))
    refute C.present?("def f(x)\n  x + 1\nend\n")
  end

  def test_int_block_lowered_to_method
    out = C.transform(DSL_INT)
    assert_includes out, "def __spnl_consume_int(v)"
    refute_match(/^\s*on_emit\s+do/, out)
    assert_includes out, "  @sum = @sum + v"        # body preserved
    assert_includes out, "__spnl_consume_events(200)" # call rewritten
    refute_match(/^\s*consume_events\(/, out)
  end

  def test_pair_block_lowered_to_method
    out = C.transform(DSL_PAIR)
    assert_includes out, "def __spnl_consume_pair(svc, dur)"
    assert_includes out, "__spnl_consume_events(100)"
  end

  def test_int_driver_ffi_and_loop
    out = C.transform(DSL_INT)
    assert_includes out, "ffi_func :spnl_consume_poll, [:int], :int"
    assert_includes out, "ffi_func :spnl_consume_count_int, [], :int"
    assert_includes out, "ffi_func :spnl_cget, [:int], :int"
    assert_includes out, "SpnlConsumeFFI.spnl_consume_poll(t)"   # single persistent poll
    assert_match(/n0 = SpnlConsumeFFI\.spnl_consume_count_int/, out)
    assert_match(/__spnl_consume_int\(SpnlConsumeFFI\.spnl_cget\(i0\)\)/, out)
  end

  def test_pair_driver_ffi_and_loop
    out = C.transform(DSL_PAIR)
    assert_includes out, "ffi_func :spnl_consume_count_pair, [], :int"
    assert_includes out, "ffi_func :spnl_cget_pair_a, [:int], :int"
    assert_includes out, "ffi_func :spnl_cget_pair_b, [:int], :int"
    assert_match(/__spnl_consume_pair\(SpnlConsumeFFI\.spnl_cget_pair_a\(i0\), SpnlConsumeFFI\.spnl_cget_pair_b\(i0\)\)/, out)
  end

  def test_pair_with_timestamp_param
    # E242 #1: an extra trailing param beyond the value arity binds the ts.
    src = "on_emit_pair do |svc, dur, ts|\n  @x = ts\nend\nconsume_events(0)\n"
    out = C.transform(src)
    assert_includes out, "def __spnl_consume_pair(svc, dur, ts)"
    assert_includes out, "ffi_func :spnl_cget_pair_ts, [:int], :long"
    assert_match(/__spnl_consume_pair\(SpnlConsumeFFI\.spnl_cget_pair_a\(i0\), SpnlConsumeFFI\.spnl_cget_pair_b\(i0\), SpnlConsumeFFI\.spnl_cget_pair_ts\(i0\)\)/, out)
  end

  def test_int_no_ts_unchanged
    out = C.transform(DSL_INT)   # |v| only -> no ts getter
    refute_includes out, "spnl_cget_ts"
  end

  def test_on_emit_with_trailing_comment
    src = "on_emit do |v|   # handle each event\n  @s = @s + v\nend\nconsume_events(50)\n"
    out = C.transform(src)
    assert_includes out, "def __spnl_consume_int(v)"
    assert_includes out, "__spnl_consume_events(50)"
  end

  def test_transform_noop_without_dsl
    plain = "def f(x)\n  x + 1\nend\nputs f(2)\n"
    assert_equal plain, C.transform(plain)
  end

  def test_native_method_name_predicate
    assert C.native_method_name?("__spnl_consume_int")
    assert C.native_method_name?("__spnl_consume_pair")
    assert C.native_method_name?("__spnl_consume_events")
    assert C.native_method_name?("__spnl_named_http_open")
    refute C.native_method_name?("produce")
  end

  # ---------- E242 #3: named emits ----------

  NAMED = <<~RUBY
    def kretprobe__x(r)
      emit :http_open, latency_end
      emit :tcp_send,  42
    end
    on_emit :http_open do |v|
      @h = @h + v
    end
    on_emit :tcp_send do |v|
      @t = @t + v
    end
    consume_events(0)
  RUBY

  def test_name_tag_stable_positive_distinct
    assert_equal C.name_tag("svc_a"), C.name_tag("svc_a")
    assert C.name_tag("svc_a").positive?
    assert C.name_tag("svc_a") < (1 << 31)
    refute_equal C.name_tag("svc_a"), C.name_tag("svc_b")
  end

  def test_named_detect
    assert_equal({ "http_open" => "v", "tcp_send" => "v" }, C.named(NAMED))
  end

  def test_named_transform_producer_and_consumer
    out = C.transform(NAMED)
    th = C.name_tag("http_open")
    tt = C.name_tag("tcp_send")
    # producer: emit :name, expr -> spnl_emit_pair(tag, (expr))
    assert_includes out, "spnl_emit_pair(#{th}, (latency_end))"
    assert_includes out, "spnl_emit_pair(#{tt}, (42))"
    # consumer: on_emit :name do |v| -> def + tagged dispatch
    assert_includes out, "def __spnl_named_http_open(v)"
    assert_includes out, "def __spnl_named_tcp_send(v)"
    assert_match(/__spnl_named_http_open\(v\) if tag == #{th}/, out)
    assert_match(/__spnl_named_tcp_send\(v\) if tag == #{tt}/, out)
    assert_includes out, "ffi_func :spnl_consume_count_pair, [], :int"
  end
  # ---- E371 (S4): typed record consumer -------------------------------------

  TYPED = <<~RUBY
    def kprobe__udp_sendmsg(sk, msg, len)
      emit_dns(msg)
      0
    end
    @ep = "http://127.0.0.1:4318"
    @sent = 0
    def interesting?(name)
      name.end_with?(".invalid")
    end
    on_emit :dns do |ev|
      next unless interesting?(ev.qname)   # ev.qname は comment 内でも触らない
      send_otlp(to_span(ev), @ep)
      @sent = @sent + 1
      puts ev.comm
    end
    loop do
      sleep 1
      st = consume_records(200)
    end
  RUBY

  # `on_emit :dns` は record channel id なので typed record 経路 (E242 named ではない)。
  def test_record_consumer_detected_by_channel_id
    assert_equal({ "dns" => "ev" }, C.record_consumers(TYPED))
    assert_empty C.record_consumers("on_emit :http_open do |v|\n  x\nend\n")   # 未知 id は named のまま
    assert C.present?(TYPED)
  end

  def test_record_block_becomes_a_method_and_next_becomes_return
    out = C.transform(TYPED)
    assert_includes out, "def __spnl_consume_rec_dns(ev)"
    # block -> method なので block-local な next は method-local な return に
    assert_includes out, "return 0 unless interesting?(SpnlRecDns.spnl_rec_dns_qname(ev))"
    refute_match(/^\s*next\b/, out)
  end

  def test_record_properties_lower_to_generated_accessors
    out = C.transform(TYPED)
    assert_includes out, "SpnlRecDns.spnl_rec_dns_qname(ev)"
    assert_includes out, "puts SpnlRecDns.spnl_rec_dns_comm(ev)"
    # to_span / send_otlp は callee 名の置換 (引数はそのまま = 入れ子でも壊れない)
    assert_includes out, "SpnlRecSink.spnl_otlp_span_send(SpnlRecDns.spnl_rec_dns_to_span(ev), @ep)"
  end

  # 型付きの意味: 宣言に無いプロパティは compile 時に落ちる (link error でも 0 でもない)。
  def test_unknown_property_is_a_loud_error_listing_the_real_set
    bad = "on_emit :dns do |ev|\n  puts ev.qnam\nend\n"
    e = assert_raises(SpinelEbpf::Consumer::Error) { C.transform(bad) }
    assert_match(/has no property `qnam`/, e.message)
    assert_match(/ev\.qname/, e.message)      # 正しい名前を名指しする
  end

  # 同名の receiver でなければ触らない (`req.pid` を record accessor にしない)。
  def test_only_the_handle_receiver_is_rewritten
    src = "on_emit :dns do |ev|\n  puts ev.pid\nend\nputs req.pid\n"
    out = C.transform(src)
    assert_includes out, "puts SpnlRecDns.spnl_rec_dns_pid(ev)"
    assert_includes out, "puts req.pid"
  end

  def test_record_driver_declares_ffi_from_the_declaration_and_flushes
    out = C.transform(TYPED)
    assert_includes out, "ffi_func :spnl_rec_dns_drain, [:int], :int"
    assert_includes out, "ffi_func :spnl_rec_dns_qname, [:int], :str"     # derived, :str
    assert_includes out, "ffi_func :spnl_rec_dns_cgid, [:int], :long"     # scalar, :long
    assert_includes out, "ffi_func :spnl_otlp_span_send, [:int, :str], :int"
    assert_includes out, "def __spnl_consume_records(t)"
    assert_includes out, "__spnl_consume_rec_dns(i0)"
    assert_includes out, "SpnlRecSink.spnl_otlp_span_flush"
    assert_includes out, "st = __spnl_consume_records(200)"
    # 生成メソッドは partition/codegen が native 強制する __spnl_ 名前空間に居ること
    assert C.native_method_name?("__spnl_consume_rec_dns")
    assert C.native_method_name?("__spnl_consume_records")
  end

  # 同名の E242 named event と typed consumer が同居したら、どちらか推測せず落とす。
  def test_ambiguous_named_event_and_record_channel_is_rejected
    src = "emit :dns, 1\non_emit :dns do |ev|\n  puts ev.pid\nend\n"
    e = assert_raises(SpinelEbpf::Consumer::Error) { C.transform(src) }
    assert_match(/named event of the same name/, e.message)
  end

  # 簡潔形 (既存 probe) は typed 経路に入らない = 1 文字も変わらない。
  def test_concise_probe_is_untouched
    src = File.read(File.expand_path("../../examples/observability/otlp/audit_dns.rb", __dir__))
    assert_equal src, C.transform(src)
  end

  # ---- E374 (ADR-017 D3): 多チャネルの `to_span` 解決 -------------------------
  #
  # `to_span` は層 1 の**汎用の口**のまま (channel ごとに名前を増やさない、ADR-014)。
  # どの channel かは **`on_emit :<ch>` ブロックのスコープ**から解く。同じ param 名
  # (`ev`) を 2 つの block が使ってもよい — block の中では曖昧でないから。

  MULTI = <<~RUBY
    def kprobe__udp_sendmsg(sk, msg, len)
      emit_dns(msg)
      0
    end
    def kprobe__tcp_sendmsg(sk, msg, size)
      http_req_start(sk, msg)
      0
    end
    @ep = "http://127.0.0.1:4318"
    on_emit :dns do |ev|
      next unless ev.qname.end_with?(".invalid")
      send_otlp(to_span(ev), @ep)
    end
    on_emit :http do |ev|
      next unless ev.status >= 500
      send_otlp(to_span(ev), @ep)
      puts ev.method + " " + ev.path
    end
    st = consume_records(200)
  RUBY

  def test_multi_channel_to_span_resolves_from_the_enclosing_block
    out = C.transform(MULTI)
    assert_equal({ "dns" => "ev", "http" => "ev" }, C.record_consumers(MULTI))
    # 同じ綴り `to_span(ev)` が block ごとに別 channel の builder に降りる
    assert_includes out, "SpnlRecSink.spnl_otlp_span_send(SpnlRecDns.spnl_rec_dns_to_span(ev), @ep)"
    assert_includes out, "SpnlRecSink.spnl_otlp_span_send(SpnlRecHttp.spnl_rec_http_to_span(ev), @ep)"
    # プロパティも block スコープで解決される (同名 param が衝突しない)
    assert_includes out, "SpnlRecDns.spnl_rec_dns_qname(ev)"
    assert_includes out, "SpnlRecHttp.spnl_rec_http_status(ev)"
    assert_includes out, "SpnlRecHttp.spnl_rec_http_method(ev)"
    assert_includes out, "SpnlRecHttp.spnl_rec_http_path(ev)"
    refute_includes out, "spnl_rec_dns_status", "http の block が dns の accessor に落ちた"
  end

  def test_multi_channel_driver_drains_every_channel_and_flushes_once
    out = C.transform(MULTI)
    assert_includes out, "ffi_func :spnl_rec_dns_drain, [:int], :int"
    assert_includes out, "ffi_func :spnl_rec_http_drain, [:int], :int"
    assert_includes out, "ffi_func :spnl_rec_http_status, [:int], :long"   # derived, int
    assert_includes out, "ffi_func :spnl_rec_http_method, [:int], :str"    # derived, str
    assert_includes out, "__spnl_consume_rec_dns(i0)"
    assert_includes out, "__spnl_consume_rec_http(i1)"
    assert_equal 1, out.scan("SpnlRecSink.spnl_otlp_span_flush").length, "flush は 1 サイクル 1 回"
  end

  # プロパティ集合も block ごと: dns の block で `ev.path` は dns の集合を名指して落ちる。
  def test_property_set_is_per_block
    bad = "on_emit :dns do |ev|\n  puts ev.path\nend\non_emit :http do |ev|\n  puts ev.path\nend\n"
    e = assert_raises(SpinelEbpf::Consumer::Error) { C.transform(bad) }
    assert_match(/the `dns` record has no property `path`/, e.message)
    assert_match(/ev\.qname/, e.message)
  end

  # 解決できないときは **推測しない** (ADR-017 D3-3)。行番号・理由・逃げ道を全部言う。
  def test_to_span_outside_any_block_is_a_loud_error
    src = "on_emit :dns do |ev|\n  puts ev.pid\nend\n" \
          "on_emit :http do |ev|\n  puts ev.pid\nend\n" \
          "def emit_it(x)\n  send_otlp(to_span(x), @ep)\nend\n"
    e = assert_raises(SpinelEbpf::Consumer::Error) { C.transform(src) }
    assert_match(/`to_span\(\.\.\.\)` \(line 8\)/, e.message)          # どこで
    assert_match(/outside every `on_emit :<channel>` block/, e.message) # なぜ
    assert_match(/dns_span\(ev\) \/ http_span\(ev\)/, e.message)        # どう書くか
    assert_match(/consumes 2 typed record channels \(dns, http\)/, e.message)
  end

  def test_to_span_on_a_copied_handle_inside_a_block_is_a_loud_error
    src = "on_emit :dns do |ev|\n  puts ev.pid\nend\n" \
          "on_emit :http do |ev|\n  keep = ev\n  send_otlp(to_span(keep), @ep)\nend\n"
    e = assert_raises(SpinelEbpf::Consumer::Error) { C.transform(src) }
    assert_match(/`to_span\(\.\.\.\)` \(line 6\)/, e.message)
    assert_match(/inside `on_emit :http`/, e.message)
    assert_match(/applied to something other than that block's own parameter `ev`/, e.message)
    assert_match(/http_span\(ev\)/, e.message)
  end

  # escape hatch (ADR-017 D3-4): channel を名指す明示形。**逃げ道であって主ではない**。
  def test_channel_span_escape_hatch_is_unambiguous_anywhere
    src = "on_emit :dns do |ev|\n  puts ev.pid\nend\n" \
          "on_emit :http do |ev|\n  keep = ev\n  send_otlp(http_span(keep), @ep)\nend\n" \
          "def send_dns(h)\n  send_otlp(dns_span(h), @ep)\nend\n"
    out = C.transform(src)
    assert_includes out, "SpnlRecSink.spnl_otlp_span_send(SpnlRecHttp.spnl_rec_http_to_span(keep), @ep)"
    assert_includes out, "SpnlRecSink.spnl_otlp_span_send(SpnlRecDns.spnl_rec_dns_to_span(h), @ep)"
  end

  # 消費していない channel の明示形は link error でなく compile error。
  def test_channel_span_for_an_unconsumed_channel_is_a_loud_error
    src = "on_emit :dns do |ev|\n  send_otlp(http_span(ev), @ep)\nend\n"
    e = assert_raises(SpinelEbpf::Consumer::Error) { C.transform(src) }
    assert_match(/`http_span\(\.\.\.\)` \(line 2\)/, e.message)
    assert_match(/no `on_emit :http do \|ev\| \.\.\. end` block/, e.message)
    assert_match(/`dns_span\(ev\)`/, e.message)
  end

  # 単一 channel は従来どおりどこでも解決する (E371 の書き方を壊さない)。
  def test_single_channel_still_resolves_outside_the_block
    src = "on_emit :dns do |ev|\n  emit_it(ev)\nend\n" \
          "def emit_it(x)\n  send_otlp(to_span(x), @ep)\nend\n"
    out = C.transform(src)
    assert_includes out, "SpnlRecSink.spnl_otlp_span_send(SpnlRecDns.spnl_rec_dns_to_span(x), @ep)"
  end

  # helper method に handle を渡す書き方 (E371) は単一 channel なら block 外でも解決する。
  def test_single_channel_handle_property_outside_the_block
    src = "on_emit :dns do |ev|\n  hot?(ev)\nend\ndef hot?(ev)\n  ev.duration_ns > 1000\nend\n"
    out = C.transform(src)
    assert_includes out, "SpnlRecDns.spnl_rec_dns_duration_ns(ev) > 1000"
  end

  # ---- E379: offcpu channel (「なぜ遅いか」で絞る) ---------------------------
  #
  # offcpu の `ev` は **フィールドそのままでない値**を 3 つ持つ (clamp / 差 / kallsyms 分類)。
  # Ruby からは普通のプロパティに見え、その値は span 属性と同値 (parity test が pin)。
  OFFCPU_TYPED = <<~RUBY
    def kprobe__tcp_sendmsg(sk, msg)
      offcpu_emit(sk, msg)
      0
    end
    @ep = "http://127.0.0.1:4318"
    on_emit :offcpu do |ev|
      next unless ev.offcpu_ns > 100000000
      send_otlp(to_span(ev), @ep)
      puts ev.method + " " + ev.path + " " + ev.wait_kind + " on=" + ev.oncpu_ns.to_s
    end
    st = consume_records(200)
  RUBY

  def test_offcpu_channel_is_a_typed_consumer
    assert_includes C.record_channel_ids, "offcpu"
    assert_equal({ "offcpu" => "ev" }, C.record_consumers(OFFCPU_TYPED))
    out = C.transform(OFFCPU_TYPED)
    assert_includes out, "def __spnl_consume_rec_offcpu(ev)"
    # clamp 後の off-CPU / 計算値 on-CPU / kallsyms 分類 — どれも生成 accessor に降りる
    assert_includes out, "SpnlRecOffcpu.spnl_rec_offcpu_offcpu_ns(ev) > 100000000"
    assert_includes out, "SpnlRecOffcpu.spnl_rec_offcpu_oncpu_ns(ev)"
    assert_includes out, "SpnlRecOffcpu.spnl_rec_offcpu_wait_kind(ev)"
    assert_includes out, "SpnlRecSink.spnl_otlp_span_send(SpnlRecOffcpu.spnl_rec_offcpu_to_span(ev), @ep)"
    assert_includes out, "ffi_func :spnl_rec_offcpu_drain, [:int], :int"
    assert_includes out, "ffi_func :spnl_rec_offcpu_wait_kind, [:int], :str"    # derived, str
    assert_includes out, "ffi_func :spnl_rec_offcpu_offcpu_ns, [:int], :long"   # derived, int
    assert_includes out, "__spnl_consume_rec_offcpu(i0)"
  end

  # 非公開の生フィールド (stack id / window anchor / 生ヘッダ) は名指しで落ちる。
  def test_offcpu_raw_fields_are_not_properties
    %w[wait_stack start_ktime hdr_ext].each do |f|
      e = assert_raises(SpinelEbpf::Consumer::Error) {
        C.transform("on_emit :offcpu do |ev|\n  puts ev.#{f}\nend\n")
      }
      assert_match(/the `offcpu` record has no property `#{f}`/, e.message)
      assert_match(/ev\.wait_kind/, e.message)   # 代わりに読むべきものを名指す
    end
  end

  # 簡潔形 (E300 の無変更 probe) は typed 経路に入らない = 1 文字も変わらない。
  def test_concise_offcpu_probe_is_untouched
    src = File.read(File.expand_path("../../examples/observability/otlp/audit_offcpu.rb", __dir__))
    assert_equal src, C.transform(src)
  end

  # 2 つの block が同じ param 名を使い、その名前を block の外でも読んだら曖昧 -> loud。
  def test_same_param_name_read_outside_both_blocks_is_a_loud_error
    src = "on_emit :dns do |ev|\n  puts ev.pid\nend\n" \
          "on_emit :http do |ev|\n  puts ev.pid\nend\n" \
          "def dump(ev)\n  puts ev.pid\nend\n"
    e = assert_raises(SpinelEbpf::Consumer::Error) { C.transform(src) }
    assert_match(/`ev\.pid` \(line 8\)/, e.message)
    assert_match(/block parameter of 2 typed consumers \(on_emit :dns, on_emit :http\)/, e.message)
    assert_match(/distinct parameter names/, e.message)
  end
end
