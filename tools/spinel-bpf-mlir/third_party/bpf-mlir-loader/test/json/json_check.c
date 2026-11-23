// test/corpus/json_check.c — file を bml_json_parse で読み、"<path>\tok" か "<path>\terror\t<文>" を出す (E002)。
//   json_check <file>...     rc: 0 は全て ok、1 は拒否が在る、2 は入出力の誤り
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "json/json.h"

int main(int argc, char **argv)
{
	int bad = 0;
	for (int i = 1; i < argc; i++) {
		FILE *f = fopen(argv[i], "rb");
		if (!f) {
			fprintf(stderr, "json_check: %s: %s\n", argv[i], strerror(errno));
			return 2;
		}
		struct bml_buf b = {0};
		char tmp[65536];
		size_t r;
		while ((r = fread(tmp, 1, sizeof(tmp), f)) > 0)
			bml_buf_add(&b, tmp, r);
		fclose(f);
		struct bml_json *j;
		char *err;
		if (bml_json_parse(b.p ? b.p : "", b.len, &j, &err) == 0) {
			printf("%s\tok\n", argv[i]);
			bml_json_free(j);
		} else {
			printf("%s\terror\t%s\n", argv[i], err);
			free(err);
			bad = 1;
		}
		bml_buf_free(&b);
	}
	return bad;
}
