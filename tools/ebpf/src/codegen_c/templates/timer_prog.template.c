/* E079: bpf_timer callback for on :timer, every: @NS@ ns.
 * The verifier requires bpf_timer callbacks to return literal 0
 * (the body's return value is ignored, which matches the Ruby
 * semantic of `on :timer do ... end` having no return value).
 *
 * E411 re-ported this from the retired Ruby codegen (lost in the ADR-011
 * Stage 2 port, withdrawn by E407) and re-measured the rule on 7.1.5:
 * returning an unknown scalar here still fails with "At async callback
 * return the register R0 has unknown scalar value should have been in
 * [0, 0]" -- the same verdict E079 recorded on 7.0.x. */
static int spnl_timer_cb_@NAME@(void *map, int *key, struct spnl_timer_value *v)
{
    (void)map; (void)key;
@BODY@    bpf_timer_start(&v->t, @NS@ULL, 0);
    return 0;
}

/* E079: arm prog — fired once by userspace at load time via
 * bpf_prog_test_run (glue.c _spnl_timer_arm_all fires every program whose
 * name starts with spnl_timer_arm_).
 *
 * `__u64 *ctx` is E079's shape. E411 measured that a plain `void *ctx` also
 * loads on 7.1.5, so that lesson has expired -- the typed pointer is kept
 * because it is what the arm program is (libbpf sizes the argument from BTF)
 * and because changing it would buy nothing. The literal 1 below has NOT
 * expired: CLOCK_MONOTONIC is still absent from vmlinux.h. */
SEC("syscall")
int spnl_timer_arm_@NAME@(__u64 *ctx)
{
    __u32 _k = 0;
    struct spnl_timer_value *_v = bpf_map_lookup_elem(&spnl_timer_map, &_k);
    if (!_v) return 0;
    bpf_timer_init(&_v->t, &spnl_timer_map, 1 /* CLOCK_MONOTONIC */);
    bpf_timer_set_callback(&_v->t, spnl_timer_cb_@NAME@);
    bpf_timer_start(&_v->t, @NS@ULL, 0);
    (void)ctx;
    return 0;
}
