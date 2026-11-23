package frontend

import (
	"fmt"
	"math/big"
)

// 区間の解析 (P002 §2.1): Ruby の Integer の式の数学の値の閉区間を math/big で持つ。
// 結果が i64 に収まらない演算は受けない — 収まれば wrap が起きず、Ruby (CRuby の任意精度・Spinel の i64) と BPF (i64) の値が同じ。

// Ival は閉区間 [Lo, Hi]。
type Ival struct{ Lo, Hi *big.Int }

var (
	bigZero   = big.NewInt(0)
	bigOne    = big.NewInt(1)
	i64Min    = new(big.Int).Neg(new(big.Int).Lsh(bigOne, 63))
	i64Max    = new(big.Int).Sub(new(big.Int).Lsh(bigOne, 63), bigOne)
	u32Max    = new(big.Int).Sub(new(big.Int).Lsh(bigOne, 32), bigOne)
	i32Min    = new(big.Int).Neg(new(big.Int).Lsh(bigOne, 31))
	i32Max    = new(big.Int).Sub(new(big.Int).Lsh(bigOne, 31), bigOne)
	u64Max    = new(big.Int).Sub(new(big.Int).Lsh(bigOne, 64), bigOne)
	fullI64   = Ival{i64Min, i64Max}
	literalLo = new(big.Int).Add(i64Min, bigOne) // literal は −2^63 を除く (Spinel の nil の印 — P001 §3.8)
)

func point(v *big.Int) Ival { return Ival{new(big.Int).Set(v), new(big.Int).Set(v)} }

func iv(lo, hi *big.Int) Ival { return Ival{lo, hi} }

func (a Ival) String() string { return fmt.Sprintf("[%s, %s]", a.Lo, a.Hi) }

// within は a が [lo, hi] に収まるか。
func (a Ival) within(lo, hi *big.Int) bool { return a.Lo.Cmp(lo) >= 0 && a.Hi.Cmp(hi) <= 0 }

func (a Ival) fitsI64() bool { return a.within(i64Min, i64Max) }

func (a Ival) nonNeg() bool { return a.Lo.Sign() >= 0 }

func (a Ival) isPoint() (*big.Int, bool) {
	if a.Lo.Cmp(a.Hi) == 0 {
		return a.Lo, true
	}
	return nil, false
}

func union(a, b Ival) Ival {
	lo, hi := a.Lo, a.Hi
	if b.Lo.Cmp(lo) < 0 {
		lo = b.Lo
	}
	if b.Hi.Cmp(hi) > 0 {
		hi = b.Hi
	}
	return Ival{lo, hi}
}

func minMax(vs ...*big.Int) Ival {
	lo, hi := vs[0], vs[0]
	for _, v := range vs[1:] {
		if v.Cmp(lo) < 0 {
			lo = v
		}
		if v.Cmp(hi) > 0 {
			hi = v
		}
	}
	return Ival{new(big.Int).Set(lo), new(big.Int).Set(hi)}
}

func ivAdd(a, b Ival) Ival { return Ival{new(big.Int).Add(a.Lo, b.Lo), new(big.Int).Add(a.Hi, b.Hi)} }
func ivSub(a, b Ival) Ival { return Ival{new(big.Int).Sub(a.Lo, b.Hi), new(big.Int).Sub(a.Hi, b.Lo)} }
func ivMul(a, b Ival) Ival {
	m := func(x, y *big.Int) *big.Int { return new(big.Int).Mul(x, y) }
	return minMax(m(a.Lo, b.Lo), m(a.Lo, b.Hi), m(a.Hi, b.Lo), m(a.Hi, b.Hi))
}
func ivNeg(a Ival) Ival { return Ival{new(big.Int).Neg(a.Hi), new(big.Int).Neg(a.Lo)} }

// ivNot は ~a = −a − 1。
func ivNot(a Ival) Ival {
	return Ival{new(big.Int).Sub(new(big.Int).Neg(a.Hi), bigOne), new(big.Int).Sub(new(big.Int).Neg(a.Lo), bigOne)}
}

// pow2m1 は 2^bitlen(x) − 1 (x ≥ 0 の全ての値の | と ^ の上限)。
func pow2m1(x *big.Int) *big.Int {
	return new(big.Int).Sub(new(big.Int).Lsh(bigOne, uint(x.BitLen())), bigOne)
}

// ivBit は & | ^ の区間。負を含む operand は i64 の全体 (i64 に収まる — 受ける)。
func ivBit(op string, a, b Ival) Ival {
	switch op {
	case "&":
		switch {
		case a.nonNeg() && b.nonNeg():
			hi := a.Hi
			if b.Hi.Cmp(hi) < 0 {
				hi = b.Hi
			}
			return Ival{new(big.Int), new(big.Int).Set(hi)}
		case a.nonNeg():
			return Ival{new(big.Int), new(big.Int).Set(a.Hi)}
		case b.nonNeg():
			return Ival{new(big.Int), new(big.Int).Set(b.Hi)}
		}
	case "|", "^":
		if a.nonNeg() && b.nonNeg() {
			hi := a.Hi
			if b.Hi.Cmp(hi) > 0 {
				hi = b.Hi
			}
			return Ival{new(big.Int), pow2m1(hi)}
		}
	}
	return fullI64
}

// floorDiv は Ruby の Integer#/ (−∞ への切り捨て)。
func floorDiv(x, d *big.Int) *big.Int {
	q, m := new(big.Int).DivMod(x, d, new(big.Int)) // Euclid: 0 ≤ m < |d|
	if d.Sign() < 0 && m.Sign() != 0 { // 7 / −2: Euclid の q = −3 (7 = 6 + 1)、floor は −4
		q.Sub(q, bigOne)
	}
	return q
}

// isPow2Mag は |d| が 2 の冪か。
func isPow2Mag(d *big.Int) bool {
	a := new(big.Int).Abs(d)
	return a.Sign() > 0 && new(big.Int).And(a, new(big.Int).Sub(a, bigOne)).Sign() == 0
}
