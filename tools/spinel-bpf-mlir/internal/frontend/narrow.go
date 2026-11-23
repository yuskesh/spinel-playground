package frontend

import "math/big"

// 条件の区間の狭め (P017 E070): if / unless の腕の入口で、条件の比較が局所の区間を交わす。
// - `x op y` (op は < <= > >= ==、x か y が局所の読み — 他方は literal か局所か他の式 (その区間を境に使う))、!= は狭めない
// - && の真の腕は両方、偽の腕は狭めない。|| は狭めない。not は真偽を入れ替える
// - 交わりが空になる腕は狭めない (元の区間のまま — 到達しない腕の中の誤りも今どおり止める)
// - 合流は今の joinEnv の和、腕の中の再代入は新しい区間 (狭めの失効)
// lowering は変えない — kernel の検査 (ref.index の比較・loop の bound の min) は狭めに依らず ELF に残る。

// narrowEnv は env の写しに cond (positive は真の腕か) の狭めを施す。空の区間になれば狭めない写しを返す。
func narrowEnv(env map[string]*varInfo, cond *Expr, positive bool) map[string]*varInfo {
	out := copyEnv(env)
	if cond == nil || !narrowInto(out, cond, positive) {
		return copyEnv(env)
	}
	return out
}

// narrowInto は env を狭める (空の区間になれば false)。
func narrowInto(env map[string]*varInfo, e *Expr, pos bool) bool {
	switch e.Kind {
	case "not":
		return narrowInto(env, e.Args[0], !pos)
	case "and":
		if !pos {
			return true // !(a && b) は狭めない
		}
		return narrowInto(env, e.Args[0], true) && narrowInto(env, e.Args[1], true)
	case "cmp":
		op := e.Op
		if !pos {
			op = map[string]string{"<": ">=", "<=": ">", ">": "<=", ">=": "<", "==": "!=", "!=": "=="}[op]
		}
		return narrowCmp(env, e.Args[0], op, e.Args[1])
	}
	return true
}

// side は比較の片側の区間と、局所の読みなら名前。
func side(env map[string]*varInfo, x *Expr) (Ival, string, bool) {
	if x.Bool || x.Wide {
		return Ival{}, "", false
	}
	if x.Kind == "var" {
		if v, ok := env[x.Var]; ok && !v.Bool {
			return v.Iv, x.Var, true
		}
		return Ival{}, "", false
	}
	if x.Iv.Lo == nil {
		return Ival{}, "", false
	}
	return x.Iv, "", true
}

func bigMin(a, b *big.Int) *big.Int {
	if a.Cmp(b) < 0 {
		return a
	}
	return b
}

func bigMax(a, b *big.Int) *big.Int {
	if a.Cmp(b) > 0 {
		return a
	}
	return b
}

// narrowCmp は `l op r` の真の時の区間を局所の側に書く。
func narrowCmp(env map[string]*varInfo, l *Expr, op string, r *Expr) bool {
	L, ln, ok1 := side(env, l)
	R, rn, ok2 := side(env, r)
	if !ok1 || !ok2 || (ln == "" && rn == "") {
		return true
	}
	one := big.NewInt(1)
	nl, nr := L, R
	switch op {
	case "<": // hi(l) ≤ hi(r) − 1、lo(r) ≥ lo(l) + 1
		nl = Ival{L.Lo, bigMin(L.Hi, new(big.Int).Sub(R.Hi, one))}
		nr = Ival{bigMax(R.Lo, new(big.Int).Add(L.Lo, one)), R.Hi}
	case "<=":
		nl = Ival{L.Lo, bigMin(L.Hi, R.Hi)}
		nr = Ival{bigMax(R.Lo, L.Lo), R.Hi}
	case ">":
		nl = Ival{bigMax(L.Lo, new(big.Int).Add(R.Lo, one)), L.Hi}
		nr = Ival{R.Lo, bigMin(R.Hi, new(big.Int).Sub(L.Hi, one))}
	case ">=":
		nl = Ival{bigMax(L.Lo, R.Lo), L.Hi}
		nr = Ival{R.Lo, bigMin(R.Hi, L.Hi)}
	case "==":
		nl = Ival{bigMax(L.Lo, R.Lo), bigMin(L.Hi, R.Hi)}
		nr = nl
	default:
		return true
	}
	if nl.Lo.Cmp(nl.Hi) > 0 || nr.Lo.Cmp(nr.Hi) > 0 {
		return false
	}
	if ln != "" {
		v := *env[ln]
		v.Iv = Ival{new(big.Int).Set(nl.Lo), new(big.Int).Set(nl.Hi)}
		env[ln] = &v
	}
	if rn != "" && rn != ln {
		v := *env[rn]
		v.Iv = Ival{new(big.Int).Set(nr.Lo), new(big.Int).Set(nr.Hi)}
		env[rn] = &v
	}
	return true
}
