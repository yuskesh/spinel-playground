package frontend

import (
	"fmt"
)

// hash の系の map (P008): `M = BPF::HashMap.new("M", key, value, n)` (整数の値) / `BPF::RecordHashMap.new(…)` (record の値) と LRU の 2 つ。
// key と value は整数の型の Symbol か record の見本。書きの操作 (update / insert / replace / delete / add_or_init) は status (i64 — 0 か負の errno) を返し、
// 捨てる形は SB026 (P008 §2)。宣言の class は値の種類で分ける — 1 つの class では lookup の戻り値が MapRef と RecordRef の多相になり Spinel の推論の型が壊れる (E032 の probe)。

type hashClass struct {
	kind   string // schema の kind ("hash" / "lru_hash")
	record bool   // record の値
	class  string // bpf.rb の class の名前
}

var hashClasses = map[string]hashClass{
	"BPF::HashMap":             {"hash", false, "HashMap"},
	"BPF::LruHashMap":          {"lru_hash", false, "LruHashMap"},
	"BPF::RecordHashMap":       {"hash", true, "RecordHashMap"},
	"BPF::LruRecordHashMap":    {"lru_hash", true, "LruRecordHashMap"},
	"BPF::PerCpuHashMap":       {"percpu_hash", false, "PerCpuHashMap"}, // P009
	"BPF::PerCpuRecordHashMap": {"percpu_hash", true, "PerCpuRecordHashMap"},
}

// valueCounterpart は値の種類の違う同じ kind の class (宣言の案内の文)。
var valueCounterpart = map[string]string{"HashMap": "RecordHashMap", "RecordHashMap": "HashMap", "LruHashMap": "LruRecordHashMap", "LruRecordHashMap": "LruHashMap", "PerCpuHashMap": "PerCpuRecordHashMap", "PerCpuRecordHashMap": "PerCpuHashMap"}

// perCPUExempt は per-CPU の map の SB019 の免除の条件 (P009 のレビューの P2): map が per-CPU で、program の種類が全て xdp のとき。
// 同じ slot に同時に書く CPU は無い (test run は migrate_disable・XDP は softirq) が、tracing (kprobe・fentry) や perf の program は XDP の softirq の途中に
// 同じ CPU で割り込みうる — 1 つでも XDP でない種類が在れば免除を外す (program の種類を足した時に黙って免除が漏れる形を入口で閉じる)。kinds は program の root の種類の全て
// (map を使う program の上位の集合 — 保守的)。
func perCPUExempt(m *MapDecl, kinds []string) bool {
	if m != nil && mutation("percpu-exempt-all") { // 変異の対照 (試験の build だけ — E039): 免除を共有の map に漏らす
		return true
	}
	if m == nil || !m.PerCPU() || len(kinds) == 0 {
		return false
	}
	for _, k := range kinds {
		if k != "xdp" {
			return false
		}
	}
	return true
}

// exempt は progCtx の per-CPU の免除 (program の root の種類の全て)。
func (c *progCtx) exempt(m *MapDecl) bool { return perCPUExempt(m, c.z.rootKinds) }

// statusOps は status を返す hash の操作と try_update の flags ("delete" は try_delete、"add_or_init" は展開)。
var statusOps = map[string]string{"update": "any", "insert": "noexist", "replace": "exist", "delete": "delete", "add_or_init": "add_or_init"}

// errnoConsts は bpf.rb の status の定数 (負の errno — 試験が bpf.rb の値と CRuby の Errno と照合)。
var errnoConsts = map[string]int64{"BPF::ENOENT": -2, "BPF::E2BIG": -7, "BPF::ENOMEM": -12, "BPF::EEXIST": -17}

// intTypes は整数の型の Symbol (8 / 16 bit は外 — P008 §1)。
var intTypes = map[string][2]int{"u32": {32, 0}, "u64": {64, 0}, "i32": {32, 1}, "i64": {64, 1}}

