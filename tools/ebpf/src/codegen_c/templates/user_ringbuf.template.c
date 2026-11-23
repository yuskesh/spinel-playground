/* E061: USER_RINGBUF for host→kernel command channel.
 *
 * The one direction a plain BPF ringbuf cannot go. `bpf_ringbuf_*` carries
 * kernel->host; this map carries host->kernel, in FIFO order, with the host
 * side batching through libbpf's reserve/submit (ADR-002 §論点3).
 *
 * E414 re-ported this from the retired Ruby codegen (lost in the ADR-011
 * Stage 2 port; E409 withdrew the map type after E406 withdrew
 * `user_ringbuf_drain` and E407 withdrew the `user_ringbuf__` attach kind).
 * The declaration below is byte-for-byte the oracle's, and the oracle's whole
 * output was measured to compile and load unchanged on 7.1.5-ebpf /
 * clang 19.1.7 / -mcpu=v1 (results/E414/d1_oracle_form_load.txt).
 *
 * TWO NUMBERS LIVE IN TWO FILES HERE and nothing checks them at build time:
 *   - the map's literal name `bpf_user_cmds`, which the loader's
 *     `sp_bpf_user_cmd_push` finds by string, and
 *   - the 8-byte record, which the callback below reads with a fixed
 *     `sizeof(__s64)` and the loader reserves with a fixed `sizeof(long long)`.
 * Measured what a disagreement does (results/E414/d1_recordsize.txt): a SHORT
 * record still fires the callback and still counts, but `bpf_dynptr_read`
 * returns -E2BIG and the value stays 0 -- silently. That is why the shipped
 * pusher is the only advertised way in, and why `describe` prints the size.
 *
 * max_entries is a byte count (ring size), not a record count: 256 KB. */
struct {
    __uint(type, BPF_MAP_TYPE_USER_RINGBUF);
    __uint(max_entries, 262144);
} bpf_user_cmds SEC(".maps");

static long spnl_user_ringbuf_cb_@CB@(struct bpf_dynptr *dynptr, void *_uctx);
