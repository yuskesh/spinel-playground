//go:build spinelbpf_mutation

package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// TestHookNoOrigin は E063 の H3: 変異 no-origin (局所への出自の伝播を外す — 試験の build だけ) で局所を経た RMW の 7 つの負の例が受理に戻り、
// 直の読みの rmw_atomic_add_direct は SB019 のまま (出自でなく直の読みの検査) — 出自の伝播が拒否の理由であることの対照。
// `go test -tags spinelbpf_mutation -run TestHook ./cmd/spinelbpf` (gate の mutation の段)。
func TestHookNoOrigin(t *testing.T) {
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
	t.Setenv("SPINELBPF_MUTATION", "no-origin")
	for _, name := range []string{"rmw_local1", "rmw_local2", "rmw_local_arm", "rmw_local_loop", "rmw_local_record", "rmw_local_add_or_init", "rmw_local_atomic_add", "rmw_record_atomic_add_local"} {
		if ds := analyze(name); ds.Blocking() {
			t.Errorf("%s: want accepted under no-origin, got %v", name, ds)
		}
	}
	for _, name := range []string{"rmw_atomic_add_direct", "rmw_record_atomic_add"} { // 直の読み (追記: record の member の atomic_add も)
		ds := analyze(name)
		if !ds.Blocking() || len(ds) != 1 || ds[0].Code != frontend.SB019SharedReadModifyWrite {
			t.Errorf("%s: want SB019 under no-origin too, got %v", name, ds)
		}
	}
}
