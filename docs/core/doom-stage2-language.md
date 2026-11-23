# The CORE language surface, and what decision 0008 task 4 adds

**Status: proposed.** This is written BEFORE the syntax it describes is
implemented, which is what 0008's plan asks for: each form is listed with its
position, its admitted shape and its exact refusal before there is code that
decides any of it. Where a form is already implemented the entry says so.

The surface is decision 0007's, plus the forms 0008 measured the DOOM closure
to need. Nothing here broadens 0007's numeric, ownership or failure contracts:
the status ABI is still `0 OK, 1 ARGUMENT, 2 ARITHMETIC, 3 BOUNDS, 4 CAPACITY`
and `core_fail(:capacity)` is still the only intrinsic. A form that would need
a different domain or a new failure category is not here; it would be a
separate decision.

## Position

Two positions, and a form may be admitted in one and refused in the other.

* **Statement position** — the value is not consumed. Every element of a body
  except the last, and every statement of a loop body.
* **Value position** — the value is consumed: the last element of a method
  body or of a branch that produces the method's value, an operand, an
  argument, an index, or the right-hand side of an assignment.

The distinction is structural and is decided from the tree, not from a type.
It matters because Ruby gives a branch that did not run the value `nil`, and
there is no nil in this subset: a missing branch is admissible exactly when
nothing reads what it would have produced.

## What was measured before any of this was written

Each form below was run against the pin (`cad0ad14`) with the checker as
decision 0007 left it, so the "before" column is a measurement and not a
recollection.

| form | before |
| --- | --- |
| `if` with no `else`, statement position | `implicit-nil: both conditional branches must have explicit scalar results` |
| `if` with no `else`, value position | the same |
| `return` on one path | the same |
| `break` in a `while` | the same |
| `next` in a `while` | the same |
| `a && b` | `unsupported-node: AndNode` |
| `a \|\| b` | `unsupported-node: OrNode` |
| `!a` | `unresolved-call: no scalar effect contract for !` |
| `buf[i] += 1` | `unsupported-node: IndexOperatorWriteNode` |

## 1. A conditional with no else

**Admitted** in statement position:

```ruby
if i > 0
  r = 1
end
```

The branch that does not run produces no value, and nothing reads one. A name
the branch assigns is still subject to the existing rule that a name bound on
one path and not the other is refused where it is READ — that rule does not
change, and this form does not create an exception to it.

**Refused** in value position, with `implicit-nil`, unchanged:

```ruby
r = if i > 0
      1
    end          # implicit-nil: this branch has no value on the path not taken
```

`unless` without an `else` is the same form with the arms swapped and is
admitted and refused on the same rule.

**An unreachable path is not a nil value.** A branch whose body always returns
or always fails leaves nothing to merge, and that is a different fact from a
branch that fell through having produced nothing. The two keep separate
diagnostics.

## 2. `return` on one path

**Admitted** in statement position:

```ruby
return 1 if i > 0
0
```

The modifier form and the block form are the same shape. The returned
expression is in value position and must have a value; `return` with no
expression is refused with `implicit-nil`, because the method's result domain
is the contract's and there is nothing to publish.

## 3. `break` and `next`

**Admitted** inside a `while` or `until`, in statement position, **without a
value**:

```ruby
while k < 10
  break if k == i
  k = k + 1
end
```

`break` leaves the nearest enclosing loop and `next` starts its next
iteration. **Nearest** is the whole rule: there is no labelled loop here, and
a nested loop's `break` leaves the inner one.

**Refused:**

| shape | category |
| --- | --- |
| `break 1` or `next 1` | `loop-control-value` — a loop is a statement here and produces nothing, so a value would have nowhere to go |
| `break` or `next` outside any loop | `loop-control-outside-loop` |
| `redo`, `retry` | `unsupported-node`, unchanged |

## 4. `&&`, `||` and `!`

**Admitted** with **statically boolean operands**, with real short circuiting:

```ruby
(flag != 0) && dc_bump(count, n_count)
```

* Both operands of `&&` and `||` are booleans, and the result is a boolean.
  The operand of `!` is a boolean and the result is a boolean.
* The right operand of `&&` is evaluated **only** when the left is true, and
  the right operand of `||` **only** when the left is false. That is
  observable: the right operand may call a helper that writes a buffer, and
  it may fail — and a right operand that is never evaluated never fails.
* A boolean is not a number. `0` is not false and a boolean is not 0 or 1 at
  the source level; an internal helper may ANSWER a boolean (task 3), and the
  value travels in the status ABI's result slot as 0 or 1, which is a lowering
  detail and not a source-level coercion.

**Refused:**

| shape | category |
| --- | --- |
| an integer operand, e.g. `i && j` | `non-boolean-operand` — Ruby's truthiness makes every integer true, including 0, and this subset does not have it |
| a nullable or union operand | `non-boolean-operand`; there are no nullable unions here |
| `and`, `or`, `not` | the same nodes; admitted on the same rule |

## 4b. `true` and `false`