// sampleRecord は `S.new(0, …)` (宣言した record の見本 — 全 member が literal の 0) を読む。誤りは SB024 で nil。
func (z *analyzer) sampleRecord(a *AST, x *Node) *RecordDecl {
	sc := constName(a, a.ref(x, "receiver"))
	r := z.records[sc]
	if x.Str["name"] != "new" || r == nil {
		z.add(Rejected, SB024RecordShape, z.pos(a, x), "the sample must be `S.new(0, …)` of a record S declared with BPF.record")
		return nil
	}
	sas := args(a, x)
	if len(sas) != len(r.Fields) {
		z.add(Rejected, SB024RecordShape, z.pos(a, x), "the sample must give all %d members of %s explicitly (upstream_suspects S5)", len(r.Fields), sc)
		return nil
	}
	if !z.sampleArgs(a, sas, r, "the sample's members must be the literal 0 — it is a sample of the type, not an initial value", "a hash map (key or value)") {
		return nil
	}
	return r
}

// hashMapDecl は最上位の `C = BPF::HashMap.new("C", key, value, n)` (と他の 3 つの class) を読む (P008 §1)。
func (z *analyzer) hashMapDecl(a *AST, n *Node, hc hashClass) {
	v := a.ref(n, "value")
	c := n.Str["name"]
	p := z.pos(a, n)
	z.badMaps[c] = true
	z.badHash[c] = true
	if _, dup := z.maps[c]; dup {
		z.add(Rejected, SB013MapDeclShape, p, "constant %s is assigned twice", c)
		return
	}
	as := args(a, v)
	for _, x := range as {
		if x.Type == "CallNode" && z.badRecs[constName(a, a.ref(x, "receiver"))] {
			return // record の宣言は既に止めた — 重ねない
		}
	}
	shape := "`" + c + " = BPF::" + hc.class + ".new(\"" + c + "\", key, value, max_entries)` with literal arguments — key is :u32 / :u64 / :i32 / :i64 or a record sample `S.new(0, …)`"
	if hc.record {
		shape += ", value is a record sample `S.new(0, …)`"
	} else {
		shape += ", value is :u32 / :u64 / :i32 / :i64"
	}
	if len(as) != 4 || as[0].Type != "StringNode" || as[3].Type != "IntegerNode" {
		z.add(Rejected, SB013MapDeclShape, p, "a hash map is declared as %s", shape)
		return
	}
	name := as[0].Str["content"]
	if name != c {
		z.add(Rejected, SB013MapDeclShape, z.pos(a, as[0]), "the map name %q differs from its constant %s — both sides look the map up by this name, so they must be the same", name, c)
		return
	}
	for _, m := range z.mapOrder {
		if m.Name == name {
			z.add(Rejected, SB013MapDeclShape, p, "two map declarations use the name %q", name)
			return
		}
	}
	m := &MapDecl{Const: c, Name: name, Kind: hc.kind, Class: hc.class, Pos: p}
	switch k := as[1]; k.Type {
	case "SymbolNode":
		t, ok := intTypes[k.Str["value"]]
		if !ok {
			z.add(Rejected, SB013MapDeclShape, z.pos(a, k), "the key type must be :u32, :u64, :i32 or :i64 (8- and 16-bit keys are not accepted), got :%s", k.Str["value"])
			return
		}
		m.KeyBits, m.KeySigned = t[0], t[1] == 1
	case "CallNode":
		if m.KeyRecord = z.sampleRecord(a, k); m.KeyRecord == nil {
			return
		}
	default:
		z.add(Rejected, SB013MapDeclShape, z.pos(a, k), "a hash map is declared as %s", shape)
		return
	}
	switch x := as[2]; {
	case hc.record && x.Type == "CallNode":
		if m.Record = z.sampleRecord(a, x); m.Record == nil {
			return
		}
	case !hc.record && x.Type == "SymbolNode":
		t, ok := intTypes[x.Str["value"]]
		if !ok {
			z.add(Rejected, SB013MapDeclShape, z.pos(a, x), "the value type must be :u32, :u64, :i32 or :i64 (8- and 16-bit values are not accepted), got :%s", x.Str["value"])
			return
		}
		m.ValueBits, m.Signed = t[0], t[1] == 1
	case hc.record:
		z.add(Rejected, SB013MapDeclShape, z.pos(a, x), "BPF::%s takes a record sample `S.new(0, …)` as its value — integer values use BPF::%s", hc.class, valueCounterpart[hc.class])
		return
	default:
		z.add(Rejected, SB013MapDeclShape, z.pos(a, x), "BPF::%s takes an integer type as its value — record values use BPF::%s", hc.class, valueCounterpart[hc.class])
		return
	}
	entries, ok := z.literal(a, as[3])
	if !ok {
		return
	}
	if entries.Sign() <= 0 || !entries.IsUint64() || entries.Uint64() > 1<<32-1 {
		z.add(Rejected, SB013MapDeclShape, z.pos(a, as[3]), "max_entries must be a positive integer below 2^32, got %s", entries)
		return
	}
	if reservedPrefix.MatchString(name) {
		z.add(Rejected, SB007ReservedName, p, "map name %q uses the reserved prefix spinelbpf_", name)
		return
	}
	delete(z.badMaps, c)
	delete(z.badHash, c)
	m.MaxEntries = entries.Uint64()
	z.maps[c] = m
	z.mapOrder = append(z.mapOrder, m)
}

