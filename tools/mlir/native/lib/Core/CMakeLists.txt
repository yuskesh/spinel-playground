# Decision 0026 step 5: the subset refusal table, data only. The freestanding
# routes link it through SpinelMLIRScalar without linking the checker.
add_library(SpinelCoreSubsetRefusals STATIC SubsetRefusals.cpp)
target_include_directories(SpinelCoreSubsetRefusals PUBLIC ${CMAKE_SOURCE_DIR}/include)

# Decision 0041 stage 1: which calls are loops with a literal block. The one
# owner of that shape, read by the importer, the freestanding walk, the checker,
# the loop bounds and the lowering. It needs the contract model and no MLIR.
add_library(SpinelCoreBlockLoops STATIC BlockLoops.cpp)
target_link_libraries(SpinelCoreBlockLoops PUBLIC SpinelMLIRContract)

# Decision 0042 stage 4: the hosted prelude and the definitions a copy of a
# source gets. Data and text only; the freestanding emitter links it too.
add_library(SpinelCorePrelude STATIC Prelude.cpp)
target_include_directories(SpinelCorePrelude PUBLIC ${CMAKE_SOURCE_DIR}/include
  PRIVATE ${CMAKE_BINARY_DIR}/include)
target_link_libraries(SpinelCorePrelude PUBLIC LLVMSupport)

# Decision 0045: the buffer rewrite (BufferSpelling.cpp) parses with the
# vendored Prism, the library `make -C vendor/spinel deps` and the vendor
# build leave in vendor/spinel/build, as tools/contract links it. The
# kernel's source stamp covers it (tools/test/source-stamp.rb).
get_filename_component(SPINEL_VENDOR "${CMAKE_SOURCE_DIR}/../../../vendor/spinel" ABSOLUTE)
if(NOT EXISTS "${SPINEL_VENDOR}/build/libprism.a" OR
   NOT EXISTS "${SPINEL_VENDOR}/vendor/prism/include/prism.h")
  message(FATAL_ERROR "no vendored Prism at ${SPINEL_VENDOR} (build/libprism.a and "
                      "vendor/prism/include): run make -C vendor/spinel deps and "
                      "make -C vendor/spinel first (docs/building.md)")
endif()
add_library(SpinelVendorPrism STATIC IMPORTED)
set_target_properties(SpinelVendorPrism PROPERTIES
  IMPORTED_LOCATION "${SPINEL_VENDOR}/build/libprism.a"
  INTERFACE_INCLUDE_DIRECTORIES "${SPINEL_VENDOR}/vendor/prism/include")

add_library(SpinelCoreEligibility STATIC Eligibility.cpp Input.cpp BufferSpelling.cpp BorrowFacts.cpp
  LoopBounds.cpp Effects.cpp)
target_link_libraries(SpinelCoreEligibility PUBLIC SpinelMLIRContract SpinelCoreSubsetRefusals
  SpinelCoreBlockLoops SpinelCorePrelude PRIVATE SpinelVendorPrism)

# The contract boundary of decision 0007: the contract file, the owned
# snapshot, the resolved entry and the generated header.  It needs the
# contract reader (Input.cpp) because the entry is resolved against the
# analysed AST rather than against the file's text, but it does not need MLIR:
# a tool that only prints a header must not drag the emitter in behind it.
add_library(SpinelCoreBoundary STATIC Boundary.cpp)
target_link_libraries(SpinelCoreBoundary PUBLIC SpinelCoreEligibility)

# The Full adapter of decision 0007 task 4: contract in, C source out. It needs
# the boundary model and nothing else -- the adapter is generated text, and
# generating it must not drag the emitter in behind it.
add_library(SpinelCoreAdapter STATIC Adapter.cpp)
target_link_libraries(SpinelCoreAdapter PUBLIC SpinelCoreBoundary)

# The checked scalar kernel of decision 0007 task 2: contract in, object out.
# Report.cpp is decision 0010's build report; it runs after the object exists.
add_library(SpinelCoreKernel STATIC Kernel.cpp Report.cpp StackBudget.cpp)
# StackBudget.cpp reads back the IR the object was generated from, so this is
# the first thing here that parses LLVM IR from a file rather than building it.
target_link_libraries(SpinelCoreKernel
  PUBLIC SpinelCoreBoundary SpinelCoreEligibility SpinelMLIRScalar LLVMIRReader)

# The emission adapter is a separate target: the checker is used on its own by
# spinel-core-check, which must not pull MLIR in behind it.
add_library(SpinelCoreEmit STATIC Emit.cpp)
target_link_libraries(SpinelCoreEmit
  PUBLIC SpinelCoreEligibility SpinelMLIRScalar)
