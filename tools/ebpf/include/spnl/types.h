/* SPDX-License-Identifier: GPL-2.0
 *
 * spinel-ebpf shared types — used by both eBPF C (generated) and host C.
 * Per ADR-002 §論点3 (host↔kernel ringbuf record header).
 *
 * Layout MUST stay 16 bytes and field order MUST not change without bumping
 * SPNL_EVENT_HDR_VERSION; both sides assume the same layout.
 *
 * This header does NOT define __u16/__u32/__u64 — they must be provided
 * by including either <vmlinux.h> (BPF side) or <linux/types.h> /
 * <bpf/libbpf.h> (host side) before this file.
 */
#ifndef SPNL_TYPES_H
#define SPNL_TYPES_H

#define SPNL_EVENT_HDR_VERSION 1

/* Type tag namespacing per ADR-002:
 *   0x0000-0x00FF : reserved for spinel-ebpf runtime (errors, system events)
 *   0x0100-0xFFFF : user codegen-allocated (one per Ruby class/method/event)
 */
#define SPNL_EVT_ERROR     0x0001
#define SPNL_EVT_USER_BASE 0x0100

/* E155: channel ごとの record ID。producer (codegen が出す .bpf.c) が
 * hdr.type に書き、consumer (record mirror の unpack / glue の drain) が
 * 突き合わせて、**自分の channel の tag でも SPNL_EVT_USER_BASE (旧 producer の
 * 一律値) でもないものを拒否**する。routing の正は ringbuf map 名のままで、
 * これは誤配線・破損に対する防御の面。
 *
 * **割当は append-only** — 値は BTF / object に焼き込まれて出荷されるので、
 * 一度割り当てた値は変えない。0x0100 台 = 汎用 emit channel (層の形ごと)、
 * 0x0110 台 = 宣言型 record channel (record_schema.h の行)。 */
#define SPNL_EVT_EMIT_INT   0x0100   /* == SPNL_EVT_USER_BASE: int channel が旧値を継ぐ */
#define SPNL_EVT_EMIT_STR   0x0101
#define SPNL_EVT_EMIT_PAIR  0x0102
#define SPNL_EVT_EMIT3      0x0103
#define SPNL_EVT_EMIT4      0x0104
#define SPNL_EVT_DNS        0x0110
#define SPNL_EVT_CONN       0x0111
#define SPNL_EVT_L7         0x0112
#define SPNL_EVT_HTTP       0x0113
#define SPNL_EVT_REDIS      0x0114
#define SPNL_EVT_OFFCPU     0x0115
#define SPNL_EVT_L7STREAM   0x0116

/* consumer 側の受理規則 (unpack / drain が共有する 1 本):
 * 自 channel の tag か、旧 producer の一律値 SPNL_EVT_USER_BASE のみ受ける。
 * それ以外 = 未知 ID / 別 channel の record — 拒否して落とす (数えるのは呼び手)。 */
#define SPNL_EVT_TYPE_OK(got, want) \
    ((__u16)(got) == (__u16)(want) || (__u16)(got) == (__u16)SPNL_EVT_USER_BASE)

struct spnl_event_hdr {
    __u16 type;
    __u16 version;
    __u32 reserved;
    __u64 timestamp;        /* bpf_ktime_get_ns() at producer side */
};

#endif /* SPNL_TYPES_H */
