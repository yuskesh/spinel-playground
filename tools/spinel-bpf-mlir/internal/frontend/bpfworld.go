package frontend

import (
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
)

// verify-bpf-world (P001 §3.2 — go-bpf-mlir E015 / mojo-bpf-mlir の形)。frontend が出してよい op の集合を 1 か所に持ち、
// 生成の .mlir の op が全てこの集合に入ることを frontend の出口と試験で確かめる。集合は bpf-mlir の docs/reference/ebpf_ops.md の
// 「① 入力の op」の部分集合であること (試験 — ReferenceOps)。**出さない op は入れない** — 広げるのは lowering を足す変更と同じ commit で。
var allowedOps = map[string]bool{
	"ebpf.program": true, "ebpf.verdict": true,
	"ebpf.map.lookup": true, "ebpf.map.update": true, "ebpf.map.atomic_add": true,
	"ebpf.ref.check": true, "ebpf.ref.load": true, "ebpf.yield": true,
	"arith.constant": true,
	// P002 (E008): 演算子・比較・Bool・幅の出入り・if
	"ebpf.if": true, "ebpf.if.yield": true,
	"arith.addi": true, "arith.subi": true, "arith.muli": true, "arith.andi": true, "arith.ori": true, "arith.xori": true,
	"arith.shli": true, "arith.shrsi": true, "arith.shrui": true, "arith.divui": true, "arith.remui": true,
	"arith.floordivsi": true, "arith.remsi": true, "arith.cmpi": true, "arith.select": true,
	"arith.extui": true, "arith.extsi": true, "arith.trunci": true,
	// P004 (E014): packet の検査済みの window の読み (検査無しの ebpf.packet.load は入れない — 範囲外の暗黙の 0)
	"ebpf.packet.check": true, "ebpf.packet.window_load": true, "ebpf.byteorder.from_be": true,
	// P006 (E020): record の map value
	"ebpf.ktime.ns": true, "ebpf.record.make": true,
	// P013 E051: tracing の読みと helper
	"ebpf.global.load": true, "ebpf.global.atomic_add": true, // P014
	"ebpf.ctx.retval": true, "ebpf.kprobe.arg": true, "ebpf.probe.retval": true /* P026 E111 */, "ebpf.task.pid_tgid": true,
	"ebpf.uprobe.arg": true, "ebpf.user.read_str": true, "ebpf.ringbuf.store_field": true, // P020 E080 (uprobe と output_str)
	"ebpf.ctx.arg": true, "ebpf.kfield.load": true, // P021 E086 (tp_btf と CO-RE)
	"ebpf.ctx.field": true, // P026 E126 (socket_filter の __sk_buff の len)・E113 (raw_tp の args[i])
	"ebpf.ctx.field.store": true, // P026 E120 (sched_cls の __sk_buff の mark の書き)
	"ebpf.xdp.adjust_head": true, // P026 E122 (XDP の packet の先頭)
	"ebpf.xdp.adjust_tail": true, // P026 E123 (XDP の packet の末尾を縮める)
	"ebpf.flow_keys.load": true, "ebpf.flow_keys.store": true, // P026 E130 (flow_dissector の flow_keys)
	"ebpf.tp.field": true, // P026 E114 (tracepoint の event の field)
	"ebpf.ksyscall.arg": true, // P026 E115 (ksyscall の syscall の引数)
	"ebpf.kernel.read_scalar": true, // P026 E116 (kprobe の ptr の先の固定幅の読み)
	"ebpf.kernel.read_str": true, // P026 E118 (kernel の struct の char * の先の文字列)
	"ebpf.task.comm":       true, // P028 E145 (今の task の comm — R.output_comm)
	"ebpf.user.str_at":     true, // P028 E151 (argv の slot — R.output_argv)
	"ebpf.user.read":       true, // P029 E158 (user buffer — R.output_buf、bpf-mlir E560)
	"ebpf.redirect_map": true, // P026 E124 (xdp の devmap への redirect — 終端)
	"ebpf.sock.map_lookup": true, "ebpf.sock.ref_check": true, "ebpf.sk.assign": true, "ebpf.sock.release": true, // P026 E129 (sk_lookup の sk.assign)
	"ebpf.kfield.ptr": true, "ebpf.kptr.check": true, // P021 E088 (nullable の kernel pointer)
	"ebpf.kfield.copy": true, // P021 E089 (配列の field の写し)
	"ebpf.tp.field.copy": true, // P029 E153 (tracepoint の配列の field の写し — bpf-mlir E552)
	"ebpf.kptr.addr": true, // P029 E155 (検査済みの kernel pointer の address — bpf-mlir E554)
	"ebpf.func": true, "ebpf.call": true, "ebpf.return": true, // P023 E092 (subprogram)
	"ebpf.ringbuf.discard": true, // P024 E100 (output_str_or_discard — 腕ごとの discard)
	// P007 (E026): ring buffer (discard は出さない)
	"ebpf.ringbuf.reserve": true, "ebpf.ringbuf.if_reserved": true, "ebpf.ringbuf.store_record": true, "ebpf.ringbuf.submit": true, "ebpf.ref.field.load": true, "ebpf.ref.field.store": true, "ebpf.ref.field.atomic_add": true,
	// P008 (E032): hash の系の map の status を返す操作と借用への atomic_add (status を捨てる ebpf.map.delete は出さない)
	"ebpf.map.try_update": true, "ebpf.map.try_delete": true, "ebpf.ref.atomic_add": true,
	// P015 (E060): 有界の loop の (U) 展開 (callback の形と stop は出さない)
	"ebpf.loop": true, "ebpf.loop.yield": true, "ebpf.break": true, "ebpf.continue": true,
	// P016 (E068): record の配列の member の可変の添字 (区間で証明した添字だけ)
	"ebpf.ref.index": true, "ebpf.elem.load": true, "ebpf.elem.store": true,
	// E073: 早い return の guard — program の直下の 2 つの判定
	"ebpf.verdict.if": true,
}

