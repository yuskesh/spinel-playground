> **Historical record, not current evidence.** This is spinel-llvm's validation of
> the app at its own compiler pin (revision `463d49dd`), kept because comments in
> the sources cite it. At this repository's pin, `tests/mvc-blog/run.sh` is the
> check, and §4-1 and §4-3 no longer reproduce (README). Timings are
> measurements of that time and machine, not claims.

# examples/mvc — validation record

`examples/mvc` is a sample, not an experiment, so it does not use `docs/experiments/results/`.
This file holds **what was actually run on this subject, and the results**.

Environment: macOS 26.6 (arm64) / node v24.12.0 / wrangler 4.61.1 (`--local` = workerd) /
`vendor/spinel` is the submodule's `c-emit-ir` (unmodified) / `tools/wasm` is unmodified too.
**Not one byte of `worker.mjs` / `wasi_shim.mjs` / `spinel_host.mjs` was touched.**

---

## 0. Summary

| Item | Result |
| --- | --- |
| Fit to the subset | **The build passes without `--allow-unsupported`**. 10 forms were avoided (README §"Notes on a Rails-style design in the Spinel subset") |
| Several files | **`require_relative` works as it is**. No concatenation step in the build is needed |
| native e2e | 8/8 pass (routing / validation / escaping / multibyte / persistence / deletion / 404 / redirect) |
| workerd e2e (with KV) | 10/10 pass. **State persists across requests** |
| workerd e2e (without KV) | As specified, **every request starts empty**. The id is 1 every time, and the list is always empty |
| Size | `app.wasm` **483,969 B** / gzip **137,625 B** (1.97 times / 1.47 times echo.rb) |
| Latency (GET /posts, 10 posts, KV) | wall **p50 6.37 ms** / in-handler p50 5 ms / 12 KV gets = 12 suspends |
| Holes found | **3** (2 of them "silently return a wrong answer". §4) |

---

## 1. Build

```
$ vendor/spinel/bin/spinel app.rb -I native -o /tmp/mvc            # native  1.35 s
$ tools/wasm/spinel-wasm app.rb -o app.wasm --host-api            # wasm    1.53 s (rt cache warm)
$ tools/wasm/spinel-wasm app.rb --emit-worker DIR --host-api      # the full Workers set
```

- **`--allow-unsupported` is not used.** The unsupported-construct gate lets it through.
- The generated C is 3,454 lines (Ruby 1,285 lines; the 120 lines of `native/edge/kv.rb`
  are native only and do not go into wasm).
