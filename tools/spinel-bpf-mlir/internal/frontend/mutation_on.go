//go:build spinelbpf_mutation

package frontend

import "os"

// mutation は差動の変異の対照の hook (P002 §3.4 — E010 — 試験の build だけ)。SPINELBPF_MUTATION の値が名前と同じとき働く:
//
//	no-overflow    区間の証明の溢れの検査を外す (fits が常に true)
//	swap-operands  `-` と比較の lower で operand の順を入れ替える (入れ替えても合法な op だけ)
//	no-offset-range  window の offset の区間の検査 (SB023) を外す (P004 §5)
//	no-rmw  record の member の read-modify-write の検査 (SB019) を外す (P006 §4 — E022 の多 CPU)
//	no-origin  局所への lookup の出自の伝播を外す (P015 E063 — 局所を経た RMW の SB019 の対照)
//	no-member-recv  record の member の読みの receiver の boxed の dispatch の受けを外す (E065)
func mutation(name string) bool { return os.Getenv("SPINELBPF_MUTATION") == name }
