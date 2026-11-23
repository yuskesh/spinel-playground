package frontend

import (
	"math/big"
	"sort"
	"strings"
)

// 有界の loop (P015 E060): `N.times` / `k.times` / `(0...k).each` / `(0..m).each` の block を ebpf.loop の (U) 展開に。
// N は literal か、実行時の回数の区間の上端 (≤ 64)。実行時の回数は bound(%k') — 区間の下端が負なら k' = k < 0 ? 0 : k を明示する
// (unsigned の min(n, N) に任せると −1 が N 回になる)。break / next は if / unless / present の腕の最後の文だけ。
// 区間は (U) なので本体を N 回順に解析して合流する (i は複製ごとに [j, j] — 不動点も widening も要らない)。

const maxLoopCount = 64 // bpf-mlir の ebpf.loop の N の上限 (入れ子の積も)

// loopFrame は解析中の loop 1 段 — break / next の時の環境 (loop の後と次の iteration の合流に)。
type loopFrame struct {
	n      int64
	breaks []map[string]*varInfo
	nexts  []map[string]*varInfo
}

// iterNames は block を取る反復の method (受けるのは times と each の形だけ — 他は SB030 で名指し)。
var iterNames = map[string]bool{"times": true, "each": true, "upto": true, "downto": true, "step": true, "each_with_index": true,
	"each_with_object": true, "map": true, "select": true, "reject": true, "each_slice": true, "each_cons": true, "reverse_each": true, "loop": true}

// isIterCall は block 付きの反復の呼び出しか。
func (c *progCtx) isIterCall(n *Node) bool {
	if n == nil || n.Type != "CallNode" || !iterNames[n.Str["name"]] {
		return false
	}
	b := c.a.ref(n, "block")
	return b != nil && b.Type == "BlockNode"
}

const loopForms = "`N.times do |i| … end`, `k.times`, `(0...k).each` or `(0..m).each`"

// rangeRecv は `(lo...hi)` / `(lo..hi)` の receiver (括弧の中の RangeNode 1 つ)。
func (c *progCtx) rangeRecv(recv *Node) (lo, hi *Node, incl, ok bool) {
	if recv == nil || recv.Type != "ParenthesesNode" {
		return nil, nil, false, false
	}
	st := c.a.ref(recv, "body")
	if st == nil || st.Type != "StatementsNode" || len(c.a.arr(st, "body")) != 1 {
		return nil, nil, false, false
	}
	r := c.a.arr(st, "body")[0]
	if r.Type != "RangeNode" {
		return nil, nil, false, false
	}
	return c.a.ref(r, "left"), c.a.ref(r, "right"), r.Int["flags"]&4 == 0, true // RangeFlags::EXCLUDE_END = 4
}

// blockParam は block の引数 (無しか必須の 1 つ)。
func (c *progCtx) blockParam(blk *Node) (string, bool) {
	bp := c.a.ref(blk, "parameters")
	if bp == nil {
		return "", true
	}
	ps := c.a.ref(bp, "parameters")
	if bp.Type != "BlockParametersNode" || len(c.a.arr(bp, "locals")) != 0 || ps == nil {
		c.add(Rejected, SB030LoopShape, bp, "the loop block takes one parameter `|i|` (or none) — no block-local `;` names")
		return "", false
	}
	req := c.a.arr(ps, "requireds")
	extra := len(c.a.arr(ps, "optionals")) + len(c.a.arr(ps, "keywords")) + len(c.a.arr(ps, "posts"))
	for _, f := range []string{"rest", "keyword_rest", "block"} {
		if c.a.ref(ps, f) != nil {
			extra++
		}
	}
	if len(req) != 1 || extra != 0 || req[0].Type != "RequiredParameterNode" {
		c.add(Rejected, SB030LoopShape, bp, "the loop block takes one parameter `|i|` (the index 0, 1, …) or none")
		return "", false
	}
	return req[0].Str["name"], true
}

// writesIn は node の下で代入される局所の名前。
func writesIn(a *AST, n *Node) map[string]*Node {
	out := map[string]*Node{}
	walk(a, n, func(x *Node) bool {
		switch x.Type {
		case "LocalVariableWriteNode", "LocalVariableOperatorWriteNode", "LocalVariableOrWriteNode", "LocalVariableAndWriteNode":
			if _, had := out[x.Str["name"]]; !had {
				out[x.Str["name"]] = x
			}
		}
		return true
	})
	return out
}

