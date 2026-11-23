/* SPDX-License-Identifier: GPL-2.0
 *
 * spnl/amp_abi_imx95m7.h — 固定 AMP ABI (board プロファイル: FRDM-IMX95 Cortex-M7)
 *
 * P008 の中核: メモリ ABI を固定することで amp-m7 codegen が nm なしの固定定数を
 * 焼ける → 単一パス・firmware 非依存の blob になる (E360 の 2 パス build を廃止)。
 * 「firmware 非依存」は **同一 board プロファイル内** (この 1 ファイル) の主張。
 *
 * ABI は 2 面に分離する (P008 方針節):
 *   - blob-facing : blob に焼かれる定数。変更 = 全 blob 再 AOT ⇒ 最小・慎重に。
 *   - A55-facing  : firmware<->A55 の契約。blob には無関係 (blob はリングに触れない;
 *                   spnl_emit は helper 呼出しで、リングを知るのは firmware 側だけ)。
 *
 * 実測の裏付け:
 *   - ITCM/DTCM のアドレス・サイズ = Zephyr SoC dtsi (nxp_imx95_m7.dtsi): ITCM
 *     0x00000000 / 256 KiB、DTCM 0x20000000 / 256 KiB。board は flash=&itcm(code)・
 *     sram=&dtcm(data)。E360 実機と一致 (code @ ITCM 0xe60、.bss @ DTCM 0x20000d1c)。
 *   - helper 間接化 (H1 literal-jump) と ivar 直 RMW の実行可能性 = E361 (QEMU/an386)。
 *
 * !!! 重要な JIT 制約 (E351/E352/E361 実測) !!!
 *   micro-bpf host JIT の即値ロード (MoveImmediate) は **負の i32 (= bit31 が立つ値)
 *   を 8bit 超で拒否する**。ゆえに blob に焼かれるアドレス (AMP_HELPER_BASE および
 *   ivar 直 RMW の AMP_IVARS_BASE) は **bit31 = 0 でなければならない**。ITCM/DTCM
 *   (0x00xxxxxx / 0x20xxxxxx) は満たす。DDR carveout (0x8xxxxxxx) は満たさない ⇒
 *   IVARS を DDR に置くなら「直 RMW」を捨てて **helper 経由の ivar アクセス** に
 *   変える必要がある (codegen 変更、S1 スコープ)。この制約が下記 IVARS の TODO の芯。
 */
#ifndef SPNL_AMP_ABI_IMX95M7_H
#define SPNL_AMP_ABI_IMX95M7_H

#include <stdint.h>   /* struct amp_blob_staging (A55-facing) */

/*
 * ABI version。「ABI を守る任意の firmware で動く」を検証可能にするための gate。
 * manifest (E355) に blob の要求 version を載せ、loader が不一致を **loud に拒否**
 * する (silent breakage を作らない)。A55-facing 側はリング制御ブロックの
 * AMP_RING_VERSION (spnl/amp_ring.h) が同役。
 * bump するのは blob-facing の定数 (下記) を変えた時だけ。
 */
#define AMP_ABI_VERSION 1u

/* ======================================================================== *
 *  blob-facing ABI  (blob に焼かれる。bit31 = 0 必須。変更は ABI version bump) *
 * ======================================================================== */

/* --- i.MX95 M7 TCM 地図 (Zephyr nxp_imx95_m7.dtsi、実機一致) --- */
#define AMP_ITCM_BASE   0x00000000u   /* ITCM 基点 (Code region: 既定 map で実行可) */
#define AMP_ITCM_SIZE   0x00040000u   /* 256 KiB */
#define AMP_DTCM_BASE   0x20000000u   /* DTCM 基点 (M7-local view) */
#define AMP_DTCM_SIZE   0x00040000u   /* 256 KiB */

/* --- helper 入口テーブル (H1: 固定 literal-jump、JIT 無改変) ---
 * firmware は AMP_HELPER_BASE に 8B/slot のテーブルを置く。各 slot は
 *   [0]=`ldr.w pc,[pc]` (AMP_HELPER_LDR_PC_PC) / [1]=literal(実 helper addr|Thumb)。
 * literal は **起動時に firmware がデータ書込みでパッチ** (リンカ解決でない) ⇒
 * b.w レンジ・veneer・gc-sections drift (E360 の罠) が消える。codegen は
 * `call <id>` を AMP_HELPER_SLOT(id) の即値呼出しに焼く (JIT が Thumb bit を付す)。
 * 8B×32slot=256B を最初から予約し、helper 増分は slot 追加で吸収 (ABI 不変)。
 *
 * 配置: ITCM 最上位 256B。ITCM = Code region (実行可) かつ TCM (起動時パッチ可・
 * 非キャッシュ ⇒ I-cache 整合不要)、bit31=0 (JIT-bakeable)。
 * firmware は ITCM code 領域をこの 256B 手前で終える形で **予約** する必要がある
 * (E361 QEMU では sram0 を 8KiB 縮めて実証した機構の ITCM 版)。
 *
 * TODO(P008 S0 実機): 実 M7 の MPU/XN 下で ITCM のこの領域が **実行可能** か。
 *   Zephyr の memory-region flags は advisory (MPU を駆動しない) ので、MPU 設定
 *   (region entry) 側で exec を許す必要がある。QEMU スパイク (E361) は MPU=n で
 *   回避済 ⇒ ここは実 HW 確認 (監督者判断)。
 */