// statusCall は n が hash の map の status を返す操作 (`M.insert(…)` 等) か。宣言を止めた hash の map なら bad (使う側で重ねない)。
func (c *progCtx) statusCall(n *Node) (m *MapDecl, bad, ok bool) {
	if n == nil || n.Type != "CallNode" {
		return nil, false, false
	}
	if _, st := statusOps[n.Str["name"]]; !st {
		return nil, false, false
	}
	recv := c.a.ref(n, "receiver")
	if recv == nil || recv.Type != "ConstantReadNode" {
		return nil, false, false
	}
	if c.z.badHash[recv.Str["name"]] {
		return nil, true, true
	}
	m = c.z.maps[recv.Str["name"]]
	if m == nil || !m.IsHash() {
		return nil, false, false
	}
	return m, false, true
}

// statusParentOK は status の呼び出し n の置き場が受ける形 (局所への代入・比較の operand) か。
func (c *progCtx) statusParentOK(n *Node) bool {
	p := c.a.node(c.a.Parent[n.ID])
	if p != nil && p.Type == "LocalVariableWriteNode" && c.a.ref(p, "value") == n {
		return true
	}
	if p != nil && p.Type == "ArgumentsNode" {
		p = c.a.node(c.a.Parent[p.ID])
	}
	return p != nil && p.Type == "CallNode" && cmpOps[p.Str["name"]]
}

// statusIgnored は SB026 の文言 (受ける形を並べる)。
func statusIgnored(m *MapDecl, op string) string {
	return "the status of `" + m.Const + "." + op + "` (0 or a negative errno such as BPF::EEXIST) is dropped — receive it as `st = " + m.Const + "." + op + "(…)` and read `st`, compare it (`if " + m.Const + "." + op + "(…) != 0`), or drop it explicitly with `_ = " + m.Const + "." + op + "(…)`"
}

