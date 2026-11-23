// Package frontend は Ruby (Spinel) の program の eBPF の側を bpf-mlir の ebpf dialect (段 ①) の .mlir と schema にする (P001)。
//
// Ruby を自分で parse しない。Spinel の text AST (`--dump-ast --emit-types`) と推論の型 (`--emit-types` の JSON) を読み、
// Spinel を「Go の go/types の役」にする (R001 §1)。受ける形は P001 §3 の表だけで、外は位置付きで loud に止める (fail closed)。
package frontend

import (
	"fmt"
	"sort"
	"strings"
)

// Verdict は判定の 4 値 (bpf-mlir の CheckResult と同じ意味 — P001 §3.2、go-bpf-mlir・mojo-bpf-mlir と同じ形)。
// Verified と Conditional 以外は生成を止める。
type Verdict int

const (
	Verified Verdict = iota
	Rejected
	Conditional
	Unknown
)

func (v Verdict) String() string {
	switch v {
	case Verified:
		return "verified"
	case Rejected:
		return "rejected"
	case Conditional:
		return "conditional"
	case Unknown:
		return "unknown"
	}
	return fmt.Sprintf("verdict(%d)", int(v))
}

// Code は reason code。**増やしてよいが意味を変えない** (P001 §3.2)。
//
// 理由の優先順位 (E020 のレビューの P3 — 1 つの行に複数の理由が当てはまるとき、どれを言うか。E020 の 1 回目の誤り 5 つの再発を防ぐ表):
//
//  1. 宣言の誤り (SB013 / SB024 — map・record の宣言) は宣言の位置で 1 度だけ。宣言の止まった map を使う側で別の理由 (lookup の SB011 等) を重ねない
//  2. 構文の形 (別名の SB005・read-modify-write の SB019) は値の区間 (SB014) より先に見る — 区間の誤りは形が正しいときだけ言う (RMW が範囲に隠れた誤り)
//  3. 名前の存在 (知らない member の SB002) は呼び先の検査 (Spinel の codegen の SB004 / callee の SB011) より先 — Spinel が record を出さない名前を「静的でない呼び出し」と言わない
//  4. 別名の形 (値そのものを使う method — dup・== 等) は walk の SB005 だけで言い、member の不在 (SB002) を重ねない
//  5. 直し方の案内は受理される形だけを示す (存在しない型の `_pad0: :u24` を示さない — 案内の文も負の例で見る)
//  6. AST の field の名前は Spinel の --dump-ast で確かめる (Prism の CallOperatorWriteNode は `name` — read_name ではない)
//  7. status を捨てる文・読まれない / 2 度代入の status の局所 (SB026) は引数 (key / value) の検査より先 — 受ける形を直した後で引数の誤りを言う。2 度代入は最初の代入の位置で 1 度だけ (P008 E032)
type Code string

