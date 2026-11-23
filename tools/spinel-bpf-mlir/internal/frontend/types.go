package frontend

import (
	"encoding/json"
	"fmt"

	"github.com/yuskesh/go-bpf-mlir/requirements"
)

// Spinel の `--emit-types` の JSON (third_party/spinel/docs/emit-types.md) の reader と、AST の node との join (P001 §3.2)。
// JSON に node の id は無い。(file, line, col, end_line, end_col, kind) の key で結び、1 つの key に 2 つ以上の record があれば曖昧 (SB015)、
// 無ければ型が無い (unknown / void は JSON に出ない — 区別せずどちらも止める)。

// TypeRec は types の record 1 つ。
type TypeRec struct {
	File      string `json:"file"`
	Line      int    `json:"line"`
	Col       int    `json:"col"`
	EndLine   int    `json:"end_line"`
	EndCol    int    `json:"end_col"`
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Type      string `json:"type"`
	RBS       string `json:"rbs"`
	Owner     string `json:"owner"`
	Signature string `json:"signature"`
	Singleton bool   `json:"singleton"`
	Widened   bool   `json:"widened"`
}

// CodegenRec は codegen の record 1 つ (呼び出しの dispatch と呼び先)。
type CodegenRec struct {
	File       string   `json:"file"`
	Line       int      `json:"line"`
	Col        int      `json:"col"`
	EndLine    int      `json:"end_line"`
	EndCol     int      `json:"end_col"`
	Kind       string   `json:"kind"`
	Name       string   `json:"name"`
	Dispatch   string   `json:"dispatch"`
	Callee     string   `json:"callee"`
	Candidates []string `json:"candidates"`
	Inlined    *bool    `json:"inlined"`
}

// DiagRec は Spinel の診断 1 つ (widen の警告・拒否の誤り)。
type DiagRec struct {
	File     string `json:"file"`
	Line     int    `json:"line"`
	Col      int    `json:"col"`
	Severity string `json:"severity"`
	Method   string `json:"method"`
	Slot     string `json:"slot"`
	Param    string `json:"param"`
	Message  string `json:"message"`
}

// Types は読んだ JSON。
type Types struct {
	Types       []TypeRec    `json:"types"`
	Diagnostics []DiagRec    `json:"diagnostics"`
	Codegen     []CodegenRec `json:"codegen"`

	byKey     map[spanKey][]int
	cgByKey   map[spanKey][]int
}

type spanKey struct {
	File                         string
	Line, Col, EndLine, EndCol   int
	Kind                         string
}

// ParseTypes は JSON を読み、key の索引を作る。知らない field は無視する (Spinel の追加に耐える) が、必須の形の崩れは誤り。
// 文書の全体は requirements.DecodeStrictJSON の規則 (重複の key・nul・不正な UTF-8・後ろの byte・深さ) で先に見る (後勝ちで黙って読まない — E025)。
func ParseTypes(data []byte) (*Types, error) {
	var all any
	if err := requirements.DecodeStrictJSON(data, &all); err != nil {
		return nil, fmt.Errorf("spinel --emit-types JSON: %w", err)
	}
	var t Types
	if err := json.Unmarshal(data, &t); err != nil {
		return nil, fmt.Errorf("spinel --emit-types JSON: %w", err)
	}
	for i, r := range t.Types {
		if r.File == "" || r.Kind == "" || r.EndLine == 0 {
			return nil, fmt.Errorf("spinel --emit-types JSON: type record %d has no file / kind / end", i)
		}
	}
	reindex(&t)
	return &t, nil
}

// reindex は key の索引を作り直す。
func reindex(t *Types) {
	t.byKey = map[spanKey][]int{}
	for i, r := range t.Types {
		k := spanKey{r.File, r.Line, r.Col, r.EndLine, r.EndCol, r.Kind}
		t.byKey[k] = append(t.byKey[k], i)
	}
	t.cgByKey = map[spanKey][]int{}
	for i, r := range t.Codegen {
		k := spanKey{r.File, r.Line, r.Col, r.EndLine, r.EndCol, r.Kind}
		t.cgByKey[k] = append(t.cgByKey[k], i)
	}
}

func keyOf(a *AST, n *Node) spanKey {
	return spanKey{a.File(n), n.Line, n.Col, n.EndLine, n.EndCol, n.Type}
}

// TypeOf は node の型の record。無い → (nil, 0)、曖昧 → (nil, 件数)。
//
// Since upstream Spinel f8ff01939 the analysis puts the one expression a pair
// of parentheses holds in their place, so the facts have no record for the
// ParenthesesNode: a pair with no record of its own and exactly one
// expression in its body reads that expression's record.
func (t *Types) TypeOf(a *AST, n *Node) (*TypeRec, int) {
	ids := t.byKey[keyOf(a, n)]
	if len(ids) == 0 && n.Type == "ParenthesesNode" {
		if b := a.ref(n, "body"); b != nil && b.Type == "StatementsNode" && len(b.Arr["body"]) == 1 {
			return t.TypeOf(a, a.arr(b, "body")[0])
		}
	}
	if len(ids) != 1 {
		return nil, len(ids)
	}
	return &t.Types[ids[0]], 1
}

// CodegenOf は呼び出しの node の codegen の record。無い → (nil, 0)、曖昧 → (nil, 件数)。
func (t *Types) CodegenOf(a *AST, n *Node) (*CodegenRec, int) {
	ids := t.cgByKey[keyOf(a, n)]
	if len(ids) != 1 {
		return nil, len(ids)
	}
	return &t.Codegen[ids[0]], 1
}

// Errors は Spinel の拒否 (severity error) の診断。
func (t *Types) Errors() []DiagRec {
	var out []DiagRec
	for _, d := range t.Diagnostics {
		if d.Severity == "error" {
			out = append(out, d)
		}
	}
	return out
}
