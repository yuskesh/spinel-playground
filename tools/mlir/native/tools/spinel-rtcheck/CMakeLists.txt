# Allocation-proof CLI replacing frozen Python.
add_llvm_executable(spinel-rtcheck main.cpp)
llvm_update_compile_flags(spinel-rtcheck)
target_link_libraries(spinel-rtcheck PRIVATE SpinelMLIRRealtime)