#define AMP_HELPER_SLOT_BYTES 8u
#define AMP_HELPER_SLOTS      32u
#define AMP_HELPER_SIZE       (AMP_HELPER_SLOT_BYTES * AMP_HELPER_SLOTS)  /* 256 B */
#define AMP_HELPER_BASE       0x0003FF00u  /* = ITCM top - 256B (0x40000 - 0x100) */

/* slot 内オフセット: [0]=命令, [1]=literal */
#define AMP_HELPER_SLOT(id)   (AMP_HELPER_BASE + ((unsigned)(id) - 1u) * AMP_HELPER_SLOT_BYTES)
/* `ldr.w pc, [pc]` (T2 LDR-literal, Rt=PC, imm12=0): slot+4 の literal を PC へ。
 * (E361 で arm-none-eabi-as から encoding 実測: bytes df f8 00 f0 = word 0xF000F8DF) */
#define AMP_HELPER_LDR_PC_PC  0xF000F8DFu
/* literal に書く値 = 実 helper アドレス | Thumb bit */
#define AMP_HELPER_LITERAL(addr) (((unsigned)(addr)) | 1u)

/* helper id 空間 (E360 firmware と一致: id 1=emit, id 2=ktime) */
#define AMP_HELPER_ID_EMIT    1u   /* spnl_emit -> ring publish (cache flush は helper 内) */
#define AMP_HELPER_ID_KTIME   2u   /* ktime_ns  -> uptime ns (PHC/gPTP は S5) */

/* --- ivar 置場 (@ivar の直 RMW。address は bytecode 即値) ---
 * codegen は `SPNL_AMP_IVARS_BASE = AMP_IVARS_BASE` で焼く (E352: MOV/LDDW 即値、
 * .data/.rodata relocation を経由しない ⇒ アドレスパラメタ化パッチ不要)。
 * loader は **slot install ごとに AMP_IVARS_SIZE をゼロ化** (boot 時だけだと hot
 * swap で前 probe の残骸を次 probe が読む。P008 S2/S4 前提)。
 *
 * 配置: DTCM 最上位 256B。bit31=0 (JIT-bakeable、上記 JIT 制約)。E360 は DTCM .bss
 * を使った (0x20000d1c)。firmware は DTCM の .bss/heap/stack をこの 256B 手前に収め、
 * この領域を **予約** する (E361 の sram0 縮小 = memory-region の DTCM 版)。
 *
 * !!! 未決定 (P008 S0 の決めどころ、silent に決めない) !!!
 *   ADR-016 は「A55 から ivar を mmap 読取可」を要件にする。DTCM は M7-local
 *   (0x20000000) で、A55 からは **TCM システムエイリアス** 経由でしか見えない (もし
 *   存在すれば)。決定木:
 *     (a) A55 が DTCM alias を読める  → 下の A55-facing AMP_IVARS_A55_ALIAS を確定し、
 *         DTCM 直 RMW のまま (現状の設計、JIT 制約も満たす)。← 第一候補
 *     (b) A55 が DTCM を一切見えない  → IVARS を DDR carveout に移すしかないが bit31 が
 *         立ち JIT 直 RMW 不可 ⇒ **ivar アクセスを helper 経由に変更** (codegen 変更、
 *         S1) するか、M7 が周期的に ivar を ring へ dump する。
 *   TODO(P008 S0 実機/RM): i.MX95 で A55 が M7 DTCM を見る alias の有無・アドレスを
 *     確定し、(a)/(b) を決める。決まるまで AMP_IVARS_A55_ALIAS は未定義のまま。
 */
#define AMP_IVARS_SIZE  0x00000100u    /* 256 B (>= 1 probe の @ivar 集合。checker が範囲検査) */
#define AMP_IVARS_BASE  0x2003FF00u    /* = DTCM top - 256B (0x20040000 - 0x100) */

