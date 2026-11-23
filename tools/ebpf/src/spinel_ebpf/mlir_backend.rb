# frozen_string_literal: true
#
# E154 (P013 Task 7): **MLIR backend を実際に走らせて .bpf.o を作る。**
#
# ## 経路
#
#   .ir / .ast
#     -> spinel_ebpf_cc (現行 C backend)  -> .bpf.c -> clang -> 現行 .bpf.o
#     -> 宣言 manifest (schema adapter)   -> schema.json + prog.mlir
#                                        -> spbpf-compile -> MLIR .bpf.o
#
# 両方の **object** を同じ reader (SpinelEbpf::BpfObject) に通して意味を比べる。
# 正典は codegen の宣言であって、SPINEL-IR text でも .bpf.c でもない。
#
# ## 2 つの差動があること
#
#   checkpoint 2  宣言 manifest vs 生成された .bpf.c の本文
#                 (MlirShadow.meaning_of_bpf_c / meaning_of_manifest)
#                 -> 宣言と emit の乖離を捕まえる。record / field offset を覆う。
#
#   checkpoint 3  現行 .bpf.o vs MLIR .bpf.o   ← **ここ**
#                 -> 実際の成果物同士。program / map / verdict を覆う。
#                    record は object の BTF に載らないので覆わない
#                    (bpf_object.rb 冒頭の限界を参照)。
#
# どちらも独立した gate として残す。片方が他方を含むわけではない。
#
# ## 失敗の扱い
#
# **shadow 側が動かないことを成功扱いにしない。** 道具が無い / 落ちた /
# object が出なかった、はすべて ShadowError で loud に落とす。現行成果物へ
# 黙って fallback する経路はここに存在しない。

require "json"
require "open3"
require "tmpdir"
require "fileutils"

require "spinel_ebpf/mlir_shadow"
require "spinel_ebpf/spbpf_schema"
require "spinel_ebpf/bpf_object"

