package frontend

import (
	"fmt"
	"math/big"
	"regexp"
	"strings"
)

// record (P006 §1): `S = Struct.new(:a, …)` + `BPF.record(S, a: :u16, …)` + `M = BPF::RecordMap.new("M", S.new(0, …), n)`。
// member の型・幅・offset は全て BPF.record の宣言から決める (Spinel の推論の型を使わない — R002 の r1、P006 のレビューの (a))。

// RecordField は record の member 1 つ。
type RecordField struct {
	Name   string
	Bits   int
	Signed bool
	Pad    bool // `_pad<N>` — schema・maps.json に書かない穴、eBPF の側で読み書きしない
	Offset int
	Count  int // 配列の member の要素の数 (P016 E066 — `m: [:u32, 8]`)。0 は整数の member。Bits・Signed は要素の型
}

// Size は member の byte の大きさ (配列は要素 × 数)。
func (f RecordField) Size() int {
	if f.Count > 0 {
		return f.Bits / 8 * f.Count
	}
	return f.Bits / 8
}

// DeclType は requirements の records の member の綴り (配列は `[N]u32` — bpf-mlir の requirements_format)。
func (f RecordField) DeclType() string {
	if f.Count > 0 {
		return fmt.Sprintf("[%d]%s", f.Count, f.TypeName())
	}
	return f.TypeName()
}

// Flat は member の平らな名前と offset (配列は要素ごとの `m[i]` — 埋め込みの表・user 空間の値の並び・harness の slot)。
func (f RecordField) Flat() ([]string, []int) {
	if f.Count == 0 {
		return []string{f.Name}, []int{f.Offset}
	}
	var ns []string
	var os []int
	for i := 0; i < f.Count; i++ {
		ns = append(ns, fmt.Sprintf("%s[%d]", f.Name, i))
		os = append(os, f.Offset+i*f.Bits/8)
	}
	return ns, os
}

// HasArray は record が配列の member を持つか (record.make・ring の event・hash の key は E066 では受けない)。
func (r *RecordDecl) HasArray() bool {
	for _, f := range r.Fields {
		if f.Count > 0 {
			return true
		}
	}
	return false
}

// TypeName は member の型の綴り (u8 … i64 — maps.json・schema と同じ)。
func (f RecordField) TypeName() string {
	if f.Signed {
		return fmt.Sprintf("i%d", f.Bits)
	}
	return fmt.Sprintf("u%d", f.Bits)
}

// Range は member の型の範囲 (u64 は Ruby の Integer の上限 2^63−1 まで — P002 §1.4 の store の規則と同じ)。
func (f RecordField) Range() Ival {
	if f.Signed {
		lo := new(big.Int).Neg(new(big.Int).Lsh(bigOne, uint(f.Bits-1)))
		hi := new(big.Int).Sub(new(big.Int).Lsh(bigOne, uint(f.Bits-1)), bigOne)
		return iv(lo, hi)
	}
	if f.Bits == 64 {
		return iv(new(big.Int), new(big.Int).Set(i64Max))
	}
	return iv(new(big.Int), new(big.Int).Sub(new(big.Int).Lsh(bigOne, uint(f.Bits)), bigOne))
}

// RecordDecl は record の宣言 (Struct の定数の名前が schema の symbol)。
type RecordDecl struct {
	Const     string
	Fields    []RecordField
	Size      int
	Align     int
	Pos       Pos // BPF.record の位置
	StructPos Pos // `S = Struct.new(…)` の位置 (twin の keptSource が残す)
}

// Field は名前の member (無ければ nil)。
func (r *RecordDecl) Field(name string) *RecordField {
	for i := range r.Fields {
		if r.Fields[i].Name == name {
			return &r.Fields[i]
		}
	}
	return nil
}

// MLIRType は `!ebpf.record<"S", size>`。
func (r *RecordDecl) MLIRType() string { return fmt.Sprintf(`!ebpf.record<%q, %d>`, r.Const, r.Size) }

// Shape は layout の表の 1 行 (`S|size=24;a:0:u32;_pad0:4:u8;…` — 埋め込みの spinelbpf_records、P006 §3)。
func (r *RecordDecl) Shape() string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s|size=%d;", r.Const, r.Size)
	for _, f := range r.Fields {
		ns, os := f.Flat()
		for i := range ns {
			fmt.Fprintf(&b, "%s:%d:%s;", ns[i], os[i], f.TypeName())
		}
	}
	return b.String()
}

var padName = regexp.MustCompile(`^_pad[0-9]+$`)

var recordTypes = map[string][2]int{
	"u8": {8, 0}, "u16": {16, 0}, "u32": {32, 0}, "u64": {64, 0},
	"i8": {8, 1}, "i16": {16, 1}, "i32": {32, 1}, "i64": {64, 1},
}

// structDecl は `S = Struct.new(:a, :b)` の member の名前 (形の外は nil — 利用者の側の Struct は record でなければ問わないので、ここでは止めない)。
type structInfo struct {
	names []string
	pos   Pos
	bad   string // record に使えない形の理由 ("" は使える)
}

func (z *analyzer) structOf(a *AST, n *Node) (*structInfo, bool) {
	v := a.ref(n, "value")
	if v == nil || v.Type != "CallNode" {
		return nil, false
	}
	recv := constName(a, a.ref(v, "receiver"))
	switch {
	case recv == "Struct" && v.Str["name"] == "new":
	case recv == "Data" && v.Str["name"] == "define":
		return &structInfo{pos: z.pos(a, n), bad: "Data.define has no member setters — a record is a Struct"}, true
	default:
		return nil, false
	}
	s := &structInfo{pos: z.pos(a, n)}
	if a.ref(v, "block") != nil {
		s.bad = "a record Struct takes no block"
		return s, true
	}
	for _, x := range args(a, v) {
		if x.Type != "SymbolNode" {
			s.bad = "a record Struct takes Symbol literals only — no keyword_init, no string name"
			return s, true
		}
		s.names = append(s.names, x.Str["value"])
	}
	if len(s.names) == 0 {
		s.bad = "a record Struct needs at least one member"
	}
	return s, true
}

