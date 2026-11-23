package spbpf

import (
	"fmt"
	"strings"
)

// Builder は 1 つの block (または ref.check の region) に op を積む。
// **op を綴る唯一の場所**であり、外から文字列を渡す口は無い。
type Builder struct {
	program *Program
	buf     strings.Builder
	indent  string

	hasVerdict bool
}

func (b *Builder) emit(format string, a ...any) {
	b.buf.WriteString(b.indent)
	fmt.Fprintf(&b.buf, format, a...)
	b.buf.WriteString("\n")
}

func (b *Builder) def(ty string) Value {
	return Value{name: b.program.nextName(), ty: ty}
}

// --- 定数は標準 dialect (arith) をそのまま使う ---------------------------------

func (b *Builder) ConstI32(v int32) Value {
	r := b.def("i32")
	b.emit("%s = arith.constant %d : i32", r, v)
	return r
}

func (b *Builder) ConstI64(v int64) Value {
	r := b.def("i64")
	b.emit("%s = arith.constant %d : i64", r, v)
	return r
}

// ExtendI64 は符号なしで 64bit へ広げる (標準 dialect の arith をそのまま使う)。
func (b *Builder) ExtendI64(v Value) Value {
	r := b.def("i64")
	b.emit("%s = arith.extui %s : %s to i64", r, v, v.Type())
	return r
}

// --- packet ------------------------------------------------------------------

// PacketLoad は context の packet から整数を読む。境界検査は lowering が入れる。
func (b *Builder) PacketLoad(offset Value, ty IntType) Value {
	r := b.def(ty.String())
	b.emit("%s = spbpf.packet.load %%ctx[%s] : !spbpf.ctx<%q>, %s -> %s",
		r, offset, b.program.kind, offset.Type(), ty)
	return r
}

// --- map ---------------------------------------------------------------------

func (m *MapRef) mlirType() string { return m.value.ty }

// MapLookup は未検査の nullable 参照を返す。**そのままでは読めない** —
// RefCheck を通さないと dialect の verifier が落とす。
func (b *Builder) MapLookup(m *MapRef, key Value) Value {
	r := b.def(fmt.Sprintf("!spbpf.maybe_ref<%s>", m.value_))
	b.emit("%s = spbpf.map.lookup %s[%s] : %s, %s -> %s",
		r, m.value, key, m.mlirType(), key.Type(), r.Type())
	return r
}

func (b *Builder) MapUpdate(m *MapRef, key, value Value) {
	b.emit("spbpf.map.update %s[%s], %s : %s, %s, %s",
		m.value, key, value, m.mlirType(), key.Type(), value.Type())
}

func (b *Builder) MapAtomicAdd(m *MapRef, key, delta Value) {
	b.emit("spbpf.map.atomic_add %s[%s], %s : %s, %s, %s",
		m.value, key, delta, m.mlirType(), key.Type(), delta.Type())
}

// --- 参照 ---------------------------------------------------------------------

// RefCheck は nullable 参照を検査する。**借用参照は present 側の関数の中だけで
// 有効**で、外へ持ち出す綴りが存在しない (Go の型としても Value を返せない形に
// してある — 返せるのは yield する値だけ)。
func (b *Builder) RefCheck(maybe Value, ty IntType,
	present func(*Builder, Value) []Value, absent func(*Builder) []Value) Value {
	r := b.def(ty.String())
	inner := ty.String()

	refName := b.program.nextName()
	pointee := strings.TrimSuffix(strings.TrimPrefix(maybe.Type(), "!spbpf.maybe_ref<"), ">")
	ref := Value{name: refName, ty: fmt.Sprintf("!spbpf.borrowed<%s>", pointee)}

	pb := &Builder{program: b.program, indent: b.indent + "  "}
	pv := present(pb, ref)
	ab := &Builder{program: b.program, indent: b.indent + "  "}
	av := absent(ab)

	if len(pv) != 1 || len(av) != 1 {
		b.program.module.fail("RefCheck: present and absent must each return exactly 1 value")
		return r
	}

	b.emit("%s = spbpf.ref.check %s : %s -> %s present {", r, maybe, maybe.Type(), inner)
	b.buf.WriteString(b.indent + fmt.Sprintf("^present(%s: %s):\n", ref.name, ref.ty))
	b.buf.WriteString(pb.buf.String())
	b.buf.WriteString(b.indent + "  " + fmt.Sprintf("spbpf.yield %s : %s\n", pv[0], pv[0].Type()))
	b.buf.WriteString(b.indent + "} absent {\n")
	b.buf.WriteString(ab.buf.String())
	b.buf.WriteString(b.indent + "  " + fmt.Sprintf("spbpf.yield %s : %s\n", av[0], av[0].Type()))
	b.buf.WriteString(b.indent + "}\n")
	return r
}

