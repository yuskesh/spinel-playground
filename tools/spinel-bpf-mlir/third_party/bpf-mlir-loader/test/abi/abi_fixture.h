/* abi_fixture.h — abi_case の入力 (bpf-mlir の kernel/flow/mlir の ELF の map の宣言・records・UDP の frame — E006) */
#ifndef BML_TEST_ABI_FIXTURE_H
#define BML_TEST_ABI_FIXTURE_H

#include <stdint.h>
#include <string.h>

#define M_EVENTS "{\"name\":\"events\",\"kind\":\"ringbuf\",\"key\":\"-\",\"value\":\"record:event\",\"max_entries\":4096}"
#define M_FLOWS "{\"name\":\"flows\",\"kind\":\"lru_hash\",\"key\":\"record:flow_key\",\"value\":\"record:flow_val\",\"max_entries\":64}"
#define M_POLICY "{\"name\":\"policy\",\"kind\":\"lpm_trie\",\"key\":\"record:lpm_key\",\"value\":\"u32\",\"max_entries\":16,\"flags\":1}"
#define M_STATS(mx) "{\"name\":\"stats\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":" mx "}"

#define MAPS_OK "{\"globals\":[],\"maps\":[" M_EVENTS "," M_FLOWS "," M_POLICY "," M_STATS("4") "]}"
#define MAPS_BAD_MAX "{\"maps\":[" M_EVENTS "," M_FLOWS "," M_POLICY "," M_STATS("5") "]}"
#define MAPS_GHOST_GLOBAL                                                                                                          \
	"{\"globals\":[{\"name\":\"ghost\",\"section\":\"rodata\",\"type\":\"u32\"}],\"maps\":[" M_EVENTS "," M_FLOWS "," M_POLICY "," M_STATS("4") "]}"

#define DECL_STATS M_STATS("4")
#define DECL_STATS_U32 "{\"name\":\"stats\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u32\",\"max_entries\":4}"
#define DECL_STATS_HASH "{\"name\":\"stats\",\"kind\":\"hash\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":4}"
#define DECL_NOPE "{\"name\":\"nope\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":4}"
#define DECL_FLOWS M_FLOWS
#define DECL_FLOWS_ARRAY "{\"name\":\"flows\",\"kind\":\"array\",\"key\":\"record:flow_key\",\"value\":\"record:flow_val\",\"max_entries\":64}"
#define DECL_EVENTS M_EVENTS

#define R_FLOW_KEY                                                                                                                 \
	"\"flow_key\":{\"size\":16,\"members\":[{\"name\":\"saddr\",\"offset\":0,\"type\":\"u32\"},{\"name\":\"daddr\",\"offset\":4,\"type\":\"u32\"},"  \
	"{\"name\":\"sport\",\"offset\":8,\"type\":\"u16\"},{\"name\":\"dport\",\"offset\":10,\"type\":\"u16\"},"                        \
	"{\"name\":\"proto\",\"offset\":12,\"type\":\"u8\"},{\"name\":\"_pad\",\"offset\":13,\"type\":\"[3]u8\"}]}"
#define R_FLOW_VAL                                                                                                                 \
	"\"flow_val\":{\"size\":24,\"members\":[{\"name\":\"packets\",\"offset\":0,\"type\":\"u64\"},{\"name\":\"bytes\",\"offset\":8,\"type\":\"u64\"}," \
	"{\"name\":\"last_ns\",\"offset\":16,\"type\":\"u64\"}]}"
#define R_EVENT                                                                                                                    \
	"\"event\":{\"size\":32,\"members\":[{\"name\":\"key\",\"offset\":0,\"type\":\"record:flow_key\"},"                                 \
	"{\"name\":\"first_ns\",\"offset\":16,\"type\":\"u64\"},{\"name\":\"len\",\"offset\":24,\"type\":\"u32\"},{\"name\":\"_pad\",\"offset\":28,\"type\":\"u32\"}]}"

#define REC_KEY "{" R_FLOW_KEY "}"
#define REC_VAL "{" R_FLOW_VAL "}"
#define REC_EVENT "{" R_EVENT "," R_FLOW_KEY "}"

/* Ethernet (0x0800) + IPv4 (IHL 5・total length 28・proto 17・fragment 0・10.0.0.1 → 10.0.0.2) + UDP (1234 → 80) — 42 byte */
static inline void udp_frame(uint8_t f[42])
{
	static const uint8_t h[42] = {
		0x02, 0, 0, 0, 0, 0x02, 0x02, 0, 0, 0, 0, 0x01, 0x08, 0x00,                  /* Ethernet */
		0x45, 0, 0x00, 0x1c, 0, 1, 0x00, 0x00, 64, 17, 0, 0, 10, 0, 0, 1, 10, 0, 0, 2, /* IPv4 */
		0x04, 0xd2, 0x00, 0x50, 0x00, 0x08, 0, 0,                                      /* UDP */
	};
	memcpy(f, h, 42);
}

/* flow.mlir が作る flow_key (saddr・daddr・sport・dport は packet の byte の並びのまま、proto 17、_pad 0) */
static inline void flow_key_of(uint8_t k[16])
{
	static const uint8_t v[16] = {10, 0, 0, 1, 10, 0, 0, 2, 0x04, 0xd2, 0x00, 0x50, 17, 0, 0, 0};
	memcpy(k, v, 16);
}

#endif
