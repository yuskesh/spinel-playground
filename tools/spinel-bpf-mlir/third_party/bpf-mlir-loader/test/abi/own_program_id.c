/* own_program_id — E067 の VM の runner が own の program の ID を実の fd の Info で固定する部品。
 * 製品に試験の API を足さず (program_fd の公開は socket_filter 限定のまま)、runner にだけ link する別の .o。release の libbml.a をそのまま測るため内部の入口を使う。 */
#include <errno.h>
#include <stdio.h>
#include <string.h>

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "abi/internal.h"
#include "run_own.h"

int own_program_id(int64_t obj, const char *prog, uint32_t *id, char *err, size_t en)
{
	int64_t e;
	struct abi_object *o = abi_object_acquire(obj, &e);
	if (!o) {
		snprintf(err, en, "object handle %lld is not open", (long long)obj);
		bml_result_free(e);
		return -1;
	}
	struct bpf_program *p;
	if ((e = abi_program(o, prog, (int64_t)strlen(prog), &p))) {
		snprintf(err, en, "program %s is not in the object", prog);
		bml_result_free(e);
		abi_object_release(o);
		return -1;
	}
	struct bpf_prog_info i;
	uint32_t l = sizeof i;
	memset(&i, 0, sizeof i);
	int rc = bpf_prog_get_info_by_fd(bpf_program__fd(p), &i, &l);
	if (rc != 0)
		snprintf(err, en, "program info: errno %d", errno);
	else
		*id = i.id;
	abi_object_release(o);
	return rc != 0 || i.id == 0 ? -1 : 0;
}
