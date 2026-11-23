package frontend

import (
	"encoding/json"
)

// schema (bpf-mlir v0.8.0 の docs/schema_format.md — mojo-bpf-mlir の生成物と同じ形)・maps.json (bindrt.MapDecls の形 — loader の段 2' の宣言)・
// domain-graph (root・到達・Membership・辺・判定)。出力は同じ入力から byte で同じ (map の順は宣言の順、JSON の key の順は構造体の順)。

type schemaInt struct {
	Kind       string `json:"kind"`
	Bits       int    `json:"bits"`
	Signed     bool   `json:"signed"`
	Endianness string `json:"endianness"`
	Alignment  int    `json:"alignment"`
}

type schemaMap struct {
	Symbol     string    `json:"symbol"`
	Kind       string    `json:"kind"`
	Key        any       `json:"key"`   // schemaInt か schemaRecordRef (P008 — hash の record の key)
	Value      any       `json:"value"` // schemaInt か schemaRecordRef (P006)
	MaxEntries uint64    `json:"max_entries"`
	Flags      int       `json:"flags"`
	Record     string    `json:"record"`
	Note       string    `json:"note"`
}

type schemaRecordRef struct {
	Kind   string `json:"kind"`
	Symbol string `json:"symbol"`
}

type schemaField struct {
	Name   string    `json:"name"`
	Offset int       `json:"offset"`
	Expose string    `json:"expose"`
	Note   string    `json:"note"`
	Type   any       `json:"type"` // schemaInt か schemaArray (P016 E066)
}

// schemaArray は配列の member の型 (bpf-mlir の type(array) — count ≥ 1、要素は整数 — P016 E066)。
type schemaArray struct {
	Kind    string    `json:"kind"`
	Count   int       `json:"count"`
	Element schemaInt `json:"element"`
}

type schemaRecord struct {
	Symbol          string        `json:"symbol"`
	ID              int           `json:"id"`
	Size            int           `json:"size"`
	MinSize         int           `json:"min_size"`
	Alignment       int           `json:"alignment"`
	RequiredThrough string        `json:"required_through"`
	Note            string        `json:"note"`
	Fields          []schemaField `json:"fields"`
}

// usedRecords は map が使う record (map の順・重複なし — schema の records と maps.json の records の順)。
func usedRecords(res *Result) []*RecordDecl {
	var out []*RecordDecl
	seen := map[*RecordDecl]bool{}
	for _, m := range res.Maps {
		for _, r := range []*RecordDecl{m.KeyRecord, m.Record} { // key の record (P008) を先に
			if r != nil && !seen[r] {
				seen[r] = true
				out = append(out, r)
			}
		}
	}
	for _, r := range res.Rings {
		if !seen[r.Record] {
			seen[r.Record] = true
			out = append(out, r.Record)
		}
	}
	return out
}

// schemaRing は ring buffer の map (bpf-mlir の形 — key / value は無く record に event の record の名前)。
type schemaRing struct {
	Symbol     string `json:"symbol"`
	Kind       string `json:"kind"`
	MaxEntries uint64 `json:"max_entries"`
	Flags      int    `json:"flags"`
	Record     string `json:"record"`
	Note       string `json:"note"`
}

type schemaProgram struct {
	Name         string   `json:"name"`
	Kind         string   `json:"kind"`
	AttachTarget string   `json:"attach_target"`
	// tracing (P013 E051 — schema_format.md §programs): fexit の nargs と ret、kprobe の arch と params (xdp の JSON は変えない — 出さない)
	Nargs        *int          `json:"nargs,omitempty"`
	Ret          *schemaInt    `json:"ret,omitempty"`
	Maps         []string      `json:"maps"`
	Arch         string        `json:"arch,omitempty"`
	Params       []schemaParam `json:"params,omitempty"`
	BinarySHA256 string        `json:"binary_sha256,omitempty"` // uprobe (P020 E080)
	Args         []any         `json:"args,omitempty"`          // tp_btf (P021 E086 — 位置の配列、読まない引数は null)
	Fields       []schemaTpField `json:"fields,omitempty"`      // tracepoint (P026 E114 — 宣言の順)
	Note         string        `json:"note"`
}

// schemaTpField は tracepoint の event の field の宣言 (P026 E114 — schema_format.md の core.programs[].fields[])。
type schemaTpField struct {
	Name   string    `json:"name"`
	Offset int64     `json:"offset"`
	Type   any       `json:"type"` // 整数は schemaInt、P028 E142: :user_str は {kind: user_str}
}

// schemaParam は kprobe の引数 (n は 1 始まりの register の番号 — Ruby の ctx.arg(n) と同じ)。
// schemaKernelType は core.kernel_types の要素 (P021 E086)。
type schemaKernelType struct {
	Name   string         `json:"name"`
	Note   string         `json:"note"`
	Fields []schemaKField `json:"fields"`
}

