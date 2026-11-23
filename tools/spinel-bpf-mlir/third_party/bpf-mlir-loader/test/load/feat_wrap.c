/* test/load/feat_wrap.c — 負の対照の wrap (E005): -Wl,--wrap=feat_supported で link した試験の道具だけで、libbpf の feature の判断を
 * 偽る (製品の library に hook を入れない)。BML_FAKE_MISSING="3,4" は libbpf の kern_feature_id の 3 と 4 を MISSING に — libbpf の
 * load の中の kernel_supports と guard の feat_supported の両方が同じ偽りを見る。 */
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

bool __real_feat_supported(void *cache, int feat_id);

bool __wrap_feat_supported(void *cache, int feat_id)
{
	const char *m = getenv("BML_FAKE_MISSING");
	if (m) {
		char buf[256];
		strncpy(buf, m, sizeof buf - 1);
		buf[sizeof buf - 1] = 0;
		for (char *t = strtok(buf, ","); t; t = strtok(NULL, ","))
			if (atoi(t) == feat_id)
				return false;
	}
	return __real_feat_supported(cache, feat_id);
}