**Admitted** as literals. They were added while task 4 was being implemented,
because `&&` and `||` need statically boolean operands and an internal helper
answering a boolean has to be able to write one — the plan's own short-circuit
fixture ends `dc_bump` with `true`, and it was refused as `unsupported-node:
TrueNode`. Recorded here rather than left as an unstated addition.

They are **not** 1 and 0. Nothing in this subset converts between a boolean and
an integer; the widening that carries a helper's boolean through the status
ABI's result slot is a lowering detail with no source-level spelling.

## 5. `buf[i] += 1`

**Admitted** on a buffer the method holds writable, with `+ - * / % << >> & | ^`:

```ruby
buf[i] += 1
```

**The receiver and the index are evaluated exactly once.** The order is fixed
and observable:

1. evaluate the receiver and the index, once each;
2. bounds-check the index against the descriptor — `BOUNDS` if it is outside;
3. load the element and widen it to i64;
4. compute, with the same checked arithmetic an ordinary operator gets —
   `ARITHMETIC` on overflow or a zero divisor;
5. narrow the result to the element type — `ARITHMETIC` if it does not fit;
6. store.

**No store happens if 2, 4 or 5 fails.** A failure leaves the element exactly
as it was, which is the same promise an ordinary `buf[i] = v` makes.

An index expression with a side effect is evaluated once, and that is tested
with an index helper that counts its own calls rather than by reading the
generated code.

**Refused:**

| shape | category |
| --- | --- |
| the buffer is borrowed read-only | `readonly-write`, as for `[]=` |
| `buf[i] ||= v`, `buf[i] &&= v` | `unsupported-node` — these are conditional assignment, not operator assignment, and their nil semantics are not in this subset |
| an operator outside the list above | `unsupported-node` |

## 6. Loops with a literal block (decision 0041 stage 1)

Added after the rest of this document, by decision 0041 stage 1, and
implemented with it. The block is a compile-time entity: it is inlined as the
loop's body where it is written, and no Proc exists.

| form | loop |
| --- | --- |
| `n.times { \|i\| ... }` | `i` from 0 while `i < n` |
| `a.upto(b) { \|j\| ... }` | `j` from `a` to `b` inclusive |
| `a.downto(b) { \|j\| ... }` | `j` from `a` down to `b` inclusive |
| `buf.each { \|x\| ... }` | `x` each element of a declared buffer, in order |
| `buf.each_with_index { \|x, k\| ... }` | the element and its index |

* Statement position only. Ruby gives the loop the receiver as its value, and
  nothing here reads it.
* The receiver and the argument are read once, before the first iteration.
  The counter is hidden: assigning the block parameter or the receiver in the
  block does not change how many times the block runs.
* `upto` and `downto` leave through an equality test before stepping, so a
  loop to the largest or smallest Integer of the body ends without
  `ARITHMETIC`.
* `break` and `next` without a value, `return` and `core_fail` act as in a
  `while`; `next` goes on to the next element.
* The block may name fewer parameters than the call yields, never more. A
  block's own locals start afresh on every iteration, as in Ruby, so one
  read before it is assigned on some path is refused.

| shape | category |
| --- | --- |
| the loop's value is used | `loop-value` |
| `map`, `select` or any other call with a block; `&block`, `&:sym`; numbered or `it` parameters; optional, splat, keyword, block-local or destructured parameters; more parameters than the call yields | `unsupported-block` |
| a block parameter or block local with the name of a local of an enclosing scope | `unsupported-block` — Ruby makes it a variable of its own, and this subset gives a method one variable per name |
| `each` or `each_with_index` on anything but a declared buffer | `unsupported-block` |
| `break 1` or `next 1` | `loop-control-value`, as in a `while` |
| a block local read before it is assigned on some path | `type-evidence` (`local t is conflicting`) |
| `yield` | `unsupported-node`, unchanged |
| a block loop in a mode other than the checked scalar one | `unsupported-node`, as a `while` is |

## What is still refused, and stays refused

* `case`/`when`. 0008 says an unsupported `case` is refactored into explicit
  integer-tag branches with an adaptation record.
* Blocks other than §6's, `map`, `yield`, a block argument, any other call
  taking a block.
* `redo`, `retry`, `begin`/`rescue`, `raise`.
* Dispatch through a value: `send`, a method reference, a callback into Full.
* Recursion, direct or indirect. 0008 replaces each recursive component with
  an explicit preallocated work stack; the general refusal remains.
* Ruby truthiness of integers, in every position.

## How the closure survey is kept honest

`tests/core-boundary/fixtures/closure/constructs.tsv` records what each probe
does. A verdict there changes **only** when an execution or refusal fixture
establishes the change, and the row says which decision changed it — as the
`helper_buffer` row does for 0008 task 3.

The source census in `docs/core/doom-closure-gaps.md` is a count taken at a
revision. It is not edited to follow the checker: its denominator is a
historical fact about that revision, and a later admission is recorded beside
it rather than by rewriting it.