- The imports are **16 from wasi_snapshot_preview1 and 5 from `spinel_host`**:
  `last_error` / `res_body_len` / `res_body_read` / `kv_get` / `kv_put`.
  **`http_request` and `res_headers` are not there** — this app does not call
  `Edge::HTTP.request`, so `--gc-sections` dropped them, thunks and all
  (E014's "you do not pay for what you do not use", observed as it is).

### How several files are bundled (a point the request asked to confirm)

**`require_relative` works, so no concatenation step in the build is needed.**

- Spinel **inserts `require` / `require_relative` as text at compile
  time** (`src/spinel_parse.c:2051-` `resolve_requires`). No file system is
  involved at run time, so it works as it is in wasm, which has no file system.
- Files are deduplicated by canonical path, so one file may be required from several.
  `framework/model.rb` and `framework/controller.rb` both
  require `codec`, but it is inserted only once (measured: no struct redefinition error).
- `require_relative` is **relative to the requiring file**. No `-I` is needed.
- Only `require "edge/kv"` uses the `-I` search roots. `--host-api` adds
  `tools/wasm/lib` as a root.
- **For native, add `-I native` so that it resolves to `native/edge/kv.rb`.**
  The real `tools/wasm/lib/edge/kv.rb` is a set of `ffi_func :sp_host_*` declarations, so
  linking it natively gives `Undefined symbols: _sp_host_available` (measured).

---

## 2. native e2e

`vendor/spinel/bin/spinel app.rb -I native -o /tmp/mvc` is driven directly as a CGI.
Pointing `MVC_NATIVE_KV` at a file enables the KV test double in `native/edge/kv.rb`
(1 line = `ns\tkey\tvalue`), so **persistence across processes can be exercised natively too**.

| # | Input | Expected | Measured |
| --- | --- | --- | --- |
| 1 | `GET /` | 303 → `/posts` | ✅ `Status: 303` + `Location: /posts` |
| 2 | `POST /posts` (multibyte + `<script>alert(1)</script>` in `title`, a newline in `body`) | 303 → `/posts/1` | ✅ |
| 3 | `POST /posts` (the second) | 303 → `/posts/2` | ✅ the id is numbered |
| 4 | `GET /posts` | 2 posts, titles escaped | ✅ `日本語 &lt;script&gt;alert(1)&lt;/script&gt;` |
| 5 | `GET /posts/1` | newlines in the body become `<br>`, `<script>` is made harmless | ✅ `<div>1行目<br>` |
| 6 | `POST /posts` (empty) | 422 + 2 errors + the input kept | ✅ |
| 7 | `POST /posts` (`title` of 81 characters) | 422 (max_length 80) | ✅ |
| 8 | `POST /posts/1/delete` → `GET /posts` | 303 → `/posts`, 1 post listed | ✅ `posts: 2` → `posts: 1` |
| 9 | `GET /posts/1` (deleted) / `GET /nope` | 404 | ✅ `Status: 404` for both, **exit code 0** |

The multibyte input of row 2 is a Japanese title, a word meaning "Japanese", and a
body whose two lines are Japanese for "line 1" and "line 2"; rows 4 and 5, and the
records below, show those bytes as they came back.

The KV double's contents (the encoding, as stored):

```
MY_KV	posts:seq	2
MY_KV	posts:index	1%0A2
MY_KV	posts:1	title=日本語 <script>alert(1)</script>%0Abody=1行目%250A2行目%0Acreated_at=1786837366%0A
MY_KV	posts:2	title=second%0Abody=hello world%0Acreated_at=1786837366%0A
```

`%250A` is **a newline escaped twice** — the record turned `\n` into `%0A`,
and the double's file format turned that `%` into `%25`. It is evidence that the nesting is intact.
UTF-8 and `<` `>` are not escaped, so the KV contents can be read by eye.

---

## 3. workerd e2e (`wrangler dev --local`)

```toml
[vars]
SPINEL_CGI_HEADERS = "1"
SPINEL_HOST_KV = "MVC_KV"
[[kv_namespaces]]
binding = "MVC_KV"
id = "mvc_local"
```

### 3-1. With a KV binding

| # | Request | Measured |
| --- | --- | --- |
| 1 | `GET /` | `303` / `Location: /posts` / `x-spinel-exit: 0` |
| 2 | `POST /posts` (multibyte + HTML injection) | `303` → `/posts/1`, `x-spinel-host: kv_get=2 kv_put=3 suspends=5` |
| 3 | `POST /posts` (the second) | `303` → `/posts/2` |
| 4 | `GET /posts` (**another instance**) | 2 posts appear. **State persists across requests** |
| 5 | Escaping | `<h2><a href="/posts/1">日本語 &lt;script&gt;alert(1)&lt;/script&gt;</a></h2>` |
| 6 | `GET /posts/1` | `<div>1行目<br>` / `#1 / created_at=1786837638` (`Time.now` works in wasm) |
| 7 | `POST /posts` (empty) | `422` |
| 8 | `GET /nope` / `GET /posts/999` | `404` / `404` |
| 9 | `POST /posts/1/delete` | `303` → `/posts`, the list goes from `posts: 2` → `posts: 1` |
| 10 | `HEAD /posts` | `200` (the router takes HEAD on the GET route) |

4 passes **although every request is instantiated afresh** = the state lives only in KV.

### 3-2. Without a KV binding (production's default)

The same `app.wasm`, with `SPINEL_HOST_KV` and `[[kv_namespaces]]` removed:

| Request | Measured |
| --- | --- |
| `POST /posts` | `303` → `/posts/**1**` |
| `POST /posts` (the second time) | `303` → `/posts/**1**` ← **number 1 again** |
| `GET /posts` | "まだ記事がありません" (the app's "no posts yet") / `store: memory / posts: 0` |
| `GET /posts/1` | `404` |
| host counters | `kv_get=0 kv_put=0 suspends=0` |

**The in-memory store disappears after one request.** This is just E011/E013's
"instantiate per request" showing through, not a bug. That is why
the footer (`store: memory`) always shows that
"without a binding it works, but nothing is kept".
**This is why KV is needed.**

### 3-3. Size and latency

| Module | bytes | gzip -9 |
| --- | --- | --- |
| `examples/echo.rb` | 245,150 | 93,420 |
| `examples/fetch.rb` (`--host-api`) | 224,489 | 86,189 |
| **`examples/mvc/app.rb`** (`--host-api`) | **483,969** | **137,625** |

The MVC framework + app, 1,165 lines (excluding the 120 native-only lines), cost
**+239 KB / gzip +44 KB**.

Latency (`wrangler dev --local`, 10 posts, 100 samples after 20 warm-up runs):

| Path | KV get | suspend | wall p50 | wall p90 | wall p99 | in-handler p50 (`x-spinel-ms`) |
| --- | --- | --- | --- | --- | --- | --- |
| `GET /posts` (10 posts) | 12 | 12 | **6.37 ms** | 7.79 | 10.50 | 5 ms |
| `GET /posts/new` | 1 | 1 | 2.91 ms | 3.28 | — | — |
| `GET /posts` (without KV) | 0 | 0 | 2.34 ms | 3.24 | — | 1 ms |

- **About 0.32 ms per KV access** ((6.37 − 2.34) / 12, local workerd).
- The 12 accesses of `GET /posts` have **the 1 + N shape**: the index 1 + 10 records +
  the layout's footer reads the index once more for `Post.count`.
  KV has neither `list` nor a range read, so this cannot be hidden
  (the same picture as Rails' N+1, and **it was left visible on purpose**).
  Computing `Post.count` from `Post.all.length` would cut it to 11, but
  it would couple the layout to the controller, so the sample leaves it as it is.
- The 2.34 ms of a bare `GET /posts` (without KV) is the sum of instantiation + Ruby execution +
  E013's lifecycle layer.

---

## 4. Holes observed

Not "the subset was avoided", but things that **should have been writable and did not work as expected**.
1 and 2 **return a wrong answer with no exception and no warning**, which is the kind of breakage this platform dislikes most.
All of them also reproduce with the native `vendor/spinel/bin/spinel`, so none is specific to wasm.

### 4-1. `str[i] == "<a 1-byte literal>"` compares at a byte position (**a silent wrong answer**)

The test string starts with a Japanese character that takes 3 bytes in UTF-8, so
every later character's byte offset differs from its character index.

```ruby
s = "あ%{x}"
# characters: あ(0) %(1) {(2) x(3) }(4)   bytes: あ=0..2, %=3, {=4, ...
s.length        #=> 5      (correct)
s[1]            #=> "%"    (correct)
s[1] == "%"     #=> false  ← ★ wrong
t = s[1]; t == "%"   #=> true    (correct when taken into a local variable)
s[1].eql?("%")       #=> true    (eql? is correct)
"%" == s[1]          #=> false   (wrong with the sides swapped, too)
"ascii%{x}"[5] == "%" #=> true   (correct when there is no multibyte character)
```

Minimal reproduction (`spinel p.rb -o p && ./p`):

```ruby
s = "あ%{x}"
puts s[1].inspect                 # "%"
puts (s[1] == "%").inspect        # false
```

- It happens only when **a multibyte character comes before the index**.
- It happens only when the other side is a 1-byte ASCII literal
  (comparing with a multibyte literal, as in `t[1] == "い"`, another 3-byte
  Japanese character, is correct).
- The generated C appears to choose a fast path that treats the index as a **byte offset**.

**On this subject this was the most dangerous one.** Template scanning (`framework/view.rb`) and
the router's pattern matching (`framework/router.rb`) both hit it,
and it surfaced as **`%!{posts}` appearing in the HTML unreplaced**.
No exception is raised, so it goes unnoticed until the native output is read by eye.

Workaround: **always take the indexed character into a local variable before comparing**. Both files carry a comment saying so.

### 4-2. `Hash{String=>String}#key?` is always false for a boxed key (**a silent wrong answer**)

`Model#initialize`'s

```ruby
attributes.each do |k, v|
  @attributes[k] = v.to_s if @attributes.key?(k)
end
```

**assigned nothing at all**. The generated C (`spinel app.rb -c`) shows `key?` falling into
the generic `include?` dispatch, whose `switch` has only
the 7 cases

```
SP_BUILTIN_RANGE, SP_BUILTIN_FLOAT_RANGE, SP_BUILTIN_INT_ARRAY,
SP_BUILTIN_FLT_ARRAY, SP_BUILTIN_STR_ARRAY, SP_BUILTIN_POLY_ARRAY,
SP_BUILTIN_POLY_POLY_HASH
```

— **there is no case for `SP_BUILTIN_STR_STR_HASH`**, so it fell to
`default: sp_poly_user_include(...)` and returned 0.
The receiver is `@attributes` (a StrStrHash) and the key is a block argument of a poly `each`
(`sp_RbVal`).

- A small standalone program does not reproduce it (when the receiver or the key is inferred to a concrete type, the right path is emitted).
- The generated C that reproduces it could still be observed with `spinel app.rb -c -o out.c`, but
  **it could not be narrowed to a minimal reproduction of about 10 lines**. The case list above is the evidence.

Workaround: stop iterating over the given Hash with `each`, and **look up
`attributes[f]` from the schema side (`fields`)**. As a side effect this also gives the effect of strong parameters.

### 4-3. The name of the set class (the 3 letters S-e-t) in the source stops the wasm build

```ruby
# Set
puts 1
```

Feeding these 2 lines to `spinel-wasm` gives:

```
spinel-wasm: unsupported construct(s) for the wasm32 profile:
  - Enumerator#next / #peek / #to_a / #take (external iteration) ...
```

**A single word inside a comment** stops the build. The output of `spinel -c` shows
`packages/set/set.rb` inserted as it is, 114 lines, and the unsupported-construct gate
correctly detects the `Enumerator#to_a` inside it.

- It also happens inside a string literal (`$stderr.puts "Set"`).
- It does not happen with `set` (lower case) or `aSet`. **Only that word as a bare identifier**.
- It does not happen with other package names (`ERB` / `JSON` / `CSV` / `Pathname` / `StringIO` /
  `Base64` / `Digest` / `OptionParser`) — **only `set` is
  required automatically**.
- This app hit it by writing "... it in wrangler.toml" in the warning text for
  `SPINEL_CGI_HEADERS`.

**It does not break silently** (the build stops), so it is milder than 1 / 2. But
**the error names a construct that was never written**, so reaching the cause is hard.
In the same spirit as `spinel-wasm`'s link-error translation table (README "Translating link errors"),
**an unsupported construct that comes from an inserted package should say where it came from**, I think.

### 4-4. (For reference) `+=` on a String captured by a block became `sp_int_add`

In a version during development, `Response#to_cgi`'s

```ruby
out = "Status: #{@status}\n"
@headers.each { |k, v| out += "#{k}: #{v}\n" }
```

became `(*_wc715) = sp_int_add((*...->out), <string concatenation>)` in the generated C, and
failed with **a C compile error** (the capture struct's type was `const char **`, which is correct).

- **Once the model layer was changed to §4-2's form, it no longer reproduced** — so the type inference
  of an unrelated method had been contaminated. No minimal reproduction was obtained.
- A snapshot of the tree that reproduces it exists only in a working directory from development,
  so as a reproduction step it can only be called "the broken version's `framework/model.rb`".
- **It fails at compile time**, so it is not a silent breakage.
- The current code uses `Array#<<` + `join` (a form this inference does not affect).

---

## 5. Where this deliberately did not go

- **Not validated on a real edge.** Only `wrangler dev --local` (workerd) and native.
  The same as E014's Honest boundary.
- **Concurrency was not measured.** E013 measured that 50 concurrent requests do not
  contaminate each other, and this app keeps no module-lifetime state at all, so
  the same conclusion should hold as it is, but **it was not measured**.
- **KV consistency was not considered.** The read-modify-write of the index (`posts:index`) is
  not atomic, so **concurrent POSTs can lose an id**.
  KV has no CAS, and neither does E014's bridge v0, so
  this is left as "do not fake what is not there".
- **`Edge::HTTP.request` is not used.** This app makes no outbound requests, and
  that shows in the import list (§1) too.
