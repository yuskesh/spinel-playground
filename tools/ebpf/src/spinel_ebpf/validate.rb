# frozen_string_literal: true
#
# E317 (ADR-015 原則2「loud failure」+ 投資優先(b)): compile 時の loud で
# actionable な拒否。AI が誤った Ruby を書いたとき、**何が・なぜ・どこ・どう直すか**
# を返して自己修正を助ける (E316 affordance = 読む、本モジュール = 直す)。
#
# partition と codegen の隙間に落ちる穴を、**codegen を呼ぶ前**に Ruby で
# 塞ぐ (C 版・Ruby oracle どちらの codegen でも同じ loud エラーが CLI から出る):
#
#   1. attach ハンドラが :native に落ちる = silent no-op
#      (`def kprobe__x` が float/regex/io で eBPF 不適格 → 誰も発火させない。
#       exit 0 のまま黙って消える最悪ケース)。attach prefix を持つメソッドが
#       ebpf-impossible で :native なら **hard error** + 具体的理由。
#
#   2. attach 名の typo (E320 / E319 GAP-2、最重大) — `def kprobe_do_sys_openat2`
#      (アンダースコア 1 個、正しくは `kprobe__`)。既知の attach-kind (kprobe/…) の
#      後に単一 `_` が続くと、どの ATTACH_PATTERNS にもマッチせず **孤児 SEC("syscall")
#      program に silent フォールバック**する (partition/codegen/clang/verifier 全緑
#      なのにカーネルに attach されず一生発火しない)。`__` にすれば valid attach に
#      なるものを typo とみなし **did-you-mean** で loud に落とす。
#
#   3. 0 引数 builtin の余分な引数 (E320 / E319 GAP-1) — `latency_start(1)`。C 版
#      codegen は sibling の `lat_start`/`lat_end` (arity 1) は arity を検査するのに
#      `latency_start`/`latency_end` (arity 0) は引数を silent に捨てる非対称がある。
#      余分な引数を **loud** に落として整合させる (`expects no arguments`)。
#
#   4. 未知 builtin (typo) — `hist_observ(x)`。codegen は "CallNode not yet ported"
#      や "not lowerable" と cryptic に落ちる。ここで **did-you-mean** (Levenshtein、
#      依存なし) を出す。
#
#   5. 不完全な必須組 — `http_req_start` だけ書いて `http_emit` を書かない等。
#      現状は **silent に壊れた program** (span が出ないが exit 0)。
#      Capabilities::REQUIRED_SETS を参照して **loud** に落とす。
#
# +heap: `[1,2,3].map { }` 等の enumerable ブロックは eBPF 不可。partition は
#   これを捕まえないので (map は DYNAMIC_ARRAY_OPS 外)、ここで名指しして落とす。
#
# 非目標: **成功する probe の生成コードは 1 byte も変えない** (golden 不変)。
# エラー経路だけを賢くする。過剰に厳しくしない (2 軸ハーネス: 良い probe は通す)。

require "set"
require_relative "capabilities"
require_relative "codegen_bpf"
require_relative "dispatch_shim"  # E422: the (7) check needs the extern-method rule
require_relative "param"
require_relative "kernel_cache"   # E420: the (6) check needs the declaration parser

