package main

import "github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/toolchain"

// unverifiedBPFMLIRCommit は ebpf-compile が無い時の driver の bpf-mlir の commit — 公開の形は bpf-mlir の source release の commit
// (写しの先に gitlink が無いか、在っても開発の pin を指しうる — E161)。
func unverifiedBPFMLIRCommit(Config) (string, error) {
	return toolchain.ReleaseCompilerCommit, nil
}
