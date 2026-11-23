package frontend

import (
	"fmt"
	"os"
	"sort"
)

func sortStrings(s []string) { sort.Strings(s) }

// Output は frontend の生成物。
type Output struct {
	Result *Result
	MLIR   string
	Schema []byte
	Maps   []byte
	Domain []byte
	// Records は埋め込みの layout の表 (RecordsTable — record の map が無ければ空)
	Records string
}

// Generate は source を解析し、止める判定が無ければ生成物を作る。止める判定があれば *Error (Domain は判定入りで返す)。
// work は Spinel の解析用の directory (build の下 — 利用者の source の directory には書かない)。
func Generate(sp Spinel, work, sourcePath string) (*Output, error) {
	text, err := os.ReadFile(sourcePath)
	if err != nil {
		return nil, err
	}
	res, err := Analyze(sp, work, sourcePath, string(text))
	if err != nil {
		return nil, err
	}
	out := &Output{Result: res}
	if out.Domain, err = DomainGraph(res); err != nil {
		return nil, err
	}
	if res.Diags.Blocking() {
		return out, &Error{Diags: res.Diags}
	}
	if len(res.Programs) == 0 {
		return out, fmt.Errorf("internal: no program and no blocking diagnostic")
	}
	if out.MLIR, err = Lower(res); err != nil {
		return out, &Error{Diags: Diags{{Verdict: Rejected, Code: SB017InternalEmitter, Pos: Pos{File: res.Source}, Msg: err.Error()}}}
	}
	if out.Schema, err = Schema(res); err != nil {
		return nil, err
	}
	if out.Maps, err = MapsJSON(res); err != nil {
		return nil, err
	}
	out.Records = RecordsTable(res)
	return out, nil
}
