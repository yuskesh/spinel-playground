//go:build !spinelbpf_mutation

package frontend

// mutation は差動の変異の対照の hook (P002 §3.4 — E010)。本番の build では常に false (build tag spinelbpf_mutation の試験の build だけで働く)。
func mutation(string) bool { return false }