// recordDecl は top level の `BPF.record(S, a: :u16, …)` を読む。
func (z *analyzer) recordDecl(a *AST, n *Node, structs map[string]*structInfo) {
	p := z.pos(a, n)
	as := args(a, n)
	if len(as) != 2 || as[0].Type != "ConstantReadNode" || as[1].Type != "KeywordHashNode" {
		z.add(Rejected, SB024RecordShape, p, "a record is declared as `BPF.record(S, member: :u16, …)` with S a Struct constant and every member's type")
		return
	}
	c := as[0].Str["name"]
	s := structs[c]
	z.badRecs[c] = true
	switch {
	case s == nil:
		z.add(Rejected, SB024RecordShape, z.pos(a, as[0]), "%s is not a top-level `%s = Struct.new(:m, …)`", c, c)
		return
	case s.bad != "":
		z.add(Rejected, SB024RecordShape, s.pos, "%s: %s", c, s.bad)
		return
	}
	if _, dup := z.records[c]; dup {
		z.add(Rejected, SB024RecordShape, p, "record %s is declared twice", c)
		return
	}
	r := &RecordDecl{Const: c, Pos: p, StructPos: s.pos}
	var got []string
	for _, e := range a.arr(as[1], "elements") {
		k, v := a.ref(e, "key"), a.ref(e, "value")
		count := 0
		if e.Type == "AssocNode" && k != nil && k.Type == "SymbolNode" && v != nil && v.Type == "ArrayNode" { // P016 E066: 配列の member `m: [:u32, 8]`
			els := a.arr(v, "elements")
			if len(els) != 2 || els[0].Type != "SymbolNode" || els[1].Type != "IntegerNode" {
				z.add(Rejected, SB024RecordShape, z.pos(a, v), "member %s: an array member is `%s: [:u32, N]` — the element type and a literal length", k.Str["value"], k.Str["value"])
				return
			}
			n, ok := z.literal(a, els[1])
			if !ok || !n.IsInt64() || n.Int64() < 1 || n.Int64() > 64 {
				z.add(Rejected, SB024RecordShape, z.pos(a, els[1]), "member %s: the array length must be a literal 1..64 (bpf-mlir's record arrays)", k.Str["value"])
				return
			}
			if padName.MatchString(k.Str["value"]) {
				z.add(Rejected, SB024RecordShape, z.pos(a, e), "padding member %s cannot be an array — declare `_pad<N>` members as integers", k.Str["value"])
				return
			}
			count, v = int(n.Int64()), els[0]
		}
		if e.Type != "AssocNode" || k == nil || v == nil || k.Type != "SymbolNode" || v.Type != "SymbolNode" {
			z.add(Rejected, SB024RecordShape, z.pos(a, e), "each member is `name: :type` (or `name: [:type, N]` for an array) with Symbol literals")
			return
		}
		t, ok := recordTypes[v.Str["value"]]
		if !ok {
			z.add(Rejected, SB024RecordShape, z.pos(a, v), "member %s: the type must be :u8 … :u64 or :i8 … :i64, got :%s", k.Str["value"], v.Str["value"])
			return
		}
		got = append(got, k.Str["value"])
		r.Fields = append(r.Fields, RecordField{Name: k.Str["value"], Bits: t[0], Signed: t[1] == 1, Pad: padName.MatchString(k.Str["value"]), Count: count})
	}
	if strings.Join(got, ",") != strings.Join(s.names, ",") {
		z.add(Rejected, SB024RecordShape, p, "the members of BPF.record(%s, …) (%s) must be the Struct's members in the same order (%s)", c, strings.Join(got, ", "), strings.Join(s.names, ", "))
		return
	}
	// layout: C の自然な alignment、暗黙の padding は拒否 (mojo の MB019 の形)
	off, maxAlign, pad := 0, 1, 0
	for i := range r.Fields {
		f := &r.Fields[i]
		sz := f.Bits / 8 // alignment は要素の型の大きさ (配列も — C の自然な並び)
		if off%sz != 0 {
			gap := sz - off%sz
			z.add(Rejected, SB024RecordShape, p, "record %s has %d implicit padding byte(s) before member %s (offset %d, alignment %d) — declare them before %s: %s", c, gap, f.Name, off, sz, f.Name, padHint(off, gap, pad))
			return
		}
		f.Offset = off
		off += f.Size()
		if sz > maxAlign {
			maxAlign = sz
		}
		if f.Pad {
			pad++
		}
	}
	if off%maxAlign != 0 {
		gap := maxAlign - off%maxAlign
		z.add(Rejected, SB024RecordShape, p, "record %s has %d implicit trailing padding byte(s) (size %d, alignment %d) — declare them at the end: %s", c, gap, off, maxAlign, padHint(off, gap, pad))
		return
	}
	named := 0
	for _, f := range r.Fields {
		if !f.Pad {
			named++
		}
	}
	if named == 0 {
		z.add(Rejected, SB024RecordShape, p, "record %s has no named member", c)
		return
	}
	r.Size, r.Align = off, maxAlign
	delete(z.badRecs, c)
	z.records[c] = r
}

// memberNames は record の member の名前の並び (宣言の順)。
func memberNames(r *RecordDecl) string {
	var ns []string
	for _, f := range r.Fields {
		ns = append(ns, f.Name)
	}
	return strings.Join(ns, ", ")
}

// inRootOrSample は n が eBPF の program の def の中か RecordMap.new の見本か (それらは別の検査が見る — 重ねない)。
func (z *analyzer) inRootOrSample(a *AST, n *Node, isRoot map[string]bool) bool {
	for p, ok := a.Parent[n.ID]; ok; p, ok = a.Parent[p] {
		x := a.node(p)
		if x == nil {
			return false
		}
		if x.Type == "DefNode" && isRoot[x.Str["name"]] {
			return true
		}
		if x.Type == "CallNode" && x.Str["name"] == "new" && constName(a, a.ref(x, "receiver")) == "BPF::RecordMap" {
			return true
		}
	}
	return false
}

