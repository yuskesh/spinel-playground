# Spinel Extended: only the two drivers this slice needs. The predecessor file
# also builds spinel-mlirgen, spbpf-*, spinel-opt, spinel-contract-dump, the
# scalar drivers, spinel-fs-grad, spinel-tensor-import and spinel-rtcheck.
add_subdirectory(spinel-fs-check)
add_subdirectory(spinel-tensor-import)
add_subdirectory(spinel-fs-emit)
add_subdirectory(spinel-fs-codegen)
add_subdirectory(spinel-core-check)
add_subdirectory(spinel-core-emit)
add_subdirectory(spinel-core-boundary)
add_subdirectory(spinel-core-kernel)
add_subdirectory(spinel-core-stack)
add_subdirectory(spinel-core-adapter)
add_subdirectory(spinel-core-package)
# E169: the allocation-freedom prover's CLI (tools/realtime/spinel-rtcheck execs it).
add_subdirectory(spinel-rtcheck)
# E167: the freestanding gradient generator (Enzyme loaded in-process).
add_subdirectory(spinel-fs-grad)
# The SpBPF lane: .mlir + schema -> BPF ELF, and its opt driver.
add_subdirectory(spbpf-compile)
add_subdirectory(spbpf-opt)
# The C API smoke over the SpBPF schema (SpinelMLIRCAPI).
add_subdirectory(spinel-mlir-capi-smoke)
