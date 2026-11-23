package toolchain

import (
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"testing"
)

// TestPublicVerify は E161 の H3: 公開の形の正 2 (source release の describe と git の checkout の describe — commit で照合) と、負 6 — 各々が名指しの誤りで
// 公開の形の直し方 (source release) を言う。
func TestPublicVerify(t *testing.T) {
	const c = ReleaseCompilerCommit
	for _, d := range []string{"v1.21.0", "go/v1.19.0-1962-g41b188568"} {
		out := "LLVM (http://llvm.org/):\n  LLVM version 23.1.1\nbpf-mlir " + d + " (commit " + c + ")\n"
		if v, err := Verify(out, ReleaseGoModuleVersion, ""); err != nil || v.Describe != d || v.Commit != c || v.Module != "v0.19.0" {
			t.Fatal(v, err)
		}
	}
	ok := "bpf-mlir v1.21.0 (commit " + c + ")\n"
	const otherCommit = "e0a98646d0ebcfe3e260a66fa8d602ae97a9dd50" // 公開の commit でない commit (E166 で開発の pin = 公開の pin になったので前の開発の pin を使う)
	for _, tc := range []struct{ name, out, mod, sub, want string }{
		{"other_commit", "bpf-mlir go/v1.19.0-1933-ge0a98646d (commit " + otherCommit + ")", ReleaseGoModuleVersion, "", "needs exactly bpf-mlir commit " + c},
		{"dirty", "bpf-mlir v1.21.0-dirty (commit " + c + ")", ReleaseGoModuleVersion, "", "modified or unidentified source"},
		{"unknown", "bpf-mlir unknown (commit " + c + ")", ReleaseGoModuleVersion, "", "modified or unidentified source"},
		{"no_line", "garbage", ReleaseGoModuleVersion, "", "no `bpf-mlir"},
		{"module_version", ok, "v0.17.0", "", "the pinned version is v0.19.0 (the go-bpf-mlir release"},
		{"module_version_previous", ok, "v0.18.0", "", "the pinned version is v0.19.0 (the go-bpf-mlir release"}, // E167: 前の公開の pin (d3e13842 の写し) を止める
		{"submodule", ok, ReleaseGoModuleVersion, otherCommit, "third_party/bpf-mlir/SOURCE_VERSION has source_commit"},
	} {
		_, err := Verify(tc.out, tc.mod, tc.sub)
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: want %q, got %v", tc.name, tc.want, err)
			continue
		}
		if !strings.HasPrefix(tc.name, "module_version") && tc.name != "submodule" &&!strings.Contains(err.Error(), "source release (commit "+c+")") {
			t.Errorf("%s: the error does not name the source release remedy: %v", tc.name, err)
		}
	}
}

// TestPublicModuleVersion は E161 の H1.1 (c): 公開の形は go-bpf-mlir を build の情報で読み、開発の bpf-mlir/go・replace・無いを止める。
func TestPublicModuleVersion(t *testing.T) {
	if BPFMLIRGoModule != "github.com/yuskesh/go-bpf-mlir" {
		t.Fatalf("BPFMLIRGoModule %s", BPFMLIRGoModule)
	}
	bi := &debug.BuildInfo{Deps: []*debug.Module{{Path: "github.com/yuskesh/go-bpf-mlir", Version: "v0.19.0"}}}
	if v, err := ModuleVersion(bi); err != nil || v != "v0.19.0" {
		t.Fatal(v, err)
	}
	bi.Deps[0].Replace = &debug.Module{Path: "../go-bpf-mlir"}
	if _, err := ModuleVersion(bi); err == nil || !strings.Contains(err.Error(), "replaced") {
		t.Fatalf("replace: %v", err)
	}
	other := &debug.BuildInfo{Deps: []*debug.Module{{Path: "example.invalid/bpf-mlir-copy", Version: "v0.19.0"}}}
	if _, err := ModuleVersion(other); err == nil || !strings.Contains(err.Error(), "no dependency github.com/yuskesh/go-bpf-mlir") {
		t.Fatalf("other module: %v", err)
	}
}

// TestPublicSubmoduleSource は E167 の H1: 公開の形の照合 4 は submodule の HEAD でなく SOURCE_VERSION の source_commit を読む
// (公開 bpf-mlir の submodule の HEAD は書き出しの commit — ここでは .git に別の HEAD を置いても読まないことを見る)。
// The positive is the real public bpf-mlir v1.21.0's SOURCE_VERSION (testdata); the negatives are three lines whose source_commit is not C (Verify stops at check 4 — from the bpf-mlir reviewer's review).
func TestPublicSubmoduleSource(t *testing.T) {
	actual, err := os.ReadFile(filepath.Join("testdata", "public_bpf_mlir_v1.21.0.SOURCE_VERSION"))
	if err != nil {
		t.Fatal(err)
	}
	mk := func(sv []byte) string {
		repo := t.TempDir()
		sub := filepath.Join(repo, "third_party", "bpf-mlir")
		if err := os.MkdirAll(sub, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(sub, ".git"), []byte("gitdir: /nonexistent-e167\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(sub, "SOURCE_VERSION"), sv, 0o644); err != nil {
			t.Fatal(err)
		}
		return repo
	}
	out := "bpf-mlir v1.21.0 (commit " + ReleaseCompilerCommit + ")\n"
	got, err := submoduleSource(mk(actual))
	if err != nil || got != ReleaseCompilerCommit {
		t.Fatalf("submoduleSource of the actual public SOURCE_VERSION: %q %v", got, err)
	}
	if _, err := Verify(out, ReleaseGoModuleVersion, got); err != nil {
		t.Fatalf("Verify with the SOURCE_VERSION commit: %v", err)
	}
	const otherCommit = "e0a98646d0ebcfe3e260a66fa8d602ae97a9dd50"
	other, err := submoduleSource(mk([]byte("format=1\nversion=" + strings.TrimPrefix(ReleaseCompilerVersion, "v") + "\nsource_commit=" + otherCommit + "\n")))
	if err != nil || other != otherCommit {
		t.Fatalf("submoduleSource of another commit: %q %v", other, err)
	}
	_, err = Verify(out, ReleaseGoModuleVersion, other)
	if err == nil || !strings.Contains(err.Error(), "third_party/bpf-mlir/SOURCE_VERSION has source_commit "+otherCommit) {
		t.Fatalf("Verify with another source_commit: %v", err)
	}
	t.Logf("other_commit: %v", err)
}