// statusLocalOK は `st = M.op(…)` の局所の規則: その名前への代入はこの 1 つだけで、少なくとも 1 度読まれる (P008 §2 — 読まない status と上書きで失う status を塞ぐ)。
func (c *progCtx) statusLocalOK(w *Node, m *MapDecl, op string) bool {
	name := w.Str["name"]
	writes, reads := 0, 0
	walk(c.a, c.def, func(x *Node) bool {
		if x.Str["name"] != name {
			return true
		}
		switch x.Type {
		case "LocalVariableWriteNode", "LocalVariableOperatorWriteNode", "LocalVariableOrWriteNode", "LocalVariableAndWriteNode":
			writes++
		case "LocalVariableReadNode":
			reads++
		}
		return true
	})
	switch {
	case writes != 1 && c.statusReported[name]:
		return false // 同じ名前は最初の代入で 1 度だけ言った
	case writes != 1:
		c.statusReported[name] = true
		c.add(Rejected, SB026StatusIgnored, w, "`%s` holds the status of `%s.%s` but is assigned %d times — a status local is assigned once (give each status its own name, so none is overwritten before it is read)", name, m.Const, op, writes)
		return false
	case reads == 0:
		c.add(Rejected, SB026StatusIgnored, w, "`%s` holds the status of `%s.%s` but is never read — check it (e.g. `if %s != 0`) or drop it explicitly with `_ = %s.%s(…)`", name, m.Const, op, name, m.Const, op)
		return false
	}
	return true
}

// statusExpr は status を返す操作の値 (i64 — 区間は i64 の全体: errno の範囲を仮定しない)。
func (c *progCtx) statusExpr(n *Node, m *MapDecl, refVar string) *Expr {
	name := n.Str["name"]
	if name == "add_or_init" && m.Record != nil {
		c.add(Rejected, SB002UnsupportedCall, n, "`%s.add_or_init` takes integer values only — for a record value, `p = %s.lookup(k)`, `if p`, `p.atomic_add(:member, d)`, with `%s.insert(k, %s.new(…))` for a new key", m.Const, m.Const, m.Const, m.Record.Const)
		return nil
	}
	callee, ok := c.callee(n)
	if !ok {
		return nil
	}
	if callee != m.ClassName()+"#"+name {
		c.add(Rejected, SB011ShadowedName, n, "`%s` resolves to %s, not BPF::%s#%s", name, callee, m.ClassName(), name)
		return nil
	}
	if c.mapOf(c.a.ref(n, "receiver"), n) == nil {
		return nil
	}
	as := args(c.a, n)
	want := 2
	if name == "delete" {
		want = 1
	}
	if len(as) != want || c.a.ref(n, "block") != nil {
		c.add(Rejected, SB002UnsupportedCall, n, "`%s.%s` takes exactly %d argument(s)", m.Const, name, want)
		return nil
	}
	k := c.key(as[0], m, refVar)
	if want == 2 && !mutation("no-rmw") && c.rmwFirst(n, as[1], m, k, func(ref string) string { // P015 E062: RMW を値の区間より先に
		if name == "add_or_init" {
			return fmt.Sprintf("`%s.add_or_init` adds a value read from the same map (`%s.load`) — concurrent CPUs interleave the read and the add; use a delta that does not read %s", m.Name, ref, m.Const)
		}
		return fmt.Sprintf("`%s.%s` stores a value read from the same map (`%s.load`) — concurrent CPUs lose updates; use `%s.add_or_init` or `%s.atomic_add` inside `if %s`", m.Name, name, ref, m.Const, ref, ref)
	}) {
		return nil
	}
	var v *Expr
	if want == 2 {
		switch {
		case m.Record != nil:
			v = c.recordMake(as[1], m.Record, m, refVar)
		case name == "add_or_init":
			v = c.value(as[1], m, refVar, "delta")
		default:
			v = c.value(as[1], m, refVar, "value")
		}
		if v == nil {
			return nil
		}
	}
	if k == nil {
		return nil
	}
	if ref, ok := readsMap(v, m); ok && !mutation("no-rmw") && !c.exempt(m) { // per-CPU の map は免除 (P009) // no-rmw: 変異の対照 (試験の build だけ — E035 の非 atomic)
		lk := c.refKey[ref]
		if lk == nil || lk.Kind != "lit" || k.Kind != "lit" || lk.Lit.Cmp(k.Lit) == 0 {
			c.add(Rejected, SB019SharedReadModifyWrite, n, "`%s.%s` stores a value read from the same map (`%s.load`) — concurrent CPUs lose updates; use `%s.add_or_init` or `%s.atomic_add` inside `if %s`", m.Name, name, ref, m.Const, ref, ref)
			return nil
		}
	}
	return &Expr{Kind: "hstatus", Op: statusOps[name], Map: m, Args: []*Expr{k, v}, Iv: fullI64, Pos: c.z.pos(c.a, n)}
}

