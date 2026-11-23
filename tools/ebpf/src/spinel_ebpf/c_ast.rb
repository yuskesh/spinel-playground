# frozen_string_literal: true

# C-AST — ADR-008 Phase 0 (構造化 codegen の最小土台)
#
# 現状の codegen_bpf.rb は「Ruby AST → C 文字列テンプレート展開」で、式の値が
# 文字列として流れる(型が乗らない / 防御的括弧を手で書く / 式と文の境界が曖昧)。
# ADR-008 はこれを「typed C-AST + 明示的型/所有権 IR」へ段階移行する。
#
# 本ファイルは Phase 0 = **式(CExpr)だけ**の薄い C-AST と、唯一の印字器
# `CPrinter`(優先順位→自動括弧)を提供する。文(CStmt)/宣言(CDecl)は後続 Phase。
#
# 設計方針:
# - **byte-identical 安全網**: Phase 0 では既存出力をバイト一致で再現する。現コードが
#   持つ「防御的な外側括弧」は `CParen` で**明示的に**モデル化して再現する(後の意図的な
#   Phase で precedence に基づき冗長な括弧を落とす)。
# - **自動括弧の能力は別途実証**: `CPrinter` は precedence に基づく最小括弧付けを実装し、
#   c_ast_test.rb で単体検証する。Phase 0 の統合では byte-identical のため `CParen` を使う。
# - **エスケープハッチ `CRaw`**: 未移行の lowering が返す C 文字列をそのまま木に埋め込む。
# - **node-id 貼付**: 各ノードは生成元 Ruby node-id を `nid` で保持できる(ADR-008:
#   verifier reject / 境界 ABI 違反を `foo.rb:42` と名指しする土台。Phase 0 では未使用)。

