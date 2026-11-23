package frontend

// 早い return の guard (E073): program の直下の文 `return BPF::XDP_X if c` / `unless c` (腕が return 1 つだけの if / unless — else 無し)。
// 後ろの文を否定の条件の腕に包む: Stmt{Kind: "guard", Cond: c, Else: <後ろの文>, Op: <判定>}。lower は
// `%f = ebpf.if %c -> i1 { true } else { <後ろ>; <後ろの guard の fired か false> }` と最後の `ebpf.verdict.if %f "<X>" else "<V>"`。
// bpf-mlir の判定は program の直下だけ・verdict.if は 2 つの判定だけ — 全ての guard の判定は同じ X (違えば SB008)。
// 後ろの文は否定の条件で狭めた環境で解析 (P017 — narrowEnv)。腕の中・loop の中・値の無い return は verdict の walk が今どおり SB008。
// ownership: ring の output は 1 つの文の中で予約と submit が閉じ、借用と窓は腕の中だけ — program の直下の guard を跨ぐ region は無い。

// guardOf は n が guard (`return BPF::XDP_X if c` の if / unless — 腕が return 1 つ、else 無し) なら その ReturnNode を返す。
func (c *progCtx) guardOf(n *Node) *Node {
	if n.Type != "IfNode" && n.Type != "UnlessNode" {
		return nil
	}
	if n.Type == "IfNode" && c.a.ref(n, "subsequent") != nil || n.Type == "UnlessNode" && c.a.ref(n, "else_clause") != nil {
		return nil
	}
	st := c.a.ref(n, "statements")
	if st == nil || len(c.a.arr(st, "body")) != 1 {
		return nil
	}
	r := c.a.arr(st, "body")[0]
	if r.Type != "ReturnNode" {
		return nil
	}
	return r
}

// guardStmts は program の直下の文の並び (最後の判定の前まで)。最初の guard で分け、後ろを guard の Else に (入れ子)。
func (c *progCtx) guardStmts(ns []*Node) []Stmt {
	for i, n := range ns {
		r := c.guardOf(n)
		if r == nil {
			continue
		}
		out := c.stmts(ns[:i], "")
		c.guardReturns[r] = true
		var as []*Node
		if args := c.a.ref(r, "arguments"); args != nil {
			as = c.a.arr(args, "arguments")
		}
		table := verdictsOf(c.prog.Kind) // P019 E076: sched_cls は BPF::TC_* (他の kind の定数は program の入口の walk が SB028)
		if len(as) != 1 {
			c.add(Rejected, SB008ProgramShape, r, "a guard `return` must return one %s (%s)", verdictWant(c.prog.Kind, "BPF::XDP_* constant"), verdictWant(c.prog.Kind, "`return BPF::XDP_DROP if cond`"))
			return out
		}
		cn := constName(c.a, as[0])
		v := ""
		if c.prog.Kind == "fmod_ret" && c.isFmodReturn(as[0]) { // P028 E144: `return BPF.fmod_return(lit) if c` — 終端の select の値
			lit, ok := c.fmodGuardValue(r, as[0])
			if !ok {
				return out
			}
			if c.prog.FmodGuard != nil && c.prog.FmodGuard.Cmp(lit) != 0 {
				c.add(Rejected, SB008ProgramShape, r, "the early returns return BPF.fmod_return(%s) and BPF.fmod_return(%s) — the terminal arith.select chooses between only two values (the early one and the last one), so every guard returns the same value", c.prog.FmodGuard, lit)
				return out
			}
			c.prog.FmodGuard, v = lit, "value"
		} else if as[0].Type != "ConstantPathNode" || len(cn) < 5 || cn[:5] != "BPF::" || table[cn[5:]] == "" {
			c.add(Rejected, SB008ProgramShape, r, "a guard `return` must return one %s, got %s", verdictWant(c.prog.Kind, "BPF::XDP_* constant"), as[0].Type)
			return out
		} else {
			v = table[cn[5:]]
		}
		if c.prog.GuardVerdict != "" && c.prog.GuardVerdict != v {
			c.add(Rejected, SB008ProgramShape, r, "the early returns return %s and %s — bpf-mlir's ebpf.verdict.if chooses between only two verdicts (the early one and the last one), so every guard returns the same verdict", c.prog.GuardVerdict, v)
			return out
		}
		c.prog.GuardVerdict = v
		cond := c.cond(c.a.ref(n, "predicate"), "")
		if cond == nil {
			return out
		}
		if n.Type == "UnlessNode" {
			cond = &Expr{Kind: "not", Args: []*Expr{cond}, Bool: true, Pos: cond.Pos}
		}
		pre := c.env
		c.env = narrowEnv(pre, cond, false) // 後ろは guard が効かなかった側 — 否定の条件で狭める (P017)
		rest := c.guardStmts(ns[i+1:])
		return append(out, Stmt{Kind: "guard", Cond: cond, Else: rest, Op: v, Pos: c.z.pos(c.a, n)})
	}
	return c.stmts(ns, "")
}
