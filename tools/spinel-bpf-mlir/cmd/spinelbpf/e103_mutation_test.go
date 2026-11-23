//go:build spinelbpf_mutation

package main

import (
	"fmt"
	"strings"
	"testing"
)

// TestHookEbpfPrefixCollision は E103 の H4: 変異 no-ebpf-prefix (frontend の `__ebpf_` の予約を外す) の build で、outline される大きな event の
// program prog の隣の helper `__ebpf_present_prog_0` を ebpf-compile が名指しの誤りで止める — 文を記録する。
func TestHookEbpfPrefixCollision(t *testing.T) {
	t.Setenv("SPINELBPF_MUTATION", "no-ebpf-prefix")
	cfg, _ := defaultConfig()
	d := t.TempDir()
	src := genBig(t, d, bigN, "def __ebpf_present_prog_0(a)\n  a & 0xFF\nend\n", "  Out.update(2, __ebpf_present_prog_0(1) & 0xFF)\n")
	_, err := Build(cfg, src)
	if err == nil || !strings.Contains(err.Error(), "__ebpf_present_prog_0") {
		t.Fatalf("want ebpf-compile to stop on the name collision, got %v", err)
	}
	t.Logf("%s", firstLines(fmt.Sprint(err), 8))
}
