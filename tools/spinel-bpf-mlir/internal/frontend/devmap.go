package frontend

// P026 E124: XDP の redirect_map と devmap — `Ports = BPF::DevMap.new("Ports", :u32, n)` (key は u32 の添字、value は ifindex — user の側が
// `obj.map_put` で入れる) と、xdp の program の最後の式 `Ports.redirect(k, BPF::XDP_PASS)` (bpf-mlir の ebpf.redirect_map — entry が在れば
// XDP_REDIRECT、無ければ fallback の判定)。program の中の devmap の lookup / update 等は bpf-mlir が拒否する (checkMapKind)。

// IsDevmap は devmap の map (E124)。
func (m *MapDecl) IsDevmap() bool { return m.Kind == "devmap" }

// redirectVerdict は最後の式の `M.redirect(k, BPF::XDP_*)` — M は devmap、k は整数の式、fallback は XDP の判定の定数。
func (c *progCtx) redirectVerdict(n, v *Node) {
	if c.prog.Kind != "xdp" {
		c.add(Rejected, SB028TracingKind, v, "`redirect` (bpf_redirect_map) ends only an XDP program — a %s program returns its own verdict", c.prog.Kind)
		return
	}
	if len(c.guardReturns) > 0 {
		c.add(Rejected, SB008ProgramShape, v, "a program that ends with `M.redirect(k, …)` takes no top-level `return … if cond` guard yet — compute the key on every path instead")
		return
	}
	m := c.mapOf(c.a.ref(v, "receiver"), v)
	if m == nil {
		return
	}
	if !m.IsDevmap() {
		c.add(Rejected, SB002UnsupportedCall, v, "`%s.redirect` needs a devmap (`BPF::DevMap.new`) — %s is a %s", m.Const, m.Const, m.MapKind())
		return
	}
	if callee, ok := c.callee(v); !ok || callee != "DevMap#redirect" {
		if ok {
			c.add(Rejected, SB011ShadowedName, v, "`redirect` resolves to %s, not BPF::DevMap#redirect", callee)
		}
		return
	}
	as := args(c.a, v)
	if len(as) != 2 {
		c.add(Rejected, SB008ProgramShape, v, "`%s.redirect(k, BPF::XDP_PASS)` takes the key and the fallback verdict", m.Const)
		return
	}
	cn := constName(c.a, as[1])
	table := verdictsOf("xdp")
	if as[1].Type != "ConstantPathNode" || len(cn) < 5 || cn[:5] != "BPF::" || table[cn[5:]] == "" {
		c.add(Rejected, SB008ProgramShape, as[1], "the fallback of `%s.redirect` is an XDP verdict constant (BPF::XDP_ABORTED / XDP_DROP / XDP_PASS / XDP_TX)", m.Const)
		return
	}
	k := c.expr(as[0], "")
	if k == nil {
		return
	}
	if k.Bool {
		c.add(Rejected, SB001UnsupportedConstruct, as[0], "the key of `%s.redirect` is an Integer (a devmap index), not a bool", m.Const)
		return
	}
	if !c.valueOK(k, as[0]) {
		return
	}
	c.prog.Verdict, c.prog.VerdictConst, c.prog.VerdictPos = table[cn[5:]], cn[5:], c.z.pos(c.a, n)
	c.prog.RedirMap, c.prog.RedirKey = m, k
}