module SpinelEbpf
  module Validate
    # 拒否は ADR-003 に従い即エラー。CLI は rescue して `error: <message>` で abort。
    class Error < StandardError; end

    module_function

    # 全 builtin の権威集合 (codegen の BUILTIN_NAMES + dynptr)。
    BUILTINS = (CodegenBpf::BUILTIN_NAMES + CodegenBpf::DYNPTR_BUILTINS).uniq.to_set.freeze

    # eBPF サブセットで唯一許される受信あり反復は `n.times { }`。それ以外の
    # enumerable ブロック呼出は heap 反復 = eBPF 不可。ブロック付きに限定して
    # 判定するので、kfield の dot-field read (`t.min`、ブロック無し) や
    # dot-accessor (`sk.snd_cwnd`) を誤検出しない。
    ENUMERABLE_BLOCK_METHODS = %w[
      map collect select filter reject filter_map
      reduce inject each each_with_object each_with_index each_pair
      flat_map find detect find_all group_by partition
      sort_by min_by max_by sum count chunk_while zip
    ].to_set.freeze

    # 受信なし control 形 (万一 :ebpf に残っても typo 扱いしない安全網)。
    CONTROL_NAMES = %w[times loop lambda proc].to_set.freeze

    # E320 (GAP-2): 既知の attach-kind word。affordance と検出を同じデータ源に
    # するため、Capabilities::ATTACH_KINDS の method_prefix から先頭識別子 (最初の
    # `__` より前) を機械的に抜く。例: "kprobe__<func>" -> "kprobe"、"xdp__<name>"
    # -> "xdp"、"xdp_tail__<name>" -> "xdp_tail"、"sk_skb__verdict__<name>" ->
    # "sk_skb"。timer だけ method_prefix が "on :timer, …" 形 (作者が手で def しない
    # 合成名) なので先頭が識別子でなく自然に除外される。長い word を先に試すため
    # 長さ降順 (xdp_tail を xdp より優先 = 良い suggestion)。
    ATTACH_WORDS = Capabilities::ATTACH_KINDS
                   .filter_map { |a| a[:method_prefix][/\A([a-z0-9_]+?)__/, 1] }
                   .uniq
                   .sort_by { |w| -w.length }
                   .freeze

    # E320 (GAP-1): 引数を取らない (arity 0) builtin のうち、sibling (lat_start/
    # lat_end) が arity を検査するのに C codegen が silent に引数を捨てる非対称を
    # 持つもの。余分な引数を loud に落とす。tid キーは builtin 内部で取るので 0 引数。
    ZERO_ARG_STRICT = %w[latency_start latency_end].to_set.freeze

    # 全チェックを走らせる (loud 検査 = 最初の違反で raise)。
    #   ast            -- ParseSpinelAst
    #   result         -- Partition::Result (tag 決定済)
    #   ebpf_dispatch: -- CLI の --ebpf-dispatch (E422 (7) が使う)
    # extra_builtins: E456 -- a restricted target's call allowlist (TargetProfile)
    # can name builtins that exist only on that target (gpu_load etc.); they are
    # known there, so the unknown-builtin check must not read them as typos. The
    # target's own codegen scan remains the authority on what they lower to.
    def validate!(ast, result, ebpf_dispatch: false, extra_builtins: [])
      return if result.nil? || ast.nil?
      check_attach_handlers_are_ebpf!(result)              # (1)
      check_attach_name_typos!(result)                     # (2) E320 GAP-2
      used, unknown = scan_ebpf_calls(ast, result, extra_builtins) # 1 回の walk で両方
      check_heap_iteration!(ast, result)                   # +heap
      check_zero_arg_builtins!(ast, result)                # (3) E320 GAP-1
      check_unknown_builtins!(unknown)                     # (4)
      check_required_sets!(used)                           # (5)
      check_kernel_cache_unported!(ast)                    # (6) E420
      check_native_side_ebpf_builtins!(ast, result, ebpf_dispatch) # (7) E422
      nil
    end

    # ---------- E422: the seam between the two partitioners ----------
    #
    # spinel-ebpf runs TWO partitions over the same program:
    #
    #   Ruby (Partition.classify)  walks the body -- I/O, unbounded loops,
    #                              closures, recursion, inherited impossibility
    #   C (cc_sig_eligible)        reads the SIGNATURE and nothing else
    #
    # They disagree in one direction only: a method can be int,int->int (so the C
    # side would emit it) and still be eBPF-impossible (so the Ruby side keeps it
    # native). `def worker_loop(port, my_idx)` in examples/http_server/M003 is
    # both; E421 measured it dying as `CallNode not yet ported (Stage 1): loop`.
    #
    # Ruby wins, because it is the one that looked at the body. These are the
    # names handed to the codegen in $SPNL_PARTITION_NATIVE.
    #
    # WHAT MAY NOT BE ON THIS LIST: an attach handler. Attach is the author's
    # stated intent and has no native execution path, so excluding one turns
    # "it fires" into "it never fires" with exit 0 -- the silent drop E421
    # refused to risk. Those already die in check (1) above, one layer before
    # this list is built; keeping them out of it means E422 cannot introduce
    # that failure even if check (1) were ever narrowed. `describe`/the
    # partition table print the reason either way, and the codegen prints one
    # line per name it actually overrules (cc_report_partition_overrides), so
    # the disagreement is never invisible from either side.
    def native_override_names(result)
      return [] if result.nil?
      result.methods.filter_map do |mi|
        next unless mi.tag == :native
        next if mi.scope == :main
        name = mi.method_name
        next if name.nil? || name.empty?
        next if name.start_with?("__spnl_")            # E242 consumer fns: already excluded
        next if CodegenBpf.detect_attach(name)         # never (see above)
        mi.scope == :class ? "#{mi.class_name}##{name}" : name
      end.uniq
    end

    # (7) E422: an eBPF-only builtin in a body that is ALSO compiled natively.
    #
    # Without --ebpf-dispatch, spinel emits a native C body for every method
    # reachable from `<main>` -- including the :ebpf-tagged ones. So a builtin
    # that only the eBPF codegen knows (`path_counter_inc` -> a BPF map update)
    # reaches upstream spinel, which refuses it:
    #
    #   spinel: server.rb:67: unsupported call: node 1408
    #           (CallNode `path_counter_inc`) recv=-/ty-1 argc=1 arg0ty3
    #
    # spinel-ebpf holds all three facts before that call is made (the builtin
    # list, the partition, and whether --ebpf-dispatch was passed), so it says
    # so itself, with the fix (ADR-003 / E413 / E421 R5(C)).
    #
    # REACHABILITY IS PART OF THE CONDITION, and it was measured, not assumed
    # (results/E422/upstream_reachability.txt): upstream does NOT emit a method
    # nothing calls. An attach handler using `spnl_emit` with no stub compiles
    # fine today precisely because nobody calls it from Ruby -- so a check that
    # only asked "does an :ebpf body call an eBPF-only builtin" would reject
    # most of the corpus. The walk starts at `<main>` and stops at any method
    # --ebpf-dispatch turns into an extern, because that is exactly the set
    # whose bodies still reach the native emitter.
    #
    # The E392/E399 precedent (`param` / `filter_by` commented out of the native
    # copy only) does not transfer: those are top-level DECLARATIONS, one line
    # each, and blanking them changes nothing about the method bodies. This is a
    # call inside a body -- deleting it would silently change what the native
    # side does (M003's `route` would stop counting), and rewriting the body is
    # what --ebpf-dispatch already does, properly, through the extern hook.
    def check_native_side_ebpf_builtins!(ast, result, ebpf_dispatch)
      extern = ebpf_dispatch ? DispatchShim.eligible_method_names(result).to_set : Set.new
      by_name = Hash.new { |h, k| h[k] = [] }
      result.methods.each { |m| by_name[m.method_name] << m }

      # Bodies the native emitter still reaches: from <main>, through every
      # method that is not handed to spinel as an extern declaration.
      reached = {}
      order   = []
      stack   = result.methods.select { |m| m.scope == :main }
      until stack.empty?
        mi = stack.pop
        key = mi.qualified_name
        next if reached[key]
        reached[key] = mi
        order << mi
        mi.flags.calls.uniq.each do |callee|
          next if extern.include?(callee)
          by_name[callee].each { |cm| stack << cm }
        end
      end

      defined_names = ast_defined_method_names(ast)
      order.each do |mi|
        next unless mi.tag == :ebpf
        next if mi.body_id.nil? || mi.body_id < 0
        walk_calls(mi.body_id, ast) do |nid|
          next unless ast.receiver_of(nid) < 0
          name = ast.name_of(nid)
          next if name.nil? || name.empty?
          next unless BUILTINS.include?(name)
          next if defined_names.include?(name)   # `def spnl_emit(x); end` stub: upstream resolves it
          raise Error, native_side_builtin_message(mi, name, result, ebpf_dispatch)
        end
      end
    end

    # Every `def <name>` in the AST, whatever its scope and whether or not it has
    # a body. NOT method_name_set(result): the partition skips a body-less def
    # (`resolve_ast_body_id` finds no body), and a body-less def is exactly the
    # shape of the builtin stub the corpus uses — `def spnl_emit(x); end`, which
    # is why fixtures full of `spnl_emit` compile natively today (measured:
    # results/E422/upstream_reachability.txt, probe D). Reading the partition
    # here made the first version of this check reject 3 fixtures that build.
    def ast_defined_method_names(ast)
      s = Set.new
      return s unless ast && ast.nodes
      ast.nodes.each_value do |n|
        next unless n.type == "DefNode"
        nm = n.attrs.fetch("name", "")
        s << nm unless nm.empty?
      end
      s
    end

    def native_side_builtin_message(mi, builtin, result, ebpf_dispatch)
      dispatchable = DispatchShim.eligible?(mi)
      fix =
        if dispatchable && !ebpf_dispatch
          "Fix: add `--ebpf-dispatch`. It declares `#{mi.method_name}` extern " \
          "(ADR-004 SPINEL_EXTERN_METHODS) so spinel emits no native body for it, and links a " \
          "shim that forwards the native call into the BPF program (E028) — which is what " \
          "calling an :ebpf method from native code is supposed to mean."
        elsif dispatchable
          "Fix: `--ebpf-dispatch` is on but `#{mi.method_name}` was not made extern — check the " \
          "boundary ABI (only int/bool parameters and int/bool/void returns cross)."
        else
          why = CodegenBpf.detect_attach(mi.method_name) ? "it is an attach handler" : "it is not a plain top-level method"
          "Fix: `--ebpf-dispatch` cannot cover `#{mi.method_name}` (#{why}), so it has no extern " \
          "form. Move the `#{builtin}` call into a plain top-level :ebpf method and call THAT " \
          "from native code, or stop calling `#{mi.method_name}` from native code."
        end
      "`#{mi.method_name}` calls the eBPF-only builtin `#{builtin}`, and its body is also compiled " \
      "into the native C.\n" \
      "  Why: `#{builtin}` exists only in the eBPF codegen; upstream spinel has no such method and " \
      "refuses it (\"unsupported call: (CallNode `#{builtin}`)\"). " \
      "#{ebpf_dispatch ? 'Even with --ebpf-dispatch, spinel' : 'Without --ebpf-dispatch, spinel'} emits a " \
      "native body for every method reachable from `<main>`, and this one is reached via " \
      "#{native_reach_path(mi, result).join(' -> ')}.\n" \
      "  #{fix}"
    end

    # A shortest <main> -> ... -> mi path through the call graph, for the message.
    # Over-approximate by name (the same approximation Phase 3 uses); worst case
    # the author is shown a different true path to the same method.
    def native_reach_path(mi, result)
      by_name = Hash.new { |h, k| h[k] = [] }
      result.methods.each { |m| by_name[m.method_name] << m }
      seen  = {}
      queue = result.methods.select { |m| m.scope == :main }.map { |m| [m, ["<main>"]] }
      until queue.empty?
        cur, path = queue.shift
        key = cur.qualified_name
        next if seen[key]
        seen[key] = true
        return path if cur.equal?(mi)
        cur.flags.calls.uniq.each do |callee|
          by_name[callee].each { |cm| queue << [cm, path + [cm.qualified_name]] }
        end
      end
      ["<main>", mi.qualified_name]
    end

    # (6) E420: `kernel_cache "/path", body` — a top-level directive that reaches
    # NOTHING. E188 built it in the retired Ruby oracle; the C port (ADR-011
    # Stage 2) never carried it, and E416 re-ported the tcp_slice bundle WITHOUT
    # the kernel_cache branch. Measured on 2026-08-05, before this check existed:
    #
    #   partition   says `ebpf  xdp__tcp_slice__kernel_cache`
    #   codegen     emits an EMPTY .bpf.c ("ebpf-eligible methods: 0")
    #   --build     succeeds; the binary prints "BPF loaded and attached"
    #   run         `bpftool prog show` = 0 programs, curl :8080 refused, exit 0
    #
    # E417 recorded the three orphaned map lookups (bpf_kc_resp{,_len,_csum}) and
    # argued the hole was loud because sp_kc_set returns -2. It is loud only if
    # the caller looks: the shipped demo discarded the value and printed a success
    # message. So the hole was silent in exactly the shape ADR-003 forbids, and
    # E420 closed it here -- at the layer that still knows the author wrote
    # `kernel_cache`, rather than at a `find_map_by_name` that returns NULL.
    #
    # E427 (2026-08-07) removed the first line of that trace: partition used to
    # synthesize `xdp__tcp_slice__kernel_cache` and print it in the tag table of
    # a program this check was about to refuse — the tool announcing an eBPF
    # method and then contradicting itself two lines later. The synthesis fed
    # only the retired oracle, so deleting it costs nothing and stops the
    # partition table from claiming something that cannot exist.
    #
    # What is left of the surface is the DETECTOR (SpinelEbpf::KernelCache),
    # which exists for this check and nothing else. Its file says so.
    def check_kernel_cache_unported!(ast)
      decls = SpinelEbpf::KernelCache.declared_paths(ast)
      return if decls.empty?
      paths = decls.map(&:inspect).join(", ")
      raise Error,
            "`kernel_cache` is not implemented by the production codegen (#{decls.length} " \
            "declaration(s): #{paths}).\n" \
            "  Why: E188 built the kernel-cache XDP slice in the retired Ruby oracle only. The " \
            "C codegen (ADR-011 Stage 2) never carried it, and E416 re-ported the pure-XDP TCP " \
            "slice WITHOUT the kernel_cache branch. Measured E420: the generated .bpf.c contains " \
            "zero programs, the build succeeds, the binary prints \"BPF loaded and attached\", " \
            "and nothing is ever served.\n" \
            "  Fix: serve the route from userspace (examples/http_server/), or write the fast " \
            "path yourself with `def xdp__tcp_slice__<name>` (E416, one fixed response) — that " \
            "one IS in the production codegen.\n" \
            "  Not a silent no-op any more: E417 recorded the three orphaned map lookups " \
            "(bpf_kc_resp/_len/_csum); E420 removed them and refuses here instead."
    end

    # (1) attach ハンドラが ebpf-impossible で :native に落ちていたら loud に落とす。
    # attach は eBPF でしか動かない (native 実行パスが無い) ので、黙って native 化
    # すると **一切発火しない**。partition table には理由が出るが exit 0 なので AI は
    # 成功と誤読する ⇒ hard error にする。
    def check_attach_handlers_are_ebpf!(result)
      result.methods.each do |mi|
        next unless mi.tag == :native
        next unless mi.scope == :top_level
        # ebpf-impossible が原因のときだけ (force_native / __spnl_ / <main> は対象外)。
        next unless mi.flags && mi.flags.ebpf_impossible?
        attach = CodegenBpf.detect_attach(mi.method_name)
        next unless attach
        reasons = mi.flags.reasons.join("; ")
        raise Error,
              "attach handler `def #{mi.method_name}` (#{attach[:sec]}) can't be lowered to eBPF: " \
              "#{reasons}. An attach handler MUST be eBPF — there is no native execution path for a " \
              "#{attach[:kind]} hook, so this probe would silently never fire. Rewrite the body to the " \
              "eBPF subset (integers + builtins only; see `spinel-ebpf capabilities`)."
      end
    end

    # (2) E320 GAP-2 (最重大、loud-failure 違反の是正): attach 名の 1 文字 typo
    # (`kprobe_x` = 単一 `_`、正しくは `kprobe__x`) を compile 時に loud に落とす。
    #
    # 単一 `_` はどの ATTACH_PATTERNS にもマッチせず、top-level :ebpf メソッドは
    # 孤児 SEC("syscall") program に化ける — partition/codegen/clang/verifier は全緑
    # なのに **カーネルの何にも attach されず一生発火しない** (E319 で実測)。verifier
    # は「安全か」しか見ないのでこの穴は check でも捕まらなかった。ここで名前規則
    # から高確度に検出する。
    #
    # 締めすぎ回避 (2 軸ハーネス): detect_attach が既に valid とみなす名前 (= 正しい
    # `__` 形、DSL 合成名) は対象外。かつ「word + 単一 `_` + rest を `__` に直すと
    # valid attach になる」場合だけ flag する (attach_name_typo_suggestion が
    # detect_attach で検証)。corpus 403 メソッド名で false-reject 0 を実測 (E320)。
    def check_attach_name_typos!(result)
      result.methods.each do |mi|
        next unless mi.tag == :ebpf
        next unless mi.scope == :top_level
        name = mi.method_name
        next if name.nil? || name.empty?
        next if CodegenBpf.detect_attach(name)     # 既に valid attach 形 — 正当
        hit = attach_name_typo_suggestion(name)
        next unless hit
        word, suggestion = hit
        raise Error,
              "method `#{name}` looks like an attach handler but uses a single underscore after " \
              "the attach kind `#{word}`; did you mean `#{suggestion}`? A single `_` here is NOT a " \
              "valid attach prefix, so it lowers to an orphaned SEC(\"syscall\") program that is never " \
              "attached to any kernel event and never fires — yet partition/codegen/clang/verifier all " \
              "stay green. Use the double-underscore form `#{word}__<target>`, or rename it if this is " \
              "intentionally a plain (BPF-to-BPF) helper."
      end
    end

    # name が「attach word + 単一 `_` + rest」で、`__` に直すと valid attach になる
    # なら [word, suggestion] を返す (無ければ nil)。単一 fix (1 個の `_` → `__`) で
    # valid になる高確度 typo だけを対象にする (rest が `_` 始まりなら既に `__` =
    # valid 形なので除外)。長い word 優先で最良の suggestion を出す。
    def attach_name_typo_suggestion(name)
      ATTACH_WORDS.each do |w|
        prefix = "#{w}_"
        next unless name.start_with?(prefix)
        rest = name[prefix.length..]
        next if rest.nil? || rest.empty? || rest.start_with?("_")
        candidate = "#{w}__#{rest}"
        return [w, candidate] if CodegenBpf.detect_attach(candidate)
      end
      nil
    end

    # (3) E320 GAP-1: 0 引数 builtin (latency_start/latency_end) に余分な引数が
    # 渡っていたら loud に落とす。sibling の lat_start/lat_end (arity 1) との非対称
    # (C codegen が黙って引数を捨てる) を是正。成功 probe は 0 引数なので不変。
    def check_zero_arg_builtins!(ast, result)
      each_ebpf_body(result) do |mi, body_id|
        walk_calls(body_id, ast) do |nid|
          next unless ast.receiver_of(nid) < 0   # 受信なし builtin 呼出のみ
          name = ast.name_of(nid)
          next unless ZERO_ARG_STRICT.include?(name)
          n = call_arg_count(ast, nid)
          next if n.zero?
          raise Error,
                "`#{name}` expects no arguments but got #{n} in `#{mi.method_name}` — it captures the " \
                "tid key automatically, so it takes 0 args. Its siblings `lat_start`/`lat_end` take a " \
                "key argument, but `latency_start`/`latency_end` do not. Remove the argument(s)."
        end
      end
    end

    # CallNode の実引数個数 (ArgumentsNode が無ければ 0)。
    def call_arg_count(ast, nid)
      aid = ast.arguments_of(nid)
      return 0 if aid < 0
      an = ast.node(aid)
      return 0 unless an && an.type == "ArgumentsNode"
      an.arrays.fetch("arguments", []).length
    end

    # +heap: :ebpf メソッド本体に enumerable ブロック呼出があれば loud に落とす。
    def check_heap_iteration!(ast, result)
      each_ebpf_body(result) do |mi, body_id|
        walk_calls(body_id, ast) do |nid|
          name = ast.name_of(nid)
          next unless ENUMERABLE_BLOCK_METHODS.include?(name)
          next if ast.ref(nid, "block", default: -1) < 0   # ブロック付きのみ
          raise Error,
                "`.#{name} { ... }` in `#{mi.method_name}` is heap/enumerable iteration, which is " \
                "eBPF-illegal (no heap, no dynamic allocation in BPF). The only bounded loop in the " \
                "eBPF subset is `n.times { |i| ... }`. Rewrite the iteration with `n.times`."
        end
      end
    end

    # (4) 未知 builtin (typo) を did-you-mean 付きで落とす。
    def check_unknown_builtins!(unknown)
      return if unknown.empty?
      u = unknown.first
      name, method = u[:name], u[:method]
      best, dist = nearest_builtin(name)
      # 近い builtin があれば did-you-mean。閾値は名前長に応じて緩める。
      threshold = [2, (name.length / 3.0).ceil].max
      if best && dist <= threshold
        sig = Capabilities.signature_for(best)
        hint = sig[:params] ? "(#{sig[:params].join(', ')})" : "(#{sig[:arity]} args)"
        raise Error,
              "unknown builtin `#{name}` in `#{method}` — did you mean `#{best}`#{hint}? " \
              "#{sig[:summary]} (run `spinel-ebpf capabilities --json` for all #{BUILTINS.size} builtins)."
      end
      # Edit distance only bridges typos. An author who does not know the
      # vocabulary reaches for a *plausible* name instead, and that lands far
      # away in edit distance while staying close in meaning: `parent_is` is 6
      # edits from `parent_path_eq` but shares the token that matters. Measured
      # with a model authoring from errors alone: told only "unknown builtin", it
      # guessed the replacement and happened to be right. A loud error that sends
      # the reader back to guessing has done half its job.
      rel = related_builtins(name)
      if rel.any?
        listed = rel.map do |b|
          sig = Capabilities.signature_for(b)
          ps  = sig && sig[:params] ? "(#{sig[:params].join(', ')})" : ""
          "`#{b}`#{ps}"
        end
        raise Error,
              "unknown builtin `#{name}` in `#{method}` — no builtin by that name. These share a " \
              "name part with it: #{listed.join(' / ')}. If none of them is what you meant, run " \
              "`spinel-ebpf capabilities --json` for all #{BUILTINS.size} builtins."
      end
      raise Error,
            "unknown builtin/method `#{name}` in `#{method}` — not a known builtin, defined method, or " \
            "eBPF construct. Run `spinel-ebpf capabilities` (#{BUILTINS.size} builtins) or define it."
    end

    # Builtins sharing a snake_case token with `name`, best overlap first. Tokens
    # shorter than 3 chars are dropped: `is`/`to`/`of` are glue and match half
    # the registry, and a suggestion list that is always long is one nobody reads.
    def related_builtins(name, limit: 4)
      toks = name.to_s.split("_").select { |t| t.length >= 3 }
      return [] if toks.empty?
      BUILTINS.select { |b| (b.split("_") & toks).any? }
              .sort_by { |b| [-(b.split("_") & toks).size, b.length, b] }
              .first(limit)
    end

    # (5) 不完全な必須組を loud に落とす (Capabilities::REQUIRED_SETS を参照)。
    def check_required_sets!(used)
      gaps = Capabilities.missing_companions(used.keys)
      return if gaps.empty?
      g = gaps.first
      if g[:mode] == :all
        raise Error,
              "incomplete builtin set `#{g[:name]}` (#{g[:experiment]}): you use " \
              "#{g[:present].join(', ')} but not #{g[:missing].join(', ')}. These builtins only work " \
              "as a set — #{g[:why]} Add the missing hook(s), or remove the ones you have."
      else
        raise Error,
              "`#{g[:trigger]}` (#{g[:experiment]}) needs #{g[:missing].join(', ')} to have any effect — " \
              "#{g[:why]} Add #{g[:missing].join(', ')}, or remove `#{g[:trigger]}`."
      end
    end

    # ---------- 内部ヘルパー ----------

    # 全 :ebpf メソッドを 1 回 walk し、(a) 使用中 builtin -> [method,...]、
    # (b) 未知の受信なし呼出 [{name:, method:}] を集める。
    #
    # chain accessor の base (`pkt.l4.proto` の `pkt`) は「受信なし CallNode だが
    # 別 CallNode の receiver」= codegen の accessor が処理する正当形。builtin/typo
    # は leaf 呼出 (誰の receiver でもない) なので、**receiver 位置の call は unknown
    # 判定から除外** (E317 の 2 軸ハーネス: 正当な chain accessor を弾かない)。
    def scan_ebpf_calls(ast, result, extra_builtins = [])
      known = method_name_set(result)
      known.merge(extra_builtins)   # E456: target-profile allowlist names are known there
      # E392 (P011 S3): a declared `param :x` is read as a bare name, which prism
      # gives us as a receiver-less CallNode — indistinguishable from a typo
      # unless we know the declarations. Read from the same AST the codegen reads,
      # so "known here" and "lowerable there" cannot drift.
      known.merge(SpinelEbpf::Param.declarations(ast).map(&:name))
      used = Hash.new { |h, k| h[k] = [] }
      candidates = []          # [{ nid:, name:, method: }] receiver-less unknowns
      receiver_ids = Set.new   # 他 CallNode の receiver になっている node id
      each_ebpf_body(result) do |mi, body_id|
        walk_calls(body_id, ast) do |nid|
          rid = ast.receiver_of(nid)
          receiver_ids << rid if rid >= 0
          next unless rid < 0                      # builtin / bpf-to-bpf は受信なし
          name = ast.name_of(nid)
          next if name.nil? || name.empty?
          if BUILTINS.include?(name)
            used[name] << mi.method_name
          elsif known.include?(name) || CONTROL_NAMES.include?(name) || BINARY_OP_NAMES.include?(name)
            # 定義済メソッド (bpf-to-bpf) / control / 二項演算 — 既知、無視
          else
            candidates << { nid: nid, name: name, method: mi.method_name }
          end
        end
      end
      # chain accessor の base (receiver 位置) は除外。
      unknown = candidates.reject { |c| receiver_ids.include?(c[:nid]) }
      [used, unknown]
    end

    BINARY_OP_NAMES = CodegenBpf::MethodEmitter::BINARY_OPS.to_set.freeze

    # result 内の全メソッド名 (bare + dsl 元名) の集合。bpf-to-bpf 呼出の解決に使う。
    # 広めに取る (permissive) — 誤検出で正当な呼出を弾くより did-you-mean を逃す方が安全。
    def method_name_set(result)
      s = Set.new
      result.methods.each do |m|
        s << m.method_name if m.method_name
        s << m.dsl_orig_name if m.dsl_orig_name
      end
      s
    end

    def each_ebpf_body(result)
      result.methods.each do |mi|
        next unless mi.tag == :ebpf
        next if mi.body_id.nil? || mi.body_id < 0
        yield mi, mi.body_id
      end
    end

    # body_id 以下の CallNode を yield (nested def/class/module には入らない;
    # partition の walk と同じガード)。
    def walk_calls(body_id, ast, &blk)
      visited = {}
      stack = [body_id]
      until stack.empty?
        nid = stack.pop
        next if nid.nil? || !nid.is_a?(Integer) || nid < 0
        next if visited[nid]
        visited[nid] = true
        node = ast.node(nid)
        next unless node
        case node.type
        when "DefNode", "ClassNode", "ModuleNode"
          next   # 別メソッドとして解析される — 二重カウント回避
        when "CallNode"
          blk.call(nid)
        end
        # refs は Integer 値のみ辿る (IntegerNode#value=0 を node 0 と誤認しない)。
        node.refs.each_value { |c| stack << c if c.is_a?(Integer) && c >= 0 }
        node.arrays.each_value { |arr| arr.each { |c| stack << c if c.is_a?(Integer) && c >= 0 } }
      end
    end

    # 依存なしの Levenshtein 距離。
    def levenshtein(a, b)
      return b.length if a.empty?
      return a.length if b.empty?
      prev = (0..b.length).to_a
      a.each_char.with_index do |ca, i|
        cur = [i + 1]
        b.each_char.with_index do |cb, j|
          cost = ca == cb ? 0 : 1
          cur << [cur[j] + 1, prev[j + 1] + 1, prev[j] + cost].min
        end
        prev = cur
      end
      prev[b.length]
    end

    # name に最も近い builtin と距離を返す [best, dist] (BUILTINS 空なら [nil, ∞])。
    def nearest_builtin(name)
      best = nil
      best_d = Float::INFINITY
      BUILTINS.each do |b|
        d = levenshtein(name, b)
        if d < best_d
          best_d = d
          best = b
        end
      end
      [best, best_d]
    end
  end
end