type schemaKField struct {
	Name string `json:"name"`
	Type any    `json:"type"`
}

type schemaKPtr struct {
	Kind   string `json:"kind"`
	Struct string `json:"struct"`
}

type schemaParam struct {
	N    int `json:"n"`
	Type any `json:"type"` // schemaInt、uprobe の :user_str は schemaUserStr (P020 E080)
}

// schemaUserStr は params の type(user_str) と kprobe の type(ptr) (P026 E116) (schema_format.md — key は kind だけ)。
type schemaUserStr struct {
	Kind string `json:"kind"`
}

// schemaTpArray は tracepoint の固定 byte の配列の field の型 (P029 E153 — bpf-mlir E552 の `{kind: array, elem: u8|i8, n: N}`)。
type schemaTpArray struct {
	Kind string `json:"kind"`
	Elem string `json:"elem"`
	N    int    `json:"n"`
}

// traceInt は :i32 等の型の名前の schema の整数。
func traceInt(t string) schemaInt {
	rt := recordTypes[t]
	return schemaInt{"int", rt[0], rt[1] == 1, "little", rt[0] / 8}
}

// schemaGlobal は core.globals の要素 (schema_format.md — name・section・type)。
type schemaGlobal struct {
	Name    string    `json:"name"`
	Section string    `json:"section"`
	Type    schemaInt `json:"type"`
	Note    string    `json:"note"`
}

type schemaDoc struct {
	Version  int `json:"version"`
	Coverage struct {
		Programs  string `json:"programs"`
		Maps      string `json:"maps"`
		Records   string `json:"records"`
		Telemetry string `json:"telemetry"`
	} `json:"coverage"`
	Core struct {
		KernelTypes []schemaKernelType `json:"kernel_types,omitempty"` // P021 E086 — CO-RE の局所型 (tp_btf の program が在る時だけ — 無い schema は今と byte 同じ)
		Records  []any           `json:"records"`
		Maps     []any           `json:"maps"` // schemaMap か schemaRing (P007)
		Programs []schemaProgram `json:"programs"`
		Globals  []schemaGlobal  `json:"globals,omitempty"` // P014 E057 — 使う global が在る時だけ (無い program の schema は今と byte 同じ)
	} `json:"core"`
	Telemetry struct {
		Clocks     []any `json:"clocks"`
		ValueMaps  []any `json:"value_maps"`
		BoundsSets []any `json:"bounds_sets"`
		Signals    []any `json:"signals"`
	} `json:"telemetry"`
	Extensions struct{} `json:"extensions"`
}

func uint32T() schemaInt { return schemaInt{"int", 32, false, "little", 4} }

