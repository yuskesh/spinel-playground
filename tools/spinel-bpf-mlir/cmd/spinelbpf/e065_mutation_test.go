//go:build spinelbpf_mutation

package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// TestHookNoMemberRecv は E065 の H4: 変異 no-member-recv (record の member の読みの receiver の boxed の受けを外す — 試験の build だけ) で
// 正の例 rec_member_builtin_names が SB004 に戻る (受けが拒否の消えた理由であることの対照)。
func TestHookNoMemberRecv(t *testing.T) {
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	sp := frontend.Spinel{Bin: cfg.Spinel, LibDir: filepath.Join(cfg.Repo, "ruby", "lib")}
	src := filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "rec_member_builtin_names.rb")
	b, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("SPINELBPF_MUTATION", "no-member-recv")
	res, err := frontend.Analyze(sp, t.TempDir(), src, string(b))
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, d := range res.Diags {
		if d.Code == frontend.SB004UnknownEdge {
			n++
		}
	}
	if n != 4 || len(res.Diags) != 4 {
		t.Errorf("want 4 SB004 under no-member-recv (the before-fix set), got %v", res.Diags)
	}
}
