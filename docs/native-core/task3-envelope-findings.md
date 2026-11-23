# Task 3: the admitted hosted envelope

Decision [0005](../decisions/0005-native-core-executable.md), plan task 3.
Implemented in `tools/mlir/native/lib/Core/Eligibility.cpp`; no vendor change,
and the change is independent of the `--core` seam.

Debian, LLVM/Clang 23.1.1. Nothing here is macOS evidence.

## What the checker did before

The acceptance program was refused by the envelope and **only** by it: one
diagnostic, `binding-environment`, on the `puts` line. The type evidence already
passed — with a real integer caller the parameters, locals, comparison and
result were all proved. The control is the same method with no caller, refused
eleven times for `type-evidence` and never for the envelope, which is the
checker doing what decision 0005 requires: real inference evidence, not
synthetic integer callers.

The finding recorded before the change: every primitive-rebinding negative was
refused by the **same rule and the same reason string** as the program task 3
had to admit. Those negatives passed because the top level admitted nothing at
all, not because anything targeted rebinding.

## What was changed, and what deliberately was not

The blanket refusal is **unchanged**. A narrower admission was placed in front
of it:

```
puts <inference call>
```

and nothing wider. Every clause narrows: the receiverless `.` form, the name
`puts`, exactly one argument, that argument itself an inference call into the
checked closure, its result a proven non-null integer, and no top-level `def
puts` shadowing the operation. Anything that fails any clause falls through to
the blanket refusal untouched.

This admits **one shape by construction**. It is not a rebinding detector and
does not contain one. That was the point of keeping the blanket rule: the
negatives are still refused by exactly the rule that refused them before, so
admitting `puts` cannot have weakened them. A design that instead replaced the
blanket rule with per-case denials would have had to get the denial list right,
and would have been green throughout the transition while protecting nothing.

The `def puts` clause is worth naming separately. A top-level definition **is**
admitted by the envelope, so a program can define its own `puts`; without that
clause the admitted output form would apply to a call to an arbitrary user
method under the name the rule was written to allow.

## Measured behaviour

Positive — `CHECKED`, exit 0, **0 diagnostics**:

```ruby
def lower(a, b)
  a < b ? a : b
end

puts lower(7, 3)
```

Refused, all exit 1, none ever `CHECKED`:

| program | still refused by |
|---|---|
| `class Integer; def <(other); true; end; end` + root + `puts` | blanket rule |
| `Integer.prepend(Module.new { def <(x); false; end })` + … | blanket rule |
| `def setup; Integer.prepend(…); end` + `setup` + … | blanket rule |
| ordinary hosted helper called before the root | blanket rule |
| top-level `x = 1` | blanket rule |
| `def puts(v); v; end` + `puts pick(7,3)` | blanket rule |
| `puts 7` | blanket rule |
| `puts pick(7,3), pick(1,2)` | blanket rule |
| `puts other(7)` (call outside the closure) | blanket rule |
| `puts pick(7,3) { 1 }` | blanket rule |
| `puts pick(-9223372036854775808, 3)` | types **and** blanket rule |

The last row is the reserved value: reaching for the minimum host integer as a
literal makes the whole closure `bigint`, so it is refused for types *and* falls
through to the blanket refusal. The test asserts both, so neither can quietly
stop happening.

No test asserts a reason string as evidence of safety. Each asserts the
behaviour — refused, and never `CHECKED`. The presence of a word in a diagnostic
is not a safety property.

## Mutation build: each new clause, removed

The plan requires the new protection to be removed in an isolated build and the
negative controls to fail. Each clause was removed on its own, rebuilt, and the
suite re-run:

| removed clause | tests killed |
|---|---|
| `if (definitions.count("puts"))` | `test_a_user_defined_puts_does_not_get_admitted` |
| `if (type(values[0]) != "int")` | `test_sentinel_literal_argument_is_not_admitted` |
| `if (values.size() != 1)` | `test_puts_of_two_calls_is_not_admitted` |
| `if (!isInferenceCall(inner))` | `test_puts_of_a_call_outside_the_closure_is_not_admitted`, `test_puts_of_a_literal_is_not_admitted`, `test_puts_with_a_block_is_not_admitted` |

Every mutation is killed by exactly the test written for it, and the restored
build passes. The fourth kills three because that clause guards three distinct
forms.

`python3 tests/core-eligibility/run.py`: **46 passed** (32 pre-existing,
unchanged, plus 14).

## An unexercised rule, found and not fixed

`integer-representation` — "inference literal is outside the non-null host
integer domain" — has two sites in `Eligibility.cpp` and **no test reaches
either**. On this 64-bit host it appears unreachable from source: a literal at
the sentinel is typed `bigint` by the producer before the check sees it, which
is why the sentinel test above is caught by types instead.

So the rule that most directly implements the admitted value domain is the one
rule here with no negative control. It is recorded rather than fixed: reaching
it needs either a 32-bit target profile or a crafted contract-reader input, and
neither is in this task's scope. It should not be cited as evidence that the
domain is enforced until something exercises it.

## What `CHECKED` means, and does not

`CHECKED` is a **source check at host width**. It says the source constraints
hold for the program as this host's compiler typed it. It is not a proof about
the emitted artifact, and not a proof about the value domain of the *target*:
the host and the target can differ in pointer width, and nothing in this check
consults the target.

Two consequences worth stating because they are easy to slide past. A program
that is `CHECKED` here may still fail an artifact check later, and must, if the
object does not carry what the mapping expects. And the admitted integer domain
this check enforces is the **host's** `[INTPTR_MIN+1, INTPTR_MAX]`; a target
with a different width has a different domain, and that has not been measured.

## Not established here

- Anything about emission. `CHECKED` says the source constraints hold; the
  checker's own verdict line says "no artifact claim".
- Any ingress beyond the single admitted output call. The enumeration
  requirement from the task 2 report `§4b` is not implemented by this change.
- Anything about macOS.
