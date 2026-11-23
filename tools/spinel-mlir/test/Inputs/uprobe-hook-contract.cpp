#include "spinel/Conversion/GroupGUprobe.h"
#include "spinel/Conversion/ConsumerExtensions.h"
#include <type_traits>
using namespace spinel::consumer;
static_assert(std::is_same_v<decltype(Registry{}.uprobe),
                             std::shared_ptr<UprobeHooks>>);
static_assert(std::is_same_v<decltype(UserStringArg{}.n), int64_t>);
static_assert(std::is_same_v<decltype(UprobeHooks{}.checkedUserString),
    std::function<mlir::FailureOr<std::shared_ptr<const UserStringArg>>(
        Consumer &, mlir::Operation *)>>);
static_assert(std::is_same_v<decltype(UprobeHooks{}.emitUserString),
    std::function<mlir::FailureOr<mlir::Value>(
        Consumer &, const UserStringArg &, mlir::Location)>>);
