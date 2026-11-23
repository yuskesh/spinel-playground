package frontend

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func repoRoot(t testing.TB) string {
	_, f, _, _ := runtime.Caller(0)
	return filepath.Clean(filepath.Join(filepath.Dir(f), "..", ".."))
}

func testSpinel(t testing.TB) Spinel {
	root := repoRoot(t)
	bin := filepath.Join(root, "third_party", "spinel", "bin", "spinel")
	// Spinel Extended: there is no third_party/spinel submodule here; SPINEL
	// names the compiler, as it does for the driver (cmd/spinelbpf/build.go).
	if s := os.Getenv("SPINEL"); s != "" {
		bin = s
	}
	if _, err := os.Stat(bin); err != nil {
		t.Fatalf("spinel not built (scripts/setup.sh): %v", err)
	}
	return Spinel{Bin: bin, LibDir: filepath.Join(root, "ruby", "lib")}
}
