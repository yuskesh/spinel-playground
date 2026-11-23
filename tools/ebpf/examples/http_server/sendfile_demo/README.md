# sendfile_demo — sendfile(2) zero-copy static file serving (E180)

A server that only adds one route, `GET /static`, to M001's HTTP/1.0 accept loop.
Only `/static` streams its body directly **from the file page cache → the socket** with `sendfile(2)`
(the counterpart of nginx's `sendfile on`). HTTP framing stays in Ruby; only the body transfer is pushed down to the kernel.

| Route | Response | Path |
|---|---|---|
| `GET /static` | contents of `$SPINEL_STATIC_FILE` (200) / 404 if missing | header=`write`, body=**`sendfile`** |
| `GET /` | `hello\n` (200) | `write` (for contrast) |
| `GET /health` | `OK\n` (200) | `write` |
| other / non-GET / malformed | 404 / 405 / 400 | `write` |

## Build + run (container)

```bash
container exec spnlbuild bash -c '
  export LANG=C.UTF-8
  cd /work
  ruby bin/spinel-ebpf compile examples/http_server/sendfile_demo/server.rb \
    -o /tmp/sfd --build --native-only
  head -c 1048576 /dev/urandom > /tmp/static.bin
  SPINEL_HTTP_PORT=8189 SPINEL_STATIC_FILE=/tmp/static.bin /tmp/sfd/server &
  sleep 1
  curl -s http://127.0.0.1:8189/static -o /tmp/out.bin
  cmp /tmp/static.bin /tmp/out.bin && echo "byte-identical"
'
```

## Proof that sendfile is issued (strace)

```bash
strace -f -e trace=sendfile,sendto,write -o strace.log \
  env SPINEL_STATIC_FILE=/tmp/static.bin /tmp/sfd/server &
# after curl /static:
#   sendto(4, "HTTP/1.0 200 OK...", 103, ...) = 103      <- only the header takes the write path
#   sendfile(4, 5, [0] => [1048576], 1048576) = 1048576  <- the 1MB body is kernel zero-copy
```

Apart from the header of at most 103 bytes, the 1MB body never goes through `write`/`sendto`.
Details are in the E180 Edoc.
