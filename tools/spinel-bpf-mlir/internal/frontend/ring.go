package frontend

import (
	"fmt"
	"math/big"
	"strings"
)

// ring buffer (P007): `C = BPF::RingBuf.new("C", S.new(0, …), size)` と eBPF の側の `C.output(S.new(…))`。
// output の結果 (予約の成否) は if / unless の条件か `_ = …` だけで受ける — 捨てる文・bool の局所・&& の operand・引数は SB025 (P007 §2)。

// RingDecl は ring buffer の宣言。
type RingDecl struct {
	Const  string
	Name   string
	Record *RecordDecl
	Size   uint64
	Pos    Pos
}

// ringDecl は最上位の `C = BPF::RingBuf.new("C", S.new(0, …), size)` を読む。
func (z *analyzer) ringDecl(a *AST, n *Node) {
	v := a.ref(n, "value")
	c := n.Str["name"]
	p := z.pos(a, n)
	z.badRings[c] = true // 止めたら使う側で重ねない (理由の優先順位の 1)
	if _, dup := z.maps[c]; dup || z.rings[c] != nil {
		z.add(Rejected, SB013MapDeclShape, p, "constant %s is assigned twice", c)
		return
	}
	as := args(a, v)
	if len(as) == 3 && as[1].Type == "CallNode" && z.badRecs[constName(a, a.ref(as[1], "receiver"))] {
		return // record の宣言は既に止めた — 重ねない
	}
	if len(as) == 3 && as[0].Type == "StringNode" && as[2].Type == "IntegerNode" && as[1].Type != "CallNode" {
		z.add(Rejected, SB024RecordShape, z.pos(a, as[1]), "the sample must be `S.new(0, …)` of a record S declared with BPF.record")
		return
	}
	if len(as) != 3 || as[0].Type != "StringNode" || as[1].Type != "CallNode" || as[2].Type != "IntegerNode" {
		z.add(Rejected, SB013MapDeclShape, p, "a ring buffer is declared as `%s = BPF::RingBuf.new(\"%s\", S.new(0, …), size)` with literal arguments", c, c)
		return
	}
	name := as[0].Str["content"]
	if name != c {
		z.add(Rejected, SB013MapDeclShape, z.pos(a, as[0]), "the ring buffer name %q differs from its constant %s", name, c)
		return
	}
	for _, m := range z.mapOrder {
		if m.Name == name {
			z.add(Rejected, SB013MapDeclShape, p, "a map and a ring buffer use the name %q", name)
			return
		}
	}
	for _, r := range z.ringOrder {
		if r.Name == name {
			z.add(Rejected, SB013MapDeclShape, p, "two ring buffer declarations use the name %q", name)
			return
		}
	}
	sample := as[1]
	sc := constName(a, a.ref(sample, "receiver"))
	r := z.records[sc]
	if sample.Str["name"] != "new" || r == nil {
		z.add(Rejected, SB024RecordShape, z.pos(a, sample), "the sample must be `S.new(0, …)` of a record S declared with BPF.record")
		return
	}
	sas := args(a, sample)
	if len(sas) != len(r.Fields) {
		z.add(Rejected, SB024RecordShape, z.pos(a, sample), "the sample must give all %d members of %s explicitly (upstream_suspects S5)", len(r.Fields), sc)
		return
	}
	if !z.sampleArgs(a, sas, r, "the sample's members must be the literal 0 — it is a sample of the type", "a ring buffer event") {
		return
	}
	size, ok := z.literal(a, as[2])
	if !ok {
		return
	}
	if !size.IsUint64() || size.Uint64() < 4096 || size.Uint64() > 1<<31 || size.Uint64()&(size.Uint64()-1) != 0 {
		z.add(Rejected, SB013MapDeclShape, z.pos(a, as[2]), "the ring buffer size must be a power of two of at least 4096 bytes (the x86_64 page) and at most 2^31, got %s", size)
		return
	}
	if reservedPrefix.MatchString(name) {
		z.add(Rejected, SB007ReservedName, p, "ring buffer name %q uses the reserved prefix spinelbpf_", name)
		return
	}
	delete(z.badRings, c)
	d := &RingDecl{Const: c, Name: name, Record: r, Size: size.Uint64(), Pos: p}
	z.rings[c] = d
	z.ringOrder = append(z.ringOrder, d)
}

// ringOf は receiver が宣言した ring buffer の定数か。
func (c *progCtx) ringOf(recv *Node) *RingDecl {
	if recv == nil || recv.Type != "ConstantReadNode" {
		return nil
	}
	return c.z.rings[recv.Str["name"]]
}

// isOutput は n が `R.output(…)` (R は ring buffer) か。
func (c *progCtx) isOutput(n *Node) bool {
	return n != nil && n.Type == "CallNode" && n.Str["name"] == "output" && c.ringOf(c.a.ref(n, "receiver")) != nil
}

