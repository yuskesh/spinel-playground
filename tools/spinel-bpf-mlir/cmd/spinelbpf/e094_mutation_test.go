//go:build spinelbpf_mutation

package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// TestHookNoSummaryBorrow は E094 の H3: 変異 no-summary (subprogram の要約を空に) で借用の helper を跨ぐ RMW の 2 形 (呼び手の読み → 整数の引数 →
// helper の借用への書き・helper の借用の読みの戻り値 → 呼び手の書き) が受理に戻り、helper の中の同じ借用の RMW (sb_rmw_callee) は SB019 のまま
// (要約でなく helper の中の既存の規則) — 要約が拒否の理由であることの対照。
func TestHookNoSummaryBorrow(t *testing.T) {
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	sp := frontend.Spinel{Bin: cfg.Spinel, LibDir: filepath.Join(cfg.Repo, "ruby", "lib")}
	analyze := func(name string) frontend.Diags {
		src := filepath.Join(repoRoot(), "internal", "frontend", "testdata", "neg", name+".rb")
		b, err := os.ReadFile(src)
		if err != nil {
			t.Fatal(err)
		}
		res, err := frontend.Analyze(sp, t.TempDir(), src, string(b))
		if err != nil {
			t.Fatal(err)
		}
		return res.Diags
	}
	t.Setenv("SPINELBPF_MUTATION", "no-summary")
	for _, name := range []string{"sb_rmw_arg", "sb_rmw_ret"} {
		if ds := analyze(name); ds.Blocking() {
			t.Errorf("%s: want accepted under no-summary, got %v", name, ds)
		}
	}
	if ds := analyze("sb_rmw_callee"); !ds.Blocking() || ds[0].Code != frontend.SB019SharedReadModifyWrite {
		t.Errorf("sb_rmw_callee: want SB019 under no-summary too (the rule inside the helper), got %v", ds)
	}
}