module SpinelEbpf
  module MlirBackend
    ROOT = File.expand_path("../..", __dir__)

    # 既定の道具。すべて環境変数で差し替えられる。
    DEFAULT_CC      = File.join(ROOT, "build", "codegen_c", "spinel_ebpf_cc")
    # Spinel Extended: no default. spbpf-compile is spinel-llvm's, and a tracked
    # file may not name a sibling checkout; SPNL_SPBPF_COMPILE must name it, or
    # the shadow stops loudly below ("spbpf-compile が無い").
    DEFAULT_SPBPF   = ""
    DEFAULT_CLANG   = "clang"
    # libspbpf C ABI の in-process consumer (tools/build_spbpf_schema_check.sh)。
    DEFAULT_SCHEMA_CHECK = File.join(ROOT, "build", "tools", "spnl_spbpf_schema_check")

    def self.codegen_path      = ENV["SPNL_EBPF_CC"] || DEFAULT_CC
    def self.spbpf_path        = ENV["SPNL_SPBPF_COMPILE"] || DEFAULT_SPBPF
    def self.clang_path        = ENV["CLANG"] || DEFAULT_CLANG
    def self.schema_check_path = ENV["SPNL_SPBPF_SCHEMA_CHECK"] || DEFAULT_SCHEMA_CHECK

    # opt-in 経路の名前。**未設定なら manifest は書かれない**ので、既定経路の
    # .bpf.c は byte-identical のまま。
    BACKEND_ENV = { "SPNL_BPF_BACKEND" => "mlir" }.freeze

    def self.shadow_error(msg) = raise(MlirShadow::ShadowError, msg)

    def self.capture(argv, env: {}, what:)
      out, err, st = Open3.capture3(env, *argv)
      shadow_error("#{what} failed (#{st.exitstatus}): #{err.strip}") unless st.success?
      [out, err]
    rescue Errno::ENOENT
      shadow_error("#{what} needs #{argv.first}, which is missing")
    end

    # --- 現行 C backend: .bpf.c ----------------------------------------------------
    def self.bpf_c(ir, ast, base)
      cc = codegen_path
      shadow_error("codegen is missing (#{cc}). Build it with make -C src/codegen_c.") unless File.executable?(cc)
      [["IR", ir], ["AST", ast]].each do |what, path|
        shadow_error("input #{what} is missing: #{path}") unless File.file?(path)
      end
      capture([cc, ir, ast, base], what: "the current backend's codegen").first
    end

    # --- 宣言 manifest -------------------------------------------------------------
    def self.manifest(ir, ast, base)
      cc = codegen_path
      shadow_error("codegen is missing (#{cc}). Build it with make -C src/codegen_c.") unless File.executable?(cc)
      [["IR", ir], ["AST", ast]].each do |what, path|
        shadow_error("input #{what} is missing: #{path}") unless File.file?(path)
      end
      Dir.mktmpdir("spnl-manifest") do |dir|
        out = File.join(dir, "manifest.json")
        _, err = capture([cc, ir, ast, base],
                         env: BACKEND_ENV.merge("SPNL_BPF_MANIFEST" => out),
                         what: "the MLIR backend's codegen")
        unless File.exist?(out)
          shadow_error("the MLIR backend wrote no manifest (stderr: #{err.strip})")
        end
        begin
          JSON.parse(File.read(out))
        rescue JSON::ParserError => e
          shadow_error("the manifest is not readable as JSON: #{e.message}")
        end
      end
    end

    # --- 現行側 .bpf.o -------------------------------------------------------------
    #
    # 生成 flags は golden_compile.sh (= 製品 CLI bin/spinel-ebpf の bpf_clang_argv)
    # と同じ骨格。ここで別 flags を使うと、比べているものが製品の成果物でなくなる。
    def self.clang_argv(src, obj)
      arch = case `uname -m`.strip
             when "aarch64", "arm64" then "-D__TARGET_ARCH_arm64"
             else "-D__TARGET_ARCH_x86"
             end
      inc = Dir.glob("/usr/include/*-linux-gnu").select { |d| File.directory?(d) }.flat_map { |d| ["-I", d] }
      [clang_path, "-O2", "-g", "-target", "bpf", arch, "-mcpu=#{ENV["SPNL_BPF_MCPU"] || "v1"}",
       "-Wno-missing-declarations", *inc,
       "-I", File.join(ROOT, "build"), "-I", File.join(ROOT, "include"),
       "-c", src, "-o", obj]
    end

    def self.compile_current(ir, ast, base, dir)
      src = File.join(dir, "#{base}.bpf.c")
      File.write(src, bpf_c(ir, ast, base))
      obj = File.join(dir, "#{base}.current.bpf.o")
      capture(clang_argv(src, obj), what: "clang compile of the current .bpf.c")
      shadow_error("clang produced no object: #{obj}") unless File.exist?(obj)
      obj
    end

    # --- MLIR 側 .bpf.o ------------------------------------------------------------
    def self.compile_mlir(manifest, base, dir)
      where = "the manifest of #{base}"
      MlirShadow.require_fully_registered(manifest, where)
      schema = File.join(dir, "#{base}.schema.json")
      mlir   = File.join(dir, "#{base}.mlir")
      obj    = File.join(dir, "#{base}.mlir.bpf.o")
      begin
        File.write(schema, JSON.pretty_generate(SpbpfSchema.schema_of(manifest, where)))
        File.write(mlir, SpbpfSchema.mlir_of(manifest, where))
      rescue SpbpfSchema::Unsupported => e
        # **範囲外は Unsupported として上げる** (ShadowError ではない) —
        # 「shadow が壊れた」ではなく「E154 の対象外」だと区別できるように。
        raise MlirShadow::Unsupported, e.message
      end
      # E154: 生成した schema を **libspbpf の C ABI で in-process に検証**して
      # から外部の spbpf-compile を呼ぶ。正典 parser (sp_bpf_schema_parse_json)
      # が受理しない schema からは object を作らない。C ABI が公開するのは
      # parse / serialize までで compile は無い — object 生成が外部 tool のままな
      # のは ABI の境界であって、この検査を省く理由ではない。
      chk = schema_check_path
      unless File.executable?(chk)
        shadow_error("spnl_spbpf_schema_check is missing (#{chk}). " \
                     "Build it with tools/build_spbpf_schema_check.sh.")
      end
      capture([chk, schema], what: "schema check through the libspbpf C ABI")
      sp = spbpf_path
      unless File.executable?(sp)
        shadow_error("spbpf-compile is missing (#{sp}). Point SPNL_SPBPF_COMPILE at it.")
      end
      capture([sp, mlir, "--schema", schema, "-o", obj], what: "spbpf-compile")
      shadow_error("spbpf-compile produced no object: #{obj}") unless File.exist?(obj)
      obj
    end

    # --- 入口 -----------------------------------------------------------------------

    # 両 backend の object を作り、それぞれの意味を返す。
    # ブロックを渡すと object の path も渡す (変異試験が object を触るため)。
    def self.both_meanings(ir, ast, base)
      Dir.mktmpdir("spnl-mlir-shadow") do |dir|
        cur_obj = compile_current(ir, ast, base, dir)
        mlir_obj = compile_mlir(manifest(ir, ast, base), base, dir)
        yield(cur_obj, mlir_obj, dir) if block_given?
        [BpfObject.meaning(cur_obj), BpfObject.meaning(mlir_obj)]
      end
    end

    # MLIR backend が出した object の意味。
    def self.meaning(ir, ast, base)
      Dir.mktmpdir("spnl-mlir-obj") do |dir|
        BpfObject.meaning(compile_mlir(manifest(ir, ast, base), base, dir))
      end
    end

    # 現行 backend が出した object の意味。
    def self.current_meaning(ir, ast, base)
      Dir.mktmpdir("spnl-cur-obj") do |dir|
        BpfObject.meaning(compile_current(ir, ast, base, dir))
      end
    end

    # 両者を突き合わせる。差があれば返す (空 = 一致)。
    #
    # record は :carried_only — 現行 object の BTF は record を運ばないことが
    # ある (実測) ので、object 同士では「両側が運ぶ record」だけを比較し、
    # MLIR object の record は record_witness_diff が宣言 manifest と厳密照合
    # する (manifest vs .bpf.c は checkpoint 2 が照合済み — 輪は閉じる)。
    def self.diff(ir, ast, base)
      m = manifest(ir, ast, base)
      Dir.mktmpdir("spnl-mlir-shadow") do |dir|
        cur_obj  = compile_current(ir, ast, base, dir)
        mlir_obj = compile_mlir(m, base, dir)
        cur, mlir = BpfObject.meaning(cur_obj), BpfObject.meaning(mlir_obj)
        MlirShadow.diff(cur, mlir, records: :carried_only) +
          record_witness_diff(m, mlir, "the manifest of #{base}")
      end
    end

    # MLIR object の BTF に載った record と宣言 manifest の layout の厳密照合。
    # 比べるのは symbol / size / field 名 / offset / (正規化した) 型。
    def self.record_witness_diff(m, mlir_meaning, where)
      want = records_of(m, where)
      got  = Array(mlir_meaning[:records])
      out = []
      want.each do |w|
        g = got.find { |r| r[:symbol] == w[:symbol] }
        if g.nil?
          out << { what: "the MLIR object has no witness for record #{w[:symbol]}",
                   current: w[:symbol], mlir: nil }
          next
        end
        if w[:size] != g[:size]
          out << { what: "size of record #{w[:symbol]} (manifest vs MLIR object)",
                   current: w[:size], mlir: g[:size] }
        end
        w[:fields].each do |wf|
          gf = g[:fields].find { |f| f[:name] == wf[:name] }
          if gf.nil?
            out << { what: "record #{w[:symbol]}.#{wf[:name]} is missing from the MLIR object",
                     current: wf[:name], mlir: nil }
            next
          end
          if wf[:offset] != gf[:offset]
            out << { what: "offset of record #{w[:symbol]}.#{wf[:name]} (manifest vs MLIR object)",
                     current: wf[:offset], mlir: gf[:offset] }
          end
          wn, gn = norm_ctype(wf[:ctype]), norm_ctype(gf[:ctype])
          if wn != gn
            out << { what: "type of record #{w[:symbol]}.#{wf[:name]} (manifest vs MLIR object)",
                     current: wf[:ctype], mlir: gf[:ctype] }
          end
        end
      end
      got.each do |g|
        next if want.any? { |w| w[:symbol] == g[:symbol] }
        next if g[:symbol] == MlirShadow::HDR[:name]
        out << { what: "the MLIR object carries a record that is not declared", current: nil, mlir: g[:symbol] }
      end
      out
    end

    # 綴りの正規化: "__s64"/"s64"、"char"/"s8"、"T [N]"/"T[N]" を同じ意味へ。
    # 知らない綴りはそのまま返す — 誤って同一視するより差として見える方が安全。
    def self.norm_ctype(ctype)
      c = ctype.to_s.strip
      return c if c.start_with?("struct ")
      if (m = c.match(/\A(.+?)\s*\[(\d+)\]\z/))
        return "#{norm_ctype(m[1])}[#{m[2]}]"
      end
      c = c.sub(/\A__/, "")
      { "char" => "s8", "int" => "s32", "long long" => "s64" }.fetch(c, c)
    end

    # --- 宣言 manifest -> 意味 (checkpoint 2 の差動が使う) ---------------------------
    #
    # object を作らずに manifest だけから意味を組む経路。**object 差動とは別の
    # gate** で、record / field offset はこちらが覆う。
    def self.from_manifest(m, where)
      MlirShadow.require_fully_registered(m, where)
      maps = maps_of(m, where)
      {
        programs: programs_of(m, where),
        maps:     maps,
        records:  records_of(m, where),
        ringbufs: maps.select { |x| x[:kind] == "ringbuf" }.map { |x| x[:symbol] },
      }
    end

    def self.manifest_meaning(ir, ast, base)
      from_manifest(manifest(ir, ast, base), "the manifest of #{base}")
    end

    def self.programs_of(m, where)
      Array(m["programs"]).map do |p|
        sec = p["sec"]
        raise MlirShadow::Unsupported, "#{where}: program has no sec: #{p.inspect}" if sec.nil?
        {
          name: p["name"],
          # section_kind — SEC 文字列の頭。両 backend 間で比較する。
          # decl_kind    — 宣言表の kname。SEC から一意に逆引きできないので
          #                比較はせず、[decl_kind, attach] の組が宣言表に実在
          #                することを比較器が検査する。
          section_kind: sec.split("/").first,
          decl_kind:    p["kind"],
          attach:       sec,
          verdict:      verdict_of(p, where),
        }
      end.sort_by { |p| p[:name] }
    end

    # 4 状態を Ruby 側の表現へ。**「分からない」を既定値へ倒さない。**
    def self.verdict_of(p, where)
      v = p["verdict"]
      unless p["has_verdict"]
        unless v.nil?
          raise MlirShadow::Unsupported,
                "#{where}: program #{p["name"]} is of a kind without a verdict, " \
                "yet it has a verdict: #{v.inspect}"
        end
        return nil
      end
      case v
      when Integer then v
      when "dynamic" then :dynamic
      when "unknown" then :unknown
      when nil
        raise MlirShadow::Unsupported,
              "#{where}: the manifest has no verdict for enforcement program #{p["name"]}. " \
              "A verdict that could not be resolved must be stated explicitly as unknown; a missing one is an error."
      else
        raise MlirShadow::Unsupported, "#{where}: unknown verdict form: #{v.inspect} (#{p["name"]})"
      end
    end

    KNOWN_MAP_KINDS = MlirShadow::MAP_TYPES.values.freeze

    def self.maps_of(m, where)
      Array(m["maps"]).map do |x|
        kind = x["kind"]
        unless KNOWN_MAP_KINDS.include?(kind)
          raise MlirShadow::Unsupported, "#{where}: unknown map kind: #{kind.inspect} (#{x["symbol"]})"
        end
        me = x["max_entries"]
        unless me.is_a?(Integer)
          raise MlirShadow::Unsupported,
                "#{where}: max_entries of map #{x["symbol"]} is not a number: #{me.inspect}"
        end
        { symbol: x["symbol"], kind: kind, key: x["key"], value: x["value"], max_entries: me }
      end.sort_by { |x| x[:symbol] }
    end

    def self.records_of(m, where)
      known = {}
      Array(m["records"]).map do |r|
        fields = Array(r["fields"]).map do |f|
          count = f["count"] || 0
          if count.to_i > 0
            raise MlirShadow::Unsupported,
                  "#{where}: field #{f["name"]} of record #{r["symbol"]} is an array " \
                  "(count=#{count}). The current side's reader cannot read arrays, so it is outside E154."
          end
          { name: f["name"], ctype: f["ctype"] }
        end
        MlirShadow.layout_record(r["symbol"], fields, known)
      end.sort_by { |r| r[:symbol] }
    end
  end
end
