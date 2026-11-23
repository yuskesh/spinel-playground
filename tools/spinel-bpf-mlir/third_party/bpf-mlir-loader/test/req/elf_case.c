// test/corpus/elf_case.c — bml_req_from_elf の段と parse の判定を test/oracle の elf-oracle と同じ形で出す (E002)。
//   elf_case <file>...    1 file に 1 行: "<path>\t<段>\t<parse の判定>"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "util/gostr.h"
#include "req/from_elf.h"

static void hex(const char *s)
{
	for (const unsigned char *p = (const unsigned char *)s; *p; p++)
		printf("%02x", *p);
}

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		FILE *f = fopen(argv[i], "rb");
		if (!f) {
			fprintf(stderr, "elf_case: %s: %s\n", argv[i], strerror(errno));
			return 2;
		}
		struct bml_buf b = {0};
		char tmp[65536];
		size_t r;
		while ((r = fread(tmp, 1, sizeof(tmp), f)) > 0)
			bml_buf_add(&b, tmp, r);
		fclose(f);
		struct bml_requirements *req;
		struct bml_req_elf_error e;
		int rc = bml_req_from_elf(b.p ? b.p : "", b.len, &req, &e);
		printf("%s\t", argv[i]);
		if (rc == 0) {
			printf("ok\t{\"version\":%d}\n", req->version);
			bml_requirements_free(req);
		} else {
			switch (e.stage) {
			case BML_REQ_ELF_OPEN:
				/* 既知の差 (C が厳しい) の名指し: e_version の上位の byte — diff-elf の除外の表が見る */
				printf("open\t%s\n", e.msg && strcmp(e.msg, "mismatched ELF version") == 0 ? "c_strict:e_version" : "-");
				break;
			case BML_REQ_ELF_NO_SECTION: printf("no_section\t-\n"); break;
			case BML_REQ_ELF_DATA: printf("data\t-\n"); break;
			default:
				if (e.parse.rule[0] == 0) {
					printf("parse\t{\"untyped\":true}\n");
				} else {
					printf("parse\t{\"line\":%d,\"row\":\"%s\",\"rule\":\"%s\",\"msg_hex\":\"", e.parse.line, e.parse.row,
					       e.parse.rule);
					hex(e.parse.msg ? e.parse.msg : "");
					printf("\"}\n");
				}
			}
			bml_req_elf_error_free(&e);
		}
		bml_buf_free(&b);
	}
	return 0;
}
