package frontend

import (
	"fmt"

	"github.com/yuskesh/go-bpf-mlir/requirements"
)

// P029 E152: driver の seam は spinel-mlir の consumer が出した domain (DomainGraph と byte 同じ — spinel-mlir E075) を読み戻し、
// roots (uprobe の target の照らし) と diagnostics (Go の経路と同じ印字) に使う。読みは厳しい (未知の key・重複・型の違いは止める)。

// DomainRoot は domain の roots の要素 (Go の Result.Programs の名前・kind・宣言と定義の位置)。
type DomainRoot = domainRoot

// ReadDomainGraph は DomainGraph の JSON を読み、roots と diagnostics (Diags — 並びは domain のまま) を返す。
func ReadDomainGraph(b []byte) ([]DomainRoot, Diags, error) {
	var doc struct {
		Source    string       `json:"source"`
		Roots     []domainRoot `json:"roots"`
		Functions []domainFunc `json:"functions"`
		Edges     []Edge       `json:"edges"`
		Diags     []domainDiag `json:"diagnostics"`
	}
	if err := requirements.DecodeStrictJSON(b, &doc); err != nil {
		return nil, nil, err
	}
	if doc.Roots == nil || doc.Functions == nil || doc.Edges == nil || doc.Diags == nil {
		return nil, nil, fmt.Errorf("roots, functions, edges and diagnostics must all be arrays")
	}
	var ds Diags
	for i, d := range doc.Diags {
		v, ok := parseVerdict(d.Verdict)
		if !ok {
			return nil, nil, fmt.Errorf("diagnostics[%d]: unknown verdict %q", i, d.Verdict)
		}
		if _, ok := codeNames[d.Code]; !ok || d.Code.Name() != d.Name {
			return nil, nil, fmt.Errorf("diagnostics[%d]: code %q with name %q is not in the reason code table", i, d.Code, d.Name)
		}
		ds = append(ds, Diag{Verdict: v, Code: d.Code, Pos: d.Pos, Path: d.Path, Msg: d.Message})
	}
	return doc.Roots, ds, nil
}

func parseVerdict(s string) (Verdict, bool) {
	for _, v := range []Verdict{Verified, Rejected, Conditional, Unknown} {
		if v.String() == s {
			return v, true
		}
	}
	return 0, false
}
