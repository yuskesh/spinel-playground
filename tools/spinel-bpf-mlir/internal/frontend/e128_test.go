package frontend

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

// TestNfOutputs は E128 H2: nf_basic の 2 回の生成が byte 同じ、.mlir は attach の句の無い netfilter の program・state / skb の ebpf.ctx.field の kptr・
// kfield.load の hook / pf / len・判定 drop / accept、schema の program は kind netfilter と空の attach_target、kernel_types に nf_hook_state と sk_buff。
func TestNfOutputs(t *testing.T) {
	sp := testSpinel(t)
	f := filepath.Join("testdata", "pos", "nf_basic.rb")
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
		"ebpf.program @small_only \"netfilter\" maps [@Out] {\n",
		"= ebpf.ctx.field %ctx \"state\" : !ebpf.ctx<\"netfilter\"> -> !ebpf.kptr<\"nf_hook_state\"> ",
		"= ebpf.ctx.field %ctx \"skb\" : !ebpf.ctx<\"netfilter\"> -> !ebpf.kptr<\"sk_buff\"> ",
		"\"hook\" : !ebpf.kptr<\"nf_hook_state\"> -> i8 ",
		"\"pf\" : !ebpf.kptr<\"nf_hook_state\"> -> i8 ",
		"\"len\" : !ebpf.kptr<\"sk_buff\"> -> i32 ",
		"\"drop\" else \"accept\" ",
	} {
		if !strings.Contains(a.MLIR, w) {
			t.Errorf("the .mlir lacks %q:\n%s", w, a.MLIR)
		}
	}
	if strings.Contains(a.MLIR, " attach ") {
		t.Errorf("a netfilter program has no attach clause:\n%s", a.MLIR)
	}
	var sc struct {
		Core struct {
			KernelTypes []struct {
				Name string `json:"name"`
			} `json:"kernel_types"`
			Programs []struct {
				Kind         string  `json:"kind"`
				AttachTarget *string `json:"attach_target"`
			} `json:"programs"`
		} `json:"core"`
	}
	if err := json.Unmarshal(a.Schema, &sc); err != nil {
		t.Fatal(err)
	}
	if len(sc.Core.Programs) != 1 || sc.Core.Programs[0].Kind != "netfilter" || sc.Core.Programs[0].AttachTarget == nil || *sc.Core.Programs[0].AttachTarget != "" {
		t.Errorf("schema programs = %+v", sc.Core.Programs)
	}
	if len(sc.Core.KernelTypes) != 2 || sc.Core.KernelTypes[0].Name != "nf_hook_state" || sc.Core.KernelTypes[1].Name != "sk_buff" {
		t.Errorf("schema kernel_types = %+v", sc.Core.KernelTypes)
	}
}
