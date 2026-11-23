# Trace byte fixtures

One byte stream per record kind of `tools/app/lib/core_app/trace_schema.tsv`
(`<KIND>.bin`), each with its text form (`<KIND>.txt`, the line the host
runner's trace would print for the same record). `tests/app/verify.sh`
requires the set of fixtures to be exactly the schema's kinds, decodes every
`.bin` and compares it with its `.txt`, and encodes every `.txt` back and
compares the bytes, so the fixtures pin the encoding in both directions:
`HEADER` pins u64 and u8 counts, `LOAD` a negative i64, `FAIL` a negative
i32, `XCALL` a scalar and a buffer argument, `ENQ` a payload, `DEQ` an empty
one, `DROP` the code 2 (`channel_full`). The code table's six values are
pinned by the suite's schema check, not by the fixtures (three of the six
appear in a fixture). The four `refuse-*.bin` streams are the decoder's
refusals: an unknown kind (99), a record shorter than its header says, a
`body_len` over the 4096 limit, and a body the fields do not consume
exactly. The bytes are checked in as data; the schema and the decoder are
the two independent readings of them.
