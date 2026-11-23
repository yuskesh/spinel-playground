# r2-d1 — R2 (object storage) and D1 (SQL) from Ruby

An asset store in one Ruby program. **R2 holds the bytes, and D1 holds the facts
about them.** Returning a PNG is something only R2 can do; "the ten largest" or
"find by name" is something only D1 can do.

```sh
./build.sh
(cd dist && npx wrangler dev --local)   # R2 and D1 emulated locally, no account
```

| Route | What it does |
|---|---|
| `GET /` | the upload form and the list (a D1 `SELECT`) |
| `POST /upload?name=..&type=..` | the body is the file: put into R2, one row inserted into D1, then 303 to `/` |
| `GET /a/<id>` | the bytes from R2, exactly as uploaded |
| `POST /a/<id>/delete` | removed from both R2 and D1, then 303 to `/` |
| `GET /orphans` | R2's listing checked against D1's index |

## Design points

- **Values always go in placeholders.** `Cloudflare::D1` has no method that
  takes SQL and values together, so there is no way to build SQL by string
  concatenation.
- Typed accessors: use `row.int("id")`, not `row["id"]`.
- The bridge has no D1 transactions, so an upload that fails halfway undoes its
  own earlier steps.
- Only the bindings named in `[vars]` (`SPINEL_HOST_R2`, `SPINEL_HOST_D1`) are
  reachable from Ruby; binding them in `wrangler.toml` alone is not enough.

## Checked

`tests/edge/run.sh` runs it under local workerd. An upload answers 303 and
appears in the listing; the asset comes back byte for byte, including non-UTF-8
bytes; `/orphans` answers; and a delete answers 303 and removes the asset from
the listing.