const (
	SB000Spinel               Code = "SB000" // Spinel が program を拒否した・出力を読めない
	SB001UnsupportedConstruct Code = "SB001" // 表に無い構文・型・値
	SB002UnsupportedCall      Code = "SB002" // 表に無い呼び出し・呼び先
	SB003CrossDomainUse       Code = "SB003" // {User, BPF} の関数・両側の API の誤用
	SB004UnknownEdge          Code = "SB004" // 静的に辿れない辺 (switch / boxed / record の無い呼び出し)
	SB005RefCheckShape        Code = "SB005" // present の検査の形の外
	SB006NonConstant          Code = "SB006" // 定数が要る所の非定数
	SB007ReservedName         Code = "SB007" // 予約の接頭辞 (_spinelbpf_ / spinelbpf_)
	SB008ProgramShape         Code = "SB008" // BPF.xdp の宣言と def の形
	SB009OperatorRedefined    Code = "SB009" // builtin の演算子の呼び出しに callee が付いた (利用者の再定義)
	SB010TypingProbe          Code = "SB010" // root の型付けの注入の検査 (P001 §3.3 (ii) / (iii))
	SB011ShadowedName         Code = "SB011" // bpf.rb の名前の再オープン・同じ名前の class・呼び先が bpf.rb に無い
	SB012ThreadInUserSide     Code = "SB012" // 欠番 (E049 — user の側の Thread を許した。前は Thread 等を使う program を止めた — P001 §3.7)
	SB013MapDeclShape         Code = "SB013" // map の宣言の形 (名前と文字列の不一致・同じ文字列の 2 つの宣言・引数)
	SB014SemanticGap          Code = "SB014" // Ruby と BPF の意味の差 (literal の範囲 — P001 §3.8)
	SB015AmbiguousType        Code = "SB015" // 1 つの node に 2 つ以上の型の record (特殊化 — R001 §1.3)
	SB016DynamicProgram       Code = "SB016" // builtin の再オープン・method_missing / define_method / send / eval 等 (P001 §3.5 — 静的な呼び先の前提が崩れる)
	SB017InternalEmitter      Code = "SB017" // frontend の内部の誤り (verify-bpf-world 等)
	SB018LogicalSideEffect    Code = "SB018" // && || の右の operand の副作用 (Ruby は短絡 — P002 §1.2)
	SB019SharedReadModifyWrite Code = "SB019" // 同じ map の load の値を同じ map の update に (多 CPU で数え落とす — P002 §1.4)
	SB020KeyOutOfRange        Code = "SB020" // map の key の区間が [0, max_entries − 1] に収まらない (array の update は黙って失敗 — P002 §1.4)
	SB021CompileWarning       Code = "SB021" // ebpf-compile の rc 0 の warning (bpf-mlir v0.10.0 E274 — Conditional、build は止めない — P003 §2)
	SB022WindowIndex          Code = "SB022" // window の長さが [1, 65535] の外・読みの添字が window の外 (P004 §1)
	SB025DroppedEvent         Code = "SB025" // ring buffer の output の結果 (予約の成否) を捨てる形 — if / unless の条件か `_ = …` だけ (P007 §2)
	SB024RecordShape          Code = "SB024" // record の宣言の形 (Struct と BPF.record の一致・暗黙の padding・見本・全 member の明示 — P006 §1)
	SB023PacketOffset         Code = "SB023" // window の offset の区間が [0, 65535 − N] に収まらない (P004 §2)
	SB031IndexRange           Code = "SB031" // record の配列の member の添字が範囲 [0, N−1] に収まると示せない (範囲外・負・可変 — P016 E066)
	SB032UprobeTarget         Code = "SB032" // uprobe の target の build の時の照合 (bpf-mlir の Precheck の uprobe の Unmet — symbol・引数の型・呼び出し規約・sha256 — P020 E080。早い誤りの便利 — load の時の照合を置き換えない)
	SB033KernelTypeShape      Code = "SB033" // CO-RE の kernel の struct の宣言と tp_btf の引数・kernel pointer の使い方の形 (P021 E086 — 幅・符号・名前の正しさは load の時の照合が守る)
	SB034SubprogramShape      Code = "SB034" // eBPF の側の subprogram (def) の形 — 引数の数と型・戻り値・return・program だけの op (P023 E092)
	SB035Recursion            Code = "SB035" // subprogram の call graph の閉路 (経路付き — P023 E092)
	SB030LoopShape            Code = "SB030" // 有界の loop (times / each) の形の外 — 上限・入れ子・break / next の位置・本体に置けない op・loop を跨ぐ参照 (P015 E060)
	SB029GlobalShape          Code = "SB029" // global 変数 (Config / OptionalConfig / Counter) の宣言と使い方の形 (P014 E057)
	SB028TracingKind          Code = "SB028" // tracing の kind の取り違え (xdp の verdict・packet・ctx.ret / ctx.arg の kind の外・params に無い番号 — P013 E051)
	SB027ThreadInBPFSide      Code = "SB027" // eBPF の側に届く関数の中の Thread 等の参照 (SB012 と別 — SB012 を外した後も残る、P012 E048)
	SB026StatusIgnored        Code = "SB026" // hash の map の操作の status (0 か負の errno) を捨てる形 — 1 度だけ代入し読む局所・比較の operand・`_ = …` だけ (P008 §2)
)

