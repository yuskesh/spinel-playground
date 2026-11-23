# tools/spinel-mlir/bpf-mlir-commit.cmake -- the bpf-mlir commit a source
# directory holds (decision 0047).
#
#   include(bpf-mlir-commit.cmake)   with BPF_MLIR_SOURCE set: sets
#                                    SPINEL_BPF_MLIR_COMMIT, or stops
#   cmake -DBPF_MLIR_SOURCE=DIR -P tools/spinel-mlir/bpf-mlir-commit.cmake
#                                    prints "commit <40 hex>", or stops
#
# - SOURCE_VERSION present (a source release, or a git clone of a public
#   release, whose HEAD is never the source commit): its source_commit.
#   SOURCE_VERSION must be format=1 with one source_commit=<40 lowercase hex>,
#   with LF line ends (a carriage return is refused).
#   In a git checkout it must also be tracked and unchanged against HEAD, and
#   the work tree must have no tracked change against HEAD: a checkout cannot
#   claim a source commit it does not hold.
# - No SOURCE_VERSION, a git checkout: git rev-parse HEAD.
# - Neither: refused.
# tests/spinel-bpf-mlir/run.sh reads a directory the same way and checks that
# this script agrees with it on every planted control.

if(NOT DEFINED BPF_MLIR_SOURCE OR BPF_MLIR_SOURCE STREQUAL "")
  message(FATAL_ERROR "bpf-mlir-commit: set BPF_MLIR_SOURCE")
endif()

set(_bmc_src "${BPF_MLIR_SOURCE}")
set(_bmc_sv "${_bmc_src}/SOURCE_VERSION")
set(_bmc_git FALSE)
if(EXISTS "${_bmc_src}/.git")
  set(_bmc_git TRUE)
endif()

function(_bmc_git_ok out)
  execute_process(COMMAND git --no-optional-locks -C "${_bmc_src}" ${ARGN}
    RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e OUTPUT_STRIP_TRAILING_WHITESPACE)
  set(${out}_rc "${_r}" PARENT_SCOPE)
  set(${out} "${_o}" PARENT_SCOPE)
endfunction()

if(EXISTS "${_bmc_sv}")
  # file(STRINGS) drops carriage returns; the shell and Go readers refuse them
  file(READ "${_bmc_sv}" _bmc_raw HEX)
  if(_bmc_raw MATCHES "^(..)*0d")
    message(FATAL_ERROR "${_bmc_sv}: has a carriage return")
  endif()
  file(STRINGS "${_bmc_sv}" _bmc_format REGEX "^format=")
  file(STRINGS "${_bmc_sv}" _bmc_commit REGEX "^source_commit=")
  list(LENGTH _bmc_format _bmc_nf)
  list(LENGTH _bmc_commit _bmc_nc)
  if(NOT _bmc_nf EQUAL 1 OR NOT _bmc_format STREQUAL "format=1" OR NOT _bmc_nc EQUAL 1
     OR NOT _bmc_commit MATCHES "^source_commit=[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$")
    message(FATAL_ERROR "${_bmc_sv}: want format=1 and one source_commit=<40 hex>")
  endif()
  if(_bmc_git)
    _bmc_git_ok(_bmc_t ls-files --error-unmatch -- SOURCE_VERSION)
    if(NOT _bmc_t_rc EQUAL 0)
      message(FATAL_ERROR "${_bmc_src}: SOURCE_VERSION is not tracked in the checkout")
    endif()
    _bmc_git_ok(_bmc_d diff --quiet HEAD -- SOURCE_VERSION)
    if(NOT _bmc_d_rc EQUAL 0)
      message(FATAL_ERROR "${_bmc_src}: SOURCE_VERSION is changed against HEAD")
    endif()
    _bmc_git_ok(_bmc_s status --porcelain --untracked-files=no)
    if(NOT _bmc_s_rc EQUAL 0 OR NOT _bmc_s STREQUAL "")
      message(FATAL_ERROR "${_bmc_src}: the checkout has tracked changes against HEAD")
    endif()
  endif()
  string(REGEX REPLACE "^source_commit=" "" SPINEL_BPF_MLIR_COMMIT "${_bmc_commit}")
elseif(_bmc_git)
  _bmc_git_ok(_bmc_h rev-parse HEAD)
  if(NOT _bmc_h_rc EQUAL 0 OR NOT _bmc_h MATCHES "^[0-9a-f]+$")
    message(FATAL_ERROR "${_bmc_src}: git rev-parse HEAD failed")
  endif()
  set(SPINEL_BPF_MLIR_COMMIT "${_bmc_h}")
else()
  message(FATAL_ERROR "${_bmc_src} is neither a git checkout nor a bpf-mlir source release (no SOURCE_VERSION)")
endif()

if(CMAKE_SCRIPT_MODE_FILE)
  message("commit ${SPINEL_BPF_MLIR_COMMIT}")
endif()
