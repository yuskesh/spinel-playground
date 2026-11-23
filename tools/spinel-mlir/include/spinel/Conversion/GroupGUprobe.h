#pragma once
#include "mlir/IR/Location.h"
#include "mlir/IR/Value.h"
#include "mlir/Support/LogicalResult.h"
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace mlir { class Operation; }
namespace spinel::consumer {
class Consumer;
struct Registry;
// Owned immutable checked metadata. The node is borrowed from input facts;
// no generated SSA is retained. Consumers hold shared_ptr<const UserStringArg>.
enum class UserStringSource { Uprobe, Tracepoint, Ksyscall };
enum class UserStringValueKind { String, Array };
struct UserStringArg {
  int64_t n = 0;
  mlir::Operation *node = nullptr;
  UserStringSource source = UserStringSource::Uprobe;
  std::string field;
  int64_t offset = 0;
  mlir::Operation *def = nullptr;
  UserStringValueKind valueKind = UserStringValueKind::String;
};
// Checked uprobe buffer metadata: input identity only, never generated SSA.
struct UserBufferArg { int64_t n=0; mlir::Operation *node=nullptr; mlir::Operation *def=nullptr; };
// Optional, run-local callbacks sharing the root handler's declaration state.
// Check never emits IR; emit uses the caller's location before reservation.
struct UprobeHooks {
  std::function<mlir::FailureOr<std::shared_ptr<const UserBufferArg>>(Consumer &,mlir::Operation *)> checkedUserBuffer;
  std::function<mlir::FailureOr<mlir::Value>(Consumer &,const UserBufferArg &,mlir::Location)> emitUserBuffer;
  std::function<mlir::FailureOr<std::shared_ptr<const UserStringArg>>(
      Consumer &, mlir::Operation *)> checkedUserString;
  std::function<mlir::FailureOr<mlir::Value>(
      Consumer &, const UserStringArg &, mlir::Location)> emitUserString;
  std::function<mlir::FailureOr<std::shared_ptr<const UserStringArg>>(
      Consumer &, mlir::Operation *)> checkedUserStringArray;
  std::function<mlir::FailureOr<mlir::Value>(
      Consumer &, const UserStringArg &, mlir::Location)> emitUserStringArray;
};
mlir::FailureOr<std::shared_ptr<const UserStringArg>>
checkedUserString(Consumer &, mlir::Operation *);
mlir::FailureOr<mlir::Value>
emitUserString(Consumer &, const UserStringArg &, mlir::Location);
mlir::FailureOr<std::shared_ptr<const UserStringArg>>
checkedUserStringArray(Consumer &, mlir::Operation *);
mlir::FailureOr<mlir::Value>
emitUserStringArray(Consumer &, const UserStringArg &, mlir::Location);
mlir::FailureOr<std::shared_ptr<const UserBufferArg>> checkedUserBuffer(Consumer &,mlir::Operation *);
mlir::FailureOr<mlir::Value> emitUserBuffer(Consumer &,const UserBufferArg &,mlir::Location);
void registerGroupGUprobe(Registry &);
} // namespace spinel::consumer
