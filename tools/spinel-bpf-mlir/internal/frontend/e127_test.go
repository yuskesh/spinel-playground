package frontend

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

// TestCgOutputs は E127 H2: cgs_basic の 2 回の生成が byte 同じ、.mlir は ingress と egress の attach の句の cgroup_skb の program・__sk_buff の len の
// ebpf.ctx.field・packet.check・判定 deny / allow、schema の program は kind cgroup_skb と attach_target ingress / egress。
func TestCgOutputs(t *testing.T) {
	sp := testSpinel(t)
	f := filepath.Join("testdata", "pos", "cgs_basic.rb")
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
		"ebpf.program @small_in \"cgroup_skb\" attach \"ingress\" maps [@Out] {\n",
		"ebpf.program @small_out \"cgroup_skb\" attach \"egress\" maps [@Out] {\n",
		"= ebpf.ctx.field %ctx \"len\" : !ebpf.ctx<\"cgroup_skb\"> -> i32 ",
		"len 20 : !ebpf.ctx<\"cgroup_skb\">, i64 -> i64 in_range {",
		"\"deny\" else \"allow\" ",
	} {
		if !strings.Contains(a.MLIR, w) {
			t.Errorf("the .mlir lacks %q:\n%s", w, a.MLIR)
		}
	}
	var sc struct {
		Core struct {
			Programs []struct {
				Name         string `json:"name"`
				Kind         string `json:"kind"`
				AttachTarget string `json:"attach_target"`
			} `json:"programs"`
		} `json:"core"`
	}
	if err := json.Unmarshal(a.Schema, &sc); err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, p := range sc.Core.Programs {
		if p.Kind != "cgroup_skb" {
			t.Errorf("schema program %s: kind %s", p.Name, p.Kind)
		}
		got[p.Name] = p.AttachTarget
	}
	if len(got) != 2 || got["small_in"] != "ingress" || got["small_out"] != "egress" {
		t.Errorf("schema attach targets = %v", got)
	}
}