/* ======================================================================== *
 *  A55-facing ABI  (firmware<->A55 の契約。blob には無関係)                    *
 * ======================================================================== */

/* 共有 DDR SPSC event ring の基点 (M7 producer / A55 mmap consumer)。
 * リング制御ブロック/レコード形式・version gate は spnl/amp_ring.h
 * (AMP_RING_MAGIC / AMP_RING_VERSION)。blob ABI から外したので、間借り
 * (0x88400000) → 専用 carveout への移動が blob の再 AOT を要求しない。
 *
 * 現状 v0: openamp shmem 間借り 0x88400000 (grant 0x88000000..0x88500000 内、
 * vrings から 4 MiB 離す。examples/amp_m7_firmware と一致)。
 * TODO(P007/frdm-imx95 側): 専用 carveout 0x8830_0000 + SM cfg/DT へ移す。
 */
#define AMP_RING_BASE   0x88400000u

/* blob staging (A55 -> M7)。A55 が共有メモリの **固定 staging 領域**に
 * `struct amp_blob_staging` ヘッダ + blob バイト列を書き、M7 loader が boot 時
 * (remoteproc restart) に読む。これで **firmware を probe より先に固定ビルド**でき、
 * blob は firmware 埋込でなく差し替え可能に (P008 S2 の肝、無停止 hot swap は S4)。
 *
 * 配置: openamp shmem grant (0x88000000..0x88500000) 内、event ring (0x88400000) の
 * 先。vrings/rsc_table は grant の低位 (rsc_table=0x88220000)、ring は 4 MiB in なので、
 * 0x8842_0000 は ring (数 KiB) と vrings 双方から離れた安全域。ring と同じく生の物理
 * アドレスで触る (DT ノード不要、amp_producer.c の ring と同流儀)。
 * TODO(frdm-imx95 側): ring と共に専用 carveout へ移す際は staging もまとめて移動。 */
#define AMP_STAGING_BASE   0x88420000u
#define AMP_STAGING_SIZE   0x1000u        /* 4 KiB: ヘッダ + blob (<= AMP_BLOB_MAX 512B) */
#define AMP_STAGING_MAGIC  0x42504D41u    /* 'A''M''P''B' (LE): amp blob staging */
#define AMP_BLOB_MAX       512u           /* 最大 blob サイズ (staging / exec slot) */

/* staging small header (A55 が書き、M7 loader が検証)。blob バイト列は直後に続く。 */
struct amp_blob_staging {
	uint32_t magic;        /* == AMP_STAGING_MAGIC (無効 = blob 未搭載) */
	uint32_t abi_version;  /* == AMP_ABI_VERSION (loader が不一致を loud 拒否) */
	uint32_t length;       /* blob バイト数 (<= AMP_BLOB_MAX) */
	uint32_t ivars_size;   /* manifest の amp_ivars_size (loader が IVARS をこの幅でゼロ化) */
	/* uint8_t blob[length] がここから続く */
};

/* cmd ring (A55 -> M7): 稼働中の runtime コマンド (hot swap の blob 配布 / 撤収)。
 * ADR-016 の user_ringbuf 写像 (A55 producer / M7 consumer)。M7 loader が tick ごとに
 * drain し、INSTALL は A/B の非活性 slot に置いて active を切替 (無停止差替え、E366)。
 * blob は record inline (<= AMP_BLOB_MAX)。配置は staging (0x88420000) の先。
 * decoupled verification: A55 は配布前に amp_check (E365) を通してから push、M7 loader は
 * magic/abi_version/length gate = 二重防御。 */
#define AMP_CMD_RING_BASE  0x88430000u
#define AMP_CMD_RING_SIZE  0x1000u         /* control + AMP_CMD_RING_CAP records */

/* Progress word (M7 -> A55 debug, E367): the runtime writes a step code here +
 * flushes at each hot-swap step, so the A55 can read (devmem2) where the M7 last
 * reached WITHOUT the M7 console (unreachable from the host). Observability, not a
 * data-plane contract. Step table = AMP_STEP_* below. */
