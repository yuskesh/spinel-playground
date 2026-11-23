package frontend

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

// TestFlowOutputs は E130 H2: flow_basic の 2 回の生成が byte 同じ、.mlir は attach の句の無い flow_dissector の program・flow_keys の load / store
// (ipv6 の添字を含む)・判定 drop / ok、schema の program は kind flow_dissector と空の attach_target。
func TestFlowOutputs(t *testing.T) {
	sp := testSpinel(t)
	f := filepath.Join("testdata", "pos", "flow_basic.rb")
	a, err := Generate(sp, t.TempDir(), f)
	if err != nil {
		t.Fatal(err)
	}
	b, err := Generate(sp, t.TempDir(), f)
	if err != nil {
		t.Fatal(err)
	}
	if a.MLIR != b.MLIR || !bytes.Equal(a.Schema, b.Schema) || !bytes.Equal(a.Maps, b.Maps) {
		t.Errorf("two generations differ")
	}
	for _, w := range []string{
		"ebpf.program @flow4 \"flow_dissector\" {\n",
		"= ebpf.flow_keys.load %ctx \"nhoff\" : !ebpf.ctx<\"flow_dissector\"> -> i16 ",
		"ebpf.flow_keys.store %ctx \"ipv4_src\", %",
		" : !ebpf.ctx<\"flow_dissector\">, i32 ",
		"ebpf.flow_keys.store %ctx \"ipv6_src\"[2], %",
		"\"drop\" else \"ok\" ",
	} {
		if !strings.Contains(a.MLIR, w) {
			t.Errorf("the .mlir lacks %q:\n%s", w, a.MLIR)
		}
	}
	var sc struct {
		Core struct {
			Programs []struct {
				Kind         string  `json:"kind"`
				AttachTarget *string `json:"attach_target"`
			} `json:"programs"`
		} `json:"core"`
	}
	if err := json.Unmarshal(a.Schema, &sc); err != nil {
		t.Fatal(err)
	}
	for _, p := range sc.Core.Programs {
		if p.Kind != "flow_dissector" || p.AttachTarget == nil || *p.AttachTarget != "" {
			t.Errorf("schema program: %+v", p)
		}
	}
}