var codeNames = map[Code]string{
	SB000Spinel:               "Spinel",
	SB001UnsupportedConstruct: "UnsupportedConstruct",
	SB002UnsupportedCall:      "UnsupportedCall",
	SB003CrossDomainUse:       "CrossDomainUse",
	SB004UnknownEdge:          "UnknownEdge",
	SB005RefCheckShape:        "RefCheckShape",
	SB006NonConstant:          "NonConstant",
	SB007ReservedName:         "ReservedName",
	SB008ProgramShape:         "ProgramShape",
	SB009OperatorRedefined:    "OperatorRedefined",
	SB010TypingProbe:          "TypingProbe",
	SB011ShadowedName:         "ShadowedName",
	SB012ThreadInUserSide:     "ThreadInUserSide",
	SB027ThreadInBPFSide:      "ThreadInBPFSide",
	SB028TracingKind:          "TracingKind",
	SB029GlobalShape:          "GlobalShape",
	SB030LoopShape:            "LoopShape",
	SB031IndexRange:           "IndexRange",
	SB032UprobeTarget:         "UprobeTarget",
	SB033KernelTypeShape:      "KernelTypeShape",
	SB034SubprogramShape:      "SubprogramShape",
	SB035Recursion:            "Recursion",
	SB013MapDeclShape:         "MapDeclShape",
	SB014SemanticGap:          "SemanticGap",
	SB015AmbiguousType:        "AmbiguousType",
	SB016DynamicProgram:       "DynamicProgram",
	SB017InternalEmitter:      "InternalEmitter",
	SB018LogicalSideEffect:    "LogicalSideEffect",
	SB019SharedReadModifyWrite: "SharedReadModifyWrite",
	SB020KeyOutOfRange:        "KeyOutOfRange",
	SB021CompileWarning:       "CompileWarning",
	SB022WindowIndex:          "WindowIndex",
	SB023PacketOffset:         "PacketOffset",
	SB024RecordShape:          "RecordShape",
	SB025DroppedEvent:         "DroppedEvent",
	SB026StatusIgnored:        "StatusIgnored",
}

// Name は code の名前 (SB001 → UnsupportedConstruct)。
func (c Code) Name() string { return codeNames[c] }

// Pos は利用者の file の位置 (行は 1 から、列は 1 から — Spinel / Prism の 0 から の列に 1 を足す)。
type Pos struct {
	File string `json:"file"`
	Line int    `json:"line"`
	Col  int    `json:"col"`
}

func (p Pos) String() string {
	if p.File == "" {
		return "-"
	}
	if p.Line == 0 {
		return p.File
	}
	return fmt.Sprintf("%s:%d:%d", p.File, p.Line, p.Col)
}

// Diag は判定の結果 1 つ (1 つの結果の型 — 文言はここから作る)。
type Diag struct {
	Verdict Verdict  `json:"-"`
	Code    Code     `json:"code"`
	Pos     Pos      `json:"pos"`
	Path    []string `json:"path,omitempty"` // 呼び出しの経路 (root から)
	Msg     string   `json:"message"`
}

func (d Diag) String() string {
	s := fmt.Sprintf("%s: %s %s (%s): %s", d.Pos, d.Verdict, d.Code, d.Code.Name(), d.Msg)
	if len(d.Path) > 0 {
		s += " [path: " + strings.Join(d.Path, " -> ") + "]"
	}
	return s
}

// Diags は判定の結果の並び。
type Diags []Diag

// Blocking は生成を止める結果 (Rejected / Unknown) があるか。
func (ds Diags) Blocking() bool {
	for _, d := range ds {
		if d.Verdict == Rejected || d.Verdict == Unknown {
			return true
		}
	}
	return false
}

// Sorted は位置の順 (同じ位置は code の順) に並べた写し。
func (ds Diags) Sorted() Diags {
	out := append(Diags(nil), ds...)
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i].Pos, out[j].Pos
		if a.File != b.File {
			return a.File < b.File
		}
		if a.Line != b.Line {
			return a.Line < b.Line
		}
		if a.Col != b.Col {
			return a.Col < b.Col
		}
		return out[i].Code < out[j].Code
	})
	return out
}

// Error は止めた判定の集まり (生成の誤り)。
type Error struct{ Diags Diags }

func (e *Error) Error() string {
	var b strings.Builder
	for i, d := range e.Diags.Sorted() {
		if i > 0 {
			b.WriteString("\n")
		}
		b.WriteString(d.String())
	}
	return b.String()
}