// Schema は schema の JSON (末尾の改行付き)。source の位置を入れない (無関係な行の追加で schema が変わらない — CLAUDE.md)。
func Schema(res *Result) ([]byte, error) {
	var d schemaDoc
	d.Version = 1
	d.Coverage.Programs, d.Coverage.Maps, d.Coverage.Records, d.Coverage.Telemetry = "complete", "complete", "complete", "complete"
	d.Core.Records = []any{}
	d.Core.Maps = []any{}
	d.Core.Programs = []schemaProgram{}
	d.Telemetry.Clocks, d.Telemetry.ValueMaps, d.Telemetry.BoundsSets, d.Telemetry.Signals = []any{}, []any{}, []any{}, []any{}
	for i, r := range usedRecords(res) {
		sr := schemaRecord{Symbol: r.Const, ID: i, Size: r.Size, MinSize: r.Size, Alignment: r.Align, RequiredThrough: "", Note: "Ruby Struct " + r.Const, Fields: []schemaField{}}
		for _, f := range r.Fields {
			if f.Pad {
				continue // padding は schema に書かない (穴 — record.make が 0 にする)
			}
			var t any = schemaInt{"int", f.Bits, f.Signed, "little", f.Bits / 8}
			if f.Count > 0 {
				t = schemaArray{"array", f.Count, schemaInt{"int", f.Bits, f.Signed, "little", f.Bits / 8}}
			}
			sr.Fields = append(sr.Fields, schemaField{Name: f.Name, Offset: f.Offset, Expose: "int", Type: t})
		}
		d.Core.Records = append(d.Core.Records, sr)
	}
	for _, m := range res.Maps {
		var v any = schemaInt{"int", m.ValueBits, m.Signed, "little", m.ValueBits / 8}
		if m.Record != nil {
			v = schemaRecordRef{Kind: "record_ref", Symbol: m.Record.Const}
		}
		var k any = uint32T()
		switch {
		case m.KeyRecord != nil:
			k = schemaRecordRef{Kind: "record_ref", Symbol: m.KeyRecord.Const}
		case m.IsHash():
			k = schemaInt{"int", m.KeyBits, m.KeySigned, "little", m.KeyBits / 8}
		}
		d.Core.Maps = append(d.Core.Maps, schemaMap{Symbol: m.Name, Kind: m.MapKind(), Key: k, Value: v, MaxEntries: m.MaxEntries, Flags: int(m.Flags()), Record: "", Note: "Ruby constant " + m.Const})
	}
	for _, r := range res.Rings {
		d.Core.Maps = append(d.Core.Maps, schemaRing{Symbol: r.Name, Kind: "ringbuf", MaxEntries: ringSize(r), Record: r.Record.Const, Note: "Ruby constant " + r.Const})
	}
	d.Core.KernelTypes = kernelTypesSchema(res) // P021 E086
	for _, p := range res.Programs {
		sp := schemaProgram{Name: p.Name, Kind: p.Kind, AttachTarget: p.Target, Maps: []string{}, Note: "Ruby def " + p.Name}
		switch p.Kind {
		case "fexit":
			n, r := p.Nargs, traceInt(p.Ret)
			sp.Nargs, sp.Ret = &n, &r
		case "fmod_ret": // P028 E144: nargs と ret は必須 (requirements の retsig — E404)、args は整数と null (farg)
			n, r := p.Nargs, traceInt(p.Ret)
			sp.Nargs, sp.Ret = &n, &r
			sp.Args = fmodArgsSchema(p)
		case "kretprobe": // P026 E111: arch だけ (params は持たない)
			sp.Arch = "x86_64"
		case "uretprobe": // P026 E112: arch と binary_sha256 (params は持たない)
			sp.Arch, sp.BinarySHA256 = "x86_64", p.BinarySHA
		case "kprobe", "uprobe", "ksyscall": // P026 E115: ksyscall も arch と params (syscall の引数)
			sp.Arch = "x86_64"
			for _, kp := range p.Params {
				if kp.Type == "ptr" { // P026 E116: kprobe の pointer の引数 (requirements の kprobearg … ptr)
					sp.Params = append(sp.Params, schemaParam{N: kp.N, Type: schemaUserStr{"ptr"}})
					continue
				}
				if kp.Type == "user_str" || kp.Type == "user_str_array" || kp.Type == "user_buf" { // P028 E143 / E151、P029 E158: user_buf
					sp.Params = append(sp.Params, schemaParam{N: kp.N, Type: schemaUserStr{kp.Type}})
					continue
				}
				sp.Params = append(sp.Params, schemaParam{N: kp.N, Type: traceInt(kp.Type)})
			}
			sp.BinarySHA256 = p.BinarySHA
		case "tp_btf": // P021 E086
			sp.Args = tpArgsSchema(p)
		case "tracepoint": // P026 E114
			for _, f := range p.TFields {
				var t any = traceInt(f.Type)
				if f.Type == "user_str" || f.Type == "user_str_array" { // P028 E142 / E151
					t = schemaUserStr{f.Type}
				}
				if f.N > 0 { // P029 E153
					t = schemaTpArray{Kind: "array", Elem: f.Type, N: f.N}
				}
				sp.Fields = append(sp.Fields, schemaTpField{Name: f.Name, Offset: f.Offset, Type: t})
			}
		case "fentry": // P021 E089: args の在る fentry だけ (無ければ今と byte 同じ)
			if len(p.TArgs) > 0 {
				sp.Args = tpArgsSchema(p)
			}
		}
		for _, m := range p.Maps {
			sp.Maps = append(sp.Maps, m.Name)
		}
		d.Core.Programs = append(d.Core.Programs, sp)
	}
	for _, g := range res.Globals {
		d.Core.Globals = append(d.Core.Globals, schemaGlobal{Name: g.Name, Section: g.Section, Type: schemaInt{"int", g.Bits, g.Signed, "little", g.Bits / 8}, Note: "Ruby constant " + g.Const + " (" + g.Class + ")"})
	}
	b, err := json.MarshalIndent(d, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// mapDeclJSON は bindrt.MapDecl と同じ JSON の形 (loader が go/bindrt に渡す — E003)。
type mapDeclJSON struct {
	Name       string `json:"name"`
	Kind       string `json:"kind"`
	Key        string `json:"key"`
	Value      string `json:"value"`
	MaxEntries uint64 `json:"max_entries"`
	Flags      uint64 `json:"flags,omitempty"` // E121: lpm_trie の BPF_F_NO_PREALLOC (bml は宣言と ELF の flags を照らす — 0 の kind は書かず既存の文書と byte 同じ)
}

// MapsJSON は map の宣言の文書 (bindrt.MapDecls の形 — 仕様 docs/requirements_format.md §12)。
func MapsJSON(res *Result) ([]byte, error) {
	type member struct {
		Name   string `json:"name"`
		Offset int    `json:"offset"`
		Type   string `json:"type"`
	}
	type shape struct {
		Size    int      `json:"size"`
		Members []member `json:"members"`
	}
	doc := struct {
		Records map[string]shape `json:"records,omitempty"` // 仕様 §12 — bindrt.CheckMapDecls が ELF の BTF と照合 (P006 §1、R002 の Q5)
		Maps    []mapDeclJSON    `json:"maps"`
		Globals []globalJSON     `json:"globals,omitempty"` // 仕様 §12 (E308) — 在れば ELF の DATASEC と双方向に照合 (P014 E057)
	}{Maps: []mapDeclJSON{}}
	for _, r := range usedRecords(res) {
		if doc.Records == nil {
			doc.Records = map[string]shape{}
		}
		sh := shape{Size: r.Size, Members: []member{}}
		for _, f := range r.Fields {
			if !f.Pad {
				sh.Members = append(sh.Members, member{f.Name, f.Offset, f.DeclType()})
			}
		}
		doc.Records[r.Const] = sh
	}
	for _, m := range res.Maps {
		fl := m.Flags()
		if mutation("lpm-no-flags") { // 変異の対照 (試験の build だけ — E121 追補 1): 埋め込みの宣言から flags を落とす
			fl = 0
		}
		doc.Maps = append(doc.Maps, mapDeclJSON{Name: m.Name, Kind: m.MapKind(), Key: m.KeyTypeName(), Value: m.TypeName(), MaxEntries: m.MaxEntries, Flags: fl})
	}
	for _, g := range res.Globals {
		doc.Globals = append(doc.Globals, globalJSON{Name: g.Name, Section: g.Section, Type: g.TypeName()})
	}
	for _, r := range res.Rings {
		doc.Maps = append(doc.Maps, mapDeclJSON{Name: r.Name, Kind: "ringbuf", Key: "-", Value: "record:" + r.Record.Const, MaxEntries: ringSize(r)})
	}
	b, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

type domainFunc struct {
	Name       string   `json:"name"`
	Membership []string `json:"membership"`
}

type domainRoot struct {
	Name string `json:"name"`
	Kind string `json:"kind"`
	Decl Pos    `json:"decl"`
	Def  Pos    `json:"def"`
}

type domainDiag struct {
	Verdict string   `json:"verdict"`
	Code    Code     `json:"code"`
	Name    string   `json:"name"`
	Pos     Pos      `json:"pos"`
	Path    []string `json:"path,omitempty"`
	Message string   `json:"message"`
}

// DomainGraph は段ごとの成果物 `--emit=domain-graph` の JSON (P001 §3.2)。位置を含む (schema と違い診断用)。
func DomainGraph(res *Result) ([]byte, error) {
	doc := struct {
		Source    string       `json:"source"`
		Roots     []domainRoot `json:"roots"`
		Functions []domainFunc `json:"functions"`
		Edges     []Edge       `json:"edges"`
		Diags     []domainDiag `json:"diagnostics"`
	}{Source: res.Source, Roots: []domainRoot{}, Functions: []domainFunc{}, Edges: []Edge{}, Diags: []domainDiag{}}
	for _, p := range res.Programs {
		doc.Roots = append(doc.Roots, domainRoot{Name: p.Name, Kind: p.Kind, Decl: p.DeclPos, Def: p.Pos})
	}
	var names []string
	for n := range res.Membership {
		names = append(names, n)
	}
	sortStrings(names)
	for _, n := range names {
		doc.Functions = append(doc.Functions, domainFunc{Name: n, Membership: res.Membership[n]})
	}
	if res.Edges != nil {
		doc.Edges = res.Edges
	}
	for _, d := range res.Diags.Sorted() {
		doc.Diags = append(doc.Diags, domainDiag{Verdict: d.Verdict.String(), Code: d.Code, Name: d.Code.Name(), Pos: d.Pos, Path: d.Path, Message: d.Msg})
	}
	b, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// ringSize は schema と maps.json に書く ring buffer の大きさ。変異の対照 ring-size (試験の build だけ — E028) は 2 倍にする (大きさを誤る frontend — 双子は宣言の大きさで数える)。
func ringSize(r *RingDecl) uint64 {
	if mutation("ring-size") {
		return r.Size * 2
	}
	return r.Size
}

// globalJSON は maps.json の globals の要素 ({name, section, type} — bml の strict な読みと同じ key)。
type globalJSON struct {
	Name    string `json:"name"`
	Section string `json:"section"`
	Type    string `json:"type"`
}