// RefLoad は借用参照から読む。RefCheck の present 側でしか呼べない綴りになっている。
func (b *Builder) RefLoad(ref Value, ty IntType) Value {
	r := b.def(ty.String())
	b.emit("%s = spbpf.ref.load %s : %s -> %s", r, ref, ref.Type(), ty)
	return r
}

// --- ring buffer -------------------------------------------------------------

// RingBufReserve は **取れていないかもしれない**予約を返す。
// そのままでは書けない — RingBufIfReserved を通すこと。
// record は scalar (IntType) でも record (RecordType) でもよい — schema の
// ringbuf が record を運ぶなら RecordType で予約すること (E155)。運ばないなら
// 従来どおり IntType で予約する。
func (b *Builder) RingBufReserve(rb *MapRef, record ReservationType) Value {
	r := b.def(fmt.Sprintf("!spbpf.maybe_reservation<%s>", record))
	b.emit("%s = spbpf.ringbuf.reserve %q : %s", r, rb.symbol, r.Type())
	return r
}

// RingBufIfReserved は予約が取れたかを検査する。**取れた予約は present 側の
// 関数の中だけで有効**で、外へ持ち出す綴りが存在しない (RefCheck と同じ形)。
// present 側では submit か discard をちょうど 1 回呼ぶこと。
func (b *Builder) RingBufIfReserved(maybe Value,
	present func(*Builder, Value), absent func(*Builder)) {
	pointee := strings.TrimSuffix(
		strings.TrimPrefix(maybe.Type(), "!spbpf.maybe_reservation<"), ">")
	res := Value{name: b.program.nextName(),
		ty: fmt.Sprintf("!spbpf.reservation<%s>", pointee)}

	pb := &Builder{program: b.program, indent: b.indent + "  "}
	present(pb, res)
	ab := &Builder{program: b.program, indent: b.indent + "  "}
	if absent != nil {
		absent(ab)
	}

	b.emit("spbpf.ringbuf.if_reserved %s : %s present {", maybe, maybe.Type())
	b.buf.WriteString(b.indent + fmt.Sprintf("^present(%s: %s):\n", res.name, res.ty))
	b.buf.WriteString(pb.buf.String())
	b.buf.WriteString(b.indent + "  spbpf.yield\n")
	b.buf.WriteString(b.indent + "} absent {\n")
	b.buf.WriteString(ab.buf.String())
	b.buf.WriteString(b.indent + "  spbpf.yield\n")
	b.buf.WriteString(b.indent + "}\n")
}

// RingBufStore は予約した領域に値を書く。**record を運ばない (scalar) 予約
// にしか使えない** — record を運ぶ予約は RingBufStoreField で field ごとに書く
// (dialect の verifier が両者を混同すると落とす)。
// 予約が取れなかった場合の分岐は lowering が入れるので、ここでは書くことだけを綴る。
func (b *Builder) RingBufStore(r Value, v Value) {
	b.emit("spbpf.ringbuf.store %s, %s : %s, %s", r, v, r.Type(), v.Type())
}

// RingBufStoreField は record を運ぶ予約のうち、byte offset で指定した 1 field
// に書く (E155)。offset と v の幅は schema の record layout と照合される —
// 合っていなければ spbpf-compile の schema 照合 (--spbpf-verify-schema) で落ちる。
func (b *Builder) RingBufStoreField(r Value, offset uint64, v Value, t IntType) {
	b.emit("spbpf.ringbuf.store_field %s[%d], %s : %s, %s", r, offset, v, r.Type(), t)
}

func (b *Builder) RingBufSubmit(r Value) {
	b.emit("spbpf.ringbuf.submit %s : %s", r, r.Type())
}

func (b *Builder) RingBufDiscard(r Value) {
	b.emit("spbpf.ringbuf.discard %s : %s", r, r.Type())
}

// --- 終端 ---------------------------------------------------------------------

func (b *Builder) Verdict(v Verdict) {
	b.emit("spbpf.verdict %q", v)
	b.hasVerdict = true
}
