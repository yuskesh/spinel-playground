/* C ABI smoke check: include headers in a C translation unit and link them, catching leaked C++ types, missing extern C and stdint assumptions. With a schema JSON argument, parse/serialize/destroy through the schema ABI. SpBPF.h defines ownership. */
#include "spinel-mlir-c/SpBPF.h"
#include "spinel-mlir-c/Support.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int schemaRoundtrip(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    fprintf(stderr, "cannot open %s\n", path);
    return 2;
  }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *buf = (char *)malloc((size_t)n + 1);
  if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) {
    fprintf(stderr, "cannot read %s\n", path);
    fclose(f);
    free(buf);
    return 2;
  }
  buf[n] = 0;
  fclose(f);

  char *error = NULL;
  SpBpfSchema *schema = sp_bpf_schema_parse_json(buf, (size_t)n, &error);
  if (!schema) {
    printf("capi-schema-reject %s\n", error ? error : "(no message)");
    sp_bpf_string_destroy(error);
    free(buf);
    return 1;
  }

  char *once = sp_bpf_schema_serialize_json(schema);
  if (!once) {
    fprintf(stderr, "serialize returned NULL\n");
    sp_bpf_schema_destroy(schema);
    free(buf);
    return 1;
  }

  /* Parse canonical output again to check idempotence through C too. */
  SpBpfSchema *again =
      sp_bpf_schema_parse_json(once, strlen(once), &error);
  int idempotent = 0;
  if (again) {
    char *twice = sp_bpf_schema_serialize_json(again);
    idempotent = twice && strcmp(once, twice) == 0;
    sp_bpf_string_destroy(twice);
    sp_bpf_schema_destroy(again);
  } else {
    sp_bpf_string_destroy(error);
  }

  printf("capi-schema-ok version=%u bytes=%zu idempotent=%d\n",
         (unsigned)SP_BPF_SCHEMA_VERSION, strlen(once), idempotent);

  sp_bpf_string_destroy(once);
  sp_bpf_schema_destroy(schema);
  /* Exercise NULL-accepting destruction too. */
  sp_bpf_schema_destroy(NULL);
  sp_bpf_string_destroy(NULL);
  free(buf);
  return idempotent ? 0 : 1;
}

int main(int argc, char **argv) {
  printf("capi-ok abi=%u llvm=%s\n", (unsigned)sp_mlir_abi_version(),
         sp_mlir_llvm_version());
  if (argc == 2)
    return schemaRoundtrip(argv[1]);
  return 0;
}