// hashKey は hash の map の key: 整数の式 (宣言の型の範囲) か、呼び出しの引数に直接書いた `S.new(…)` (record.make — padding は 0)。
func (c *progCtx) hashKey(n *Node, m *MapDecl, refVar string) *Expr {
	if m.KeyRecord != nil {
		if n.Type == "CallNode" && n.Str["name"] == "new" && constName(c.a, c.a.ref(n, "receiver")) == m.KeyRecord.Const {
			e := c.recordMake(n, m.KeyRecord, &MapDecl{Name: m.Name, Record: m.KeyRecord}, refVar)
			if e != nil && mutation("hash-key-swap") && len(e.Args) >= 2 { // 変異の対照 (試験の build だけ — E034): record の key の最初の 2 つの member の入れ替え
				e.Args[0], e.Args[1] = e.Args[1], e.Args[0]
			}
			return e
		}
		c.add(Rejected, SB024RecordShape, n, "the key of %s is `%s.new(…)` written in the call itself — a record key is not kept in a local or built elsewhere (bpf-mlir: a record.make result does not cross blocks)", m.Const, m.KeyRecord.Const)
		return nil
	}
	e := c.expr(n, refVar)
	if e == nil {
		return nil
	}
	if e.Bool || e.Wide {
		c.add(Rejected, SB001UnsupportedConstruct, n, "a map key must be an Integer (not a bool, not an unnarrowed u64 value)")
		return nil
	}
	tr := intRange(m.KeyBits, m.KeySigned)
	if !e.Iv.within(tr.Lo, tr.Hi) {
		if e.Kind == "lit" {
			c.add(Rejected, SB014SemanticGap, n, "the key literal %s is outside %s (the %s key of %s; Ruby would not wrap it)", e.Lit, tr, m.KeyTypeName(), m.Name)
		} else {
			c.add(Rejected, SB014SemanticGap, n, "the key's range %s does not fit the %s key of %s %s — the key would be truncated silently; narrow it (e.g. `& 0xFFFF_FFFF`)", e.Iv, m.KeyTypeName(), m.Name, tr)
		}
		return nil
	}
	return e
}

// intRange は整数の型の範囲 (u64 は Ruby の Integer の上限 2^63−1)。
func intRange(bits int, signed bool) Ival {
	return typeRange(&MapDecl{ValueBits: bits, Signed: signed})
}

