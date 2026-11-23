package version

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/toolchain"
)

// TestPublicBpfMLIRLine は E161 の H1.3: 公開の形の `--version` の bpf-mlir の行 (build の情報の go-bpf-mlir の版・replace の注釈・依存が無い時)。
func TestPublicBpfMLIRLine(t *testing.T) {
	bi := &debug.BuildInfo{Deps: []*debug.Module{{Path: "github.com/yuskesh/go-bpf-mlir", Version: "v0.19.0"}}}
	for _, c := range []struct {
		bi   *debug.BuildInfo
		want string
	}{
		{bi, "v1.21.0 (commit 41b18856; Go packages github.com/yuskesh/go-bpf-mlir v0.19.0, go.mod require)"},
		{&debug.BuildInfo{Deps: []*debug.Module{{Path: "github.com/yuskesh/go-bpf-mlir", Version: "v0.19.0", Replace: &debug.Module{Path: "../g"}}}},
			"v1.21.0 (commit 41b18856; Go packages github.com/yuskesh/go-bpf-mlir v0.19.0, go.mod require; replaced by ../g)"},
		{&debug.BuildInfo{Deps: []*debug.Module{{Path: "example.invalid/bpf-mlir-copy", Version: "v0.19.0"}}}, "unknown (no build information)"},
		{nil, "unknown (no build information)"},
	} {
		if got := BpfMLIR(c.bi); got != c.want {
			t.Errorf("got %q, want %q", got, c.want)
		}
	}
}

// TestPublicBMLLine は E170 の H3: 公開の形の `--version` の bml の行は公開の bpf-mlir-loader の版と source の commit の先頭、
// その先頭 (BML — 開発の形では gitlink と照らす) は公開の pin の source_commit の先頭。
func TestPublicBMLLine(t *testing.T) {
	if got, want := bmlLine(), "v0.1.0 (commit 41ec56f)"; got != want {
		t.Errorf("bmlLine() = %q, want %q", got, want)
	}
	if !strings.HasPrefix(toolchain.ReleaseBMLSourceCommit, BML) {
		t.Errorf("BML %s is not a prefix of ReleaseBMLSourceCommit %s", BML, toolchain.ReleaseBMLSourceCommit)
	}
}

// TestPublicBMLSourceVersion は E170 の H3: 公開の tree の third_party/bpf-mlir-loader/SOURCE_VERSION の version と source_commit が
// 公開の pin (ReleaseBMLVersion・ReleaseBMLSourceCommit) と一致する。開発の tree の bml の submodule は SOURCE_VERSION を持たないので skip
// (公開の tree で走ったことは書き出しの側が PASS の行で確かめる)。
func TestPublicBMLSourceVersion(t *testing.T) {
	p := filepath.Join("..", "..", "third_party", "bpf-mlir-loader", "SOURCE_VERSION")
	b, err := os.ReadFile(p)
	if errors.Is(err, os.ErrNotExist) {
		t.Skipf("%s is absent — not a public checkout of bpf-mlir-loader", p)
	}
	if err != nil {
		t.Fatal(err)
	}
	if err := checkBMLSourceVersion(b); err != nil {
		t.Errorf("%s: %v", p, err)
	}
}

// checkBMLSourceVersion は SOURCE_VERSION の version と source_commit を公開の bml の pin と照らす。
func checkBMLSourceVersion(b []byte) error {
	ver, commit, err := toolchain.ParseSourceVersion(b)
	if err != nil {
		return err
	}
	if "v"+ver != toolchain.ReleaseBMLVersion || commit != toolchain.ReleaseBMLSourceCommit {
		return fmt.Errorf("version %s and source_commit %s, want %s and %s", ver, commit, toolchain.ReleaseBMLVersion, toolchain.ReleaseBMLSourceCommit)
	}
	return nil
}

// TestPublicBMLSourceVersionCheck is checkBMLSourceVersion's positive and negatives (the public bml v0.1.0's three SOURCE_VERSION lines — checked by a bpf-mlir implementer — and a different source_commit or version).
func TestPublicBMLSourceVersionCheck(t *testing.T) {
	const real = "format=1\nversion=0.1.0\nsource_commit=41ec56f1d3df74e8ac56aec1e74f6a51c83a6bbc\n"
	if err := checkBMLSourceVersion([]byte(real)); err != nil {
		t.Errorf("the public bml v0.1.0 SOURCE_VERSION: %v", err)
	}
	for _, bad := range []string{
		strings.Replace(real, "41ec56f1d3df", "a77443f1d3df", 1),
		strings.Replace(real, "version=0.1.0", "version=0.1.1", 1),
	} {
		err := checkBMLSourceVersion([]byte(bad))
		t.Logf("%q: %v", bad, err)
		if err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
}