// outputOfBadRing は宣言を止めた ring buffer の output か (使う側では重ねて止めない — 理由の優先順位の 1)。
func (c *progCtx) outputOfBadRing(n *Node) bool {
	recv := c.a.ref(n, "receiver")
	return n != nil && n.Type == "CallNode" && (n.Str["name"] == "output" || n.Str["name"] == "output_str") && recv != nil && recv.Type == "ConstantReadNode" && c.z.badRings[recv.Str["name"]]
}

// ringOutput は `R.output(S.new(…))` の値 (bool — 予約の成否)。
func (c *progCtx) ringOutput(n *Node, refVar string) *Expr {
	r := c.ringOf(c.a.ref(n, "receiver"))
	callee, ok := c.callee(n)
	if !ok {
		return nil
	}
	if callee != "RingBuf#output" {
		c.add(Rejected, SB011ShadowedName, n, "`output` resolves to %s, not BPF::RingBuf#output", callee)
		return nil
	}
	as := args(c.a, n)
	if len(as) != 1 {
		c.add(Rejected, SB002UnsupportedCall, n, "`%s.output` takes one event (`%s.new(…)`)", r.Const, r.Record.Const)
		return nil
	}
	c.ringMake = true // P026 E119: ring の output の record.make だけ配列の member に `t.copy(:m)` を受ける
	mk := c.recordMake(as[0], r.Record, &MapDecl{Name: r.Name, Record: r.Record}, refVar)
	c.ringMake = false
	if mk == nil {
		return nil
	}
	c.usedRings[r] = true
	return &Expr{Kind: "ringout", Ring: r, Args: []*Expr{mk}, Bool: true, Pos: c.z.pos(c.a, n)}
}

// ringCopy は ring の output の record.make の配列の member の `t.copy(:m)` (P026 E119 — bpf-mlir E535 の kfield.copy の写し先に予約): record.make では
// 0 (zarr) で、lower が store_record の後・submit の前に予約へ写す。t は present の kernel pointer、m は t の struct の N byte の配列で N は member と同じ。
func (c *progCtx) ringCopy(x *Node, f *RecordField, rec *RecordDecl) (*Expr, bool) {
	if !c.ringMake || x.Type != "CallNode" || x.Str["name"] != "copy" {
		return nil, false
	}
	recv := c.a.ref(x, "receiver")
	if recv == nil || recv.Type != "LocalVariableReadNode" || c.kptrs[recv.Str["name"]] == nil {
		return nil, false
	}
	t := recv.Str["name"]
	d := c.kptrs[t]
	if cs, ok := c.callee(x); !ok || cs != "KPtr#copy" {
		if ok {
			c.add(Rejected, SB011ShadowedName, x, "`copy` resolves to %s, not BPF::KPtr#copy", cs)
		}
		return nil, true
	}
	as := args(c.a, x)
	if len(as) != 1 || as[0].Type != "SymbolNode" {
		c.add(Rejected, SB033KernelTypeShape, x, "`%s.copy(:m)` takes one member Symbol", t)
		return nil, true
	}
	kf := d.field(as[0].Str["value"])
	switch {
	case kf == nil:
		c.add(Rejected, SB033KernelTypeShape, as[0], "%s (%s) declares no member `%s`", d.Const, d.Name, as[0].Str["value"])
		return nil, true
	case kf.Kind != "array":
		c.add(Rejected, SB033KernelTypeShape, as[0], "member %s is not a byte array (`[:u8, N]`) — read it with `%s.load.%s`", kf.Name, t, kf.Name)
		return nil, true
	case f.Bits != 8 || f.Count != kf.Count:
		c.add(Rejected, SB033KernelTypeShape, x, "event member %s of %s has %d elements but %s.%s has %d — the copy is a fixed N bytes into a `[:u8, N]` member, declare the same N", f.Name, rec.Const, f.Count, d.Const, kf.Name, kf.Count)
		return nil, true
	}
	return &Expr{Kind: "zarr", Var: t, Op: d.Name, Path: kf.Name, Field: f, Pos: c.z.pos(c.a, x)}, true
}

