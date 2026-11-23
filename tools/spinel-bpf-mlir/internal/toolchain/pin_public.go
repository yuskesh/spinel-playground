package toolchain

// BPFMLIRGoModule は照合する Go の module の path — 公開の形は bpf-mlir の Go の package を写した go-bpf-mlir (E161)。
const BPFMLIRGoModule = ReleaseGoModule

// PinnedCompilerCommit は bpf-mlir の source release の commit、PinnedModuleVersion はその commit から package を写した go-bpf-mlir の release。
const (
	PinnedCompilerCommit = ReleaseCompilerCommit
	PinnedModuleVersion  = ReleaseGoModuleVersion
)

// compilerFix は compiler の照合の誤りが名指す直し方、moduleNote は module の版の誤りの注釈。
const (
	compilerFix = "build ebpf-compile from the bpf-mlir " + ReleaseCompilerVersion + " source release (commit " + ReleaseCompilerCommit + ") and point EBPF_COMPILE at it"
	moduleNote  = "the go-bpf-mlir release whose bpf-mlir Go packages are copied from commit " + ReleaseCompilerCommit
)

// submoduleWhat は照合 4 の誤りの文の主語 (submodule の commit の出所)。
const submoduleWhat = "third_party/bpf-mlir/SOURCE_VERSION has source_commit"

// submoduleSource は照合 4 の値: 公開の形は third_party/bpf-mlir/SOURCE_VERSION の source_commit (E167 — 公開 bpf-mlir の submodule の HEAD は
// 書き出しの commit で ReleaseCompilerCommit と別の SHA)。
func submoduleSource(repo string) (string, error) { return releaseSource(repo, ReleaseCompilerVersion) }
