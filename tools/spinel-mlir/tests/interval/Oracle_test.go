// E004: run unchanged pinned interval.go and narrow.go in package frontend.
package frontend

import (
	"fmt"
	"math/big"
	"os"
	"testing"
)

type Expr struct {
	Kind, Op, Var string
	Bool, Wide    bool
	Iv            Ival
	Args          []*Expr
}
type varInfo struct {
	Bool bool
	Iv   Ival
}

func copyEnv(e map[string]*varInfo) map[string]*varInfo {
	o := map[string]*varInfo{}
	for k, v := range e {
		c := *v
		o[k] = &c
	}
	return o
}
func num(s string) *big.Int {
	n, ok := new(big.Int).SetString(s, 10)
	if !ok {
		panic(s)
	}
	return n
}
func span(l, h string) Ival { return iv(num(l), num(h)) }

// Extracted consumer predicates/results: program.go:1094-1217. Names replace SB text.
func consume(op string, a Ival, d *big.Int) string {
	var r Ival
	if op == "shl" || op == "shr" {
		if d.Sign() < 0 || d.Cmp(big.NewInt(63)) > 0 {
			return "reject:shift-count"
		}
		f := new(big.Int).Lsh(bigOne, uint(d.Uint64()))
		if op == "shl" {
			r = iv(new(big.Int).Mul(a.Lo, f), new(big.Int).Mul(a.Hi, f))
		} else {
			r = iv(floorDiv(a.Lo, f), floorDiv(a.Hi, f))
		}
	} else {
		if d.Sign() == 0 {
			return "reject:division-zero"
		}
		switch {
		case a.nonNeg() && d.Sign() > 0:
			if op == "div" {
				r = iv(new(big.Int).Quo(a.Lo, d), new(big.Int).Quo(a.Hi, d))
			} else {
				hi := new(big.Int).Sub(d, bigOne)
				if a.Hi.Cmp(hi) < 0 {
					hi = new(big.Int).Set(a.Hi)
				}
				r = iv(new(big.Int), hi)
			}
		case isPow2Mag(d):
			if op == "div" {
				r = minMax(floorDiv(a.Lo, d), floorDiv(a.Hi, d))
			} else if d.Sign() > 0 {
				r = iv(new(big.Int), new(big.Int).Sub(d, bigOne))
			} else {
				r = iv(new(big.Int).Add(d, bigOne), new(big.Int))
			}
		default:
			return "reject:signed-divisor"
		}
	}
	if !r.fitsI64() {
		return "reject:overflow"
	}
	return r.String()
}
func TestGenerate(t *testing.T) {
	out, e := os.Create(os.Getenv("E004_CASES"))
	if e != nil {
		t.Fatal(e)
	}
	defer out.Close()
	rows := [][7]string{
		{"add-overflow", "add", "9223372036854775807", "9223372036854775807", "1", "1", "-"},
		{"sub-boundary", "sub", "-9223372036854775808", "0", "1", "3", "-"},
		{"mul-min", "mul", "-9223372036854775808", "-9223372036854775808", "-9223372036854775808", "-9223372036854775808", "-"},
		{"mul-big", "mul", "1361129467683753853853498429727072845824", "1361129467683753853853498429727072845824", "1361129467683753853853498429727072845824", "1361129467683753853853498429727072845824", "-"},
		{"mul-signs", "mul", "-4", "3", "-7", "5", "-"}, {"join-both", "join", "-9", "-2", "3", "8", "-"},
		{"and-pos", "&", "1", "8", "3", "12", "-"}, {"and-mixed", "&", "-8", "9", "0", "7", "-"}, {"and-neg", "&", "-8", "-1", "-3", "-1", "-"},
		{"or-pos", "|", "0", "8", "0", "3", "-"}, {"xor-zero", "^", "0", "0", "0", "0", "-"}, {"or-neg", "|", "-1", "0", "1", "2", "-"},
		{"neg-min", "neg", "-9223372036854775808", "-9223372036854775808", "0", "0", "-"}, {"not-signs", "not", "-3", "7", "0", "0", "-"},
		{"fits-min", "fits", "-9223372036854775808", "9223372036854775807", "0", "0", "-"}, {"fits-over", "fits", "0", "9223372036854775808", "0", "0", "-"},
		{"literal-min", "literal", "-9223372036854775808", "0", "0", "0", "-"}, {"literal-low", "literal", "-9223372036854775807", "0", "0", "0", "-"},
		{"point-zero", "point", "0", "0", "0", "0", "-"}, {"not-point", "point", "-1", "1", "0", "0", "-"},
		{"floor-pos-neg", "floor", "7", "7", "0", "0", "-2"}, {"floor-neg-pos", "floor", "-7", "-7", "0", "0", "2"}, {"floor-neg-neg", "floor", "-7", "-7", "0", "0", "-2"},
		{"div-neg", "div", "-7", "9", "0", "0", "-2"}, {"div-reject", "div", "-7", "9", "0", "0", "3"}, {"div-zero", "div", "0", "1", "0", "0", "0"},
		{"div-min-neg1", "div", "-9223372036854775808", "0", "0", "0", "-1"}, {"rem-pos", "rem", "-7", "9", "0", "0", "4"}, {"rem-neg", "rem", "-7", "9", "0", "0", "-4"}, {"rem-small", "rem", "0", "2", "0", "0", "7"},
		{"shift-zero", "shl", "-4", "3", "0", "0", "0"}, {"shift-63", "shl", "0", "1", "0", "0", "63"}, {"shift-floor", "shr", "-7", "7", "0", "0", "1"}, {"shift-oob", "shr", "0", "1", "0", "0", "64"}, {"shift-neg", "shl", "0", "1", "0", "0", "-1"},
		{"narrow-lt", "narrow", "0", "5", "0", "0", "<:3"}, {"empty-rollback", "narrow", "0", "5", "0", "0", "<:-4"}, {"narrow-ge", "narrow", "0", "5", "0", "0", ">=:2"}, {"narrow-eq", "narrow", "0", "5", "0", "0", "==:2"}, {"narrow-ne", "narrow", "0", "5", "0", "0", "!=:2"}, {"and-rollback", "narrow", "0", "5", "0", "0", "and:2"},
	}
	for _, c := range rows {
		a, b := span(c[2], c[3]), span(c[4], c[5])
		w := ""
		var r Ival
		switch c[1] {
		case "add":
			r = ivAdd(a, b)
		case "sub":
			r = ivSub(a, b)
		case "mul":
			r = ivMul(a, b)
		case "join":
			r = union(a, b)
		case "neg":
			r = ivNeg(a)
		case "not":
			r = ivNot(a)
		case "&", "|", "^":
			r = ivBit(c[1], a, b)
		case "fits":
			w = fmt.Sprint(a.fitsI64())
		case "literal":
			w = fmt.Sprint(a.within(literalLo, i64Max))
		case "point":
			_, ok := a.isPoint()
			w = fmt.Sprint(ok)
		case "floor":
			w = floorDiv(a.Lo, num(c[6])).String()
		case "div", "rem", "shl", "shr":
			w = consume(c[1], a, num(c[6]))
		case "narrow":
			env := map[string]*varInfo{"x": {Iv: a}}
			x := &Expr{Kind: "var", Var: "x"}
			cmp := func(op, n string) *Expr {
				return &Expr{Kind: "cmp", Op: op, Args: []*Expr{x, {Kind: "lit", Iv: point(num(n))}}}
			}
			var op, n string
			for i, ch := range c[6] {
				if ch == ':' {
					op, n = c[6][:i], c[6][i+1:]
					break
				}
			}
			cond := cmp(op, n)
			if op == "and" {
				cond = &Expr{Kind: "and", Args: []*Expr{cmp("<", "2"), cmp(">", "4")}}
			}
			r = narrowEnv(env, cond, true)["x"].Iv
		}
		if w == "" {
			w = r.String()
		}
		fmt.Fprintf(out, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", c[0], c[1], c[2], c[3], c[4], c[5], c[6], w)
	}
}