module SpinelEbpf
  module CodegenBpf
    module CAst
      # 演算子優先順位(値が大きいほど強く束縛)。CPrinter が最小括弧付けに使う。
      # 一次式(CLit/CId/CCall/CParen/CField/CRaw)は PRIMARY_PREC で括弧不要。
      BINOP_PREC = {
        "||" => 20, "&&" => 25, "|" => 30, "^" => 35, "&" => 40,
        "==" => 45, "!=" => 45,
        "<" => 50, "<=" => 50, ">" => 50, ">=" => 50,
        "<<" => 55, ">>" => 55,
        "+" => 60, "-" => 60,
        "*" => 70, "/" => 70, "%" => 70
      }.freeze

      CAST_PREC    = 80
      UNARY_PREC   = 80
      POSTFIX_PREC = 90
      PRIMARY_PREC = 100

      # 式の基底。`nid` は生成元 Ruby node-id(合成式では nil)。
      class CExpr
        attr_reader :nid
        def initialize(nid: nil)
          @nid = nid
        end

        # 既定の印字器で C 文字列化(統合点。下流は文字列を受け取る)。
        def to_c
          CPrinter.new.expr(self)
        end

        # 親が括弧要否を判断するための優先順位。
        def prec
          PRIMARY_PREC
        end
      end

      # 整数リテラル / そのまま出すトークン(例 "32" / "TCP_FLAG_RST")。
      class CLit < CExpr
        attr_reader :text
        def initialize(text, nid: nil)
          super(nid: nid)
          @text = text.to_s
        end
      end

      # 識別子(ローカル変数 / map 名 等)。
      class CId < CExpr
        attr_reader :name
        def initialize(name, nid: nil)
          super(nid: nid)
          @name = name.to_s
        end
      end

      # エスケープハッチ: 既に C 文字列化済みの断片を一次式として埋め込む。
      # Phase 0 で未移行 lowering の戻り値を木に載せるために使う。
      class CRaw < CExpr
        attr_reader :text
        def initialize(text, nid: nil)
          super(nid: nid)
          @text = text.to_s
        end
      end

      # 関数呼び出し callee(args...)。後置 = 高優先。
      class CCall < CExpr
        attr_reader :callee, :args
        def initialize(callee, args = [], nid: nil)
          super(nid: nid)
          @callee = callee.to_s
          @args = args
        end

        def prec
          POSTFIX_PREC
        end
      end

      # C キャスト (type)operand。前置 = キャスト優先。
      class CCast < CExpr
        attr_reader :type, :operand
        def initialize(type, operand, nid: nil)
          super(nid: nid)
          @type = type.to_s
          @operand = operand
        end

        def prec
          CAST_PREC
        end
      end

      # 単項前置 <op>operand(例 "!" / "-" / "~")。
      class CUnary < CExpr
        attr_reader :op, :operand
        def initialize(op, operand, nid: nil)
          super(nid: nid)
          @op = op.to_s
          @operand = operand
        end

        def prec
          UNARY_PREC
        end
      end

      # 二項 lhs <op> rhs(C は左結合)。
      class CBinop < CExpr
        attr_reader :op, :lhs, :rhs
        def initialize(op, lhs, rhs, nid: nil)
          super(nid: nid)
          raise ArgumentError, "unknown C binop #{op.inspect}" unless BINOP_PREC.key?(op.to_s)

          @op = op.to_s
          @lhs = lhs
          @rhs = rhs
        end

        def prec
          BINOP_PREC.fetch(@op)
        end
      end

      # メンバアクセス recv.field / recv->field。後置 = 高優先。
      class CField < CExpr
        attr_reader :recv, :field, :arrow
        def initialize(recv, field, arrow: false, nid: nil)
          super(nid: nid)
          @recv = recv
          @field = field.to_s
          @arrow = arrow
        end

        def prec
          POSTFIX_PREC
        end
      end

      # 明示的なグルーピング括弧。常に "(inner)" を出す。Phase 0 で現コードの
      # 防御的括弧を byte-identical に再現するために使う(後の Phase で冗長分を除去)。
      class CParen < CExpr
        attr_reader :inner
        def initialize(inner, nid: nil)
          super(nid: nid)
          @inner = inner
        end
      end

      # ---- 文(CStmt) — ADR-008 Phase 2。1 文 = 1 行を表す(indent は呼び出し側 / 後続
      # Phase の CBlock が担当)。CPrinter#stmt が末尾 `;` を含めて 1 行を返す。
      class CStmt
        attr_reader :nid
        def initialize(nid: nil)
          @nid = nid
        end

        def to_c
          CPrinter.new.stmt(self)
        end
      end

      # 既に C 文字列化済みの 1 行(末尾 `;`/`{`/`}` 等を含む)。未移行 lowering の
      # エスケープハッチ。
      class CRawStmt < CStmt
        attr_reader :text
        def initialize(text, nid: nil)
          super(nid: nid)
          @text = text.to_s
        end
      end

      # 式文 `<expr>;`。副作用 builtin の呼び出し文など。
      class CExprStmt < CStmt
        attr_reader :expr
        def initialize(expr, nid: nil)
          super(nid: nid)
          @expr = expr
        end
      end

      # 宣言 `<type> <name>;` または `<type> <name> = <init>;`。
      class CDecl < CStmt
        attr_reader :type, :name, :init
        def initialize(type, name, init = nil, nid: nil)
          super(nid: nid)
          @type = type.to_s
          @name = name.to_s
          @init = init
        end
      end

      # `return <expr>;` または `return;`。
      class CReturn < CStmt
        attr_reader :expr
        def initialize(expr = nil, nid: nil)
          super(nid: nid)
          @expr = expr
        end
      end

      # 文の並び(ブロック本体)。`CPrinter#block_lines(block, depth)` が深さに応じた
      # インデントで複数行に展開する。後付け文字列インデント(`"    " + line`)を
      # **構造的インデント**で置き換えるための器(ADR-008 Phase 2 Step 2)。
      class CBlock < CStmt
        attr_reader :stmts
        def initialize(stmts = [], nid: nil)
          super(nid: nid)
          @stmts = stmts
        end
      end

      # `if (cond) { then } [else { else }]`。then/else は CBlock。CPrinter が
      # depth に基づいて構造的にインデント(後付けインデント不要)。
      class CIf < CStmt
        attr_reader :cond, :then_block, :else_block
        def initialize(cond, then_block, else_block = nil, nid: nil)
          super(nid: nid)
          @cond = cond
          @then_block = then_block
          @else_block = else_block
        end
      end

      # 裸のスコープブロック `{ <body> }`(body は CBlock)。spnl_emit 等の
      # ringbuf スコープに使う。CPrinter が depth で構造的にインデント。
      class CBraceBlock < CStmt
        attr_reader :body
        def initialize(body, nid: nil)
          super(nid: nid)
          @body = body
        end
      end

      # 唯一の印字器。式は優先順位→最小括弧、文は末尾 `;` 付き 1 行。indent は扱わない。
      class CPrinter
        def expr(node)
          case node
          when CLit   then node.text
          when CId    then node.name
          when CRaw   then node.text
          when CParen then "(#{expr(node.inner)})"
          when CCall  then "#{node.callee}(#{node.args.map { |a| expr(a) }.join(', ')})"
          when CField then "#{operand(node.recv, POSTFIX_PREC)}#{node.arrow ? '->' : '.'}#{node.field}"
          when CCast  then "(#{node.type})#{cast_operand(node.operand)}"
          when CUnary then "#{node.op}#{operand(node.operand, UNARY_PREC)}"
          when CBinop then binop(node)
          else raise ArgumentError, "CPrinter: unknown node #{node.class}"
          end
        end

        # 文を末尾 `;` 付き 1 行で印字(indent は付けない)。
        def stmt(node)
          case node
          when CRawStmt  then node.text
          when CExprStmt then "#{val(node.expr)};"
          when CReturn   then node.expr.nil? ? "return;" : "return #{val(node.expr)};"
          when CDecl
            node.init.nil? ? "#{node.type} #{node.name};" : "#{node.type} #{node.name} = #{val(node.init)};"
          else raise ArgumentError, "CPrinter: unknown stmt #{node.class}"
          end
        end

        INDENT = "    "

        # ブロックを depth に応じたインデントで複数行(Array<String>)に展開。
        def block_lines(block, depth)
          block.stmts.flat_map { |s| stmt_lines(s, depth) }
        end

        # 1 文(または入れ子ブロック/if/brace)を depth インデントで複数行に。
        def stmt_lines(node, depth)
          case node
          when CIf         then if_lines(node, depth)
          when CBlock      then block_lines(node, depth)
          when CBraceBlock then brace_lines(node, depth)
          else "#{INDENT * depth}#{stmt(node)}".split("\n", -1)
          end
        end

        private

        def if_lines(node, depth)
          pad = INDENT * depth
          out = ["#{pad}if (#{val(node.cond)}) {"]
          out.concat(block_lines(node.then_block, depth + 1))
          if node.else_block
            out << "#{pad}} else {"
            out.concat(block_lines(node.else_block, depth + 1))
          end
          out << "#{pad}}"
          out
        end

        def brace_lines(node, depth)
          pad = INDENT * depth
          ["#{pad}{"] + block_lines(node.body, depth + 1) + ["#{pad}}"]
        end

        # CExpr なら印字、文字列等はそのまま(未移行 lowering の戻り文字列を許容)。
        def val(x)
          x.is_a?(CExpr) ? expr(x) : x.to_s
        end

        def binop(node)
          p = node.prec
          # 左結合: 左子は優先順位が厳密に低いとき、右子は低いか等しいとき括弧。
          # これで a-b-c は平坦、a-(b-c) は括弧維持。
          ls = paren_if(node.lhs, node.lhs.prec < p)
          rs = paren_if(node.rhs, node.rhs.prec <= p)
          "#{ls} #{node.op} #{rs}"
        end

        # キャストの被演算子: キャスト/単項/後置/一次は >= なので括弧不要、
        # 二項(より弱い)だけ括弧。
        def cast_operand(operand)
          paren_if(operand, operand.prec < CAST_PREC)
        end

        def operand(child, parent_prec)
          paren_if(child, child.prec < parent_prec)
        end

        def paren_if(child, cond)
          cond ? "(#{expr(child)})" : expr(child)
        end
      end

      module_function

      # --- 簡潔なビルダ(builtin から読みやすく組むため) ---

      def lit(text, nid: nil)
        CLit.new(text, nid: nil)
      end

      def id(name, nid: nil)
        CId.new(name, nid: nil)
      end

      def raw(text, nid: nil)
        CRaw.new(text, nid: nil)
      end

      def call(callee, *args, nid: nil)
        CCall.new(callee, args, nid: nil)
      end

      def cast(type, operand, nid: nil)
        CCast.new(type, operand, nid: nil)
      end

      def binop(op, lhs, rhs, nid: nil)
        CBinop.new(op, lhs, rhs, nid: nil)
      end

      def paren(inner, nid: nil)
        CParen.new(inner, nid: nil)
      end

      # 多用される防御的キャスト ((__s64) x) を 1 つに。現コードが builtin 戻り値を
      # 大式に埋め込む際の外側括弧を byte-identical に再現する。
      def s64(operand)
        paren(cast("__s64", operand))
      end

      # --- 文ビルダ ---

      def raw_stmt(text, nid: nil)
        CRawStmt.new(text, nid: nil)
      end

      def expr_stmt(expr, nid: nil)
        CExprStmt.new(expr, nid: nil)
      end

      def decl(type, name, init = nil, nid: nil)
        CDecl.new(type, name, init, nid: nil)
      end

      def ret(expr = nil, nid: nil)
        CReturn.new(expr, nid: nil)
      end

      def block(stmts = [], nid: nil)
        CBlock.new(stmts, nid: nil)
      end

      def cif(cond, then_block, else_block = nil, nid: nil)
        CIf.new(cond, then_block, else_block, nid: nil)
      end

      def brace_block(body, nid: nil)
        CBraceBlock.new(body, nid: nil)
      end

      # ブロックを depth インデントで Array<String> に展開(構造的インデント)。
      def render_block(block, depth = 0)
        CPrinter.new.block_lines(block, depth)
      end

      # 1 文(CBlock/CIf/CBraceBlock 含む)を depth インデントで Array<String> に。
      def render_stmt(stmt, depth = 0)
        CPrinter.new.stmt_lines(stmt, depth)
      end

      # --- ADR-008 Phase 4: linear-use / 所有権解析(構造を消費する最初の pass) ---
      #
      # bpf_ringbuf の reserve→submit 規律を C-AST の構造から検証する。
      # aya の `RingBufEntry #[must_use]` / E096 の skb ref leak と同じ「取得した
      # リソースは必ず解放する」= linear-use。`bpf_ringbuf_reserve` の戻り値を束縛した
      # local が、同じ木の中で `bpf_ringbuf_submit` / `bpf_ringbuf_discard` で解放されて
      # いなければ **leak** と判定する(戻り値 = leak した local 名の配列、空 = OK)。
      # ADR-007 の境界 ABI(own/borrow・linear-use)の基盤メカニズム。
      RINGBUF_ACQUIRE = "bpf_ringbuf_reserve"
      RINGBUF_RELEASE = %w[bpf_ringbuf_submit bpf_ringbuf_discard].freeze

      def ringbuf_leaks(stmt)
        reserved = []   # [name] declared from bpf_ringbuf_reserve
        released = []   # [name] passed to submit/discard
        walk_stmts(stmt) do |s|
          case s
          when CDecl
            reserved << strip_declarator(s.name) if calls?(s.init, RINGBUF_ACQUIRE)
          when CExprStmt
            e = s.expr
            if e.is_a?(CCall) && RINGBUF_RELEASE.include?(e.callee) && e.args.first
              released << expr_text(e.args.first)
            end
          end
        end
        reserved.uniq - released
      end

      # CStmt 木を walk(CBlock/CBraceBlock/CIf を再帰)、各文を yield。
      def walk_stmts(node, &blk)
        case node
        when CBlock      then node.stmts.each { |s| walk_stmts(s, &blk) }
        when CBraceBlock then walk_stmts(node.body, &blk)
        when CIf
          blk.call(node)
          walk_stmts(node.then_block, &blk)
          walk_stmts(node.else_block, &blk) if node.else_block
        when CStmt then blk.call(node)
        end
      end

      def calls?(expr, callee)
        expr.is_a?(CCall) && expr.callee == callee
      end

      # `*p` / `p` どちらの宣言子でも local 名 `p` を返す。
      def strip_declarator(name)
        name.to_s.sub(/\A\*+/, "")
      end

      def expr_text(expr)
        expr.is_a?(CExpr) ? expr.to_c : expr.to_s
      end
    end
  end
end