// loopStmt は block 付きの反復の文。
func (c *progCtx) loopStmt(n *Node) (Stmt, bool) {
	name, recv, blk := n.Str["name"], c.a.ref(n, "receiver"), c.a.ref(n, "block")
	if name == "loop" && recv == nil {
		c.add(Rejected, SB001UnsupportedConstruct, n, "`loop do` has no bound — write %s with a bound ≤ %d", loopForms, maxLoopCount)
		return Stmt{}, false
	}
	var count *Node
	incl := false
	switch {
	case name == "times" && recv != nil && len(args(c.a, n)) == 0:
		count = recv
	case name == "each" && len(args(c.a, n)) == 0:
		lo, hi, in, ok := c.rangeRecv(recv)
		if !ok || hi == nil {
			c.add(Rejected, SB030LoopShape, n, "`each` is accepted only on a range `(0...k)` / `(0..m)` — the bounded loops are %s", loopForms)
			return Stmt{}, false
		}
		if lo == nil || lo.Type != "IntegerNode" || lo.Int["value"] != 0 {
			c.add(Rejected, SB030LoopShape, n, "the range must start at literal 0 — write `(0...k).each` and add the start inside the body")
			return Stmt{}, false
		}
		count, incl = hi, in
	default:
		c.add(Rejected, SB030LoopShape, n, "`%s` with a block is not accepted on the eBPF side — the bounded loops are %s", name, loopForms)
		return Stmt{}, false
	}
	if len(c.loops) >= 2 {
		c.add(Rejected, SB030LoopShape, n, "loops nest at most 2 deep on the eBPF side (bpf-mlir's ebpf.loop) — move the innermost loop out")
		return Stmt{}, false
	}
	ivName, ok := c.blockParam(blk)
	if !ok {
		return Stmt{}, false
	}
	body := c.a.ref(blk, "body")
	var bodyN []*Node
	if body != nil {
		if body.Type != "StatementsNode" {
			c.add(Rejected, SB030LoopShape, body, "the loop body must be a plain sequence of statements, got %s", body.Type)
			return Stmt{}, false
		}
		bodyN = c.a.arr(body, "body")
	}
	if !c.loopBodyAllowed(blk, ivName) {
		return Stmt{}, false
	}

	// 回数: literal か区間の上端
	var bound *Expr
	var nCount int64
	clamp := false
	if count.Type == "IntegerNode" {
		v, _ := c.z.literal(c.a, count)
		if v == nil {
			return Stmt{}, false
		}
		if incl {
			v = new(big.Int).Add(v, bigOne)
		}
		if v.Cmp(big.NewInt(maxLoopCount)) > 0 {
			c.add(Rejected, SB030LoopShape, n, "the loop runs %s times — bpf-mlir's ebpf.loop runs at most %d; split the work or narrow it", v, maxLoopCount)
			return Stmt{}, false
		}
		if v.Sign() > 0 {
			nCount = v.Int64()
		}
	} else {
		e := c.expr(count, "")
		if e == nil {
			return Stmt{}, false
		}
		if e.Bool || e.Wide {
			c.add(Rejected, SB030LoopShape, count, "the loop count must be an Integer")
			return Stmt{}, false
		}
		r := e.Iv
		if incl {
			r = ivAdd(r, point(bigOne))
		}
		if r.Hi.Cmp(big.NewInt(maxLoopCount)) > 0 {
			what := "count"
			if incl {
				what = "count (m + 1)"
			}
			c.add(Rejected, SB030LoopShape, count, "the loop %s has range %s — its upper end must be ≤ %d for bpf-mlir's ebpf.loop: show it in the range, e.g. `k & 63`, `k %% 64` or inside `if k <= 64`", what, r, maxLoopCount)
			return Stmt{}, false
		}
		if r.Hi.Sign() > 0 {
			nCount = r.Hi.Int64()
		}
		clamp = r.Lo.Sign() < 0
		bound = e
	}
	prod := nCount
	for _, f := range c.loops {
		prod *= f.n
	}
	if prod > maxLoopCount {
		c.add(Rejected, SB030LoopShape, n, "the nested loops run %d times in all — bpf-mlir's ebpf.loop allows a product ≤ %d; shrink one of the counts", prod, maxLoopCount)
		return Stmt{}, false
	}

	// 本体で代入する外の局所 (iter_args) — bool は ebpf.loop の iter_args に乗らない (整数だけ)
	pre := c.env
	var carried []string
	for w, wn := range writesIn(c.a, body) {
		if _, had := pre[w]; had {
			if pre[w].Bool {
				c.add(Rejected, SB030LoopShape, wn, "`%s` is a bool assigned inside the loop — a value carried across iterations must be an Integer (use 0 / 1)", w)
				return Stmt{}, false
			}
			carried = append(carried, w)
		}
	}
	sort.Strings(carried)

	// (U) の順の解析 (診断と束縛は捨てる) — 各 iteration の入口と出口の環境
	entry := copyEnv(pre)
	var entries, exits []map[string]*varInfo
	snap := c.save()
	for j := int64(0); j < nCount; j++ {
		entries = append(entries, entry)
		if bound != nil {
			exits = append(exits, entry) // 実行時の回数は 0〜N
		}
		_, end, brks := c.loopBody(bodyN, entry, ivName, point(big.NewInt(j)), nCount)
		c.restore(snap)
		exits = append(exits, brks...)
		entry = keepKeys(end, pre)
	}
	exits = append(exits, entry) // N 回の後 (N = 0 なら loop の前)
	// 本番の解析: 入口は全ての iteration の入口の合流 (i は [0, N−1])
	all := copyEnv(pre)
	if len(entries) > 0 {
		all = entries[0]
		for _, e := range entries[1:] {
			all = joinEnv(all, e)
		}
	}
	ivr := Ival{big.NewInt(0), big.NewInt(nCount - 1)}
	if nCount == 0 {
		ivr = point(bigZero)
	}
	ss, _, _ := c.loopBody(bodyN, all, ivName, ivr, nCount)
	post := exits[0]
	for _, e := range exits[1:] {
		post = joinEnv(post, e)
	}
	c.env = keepKeys(post, pre)
	for w := range writesIn(c.a, body) {
		if _, had := pre[w]; !had && w != ivName {
			c.blockLocals[w] = true
		}
	}
	return Stmt{Kind: "loop", Count: nCount, Bound: bound, Clamp: clamp, Incl: incl && bound != nil, Var: ivName, Carried: carried, Then: ss, Pos: c.z.pos(c.a, n)}, true
}

