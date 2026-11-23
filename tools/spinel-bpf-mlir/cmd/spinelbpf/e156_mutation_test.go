//go:build spinelbpf_mutation

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestHookUprobeDebugOff は E156 の H6 (非 root): hook uprobe-debug-off (build の時の caps が分けた DWARF を探さない) で、正の例 up_libc_gai の
// build が SB032 の uprobearg_unknown (on_gai) と uretprobe_abi_unknown (on_gai_ret) で止まる — 通る理由が分けた DWARF の caps であることの対照。
func TestHookUprobeDebugOff(t *testing.T) {
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, err := os.ReadFile(uprobeSrc("up_libc_gai"))
	if err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(d, "up_libc_gai.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatalf("without the hook the build must pass: %v", err)
	}
	t.Setenv("SPINELBPF_MUTATION", "uprobe-debug-off")
	_, err = Build(cfg, src)
	t.Logf("%v", err)
	msg := ""
	if err != nil {
		msg = err.Error()
	}
	for _, w := range []string{"up_libc_gai.rb:23:1: rejected SB032", "uprobearg_unknown 1 of getaddrinfo (strptr): separate DWARF lookup is disabled",
		"up_libc_gai.rb:36:1: rejected SB032", "uretprobe_abi_unknown getaddrinfo"} {
		if !strings.Contains(msg, w) {
			t.Errorf("want %q in the hooked build's error", w)
		}
	}
}
