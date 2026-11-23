package main

import (
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/toolchain"
)

// TestPublicSeamPin は E161 の H1.2: 公開の形の seam の pin — 照合済みの ebpf-compile の commit はそのまま、無い時は source release の commit。
func TestPublicSeamPin(t *testing.T) {
	if c, err := bpfMLIRCommit(Config{}, "0123"); err != nil || c != "0123" {
		t.Fatal(c, err)
	}
	if c, err := bpfMLIRCommit(Config{Repo: t.TempDir()}, ""); err != nil || c != toolchain.ReleaseCompilerCommit {
		t.Fatal(c, err)
	}
}
