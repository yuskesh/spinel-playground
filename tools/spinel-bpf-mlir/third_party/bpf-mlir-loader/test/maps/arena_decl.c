/* E061: arena-only declaration extension. No kernel, mmap, or load. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "maps/mapdecl.h"
#include "maps/arena.h"
#include "req/from_elf.h"
#include "../arena_fixture.h"

int main(int argc, char **argv)
{
	const char *arena = "{\"name\":\"ar\",\"kind\":\"arena\",\"key\":\"-\",\"value\":\"-\",\"max_entries\":4,\"flags\":1024,\"map_extra\":" E061_ARENA_ADDRESS_JSON "}";
	const char *array = "{\"name\":\"in\",\"kind\":\"array\",\"map_extra\":4294971392}";
	struct bml_map_decl d = {0}; char *err = NULL; int fails = 0;
	int rc = bml_map_decl_parse_one(arena, strlen(arena), &d, &err);
	int generic = rc && err && strstr(err,"unknown field \"map_extra\"");
	printf("generic-arena-extension: %s\n",generic?"GREEN":"FAIL");fails+=!generic;
	free(err);err=NULL;bml_map_decl_free(&d);
	rc = bml_arena_map_decl_parse_one(arena,strlen(arena),&d,&err);
	printf("arena-declaration: %s (%s)\n", rc ? "FAIL" : "GREEN", err ? err : "accepted");
	fails += rc != 0; free(err); err = NULL; bml_map_decl_free(&d);
	rc = bml_map_decl_parse_one(array, strlen(array), &d, &err);
	int old = rc && err && strstr(err, "unknown field \"map_extra\"");
	printf("ordinary-declaration: %s (%s)\n", old ? "GREEN" : "FAIL", err ? err : "unexpected acceptance");
	fails += !old; free(err); bml_map_decl_free(&d);
	if (argc == 2) {
		FILE *f = fopen(argv[1], "rb"); if (!f) return 2;
		if (fseek(f, 0, SEEK_END)) return 2;
		long n = ftell(f); if (n <= 0 || fseek(f, 0, SEEK_SET)) return 2;
		void *elf = malloc((size_t)n); if (!elf || fread(elf, 1, (size_t)n, f) != (size_t)n) return 2; fclose(f);
		struct bml_requirements *req = NULL; struct bml_req_elf_error re = {0};
		if (bml_req_from_elf(elf, (size_t)n, &req, &re)) return 2;
		err = NULL; if (bml_arena_map_decl_parse_one(arena, strlen(arena), &d, &err)) return 2;
		struct bml_map_decls ds = {.allow_undeclared=1, .has_maps=1, .maps=&d, .n_maps=1};
		for (int arm = 0; arm < 3; arm++) {
			if (arm == 1) d.map_extra += 4096;
			if (arm == 2) { d.map_extra -= 4096; d.has_map_extra = 0; }
			struct bml_map_problems ps;
			rc = bml_check_map_decls(req, elf, (size_t)n, &ds, &ps);
			if (!rc) rc=bml_check_arena_decls(req,elf,(size_t)n,&ds,1,&ps);
			int good = arm == 0 ? rc == 0 : rc == 1 && ps.n > 0;
			printf("arena-elf-%s: %s\n", arm == 0 ? "match" : arm == 1 ? "wrong-address" : "missing-address", good ? "GREEN" : "FAIL");
			fails += !good; bml_map_problems_free(&ps);
		}
		bml_map_decl_free(&d); bml_requirements_free(req); bml_req_elf_error_free(&re); free(elf);
	}
	return fails ? 1 : 0;
}
