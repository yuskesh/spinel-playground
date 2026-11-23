#include "spinel-mlir-c/Support.h"

#include "llvm/Config/llvm-config.h"

extern "C" {

uint32_t sp_mlir_abi_version(void) { return SP_MLIR_ABI_VERSION; }

const char *sp_mlir_llvm_version(void) { return LLVM_VERSION_STRING; }

} // extern "C"
