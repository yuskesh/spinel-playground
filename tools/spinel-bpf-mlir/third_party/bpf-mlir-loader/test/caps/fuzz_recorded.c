// test/fuzz/fuzz_recorded.c — libFuzzer の harness: 記録した caps (caps.json) の読みと、受理した caps での照合 (E002)。
// requirements は全ての行の種類を持つ固定の文 (corpus の parse/accept_all_rows_v7 と同じ形) — 任意の答えの組で Check を走らせる。
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "req/check.h"
#include "caps/recorded.h"

static const char req_text[] =
	"ebpf-requirements 7\n"
	"schema\tsha256\t0000000000000000000000000000000000000000000000000000000000000000\n"
	"program\ta\tkprobe\t2\nprogram\tb\ttracing\t26\nprogram\tc\ttracing\t26\nprogram\td\tkprobe\t2\nprogram\te\txdp\t6\n"
	"helper\ta\tget_current_pid_tgid\t14\nhelper\tb\tget_func_arg\t183\n"
	"map\tprogs\tprog_array\t3\tu32\tu32\t2\t0\nmap\tm\thash\t1\tu32\trecord:r\t8\t0\n"
	"kfield\tb\ttask_struct\tpid\ti32\n"
	"attach\ta\tkprobe\tdo_sys_poll\narch\ta\tx86_64\nctxfield\ta\tpt_regs\tdx\t96\t8\nkprobearg\ta\t3\tu32\n"
	"attach\tb\ttrace_raw_tp\tsched_process_fork\narg\tb\t0\ttask_struct\narg\tb\t1\ttask_struct\n"
	"attach\tc\ttrace_fexit\tdo_sys_poll\nretsig\tc\t1\ti32\n"
	"attach\td\tuprobe\tprobe_target\narch\td\tx86_64\nctxfield\td\tpt_regs\tdi\t112\t8\n"
	"binary\td\tsha256\t5a57b4994db32696dfad6c0105aaceb52e6505e0374fd556ae3fbd37c1e2c35c\nuprobearg\td\t1\tu32\n"
	"attach\te\ttcx\tingress\n"
	"btf\tint\nbtf\tfunc_global\nbtf\tdecl_tag\nbtf\tfunc\n"
	"argtag\te\targ:nonnull\tmem\n"
	"tailslot\tprogs\t0\te\n";

static struct bml_requirements *req;

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	if (!req) {
		struct bml_parse_error pe;
		if (bml_req_parse(req_text, sizeof(req_text) - 1, &req, &pe))
			abort();
	}
	char *err = NULL;
	/* dir は存在しない path — uprobe の binary の読みは誤り (binary_unknown) の経路 */
	struct bml_recorded *r = bml_recorded_parse((const char *)data, size, "/nonexistent-bml-fuzz", &err);
	if (!r) {
		free(err);
		return 0;
	}
	struct bml_caps caps;
	bml_recorded_caps(r, &caps);
	struct bml_unmets u;
	char *cerr = NULL;
	if (bml_check(req, &caps, &u, &cerr) == 0) {
		for (size_t i = 0; i < u.n; i++) {
			char *s = bml_unmet_string(&u.u[i]);
			free(s);
			(void)bml_unmet_blocks_load(&u.u[i]);
		}
		bml_unmets_free(&u);
	} else {
		free(cerr);
	}
	bml_recorded_free(r);
	return 0;
}
