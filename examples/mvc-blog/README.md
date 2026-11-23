# examples/mvc-blog — a Rails-style blog on Workers

A small application split into router, controllers, models and views, written
in plain Ruby and compiled by Spinel. The same `app.rb` runs as a native CGI
executable and, through [`tools/wasm/spinel-wasm`](../../tools/wasm/README.md)
with `--host-api`, as a Cloudflare Workers module whose posts live in KV.
Neither `vendor/spinel` nor the worker template is changed for it. Ported from
spinel-llvm `463d49dd`; see [provenance](../../docs/provenance.md).

```
app.rb                      routes, and the only place that touches the CGI contract
framework/                  the mini framework, independent of the app
  codec.rb                  percent-encoding (form bodies and the record format)
  view.rb                   %{...} templates with HTML escaping by default
  model.rb                  Store / Repo / Model: validation and persistence
  controller.rb             Request / Response / Controller
  router.rb                 RESTful routing by path segments
app/                        the blog: models/post.rb, controllers/, views/
native/edge/kv.rb           a KV test double for native runs (not in the wasm build)
```

The program meets the host through the CGI contract of the worker template:
`ARGV[0]` is the path, `ARGV[1]` the query string, `$stdin` the body, `ENV` the
CGI variables, and `$stdout` the response. With `SPINEL_CGI_HEADERS=1` a
leading header block (`Status:`, `Location:`, `Content-Type:`) becomes the
HTTP status and headers. A 404 or 422 is a normal result: the program exits 0
and says so in `Status:`. Only a crash is a 500.

Each request is a fresh instance, so nothing survives in memory. KV is the only
persistent store; without a KV binding the app still answers, starts empty
every time, and says `store: memory` in its footer.

## Build and run

Native, the fastest loop:

```sh
vendor/spinel/bin/spinel examples/mvc-blog/app.rb -I examples/mvc-blog/native -o /tmp/mvc
export SPINEL_CGI_HEADERS=1
export MVC_NATIVE_KV=/tmp/mvc-kv.txt SPINEL_HOST_KV=MY_KV   # persistence through the test double
REQUEST_METHOD=GET /tmp/mvc /posts ''
printf 'title=hello&body=world' |
  REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded /tmp/mvc /posts ''
```

`-I native` resolves `require "edge/kv"` to the test double; the real
`tools/wasm/lib/edge/kv.rb` declares host imports a native link cannot satisfy.

Workers, on local workerd:

```sh
examples/mvc-blog/build.sh              # spinel-wasm --emit-worker dist --host-api
cd examples/mvc-blog/dist && wrangler dev --local
```

`wrangler.toml` sets `SPINEL_CGI_HEADERS = "1"`. For persistence, add a KV
namespace and name it in `SPINEL_HOST_KV`, which is the explicit list of
bindings the app may reach:

```toml
[vars]
SPINEL_HOST_KV = "MVC_KV"

[[kv_namespaces]]
binding = "MVC_KV"
id = "mvc_local"
```

`bash tests/mvc-blog/run.sh` runs both: the native CGI flow with the KV double,
and the Workers module with and without a KV binding.

## Records in KV

There is no JSON on this target (`require "json"` needs a native object), so a
record is one string of `field=value` lines, split at the first `=`, with only
`%`, `\n` and `\r` escaped. UTF-8 stays readable in KV. Keys: `posts:seq` (the
next id), `posts:index` (live ids, one per line) and `posts:<id>`. KV has no
delete, so `destroy` removes the id from the index and blanks the record.

## What it is not

No database or relations (KV has get and put only, so a list is 1 + N reads,
and the app does not hide that), no sessions, flash or CSRF token (nowhere to
keep state between requests), no ERB (templates are heredocs with `%{...}`;
there is no compiler at run time), no `send`, `before_action` or class-body
macros such as `validates` (validations are a class method,
`def self.validations`), and no streaming.

## Writing Rails-style code in the Spinel subset

What spinel-llvm hit while writing this app, and what the code does instead:

- An action cannot be named `new`: it collides with the class allocator in the
  generated C, and the build fails. The action is `new_form`.
- A user-defined macro in a class body is not run, silently. Declare rules as
  an overridable class method.
- A class method defined only on the base class, called as `self.class.x`,
  runs with the base class as receiver, silently. Only overridden class
  methods are called through the instance; the rest are module functions
  (`Repo.*`) that take what they need as arguments.
- A base-class default of `[]` where the subclass returns strings makes two
  array types collide; the default is a non-empty array of the same shape.
- `Hash#key?` with a block's boxed key could answer false on a
  String-to-String hash, silently. The model reads attributes through its own
  field list (`attrs[f]`) instead. Not re-checked at this pin.
- `ENV` cannot flow as a value; read `ENV["KEY"]` where it is used.
- `id` is a String throughout, so every call site agrees on its type.
- Routes match top to bottom, so `/posts/new` precedes `/posts/:id`.

Two more no longer reproduce at the pinned compiler (checked 2026-09-23):
`str[i] == "x"` answering false after a multibyte character, and the word
`Set` anywhere in the source pulling in the set package and stopping the wasm
build. The code keeps its workarounds for them.

[VALIDATION.md](VALIDATION.md) is spinel-llvm's original validation record,
kept as history; the comments in the sources refer to it.
