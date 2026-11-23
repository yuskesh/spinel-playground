package frontend

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

// TestSfOutputs は E126 H2: sf_basic の 2 回の生成が byte 同じ、.mlir は attach の句の無い socket_filter の program・__sk_buff の len の ebpf.ctx.field・
// 判定 drop / keep、schema の program は kind socket_filter と空の attach_target。
func TestSfOutputs(t *testing.T) {
	sp := testSpinel(t)
	f := filepath.Join("testdata", "pos", "sf_basic.rb")
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
		"ebpf.program @short_only \"socket_filter\" maps [@Out] {\n",
		"= ebpf.ctx.field %ctx \"len\" : !ebpf.ctx<\"socket_filter\"> -> i32 ",
		"ebpf.verdict.if %v7 \"drop\" else \"keep\" ",
	} {
		if !strings.Contains(a.MLIR, w) {
			t.Errorf("the .mlir lacks %q:\n%s", w, a.MLIR)
		}
	}
	if strings.Contains(a.MLIR, " attach ") {
		t.Errorf("a socket_filter program has no attach clause:\n%s", a.MLIR)
	}
	var sc struct {
		Core struct {
			Programs []struct {
				Name         string  `json:"name"`
				Kind         string  `json:"kind"`
				AttachTarget *string `json:"attach_target"`
			} `json:"programs"`
		} `json:"core"`
	}
	if err := json.Unmarshal(a.Schema, &sc); err != nil {
		t.Fatal(err)
	}
	if len(sc.Core.Programs) != 1 || sc.Core.Programs[0].Kind != "socket_filter" || sc.Core.Programs[0].AttachTarget == nil || *sc.Core.Programs[0].AttachTarget != "" {
		t.Errorf("schema programs = %+v, want one socket_filter with attach_target \"\"", sc.Core.Programs)
	}
}
