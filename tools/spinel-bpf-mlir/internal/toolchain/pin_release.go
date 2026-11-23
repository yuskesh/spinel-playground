package toolchain

// ReleaseCompilerVersion・ReleaseCompilerCommit は公開の形 (build tag spinelbpf_public — E161) が組む bpf-mlir の source release、
// ReleaseGoModule・ReleaseGoModuleVersion はその commit の bpf-mlir の Go の package (bindrt・layout・requirements) を写した go-bpf-mlir の公開の release。
// E167: go-bpf-mlir v0.19.0 (P170 — bpf-mlir C 41b188568 の Go の package の写し、前は v0.18.0 = d3e13842 の写し)。公開の前は go の proxy から取れないので、
// この版で実際に module を取る build は公開の後の隔離の検収 (bpf-mlir E699)。
// tag なしで置く (開発の形の TestReleasePinSameCompilerSource が開発の pin と照らす)。
const (
	ReleaseCompilerVersion = "v1.21.0"
	ReleaseCompilerCommit  = "41b188568cb36a15d4c185d5f72027267b3fa544"
	ReleaseGoModule        = "github.com/yuskesh/go-bpf-mlir"
	ReleaseGoModuleVersion = "v0.19.0"
// E170: the public bpf-mlir-loader's version and its SOURCE_VERSION's source_commit (not the public repository's commit 42210a00 — checked by a bpf-mlir implementer)
	ReleaseBMLVersion      = "v0.1.0"
	ReleaseBMLSourceCommit = "41ec56f1d3df74e8ac56aec1e74f6a51c83a6bbc"
)
