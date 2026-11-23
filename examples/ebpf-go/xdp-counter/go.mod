// P013 Task 5 の Files 一覧には無いが、examples/ を独立に build するには要る
// (仕様の穴として E152 に記録)。
module spinel-llvm/examples/ebpf-go/xdp-counter

go 1.25.0

require (
	github.com/cilium/ebpf v0.22.0
	spinel-llvm/tools/ebpf/go v0.0.0
)

require golang.org/x/sys v0.43.0 // indirect

replace spinel-llvm/tools/ebpf/go => ../../../tools/ebpf/go
