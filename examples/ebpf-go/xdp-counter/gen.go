// xdp-counter は Go 経路の垂直スライスの例 (E152 / E153)。
//
// 生成の順序 (どれも cgo を要求しない):
//   1. bpfgen  — 純 Go の builder が .mlir を書く
//   2. spbpf-compile — .mlir + schema から BTF 付き BPF ELF
//   3. spbpf-bindgen — schema から型付き bindings (ELF は go:embed)
//
// SPBPF_COMPILE / SPBPF_BINDGEN で場所を指すこと (PATH に入れない方針)。
package main

//go:generate go run ./bpfgen xdp_counter.mlir
//go:generate sh -c "$SPBPF_COMPILE xdp_counter.mlir --schema schema.json -o xdp_counter.bpf.o"
//go:generate sh -c "$SPBPF_BINDGEN --schema schema.json --object xdp_counter.bpf.o --output objects_gen.go --package main"
