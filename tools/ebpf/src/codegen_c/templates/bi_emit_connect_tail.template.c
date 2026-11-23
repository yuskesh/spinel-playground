        _ce@E@->daddr = (__u32)(@DADDR@);
        _ce@E@->dport = (__u16)(@DPORT@);
        _ce@E@->family = (__u16)(@FAMILY@);
        _ce@E@->srtt_us = (__s64)BPF_CORE_READ((struct tcp_sock *)(unsigned long)(@SKADDR@), srtt_us);
        _ce@E@->oldstate = (__u32)(@OLDSTATE@);   /* E306: direction (active/passive) derived in userspace from the old TCP state */
        _ce@E@->daddr6_hi = (__u64)(@DADDR6_HI@);   /* E306: IPv6 daddr hi/lo (used when family==AF_INET6) */
        _ce@E@->daddr6_lo = (__u64)(@DADDR6_LO@);
        bpf_ringbuf_submit(_ce@E@, 0);
    } else spnl_lost_inc();   /* P011/E393: ring full -> account the dropped record */
}