// padHint は  offset off からの gap byte の穴を埋める `_pad<N>` の member の並び (各 member は自然な alignment — 例 off 1 の 3 byte は `_pad0: :u8, _pad1: :u16`)。
func padHint(off, gap, first int) string {
	var parts []string
	for gap > 0 {
		w := 4
		for w > 1 && (off%w != 0 || w > gap) {
			w /= 2
		}
		parts = append(parts, fmt.Sprintf("`_pad%d: :u%d`", first, w*8))
		first++
		off += w
		gap -= w
	}
	return strings.Join(parts, ", ")
}

// recordMapDecl は  `C = BPF::RecordMap.new("C", S.new(0, …), n)` を読む。
func (z *analyzer) recordMapDecl(a *AST, n *Node) {
	v := a.ref(n, "value")
	c := n.Str["name"]
	p := z.pos(a, n)
	z.badMaps[c] = true
	if _, dup := z.maps[c]; dup {
		z.add(Rejected, SB013MapDeclShape, p, "constant %s is assigned twice", c)
		return
	}
	as := args(a, v)
	if len(as) == 3 && as[1].Type == "CallNode" && z.badRecs[constName(a, a.ref(as[1], "receiver"))] {
		return // record の宣言は既に止めた — 重ねない
	}
	if len(as) != 3 || as[0].Type != "StringNode" || as[1].Type != "CallNode" || as[2].Type != "IntegerNode" {
		z.add(Rejected, SB013MapDeclShape, p, "a record map is declared as `%s = BPF::RecordMap.new(\"%s\", S.new(0, …), max_entries)` with literal arguments", c, c)
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
	sample := as[1]
	sc := constName(a, a.ref(sample, "receiver"))
	r := z.records[sc]
	if sample.Str["name"] != "new" || r == nil {
		z.add(Rejected, SB024RecordShape, z.pos(a, sample), "the sample must be `S.new(0, …)` of a record S declared with BPF.record")
		return
	}
	sas := args(a, sample)
	if len(sas) != len(r.Fields) {
		z.add(Rejected, SB024RecordShape, z.pos(a, sample), "the sample must give all %d members of %s explicitly (an omitted member is nil, which Spinel types as Integer — upstream_suspects S5)", len(r.Fields), sc)
		return
	}
	if !z.sampleArgs(a, sas, r, "the sample's members must be the literal 0 — it is a sample of the type, not an initial value (array entries start as 0 in the kernel)", "") {
		return
	}
	entries, ok := z.literal(a, as[2])
	if !ok {
		return
	}
	if entries.Sign() <= 0 || !entries.IsUint64() || entries.Uint64() > 1<<32-1 {
		z.add(Rejected, SB013MapDeclShape, z.pos(a, as[2]), "max_entries must be a positive integer below 2^32, got %s", entries)
		return
	}
	if reservedPrefix.MatchString(name) {
		z.add(Rejected, SB007ReservedName, p, "map name %q uses the reserved prefix spinelbpf_", name)
		return
	}
	delete(z.badMaps, c)
	m := &MapDecl{Const: c, Name: name, Record: r, MaxEntries: entries.Uint64(), Pos: p}
	if constName(a, a.ref(v, "receiver")) == "BPF::PerCpuRecordMap" {
		m.Kind, m.Class = "percpu_array", "PerCpuRecordMap" // P009
	}
	z.maps[c] = m
	z.mapOrder = append(z.mapOrder, m)
}

// checkMemberDefs は record の member の名前の利用者の def が無いことを構文で確かめる (P006 §2 — Spinel の dispatch が switch / boxed でも、
// 候補が Struct の合成の accessor だけであることの保証 — P006 のレビューの (a) (i))。
func (z *analyzer) checkMemberDefs(a *AST, fid int, roots []rootDecl) {
	isRoot := map[string]bool{}
	for _, r := range roots {
		isRoot[r.Name] = true
	}
	names := map[string]string{}
	for _, r := range z.records {
		for _, f := range r.Fields {
			names[f.Name] = r.Const
			names[f.Name+"="] = r.Const
		}
	}
	if len(names) == 0 {
		return
	}
	walk(a, a.node(a.Root), func(n *Node) bool {
		if a.File(n) != z.base {
			return true
		}
		switch n.Type {
		case "DefNode":
			if rc, ok := names[n.Str["name"]]; ok {
				z.add(Rejected, SB011ShadowedName, z.pos(a, n), "`def %s` shares a name with a member of record %s — the eBPF side reads members by the declaration, so a user method of that name is refused", n.Str["name"], rc)
			}
		case "CallNode":
			if n.Str["name"] == "new" {
				if _, ok := z.records[constName(a, a.ref(n, "receiver"))]; ok {
					rc := z.records[constName(a, a.ref(n, "receiver"))]
					splat := false
					for _, x := range args(a, n) {
						if x.Type == "SplatNode" {
							splat = true
						}
					}
					// 利用者の側の S.new(…) の引数の数 (E021 のレビューの P2 — map_get の値の Array から作る形の取り違えを構文で。eBPF の側と見本は別の検査)
					if !splat && len(args(a, n)) != len(rc.Fields) && !z.inRootOrSample(a, n, isRoot) {
						z.add(Rejected, SB024RecordShape, z.pos(a, n), "`%s.new` takes all %d members of record %s in the declaration order (%s), got %d — e.g. `%s.new(v[0], …, v[%d])` for `v = obj.map_get(M, k)`", rc.Const, len(rc.Fields), rc.Const, memberNames(rc), len(args(a, n)), rc.Const, len(rc.Fields)-1)
					}
					for _, x := range args(a, n) {
						if x.Type == "SplatNode" {
							z.add(Rejected, SB024RecordShape, z.pos(a, n), "`%s.new(*…)` — a splat makes Spinel type every member of record %s as untyped program-wide (the eBPF side then refuses); pass the members explicitly, e.g. `%s.new(v[0], v[1], …)`", constName(a, a.ref(n, "receiver")), constName(a, a.ref(n, "receiver")), constName(a, a.ref(n, "receiver")))
						}
					}
				}
			}
			switch n.Str["name"] {
			case "attr_accessor", "attr_reader", "attr_writer", "alias_method":
				for _, x := range args(a, n) {
					if x.Type == "SymbolNode" {
						if rc, ok := names[x.Str["value"]]; ok {
							z.add(Rejected, SB011ShadowedName, z.pos(a, n), "`%s :%s` shares a name with a member of record %s", n.Str["name"], x.Str["value"], rc)
						}
					}
				}
			}
		case "ClassNode":
			if _, ok := z.records[constName(a, a.ref(n, "constant_path"))]; ok {
				z.add(Rejected, SB011ShadowedName, z.pos(a, n), "record %s is reopened — its members must stay the Struct's accessors", constName(a, a.ref(n, "constant_path")))
			}
		}
		return true
	})
}

// fieldRead は `p.load.m` (P006 §2) — 型・幅・区間は宣言から。u64 の member は Wide (写し・& M・>> K だけ — P002 §1.4)。
func (c *progCtx) fieldRead(n, load *Node, refVar string) *Expr {
	m := c.refMap[refVar]
	name := n.Str["name"]
	f := m.Record.Field(name)
	if f == nil && !memberLike(name) {
		return nil // p.load.dup / == 等 — lookupCheck の walk が SB005 (別名) で止める
	}
	if f != nil && !f.Pad && !c.loadCallee(load) {
		return nil
	}
	switch {
	case f == nil:
		c.add(Rejected, SB002UnsupportedCall, n, "record %s has no member `%s`", m.Record.Const, name)
		return nil
	case f.Pad:
		c.add(Rejected, SB024RecordShape, n, "`%s` is padding — it is neither read nor written on the eBPF side", name)
		return nil
	case len(args(c.a, n)) != 0 || c.a.ref(n, "block") != nil:
		c.add(Rejected, SB002UnsupportedCall, n, "a member read takes no arguments")
		return nil
	case f.Count > 0:
		c.add(Rejected, SB024RecordShape, n, "the array member %s is read by element (`%s.load.%s[k]`) — the array itself is not a value on the eBPF side", name, refVar, name)
		return nil
	}
	e := &Expr{Kind: "fload", Ref: refVar, Map: m, Field: f, Pos: c.z.pos(c.a, n)}
	if f.Bits == 64 && !f.Signed {
		e.Iv, e.Wide = iv(new(big.Int), new(big.Int).Set(u64Max)), true
	} else {
		e.Iv = f.Range()
		if f.Bits == 64 {
			e.Iv = fullI64
		}
	}
	return e
}

// objectMethods は record の値そのものを使う method (別名の形 — SB005)。member の名前と見なさない。
var objectMethods = map[string]bool{"dup": true, "clone": true, "freeze": true, "frozen?": true, "to_a": true, "to_h": true, "deconstruct": true,
	"members": true, "values": true, "each": true, "hash": true, "eql?": true, "equal?": true, "inspect": true, "to_s": true, "size": true, "length": true, "tap": true, "then": true}

var identRe = regexp.MustCompile(`^[a-z_][a-zA-Z0-9_]*$`)

// memberLike は member の読みの名前に見えるか (識別子で、record の値そのものを使う method でない)。
func memberLike(name string) bool { return identRe.MatchString(name) && !objectMethods[name] }

// loadCallee は  `p.load` の呼び先が bpf.rb の RecordRef#load であることを確かめる (member の読み書きの dispatch は宣言から決めるが、load は静的)。
func (c *progCtx) loadCallee(load *Node) bool {
	callee, ok := c.callee(load)
	if !ok {
		return false
	}
	if callee != "RecordRef#load" {
		c.add(Rejected, SB011ShadowedName, load, "`load` resolves to %s, not BPF::RecordRef#load", callee)
		return false
	}
	return true
}

// recordCall は record の member の書き (`p.load.m = e`) と `p.atomic_add(:m, d)` を文として受ける。handled は record の形だったか。
func (c *progCtx) recordCall(n *Node, refVar string) (Stmt, bool, bool) {
	recv := c.a.ref(n, "receiver")
	name := n.Str["name"]
	// p.load.m[k] = e (P016 E066)
	if name == "[]=" && recv != nil && recv.Type == "CallNode" {
		if ld := c.a.ref(recv, "receiver"); ld != nil && ld.Type == "CallNode" && ld.Str["name"] == "load" {
			pv := c.a.ref(ld, "receiver")
			if pv != nil && pv.Type == "LocalVariableReadNode" && c.refs[pv.Str["name"]] != nil && c.refMap[pv.Str["name"]].Record != nil {
				ref := pv.Str["name"]
				if ref != refVar {
					return Stmt{}, false, false // 腕の外 — lookupCheck の walk が止める
				}
				m := c.refMap[ref]
				if !c.loadCallee(ld) {
					return Stmt{}, false, true
				}
				f := m.Record.Field(recv.Str["name"])
				as := args(c.a, n)
				switch {
				case f == nil:
					c.add(Rejected, SB002UnsupportedCall, n, "record %s has no member `%s`", m.Record.Const, recv.Str["name"])
					return Stmt{}, false, true
				case f.Count == 0:
					c.add(Rejected, SB002UnsupportedCall, n, "member %s of record %s is not an array — `[]=` is for array members", f.Name, m.Record.Const)
					return Stmt{}, false, true
				case len(as) != 2:
					c.add(Rejected, SB002UnsupportedCall, n, "an element write is `%s.load.%s[k] = v`", ref, f.Name)
					return Stmt{}, false, true
				}
				c.noteFlow(as[1], m, n) // P023 E092
				if !mutation("no-rmw") && !c.exempt(m) && c.readsRefVia(as[1], ref) { // 同じ entry の read-modify-write (E063 の規則 — entry の粒度)
					c.add(Rejected, SB019SharedReadModifyWrite, n, "`%s.load.%s[…] = …` stores a value read from the same map entry — concurrent CPUs lose updates; use `%s.atomic_add(:%s, k, d)`", ref, f.Name, ref, f.Name)
					return Stmt{}, false, true
				}
				k := c.arrayIndex(as[0], f, ref)
				var ix *Expr
				if k == -2 { // P016 E068: 可変の添字 — 区間で証明して ebpf.ref.index
					if ix = c.varIndex(as[0], f, ref, refVar); ix == nil {
						return Stmt{}, false, true
					}
				} else if k < 0 {
					return Stmt{}, false, true
				}
				v := c.fieldValue(as[1], f, m, refVar)
				if v == nil {
					return Stmt{}, false, true
				}
				if ix != nil {
					return Stmt{Kind: "istore", Var: ref, Map: m, Field: f, Key: ix, Value: v, Pos: c.z.pos(c.a, n)}, true, true
				}
				return Stmt{Kind: "fstore", Var: ref, Map: m, Field: f, Path: fmt.Sprintf("%s[%d]", f.Name, k), Value: v, Pos: c.z.pos(c.a, n)}, true, true
			}
		}
	}
	// P029 E154 (停止 A の直し): kernel の struct の埋め込みの経路への書き `t.load.a.m = v` — 名指しで止める (経路は読みだけ — bpf-mlir も
	// kfield.store の経路を拒否する)。文は program.go:369 の recordCall を通り、式の kpathRead を通らない (そこに置いた検査は届かなかった)
	if strings.HasSuffix(name, "=") && name != "==" && name != "!=" && c.kptrPathRecv(recv) {
		c.add(Rejected, SB033KernelTypeShape, n, "`%s v` writes a kernel struct member through a member path — a member path is read only", name)
		return Stmt{}, false, true
	}
	// p.load.m = e
	if recv != nil && recv.Type == "CallNode" && recv.Str["name"] == "load" && strings.HasSuffix(name, "=") && name != "==" && name != "!=" {
		pv := c.a.ref(recv, "receiver")
		if pv == nil || pv.Type != "LocalVariableReadNode" || c.refs[pv.Str["name"]] == nil || c.refMap[pv.Str["name"]].Record == nil {
			return Stmt{}, false, false
		}
		ref := pv.Str["name"]
		if ref != refVar {
			return Stmt{}, false, false // 腕の外 — lookupCheck の walk が止める
		}
		m := c.refMap[ref]
		if !c.loadCallee(recv) {
			return Stmt{}, false, true
		}
		f := m.Record.Field(strings.TrimSuffix(name, "="))
		as := args(c.a, n)
		switch {
		case f == nil:
			c.add(Rejected, SB002UnsupportedCall, n, "record %s has no member `%s`", m.Record.Const, strings.TrimSuffix(name, "="))
			return Stmt{}, false, true
		case f.Pad:
			c.add(Rejected, SB024RecordShape, n, "`%s` is padding — it is neither read nor written on the eBPF side", f.Name)
			return Stmt{}, false, true
		case len(as) != 1:
			c.add(Rejected, SB002UnsupportedCall, n, "a member write takes one value")
			return Stmt{}, false, true
		case as[0].Type == "CallNode" && as[0].Str["name"] == "copy" && c.isKptrRead(c.a.ref(as[0], "receiver")): // P021 E089: r.load.m = t.copy(:f)
			s, ok := c.kcopyStmt(n, as[0], ref, m, f)
			return s, ok, true
		case c.ctxCopyOtherKind(as[0]): // E153 停止 B: tracepoint でない ctx の copy
			return Stmt{}, false, true
		case c.isTpCopy(as[0]): // P029 E153: r.load.m = ctx.copy(:f)
			s, ok := c.tpcopyStmt(n, as[0], ref, m, f)
			return s, ok, true
		case f.Count > 0:
			c.add(Rejected, SB024RecordShape, n, "the array member %s is written by element (`%s.load.%s[k] = v`) — not as a whole", f.Name, ref, f.Name)
			return Stmt{}, false, true
		}
		c.noteFlow(as[0], m, n) // P023 E092
		if !mutation("no-rmw") && !c.exempt(m) && c.readsRefVia(as[0], ref) { // P015 E063: 局所の出自も // // per-CPU の map は免除 (P009) // 変異の対照 (試験の build だけ): record の member の RMW の検査を外す (E022 の多 CPU) // RMW を値の範囲より先に (E020 の 1 回目 — 範囲の SB014 が先に出て理由を隠した)
			c.add(Rejected, SB019SharedReadModifyWrite, n, "`%s.load.%s = …` stores a value read from the same map entry — concurrent CPUs lose updates; use `%s.atomic_add(:%s, d)`", ref, f.Name, ref, f.Name)
			return Stmt{}, false, true
		}
		v := c.fieldValue(as[0], f, m, refVar)
		if v == nil {
			return Stmt{}, false, true
		}
		return Stmt{Kind: "fstore", Var: ref, Map: m, Field: f, Value: v, Pos: c.z.pos(c.a, n)}, true, true
	}
	// p.atomic_add(:m, d)
	if name == "atomic_add" && recv != nil && recv.Type == "LocalVariableReadNode" && c.refs[recv.Str["name"]] != nil && c.refMap[recv.Str["name"]].Record != nil {
		ref := recv.Str["name"]
		if ref != refVar {
			return Stmt{}, false, false
		}
		m := c.refMap[ref]
		callee, ok := c.callee(n)
		if !ok {
			return Stmt{}, false, true
		}
		if callee != "RecordRef#atomic_add" {
			c.add(Rejected, SB011ShadowedName, n, "`atomic_add` resolves to %s, not BPF::RecordRef#atomic_add", callee)
			return Stmt{}, false, true
		}
		as := args(c.a, n)
		if (len(as) != 2 && len(as) != 3) || as[0].Type != "SymbolNode" {
			c.add(Rejected, SB002UnsupportedCall, n, "`%s.atomic_add` takes a member Symbol literal and a delta (`%s.atomic_add(:member, d)` — an array member also takes the index: `%s.atomic_add(:member, k, d)`)", ref, ref, ref)
			return Stmt{}, false, true
		}
		f := m.Record.Field(as[0].Str["value"])
		switch {
		case f == nil || f.Pad:
			c.add(Rejected, SB002UnsupportedCall, as[0], "record %s has no member `%s` to add to", m.Record.Const, as[0].Str["value"])
			return Stmt{}, false, true
		case f.Bits != 32 && f.Bits != 64:
			c.add(Rejected, SB024RecordShape, as[0], "member %s is %s — atomic_add needs a 32- or 64-bit member (BPF has no narrower atomic add)", f.Name, f.TypeName())
			return Stmt{}, false, true
		case (f.Count > 0) != (len(as) == 3):
			c.add(Rejected, SB002UnsupportedCall, n, "`%s.atomic_add(:%s, …)` takes %s", ref, f.Name, map[bool]string{true: "the index and the delta — `atomic_add(:m, k, d)` for an array member", false: "only the delta — the member is not an array"}[f.Count > 0])
			return Stmt{}, false, true
		}
		path := ""
		if f.Count > 0 { // P016 E066: 定数の添字だけ (可変の添字の atomic は bpf-mlir に無い — elem.atomic_add は候補)
			if as[1].Type != "IntegerNode" {
				c.add(Rejected, SB031IndexRange, as[1], "`%s.atomic_add(:%s, k, d)` needs a literal index — bpf-mlir has no atomic add on a variable-index element; use a per-CPU record map (`BPF::PerCpuRecordMap`, then `%s.load.%s[i] += …` is not shared) or a literal index", ref, f.Name, ref, f.Name)
				return Stmt{}, false, true
			}
			k := c.arrayIndex(as[1], f, ref)
			if k < 0 {
				return Stmt{}, false, true
			}
			path = fmt.Sprintf("%s[%d]", f.Name, k)
			as = as[1:] // as[1] は delta
		}
		c.noteFlow(as[1], m, n) // P023 E092
		if !mutation("no-rmw") && !c.exempt(m) && c.readsRefVia(as[1], ref) { // P015 E063 追記: delta が同じ entry の読み (直か出自) — p.atomic_add (MapRef) と per-CPU の op= と同じ entry の粒度
			c.add(Rejected, SB019SharedReadModifyWrite, n, "`%s.atomic_add(:%s, …)` adds a value read from the same entry — concurrent CPUs interleave the read and the add; use a delta that does not read `%s`", ref, f.Name, ref)
			return Stmt{}, false, true
		}
		d := c.fieldValue(as[1], f, m, refVar)
		if d == nil {
			return Stmt{}, false, true
		}
		return Stmt{Kind: "fatomic", Var: ref, Map: m, Field: f, Path: path, Value: d, Pos: c.z.pos(c.a, n)}, true, true
	}
	return Stmt{}, false, false
}

// readsRef は node が record の借用 ref の読み (`ref.load.…`) を含むか (構文 — 区間の検査の前に RMW を見る)。
func readsRef(a *AST, n *Node, ref string) bool {
	found := false
	walk(a, n, func(x *Node) bool {
		if x.Type == "LocalVariableReadNode" && x.Str["name"] == ref {
			found = true
		}
		return !found
	})
	return found
}

// fieldValue は member に入れる値  (区間が member の型の範囲 — 暗黙の切り詰めをしない、u64 の値は u64 の member への写しだけ)。
func (c *progCtx) fieldValue(n *Node, f *RecordField, m *MapDecl, refVar string) *Expr {
	e := c.expr(n, refVar)
	if e == nil {
		return nil
	}
	if e.Bool {
		c.add(Rejected, SB001UnsupportedConstruct, n, "a bool cannot be stored in a record member")
		return nil
	}
	if e.Wide {
		if f.Bits == 64 && !f.Signed && (e.Kind == "load" || e.Kind == "fload" || e.Kind == "ktime" || e.Kind == "pidtgid" || e.Kind == "retval" || e.Kind == "kparg" || e.Kind == "rawarg" || e.Kind == "tpfield" || e.Kind == "gload" || e.Kind == "kfload") {
			return e
		}
		c.valueOK(e, n)
		return nil
	}
	r := f.Range()
	if !e.Iv.within(r.Lo, r.Hi) {
		c.add(Rejected, SB014SemanticGap, n, "the value's range %s does not fit member %s.%s (%s %s) — the store would truncate silently; narrow it (e.g. `& 0xFF`)", e.Iv, m.Record.Const, f.Name, f.TypeName(), r)
		return nil
	}
	return e
}

// recordUpdate は `M.update(k, S.new(a, b, …))` (全 member を位置の引数で — S5、`_pad<N>` は literal の 0 — P006 §2)。
func (c *progCtx) recordUpdate(n *Node, name string, m *MapDecl, as []*Node, refVar string) (Stmt, bool) {
	if name != "update" {
		c.add(Rejected, SB002UnsupportedCall, n, "`%s.%s` is not accepted on a record map — add to a member with `p = %s.lookup(k)`, `if p`, `p.atomic_add(:member, d)`", m.Const, name, m.Const)
		return Stmt{}, false
	}
	if len(as) != 2 || c.a.ref(n, "block") != nil {
		c.add(Rejected, SB002UnsupportedCall, n, "`update` takes exactly two arguments (key, %s.new(…))", m.Record.Const)
		return Stmt{}, false
	}
	k := c.key(as[0], m, refVar)
	mk := as[1]
	for r := range c.refs {
		if c.refMap[r].Record != nil && mk.Type == "CallNode" && mk.Str["name"] != "new" && readsRef(c.a, mk, r) {
			return Stmt{}, false // p.load / p.load.dup — lookupCheck の walk が SB005 (別名) で止める
		}
	}
	if mk.Type != "CallNode" || mk.Str["name"] != "new" || constName(c.a, c.a.ref(mk, "receiver")) != m.Record.Const {
		c.add(Rejected, SB024RecordShape, mk, "the value of %s.update is `%s.new(…)` with every member", m.Const, m.Record.Const)
		return Stmt{}, false
	}
	if m.Record.HasArray() { // P016 E066: 配列の member を持つ record の組み立て (record.make) はまだ受けない — 要素を member の書きで
		c.add(Rejected, SB024RecordShape, mk, "record %s has an array member — `%s.new(…)` is not built on the eBPF side yet; write its members with `p = %s.lookup(k)`, `if p`, `p.load.m[k] = v`", m.Record.Const, m.Record.Const, m.Const)
		return Stmt{}, false
	}
	vs := args(c.a, mk)
	for _, x := range vs {
		if x.Type == "KeywordHashNode" || x.Type == "SplatNode" {
			c.add(Rejected, SB024RecordShape, x, "%s.new takes positional arguments only", m.Record.Const)
			return Stmt{}, false
		}
	}
	if len(vs) != len(m.Record.Fields) {
		c.add(Rejected, SB024RecordShape, mk, "%s.new must give all %d members explicitly, got %d (an omitted member is nil, which Spinel types as Integer — upstream_suspects S5)", m.Record.Const, len(m.Record.Fields), len(vs))
		return Stmt{}, false
	}
	if c.rmwFirst(n, mk, m, k, func(ref string) string { // P015 E062: RMW を値の区間より先に (形の SB024 の後)
		return fmt.Sprintf("`%s.update` stores a value read from the same map (`%s.load`) — concurrent CPUs lose updates (keys must be different literals to accept this form)", m.Name, ref)
	}) {
		return Stmt{}, false
	}
	e := &Expr{Kind: "rmake", Map: m, Pos: c.z.pos(c.a, mk)}
	for i, x := range vs {
		f := &m.Record.Fields[i]
		if f.Pad {
			lit, ok := big.NewInt(1), x.Type == "IntegerNode"
			if ok {
				lit, ok = c.z.literal(c.a, x)
			}
			if !ok || lit.Sign() != 0 {
				c.add(Rejected, SB024RecordShape, x, "padding member %s must be the literal 0", f.Name)
				return Stmt{}, false
			}
			e.Args = append(e.Args, &Expr{Kind: "lit", Lit: new(big.Int), Iv: point(new(big.Int)), Pos: c.z.pos(c.a, x)})
			continue
		}
		v := c.fieldValue(x, f, m, refVar)
		if v == nil {
			return Stmt{}, false
		}
		e.Args = append(e.Args, v)
	}
	if k == nil {
		return Stmt{}, false
	}
	if ref, ok := readsMap(e, m); ok && !c.exempt(m) { // per-CPU の map は免除 (P009)
		lk := c.refKey[ref]
		if lk == nil || lk.Kind != "lit" || k.Kind != "lit" || lk.Lit.Cmp(k.Lit) == 0 {
			c.add(Rejected, SB019SharedReadModifyWrite, n, "`%s.update` stores a value read from the same map (`%s.load`) — concurrent CPUs lose updates (keys must be different literals to accept this form)", m.Name, ref)
			return Stmt{}, false
		}
	}
	return Stmt{Kind: "update", Map: m, Key: k, Value: e, Pos: c.z.pos(c.a, n)}, true
}

// RecordsTable は埋め込みの layout の表 (record の map ごとに `Map|S|size=N;m:off:type;…` — padding の member も、1 行ずつ。record の map が無ければ "")。
// Ruby の library が bytes ⇄ Struct の写しに使う (P006 §3)。build は schema と照合する。
func RecordsTable(res *Result) string {
	var b strings.Builder
	for _, m := range res.Maps {
		if m.KeyRecord != nil { // hash の record の key (P008 §3 — 行の名前は `M:key`)
			b.WriteString(m.Name + ":key|" + m.KeyRecord.Shape() + "\n")
		}
		if m.Record != nil {
			b.WriteString(m.Name + "|" + m.Record.Shape() + "\n")
		}
	}
	for _, r := range res.Rings {
		b.WriteString(r.Name + "|" + r.Record.Shape() + "\n")
	}
	b.WriteString(globalRows(res.Globals)) // P014 E057: `G|name|section|type|opt`
	return b.String()
}

// oneReasonEach は止める診断を 1 つの理由ずつにまとめる (E026 のレビューの P3 — 負の例ごとに診断はちょうど want の数):
// 同じ位置と code の重複を落とし、他に止める理由があれば注入の比較器 (SB010) を全て落とし (形の誤りは型の推論を乱す — 形を先に言う)、builtin の再オープン (SB016) が在れば
// その結果の演算子の再定義 (SB009) を落とす。Conditional は落とさない。
func oneReasonEach(ds Diags) Diags {
	stop := func(d Diag) bool { return d.Verdict == Rejected || d.Verdict == Unknown }
	hasReopen := false
	other := false
	// SB027 (eBPF の側の Thread) の位置の SB001 / SB002 は同じ参照の一般の拒否 — 名指しの SB027 だけを残す (P012 E048)
	threadAt := map[string]bool{}
	for _, d := range ds {
		if stop(d) && d.Code == SB016DynamicProgram {
			hasReopen = true
		}
		if stop(d) && d.Code == SB027ThreadInBPFSide {
			threadAt[d.Pos.String()] = true
		}
		if stop(d) && d.Code != SB010TypingProbe {
			other = true
		}
	}
	seen := map[string]bool{}
	var out Diags
	for _, d := range ds {
		if stop(d) {
			k := string(d.Code) + "@" + d.Pos.String()
			if seen[k] || (d.Code == SB010TypingProbe && other) || (d.Code == SB009OperatorRedefined && hasReopen) ||
				((d.Code == SB001UnsupportedConstruct || d.Code == SB002UnsupportedCall) && threadAt[d.Pos.String()]) {
				continue
			}
			seen[k] = true
		}
		out = append(out, d)
	}
	return out
}

// sampleArgs は見本の member の引数 (整数の member は literal の 0、配列の member は `Array.new(N, 0)` で N は宣言の長さ — P016 E066)。
// where は配列の member を受けない所の説明 ("" は受ける)。誤りは SB024 で false。
func (z *analyzer) sampleArgs(a *AST, sas []*Node, r *RecordDecl, zeroMsg, where string) bool {
	for i, x := range sas {
		f := r.Fields[i]
		if f.Count > 0 {
			// P020 E080: ring の event の :u8 の配列の member は受ける (output_str の user の文字列の受け手 — 他の配列は今のまま止める)
			if where != "" && !(where == "a ring buffer event" && f.Bits == 8 && !f.Signed) {
				z.add(Rejected, SB024RecordShape, z.pos(a, x), "record %s has the array member %s — %s takes records without array members (array members are for record map values)", r.Const, f.Name, where)
				return false
			}
			as := args(a, x)
			if x.Type != "CallNode" || x.Str["name"] != "new" || constName(a, a.ref(x, "receiver")) != "Array" || len(as) != 2 || as[0].Type != "IntegerNode" || as[1].Type != "IntegerNode" {
				z.add(Rejected, SB024RecordShape, z.pos(a, x), "the sample of the array member %s is `Array.new(%d, 0)`", f.Name, f.Count)
				return false
			}
			n, ok1 := z.literal(a, as[0])
			zero, ok2 := z.literal(a, as[1])
			if !ok1 || !ok2 || zero.Sign() != 0 {
				z.add(Rejected, SB024RecordShape, z.pos(a, x), "the sample of the array member %s is `Array.new(%d, 0)`", f.Name, f.Count)
				return false
			}
			if !n.IsInt64() || n.Int64() != int64(f.Count) {
				z.add(Rejected, SB024RecordShape, z.pos(a, as[0]), "the sample of the array member %s has %s elements, but BPF.record declares %d — they must be the same", f.Name, n, f.Count)
				return false
			}
			continue
		}
		lit, ok := big.NewInt(1), x.Type == "IntegerNode"
		if ok {
			lit, ok = z.literal(a, x)
		}
		if !ok || lit.Sign() != 0 {
			z.add(Rejected, SB024RecordShape, z.pos(a, x), "%s", zeroMsg)
			return false
		}
	}
	return true
}

// indexHint は SB031 の直し方 (P016 のレビュー — N が 2 冪でない時の `& (N−1)` の注意)。
func indexHint(n int) string {
	if n&(n-1) == 0 {
		return fmt.Sprintf("narrow it into [0, %d] (e.g. `i & %d`, `i %% %d` or inside `if i >= 0 && i < %d`)", n-1, n-1, n, n)
	}
	return fmt.Sprintf("narrow it into [0, %d] (e.g. inside `if i >= 0 && i < %d`, or `i %% %d` for a non-negative i — %d is not a power of two, so no mask `i & M` covers exactly [0, %d]: `i & %d` can reach %d)", n-1, n, n, n, n-1, pow2Above(n)-1, pow2Above(n)-1)
}

// arrayIndex は配列の member の添字 (E066 — literal の 0..N−1 だけ。可変の添字は E067)。誤りは SB031 で -1。
func (c *progCtx) arrayIndex(x *Node, f *RecordField, ref string) int64 {
	if x.Type != "IntegerNode" {
		return -2 // 可変の添字 — 呼び手が区間で (P016 E068)
	}
	v, ok := c.z.literal(c.a, x)
	if !ok {
		return -1
	}
	if v.Sign() < 0 || !v.IsInt64() || v.Int64() >= int64(f.Count) {
		c.add(Rejected, SB031IndexRange, x, "the index %s is outside [0, %d] of %s.load.%s (Ruby reads nil past the end and counts a negative index from the end; BPF has neither)", v, f.Count-1, ref, f.Name)
		return -1
	}
	return v.Int64()
}

// elemRead は `p.load.m[k]` (P016 E066 — 配列の member の定数の添字 → ref.field.load の経路 `m[k]`)。
func (c *progCtx) elemRead(n, mem, load *Node, refVar string) *Expr {
	m := c.refMap[refVar]
	f := m.Record.Field(mem.Str["name"])
	switch {
	case f == nil || f.Pad:
		return c.fieldRead(mem, load, refVar) // 名前の誤り・padding は member の読みの文で
	case f.Count == 0:
		c.add(Rejected, SB002UnsupportedCall, n, "member %s of record %s is not an array — `[]` is for array members", f.Name, m.Record.Const)
		return nil
	case len(args(c.a, mem)) != 0 || len(args(c.a, n)) != 1 || c.a.ref(n, "block") != nil:
		c.add(Rejected, SB002UnsupportedCall, n, "an element read is `%s.load.%s[k]` with one index", refVar, f.Name)
		return nil
	}
	if !c.loadCallee(load) {
		return nil
	}
	k := c.arrayIndex(args(c.a, n)[0], f, refVar)
	var e *Expr
	switch {
	case k == -2: // P016 E068: 可変の添字 — 区間で証明して ebpf.ref.index
		ix := c.varIndex(args(c.a, n)[0], f, refVar, refVar)
		if ix == nil {
			return nil
		}
		e = &Expr{Kind: "iload", Ref: refVar, Map: m, Field: f, Args: []*Expr{ix}, Pos: c.z.pos(c.a, n)}
	case k < 0:
		return nil
	default:
		e = &Expr{Kind: "fload", Ref: refVar, Map: m, Field: f, Path: fmt.Sprintf("%s[%d]", f.Name, k), Pos: c.z.pos(c.a, n)}
	}
	if f.Bits == 64 && !f.Signed {
		e.Iv, e.Wide = iv(new(big.Int), new(big.Int).Set(u64Max)), true
	} else {
		e.Iv = f.Range()
		if f.Bits == 64 {
			e.Iv = fullI64
		}
	}
	return e
}

// varIndex は可変の添字の式 (P016 E068): 区間 ⊆ [0, N−1] を示せれば添字の Expr、示せなければ SB031 で nil。
func (c *progCtx) varIndex(x *Node, f *RecordField, ref, refVar string) *Expr {
	e := c.expr(x, refVar)
	if e == nil {
		return nil
	}
	if e.Bool || e.Wide {
		c.add(Rejected, SB031IndexRange, x, "the index of %s.load.%s must be an Integer (not a bool, not an unnarrowed u64 value)", ref, f.Name)
		return nil
	}
	if !e.Iv.within(bigZero, big.NewInt(int64(f.Count-1))) {
		neg := ""
		if e.Iv.Lo.Sign() < 0 {
			neg = " — a negative index counts from the end in Ruby, BPF has no such index"
		}
		c.add(Rejected, SB031IndexRange, x, "the index of %s.load.%s has range %s, not inside [0, %d]%s; %s", ref, f.Name, e.Iv, f.Count-1, neg, indexHint(f.Count))
		return nil
	}
	return e
}

// pow2Above は n 以上の最小の 2 の冪。
func pow2Above(n int) int {
	p := 1
	for p < n {
		p <<= 1
	}
	return p
}
