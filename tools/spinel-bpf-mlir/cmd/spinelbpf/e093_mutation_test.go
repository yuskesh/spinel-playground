//go:build spinelbpf_mutation

package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// TestHookNoCounterRMW は E093 の H4: 変異 no-counter-rmw (Counter の value の出どころの印を外す — 試験の build だけ) で Counter の RMW の 4 形
// (直・局所・helper の引数・helper の戻り値) が受理に戻る — 印が拒否の理由であることの対照。変異の無い時は SB019。
func TestHookNoCounterRMW(t *testing.T) {
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
	names := []string{"cr_direct", "cr_local", "cr_helper_arg", "cr_helper_ret"}
	for _, name := range names {
		if ds := analyze(name); !ds.Blocking() || ds[0].Code != frontend.SB019SharedReadModifyWrite {
			t.Errorf("%s: want SB019 without the mutation, got %v", name, ds)
		}
	}
	t.Setenv("SPINELBPF_MUTATION", "no-counter-rmw")
	for _, name := range names {
		if ds := analyze(name); ds.Blocking() {
			t.Errorf("%s: want accepted under no-counter-rmw, got %v", name, ds)
		}
	}
}
