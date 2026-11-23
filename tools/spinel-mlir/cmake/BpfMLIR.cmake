# bpf-mlir is configured as an independent source root by build.sh.
# Spinel Extended: bpf-mlir is a user-local checkout here, not a submodule;
# -DBPF_MLIR_SOURCE names it (docs/toolchains/spinel-bpf-mlir-deps).
set(BPF_MLIR_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/third_party/bpf-mlir" CACHE PATH "the pinned bpf-mlir source: a checkout, or a source release with SOURCE_VERSION")
set(BPF_MLIR_BUILD "${CMAKE_CURRENT_BINARY_DIR}/bpf-mlir" CACHE PATH "Private pinned bpf-mlir build")
foreach(_entry EBPFDialect:Dialect/EBPF/libMLIREBPFDialect KernelABI:Dialect/BPFABI/libBpfMLIRKernelABI Schema:Target/EBPF/libBpfMLIREBPFSchema)
  string(REPLACE ":" ";" _parts "${_entry}")
  list(GET _parts 0 _name)
  list(GET _parts 1 _archive)
  set(_path "${BPF_MLIR_BUILD}/lib/${_archive}.a")
  if(NOT EXISTS "${_path}")
    message(FATAL_ERROR "private bpf-mlir archive missing: ${_path}; run build.sh")
  endif()
  add_library(Pinned${_name} STATIC IMPORTED)
  set_target_properties(Pinned${_name} PROPERTIES
    IMPORTED_LOCATION "${_path}"
    INTERFACE_INCLUDE_DIRECTORIES "${BPF_MLIR_SOURCE}/include;${BPF_MLIR_BUILD}/include")
endforeach()
set_target_properties(PinnedKernelABI PROPERTIES INTERFACE_LINK_LIBRARIES LLVMSupport)
set_target_properties(PinnedEBPFDialect PROPERTIES
  INTERFACE_LINK_LIBRARIES "MLIRIR;MLIRSupport;PinnedKernelABI")
set_target_properties(PinnedSchema PROPERTIES
  INTERFACE_LINK_LIBRARIES "LLVMSupport;PinnedKernelABI")
