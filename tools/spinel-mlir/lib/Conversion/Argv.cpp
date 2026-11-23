#include "spinel/Conversion/Argv.h"
#include "spinel/Conversion/Consumer.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
namespace spinel::consumer {
mlir::LogicalResult emitArgvSlots(Consumer &c,mlir::Location loc,
                                const ArgvArrayEmitter &makeArray,
                                const ArgvSlotEmitter &emitSlot) {
  if(c.probing)return c.error(c.activeDef,"argv emission is unavailable during Probe");
  if(!makeArray||!emitSlot)return c.error(c.activeDef,"argv emission requires both checked callbacks");
  auto target=c.builder.saveInsertionPoint();
  if(!target.isSet()||(c.activeKind!="ksyscall"&&c.activeKind!="tracepoint"))
    return c.error(c.activeDef,"argv emission requires an active tracing insertion scope");
  OpBuilder::InsertionGuard insertion(c.builder);
  ScopeGuard scope(c);
  auto staged=std::make_unique<Block>();
  c.builder.setInsertionPointToStart(staged.get());
  auto array=makeArray(c,loc);
  if(failed(array))return failure();
  Operation *source=*array?array->getDefiningOp():nullptr;
  if(!*array||!isa<ebpf::UserStrArrayType>(array->getType())||!source||
     source->getBlock()!=staged.get()||source->getNumOperands()!=1||
     source->getOperand(0)!=c.contextValue||source->getName().getStringRef()!=
         (c.activeKind=="ksyscall"?"ebpf.ksyscall.arg":"ebpf.tp.field"))
    return c.error(c.activeDef,"argv emission requires one checked direct user_str_array source");
  SmallVector<Operation*,20> branches;
  for(int64_t k=0;k<20;++k) {
    OperationState read(loc,"ebpf.user.str_at");read.addOperands(*array);
    read.addTypes({ebpf::UserStrType::get(c.ctx),c.builder.getI64Type(),c.builder.getI1Type()});
    read.addAttribute("index",c.builder.getI64IntegerAttr(k));
    auto slot=c.builder.create(read);
    auto branch=ebpf::IfOp::create(c.builder,loc,TypeRange{},slot->getResult(2));
    branch->getRegion(0).push_back(new Block());branch->getRegion(1).push_back(new Block());
    branches.push_back(branch);
    c.builder.setInsertionPointToStart(&branch->getRegion(0).front());
    if(failed(emitSlot(c,slot->getResult(0),k,loc)))return failure();
    auto block=c.builder.getInsertionBlock();
    if(block!=&branch->getRegion(0).front()||
       (!block->empty()&&block->back().hasTrait<OpTrait::IsTerminator>()))
      return c.error(c.activeDef,"argv event callback must preserve its present insertion scope");
  }
  for(auto branch:llvm::reverse(branches)) {
    c.builder.setInsertionPointToEnd(&branch->getRegion(0).front());
    ebpf::IfYieldOp::create(c.builder,loc,ValueRange{});
    c.builder.setInsertionPointToStart(&branch->getRegion(1).front());
    ebpf::IfYieldOp::create(c.builder,loc,ValueRange{});
  }
  target.getBlock()->getOperations().splice(target.getPoint(),staged->getOperations());
  c.builder.restoreInsertionPoint(target);
  scope.commit();
  return success();
}
}
