# Admission-only CLI generates no objects and links no MLIR; it owns argv/files/typedump spawning
# and successful four-face reading, while library code checks profiles/declarations/bodies.
# AbiCli.cpp replaces abi-check.py by compiling headers with clang and reading LLVM signatures on
# both sides, without adding MLIR.
add_llvm_executable(spinel-fs-check main.cpp AbiCli.cpp ExternCli.cpp)
llvm_update_compile_flags(spinel-fs-check)
# undef reads objects and needs LLVMObject through its independent gate target, still no MLIR.
target_link_libraries(spinel-fs-check PRIVATE
  SpinelMLIRFreestandingUndef
  SpinelMLIRFreestanding
  SpinelMLIRContract)
