# frozen_string_literal: true
#
# E154 (P013 Task 7): 現行 C backend と MLIR backend の **意味**を突き合わせる。
#
# ELF のバイト一致は要求しない。比較するのは宣言された意味:
# program 名 / kind / attach / verdict、map symbol / kind / key / value /
# max_entries、record symbol / size / field offset、ring buffer 名。
#
# **正典は schema であって SPINEL-IR text ではない。** 現行側の読み取りは
# 生成された .bpf.c から行うが、これは「現行 backend が実際に何を宣言したか」を
# 読むためであって、.bpf.c を正典にするためではない。
require "json"
require "set"

module SpinelEbpf
  module MlirShadow
    # shadow 側が動かなかったことを **成功扱いにしない**ための例外。
    class ShadowError < StandardError; end
    # 解析できない意味 (非定数 verdict 等) は「差」ではなく **停止**として扱う。
    class Unsupported < StandardError; end

    # --- C の型 -> バイト数 / alignment (自然アライン) ---------------------------
    #
    # ここは **モデル**である。実物の compiler と食い違わないことは
    # test_mlir_shadow.rb の較正テストが clang の BTF に対して確かめる。
    SCALARS = {
      "__u8" => 1, "__s8" => 1, "char" => 1,
      "__u16" => 2, "__s16" => 2,
      "__u32" => 4, "__s32" => 4, "int" => 4,
      "__u64" => 8, "__s64" => 8, "long long" => 8,
    }.freeze

    # **どの attach 種別が enforcement verdict を持つか。**
    #
    # これは我々が決めることではない — codegen 自身の宣言表 (CcAttachDecl.verdict、
    # 「wrapper propagates the inner's int return」) が正典で、その機械可読 mirror が
    # attach_schema_gen.json である。ここはそれを読むだけ。
    #
    # tracepoint の `return 0` は **enforcement verdict ではなく単なる戻り値**なので、
    # XDP_PASS と同じ意味カテゴリに入れない (Mac の判断 2026-08-25)。
    ATTACH_SCHEMA = File.expand_path("attach_schema_gen.json", __dir__)

    def self.attach_rows
      @attach_rows ||= JSON.parse(File.read(ATTACH_SCHEMA))
    rescue Errno::ENOENT
      raise Unsupported, "the attach declaration table is not readable: #{ATTACH_SCHEMA}"
    end

    def self.verdict_kinds
      @verdict_kinds ||= attach_rows.select { |r| r["verdict"] }.map { |r| r["kind"] }.to_set
    end

    # --- SEC 文字列 -> 宣言表の行 ------------------------------------------------
    #
    # **先頭勝ちで 1 行に決めない。** 同じ sec を持つ行は実在する
    # (`xdp` は xdp / xdp_tail / xdp_tcp_slice の 3 行、`struct_ops/<member>` は
    # tcp_cc / sched_ext / qdisc の 3 行)。`rows.find` で先頭を採ると
    # kind_of_sec("xdp") が "xdp_tail" を返し、**将来 verdict の違う行が同じ sec に
    # 足されたとき黙って誤分類する** (Mac の指摘 2026-08-25)。
    #
    # 候補は全件集め、必要な属性についてだけ合意を要求する。
    def self.rows_for_sec(sec)
      exact = attach_rows.select { |r| r["sec"] == sec }
      return exact unless exact.empty?
      # SEC は宣言表では `tracepoint/<rest>` のように可変部を持つ。頭で引く。
      head = sec.split("/").first
      attach_rows.select { |r| (r["sec"] || "").split("/").first == head }
    end

    # 候補群から 1 つの属性を取り出す。
    #   0 件            -> Unsupported (知らない SEC を既定値へ倒さない)
    #   1 件            -> 採用
    #   複数で全一致    -> その値を採用 (属性が一致していれば曖昧でない)
    #   複数で不一致    -> ambiguous として停止
    def self.attach_attr(sec, attr)
      rows = rows_for_sec(sec)
      if rows.empty?
        raise Unsupported,
              "SEC not in the attach declaration table: #{sec.inspect} — an unknown attach does not fall back to a default."
      end
      vals = rows.map { |r| r[attr] }.uniq
      return vals.first if vals.size == 1
      raise Unsupported,
            "#{attr} cannot be determined uniquely from SEC #{sec.inspect} (ambiguous): " \
            "#{rows.map { |r| "#{r["kind"]}=#{r[attr].inspect}" }.join(" / ")}. " \
            "The first match does not win."
    end

    # その SEC が enforcement verdict を持つか。候補全件が合意しているときだけ答える。
    def self.sec_has_verdict?(sec)
      attach_attr(sec, "verdict") ? true : false
    end

    # **宣言表の kname と SEC の組が実在するか。** decl_kind は SEC から逆引き
    # できるとは限らない (16/34 で kname != SEC 頭) ので、backend 間で突き合わせる
    # のではなく「その組が宣言表にある」ことを検査する (Mac の指示 2026-08-25)。
    def self.decl_kind_pair_exists?(decl_kind, sec)
      attach_rows.any? do |r|
        next false unless r["kind"] == decl_kind
        r["sec"] == sec || (r["sec"] || "").split("/").first == sec.split("/").first
      end
    end

    # spinel の共通ヘッダ (include/spnl/types.h)。record の先頭に必ず居る。
    HDR = { name: "spnl_event_hdr", size: 16, align: 8 }.freeze

    def self.size_align_of(ctype, known_records)
      return [SCALARS[ctype], [SCALARS[ctype], 8].min] if SCALARS.key?(ctype)
      if ctype == "struct #{HDR[:name]}"
        return [HDR[:size], HDR[:align]]
      end
      if (r = known_records[ctype.sub(/\Astruct /, "")])
        return [r[:size], r[:align]]
      end
      if ctype =~ /\A(.+?)\s*\[(\d+)\]\z/
        elem, n = Regexp.last_match(1).strip, Regexp.last_match(2).to_i
        es, ea = size_align_of(elem, known_records)
        raise Unsupported, "unknown array element type: #{elem}" unless es
        return [es * n, ea]
      end
      [nil, nil]
    end

    # --- 現行 backend (.bpf.c) から意味を読む -----------------------------------
    def self.meaning_of_bpf_c(text)
      {
        programs: parse_programs(text),
        maps:     parse_maps(text),
        records:  parse_records(text),
        ringbufs: parse_maps(text).select { |m| m[:kind] == "ringbuf" }.map { |m| m[:symbol] },
      }
    end

    MAP_TYPES = {
      "BPF_MAP_TYPE_HASH" => "hash",
      "BPF_MAP_TYPE_ARRAY" => "array",
      "BPF_MAP_TYPE_PERCPU_ARRAY" => "percpu_array",
      "BPF_MAP_TYPE_RINGBUF" => "ringbuf",
      "BPF_MAP_TYPE_LRU_HASH" => "lru_hash",
    }.freeze

    def self.parse_maps(text)
      maps = []
      text.scan(/struct\s*\{(.*?)\}\s*(\w+)\s*SEC\("\.maps"\);/m) do |body, sym|
        raw = body[/__uint\(type,\s*(\w+)\)/, 1]
        kind = MAP_TYPES[raw] or raise Unsupported, "unknown map type: #{raw.inspect} (#{sym})"
        # key/value は __type(...) と __uint(key_size, sizeof(...)) の 2 形がある。
        key   = body[/__type\(key,\s*([^)]+)\)/, 1]&.strip ||
                body[/__uint\(key_size,\s*sizeof\(([^)]+)\)\)/, 1]&.strip
        value = body[/__type\(value,\s*([^)]+)\)/, 1]&.strip ||
                body[/__uint\(value_size,\s*sizeof\(([^)]+)\)\)/, 1]&.strip
        me = body[/__uint\(max_entries,\s*([^)]+)\)/, 1]&.strip
        maps << {
          symbol: sym, kind: kind, key: key, value: value,
          max_entries: eval_int(me, sym),
        }
      end
      maps.sort_by { |m| m[:symbol] }
    end

    # `256 * 1024` のような C の定数式を数にする。**解けない形は停止**する。
    def self.eval_int(expr, where)
      return nil if expr.nil?
      s = expr.strip
      return s.to_i if s =~ /\A\d+\z/
      return Regexp.last_match(1).to_i * Regexp.last_match(2).to_i if s =~ /\A(\d+)\s*\*\s*(\d+)\z/
      raise Unsupported, "max_entries cannot be made a number: #{expr.inspect} (#{where})"
    end

    # **layout モデルは 1 つだけ持つ。**
    #
    # 現行側 (.bpf.c を読む) と MLIR 側 (manifest を読む) が別々に offset を
    # 計算すると、両方同じように間違っていても緑に見える。両側ともここを通し、
    # このモデル自体を test_record_layout_matches_clang が実物の clang に対して
    # 較正する。
    #
    # fields は [{ name:, ctype: }] の順序つき配列。known は既出 record の表
    # (入れ子 struct の解決に使う) で、呼び出し側が跨いで持ち回る。
    def self.layout_record(symbol, fields, known)
      offset = 0
      maxalign = 1
      laid = fields.map do |f|
        size, align = size_align_of(f[:ctype], known)
        unless size
          raise Unsupported, "unknown type of field #{f[:name]} of record #{symbol}: #{f[:ctype]}"
        end
        offset = ((offset + align - 1) / align) * align
        at = offset
        offset += size
        maxalign = [maxalign, align].max
        { name: f[:name], ctype: f[:ctype], offset: at, size: size }
      end
      size = ((offset + maxalign - 1) / maxalign) * maxalign
      rec = { symbol: symbol, size: size, align: maxalign, fields: laid }
      known[symbol] = rec
      rec
    end

    # record = ring buffer に流す struct。先頭が spnl_event_hdr のものを拾う。
    def self.parse_records(text)
      known = {}
      out = []
      text.scan(/struct\s+(\w+)\s*\{(.*?)\n\};/m) do |name, body|
        next unless body.include?("struct spnl_event_hdr")
        fields = []
        body.scan(/^\s+([\w ]+?(?:\s*\[\d+\])?)\s+(\w+)\s*;/) do |ctype, fname|
          fields << { name: fname, ctype: ctype.strip }
        end
        out << layout_record(name, fields, known)
      end
      out.sort_by { |r| r[:symbol] }
    end

    # program = SEC("...") の直後に来る entry wrapper。
    # verdict は inner の末尾 return が既知定数のときだけ数にする
    # (E154 の対象は「末尾が既知定数を返す垂直スライス」。それ以外は
    #  :dynamic / :unknown として **明示**する — 既定値へ黙って倒さない)。
    def self.parse_programs(text)
      progs = []
      text.scan(/SEC\("([^"]+)"\)\n(?:int|__s64|__u64)\s+(\w+)\s*\(/) do |sec, name|
        next if sec == "license"
        # **enforcement verdict を持つ種別だけ verdict を記録する。**
        # 観測型 (tracepoint / kprobe ...) の戻り値は verdict ではないので nil。
        # 候補が合意しない SEC は ambiguous として停止する (先頭勝ちにしない)。
        has = sec_has_verdict?(sec)
        progs << {
          name: name,
          # **section_kind は SEC 文字列の頭であって宣言表の kind ではない。**
          # 名前で区別する (Mac の指示 2026-08-25) — 以前は両方 :kind と呼んでいた。
          section_kind: sec.split("/").first,
          attach: sec,
          verdict: has ? verdict_of(text, name) : nil,
        }
      end
      progs.sort_by { |p| p[:name] }
    end

    def self.verdict_of(text, entry)
      inner = text[/static\s+__noinline\s+\S+\s+#{Regexp.escape(entry)}_inner\s*\([^)]*\)\s*\n\{(.*?)\n\}/m, 1]
      return :unknown if inner.nil?
      tail = inner.scan(/return\s+([^;]+);/).flatten.last
      return :unknown if tail.nil?
      t = tail.strip
      return t.to_i if t =~ /\A-?\d+\z/
      :dynamic
    end

    # **unsupported がある manifest は shadow を成功扱いにしない。**
    # 「対象外だから比較しなかった」を緑にすると、欠落検出の意味が無くなる。
    def self.require_fully_registered(manifest, where)
      blocking = manifest["unsupported"] || []
      return if blocking.empty?
      raise Unsupported,
            "#{where}: some declarations are not registered in the manifest — the shadow does not count as a success:\n" +
            blocking.map { |x| "  - #{x}" }.join("\n")
    end

    # --- MLIR backend 側 (checkpoint 2: 宣言 manifest) ----------------------------
    #
    # **ここは宣言 manifest から意味を組む経路** (checkpoint 2 の差動)。
    # 突き合わせ先は meaning_of_bpf_c、つまり生成された .bpf.c の本文で、
    # 「宣言」と「emit」の乖離を捕まえる。record / field offset はこちらが覆う。
    #
    # 実際に MLIR を通して object 同士を比べるのは **checkpoint 3** で、
    # そちらは MlirBackend.both_meanings / test_mlir_object_shadow.rb が持つ。
    # 2 つは独立した gate であって、片方が他方を含むわけではない。
    #
    # require を method 内で行うのは、mlir_backend が此方を require し返すため。
    # 呼ばれる時点では此方の読み込みは終わっているので循環しない。
    def self.meaning_of_mlir(ir, ast, base)
      require "spinel_ebpf/mlir_backend"
      MlirBackend.manifest_meaning(ir, ast, base)
    end

    # --- 比較器 ------------------------------------------------------------------
    #
    # 返すのは差の一覧。**解析できない意味 (:unknown) は差ではなく停止**である。
    # records:
    #   :strict       — 両側が record を完全に運ぶチャネル (checkpoint 2:
    #                   manifest vs .bpf.c 本文)。片側欠落は差。
    #   :carried_only — object vs object (checkpoint 3)。**現行 object の BTF は
    #                   record を運ばないことがある** (witness の無い channel は
    #                   参照されていても struct が BTF に載らない — 実測)。運んで
    #                   いる record 同士だけ厳密比較し、片側だけの record は
    #                   ここでは差にしない。**黙認ではない**: MLIR object の
    #                   record は MlirBackend.record_witness_diff が宣言 manifest
    #                   と厳密照合する (manifest vs .bpf.c は checkpoint 2 が
    #                   照合済みなので、輪は閉じている)。
    def self.diff(current, mlir, records: :strict)
      out = []
      cmp_programs(current[:programs], mlir[:programs], out)
      cmp_maps(current[:maps], mlir[:maps], out)
      cmp_records(current[:records], mlir[:records], out, mode: records)
      unless current[:ringbufs].sort == mlir[:ringbufs].sort
        out << { what: "ringbufs", current: current[:ringbufs], mlir: mlir[:ringbufs] }
      end
      out
    end

    def self.cmp_programs(a, b, out)
      names = (a.map { |p| p[:name] } | b.map { |p| p[:name] }).sort
      names.each do |n|
        pa = a.find { |p| p[:name] == n }
        pb = b.find { |p| p[:name] == n }
        if pa.nil? || pb.nil?
          out << { what: "presence of program #{n}", current: !pa.nil?, mlir: !pb.nil? }
          next
        end
        # attach = 実際の SEC 文字列。section_kind = その頭。両方 backend 間で比較する。
        # decl_kind (宣言表の kname) は SEC から一意に逆引きできないので**比較しない** —
        # 代わりに [decl_kind, attach] の組が宣言表に在ることを検査する (下)。
        %i[section_kind attach].each do |k|
          out << { what: "#{k} of program #{n}", current: pa[k], mlir: pb[k] } if pa[k] != pb[k]
        end
        if pb.key?(:decl_kind) && !pb[:decl_kind].nil?
          unless decl_kind_pair_exists?(pb[:decl_kind], pb[:attach])
            out << { what: "the pair of decl_kind and attach of program #{n} is not in the declaration table",
                     current: "(declaration table: #{pb[:attach]})", mlir: pb[:decl_kind] }
          end
        end
        cmp_effects(n, pa, pb, out)
        # verdict を持たない種別 (観測型) は比較しない。
        next if pa[:verdict].nil? && pb[:verdict].nil?
        if pa[:verdict].nil? != pb[:verdict].nil?
          out << { what: "whether program #{n} has a verdict", current: !pa[:verdict].nil?, mlir: !pb[:verdict].nil? }
          next
        end
        # :dynamic / :unknown の分類は **verdict を持つ種別にだけ**適用する。
        #
        # E154 の規則 (Mac の判断 2026-08-25):
        #   known 同士      -> 値を比較
        #   none 同士       -> 比較不要 (上で return 済み)
        #   none と それ以外 -> attach 意味の差として報告 (上で return 済み)
        #   unknown が片側  -> 停止
        #   dynamic が片側  -> 停止
        if pa[:verdict] == :unknown || pb[:verdict] == :unknown
          raise Unsupported,
                "cannot attribute the verdict of program #{n} (current=#{pa[:verdict]} " \
                "mlir=#{pb[:verdict]}). E154 covers only forms that end by returning a known constant — " \
                "unknown is neither treated as a semantic difference nor turned into a default."
        end
        # **dynamic 同士を一致扱いにしない。** 両方が「非定数」というだけでは、
        # 同じ条件・同じ到達可能 verdict 集合を持つ証明にならない — 別の分岐で
        # 別の値を返す 2 つの program も等しく :dynamic になる。到達可能 verdict
        # 集合や条件式を schema で表現できた段階で比較を拡張する。
        if pa[:verdict] == :dynamic || pb[:verdict] == :dynamic
          raise Unsupported,
                "the verdict of program #{n} is not constant (current=#{pa[:verdict]} " \
                "mlir=#{pb[:verdict]}). Two dynamic verdicts do not prove a match either, so " \
                "E154 stops here — it covers only the vertical slice of constant verdicts."
        end
        if pa[:verdict] != pb[:verdict]
          out << { what: "verdict of program #{n}", current: pa[:verdict], mlir: pb[:verdict] }
        end
      end
    end

    # map effect (helper 呼び出し列 + 宣言済み map への参照回数) の比較 (E154
    # checkpoint 3)。object 由来の意味だけが :effects を持つ:
    #   両側に無い       -> 比較しない (manifest 差動 = checkpoint 2 の経路)
    #   片側にだけある   -> 別チャネルの意味を混ぜている — 比較の組み立てが誤り
    #   :unknown が片側  -> 停止 (帰属できないものを一致とも差とも呼ばない)
    #   両側 known       -> 値を比較
    def self.cmp_effects(n, pa, pb, out)
      return if !pa.key?(:effects) && !pb.key?(:effects)
      if pa.key?(:effects) != pb.key?(:effects)
        raise ShadowError,
              "program #{n}: tried to compare semantics where only one side has map effects — " \
              "semantics from the object and from the manifest are separate channels and are not compared mixed."
      end
      if pa[:effects] == :unknown || pb[:effects] == :unknown
        raise Unsupported,
              "cannot attribute the map effects of program #{n} (current=#{pa[:effects].inspect} " \
              "mlir=#{pb[:effects].inspect}). What could not be read is not treated as a match."
      end
      if pa[:effects][:helpers] != pb[:effects][:helpers]
        out << { what: "helper call sequence of program #{n}",
                 current: pa[:effects][:helpers], mlir: pb[:effects][:helpers] }
      end
      if pa[:effects][:map_refs] != pb[:effects][:map_refs]
        out << { what: "map references of program #{n}",
                 current: pa[:effects][:map_refs], mlir: pb[:effects][:map_refs] }
      end
    end

    def self.byte_width(v)
      case v
      when /\Abytes:(\d+)\z/ then Regexp.last_match(1).to_i
      when /\A[su](\d+)\z/    then Regexp.last_match(1).to_i / 8
      end
    end

    def self.cmp_maps(a, b, out)
      syms = (a.map { |m| m[:symbol] } | b.map { |m| m[:symbol] }).sort
      syms.each do |s|
        ma = a.find { |m| m[:symbol] == s }
        mb = b.find { |m| m[:symbol] == s }
        if ma.nil? || mb.nil?
          out << { what: "presence of map #{s}", current: !ma.nil?, mlir: !mb.nil? }
          next
        end
        %i[kind max_entries].each do |k|
          out << { what: "#{k} of map #{s}", current: ma[k], mlir: mb[k] } if ma[k] != mb[k]
        end
        %i[key value].each do |k|
          next if ma[k] == mb[k]
          # `__uint(key_size, N)` 宣言 (bytes:N) は幅しか運ばない。片側が幅しか
          # 主張していないときは幅で比べ、それ以上 (符号) は**主張しない** —
          # u32 と bytes:4 を「違う」と呼ぶのは、比べられない面を差と呼ぶこと。
          wa, wb = byte_width(ma[k]), byte_width(mb[k])
          bytes_only = [ma[k], mb[k]].any? { |v| v.to_s.start_with?("bytes:") }
          next if bytes_only && wa && wb && wa == wb
          out << { what: "#{k} of map #{s}", current: ma[k], mlir: mb[k] }
        end
      end
    end

    def self.cmp_records(a, b, out, mode: :strict)
      syms = (a.map { |r| r[:symbol] } | b.map { |r| r[:symbol] }).sort
      syms.each do |s|
        ra = a.find { |r| r[:symbol] == s }
        rb = b.find { |r| r[:symbol] == s }
        if ra.nil? || rb.nil?
          next if mode == :carried_only   # 片側しか運べない — diff() 冒頭の規則
          out << { what: "presence of record #{s}", current: !ra.nil?, mlir: !rb.nil? }
          next
        end
        out << { what: "size of record #{s}", current: ra[:size], mlir: rb[:size] } if ra[:size] != rb[:size]
        fnames = (ra[:fields].map { |f| f[:name] } | rb[:fields].map { |f| f[:name] }).sort
        fnames.each do |fn|
          fa = ra[:fields].find { |f| f[:name] == fn }
          fb = rb[:fields].find { |f| f[:name] == fn }
          if fa.nil? || fb.nil?
            out << { what: "presence of field #{fn} of record #{s}", current: !fa.nil?, mlir: !fb.nil? }
            next
          end
          if fa[:offset] != fb[:offset]
            out << { what: "offset of record #{s}.#{fn}", current: fa[:offset], mlir: fb[:offset] }
          end
        end
      end
    end
  end
end
