/* Public schema C ABI. Like Support.h, exposes only opaque handles and plain
 * C types, never C++ types. Function comments below define ownership. */
#ifndef SPINEL_MLIR_C_SPBPF_H
#define SPINEL_MLIR_C_SPBPF_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Schema version, matching JSON schema_version. */
#define SP_BPF_SCHEMA_VERSION 1u

/* Opaque handle to the canonical schema. */
typedef struct SpBpfSchema SpBpfSchema;

/* Parse JSON. The caller owns json; it is read/copied only during the call.
 * The caller owns a successful result and frees it with sp_bpf_schema_destroy.
 * Failure returns NULL and, if error_out is nonnull, writes a caller-owned
 * NUL-terminated error string to free with sp_bpf_string_destroy. Success
 * leaves error_out untouched. len is the byte length, independent of a NUL terminator. */
SpBpfSchema *sp_bpf_schema_parse_json(const char *json, size_t len,
                                      char **error_out);

/* Serialize canonical JSON: identical schemas produce identical bytes. Returns a caller-owned NUL-terminated string to free with sp_bpf_string_destroy, or NULL on failure. */
char *sp_bpf_schema_serialize_json(const SpBpfSchema *schema);

/* Free a schema; NULL is a no-op. */
void sp_bpf_schema_destroy(SpBpfSchema *schema);

/* Free a string returned by this ABI; NULL is a no-op. Never call free(3) directly: the allocator may differ. */
void sp_bpf_string_destroy(char *s);

#ifdef __cplusplus
}
#endif

#endif /* SPINEL_MLIR_C_SPBPF_H */
