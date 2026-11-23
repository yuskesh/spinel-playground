package frontend

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
)

// TestCtxFieldOutputs は E120 H2: ctxf_basic の 2 回の生成が byte 同じ、.mlir は xdp の ingress_ifindex・tc の len / mark の ebpf.ctx.field と
// mark の ebpf.ctx.field.store。
func TestCtxFieldOutputs(t *testing.T) {
	sp := testSpinel(t)
	f := filepath.Join("testdata", "pos", "ctxf_basic.rb")
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
		"= ebpf.ctx.field %ctx \"ingress_ifindex\" : !ebpf.ctx<\"xdp\"> -> i32 ",
		"= ebpf.ctx.field %ctx \"len\" : !ebpf.ctx<\"sched_cls\"> -> i32 ",
		"= ebpf.ctx.field %ctx \"mark\" : !ebpf.ctx<\"sched_cls\"> -> i32 ",
		"ebpf.ctx.field.store %ctx \"mark\", %",
	} {
		if !strings.Contains(a.MLIR, w) {
			t.Errorf("the .mlir lacks %q:\n%s", w, a.MLIR)
		}
	}
	if n := strings.Count(a.MLIR, "ebpf.ctx.field.store "); n != 2 {
		t.Errorf("%d mark stores, want 2", n)
	}
}
