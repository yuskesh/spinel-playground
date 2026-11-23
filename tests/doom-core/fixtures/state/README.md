# State-schema fixtures

Decision 0008 task 5. `catalog.tsv` is the prepared resource and configuration
catalog a schema may name — supplied to the generator rather than inferred,
because these are facts about what Full prepares.

`ok.*` is the schema the generator must accept. Every other pair is one thing
wrong with it, and each has to be refused by its own category:

| fixture | what is wrong |
| --- | --- |
| `dup` | a field listed twice |
| `unknown_count` | a count kind outside the grammar |
| `unbound` | a count naming nothing in the catalog |
| `overflow` | a count whose byte product leaves u64 |
| `bad_initial` | an initial value outside its element type |
| `prep_len` | prepared data of the wrong length |
| `res_fill` | a resource with an initial fill, which CORE could never have written |
| `bad_role` | a role outside the four |
| `bad_element` | an element type outside the four |
| `unknown_buf` | an access row naming no field |
| `dup_access` | one buffer listed twice for one entry |
| `res_inout` | an entry asking to write a resource |
| `out_in` | an entry asking to read an output |

Two more pairs are each one line from `ok` and must be **accepted**, with the
scalar's own initial reaching `slots.tsv`. Both once generated with the
initial silently dropped, because the shared `core_state` was a single fill of
0:

| fixture | what it declares |
| --- | --- |
| `scalar_fill` | a scalar slot with the fill -1 |
| `scalar_prep` | a scalar slot with prepared data; `scalar_prep.catalog.tsv` is `catalog.tsv` plus the one-element `gametic_start` it names |
