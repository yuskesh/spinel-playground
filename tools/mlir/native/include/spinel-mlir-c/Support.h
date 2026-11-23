/* Public C ABI foundation. No MLIR/LLVM C++ types cross this boundary: use
 * opaque handles and plain C types. Structures begin with abi_version and
 * struct_size; fields may only be added. Function comments define string ownership. */
#ifndef SPINEL_MLIR_C_SUPPORT_H
#define SPINEL_MLIR_C_SUPPORT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SP_MLIR_ABI_VERSION 1u

/* Mapping of mlir::DiagnosticSeverity; these numeric ABI values must not change. */
typedef enum {
  SP_MLIR_SEVERITY_NOTE = 0,
  SP_MLIR_SEVERITY_WARNING = 1,
  SP_MLIR_SEVERITY_ERROR = 2,
  SP_MLIR_SEVERITY_REMARK = 3
} SpMlirSeverity;

/* Called once per diagnostic. message is callee-owned and valid only for the call; the caller must copy it to retain it. */
typedef void (*SpMlirDiagnosticCallback)(void *userdata, int severity,
                                         const char *message);

/* ABI version used to build this library. */
uint32_t sp_mlir_abi_version(void);

/* Linked LLVM/MLIR version string in static callee-owned storage; do not free. */
const char *sp_mlir_llvm_version(void);

#ifdef __cplusplus
}
#endif

#endif /* SPINEL_MLIR_C_SUPPORT_H */