// loopBody は本体を入口の環境で 1 回解析し、文・本体の終わり (と next) の合流・break の時の環境を返す。
func (c *progCtx) loopBody(body []*Node, entry map[string]*varInfo, ivName string, iv Ival, n int64) ([]Stmt, map[string]*varInfo, []map[string]*varInfo) {
	c.env = copyEnv(entry)
	if ivName != "" {
		c.env[ivName] = &varInfo{Iv: iv}
	}
	f := &loopFrame{n: n}
	c.loops = append(c.loops, f)
	savedArm := c.escArm
	c.escArm = ""
	ss := c.stmts(body, "")
	c.escArm = savedArm
	c.loops = c.loops[:len(c.loops)-1]
	end := c.env
	for _, e := range f.nexts {
		end = joinEnv(end, e)
	}
	return ss, end, f.breaks
}

// keepKeys は e のうち pre に在る名前だけ (block の局所と i は loop の外に出ない)。
func keepKeys(e, pre map[string]*varInfo) map[string]*varInfo {
	out := map[string]*varInfo{}
	for k, v := range e {
		if _, ok := pre[k]; ok {
			vv := *v
			out[k] = &vv
		}
	}
	for k, v := range pre { // 本体で止めた代入 — 前の値のまま (診断は本番の解析が言う)
		if _, ok := out[k]; !ok {
			vv := *v
			out[k] = &vv
		}
	}
	return out
}

// loopBodyAllowed は本体に置けない形を解析の前に 1 つだけ言う (bpf-mlir の ebpf.loop の本体の制約を位置付きで先に)。
func (c *progCtx) loopBodyAllowed(blk *Node, ivName string) bool {
	if ivName != "" {
		if _, had := c.env[ivName]; had || ivName == c.param || c.refs[ivName] != nil || c.wins[ivName] != nil {
			c.add(Rejected, SB030LoopShape, blk, "the block parameter `%s` shadows a local of the same name — rename it", ivName)
			return false
		}
	}
	ok := true
	walk(c.a, c.a.ref(blk, "body"), func(x *Node) bool {
		if !ok {
			return false
		}
		switch {
		case x.Type == "LocalVariableReadNode" && c.kptrs[x.Str["name"]] != nil: // P021 E086
			c.add(Rejected, SB030LoopShape, x, "the kernel pointer `%s` is not read inside a loop body (bpf-mlir's ebpf.loop body has no CO-RE read) — read the members before the loop", x.Str["name"])
			ok = false
		case x.Type == "LocalVariableReadNode" && (c.refs[x.Str["name"]] != nil || c.wins[x.Str["name"]] != nil):
			c.add(Rejected, SB030LoopShape, x, "`%s` is bound outside the loop — a lookup result or a packet window does not cross into a loop body (bpf-mlir's ebpf.loop carries only integers); do the lookup / check inside the body", x.Str["name"])
			ok = false
		case ivName != "" && strings.HasPrefix(x.Type, "LocalVariable") && strings.HasSuffix(x.Type, "WriteNode") && x.Str["name"] == ivName:
			c.add(Rejected, SB030LoopShape, x, "the loop index `%s` is not assigned inside the body (Ruby rebinds it every iteration; the unrolled copies fix it) — use another local", ivName)
			ok = false
		case c.z.userCall(c.a, x) != nil && c.ringPath(c.z.userCall(c.a, x), map[string]bool{}) != nil: // P023 E092: loop の中の call から ring buffer (bpf-mlir E047)
			c.add(Rejected, SB030LoopShape, x, "`%s` is called inside a loop and reaches a ring buffer output (%s) — bpf-mlir's ebpf.loop body cannot reach a ring buffer op through a call; output after the loop", x.Str["name"], strings.Join(c.ringPath(c.z.userCall(c.a, x), map[string]bool{}), " → "))
			ok = false
		case c.isOutput(x) || c.isOutputStr(x):
			c.add(Rejected, SB030LoopShape, x, "a ring buffer `%s` is not accepted inside a loop (bpf-mlir's ebpf.loop body has no ring buffer op) — count in the loop and output after it", x.Str["name"])
			ok = false
		case x.Type == "BlockNode" && x != blk:
			// 入れ子の loop の block — その中も同じ規則 (続けて辿る)
		}
		return ok
	})
	return ok
}

