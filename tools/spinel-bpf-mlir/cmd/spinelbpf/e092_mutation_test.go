//go:build spinelbpf_mutation

package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// TestHookNoSummary は E092 の H4 (P023 段 1 の完成条件): 変異 no-summary (subprogram の要約 W / R を空に — 試験の build だけ) で関数を跨ぐ RMW の
// 3 つの負の例 (直の put(p.load)・局所を経る・戻り値を経る) が受理に戻る — 要約が拒否の理由であることの対照。変異の無い時の SB019 は負の例の表が見る。
func TestHookNoSummary(t *testing.T) {
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
	names := []string{"sp_rmw_direct", "sp_rmw_local", "sp_rmw_ret"}
	for _, name := range names {
		ds := analyze(name)
		if !ds.Blocking() || ds[0].Code != frontend.SB019SharedReadModifyWrite {
			t.Errorf("%s: want SB019 without the mutation, got %v", name, ds)
		}
	}
	t.Setenv("SPINELBPF_MUTATION", "no-summary")
	for _, name := range names {
		if ds := analyze(name); ds.Blocking() {
			t.Errorf("%s: want accepted under no-summary, got %v", name, ds)
		}
	}
}