// AllowedOps は許す op の名前 (試験用)。
func AllowedOps() []string {
	var out []string
	for k := range allowedOps {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// MlirOps は .mlir の text の op の名前を出現の順に返す。
func MlirOps(text string) []string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		s := strings.TrimSpace(line)
		switch {
		case s == "", strings.HasPrefix(s, "//"), strings.HasPrefix(s, "^"), strings.HasPrefix(s, "}"):
			continue
		case strings.HasPrefix(s, "%"):
			i := strings.Index(s, "= ")
			if i < 0 {
				out = append(out, "<unparsed:"+s+">")
				continue
			}
			s = s[i+2:]
		}
		op := s
		if i := strings.IndexAny(s, " \t"); i >= 0 {
			op = s[:i]
		}
		out = append(out, op)
	}
	return out
}

// VerifyWorld は text の op が全て許す集合に入ることを確かめる。
func VerifyWorld(text string) error {
	var bad []string
	for _, op := range MlirOps(text) {
		if !allowedOps[op] {
			bad = append(bad, op)
		}
	}
	if len(bad) > 0 {
		return fmt.Errorf("verify-bpf-world: the generated .mlir has ops outside the allowed set: %v", bad)
	}
	return nil
}

var refOpsLine = regexp.MustCompile("(?m)^- ① Input operations \\(\\d+\\): (.*)$") // E160: bpf-mlir ab0db4b40 (P130) の英語の見出し (前は「- ① 入力の op (N):」)
var backquoted = regexp.MustCompile("`([a-z0-9_.]+)`")

// ReferenceOps は bpf-mlir の docs/reference/ebpf_ops.md の ① の op の一覧を読む。
func ReferenceOps(path string) (map[string]bool, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	m := refOpsLine.FindSubmatch(data)
	if m == nil {
		return nil, fmt.Errorf("%s: no `- ① Input operations (N): …` line", path)
	}
	out := map[string]bool{}
	for _, x := range backquoted.FindAllSubmatch(m[1], -1) {
		out[string(x[1])] = true
	}
	return out, nil
}
