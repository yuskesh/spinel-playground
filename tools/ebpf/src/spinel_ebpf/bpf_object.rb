# frozen_string_literal: true
#
# E154 (P013 Task 7): **生成された .bpf.o から宣言された意味を読む。**
#
# 現行 C backend の object と MLIR backend の object を **同じ reader** に通して
# 突き合わせるためのもの。両側で別の読み方をすると「揃っているが両方誤り」が
# 緑に見えるので、reader は 1 つだけ持つ。
#
# ## 綴りではなく ABI の意味を比べる
#
# 同じ意味でも綴りは backend で違う:
#
#   現行 (clang):  TYPEDEF '__u32' -> INT 'unsigned int' size=4 encoding=(none)
#   MLIR  (spbpf): INT 'u32' size=4 encoding=(none)
#
# map の key が「32 bit の符号なし整数」であることが意味で、`__u32` という綴りは
# 付随物である。よって typedef を解いて **(bit 幅, 符号)** へ正規化してから比べる。
# 綴りで比べると、意味が同じものを差として報告してしまう。
#
# ## 読める範囲の限界 (正直な境界)
#
# **record は現行 object から読めないことがある。** witness の無い channel
# (pair 等) の record struct は、参照されていても現行 object の BTF に載らない
# (実測)。MLIR object は schema witness (.spbpf_records) で常に載る。そこで
# 比較は 2 段になる:
#   - object 同士は records: :carried_only — 両側が運ぶ record だけ厳密比較
#   - MLIR object の record は MlirBackend.record_witness_diff が宣言 manifest と
#     厳密照合 (manifest vs .bpf.c は checkpoint 2 が照合済み — 輪は閉じる)
# 「無い = 一致」とは扱わない。

require "json"
require "open3"
require "set"

