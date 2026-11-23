package frontend

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
)

// TestAdjhOutputs は E122 H2: adjh_basic の 2 回の生成が byte 同じ、.mlir は ebpf.xdp.adjust_head (delta は i32) とその後の新しい packet.check。
func TestAdjhOutputs(t *testing.T) {
	sp := testSpinel(t)
	f := filepath.Join("testdata", "pos", "adjh_basic.rb")
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
	i := strings.Index(a.MLIR, " = ebpf.xdp.adjust_head %ctx, %")
	j := strings.Index(a.MLIR, "ebpf.packet.check %ctx[")
	if i < 0 || j < 0 || j < i || !strings.Contains(a.MLIR, " : !ebpf.ctx<\"xdp\"> -> i64 ") {
		t.Errorf("want ebpf.xdp.adjust_head (-> i64) before the packet.check:\n%s", a.MLIR)
	}
}
