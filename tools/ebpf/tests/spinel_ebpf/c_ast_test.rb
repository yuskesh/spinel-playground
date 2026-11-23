# frozen_string_literal: true

require "minitest/autorun"
require "spinel_ebpf/c_ast"

# ADR-008 Phase 0: C-AST(CExpr)+ 単一 CPrinter の単体検証。
#   (1) 一次式 / 呼び出し / キャスト / 二項の印字
#   (2) precedence に基づく**最小括弧付け**の能力(後の Phase で防御的括弧を落とす土台)
#   (3) 現 codegen の pure-expression builtin 5 種を C-AST で組むと、文字列が
#       **byte-identical** に再現できること(統合の回帰安全網がこの単体で先取り確認できる)
class CAstTest < Minitest::Test
  C = SpinelEbpf::CodegenBpf::CAst

  # ---------- (1) 一次式 ----------

  def test_literal_and_id_and_raw
    assert_equal "32", C.lit("32").to_c
    assert_equal "x", C.id("x").to_c
    assert_equal "already(rendered)", C.raw("already(rendered)").to_c
  end

  def test_paren_always_wraps
    assert_equal "(x)", C.paren(C.id("x")).to_c
    assert_equal "((x))", C.paren(C.paren(C.id("x"))).to_c
  end

  def test_call_no_args_and_args
    assert_equal "f()", C.call("f").to_c
    assert_equal "g(1, x)", C.call("g", C.lit("1"), C.id("x")).to_c
  end

  def test_field_dot_and_arrow
    assert_equal "p.field", C::CField.new(C.id("p"), "field").to_c
    assert_equal "p->field", C::CField.new(C.id("p"), "field", arrow: true).to_c
  end

  # ---------- (2) precedence → 最小括弧 ----------

  def test_binop_no_parens_when_not_needed
    # a + b * c  : * は + より強い → 右子に括弧不要
    expr = C.binop("+", C.id("a"), C.binop("*", C.id("b"), C.id("c")))
    assert_equal "a + b * c", expr.to_c
  end

  def test_binop_parenthesizes_weaker_child
    # (a + b) * c : + は * より弱い左子 → 括弧
    expr = C.binop("*", C.binop("+", C.id("a"), C.id("b")), C.id("c"))
    assert_equal "(a + b) * c", expr.to_c
  end

  def test_left_assoc_stays_flat_but_right_group_kept
    # a - b - c は平坦、a - (b - c) は右子同優先で括弧維持
    flat = C.binop("-", C.binop("-", C.id("a"), C.id("b")), C.id("c"))
    assert_equal "a - b - c", flat.to_c
    grouped = C.binop("-", C.id("a"), C.binop("-", C.id("b"), C.id("c")))
    assert_equal "a - (b - c)", grouped.to_c
  end

  def test_cast_parenthesizes_only_weaker_operand
    # (__u32)f()  : 呼び出しはキャストより強い → 括弧不要
    assert_equal "(__u32)f()", C.cast("__u32", C.call("f")).to_c
    # (__s64)(a >> b) : 二項はキャストより弱い → 括弧
    shifted = C.cast("__s64", C.binop(">>", C.id("a"), C.id("b")))
    assert_equal "(__s64)(a >> b)", shifted.to_c
  end

  def test_cast_chain_no_double_parens
    # (__s64)(__u32)x : キャスト連鎖は括弧不要
    expr = C.cast("__s64", C.cast("__u32", C.id("x")))
    assert_equal "(__s64)(__u32)x", expr.to_c
  end

  def test_unknown_binop_raises
    assert_raises(ArgumentError) { C.binop("@@", C.id("a"), C.id("b")) }
  end

  # ---------- (3) 現 builtin の byte-identical 再現 ----------
  # codegen_bpf.rb の現出力文字列(防御的外側括弧つき)を C-AST で完全再現する。
  # 統合(builtin が .to_c を返す)が byte-identical であることを単体で保証する。

  def test_cpu_id_byte_identical
    # 現: ((__s64)bpf_get_smp_processor_id())
    expr = C.s64(C.call("bpf_get_smp_processor_id"))
    assert_equal "((__s64)bpf_get_smp_processor_id())", expr.to_c
  end

  def test_cgroup_id_byte_identical
    # E302: ((__s64)bpf_get_current_cgroup_id()) — k8s pod 相関の cgroup id 値 builtin
    expr = C.s64(C.call("bpf_get_current_cgroup_id"))
    assert_equal "((__s64)bpf_get_current_cgroup_id())", expr.to_c
  end

  def test_ktime_ns_byte_identical
    # 現: ((__s64)bpf_ktime_get_ns())
    expr = C.s64(C.call("bpf_ktime_get_ns"))
    assert_equal "((__s64)bpf_ktime_get_ns())", expr.to_c
  end

  def test_tgid_pid_byte_identical
    # 現: ((__s64)(bpf_get_current_pid_tgid() >> 32))
    expr = C.s64(C.paren(C.binop(">>", C.call("bpf_get_current_pid_tgid"), C.lit("32"))))
    assert_equal "((__s64)(bpf_get_current_pid_tgid() >> 32))", expr.to_c
  end

  def test_tid_byte_identical
    # 現: ((__s64)(__u32)bpf_get_current_pid_tgid())
    expr = C.s64(C.cast("__u32", C.call("bpf_get_current_pid_tgid")))
    assert_equal "((__s64)(__u32)bpf_get_current_pid_tgid())", expr.to_c
  end

  # ---------- Phase 1: コア式構文サイト(operand は未移行 lowering の CRaw) ----------

  def test_phase1_binop_callnode_byte_identical
    # 現: "(#{lhs} #{name} #{rhs})" — operand は文字列、CRaw で包む
    expr = C.paren(C.binop("+", C.raw("a"), C.raw("b")))
    assert_equal "(a + b)", expr.to_c
    cmp = C.paren(C.binop("==", C.raw("x"), C.raw("5")))
    assert_equal "(x == 5)", cmp.to_c
  end

  def test_phase1_or_and_byte_identical
    # 現: "(#{l} || #{r})" / "(#{l} && #{r})"
    or_expr = C.paren(C.binop("||", C.raw("(a > 0)"), C.raw("(b < 10)")))
    assert_equal "((a > 0) || (b < 10))", or_expr.to_c
    and_expr = C.paren(C.binop("&&", C.raw("p"), C.raw("q")))
    assert_equal "(p && q)", and_expr.to_c
  end

  def test_phase1_parentheses_node_byte_identical
    # 現: "(#{inner})"
    assert_equal "((flags & 4))", C.paren(C.raw("(flags & 4)")).to_c
  end

  def test_phase1_divu_byte_identical
    # 現: "((__s64)((__u64)(#{a}) / (__u64)(#{b})))"
    a = "x"; b = "y"
    expr = C.s64(
      C.paren(
        C.binop("/",
                C.cast("__u64", C.paren(C.raw(a))),
                C.cast("__u64", C.paren(C.raw(b))))
      )
    )
    assert_equal "((__s64)((__u64)(x) / (__u64)(y)))", expr.to_c
  end

  def test_phase1_flat_call_wrappers_byte_identical
    assert_equal "spnl_task_load()", C.call("spnl_task_load").to_c
    assert_equal "spnl_fifo_pop()", C.call("spnl_fifo_pop").to_c
    assert_equal "spnl_task_store(v)", C.call("spnl_task_store", C.raw("v")).to_c
    assert_equal "spnl_mim_inc(g, k)", C.call("spnl_mim_inc", C.raw("g"), C.raw("k")).to_c
  end

  # ---------- Phase 2: 文(CStmt) ----------

  def test_stmt_raw
    assert_equal "if (x) {", C.raw_stmt("if (x) {").to_c
  end

  def test_stmt_expr_byte_identical
    # 現: @lines << "spnl_latency_start();"
    assert_equal "spnl_latency_start();", C.expr_stmt(C.call("spnl_latency_start")).to_c
    # 現: @lines << "spnl_lock_edge(#{a}, #{b});"
    assert_equal "spnl_lock_edge(a, b);",
                 C.expr_stmt(C.call("spnl_lock_edge", C.raw("a"), C.raw("b"))).to_c
  end

  def test_stmt_decl_byte_identical
    # 現: @lines << "__s64 #{name} = 0;"
    assert_equal "__s64 x = 0;", C.decl("__s64", "x", C.lit("0")).to_c
    # init 無し宣言
    assert_equal "__s64 y;", C.decl("__s64", "y").to_c
  end

  def test_stmt_return_byte_identical
    # 現: @lines << "return #{last_expr};"
    assert_equal "return _if1;", C.ret(C.raw("_if1")).to_c
    assert_equal "return 0;", C.ret(C.raw("0")).to_c
    assert_equal "return;", C.ret.to_c
  end

  # ---------- Phase 2 Step 2: CBlock / CIf 構造的インデント ----------

  def test_block_flat_indent
    blk = C.block([C.decl("__s64", "x", C.lit("0")), C.ret(C.raw("x"))])
    assert_equal ["__s64 x = 0;", "return x;"], C.render_block(blk, 0)
    assert_equal ["    __s64 x = 0;", "    return x;"], C.render_block(blk, 1)
  end

  def test_nested_if_byte_identical_to_sign_inner
    # 現 sign_inner の本体(@lines 段階 = depth0、呼び出し側 +4 前)を構造的に再現。
    blk = C.block([
      C.decl("__s64", "_if1", C.lit("0")),
      C.cif(C.raw("x > 0"),
            C.block([C.expr_stmt(C.raw("_if1 = 1"))]),
            C.block([
              C.decl("__s64", "_if2", C.lit("0")),
              C.cif(C.raw("x < 0"),
                    C.block([C.expr_stmt(C.raw("_if2 = -1"))]),
                    C.block([C.expr_stmt(C.raw("_if2 = 0"))])),
              C.expr_stmt(C.raw("_if1 = _if2"))
            ]))
    ])
    expected = [
      "__s64 _if1 = 0;",
      "if (x > 0) {",
      "    _if1 = 1;",
      "} else {",
      "    __s64 _if2 = 0;",
      "    if (x < 0) {",
      "        _if2 = -1;",
      "    } else {",
      "        _if2 = 0;",
      "    }",
      "    _if1 = _if2;",
      "}"
    ]
    assert_equal expected, C.render_block(blk, 0)
  end

  def test_if_without_else
    blk = C.block([C.cif(C.raw("c"), C.block([C.expr_stmt(C.raw("f()"))]))])
    assert_equal ["if (c) {", "    f();", "}"], C.render_block(blk, 0)
  end

  # ---------- Phase 4 prep: CBraceBlock (spnl_emit ringbuf scope) ----------

  def test_brace_block_byte_identical_to_spnl_emit
    # 現 spnl_emit の @lines 段階(depth0)を構造的に再現。
    evar = "_e1"
    blk = C.brace_block(C.block([
      C.decl("struct u_event", "*#{evar}",
             C.call("bpf_ringbuf_reserve", C.raw("&u_events"), C.raw("sizeof(*#{evar})"), C.raw("0"))),
      C.cif(C.raw(evar), C.block([
        C.expr_stmt(C.raw("#{evar}->hdr.type = SPNL_EVT_USER_BASE")),
        C.expr_stmt(C.raw("#{evar}->value = x + 1")),
        C.expr_stmt(C.call("bpf_ringbuf_submit", C.raw(evar), C.raw("0"))),
      ]))
    ]))
    expected = [
      "{",
      "    struct u_event *_e1 = bpf_ringbuf_reserve(&u_events, sizeof(*_e1), 0);",
      "    if (_e1) {",
      "        _e1->hdr.type = SPNL_EVT_USER_BASE;",
      "        _e1->value = x + 1;",
      "        bpf_ringbuf_submit(_e1, 0);",
      "    }",
      "}"
    ]
    assert_equal expected, C.render_stmt(blk, 0)
  end

  # ---------- Phase 4: linear-use / ownership (structure-consuming pass) ----------

  def test_ringbuf_leaks_none_when_submitted
    blk = C.brace_block(C.block([
      C.decl("struct u_event", "*_e1",
             C.call("bpf_ringbuf_reserve", C.raw("&u_events"), C.raw("sizeof(*_e1)"), C.raw("0"))),
      C.cif(C.raw("_e1"), C.block([
        C.expr_stmt(C.call("bpf_ringbuf_submit", C.raw("_e1"), C.raw("0"))),
      ]))
    ]))
    assert_empty C.ringbuf_leaks(blk), "reserve followed by submit must not leak"
  end

  def test_ringbuf_leaks_detected_when_not_released
    # reserve but never submit/discard -> leak (aya #[must_use] / E096 ref-leak class).
    blk = C.brace_block(C.block([
      C.decl("struct u_event", "*_e1",
             C.call("bpf_ringbuf_reserve", C.raw("&u_events"), C.raw("sizeof(*_e1)"), C.raw("0"))),
      C.cif(C.raw("_e1"), C.block([
        C.expr_stmt(C.raw("_e1->value = 7")),
        # no submit/discard!
      ]))
    ]))
    assert_equal ["_e1"], C.ringbuf_leaks(blk)
  end

  def test_ringbuf_leaks_discard_also_releases
    blk = C.block([
      C.decl("struct u_event", "*_e2",
             C.call("bpf_ringbuf_reserve", C.raw("&u_events"), C.raw("sizeof(*_e2)"), C.raw("0"))),
      C.expr_stmt(C.call("bpf_ringbuf_discard", C.raw("_e2"), C.raw("0"))),
    ])
    assert_empty C.ringbuf_leaks(blk)
  end
end