#define AMP_PROGRESS_BASE  0x88431000u     /* shmem, just past the cmd ring */
enum amp_step {
	AMP_STEP_TICK        = 10,   /* amp_tick entry */
	AMP_STEP_POLL        = 20,   /* amp_m7_poll_cmd entry */
	AMP_STEP_CMD_MAGIC   = 25,   /* cmd ring magic OK */
	AMP_STEP_CMD_FOUND   = 30,   /* a command is pending */
	AMP_STEP_PRE_INSTALL = 40,   /* about to install_to_slot */
	AMP_STEP_PRE_WINDOW  = 45,   /* about to open the ITCM write-window (MPU off) */
	AMP_STEP_IN_WINDOW   = 50,   /* MPU disabled, inside the window */
	AMP_STEP_POST_IVARS  = 55,   /* IVARS zeroed */
	AMP_STEP_POST_MEMCPY = 60,   /* blob copied into the slot */
	AMP_STEP_POST_ICACHE = 65,   /* I-cache invalidated (if present) */
	AMP_STEP_POST_WINDOW = 70,   /* MPU restored, window closed */
	AMP_STEP_POST_FLIP   = 80,   /* active slot flipped */
	AMP_STEP_RUN         = 90,   /* about to run the active blob */
	AMP_STEP_RUN_DONE    = 95,   /* blob returned */
	AMP_STEP_TICK_DONE   = 100,  /* amp_tick exit */
};
/* Capability table (P010 U3): what THIS firmware build can attach to and which
 * context fields each attach point provides. The firmware writes it once at boot
 * and never again; the A55 installer reads it before staging a probe.
 *
 * Placed in shared memory rather than the resource table or an RPMsg query on
 * purpose (P010 D7): it must be readable without the remoteproc lifecycle and
 * without a live control plane, because "which firmware is actually running"
 * is exactly the question asked when those are in doubt. */
#define AMP_CAPABILITY_BASE 0x88432000u    /* shmem, just past the progress word */
#define AMP_CAPABILITY_SIZE 0x1000u        /* 4 KiB: header + attach entries */

#define AMP_CMD_RING_MAGIC 0x444D4341u     /* 'A''C''M''D' (LE) */
#define AMP_CMD_RING_CAP   2u

enum amp_cmd_type {
	AMP_CMD_NONE = 0,
	AMP_CMD_INSTALL = 1,   /* install blob[] into the inactive A/B slot, flip active */
	AMP_CMD_TEARDOWN = 2,  /* deactivate (stop emit) + zero IVARS (traceless removal) */
};

struct amp_cmd_rec {
	uint32_t type;         /* enum amp_cmd_type */
	uint32_t abi_version;  /* == AMP_ABI_VERSION (loader gate) */
	uint32_t length;       /* blob bytes (INSTALL; <= AMP_BLOB_MAX) */
	uint32_t ivars_size;   /* per-install IVARS zeroing width */
	uint8_t  blob[AMP_BLOB_MAX];
};

struct amp_cmd_ring {
	uint32_t magic;        /* AMP_CMD_RING_MAGIC */
	uint32_t version;
	uint32_t capacity;
	uint32_t rec_size;     /* sizeof(struct amp_cmd_rec) */
	volatile uint32_t prod;  /* A55 producer index */
	volatile uint32_t cons;  /* M7 consumer index */
	uint32_t _pad[2];
	/* struct amp_cmd_rec recs[capacity] follows immediately */
};

static inline struct amp_cmd_rec *amp_cmd_ring_recs(struct amp_cmd_ring *r) {
	return (struct amp_cmd_rec *)((char *)r + sizeof(struct amp_cmd_ring));
}

/* M7 inits the cmd ring at boot (fresh); the A55 syncs on the magic before pushing. */
static inline void amp_cmd_ring_init(struct amp_cmd_ring *r) {
	r->version = 1;
	r->capacity = AMP_CMD_RING_CAP;
	r->rec_size = (uint32_t)sizeof(struct amp_cmd_rec);
	r->prod = 0;
	r->cons = 0;
	r->_pad[0] = r->_pad[1] = 0;
	r->magic = AMP_CMD_RING_MAGIC;   /* publish last */
}

/* A55 producer: push one command (returns 1 on success, 0 if the ring is full). */
static inline int amp_cmd_ring_push(struct amp_cmd_ring *r, const struct amp_cmd_rec *rec) {
	if (r->magic != AMP_CMD_RING_MAGIC) return 0;
	uint32_t prod = r->prod, cons = r->cons;
	if (prod - cons >= r->capacity) return 0;   /* full */
	amp_cmd_ring_recs(r)[prod % r->capacity] = *rec;
	r->prod = prod + 1;                          /* publish */
	return 1;
}

/* DTCM ivar を A55 が読むための **システムバス エイリアス** (上の IVARS 決定木 (a))。
 * TODO(P008 S0): 実機/RM で確定するまで **意図的に未定義**。確定したら:
 *   #define AMP_IVARS_A55_ALIAS  0x????????u   (= A55 から見た AMP_IVARS_BASE)
 * 決定木 (b) を採る場合はこのマクロは不要 (IVARS は DDR/helper 経由になる)。
 */
/* #define AMP_IVARS_A55_ALIAS  0x00000000u */  /* TODO: 未確定 */

#endif /* SPNL_AMP_ABI_IMX95M7_H */
