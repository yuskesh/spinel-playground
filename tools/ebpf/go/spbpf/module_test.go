package spbpf_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"spinel-llvm/tools/ebpf/go/spbpf"
)

// golden: builder が出す .mlir が期待どおりであること。
// **builder は文字列注入 API を持たない** — ここで組み立てられる形が全部である。
func TestModuleWriteMLIR(t *testing.T) {
	m := spbpf.NewModule("xdp_counter")
	p := m.Program("count_packets", spbpf.XDP)
	counts := p.Map("counts", spbpf.Array, spbpf.I32, spbpf.I64)
	events := p.RingBuf("events")

	b := p.Body()
	key := b.PacketLoad(b.ConstI32(0), spbpf.I32)
	b.MapAtomicAdd(counts, key, b.ConstI64(1))

	maybe := b.MapLookup(counts, key)
	cur := b.RefCheck(maybe, spbpf.I64,
		func(pb *spbpf.Builder, ref spbpf.Value) []spbpf.Value {
			return []spbpf.Value{pb.RefLoad(ref, spbpf.I64)}
		},
		func(ab *spbpf.Builder) []spbpf.Value {
			return []spbpf.Value{ab.ConstI64(0)}
		})
	b.MapUpdate(counts, key, cur)

	// events は record "tick" (size 8, count @0) を運ぶ ringbuf (E155)。
	// 予約は取れないことがある。**検査を通した present 側でしか書けない。**
	tick := spbpf.RecordType{Symbol: "tick", Size: 8}
	maybeRes := b.RingBufReserve(events, tick)
	b.RingBufIfReserved(maybeRes,
		func(pb *spbpf.Builder, r spbpf.Value) {
			pb.RingBufStoreField(r, 0, cur, spbpf.I64)
			pb.RingBufSubmit(r)
		}, nil)
	b.Verdict(spbpf.Pass)

	var sb strings.Builder
	if err := m.WriteMLIR(&sb); err != nil {
		t.Fatalf("WriteMLIR: %v", err)
	}
	got := sb.String()

	golden := filepath.Join("testdata", "xdp_counter.mlir")
	if os.Getenv("UPDATE_GOLDEN") != "" {
		if err := os.WriteFile(golden, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("golden を読めない (UPDATE_GOLDEN=1 で作る): %v", err)
	}
	if got != string(want) {
		t.Errorf("生成 .mlir が golden と違う\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// 空の program は verdict が無いので拒否されること (dialect の verifier より前に、
// builder の段階で落とす — 生成器が壊れた IR を出さないため)。
func TestProgramNeedsVerdict(t *testing.T) {
	m := spbpf.NewModule("nope")
	m.Program("p", spbpf.XDP)
	var sb strings.Builder
	if err := m.WriteMLIR(&sb); err == nil {
		t.Fatal("verdict の無い program が通ってしまった")
	}
}

// map 引数は schema symbol と位置で対応づく。二重 binding は拒否。
func TestDuplicateMapSymbol(t *testing.T) {
	m := spbpf.NewModule("dup")
	p := m.Program("p", spbpf.XDP)
	p.Map("counts", spbpf.Array, spbpf.I32, spbpf.I64)
	p.Map("counts", spbpf.Array, spbpf.I32, spbpf.I64)
	b := p.Body()
	b.Verdict(spbpf.Pass)
	var sb strings.Builder
	if err := m.WriteMLIR(&sb); err == nil {
		t.Fatal("同じ map symbol の二重 binding が通ってしまった")
	}
}
