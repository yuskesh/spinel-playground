//go:build spinelbpf_mutation

package main

import (
	"os"
	"strings"
	"testing"
)

// TestHookFlowMutations は E130 の H6 (host、root): 変異の対照の検出器の列 — 各々で双子と kernel の出力が食い違い、最初の食い違いが f_frames の行。
// flow-noclamp は harness の双子 (thoff の clamp を外す — clamp の program の行)、flow-swap-addr は frontend (ipv4_src の store を ipv4_dst に — IPv4 の UDP の行)。
func TestHookFlowMutations(t *testing.T) {
	requireUnverified(t)
	script := tFlowScript()
	for _, m := range []struct{ name, hook string }{
		{"noclamp (双子の thoff の clamp を外す)", "flow-noclamp"},
		{"swap-addr (ipv4_src の store を ipv4_dst に)", "flow-swap-addr"},
	} {
		t.Setenv("SPINELBPF_MUTATION", m.hook)
		h := buildHarnesses(t, flowData("t_flow.rb"))
		os.Unsetenv("SPINELBPF_MUTATION")
		d := ringDiff(feed(t, false, script, h.twinBin), feed(t, true, script, h.kernelBin))
		t.Logf("%s: %s", m.name, d)
		if d == "" || !strings.HasPrefix(d, "row f_frames ") || !strings.Contains(d, "\"ret=") {
			t.Errorf("%s: want the first difference at row f_frames on a ret=/keys= line, got %q", m.name, d)
		}
	}
}
