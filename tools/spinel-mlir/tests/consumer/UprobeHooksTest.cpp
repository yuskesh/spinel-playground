#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/GroupGUprobe.h"
#include "spinel/Conversion/GroupGProbe.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/IR/BuiltinOps.h"
#include <cstdlib>
using namespace mlir;
using namespace spinel::consumer;
static void require(bool yes,const char *name) {
  if (!yes) {llvm::errs()<<"FAIL "<<name<<"\n";std::exit(1);}
}
int main() {
  MLIRContext ctx;ctx.getOrLoadDialect<ebpf::EBPFDialect>();
  auto module=ModuleOp::create(UnknownLoc::get(&ctx));
  Consumer c(module);c.useIsolatedRegistryForTesting();c.probing=true;
  require(failed(checkedUserString(c,nullptr)),"missing check refuses");
  require(c.probeIssues.size()==1 && StringRef(c.probeIssues.back().message).contains("check hook is unavailable"),"missing check is named");
  UserStringArg metadata{2,nullptr};
  require(metadata.source==UserStringSource::Uprobe && metadata.field.empty() && metadata.offset==0 && !metadata.def,"legacy aggregate source defaults");
  require(failed(emitUserString(c,metadata,UnknownLoc::get(&ctx))),"missing emit refuses");
  require(c.probeIssues.size()==2 && StringRef(c.probeIssues.back().message).contains("emit hook is unavailable"),"missing emit is named");
  require(!c.blocking && module.getBody()->empty(),"probe refuses without IR or blocking");
  c.registry.uprobe=std::make_shared<UprobeHooks>();
  unsigned checks=0,emits=0;
  c.registry.uprobe->checkedUserString=[&](Consumer &,Operation *)->FailureOr<std::shared_ptr<const UserStringArg>> {
    ++checks;return std::shared_ptr<const UserStringArg>(std::make_shared<UserStringArg>(metadata));
  };
  Block values;auto value=values.addArgument(ebpf::UserStrType::get(&ctx),UnknownLoc::get(&ctx));
  auto loc=FileLineColLoc::get(&ctx,"uprobe.rb",12,7);
  c.registry.uprobe->emitUserString=[&](Consumer &,const UserStringArg &arg,Location at)->FailureOr<Value> {
    require(arg.n==2 && at==loc,"emit forwards checked number and caller location");++emits;return value;
  };
  auto checked=checkedUserString(c,nullptr);require(succeeded(checked) && (*checked)->n==2,"immutable metadata delegated");
  auto emitted=emitUserString(c,**checked,loc);require(succeeded(emitted) && *emitted==value,"typed value delegated");
  require(checks==1 && emits==1 && module.getBody()->empty(),"callbacks once and no reservation");
// Production routing: partial hooks stay loud; mismatched/unknown source
// cannot silently use another context. Probe failures retain no IR/state.
c.registry.uprobe->emitUserString = {};
require(failed(emitUserString(c,metadata,loc)),"partial emit hook refuses");
registerGroupGProbe(c.registry);
c.activeKind="tracepoint";
auto before=c.probeIssues.size();
require(failed(emitUserString(c,metadata,loc)),"uprobe source cannot emit in tracepoint");
require(c.probeIssues.size()==before+1 && StringRef(c.probeIssues.back().message).contains("source does not match"),"source mismatch is named");
metadata.source=UserStringSource::Tracepoint;
require(failed(emitUserString(c,metadata,loc)),"unbound tracepoint metadata refuses");
require(StringRef(c.probeIssues.back().message).contains("matching checked source"),"unbound declaration is named");
metadata.source=static_cast<UserStringSource>(99);
require(failed(emitUserString(c,metadata,loc)),"unknown source refuses");
require(!c.blocking && module.getBody()->empty(),"production probe route preserves IR and blocking");
module.erase();
llvm::outs()<<"uprobe hook contract ok\n";
}