// recordMake は `S.new(a, b, …)` (位置の引数で全 member、`_pad<N>` は literal の 0 — P006 §2) の record.make の式。
func (c *progCtx) recordMake(mk *Node, rec *RecordDecl, m *MapDecl, refVar string) *Expr {
	if mk.Type != "CallNode" || mk.Str["name"] != "new" || constName(c.a, c.a.ref(mk, "receiver")) != rec.Const {
		c.add(Rejected, SB024RecordShape, mk, "the value is `%s.new(…)` with every member", rec.Const)
		return nil
	}
	vs := args(c.a, mk)
	for _, x := range vs {
		if x.Type == "KeywordHashNode" || x.Type == "SplatNode" {
			c.add(Rejected, SB024RecordShape, x, "%s.new takes positional arguments only", rec.Const)
			return nil
		}
	}
	if len(vs) != len(rec.Fields) {
		c.add(Rejected, SB024RecordShape, mk, "%s.new must give all %d members explicitly, got %d (an omitted member is nil, which Spinel types as Integer — upstream_suspects S5)", rec.Const, len(rec.Fields), len(vs))
		return nil
	}
	e := &Expr{Kind: "rmake", Map: m, Pos: c.z.pos(c.a, mk)}
	for i, x := range vs {
		f := &rec.Fields[i]
		if f.Pad {
			lit, ok := big.NewInt(1), x.Type == "IntegerNode"
			if ok {
				lit, ok = c.z.literal(c.a, x)
			}
			if !ok || lit.Sign() != 0 {
				c.add(Rejected, SB024RecordShape, x, "padding member %s must be the literal 0", f.Name)
				return nil
			}
			e.Args = append(e.Args, &Expr{Kind: "lit", Lit: new(big.Int), Iv: point(new(big.Int)), Pos: c.z.pos(c.a, x)})
			continue
		}
		if f.Count > 0 { // P020 E080: 配列の member は `Array.new(N, 0)` だけ (全要素 0 — record.make の葉 `m[i]` を 0 で)
			if c.ctxCopyOtherKind(x) { // E153 停止 B: tracepoint でない ctx の copy
				return nil
			}
			if c.isTpCopy(x) { // P029 E153: ring の output の `ctx.copy(:f)` — record.make では 0、lower が store_record の後に予約へ写す
				if !c.ringMake {
					c.add(Rejected, SB028TracingKind, x, "`%s.copy(:f)` is accepted only as an array member's argument of `R.output(S.new(…))` or as `r.load.<member> = %s.copy(:f)`", c.param, c.param)
					return nil
				}
				tf, ok := c.tpCopyField(x, x, f, rec.Const)
				if !ok {
					return nil
				}
				e.Args = append(e.Args, &Expr{Kind: "zarr", TpCopy: tf, Field: f, Pos: c.z.pos(c.a, x)})
				continue
			}
			if cp, handled := c.ringCopy(x, f, rec); handled { // P026 E119: ring の output の `t.copy(:m)`
				if cp == nil {
					return nil
				}
				e.Args = append(e.Args, cp)
				continue
			}
			if !c.zeroArray(x, f.Count) {
				c.add(Rejected, SB024RecordShape, x, "the array member %s is given as `Array.new(%d, 0)` in %s.new — its elements are not values on the eBPF side", f.Name, f.Count, rec.Const)
				return nil
			}
			e.Args = append(e.Args, &Expr{Kind: "zarr", Pos: c.z.pos(c.a, x)})
			continue
		}
		v := c.fieldValue(x, f, m, refVar)
		if v == nil {
			return nil
		}
		e.Args = append(e.Args, v)
	}
	return e
}

// zeroArray は x が `Array.new(n, 0)` (literal) か。
func (c *progCtx) zeroArray(x *Node, n int) bool {
	if x == nil || x.Type != "CallNode" || x.Str["name"] != "new" || constName(c.a, c.a.ref(x, "receiver")) != "Array" {
		return false
	}
	as := args(c.a, x)
	if len(as) != 2 || as[0].Type != "IntegerNode" || as[1].Type != "IntegerNode" {
		return false
	}
	a, ok1 := c.z.literal(c.a, as[0])
	b, ok2 := c.z.literal(c.a, as[1])
	return ok1 && ok2 && a.IsInt64() && a.Int64() == int64(n) && b.Sign() == 0
}

// outputIsCondition は output の CallNode が if / unless の条件そのもの (`!` を 1 つ挟んでもよい) か。
func (c *progCtx) outputIsCondition(n *Node) bool {
	p := c.a.node(c.a.Parent[n.ID])
	if p != nil && p.Type == "CallNode" && p.Str["name"] == "!" && c.a.ref(p, "receiver") == n {
		n, p = p, c.a.node(c.a.Parent[p.ID])
	}
	return p != nil && (p.Type == "IfNode" || p.Type == "UnlessNode") && c.a.ref(p, "predicate") == n
}

func droppedMsg(r *RingDecl) string {
	return fmt.Sprintf("the result of %s.output (false when the ring is full) is dropped — use it as an `if` / `unless` condition (count drops in the false arm) or write `_ = %s.output(…)` to choose not to count them", r.Const, r.Const)
}

// ringLines は keptSource が残す ring buffer の行 (宣言と record の Struct / BPF.record)。
func ringLines(res *Result) []int {
	var out []int
	for _, r := range res.Rings {
		out = append(out, r.Pos.Line, r.Record.StructPos.Line, r.Record.Pos.Line)
	}
	return out
}

var _ = strings.Join
