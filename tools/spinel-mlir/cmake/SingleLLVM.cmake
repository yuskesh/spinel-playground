# Adapted from bpf-mlir 3fa1d98e CMakeLists.txt; see docs/provenance.md.
if(LLVM_LINK_LLVM_DYLIB AND TARGET LLVM)
  get_target_property(_single_llvm LLVM IMPORTED_LOCATION)
  if(NOT _single_llvm)
    get_target_property(_llvm_configs LLVM IMPORTED_CONFIGURATIONS)
    foreach(_cfg IN LISTS _llvm_configs)
      get_target_property(_single_llvm LLVM IMPORTED_LOCATION_${_cfg})
      if(_single_llvm)
        break()
      endif()
    endforeach()
  endif()
  if(NOT _single_llvm)
    message(FATAL_ERROR "shared LLVM requested but its path cannot be resolved")
  endif()
  foreach(_lib IN LISTS LLVM_AVAILABLE_LIBS)
    if(_lib MATCHES "^LLVM[A-Za-z0-9]+$" AND NOT _lib STREQUAL "LLVM" AND TARGET ${_lib})
      get_target_property(_kind ${_lib} TYPE)
      if(_kind STREQUAL "STATIC_LIBRARY")
        set_target_properties(${_lib} PROPERTIES
          IMPORTED_LOCATION "${_single_llvm}"
          IMPORTED_LOCATION_RELEASE "${_single_llvm}"
          IMPORTED_LOCATION_DEBUG "${_single_llvm}"
          IMPORTED_LOCATION_RELWITHDEBINFO "${_single_llvm}"
          IMPORTED_LOCATION_MINSIZEREL "${_single_llvm}"
          INTERFACE_LINK_LIBRARIES LLVM)
      endif()
    endif()
  endforeach()
endif()
