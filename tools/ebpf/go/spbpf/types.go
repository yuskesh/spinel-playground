// Package spbpf は spbpf dialect の **純 Go の typed builder** である (E152 / P013 Task 5)。
//
// 目的は「Go から eBPF を書くとき、MLIR も clang も cgo も要らない」こと。
// ここが出すのは MLIR のテキストだけで、実行時に MLIR ライブラリを引かない。
//
// **任意の operation 文字列を注入する API は持たない** (P013 Task 5 の checkbox)。
// 組み立てられる形は、この package が用意した method の組み合わせが全部である。
package spbpf

import "fmt"

// ProgramKind は attach 点の種別。初期スライスは XDP だけ。
type ProgramKind string

const XDP ProgramKind = "xdp"

// MapKind。**初期スライスは ARRAY と ring buffer だけ**を Go 側に出す
// (P013 Task 5: 「XDP/ARRAY/ringbuf だけの型付き builder」)。
// dialect は hash も持つが、Go builder からは作れない。
type MapKind string

const (
	Array   MapKind = "array"
	RingBuf MapKind = "ringbuf"
)

// IntType は record / key / value に使える整数型。
type IntType struct {
	Bits uint32
}

var (
	I32 = IntType{Bits: 32}
	I64 = IntType{Bits: 64}
)

func (t IntType) String() string { return fmt.Sprintf("i%d", t.Bits) }

// RecordType は record を運ぶ ring buffer の予約に使う型 (E155)。
// schema の record symbol とその size をそのまま持つ — 綴りは
// `!spbpf.record<"tick", 8>`。layout (fields の offset/幅) の照合は
// spbpf-compile の schema 照合 (--spbpf-verify-schema) が行う — builder は
// symbol と size を運ぶだけで、fields までは知らない。
type RecordType struct {
	Symbol string
	Size   uint64
}

func (t RecordType) String() string {
	return fmt.Sprintf("!spbpf.record<%q, %d>", t.Symbol, t.Size)
}

// ReservationType は ring buffer の予約が運べる型。scalar (IntType) と
// record (RecordType) のどちらかになれる。isReservationType は非公開なので、
// この package の外から新しい実装を足すことはできない
// (「任意の operation 文字列を注入する API は持たない」の型版)。
type ReservationType interface {
	fmt.Stringer
	isReservationType()
}

func (IntType) isReservationType()    {}
func (RecordType) isReservationType() {}

// Verdict は program が返す判定。綴りは dialect のものと同じ。
type Verdict string

const (
	Aborted  Verdict = "aborted"
	Drop     Verdict = "drop"
	Pass     Verdict = "pass"
	Tx       Verdict = "tx"
	Redirect Verdict = "redirect"
)

// Value は SSA 値。中身 (綴り) は package の外から作れない。
type Value struct {
	name string
	ty   string
}

func (v Value) String() string { return v.name }
func (v Value) Type() string   { return v.ty }

// MapRef は program の entry block 引数として入ってくる map handle。
type MapRef struct {
	value  Value
	symbol string
	kind   MapKind
	key    IntType
	value_ IntType
}
