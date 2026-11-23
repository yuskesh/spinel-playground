# Spinel frontend contract reader. Depends only on LLVMSupport, not MLIR or spbpf::Schema. Initially
# this library contained face parsers only; public readContract, sealing and the canonical CLI were
# added at the next checkpoint.
add_library(SpinelMLIRContract STATIC
  Model.cpp
  Reader.cpp)
target_include_directories(SpinelMLIRContract PUBLIC
  ${CMAKE_SOURCE_DIR}/include)
target_link_libraries(SpinelMLIRContract PUBLIC LLVMSupport)
