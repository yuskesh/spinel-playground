# frozen_string_literal: true
#
# E242 (4): `spinel-ebpf describe` — emit/consumer 内省。
#
# 「on_emit に何が emit されるか」は現状コードの約束(位置つき __s64、意味は
# emit 呼出の引数)でしか分からない。このモジュールはソースを走査して
# emit 元(kind/arity/呼出テキスト)と consumer(kind/block params)を突き合わせ、
# 対応・arity 不一致・producer/consumer 欠落を一覧化する(機械可読な代替)。
require_relative "consumer"
require_relative "capabilities"
require_relative "param"
require_relative "common_filter"
require_relative "keep_filter"

module SpinelEbpf
  module Introspect
    module_function

    # E314 (ADR-014 層1): scan source text for capability builtins and group the
    # hits by domain. Text-based (like emits/consumers), best-effort: drop trailing
    # comments per line, then whole-word match each registered builtin. The
    # lookbehind (?<![\w.]) keeps `path_eq` from matching inside `parent_path_eq`
    # (preceded by `_`) or a `sk.foo` receiver. Returns {domain => [builtin(sorted)]}.
    # E401: the multi-symbol `on` forms in this source.
    #
    # Text-scanned, like every other section of `describe` — the point of the
    # command is to answer questions about a file without building it, so it
    # never runs the codegen. The consequence is that the mechanism reported here
    # is what the codegen WOULD pick from the same two inputs (list length,
    # `via:`); SPNL_ATTACH_MULTI is a measurement knob and deliberately not
    # consulted, since describing an environment variable's effect on a file
    # would make the description depend on who is reading it.
    # E418: この源が書いている attach method のうち、d_path gate の SEC に当たるものを返す。
    # `fmod_ret` を先に見るのは `lsm`/`fentry` と接頭辞が衝突しないため順序が意味を持たないが、
    # 「最初に一致した接頭辞で切る」規則を明示しておく (将来 prefix が増えたときの事故防止)。
    DPATH_ATTACH_PREFIXES = %w[fmod_ret lsm fentry fexit].freeze

    def dpath_secs_used(source)
      source.scan(/^\s*def\s+([a-z_0-9]+)/).flatten.filter_map do |m|
        pre = DPATH_ATTACH_PREFIXES.find { |p| m.start_with?("#{p}__") }
        next nil unless pre

        sec = "#{pre}/#{m[(pre.length + 2)..]}"
        sec if SpinelEbpf::Capabilities::DPATH_HOOKS.key?(sec)
      end.uniq
    end

    def multi_attach_sets(source)
      source.scan(/^\s*on\s+:(\w+)\s*,\s*%w\[([^\]]*)\]([^\n]*)/).map do |kind, body, rest|
        via = rest[/via:\s*:(\w+)/, 1]
        { kind: kind, syms: body.split(/\s+/).reject(&:empty?), via: via }
      end
    end

    # E063/E412: the `def xdp_tail__<name>` of this unit, IN FILE ORDER -- which
    # is the slot order, because libbpf iterates programs in ELF section order
    # and the loader assigns slots as it iterates. Text-scanned like the rest of
    # `describe`; the reactor has no `on :xdp_tail` spelling, so the flat `def`
    # is the whole surface.
    # Comments are stripped first, and that is not cosmetic here: a commented-out
    # `def xdp_tail__<name>` is not compiled, so counting it would shift every
    # slot number in the table and the table would disagree with the codegen.
    # (Measured while writing this: the fixture's own header sentence contains
    # `tail_call_to(slot)` and was reported as a computed slot.)
    def tail_call_targets(source)
      strip_comments(source).scan(/^\s*def\s+(xdp_tail__\w+)/).flatten
    end

    # The literal slots this source jumps to. A computed slot is reported
    # separately -- it is exactly the case nothing can check.
    def tail_call_slots(source)
      strip_comments(source).scan(/(?<![\w.])tail_call_to\s*\(\s*(\d+)\s*\)/).flatten.map(&:to_i).uniq
    end

    def strip_comments(source)
      source.each_line.map { |l| l.chomp.sub(/#.*\z/, "") }.join("\n")
    end

    # E061/E414: the host -> kernel command channel, as this source spells it.
    # Comments stripped for the reason E412 measured (a header sentence that
    # merely MENTIONS a call would otherwise be read as code -- and the two
    # committed examples both mention `user_ringbuf_drain` in their headers).
    #
    # Three things are collected because three things can be wrong and only one
    # of them is a compile error:
    #   :cb     the callback (0 or 1; 2 is refused by the codegen)
    #   :drains the handlers that call user_ringbuf_drain -- how OFTEN commands
    #           are picked up, which is the author's choice and not checkable
    #   :push   whether anything in this file pushes (the FFI may live elsewhere,
    #           so its absence is a note, not an error)
    def user_ringbuf_facts(source)
      s = strip_comments(source)
      cb = s.scan(/^\s*def\s+user_ringbuf__(\w+)/).flatten.first
      cb ||= "cmd_handler" if s =~ /(?<![\w.])on\s+:user_cmd\b/
      drains = []
      cur = nil
      s.each_line do |l|
        cur = $1 if l =~ /^\s*def\s+(\w+)/
        cur = "on :#{$1}" if l =~ /^\s*on\s+:(\w+)/
        drains << (cur || "(top level)") if l =~ /(?<![\w.])user_ringbuf_drain\b/
      end
      { cb: cb, drains: drains.uniq,
        push: s.include?("sp_bpf_user_cmd_push") }
    end

    # E043/E413: the argument texts this source passes to `worker_select`, and
    # what they say about which REUSEPORT_SOCKARRAY slots can ever be picked.
    # Comments stripped for the reason E412 measured (a header sentence that
    # merely MENTIONS the call would otherwise be read as code).
    #
    # Two shapes are decidable and one is not:
    #   `worker_select(reuseport_hash % N)` (N literal) -> slots 0..N-1
    #   `worker_select(N)`                  (N literal) -> that one slot
    #   anything else                                   -> unknown
    # The point of printing it is that the OTHER end of the correspondence --
    # how many workers call sp_bpf_reuseport_register -- is a runtime fact the
    # codegen never learns, and a mismatch is silent in both directions.
    def worker_select_args(source)
      strip_comments(source)
        .scan(/(?<![\w.])worker_select\s*\(\s*([^)]*)\)/).flatten.map(&:strip)
    end

    # `arg` may be a local, because the dominant idiom is two lines:
    #   idx = reuseport_hash % 4
    #   worker_select(idx)
    # -- which is what BOTH the fixture and the public example write, so a
    # scanner that only understands the inlined form would answer "cannot tell"
    # for every real probe. One hop of resolution is done, and ONLY when the name
    # is assigned exactly once in the file: a reassigned local is a genuinely
    # open question and saying so is better than picking an assignment.
    # `resolved` is carried through to the output so the reader can see this was
    # read off the text, not computed by the codegen.
    def reuseport_reach(arg, source = nil)
      k = reuseport_reach_direct(arg)
      return k + [false] unless k[0] == :unknown
      return k + [false] unless source && arg =~ /\A[a-z_]\w*\z/
      asg = strip_comments(source).scan(/^\s*#{Regexp.escape(arg)}\s*=\s*(.+?)\s*$/).flatten
      return k + [false] unless asg.size == 1
      k2 = reuseport_reach_direct(asg[0])
      k2[0] == :unknown ? k + [false] : k2 + [true]
    end

    def reuseport_reach_direct(arg)
      if (m = arg.match(/\Areuseport_hash\s*%\s*(\d+)\z/))  then [:modulo, m[1].to_i]
      elsif arg =~ /\A\d+\z/                                 then [:literal, arg.to_i]
      else                                                          [:unknown, nil]
      end
    end

    # Does the probe's own userspace half do the two things nothing else can do
    # for it? Both are ordinary `ffi_func` calls in the same file, so a text scan
    # sees them -- and their ABSENCE is the difference between "the program picks
    # workers" and "the program is loaded and never fires" / "every pick falls
    # back to the kernel".
    def reuseport_userspace_calls(source)
      code = strip_comments(source)
      { register: code.include?("sp_bpf_reuseport_register"),
        attach:   code.include?("sp_bpf_reuseport_attach") }
    end

    # E419: chain/dot 綴り (`pkt.l4.proto` / `sk.snd_cwnd`) も **同じ builtin** なので
    # 同じ domain を出す。flat の走査は `(?<![\w.])` でドットの後ろを除外している
    # (`sk.foo` の receiver を builtin と誤読しないため) ので、sugar は原理的に
    # 1 個も hit しなかった — 推奨している綴りの方が `(none)` になっていた。
    # 綴りの対応は `Capabilities.sugar_builtin_aliases` が **surface_sugar から導出**
    # する (E408 の権威をそのまま使う = 2 つ目の表を作らない)。
    # コメントは先に落とす (E412: describe の text scan が本文の散文を読んでいた)。
    def builtin_domains(source)
      code = strip_comments(source)
      names = SpinelEbpf::Capabilities.all_builtins.select do |b|
        code =~ /(?<![\w.])#{Regexp.escape(b)}(?![\w])/
      end
      SpinelEbpf::Capabilities.domains_used(names | SpinelEbpf::Capabilities.sugar_alias_hits(code))
    end

    # E370 (S3): packed-record emit の呼出 site を行番号つきで拾う。
    # スカラ emit (EMITS) と違い、これらは **型付き record** を ringbuf に書く builtin
    # (emit_dns 等)。どの channel を書くかは capabilities の record 契約が持つ
    # (正本は src/codegen_c/record_schema.h、offset は生成器が計算)。
    # [{ line:, name:, channel: }]
    def record_emits(source)
      prods = SpinelEbpf::Capabilities.record_producers
      return [] if prods.empty?
      source.each_line.with_index(1).flat_map do |line, n|
        body = line.chomp.sub(/#.*\z/, "")
        prods.filter_map do |p|
          next unless body =~ /(?<![\w.])#{Regexp.escape(p)}\s*\(/
          ch = SpinelEbpf::Capabilities.record_channel_for(p)
          { line: n, name: p, channel: ch[:id] }
        end
      end
    end

    NAMED_EMIT_RE     = /\A\s*emit\s+:(\w+)\s*,\s*(.+?)\s*(?:#.*)?\z/.freeze
    NAMED_CONSUMER_RE = /\A\s*on_emit\s+:(\w+)\s+do\s*\|\s*(\w+)\s*\|/.freeze

    # [{ line:, name:, text: }] for `emit :NAME, expr` producer sites
    def named_emits(source)
      source.each_line.with_index(1).filter_map do |line, n|
        m = NAMED_EMIT_RE.match(line.chomp)
        m && { line: n, name: m[1], text: line.strip }
      end
    end

    # [{ line:, name:, param: }] for `on_emit :NAME do |v|` consumer sites.
    # E371 (S4): `on_emit :<record channel>` is a *typed record* consumer, not an
    # E242 named event — same syntax, different binding — so it is reported by
    # record_consumers below and excluded here (otherwise every typed consumer
    # draws a bogus "no matching emit :dns" warning).
    def named_consumers(source)
      ids = SpinelEbpf::Capabilities.typed_record_channel_ids   # E372: typed only
      source.each_line.with_index(1).filter_map do |line, n|
        m = NAMED_CONSUMER_RE.match(line.strip)
        m && !ids.include?(m[1]) && { line: n, name: m[1], param: m[2] }
      end
    end

    # E371 (S4): [{ line:, channel:, param:, props: [name,...] }] for
    # `on_emit :<channel> do |ev|` typed record consumers. `props` is which
    # declared properties the block actually reads (`ev.qname` -> "qname"),
    # scanned the same best-effort way as the rest of describe.
    #
    # E374: a program may consume several channels, and two blocks may even share
    # the parameter name (`ev`), so "which properties does this consumer read" is
    # scanned **inside the block** (indentation-delimited, the same boundary
    # Consumer#transform_record uses) instead of over the whole file. Scanning the
    # file would credit the dns consumer with `ev.status` from the http block.
    def record_consumers(source)
      chans = SpinelEbpf::Capabilities.typed_record_channel_ids   # E372: typed only
      return [] if chans.empty?
      lines = source.each_line.map { |l| l.chomp.sub(/#.*\z/, "") }
      sites = []
      cur = nil
      lines.each_with_index do |line, i|
        if (m = NAMED_CONSUMER_RE.match(line.strip)) && chans.include?(m[1])
          cur = { line: i + 1, channel: m[1], param: m[2], indent: line[/\A\s*/].length, body: +"" }
          sites << cur
          next
        end
        if cur
          if line =~ /\A\s{#{cur[:indent]}}end\s*\z/
            cur = nil
          else
            cur[:body] << line << "\n"
          end
        end
      end
      sites.each do |s|
        s[:props] = s[:body].scan(/(?<![\w.@:])#{Regexp.escape(s[:param])}\.(\w+)/).flatten.uniq.sort
        s.delete(:body)
        s.delete(:indent)
      end
      sites
    end

    # E397: この channel の型駆動プロパティ (`value_map` を持つもの) について、
    # 値の**閉じた集合**と、その名前がどこから来ているか (authority) を出す。
    # 「`spnl.conn.tcp_state` に何が入るのか」に、走らせずに答えられる面。
    # E400: この channel の record が metric にもなること、そして**その代金**。
    # metric の代金は値ではなく label で、cardinality を間違えても span は正しいまま・
    # exit 0 のまま・請求書だけが動く。だから describe には必ず「series の上限」と、
    # その上限が declaration のどこから来たかを出す。
    # push を書いていない probe には出さない (metric を出さない probe に metric の話を
    # させない) — その判定は呼び出し側ではなくここで持つ。
    def metric_lines(cid)
      c = SpinelEbpf::Capabilities.record_channel(cid)
      ms = c && Array(c[:metrics])
      return [] if ms.nil? || ms.empty?
      lines = []
      ms.each do |m|
        val = m[:value_from].to_s.empty? ? "records" : "#{m[:value_from]} [#{m[:value_unit]} -> #{m[:unit]}]"
        lines << format("    metric: %s (%s, unit %s, value %s)  series <= %d\n",
                        m[:name], m[:kind], m[:unit], val, m[:series_bound])
        Array(m[:labels]).each do |l|
          how = l[:bound_from] == "declared_set" ?
                "declared set (#{Array(l[:values]).length}) + #{l[:fallback].inspect}; " \
                "values outside the set fold into the fallback = **declared coarsening** (the span keeps the exact value)" :
                "value map `#{l[:value_map]}` is closed (no coarsening)"
          lines << format("      label %-26s <- ev.%-12s bound %-4d %s\n", l[:key], l[:from], l[:bound], how)
        end
        lines << format("      push: spnl_otlp_record_metrics_push(endpoint)%s\n",
                        m[:kind] == "histogram" ? "   buckets #{m[:bounds]}" : "")
      end
      lines
    end

    def value_map_lines(cid)
      props = SpinelEbpf::Capabilities.record_properties(cid).select { |p| p[:value_map] }
      return [] if props.empty?
      lines = []
      props.each do |p|
        m = SpinelEbpf::Capabilities.record_value_map(p[:value_map])
        next unless m
        names = Array(m[:values]).map { |v| "#{v[:value]}=#{v[:name]}" }
        lines << format("    values: ev.%s <- %s  (value map `%s`: %d values, otherwise \"%s\")\n",
                        p[:name], p[:source].to_s.sub(/\s*->.*\z/, ""), m[:id],
                        names.length, m[:unknown])
        names.each_slice(6) { |sl| lines << "      #{sl.join('  ')}\n" }
        lines << format("      authority: %s\n", m[:authority].to_s.split(/(?<=\.)\s/).first.to_s)
      end
      lines
    end

    # emit builtin -> { kind(consumer suffix), arity, consumer name }
    EMITS = {
      "spnl_emit_pair" => { kind: "_pair", arity: 2, consumer: "on_emit_pair" },
      "spnl_emit3"     => { kind: "3",     arity: 3, consumer: "on_emit3" },
      "spnl_emit4"     => { kind: "4",     arity: 4, consumer: "on_emit4" },
      "spnl_emit_str"  => { kind: "_str",  arity: 1, consumer: "on_emit_str" },
      "spnl_emit"      => { kind: "",      arity: 1, consumer: "on_emit" },
    }.freeze
    # longest first so spnl_emit_pair matches before spnl_emit
    EMIT_ORDER = EMITS.keys.sort_by { |k| -k.length }.freeze
    ON_EMIT_RE = /\Aon_emit(_pair|_str|3|4)?\s+do\s*\|([^|]*)\|/.freeze

    # [{ line:, name:, kind:, arity:, text: }]
    def emits(source)
      source.each_line.with_index(1).filter_map do |line, n|
        body = line.chomp.sub(/#.*\z/, "")  # drop trailing comment (naive; chomp so \z matches)
        name = EMIT_ORDER.find { |e| body =~ /(?<![\w.])#{Regexp.escape(e)}\s*\(/ }
        next unless name
        { line: n, name: name, kind: EMITS[name][:kind], arity: EMITS[name][:arity], text: line.strip }
      end
    end

    # [{ line:, kind:, consumer:, nparams: }]
    def consumers(source)
      source.each_line.with_index(1).filter_map do |line, n|
        m = ON_EMIT_RE.match(line.strip)
        next unless m
        suffix = m[1] || ""
        params = m[2].split(",").map(&:strip).reject(&:empty?)
        { line: n, kind: suffix, consumer: "on_emit#{suffix}", nparams: params.length, params: params }
      end
    end

    def kind_label(k)
      { "" => ":int", "_pair" => ":pair", "_str" => ":str", "3" => ":tuple3", "4" => ":tuple4" }[k] || k
    end

    # `# @intent` / `# @expect` — 作者が書いた意図。**検査しない。**
    #
    # 意図の一致は原理的に機械では見られない (計画の ③)。実測もある: 三つ組を 2 本ずつに
    # した audit probe は収支が `in 30 out 30` で完全に釣り合ったまま、span の
    # file.path の位置に comm が入っていた (results/E386/s5_all_channels.txt)。
    # 件数が合うことは、意味が合うことの証拠にならない。
    #
    # だからここは検査を足す場所ではなく、**突き合わせる材料を隣に置く**場所。
    # 読むのは人か LLM のまま。検査に見せてはいけない ―― 「@intent を書けば安全」と
    # 読まれるのが、この機能のいちばん危ない壊れ方。
    ANNOTATION_RE = /^\s*#\s*@(intent|expect)\b[:：]?\s*(.*)$/.freeze
    # 続き行は `#` の後を 4 空白以上下げる。字下げを条件にするのは、直後に来た普通の
    # コメントを黙って意図として吸い込まないため (作者が書いていないことを作者の意図と
    # して表示するのは、書いたものを落とすのと同じくらい悪い)。
    ANNOTATION_CONT_RE = /^\s*#\s{4,}(\S.*)$/.freeze

    def annotations(source)
      out  = []
      prev = -1   # 直前に取り込んだ行 (注釈本体 or その続き)。続きは隣接必須。
      source.each_line.with_index(1) do |ln, i|
        if (m = ANNOTATION_RE.match(ln))
          text = m[2].strip
          next if text.empty?
          out << { line: i, tag: m[1], text: text }
          prev = i
        elsif !out.empty? && i == prev + 1 && (c = ANNOTATION_CONT_RE.match(ln))
          out.last[:text] = "#{out.last[:text]} #{c[1].strip}"
          prev = i
        end
      end
      out
    end

    # Human-readable report (String). path is shown in the header.
    def report(source, path)
      es = emits(source)
      cs = consumers(source)
      out = +"spinel-ebpf describe: #{path}\n\n"

      out << "emit sites (kernel -> ringbuf):\n"
      out << "  (none)\n" if es.empty?
      es.each { |e| out << format("  L%-4d %-15s arity %d  %s  %s\n", e[:line], e[:name], e[:arity], kind_label(e[:kind]), e[:text]) }

      out << "\nconsumers (ringbuf -> Ruby):\n"
      out << "  (none)\n" if cs.empty?
      cs.each { |c| out << format("  L%-4d %-13s |%s|  %s\n", c[:line], c[:consumer], c[:params].join(", "), kind_label(c[:kind])) }

      out << "\nbinding (matched by kind; payload is positional __s64, meaning is the emit args):\n"
      kinds = (es.map { |e| e[:kind] } + cs.map { |c| c[:kind] }).uniq
      warnings = []
      kinds.each do |k|
        ek = es.select { |e| e[:kind] == k }
        ck = cs.select { |c| c[:kind] == k }
        prod = ek.map { |e| "#{e[:name]}@L#{e[:line]}" }.join(", ")
        cons = ck.map { |c| "#{c[:consumer]}@L#{c[:line]}" }.join(", ")
        mark = (!ek.empty? && !ck.empty?) ? "OK" : "!!"
        out << format("  %-7s producers[%s] -> consumers[%s]  %s\n", kind_label(k), prod, cons, mark)
        warnings << "#{kind_label(k)}: emit has no matching on_emit#{k}" if !ek.empty? && ck.empty?
        warnings << "#{kind_label(k)}: on_emit#{k} has no matching emit" if ek.empty? && !ck.empty?
        ck.each do |c|
          want = EMITS.values.find { |v| v[:kind] == k }&.dig(:arity)
          warnings << "L#{c[:line]} on_emit#{k}: #{c[:nparams]} block params != emit arity #{want}" if want && c[:nparams] != want
        end
        warnings << "#{kind_label(k)}: #{ek.length} emits of the same kind -> the consumer cannot tell them apart (no per-site tags)" if ek.length > 1 && !ck.empty?
      end

      # E242 #3: named events (emit :NAME / on_emit :NAME), bound by name+tag.
      ne = named_emits(source)
      nc = named_consumers(source)
      unless ne.empty? && nc.empty?
        out << "\nnamed events (E242 #3 — bound by name; tag in pair field-a):\n"
        names = (ne.map { |e| e[:name] } + nc.map { |c| c[:name] }).uniq
        tags = {}
        names.each do |nm|
          tag = SpinelEbpf::Consumer.name_tag(nm)
          ep = ne.select { |e| e[:name] == nm }
          cp = nc.select { |c| c[:name] == nm }
          prod = ep.map { |e| "emit@L#{e[:line]}" }.join(", ")
          cons = cp.map { |c| "on_emit@L#{c[:line]}" }.join(", ")
          mark = (!ep.empty? && !cp.empty?) ? "OK" : "!!"
          out << format("  :%-12s tag=%#x  producers[%s] -> consumers[%s]  %s\n", nm, tag, prod, cons, mark)
          warnings << ":#{nm}: emit has no matching on_emit :#{nm}" if !ep.empty? && cp.empty?
          warnings << ":#{nm}: on_emit :#{nm} has no matching emit" if ep.empty? && !cp.empty?
          (tags[tag] ||= []) << nm
        end
        tags.each_value { |ns| warnings << "tag collision: #{ns.map { |x| ":#{x}" }.join(', ')} share one tag" if ns.length > 1 }
      end

      # E370 (S3): packed-record channel — この probe が ringbuf に書く byte 像と、
      # それが最終的に何の span (どの semconv 属性) になるか。ここが「レビュー可能性」の
      # 実体で、生成 C を読まずに egress まで辿れる唯一の画面。
      res = record_emits(source)
      rcs = record_consumers(source)
      unless res.empty? && rcs.empty?
        out << "\nrecord channels (E368-E371 — the ringbuf byte image -> egress span):\n"
        # E433: the same layouts also ship INSIDE the .bpf.o. Printed here rather
        # than only in `capabilities` because this screen is where somebody
        # decides how to read the records, and the answer "do not retype them"
        # has to be next to the table they would otherwise retype from.
        rbtf = SpinelEbpf::Capabilities::RECORD_BTF
        out << format("  (the layouts below also ship in the .bpf.o's BTF — DATASEC %s, one Var\n" \
                      "   per channel — so a reader in another language generates its structs\n" \
                      "   rather than copying this table: %s)\n",
                      rbtf[:section], rbtf[:reader_recipe])
        (res.group_by { |r| r[:channel] }.keys | rcs.map { |c| c[:channel] }).each do |cid|
          sites = res.select { |r| r[:channel] == cid }
          c = SpinelEbpf::Capabilities.record_channel(cid)
          prod = sites.map { |s| "#{s[:name]}@L#{s[:line]}" }.join(", ")
          out << format("  %-5s %s (%d B, map %s) <- %s\n", cid, c[:record_struct], c[:record_bytes],
                        c[:ringbuf_map], prod.empty? ? "(no producer in this unit)" : prod)
          c[:fields].each do |f|
            type = f[:count].to_i > 0 ? "#{f[:ctype]}[#{f[:count]}]" : f[:ctype]
            out << format("    @%-4d %-14s %-22s %s\n", f[:offset], f[:name], type, f[:note])
          end
          # E371 (S4): 型付き consumer を書いているなら、その block が record の
          # **どのプロパティを読んでいるか**を出す (= Ruby 側に渡っている情報の一覧)。
          typed = rcs.select { |r| r[:channel] == cid }
          typed.each do |t|
            props = SpinelEbpf::Capabilities.record_properties(cid)
            out << format("    consumer: on_emit :%s do |%s|@L%d  (%s)\n", cid, t[:param], t[:line],
                          props.map { |p| "#{t[:param]}.#{p[:name]}" }.join(" "))
            used = Array(t[:props])
            out << format("      reads: %s\n",
                          used.empty? ? "(reads nothing yet)" : used.map { |p| "#{t[:param]}.#{p}" }.join(" "))
          end
          # E397: 型駆動 derived の**閉じた集合**。属性値に何が入りうるかは、ここに
          # 出さないと「probe を走らせて 1 個見る」以外に知る手が無い — `error=2` を
          # 読まされるのと同じ状態を、契約の側で作らないための行。
          value_map_lines(cid).each { |l| out << l }
          metric_lines(cid).each { |l| out << l }
          e = c[:egress]
          next unless e
          out << format("    egress: %s -> span \"%s\" (SpanKind %s)\n",
                        e[:push_fn], e[:span_name], e[:span_kind])
          # E434: the machine forms, not the prose. `describe` is what an author
          # (or an AI writing a probe) reads to know what leaves the process, and
          # "when is this attribute here" is a question a sentence answers worse
          # than a predicate does.
          out << Capabilities.record_timing_line(e)
          e[:attributes].each do |a|
            out << format("      %-24s %-8s <- %s  [%s]\n", a[:key], a[:stability], a[:source], a[:present])
          end
          unless Array(e[:enrichers]).empty?
            out << format("      + layer-2 enricher (env-gated, probe unchanged): %s\n", Array(e[:enrichers]).join(", "))
          end
          # E325 の bug class: kernel は record を貯めるだけ。userspace が drain を
          # 書かないと compile+verify は green でも span は 0 本。drain には 2 形式が
          # あり (E371/S4)、**どちらか一方**があればよい:
          #   簡潔形 = push FFI を呼ぶ / 明示形 = on_emit :<channel> で受ける。
          drained = source =~ /(?<![\w.])#{Regexp.escape(e[:push_fn])}(?![\w])/ || !typed.empty?
          unless drained
            warnings << "#{cid}: the source has neither #{e[:push_fn]} nor `on_emit :#{cid} do |ev|` to drain the records " \
                        "— no span is produced (E325)"
          end
          # 逆向きの穴 (S4): consumer を書いたのに producer が無い = drain しても 0 件。
          if sites.empty? && !typed.empty?
            warnings << "#{cid}: `on_emit :#{cid}` is present, but this unit has no builtin that writes the record " \
                        "(#{Array(c[:producers]).join(' / ')}) — no record flows"
          end
          # 明示形の E325: block を書いても `consume_records(t)` を呼ばなければ
          # drain ループが回らない (簡潔形で push を書き忘れるのと同じ穴)。
          if !typed.empty? && source !~ /(?<![\w.])consume_records\s*\(/
            warnings << "#{cid}: `on_emit :#{cid}` is present but consume_records(timeout_ms) is never " \
                        "called — the handler is never called and no span is produced (E325)"
          end
        end
      end

      # E401 (P011 S12): 1 定義 → 複数 attach。**どちらの下回りが選ばれたかを言う**
      # のがこの節の目的。body からは見えない (それが D1 の設計) が、
      # **配備からは見える** — kprobe_multi はカーネル下限を 5.18 に上げるので、
      # 「見えないなら書かなくてよい」ではなく「body に漏らさない代わりに
      # ここで名指しする」。index → シンボル名の対応表も出す: `attached_index`
      # を emit した probe の出力は、この表が無いと読めない。
      multis = multi_attach_sets(source)
      unless multis.empty?
        out << "\nmulti-symbol attach (E401 — 1 definition → several attaches):\n"
        multis.each do |m|
          picked = m[:via] || (m[:syms].length >= SpinelEbpf::Capabilities::ATTACH_MULTI_THRESHOLD ? "multi" : "expand")
          why = if m[:via]
                  "`via: :#{m[:via]}`, explicit"
                else
                  "auto (#{m[:syms].length} #{m[:syms].length >= SpinelEbpf::Capabilities::ATTACH_MULTI_THRESHOLD ? '>=' : '<'} " \
                  "threshold #{SpinelEbpf::Capabilities::ATTACH_MULTI_THRESHOLD})"
                end
          out << format("  on :%s, %d symbols  →  %s  (%s)\n", m[:kind], m[:syms].length, picked, why)
          if picked == "multi"
            out << "    one SEC(\"kprobe.multi\") + per-symbol cookie. " \
                   "**The kernel floor rises to 5.18** (it stays 5.2 when expanded) —\n" \
                   "    for environments that cannot raise it there is `via: :expand`.\n"
          else
            out << "    SEC(\"kprobe/<func>\") expanded into #{m[:syms].length} (N programs and N attach fds).\n"
          end
          out << "    attached_index mapping:\n"
          m[:syms].each_with_index { |s, i| out << format("      %-3d %s\n", i, s) }
        end
      end

      # E063/E412: tail-call dispatch. The slot numbers in `tail_call_to(N)` and
      # the declaration order of `def xdp_tail__<name>` are bound by NOTHING in
      # the source -- the loader (_spnl_prog_array_populate, E065) writes each
      # target into the slot matching its position in the file, and a jump into a
      # slot nobody filled does not fail: it falls through and the caller keeps
      # running. The codegen refuses a literal slot outside the range, but it
      # cannot see a literal that is in range and points at the WRONG target, so
      # the correspondence has to be readable somewhere. Here.
      targets = tail_call_targets(source)
      jumps   = tail_call_slots(source)
      # A COMPUTED slot has to open this section too. Measured while writing it:
      # gating on `targets + literal jumps` left `tail_call_to(n)` with no targets
      # printing nothing at all -- which is the one probe shape the codegen cannot
      # refuse (the slot is not a literal) and the one most in need of a warning.
      computed = strip_comments(source)
                 .scan(/(?<![\w.])tail_call_to\s*\(\s*([^)\s]+)\s*\)/).flatten
                 .reject { |a| a =~ /\A\d+\z/ }
      unless targets.empty? && jumps.empty? && computed.empty?
        out << "\ntail-call dispatch (E063/E412 — slot numbers follow declaration order):\n"
        if targets.empty?
          out << "  ⚠ `tail_call_to` is present but there is no `def xdp_tail__<name>` —\n"
          out << "    the jump table stays empty, so every jump falls through (silently).\n"
        else
          targets.each_with_index do |t, i|
            hit = jumps.include?(i)
            out << format("  slot %-3d %-30s %s\n", i, t,
                          hit ? "← tail_call_to(#{i})" :
                                "(nothing in this source jumps here — only another unit or a manual populate reaches it)")
          end
        end
        out << "  Reordering the targets or inserting one between them **shifts every number**.\n" \
               "  What happens then is not \"an error\" but \"jumps to another program / does not jump\", so\n" \
               "  matching this table against `tail_call_to(N)` is the only check.\n"
        unless computed.empty?
          out << format("  ⚠ %d computed slots (%s) — these cannot be range-checked at compile time.\n",
                        computed.size, computed.uniq.join(", "))
        end
      end

      # E061/E414: the host -> kernel command channel. What this section is for is
      # the pair of numbers that live in two files and that no gate compiles
      # together (the map name and the 8-byte record), plus the one design choice
      # the codegen deliberately does NOT make for the author: where the ring is
      # drained, which is what sets command latency.
      urb = user_ringbuf_facts(source)
      if urb[:cb] || !urb[:drains].empty?
        out << "\nhost → kernel command channel (E061/E414 — USER_RINGBUF):\n"
        out << format("  callback   user_ringbuf__%s(value)  ← 1 record = 1 call\n", urb[:cb]) if urb[:cb]
        if urb[:drains].empty?
          out << "  ⚠ no handler calls `user_ringbuf_drain` (codegen rejects this)\n"
        else
          out << format("  drained by %s\n", urb[:drains].join(" / "))
          out << "    ⇒ how **often** commands are picked up is exactly how often this hook fires.\n" \
                 "      Per packet for XDP, per call for a kprobe. It is not synthesized because this is a design choice.\n"
        end
        out << "  record     **fixed 8 bytes** (the callback reads sizeof(__s64) with bpf_dynptr_read)\n"
        out << "  sending    `module M ; ffi_func :sp_bpf_user_cmd_push, [:int64], :int ; end` →\n" \
               "             `M.sp_bpf_user_cmd_push(v)`  (0=ok / -2=no ring in this unit / -5=full)\n"
        out << "  ⚠ if your own pusher sends fewer than 8 bytes, **the callback fires and the count grows, but only the value is 0**\n" \
               "    (bpf_dynptr_read returns -E2BIG and gives up silently, E414 measured). A check that looks only at the count\n" \
               "    lets this failure through — E061 was right to look at both the count and the final value.\n"
        out << "  ⚠ **kernel floor 6.1**. If the value need not change while running, `param :name, default: N`\n" \
               "    (floor 5.2, set once before load and frozen after) is more portable.\n"
        unless urb[:push]
          out << "  ⚠ this source has no `sp_bpf_user_cmd_push` — if nobody pushes, the callback\n" \
                 "    never runs (drain just returns 0 records, and that is silent).\n" \
                 "    Ignore this if you push from another file or another process.\n"
        end
      end

      # E051-E054/E416: the pure-XDP TCP slice. This section exists for one fact
      # that has no other way of reaching the reader: **the method body is thrown
      # away**. Nothing downstream says so -- the compile succeeds, the program
      # loads, the slice works -- so an author who puts logic in that body watches
      # it have no effect with no diagnostic anywhere. It is the only attach kind
      # in the affordance with `body: :discarded`, and the reason `describe` names
      # the surprising thing first rather than the machinery.
      #
      # The rest is the hardcoded contract: the port, the path, and the fact that
      # userspace holds no socket -- which is what makes `strace` on this probe
      # show no data-plane syscalls (that is the M004 claim, E053).
      slices = source.scan(/^\s*def\s+(xdp__tcp_slice__\w+)/).flatten
      unless slices.empty?
        out << "\npure-XDP TCP slice (E051-E054/E057, M004):\n"
        slices.each { |m| out << format("  handler    %s   → SEC(\"xdp\"), its body is the one line spnl_tcp_slice_main(ctx)\n", m) }
        out << "  ⚠ **the body is not used** — what you write inside `def #{slices.first}` never appears\n" \
               "    in the generated C. It is a marker, not a handler, so logic written there\n" \
               "    **does nothing and gives no warning**. To write branches, use the other style: a plain `def xdp__<name>`\n" \
               "    that lines up the 7 builtins (tcp_synack_cookie / tcp_syncookie_check / payload_starts /\n" \
               "    tcp_reply_data …).\n"
        out << "  listens    **port 8080 fixed**, and answers **only `GET /health `** (as in E054)\n"
        out << "  reply      HTTP/1.0 200 OK / body \"OK\" sent back directly with XDP_TX\n"
        out << "  state      bpf_conntab (LRU_HASH 65536) holds seq/state per 4-tuple.\n" \
               "             Overflow is **not an error** — the oldest connection is evicted silently, and that connection\n" \
               "             stops being answered (= 65536 concurrent connections is the limit; the excess shows as a lower success rate)\n"
        out << "  observe    bpf_ts_counters (ARRAY 17) — `bpftool map dump name bpf_ts_counters`.\n" \
               "             It uses no ringbuf, so it is **outside the channel balance report**\n"
        out << "  ⚠ the kernel does not listen on this port. Userspace has no socket, so there is\n" \
               "    no accept, read or write (that is the M004 claim). Conversely, **stopping this probe\n" \
               "    leaves :8080 answered by nobody** — there is no userspace to fall back to.\n"
        out << "  ⚠ the attach target is env `SPNL_XDP_IFACE` (default lo). On an iface that already has an XDP program\n" \
               "    it does not replace it and fails with EBUSY (L004).\n"
      end

      # E043/E413: SO_REUSEPORT worker selection. Three facts this section exists
      # for, none of which the codegen can settle:
      #   1. how many slots the author's arithmetic can reach,
      #   2. whether anything registers a socket into those slots,
      #   3. whether anything attaches the program to a reuseport group at all.
      # (2) and (3) are refused by NOTHING on purpose: the FFI calls may live in
      # another file, and the affordance gate's own probe for `worker_select` is
      # a bare handler with no userspace half -- refusing would make an
      # advertised builtin fail its own gate (the same shape E412 reasoned from
      # backwards for lone tail-call targets).
      wsel = worker_select_args(source)
      unless wsel.empty?
        out << "\nSO_REUSEPORT worker selection (E043/E413 — userspace fills the slots):\n"
        wsel.each do |arg|
          kind, n, via = reuseport_reach(arg, source)
          hop = via ? " (from the only assignment to `#{arg}`)" : ""
          case kind
          when :modulo
            out << format("  worker_select(%s) → reaches the %d slots 0..%d%s\n", arg, n, n - 1, hop)
            out << format("    ⇒ call `sp_bpf_reuseport_register(listen_fd, i)` for **the %d values i = 0..%d**" \
                          ".\n", n, n - 1)
          when :literal
            out << format("  worker_select(%s) → fixed to **slot %d only**%s — it does not look at the hash, so\n",
                          arg, n, hop)
            out << "    every connection goes to the same worker (a pin, not load balancing)\n"
          else
            out << format("  worker_select(%s) → the slots reached are **not known at compile time** " \
                          "(a run-time value, assignments in several places, or a value from another unit)\n", arg)
          end
        end
        out << "  naming a slot that was not registered is **not an error** — the kernel silently falls back to\n" \
               "  the default 5-tuple spread. So with the wrong worker count, \"some connections follow BPF's\n" \
               "  choice and the kernel decides the rest\", and the output cannot tell them apart.\n"
        u = reuseport_userspace_calls(source)
        unless u[:attach]
          out << "  ⚠ this source has no `sp_bpf_reuseport_attach` — the prog is only loaded and\n" \
                 "    **never fires** (the probe itself creates the SO_REUSEPORT listen socket, so\n" \
                 "    the loader cannot attach it). Ignore this if another file calls it.\n"
        end
        unless u[:register]
          out << "  ⚠ this source has no `sp_bpf_reuseport_register` — every slot is empty, so\n" \
                 "    every `worker_select` falls back to the default spread (silently too).\n"
        end
      end

      # E314 (ADR-014 層1): which capability domains does this unit touch?
      doms = builtin_domains(source)
      out << "\ncapability domains (ADR-014 layer 1):\n"
      out << "  (none)\n" if doms.empty?
      doms.each do |dom, blts|
        out << format("  %-14s %s\n", dom, blts.join(" "))
        gated = blts.filter_map { |b| g = SpinelEbpf::Capabilities.gate_for(b); [b, g] if g }
        gated.each do |b, g|
          out << format("    ! %s is usable only in %s (E286 context gate)\n", b, g[:valid_secs].join(" | "))
        end
        # E418: gate を通ることは「発火する」ことを意味しない。**この probe が実際に
        # 書いている hook** について「何をすれば踏めるか」「戻り値が効くか」「落とし穴」を出す。
        # 32 本の一覧ではなくこの probe の hook だけを出すのは、利用者の問いが
        # 「書いたポリシーは発火するか」だから (E390 は truncate でまさにここを踏み外した)。
        unless gated.empty?
          secs = dpath_secs_used(source)
          secs.each do |sec|
            line = SpinelEbpf::Capabilities.dpath_fire_line(sec)
            out << format("    * %s\n", line) if line
          end
        end
        # E396: attach-kind で効く gate (bpf_d_path の SEC allowlist ではなく、
        # 「現タスクが event の主体である hook か」等)。SEC gate を持つ builtin は
        # 上の行で出ているので二重に出さない。
        blts.each do |b|
          next if SpinelEbpf::Capabilities.gate_for(b)
          next unless SpinelEbpf::Capabilities::CONTEXT_REQUIREMENTS[b]
          ctx = SpinelEbpf::Capabilities.context_strings(b)
          out << format("    ! %s is usable only in %s (codegen enforces it at compile time)\n", b, ctx.join(" ")) if ctx
        end
        # E395: 返り値の単位・バイト順。取り違えても静かに通る値だけがここに出る
        # (packed record の note を describe が印字するのと同じ役割を builtin に対して)。
        blts.each do |b|
          sem = SpinelEbpf::Capabilities.value_semantics_for(b)
          out << format("    = %s -> %s\n", b, sem) if sem
        end
      end

      # E392 (P011 S3): この probe が **再コンパイルなしで何を絞れるか**。
      # AI にとってここが一番実用的な行になる — probe を書き直す前に「同じ
      # バイナリを env で narrowing できるか」が読めるので、`param` を持つ probe に
      # 対して新しい .rb を生成する提案をしなくて済む。
      prms = SpinelEbpf::Param.scan_source(source)
      unless prms.empty?
        out << "\nruntime parameters (E392 — written to .rodata before load. No recompilation needed):\n"
        prms.each do |p|
          e = SpinelEbpf::Param::Entry.new(name: p[:name], default: p[:default])
          out << format("  L%-4d %-16s default %-8d %s\n", p[:line], p[:name], p[:default], e.env_name)
          unless SpinelEbpf::Param.referenced?(source, p[:name])
            warnings << "no handler reads param :#{p[:name]} — " \
                        "setting #{e.env_name} changes nothing (codegen refuses this at compile time)"
          end
        end
        out << "  ^ the value is fixed at load time (.rodata is frozen). Left at the default,\n"
        out << "    branches on it are folded by the verifier and **disappear** (changes while running go through E335's map).\n"
      end

      # E399 (P011 S10): 共通フィルタ。**ハンドラ本体を読んでも見えない**ので
      # (宣言 1 行が全ハンドラの先頭に注入される) 、describe に出すのが
      # 「暗黙の意味変更」への対価。読み手が最初に知りたいのは
      # 「この probe は何で絞れるか」でなく「絞られているのか」なので、
      # 宣言が無いときも 1 行だけ出す。
      fkeys = SpinelEbpf::CommonFilter.scan_source(source)
      handlers = source.scan(/^\s*def\s+([a-z_0-9]+__[A-Za-z_0-9]*)/).flatten
      out << "\nin-kernel common filter (E399 — one declaration line is injected at the top of every attach handler):\n"
      has_timer = source.match?(/^\s*on\s+:timer\b/)
      if fkeys.empty?
        out << "  (none) this probe is **not narrowed** — events from every process / every cgroup come out.\n"
        out << "         To narrow it, add `filter_by :pid, :comm` and so on at top level (keys: " \
               "#{SpinelEbpf::CommonFilter::KEYS.map(&:name).join(' ')}).\n"
        # E411: この probe に timer が居るなら、上の助言は**この源では通らない**。
        # bpf_timer callback は process context でないので E399 の gate が
        # 宣言ごと拒否する。describe が「書けない綴り」を勧めたままにしない。
        if has_timer
          out << "         ⚠ but **this probe has `on :timer`, so `filter_by` cannot be used** — \n"
          out << "           a timer callback does not know \"whose event\" it is, so E399's gate\n"
          out << "           rejects the whole declaration at compile time. To narrow it, move the timer to another probe,\n"
          out << "           or write it by hand in the handler with `param`.\n"
        end
      else
        fkeys.each do |f|
          known, unknown = f[:keys].partition { |k| SpinelEbpf::CommonFilter::KEYS_BY_NAME.key?(k) }
          out << format("  L%-4d filter_by %s\n", f[:line], f[:keys].map { |k| ":#{k}" }.join(", "))
          known.each do |k|
            e = SpinelEbpf::CommonFilter::KEYS_BY_NAME[k]
            out << format("        %-12s %-22s unset=%-4s %s\n",
                          k, e.env_name, e.unset.to_s.empty? ? '""' : e.unset.to_s, e.desc)
          end
          unless unknown.empty?
            warnings << "unknown filter_by keys #{unknown.map { |k| ":#{k}" }.join(' ')} — " \
                        "the usable ones are #{SpinelEbpf::CommonFilter::KEYS.map(&:name).join(' ')} " \
                        "(codegen refuses this at compile time)"
          end
        end
        out << "  ^ only events that match **every** set key remain (AND). Unset keys constrain nothing,\n"
        out << "    and the verifier folds their check away together with the helper call. Applied to these attach handlers:\n"
        out << (handlers.empty? ? "      (no attach handler found in this source)\n"
                                : "      #{handlers.join(' ')}\n")
      end

      # E398 (P011 S9): userspace の consumer filter。E399 の節が「kernel で絞られて
      # いるか」なら、こちらは「**drain した後で捨てているか**」。出す条件は
      # 「typed consumer があるか、宣言があるか」— consumer を持たない probe に
      # consumer の話をさせない。宣言が無いときに 1 行出すのは E399 と同じ理由で、
      # 読み手が最初に知りたいのは「何で絞れるか」でなく「絞られているのか」だから。
      keeps = SpinelEbpf::KeepFilter.scan_source(source)
      unless keeps.empty? && rcs.empty?
        out << "\nuserspace consumer filter (E398 — dropped after drain, before sending. The span content is unchanged):\n"
        if keeps.empty?
          ex = rcs.map { |r| r[:channel] }.uniq.first
          exp = ex && SpinelEbpf::KeepFilter.example_predicate(ex)
          out << "  (none) this consumer sends **every** record it drains.\n"
          if exp
            out << format("         To narrow it, add `keep_if :%s, %s: :%s` and so on at top level (property = ev.<name>, operators: %s).\n",
                          ex, exp[:prop], exp[:op], SpinelEbpf::KeepFilter::OPS.map(&:name).join(" "))
          end
        else
          keeps.each do |d|
            out << format("  L%-4d keep_if :%s, %s\n", d[:line], d[:channel],
                          d[:preds].map { |p| "#{p[:prop]}: :#{p[:op]}" }.join(", "))
            props = SpinelEbpf::Capabilities.record_properties(d[:channel])
            unless SpinelEbpf::Capabilities.typed_record_channel_ids.include?(d[:channel])
              warnings << "keep_if :#{d[:channel]} — a channel that publishes no typed consumer " \
                          "(codegen refuses this at compile time)"
              next
            end
            # 宣言はあるが consumer が無い = 何にも繋がっていないフィルタ。
            # compile は落とすが、describe は compile しない source にも使うので
            # ここでも言う (E325 の「書いたのに一度も呼ばれない」と同型の穴)。
            if rcs.none? { |r| r[:channel] == d[:channel] }
              warnings << "keep_if :#{d[:channel]} is present but there is no `on_emit :#{d[:channel]} do |ev|` " \
                          "— nothing is drained, so it narrows nothing (codegen refuses this at compile time)"
            end
            d[:preds].each do |pr|
              p = props.find { |x| x[:name].to_s == pr[:prop] }
              unless p
                warnings << "keep_if :#{d[:channel]} unknown property `#{pr[:prop]}` — " \
                            "the usable ones are #{props.map { |x| x[:name] }.join(' ')} (codegen refuses this at compile time)"
                next
              end
              op = SpinelEbpf::KeepFilter.op(pr[:op])
              unless op && op.types.include?(p[:expose].to_s)
                warnings << "keep_if :#{d[:channel]}, #{pr[:prop]}: :#{pr[:op]} — " \
                            "an operator not usable on a #{p[:expose]} property (codegen refuses this at compile time)"
                next
              end
              where = SpinelEbpf::KeepFilter.placement(d[:channel], pr[:prop], pr[:op])
              out << format("        %-16s %-26s %-9s unset=pass\n",
                            pr[:prop], SpinelEbpf::KeepFilter.env_name(d[:channel], pr[:prop]), op.name)
              out << format("          %s\n", SpinelEbpf::KeepFilter::PLACEMENT_NOTE[where])
            end
            unless d[:bad].empty?
              warnings << "keep_if :#{d[:channel]} non-predicate elements #{d[:bad].map(&:inspect).join(' ')} " \
                          "(codegen refuses this at compile time)"
            end
          end
          out << "  ^ only records that match **every** set predicate become spans (AND — the same rule as E399).\n"
          out << "    What is dropped is the record, not span content: the span of a record that passes\n"
          out << "    is as declared, not one byte changed (ADR-017 D2 — the egress declaration is authoritative).\n"
        end
        out << "  * \"stop after the first K\" is **a different thing** = SPNL_MAX_EVENTS (E323). keep_if\n"
        out << "    changes only \"which ones are sent\", not a count limit; setting both gives\n"
        out << "    \"the first K that pass the filter\". Top N (sort/top-N) is not implemented.\n"
      end

      # S4: 作者の意図を、実際に出る属性の**隣**に置く。突き合わせるのは人の仕事のまま。
      anns = annotations(source)
      out << "\nstated intent (material to compare against. **not checked**):\n"
      if anns.empty?
        out << "  (none) writing `# @intent <what does this probe record>` and\n"
        out << "         `# @expect <what should come out, in one line>` lets you\n"
        out << "         read them next to the egress attributes above. They are not checked.\n"
      else
        anns.each { |a| out << format("  L%-4d @%-6s %s\n", a[:line], a[:tag], a[:text]) }
        out << "  ^ compare them with the egress attributes of the record channels above.\n"
        out << "    A matching count is no evidence of a matching meaning — a probe whose triple\n"
        out << "    was off put comm into file.path while its balance stayed in==out.\n"
      end

      out << "\nwarnings:\n"
      out << "  (none)\n" if warnings.empty?
      warnings.each { |w| out << "  - #{w}\n" }
      out
    end
  end
end