module SpinelEbpf
  # object を読めなかったことを **成功扱いにしない**ための例外。
  class BpfObjectError < StandardError; end

  module BpfObject
    # BPF map type 番号 -> 名前。**MlirShadow.MAP_TYPES と同じ綴り**にする
    # (比較器が両者を突き合わせるため)。
    MAP_TYPE_NUMBERS = {
      1  => "hash",
      2  => "array",
      6  => "percpu_array",
      9  => "lru_hash",
      27 => "ringbuf",
    }.freeze

    # program ではない section (ここに居る FUNC は entry ではない)。
    NON_PROGRAM_SECTIONS = [".text", ".maps", "license", ".BTF", ".BTF.ext",
                            ".symtab", ".strtab", ".shstrtab", ".eh_frame"].to_set

    def self.tool(env, default)
      ENV[env] || default
    end

    def self.run(*argv, what:)
      out, err, st = Open3.capture3(*argv)
      unless st.success?
        raise BpfObjectError, "#{what} failed (#{argv.first}): #{err.strip}"
      end
      out
    rescue Errno::ENOENT
      raise BpfObjectError, "#{what} needs #{argv.first}, which is missing"
    end

    # --- 入口 ---------------------------------------------------------------------
    def self.meaning(obj)
      raise BpfObjectError, "object is missing: #{obj}" unless File.file?(obj)
      btf   = parse_btf(obj)
      secs  = elf_sections(obj)
      maps  = maps(btf)
      progs = programs(obj, secs, btf, maps.map { |m| m[:symbol] })
      {
        programs: progs,
        maps:     maps,
        records:  records(btf),
        ringbufs: maps.select { |m| m[:kind] == "ringbuf" }.map { |m| m[:symbol] },
      }
    end

    # --- BTF ----------------------------------------------------------------------
    #
    # `bpftool btf dump file X format raw` を読む。行の形:
    #   [12] VAR 'name' type_id=11, linkage=global
    #   [11] STRUCT '(anon)' size=32 vlen=4
    #   \t'key' type_id=5 bits_offset=64
    def self.parse_btf(obj)
      text = run(tool("BPFTOOL", "bpftool"), "btf", "dump", "file", obj, "format", "raw",
                 what: "reading BTF")
      types = {}
      cur = nil
      text.each_line do |raw_line|
        ln = raw_line.chomp
        if (m = ln.match(/\A\[(\d+)\]\s+(\w+)\s+'([^']*)'(.*)\z/))
          id, kind, name, rest = m[1].to_i, m[2], m[3], m[4]
          cur = { id: id, kind: kind, name: name, members: [] }
          cur[:type_id]  = Regexp.last_match(1).to_i if rest =~ /type_id=(\d+)/
          cur[:nr_elems] = Regexp.last_match(1).to_i if rest =~ /nr_elems=(\d+)/
          cur[:size]     = Regexp.last_match(1).to_i if rest =~ /\bsize=(\d+)/
          cur[:nr_bits]  = Regexp.last_match(1).to_i if rest =~ /nr_bits=(\d+)/
          cur[:encoding] = Regexp.last_match(1)      if rest =~ /encoding=(\S+)/
          types[id] = cur
        elsif cur && ln.start_with?("\t")
          if (mm = ln.match(/\A\t'([^']*)'\s+type_id=(\d+)\s+bits_offset=(\d+)/))
            cur[:members] << { name: mm[1], type_id: mm[2].to_i, bits_offset: mm[3].to_i }
          elsif (mm = ln.match(/\A\ttype_id=(\d+)\s+offset=(\d+)\s+size=(\d+)/))
            cur[:members] << { type_id: mm[1].to_i, offset: mm[2].to_i, size: mm[3].to_i }
          end
        end
      end
      types
    end

    # typedef / const / volatile を解いて実体へ。
    def self.resolve(btf, id, depth = 0)
      t = btf[id]
      return nil if t.nil? || depth > 16
      return resolve(btf, t[:type_id], depth + 1) if %w[TYPEDEF CONST VOLATILE RESTRICT].include?(t[:kind])
      t
    end

    # スカラ整数を **(bit 幅, 符号)** へ正規化する。綴りは捨てる。
    def self.scalar_name(btf, id)
      t = resolve(btf, id)
      return nil if t.nil?
      case t[:kind]
      when "INT"
        bits = t[:nr_bits] || ((t[:size] || 0) * 8)
        signed = t[:encoding].to_s.include?("SIGNED")
        "#{signed ? "s" : "u"}#{bits}"
      when "STRUCT", "UNION"
        "struct #{t[:name]}"
      when "PTR"
        "ptr"
      when "ARRAY"
        el = scalar_name(btf, t[:type_id])
        "#{el}[#{t[:nr_elems]}]"
      end
    end

    # `__uint(field, N)` は `int (*field)[N]` — PTR -> ARRAY の nr_elems が値。
    def self.uint_value(btf, id)
      t = resolve(btf, id)
      return nil unless t && t[:kind] == "PTR"
      a = resolve(btf, t[:type_id])
      return nil unless a && a[:kind] == "ARRAY"
      a[:nr_elems]
    end

    # `__type(field, T)` は `T *field` — PTR の指す先が型。
    def self.type_value(btf, id)
      t = resolve(btf, id)
      return nil unless t && t[:kind] == "PTR"
      scalar_name(btf, t[:type_id])
    end

    # --- map ----------------------------------------------------------------------
    #
    # `.maps` DATASEC に居る VAR が map。VAR の型 (匿名 STRUCT) の member が
    # libbpf の宣言そのもの。
    def self.maps(btf)
      ds = btf.values.find { |t| t[:kind] == "DATASEC" && t[:name] == ".maps" }
      return [] if ds.nil?
      ds[:members].filter_map do |ent|
        var = btf[ent[:type_id]]
        next nil unless var && var[:kind] == "VAR"
        st = resolve(btf, var[:type_id])
        next nil unless st && st[:kind] == "STRUCT"
        by = st[:members].to_h { |mm| [mm[:name], mm[:type_id]] }

        raw = uint_value(btf, by["type"])
        kind = MAP_TYPE_NUMBERS[raw]
        if kind.nil?
          raise BpfObjectError,
                "unknown BPF map type number: #{raw.inspect} (#{var[:name]}). " \
                "An unknown map does not fall back to a default."
        end
        # key/value は __type(...) と __uint(key_size, ...) の 2 形がある。
        key   = by.key?("key")   ? type_value(btf, by["key"]) :
                (by.key?("key_size")   ? "bytes:#{uint_value(btf, by["key_size"])}"   : nil)
        value = by.key?("value") ? type_value(btf, by["value"]) :
                (by.key?("value_size") ? "bytes:#{uint_value(btf, by["value_size"])}" : nil)
        { symbol: var[:name], kind: kind, key: key, value: value,
          max_entries: uint_value(btf, by["max_entries"]) }
      end.sort_by { |m| m[:symbol] }
    end

    # --- record -------------------------------------------------------------------
    #
    # **object の BTF に載っている record だけ**を返す。載っていないことは
    # 「record が無い」ことを意味しない (冒頭の限界を参照)。ここでは共通ヘッダを
    # 先頭に持つ名前付き STRUCT を record とみなす — 現行側の .bpf.c reader が
    # `struct spnl_event_hdr` を目印にしているのと同じ規則。
    HDR_NAME = "spnl_event_hdr"

    def self.records(btf)
      btf.values.select { |t|
        t[:kind] == "STRUCT" && !t[:name].to_s.empty? && t[:name] != HDR_NAME &&
          t[:members].any? { |mm|
            h = resolve(btf, mm[:type_id])
            h && h[:kind] == "STRUCT" && h[:name] == HDR_NAME
          }
      }.map { |t|
        fields = t[:members].map do |mm|
          { name: mm[:name], ctype: scalar_name(btf, mm[:type_id]),
            offset: mm[:bits_offset] / 8 }
        end
        { symbol: t[:name], size: t[:size], fields: fields }
      }.sort_by { |r| r[:symbol] }
    end

    # --- program ------------------------------------------------------------------
    def self.elf_sections(obj)
      text = run(tool("READELF", "readelf"), "-SW", obj, what: "reading sections")
      out = {}
      text.each_line do |ln|
        next unless (m = ln.match(/\A\s*\[\s*(\d+)\]\s+(\S+)/))
        out[m[1].to_i] = m[2]
      end
      out
    end

    # GLOBAL な FUNC symbol が entry。その symbol が居る section 名が SEC 文字列。
    def self.programs(obj, secs, btf, map_symbols)
      text = run(tool("READELF", "readelf"), "-sW", obj, what: "reading symbols")
      funcs = functions(obj)
      progs = []
      text.each_line do |ln|
        m = ln.match(/\A\s*\d+:\s+\S+\s+\d+\s+FUNC\s+GLOBAL\s+\S+\s+(\d+)\s+(\S+)/)
        next unless m
        sec = secs[m[1].to_i]
        next if sec.nil? || NON_PROGRAM_SECTIONS.include?(sec) || sec.start_with?(".rel", ".debug")
        name = m[2]
        has = MlirShadow.sec_has_verdict?(sec)
        progs << {
          name:         name,
          section_kind: sec.split("/").first,
          attach:       sec,
          verdict:      has ? verdict_of(funcs, name) : nil,
          effects:      effects_of(funcs, name, map_symbols),
        }
      end
      progs.sort_by { |p| p[:name] }
    end

    # --- 逆アセンブルの構造化 -------------------------------------------------------
    #
    # `llvm-objdump -d -r` を 1 回だけ読んで、関数ごとに
    #   { section:, insns: [{ slot:, text:, reloc: }] }
    # を組む。slot は BPF の命令 slot 番号 (ld_imm64 は 2 slot を占める) で、
    # 分岐 offset の単位と一致する。reloc 行は直前の命令行に付く。
    def self.functions(obj)
      text = run(tool("LLVM_OBJDUMP", "llvm-objdump"), "-d", "-r", obj,
                 what: "reading instructions")
      funcs = {}
      section = nil
      cur = nil
      text.each_line do |raw|
        ln = raw.chomp
        if (m = ln.match(/\ADisassembly of section (\S+):\z/))
          section = m[1]
        elsif (m = ln.match(/\A[0-9a-f]+ <(\S+)>:\z/))
          cur = { section: section, insns: [] }
          funcs[m[1]] = cur
        elsif cur && (m = ln.match(/\A\s*(\d+):\t/))
          # "       0:\tb7 00 00 00 02 00 00 00\tr0 = 0x2" — tab 区切りの最後が mnemonic。
          # 行頭の slot 番号は **10 進** (byte offset ではない)。
          parts = ln.split("\t")
          next unless parts.size >= 3
          cur[:insns] << { slot: m[1].to_i, text: parts.last.strip, reloc: nil }
        elsif cur && (m = ln.match(/\A\t\t[0-9a-f]+:\s+(R_BPF_\S+)\t(\S+)\z/))
          cur[:insns].last[:reloc] = { type: m[1], target: m[2] } if cur[:insns].any?
        end
      end
      funcs
    end

    # --- verdict ------------------------------------------------------------------
    #
    # **object の命令列から verdict を読む。** 全経路を歩き、**どの exit でも
    # r0 が同じ即値のときだけ**それを既知定数と呼ぶ:
    #
    #   ある経路の exit 時 r0 が call / レジスタ / ロード由来 -> :dynamic
    #   exit ごとに即値が食い違う                             -> :dynamic
    #   経路が読めない (対象外命令 / 範囲外 jump)             -> :dynamic
    #
    # r0 だけを追う小さな抽象実行で、レジスタ間の伝播はしない (r0 = r1 は
    # :dynamic)。**過大主張しない**ことが条件で、精度はその範囲でだけ上げる。
    # 素朴な「exit 直前の命令を見る」規則は、clang が `if (x) return 1; return 2;`
    # を 1 exit へ畳んだとき到達可能集合 {1,2} のところで 1 を返した (実測) —
    # 全経路で合流を確かめる形にしたのはそのため。
    STEP_LIMIT = 20_000

    def self.parse_imm(lit)
      Integer(lit, lit.delete_prefix("-").start_with?("0x") ? 16 : 10)
    end

    def self.branch_target(ins)
      # "goto +0x2 <xdp__main+0x60>" — <sym+0xNN> の byte offset / 8 が slot。
      if (m = ins[:text].match(/<[^>+]+\+0x([0-9a-f]+)>\z/))
        return m[1].to_i(16) / 8
      end
      return 0 if ins[:text].match(/<[^>+]+>\z/)   # "<sym>" は関数先頭 = slot 0
      # 裸の "goto +N": 次 slot からの相対。
      if (m = ins[:text].match(/goto\s+([+-]0x[0-9a-f]+|[+-]\d+)\z/))
        return ins[:slot] + 1 + parse_imm(m[1])
      end
      nil
    end

    def self.verdict_of(funcs, name)
      f = funcs[name]
      return :unknown if f.nil? || f[:insns].empty?
      by_slot = f[:insns].to_h { |i| [i[:slot], i] }
      slots = by_slot.keys.sort
      nxt = slots.each_cons(2).to_h { |a, b| [a, b] }

      exits = []
      seen = Set.new
      work = [[slots.first, :unset]]
      until work.empty?
        pc, r0 = work.pop
        next if seen.include?([pc, r0])
        seen << [pc, r0]
        return :dynamic if seen.size > STEP_LIMIT
        ins = by_slot[pc]
        return :dynamic if ins.nil?   # 範囲外へ跳んだ — この経路は読めない
        t = ins[:text]
        case
        when t == "exit"
          exits << r0
        when t.start_with?("call")
          work << [nxt[pc], :dynamic]                        # 戻り値は実行時
        when t.start_with?("goto ")
          tgt = branch_target(ins)
          return :dynamic if tgt.nil?
          work << [tgt, r0]
        when t.include?("goto")                              # 条件分岐: 両側を歩く
          tgt = branch_target(ins)
          return :dynamic if tgt.nil?
          work << [tgt, r0] << [nxt[pc], r0]
        when (m = t.match(/\A[rw]0 = (-?0x[0-9a-f]+|-?\d+)\z/))
          work << [nxt[pc], parse_imm(m[1])]
        when t.match(/\A[rw]0\b/)                            # r0 への他の書き込み/演算
          work << [nxt[pc], :dynamic]
        else
          work << [nxt[pc], r0]
        end
      end
      return :unknown if exits.empty?
      return :dynamic if exits.any? { |v| v == :dynamic || v == :unset }
      vals = exits.uniq
      vals.size == 1 ? vals.first : :dynamic                 # 集合 {1,2} からどれかを選ばない
    end

    # --- map effect ---------------------------------------------------------------
    #
    # **program が map に対して何をするか**を object から読む (E154 checkpoint 3)。
    # 宣言と verdict の外形だけ揃った stub (map を触らない body) を「同じ意味」と
    # 呼ばないための面 — Mac の指摘 2026-08-25。
    #
    # 読むのは:
    #   helpers  — 到達する helper 呼び出しの **列** (BPF-to-BPF call は callee を
    #              呼び出し地点で辿って平坦化する)
    #   map_refs — 到達する命令が reloc で参照する **宣言済み map** の回数
    #
    # 帰属できないとき (callee が特定できない / 再帰) は **:unknown** を返す。
    # 比較器は :unknown を一致とも差とも扱わず停止する — verdict の 4 状態と
    # 同じ規律。命令ごとの「この lookup はこの map」という対応までは主張しない
    # (それには register の dataflow が要る)。
    HELPER_NAMES = { 1 => "map_lookup_elem", 2 => "map_update_elem", 3 => "map_delete_elem" }.freeze

    def self.resolve_callee(funcs, reloc)
      tgt = reloc[:target]
      return tgt if funcs.key?(tgt)
      # section 名への reloc (例 ".text")。その section に関数が 1 つのときだけ帰属。
      cands = funcs.keys.select { |k| funcs[k][:section] == tgt }
      cands.size == 1 ? cands.first : nil
    end

    def self.effects_of(funcs, name, map_symbols)
      helpers = []
      map_refs = Hash.new(0)
      walk = lambda do |fname, stack|
        return :unknown if stack.include?(fname)     # 再帰は帰属しない
        f = funcs[fname]
        return :unknown if f.nil?
        f[:insns].each do |ins|
          if ins[:text].start_with?("call")
            if ins[:reloc]                            # BPF-to-BPF: callee を辿る
              callee = resolve_callee(funcs, ins[:reloc])
              return :unknown if callee.nil?
              r = walk.call(callee, stack + [fname])
              return :unknown if r == :unknown
            elsif (m = ins[:text].match(/\Acall (-?0x[0-9a-f]+|-?\d+)\z/))
              n = parse_imm(m[1])
              helpers << (HELPER_NAMES[n] || "helper##{n}")
            else
              return :unknown                         # 読めない call 形
            end
          elsif ins[:reloc] && map_symbols.include?(ins[:reloc][:target])
            map_refs[ins[:reloc][:target]] += 1
          end
        end
        :ok
      end
      return :unknown if walk.call(name, []) == :unknown
      { helpers: helpers, map_refs: map_refs }
    end

  end
end