// refAtomic は整数の値の借用への `p.atomic_add(d)` (present の中 — key が在る所だけ、ebpf.ref.atomic_add — P008 §2)。
func (c *progCtx) refAtomic(n *Node, refVar string) (Stmt, bool, bool) {
	recv := c.a.ref(n, "receiver")
	if n.Str["name"] != "atomic_add" || recv == nil || recv.Type != "LocalVariableReadNode" || c.refs[recv.Str["name"]] == nil || c.refMap[recv.Str["name"]].Record != nil {
		return Stmt{}, false, false
	}
	ref := recv.Str["name"]
	if ref != refVar {
		return Stmt{}, false, false // 腕の外 — lookupCheck の walk が止める
	}
	m := c.refMap[ref]
	if m.IsLpm() {
		c.add(Rejected, SB002UnsupportedCall, n, "`%s.atomic_add` is not accepted on lpm_trie %s — an lpm_trie is read-only on the eBPF side (read the value with `%s.load`; user space writes it with `obj.lpm_put`)", ref, m.Const, ref)
		return Stmt{}, false, true
	}
	callee, ok := c.callee(n)
	if !ok {
		return Stmt{}, false, true
	}
	if callee != "MapRef#atomic_add" {
		c.add(Rejected, SB011ShadowedName, n, "`atomic_add` resolves to %s, not BPF::MapRef#atomic_add", callee)
		return Stmt{}, false, true
	}
	as := args(c.a, n)
	if len(as) != 1 {
		c.add(Rejected, SB002UnsupportedCall, n, "`%s.atomic_add` takes one delta (`%s.atomic_add(d)`)", ref, ref)
		return Stmt{}, false, true
	}
	c.noteFlow(as[0], c.refMap[ref], n) // P023 E092
	if c.readsRefVia(as[0], ref) { // P015 E063: 局所の出自も
		c.add(Rejected, SB019SharedReadModifyWrite, n, "`%s.atomic_add` adds a value read from the same entry — use a delta that does not read `%s`", ref, ref)
		return Stmt{}, false, true
	}
	d := c.value(as[0], m, refVar, "delta")
	if d == nil {
		return Stmt{}, false, true
	}
	return Stmt{Kind: "ratomic", Var: ref, Map: m, Value: d, Pos: c.z.pos(c.a, n)}, true, true
}

// perCPUAdd は per-CPU の record の member の `p.load.m += d` / `-= d` (P009 — 今の CPU の slot の load → add → store、幅で wrap する kernel の加算と同じ意味)。
// 免除の条件が成り立たない・per-CPU でない map は handled を false にして呼び手の SB019 に任せる。
func (c *progCtx) perCPUAdd(n *Node, refVar string) (Stmt, bool, bool) {
	recv := c.a.ref(n, "receiver")
	if n.Type != "CallOperatorWriteNode" || recv == nil || recv.Type != "CallNode" || recv.Str["name"] != "load" {
		return Stmt{}, false, false
	}
	pv := c.a.ref(recv, "receiver")
	if pv == nil || pv.Type != "LocalVariableReadNode" || c.refs[pv.Str["name"]] == nil {
		return Stmt{}, false, false
	}
	ref := pv.Str["name"]
	m := c.refMap[ref]
	if m.Record == nil || !c.exempt(m) {
		return Stmt{}, false, false
	}
	if ref != refVar {
		return Stmt{}, false, false // 腕の外 — lookupCheck の walk が止める
	}
	op := n.Str["binary_operator"]
	if op != "+" && op != "-" {
		c.add(Rejected, SB001UnsupportedConstruct, n, "`.%s %s= …` is not accepted on a per-CPU record member — only `+=` and `-=`", n.Str["name"], op)
		return Stmt{}, false, true
	}
	if !c.loadCallee(recv) {
		return Stmt{}, false, true
	}
	f := m.Record.Field(n.Str["name"])
	switch {
	case f == nil:
		c.add(Rejected, SB002UnsupportedCall, n, "record %s has no member `%s`", m.Record.Const, n.Str["name"])
		return Stmt{}, false, true
	case f.Pad:
		c.add(Rejected, SB024RecordShape, n, "`%s` is padding — it is neither read nor written on the eBPF side", f.Name)
		return Stmt{}, false, true
	}
	vn := c.a.ref(n, "value")
	c.noteFlow(vn, m, n) // P023 E092
	if c.readsRefVia(vn, ref) { // P015 E063: 局所の出自も
		c.add(Rejected, SB019SharedReadModifyWrite, n, "the delta of `%s.load.%s %s= …` reads the same entry — use a delta that does not read `%s`", ref, f.Name, op, ref)
		return Stmt{}, false, true
	}
	d := c.fieldValue(vn, f, m, refVar)
	if d == nil {
		return Stmt{}, false, true
	}
	return Stmt{Kind: "fadd", Var: ref, Map: m, Field: f, Value: d, Op: op, Pos: c.z.pos(c.a, n)}, true, true
}
