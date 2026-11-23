# Control-flow fixtures

Decision 0008 task 4. `docs/core/doom-stage2-language.md` states each form with
its position and its exact refusal and was written before any of it was coded;
`tests/doom-core/control-flow.sh` drives these.

| fixture | form |
| --- | --- |
| `src/if_stmt.rb` | a conditional with no else, in statement position |
| `src/if_value.rb` | the same in VALUE position — refused, and that is the point |
| `src/early_return.rb` | `return 1 if i > 0` |
| `src/break_while.rb`, `src/next_while.rb` | loop control without a value |
| `src/dc_nest.rb` | nested loops: the inner `break` leaves the inner one |
| `src/andand.rb`, `src/oror.rb`, `src/notop.rb` | the boolean operators |
| `src/dc_short.rb` | the plan's own short-circuit case, with a side effect on the right |
| `src/opassign.rb` | `buf[i] += 1` |
| `src/dc_once.rb` | an index expression with a side effect, to show it runs once |
| `refuse/break_value.rb` | `break 7` |
| `refuse/break_outside.rb` | `break` outside a loop — Ruby's parser refuses it first |
| `refuse/and_int.rb`, `refuse/not_int.rb` | an integer operand |
| `refuse/orassign.rb` | `buf[i] \|\|= 1` |
| `refuse/ro_opassign.rb` | `+=` through a read-only borrow |

Where the answer is an integer, CRuby running the same source is the reference.
Where it is a buffer, the bytes are.
