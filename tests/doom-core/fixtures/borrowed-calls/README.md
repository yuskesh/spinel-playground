# Borrowed-call fixtures

Decision 0008 task 3. `src/` is what must compile and run; `refuse/` is what
must be refused, each by its own named category. `tests/doom-core/
borrowed-calls.sh` drives both.

The plan's own positive fixture is `src/dc_pick.rb`, and it was written and
run BEFORE the implementation, as the plan asks. What it answered then, at
`cad0ad14` with the checker as it stood:

```
spinel-core-kernel: not-eligible: type-evidence: parameter data is buffer (…/dc_pick.rb:18:0)
spinel-core-kernel: not-eligible: type-evidence: local data is buffer (…/dc_pick.rb:18:0)
spinel-core-kernel: not-eligible: type-evidence: expression is buffer (…/dc_pick.rb:19:2)
```

The entry's buffer facts stopped at the entry: a helper's parameter could only
ever be an integer. What it answers now is in the test.

| fixture | what it is for |
| --- | --- |
| `src/dc_pick.rb` | the plan's own: one call, and a scalar reassignment that must not move the helper's bound |
| `src/dc_nested.rb` | the borrow two calls deep |
| `src/dc_two.rb` | two live buffers with two counts, both reaching one helper |
| `src/dc_twice_ro.rb` | the same read-only buffer at two argument positions — the positive control beside `refuse/dup_mutable.rb` |
| `src/dc_store.rb` | a write through a borrowed `inout`, and a value that must be narrowed before it |
| `src/dc_i64.rb` | an i64 element, where `INT64_MIN` is a value and not a sentinel |
| `src/dc_bool.rb` | an internal boolean helper and the branch that consumes it |
| `refuse/readonly_write.rb` | a callee writing a borrow that reached it read-only |
| `refuse/dup_mutable.rb` | one writable buffer passed twice — two names for one storage |
| `refuse/escape.rb` | a borrowed address returned out of the call that lent it |
| `refuse/rebind.rb` | rebinding the name a borrow arrived under |
| `refuse/buffer_arith.rb` | arithmetic on an address |
| `refuse/recursive.rb` | a recursive call cycle |
| `refuse/unknown_call.rb` | a call to something outside the closure |
| `refuse/bool_result.rb` | a boolean exported under an integer contract |