// escape は break / next の文 (if / unless / present の腕の最後の文だけ)。
func (c *progCtx) escape(n *Node, last bool) (Stmt, bool) {
	kw := map[string]string{"BreakNode": "break", "NextNode": "next"}[n.Type]
	switch {
	case len(c.loops) == 0:
		c.add(Rejected, SB030LoopShape, n, "`%s` outside a loop is not accepted on the eBPF side", kw)
		return Stmt{}, false
	case c.a.ref(n, "arguments") != nil:
		c.add(Rejected, SB030LoopShape, n, "`%s` with a value is not accepted — the value of a loop is not used on the eBPF side; write a bare `%s` and keep the value in a local", kw, kw)
		return Stmt{}, false
	case c.escArm == "window":
		c.add(Rejected, SB030LoopShape, n, "`%s` inside a packet window's `if w` arm is not accepted (bpf-mlir leaves a loop only from an if / present arm) — set a local in the arm and `%s if` after it", kw, kw)
		return Stmt{}, false
	case c.escArm == "":
		c.add(Rejected, SB030LoopShape, n, "an unconditional `%s` directly in the loop body makes the rest of the body dead code — write `%s if cond`", kw, kw)
		return Stmt{}, false
	case !last:
		c.add(Rejected, SB030LoopShape, n, "`%s` must be the last statement of its arm — the statements after it are dead code", kw)
		return Stmt{}, false
	}
	f := c.loops[len(c.loops)-1]
	if kw == "break" {
		f.breaks = append(f.breaks, copyEnv(c.env))
	} else {
		f.nexts = append(f.nexts, copyEnv(c.env))
	}
	return Stmt{Kind: kw, Pos: c.z.pos(c.a, n)}, true
}

// escapes は文の並びが break / next で終わるか (その腕は合流しない)。
func escapes(ss []Stmt) bool {
	return len(ss) > 0 && (ss[len(ss)-1].Kind == "break" || ss[len(ss)-1].Kind == "next")
}

// ctxSnapshot は (U) の順の解析の前の状態 (解析の副作用 — 診断・束縛・止めた名前 — を戻す)。
type ctxSnapshot struct {
	diags                                     int
	refs                                      map[string]*Node
	refMap                                    map[string]*MapDecl
	refKey                                    map[string]*Expr
	wins                                      map[string]*winInfo
	used                                      map[*MapDecl]bool
	usedGlobals                               map[*GlobalDecl]bool
	usedRings                                 map[*RingDecl]bool
	badBind, poisoned, statusReported, locals map[string]bool
	skipIfs                                   map[int]bool
}

func cp[K comparable, V any](m map[K]V) map[K]V {
	out := make(map[K]V, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func (c *progCtx) save() ctxSnapshot {
	return ctxSnapshot{len(c.z.diags), cp(c.refs), cp(c.refMap), cp(c.refKey), cp(c.wins), cp(c.used), cp(c.usedGlobals), cp(c.usedRings),
		cp(c.badBind), cp(c.poisoned), cp(c.statusReported), cp(c.blockLocals), cp(c.skipIfs)}
}

func (c *progCtx) restore(s ctxSnapshot) {
	c.z.diags = c.z.diags[:s.diags]
	c.refs, c.refMap, c.refKey, c.wins = cp(s.refs), cp(s.refMap), cp(s.refKey), cp(s.wins)
	c.used, c.usedGlobals, c.usedRings = cp(s.used), cp(s.usedGlobals), cp(s.usedRings)
	c.badBind, c.poisoned, c.statusReported, c.blockLocals, c.skipIfs = cp(s.badBind), cp(s.poisoned), cp(s.statusReported), cp(s.locals), cp(s.skipIfs)
}
