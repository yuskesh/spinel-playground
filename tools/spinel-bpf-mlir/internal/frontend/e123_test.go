package frontend

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
)

// TestAdjtOutputs は E123 H2: adjt_basic の 2 回の生成が byte 同じ、.mlir は直前の arith.constant -4 : i32 と 0 : i32 を delta に取る
// ebpf.xdp.adjust_tail (bpf-mlir E208 の形) とその後の新しい packet.check。
func TestAdjtOutputs(t *testing.T) {
	sp := testSpinel(t)
	f := filepath.Join("testdata", "pos", "adjt_basic.rb")
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
		"%v0 = arith.constant -4 : i32 loc(\"adjt_basic.rb\":7:8)\n  %v1 = ebpf.xdp.adjust_tail %ctx, %v0 : !ebpf.ctx<\"xdp\"> -> i64 ",
		"%v0 = arith.constant 0 : i32 loc(\"adjt_basic.rb\":17:7)\n  %v1 = ebpf.xdp.adjust_tail %ctx, %v0 : !ebpf.ctx<\"xdp\"> -> i64 ",
	} {
		if !strings.Contains(a.MLIR, w) {
			t.Errorf("the .mlir lacks %q:\n%s", w, a.MLIR)
		}
	}
	if i, j := strings.Index(a.MLIR, "ebpf.xdp.adjust_tail"), strings.Index(a.MLIR, "ebpf.packet.check"); i < 0 || j < i {
		t.Errorf("want the packet.check after the adjust_tail:\n%s", a.MLIR)
	}
}
