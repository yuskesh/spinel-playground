# tools/zephyr-full/host -- the Zephyr application that carries a hosted
# Spinel program and its runtime on Zephyr's POSIX layer (decision 0038).
#
# tools/zephyr-full/spinel-zephyr-full configures it; the variables it passes:
#   SP_VENDOR  the Spinel checkout whose runtime is compiled here
#   SP_OUT     the directory holding the program's generated app.c
#   SP_SHIM    decision 0032's header stand-ins (tools/npu/host/shim)
#   SP_ROOT    this repository, mapped out of __FILE__ in the image
#   SP_PEER    optional HOST:PORT, set as ZFULL_PEER for the program
#   SP_TRACE_IO  optional: print each read/fcntl/send/recv/connect/poll
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(spinel_zephyr_full)

# the runtime's members and the regexp engine, as the Spinel Makefile lists them
set(V ${SP_VENDOR})
file(STRINGS ${V}/Makefile MK REGEX "^(RT_MEMBERS|RE_SRC) *=")
set(SRCS)
foreach(l ${MK})
  string(REGEX REPLACE "^[A-Z_]+ *= *" "" w "${l}")
  separate_arguments(w)
  if(l MATCHES "^RT_MEMBERS")
    foreach(m ${w})
      list(APPEND SRCS ${V}/lib/${m}.c)
    endforeach()
  else()
    foreach(m ${w})
      list(APPEND SRCS ${V}/${m})
    endforeach()
  endif()
endforeach()
if(NOT SRCS)
  message(FATAL_ERROR "no RT_MEMBERS or RE_SRC in ${V}/Makefile")
endif()

# one thread, no signals, and fixed-size GC tables, as on the bare-metal lane
set(SP_DEFS SP_NO_SIGNALS SP_MAX_WORKERS=1 __wasi__ _GNU_SOURCE SP_ALLOC_STATS=1 SP_STR_SHAPE_MAX=1
  SP_GC_STACK_MAX=256 SP_GC_REMEMBERED_MAX=1024 SP_GC_MARK_STACK_MAX=256 SP_GC_PINNED_MAX=256 SP_DYN_SYMS_MAX=256)

# The runtime and the program are compiled inside Zephyr's build, so they see
# Zephyr's POSIX headers; force.h declares what those leave out, and the two
# shim directories come after them so that they only fill gaps.
add_library(spinel_rt STATIC ${SRCS} ${SP_OUT}/app.c)
target_link_libraries(spinel_rt PRIVATE zephyr_interface)
add_dependencies(spinel_rt zephyr_generated_headers)
target_compile_definitions(spinel_rt PRIVATE ${SP_DEFS})
target_include_directories(spinel_rt PRIVATE ${V}/lib ${V}/lib/regexp ${V}/lib/regexp/shim)
target_compile_options(spinel_rt PRIVATE -w -std=gnu2x -Os
  "SHELL:-include ${CMAKE_CURRENT_SOURCE_DIR}/force.h"
  "SHELL:-idirafter ${CMAKE_CURRENT_SOURCE_DIR}/shim" "SHELL:-idirafter ${SP_SHIM}"
  -ffile-prefix-map=${V}=spinel -ffile-prefix-map=${SP_OUT}=app -ffile-prefix-map=${SP_ROOT}=extended)
set_source_files_properties(${SP_OUT}/app.c PROPERTIES COMPILE_DEFINITIONS main=sp_app_main)
target_sources(app PRIVATE src/host.c)
target_compile_options(app PRIVATE -ffile-prefix-map=${SP_ROOT}=extended)
target_link_libraries(app PRIVATE spinel_rt)
if(SP_PEER)
  target_compile_definitions(app PRIVATE SP_PEER="${SP_PEER}")
endif()

# In user mode the program reaches only its memory domain: place the
# runtime's and the host's globals in sp_partition (src/host.c).
if(CONFIG_USERSPACE)
  set_property(TARGET zephyr_property_target APPEND PROPERTY COMPILE_OPTIONS
    "-l" $<TARGET_FILE_NAME:spinel_rt> "sp_partition"
    "-l" $<TARGET_FILE_NAME:app> "sp_partition")
endif()

if(SP_TRACE_IO)
  target_compile_definitions(app PRIVATE SP_TRACE_IO)
  zephyr_ld_options(-Wl,--wrap=read -Wl,--wrap=fcntl -Wl,--wrap=send -Wl,--wrap=recv -Wl,--wrap=connect -Wl,--wrap=poll)
endif()

# Zephyr's POSIX layer defines fdopen and fileno over its own descriptor
# table: its fdopen hands back the table entry as a FILE *, which picolibc's
# stdio (getline, fgets, fread, and fopen, which calls fdopen) cannot read.
# Link picolibc's own two from the SDK's libc.a, renamed, and send every call
# to them (src/host.c).
execute_process(COMMAND ${CMAKE_C_COMPILER} -mcpu=cortex-m33 -mthumb -specs=picolibc.specs -print-file-name=libc.a
  OUTPUT_VARIABLE PICOLIBC_A OUTPUT_STRIP_TRAILING_WHITESPACE)
if(NOT EXISTS ${PICOLIBC_A})
  message(FATAL_ERROR "the toolchain names no picolibc libc.a for cortex-m33: ${PICOLIBC_A}")
endif()
set(PS ${CMAKE_CURRENT_BINARY_DIR}/picolibc-stdio)
add_custom_command(OUTPUT ${PS}/fdopen.o ${PS}/fileno.o
  COMMAND ${CMAKE_COMMAND} -E make_directory ${PS}
  COMMAND ${CMAKE_COMMAND} -E chdir ${PS} ${CMAKE_AR} x ${PICOLIBC_A} libc_tinystdio_fdopen.c.o libc_tinystdio_fileno.c.o
  COMMAND ${CMAKE_OBJCOPY} --redefine-sym fdopen=sp_picolibc_fdopen ${PS}/libc_tinystdio_fdopen.c.o ${PS}/fdopen.o
  COMMAND ${CMAKE_OBJCOPY} --redefine-sym fileno=sp_picolibc_fileno ${PS}/libc_tinystdio_fileno.c.o ${PS}/fileno.o
  DEPENDS ${PICOLIBC_A})
target_sources(app PRIVATE ${PS}/fdopen.o ${PS}/fileno.o)
zephyr_ld_options(-Wl,--wrap=fdopen -Wl,--wrap=fileno)
