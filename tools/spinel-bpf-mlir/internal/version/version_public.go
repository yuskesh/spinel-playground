package version

import "github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/toolchain"

// BpfMLIRModule は公開の形の bpf-mlir の Go の package の module — bpf-mlir の source release の commit から写した go-bpf-mlir (E161)。
const BpfMLIRModule = toolchain.ReleaseGoModule

// bpfMLIRLine は `--version` の bpf-mlir の行の閉じ括弧の前まで — compiler の source release と、Go の package の module と build の情報の版。
func bpfMLIRLine(ver string) string {
	return toolchain.ReleaseCompilerVersion + " (commit " + toolchain.ReleaseCompilerCommit[:8] + "; Go packages " + BpfMLIRModule + " " + ver + ", go.mod require"
}

// bmlLine は `--version` の bml の行 — 公開の bpf-mlir-loader の版と、その SOURCE_VERSION の source_commit の先頭 (E170 — bpf-mlir の行と同じく
// 公開の利用者が辿れる source の commit。公開の repo の commit ではない)。
func bmlLine() string { return toolchain.ReleaseBMLVersion + " (commit " + BML + ")" }
