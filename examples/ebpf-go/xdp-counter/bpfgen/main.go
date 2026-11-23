// bpfgen は **純 Go の builder だけ**で XDP counter の .mlir を組み立てる。
// MLIR も clang も cgo も要らない — 出るのはテキストである。
package main

import (
	"fmt"
	"os"

	"spinel-llvm/tools/ebpf/go/spbpf"
)

func main() {
	out := "xdp_counter.mlir"
	if len(os.Args) > 1 {
		out = os.Args[1]
	}

	m := spbpf.NewModule("xdp_counter")
	p := m.Program("count_packets", spbpf.XDP)
	counts := p.Map("counts", spbpf.Array, spbpf.I32, spbpf.I64)
	events := p.RingBuf("events")

	b := p.Body()

	// counts[0] は packet の総数。key は定数 0 (ARRAY の index)。
	slot0 := b.ConstI32(0)
	b.MapAtomicAdd(counts, slot0, b.ConstI64(1))

	// packet の先頭 4 バイトを読んで counts[1] に置く。
	// 境界検査は lowering が入れる (kernel verifier はこれを受ける)。
	word := b.PacketLoad(b.ConstI32(0), spbpf.I32)
	b.MapUpdate(counts, b.ConstI32(1), b.ExtendI64(word))

	// 増えたあとの総数を読む。**検査を通さないと読めない。**
	maybe := b.MapLookup(counts, slot0)
	cur := b.RefCheck(maybe, spbpf.I64,
		func(pb *spbpf.Builder, ref spbpf.Value) []spbpf.Value {
			return []spbpf.Value{pb.RefLoad(ref, spbpf.I64)}
		},
		func(ab *spbpf.Builder) []spbpf.Value {
			return []spbpf.Value{ab.ConstI64(0)}
		})

	// ring buffer に 1 件流す。events は schema 上 record "tick" (size 8,
	// count を offset 0 に持つ) を運ぶので、record 型で予約し (E155)
	// count field へ store_field で書く — scalar 予約 (RingBufStore) は
	// record を運ばない ringbuf 用で、ここでは使えない。
	// 予約はちょうど 1 回消費する (verify-ownership が CFG で見る)。
	// 予約は取れないことがある。**検査を通した present 側でしか書けない。**
	tick := spbpf.RecordType{Symbol: "tick", Size: 8}
	maybeRes := b.RingBufReserve(events, tick)
	b.RingBufIfReserved(maybeRes,
		func(pb *spbpf.Builder, r spbpf.Value) {
			pb.RingBufStoreField(r, 0, cur, spbpf.I64)
			pb.RingBufSubmit(r)
		},
		nil) // 取れなければこの packet の record は落とす
	b.Verdict(spbpf.Pass)

	f, err := os.Create(out)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer f.Close()
	if err := m.WriteMLIR(f); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
