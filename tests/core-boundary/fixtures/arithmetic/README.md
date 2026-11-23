# Arithmetic reference cases for the checked scalar mode

Written **before** the checked scalar mode exists, so the expected answers are
fixed independently of whatever that mode turns out to emit.

`cases.tsv` is the claim: for each case, the status (`ok`, `arithmetic`,
`refused`), the value on success, and the reason on failure, written from
decision 0007. `../../oracle.rb` derives all three again and requires them to
agree. A disagreement is a failure, not a value to copy over: the table and the
derivation come from different places, and one of them being wrong is the thing
worth finding.

CRuby cannot be the oracle for a failure, because Ruby has no failures here: it
promotes to Bignum and keeps going. So the oracle runs each definition twice —
once plainly, which is the reference for every successful value, and once with
operands that check each operation as it happens, which is what derives the
status. The second run is Ruby dispatching over the same untouched method
bodies, not a second interpreter, and the two are required to agree wherever
both produce a value.

One definition per file, plus any helpers it calls, and **no caller anywhere**.
The contract declares each parameter's domain, and the checker derives the rest
of the closure from those facts and validates every use against them. `refuse/`
holds the sources that must be rejected — the `core_fail` spellings that are
not `:capacity`, and three shapes a derivation that painted rather than proved
would let through.

The cases that carry the most weight:

- the four sign combinations of `/` and of `%`, which separate Ruby's floor
  division and divisor-signed remainder from C's truncation;
- `INT64_MIN / -1` (fails) against `INT64_MIN % -1` (succeeds with zero), which
  is the pair decision 0007 calls out;
- `0 << 64` and `-1 >> 64`, whose results fit and which must still fail: a
  lowering that checks only the result passes these by accident;
- `1 << -1`, where Ruby reverses the shift direction and this boundary refuses
  the input instead;
- `guarded_div(1, 0)` and `guard_untaken(INT64_MAX, 0)`, where the failing
  operation is not on the executed path;
- `mid_over(INT64_MAX, 1)`, which is `(INT64_MAX + 1) - 1`: the intermediate
  leaves i64 and the final value does not, so a check applied only to the
  returned value admits it.

`src/refused_ops.rb` holds what the boundary refuses to compile at all, rather
than executes and checks. Admitting that file is a failure.
