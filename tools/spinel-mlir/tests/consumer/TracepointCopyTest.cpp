#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/GroupGProbe.h"
#include "spinel/Conversion/TracepointRecordAccess.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Parser/Parser.h"
#include <cstdlib>
#include <algorithm>
using namespace mlir;
using namespace spinel::consumer;
static void require(bool condition,const char *name) {
  if (!condition) { llvm::errs()<<"FAIL "<<name<<"\n";std::exit(1); }
}
int main(int argc,char **argv) {
  if(argc!=3) return 2;
  MLIRContext context;context.loadDialect<spinel::ir::SpinelFactsDialect,ebpf::EBPFDialect>();
  auto module=parseSourceFile<ModuleOp>(argv[1],&context);require(bool(module),"tp-array-unit-parse");
  Consumer c(*module);c.useIsolatedRegistryForTesting();registerGroupGProbe(c.registry);
  Operation *root=nullptr,*entry=nullptr;
  for(auto table:module->getOps<spinel::ir::TableOp>())
    if(text(table,"phase")=="pristine") root=c.nodes.lookup(table->getAttrOfType<IntegerAttr>("root_id").getInt());
  require(root,"tp-array-unit-pristine-root");
  for(auto n:c.array(c.ref(root,"statements"),"body")) c.selectedTop.push_back(n);
  for(auto n:c.selectedTop)
    if(text(n,"kind")=="CallNode"&&field(n,"strings","name")=="tracepoint"&&c.constant(c.ref(n,"receiver"))=="BPF") entry=n;
  require(entry,"tp-array-unit-declaration");
  auto result=c.dispatchRoot(entry);
  require(result.state==Disposition::Handled,"tp-array-root-declaration");
  c.programs.push_back(*result.value);
  auto schema=llvm::json::parse(c.json(true));require(bool(schema),"tp-array-schema-json");
  auto *core=schema->getAsObject()->getObject("core");require(core,"tp-array-schema-core");
  auto *programs=core->getArray("programs");require(programs&&programs->size()==1,"tp-array-schema-programs");
  auto *fields=programs->front().getAsObject()->getArray("fields");require(fields,"tp-array-schema-fields");
  unsigned seen=0;
  for(auto &value:*fields) {
    auto *f=value.getAsObject();auto name=f->getString("name");
    if(name&&(*name=="daddr"||*name=="daddr_v6")) {
      auto *type=f->getObject("type");require(type&&type->getString("kind")=="array"&&type->getString("elem")=="u8","tp-array-schema-shape");
      require(type->getInteger("n")==(*name=="daddr" ? 4 : 16),"tp-array-schema-length");++seen;
    }
  }
  require(seen==2,"tp-array-schema-array-fields");
  // Deliberate in-memory declaration controls; captured files remain unchanged.
  auto keyword=c.args(entry).back();Operation *arraySpec=nullptr;
  for(auto opt:c.array(keyword,"elements"))
    if(c.spelling(c.ref(opt,"key"),true)=="fields")
      for(auto assoc:c.array(c.ref(opt,"value"),"elements"))
        if(c.spelling(c.ref(assoc,"key"),true)=="daddr") arraySpec=c.ref(assoc,"value");
  require(arraySpec,"tp-array-boundary-fixture");
  auto inner=c.array(arraySpec,"elements")[1];auto pair=c.array(inner,"elements");
  auto elementNode=pair[0],numberNode=pair[1];
  std::vector<std::pair<Operation*,DictionaryAttr>> saved;
  for(auto n:{elementNode,numberNode}) for(auto target:{n,c.analyzed.lookup(c.id(n))})
    saved.emplace_back(target,target->getAttrDictionary());
  c.probing=true;
  auto perturb=[&](int64_t count,StringRef element) {
    c.blocking=false;
    for(auto target:{numberNode,c.analyzed.lookup(c.id(numberNode))}) {
      auto spelling=c.builder.getStringAttr(std::to_string(count));
      for(auto name:{"literal_text","literal_decimal","backend_decimal"})target->setAttr(name,spelling);
      NamedAttrList ints(target->getAttrOfType<DictionaryAttr>("integers"));ints.set("value",spelling);target->setAttr("integers",ints.getDictionary(&context));
    }
    for(auto target:{elementNode,c.analyzed.lookup(c.id(elementNode))}) {
      NamedAttrList strings(target->getAttrOfType<DictionaryAttr>("strings"));strings.set("value",c.builder.getStringAttr(element));target->setAttr("strings",strings.getDictionary(&context));
    }
    return c.dispatchRoot(entry).state;
  };
  require(perturb(1,"u8")==Disposition::Handled,"tp-array-boundary-one");
  require(perturb(64,"u8")==Disposition::Handled,"tp-array-boundary-sixty-four");
  require(perturb(4,"i8")==Disposition::Handled,"tp-array-signed-byte");
  require(perturb(0,"u8")==Disposition::Error&&c.probeIssues.back().code=="SB008","tp-array-zero-refused");
  require(perturb(65,"u8")==Disposition::Error&&c.probeIssues.back().code=="SB008","tp-array-sixty-five-refused");
  for(auto &[target,attrs]:saved)target->setAttrs(attrs);
  c.blocking=false;c.probeIssues.clear();
  require(c.dispatchRoot(entry).state==Disposition::Handled,"tp-array-restored-declaration");
  // Check only: these inputs are saved real producer facts; no body is lowered.
  auto rootName=c.spelling(c.args(entry).front(),true);
  for(auto n:c.selectedTop)
    if(text(n,"kind")=="DefNode"&&field(n,"strings","name")==rootName) c.activeDef=n;
  require(c.activeDef,"tp-copy-unit-active-definition");
  c.activeKind="tracepoint";c.probing=true;

  Operation *copy=nullptr;
  for(auto &[id,n]:c.nodes)
    if(n->getAttrOfType<IntegerAttr>("file_id").getInt()==0&&text(n,"kind")=="CallNode"&&field(n,"strings","name")=="copy") {
      auto args=c.args(n);if(args.size()==1&&c.spelling(args[0],true)=="daddr") {copy=n;break;}
    }
  require(copy,"tp-copy-unit-source");
  spinel::record::Layout layout;layout.name="Ev";
  spinel::record::FieldLayout member;member.name="daddr";member.type="u8";member.bits=8;member.count=4;
  size_t operations=0;module->walk([&](Operation *){++operations;});
  auto checked=checkTracepointRecordCopy(c,copy,layout,member,true);
  require(checked.state==Disposition::Handled&&!c.blocking&&c.probeIssues.empty(),"tp-copy-probe-check");
  auto data=std::static_pointer_cast<const TracepointRecordAccess>((*checked.value)->payload);
  require(data->field=="daddr"&&data->offset==36&&data->count==4&&data->element=="u8"&&data->definition==c.activeDef,"tp-copy-owned-metadata");
  auto issues=c.probeIssues.size();auto wrong=member;wrong.count=3;
  require(checkTracepointRecordCopy(c,copy,layout,wrong,true).state==Disposition::Error&&c.probeIssues.size()==issues+1&&c.probeIssues.back().code=="SB028","tp-copy-count-refusal");
  wrong=member;wrong.bits=32;
  require(checkTracepointRecordCopy(c,copy,layout,wrong,false).state==Disposition::Error&&StringRef(c.probeIssues.back().message).contains("not an 8-bit array"),"tp-copy-width-refusal");
  issues=c.probeIssues.size();
  require(checkTracepointRecordCopy(c,c.ref(copy,"receiver"),layout,member,true).state==Disposition::Declined&&c.probeIssues.size()==issues,"tp-copy-non-target-declined");
  auto handlers=c.registry.expressions;
  c.registry.expressions.erase(std::remove_if(c.registry.expressions.begin(),c.registry.expressions.end(),[](const auto &item){return item.first=="TracepointRecordAccess";}),c.registry.expressions.end());
  require(checkTracepointRecordCopy(c,copy,layout,member,true).state==Disposition::Error&&StringRef(c.probeIssues.back().message).contains("check handler is unavailable"),"tp-copy-missing-handler-is-named");
  c.registry.expressions=handlers;
  auto def=c.activeDef;c.activeDef=nullptr;
  require(checkTracepointRecordCopy(c,copy,layout,member,true).state==Disposition::Declined,"tp-copy-other-root-not-visible");c.activeDef=def;
  size_t after=0;module->walk([&](Operation *){++after;});require(operations==after&&c.locals.empty()&&c.borrows.empty(),"tp-copy-probe-no-state-or-ir");
  Block emitted;auto at=outputLoc(copy);
  auto record=ebpf::RecordType::get(&context,"Ev",24);
  auto destination=emitted.addArgument(ebpf::ReservationType::get(&context,record),at);
  c.contextValue=emitted.addArgument(ebpf::ContextType::get(&context,"tracepoint"),at);
  c.builder.setInsertionPointToEnd(&emitted);
  require(failed(emitTracepointRecordCopy(c,*checked.value,destination,"daddr",at))&&emitted.empty(),"tp-copy-probe-emission-forbidden");
  c.probing=false;c.blocking=false;
  require(succeeded(emitTracepointRecordCopy(c,*checked.value,destination,"daddr",at))&&emitted.getOperations().size()==1,"tp-copy-emission");
  require(emitted.front().getName().getStringRef()=="ebpf.tp.field.copy"&&emitted.front().getLoc()==at,"tp-copy-emission-kind-loc");
  auto modified=std::make_shared<TracepointRecordAccess>(*data);++modified->offset;
  auto expr=std::make_shared<ScalarExpr>(**checked.value);expr->payload=modified;
  require(failed(emitTracepointRecordCopy(c,expr,destination,"daddr",at))&&emitted.getOperations().size()==1,"tp-copy-metadata-mismatch-refusal");
  c.blocking=false;c.activeDef=nullptr;
  require(failed(emitTracepointRecordCopy(c,*checked.value,destination,"daddr",at))&&emitted.getOperations().size()==1,"tp-copy-emission-other-root-refusal");

  // The wrong-kind fixture has unknown type and no callee for both copy calls.
  // Kind/receiver proof must reject it before asking for callee evidence.
  auto other=parseSourceFile<ModuleOp>(argv[2],&context);require(bool(other),"tp-copy-kind-fixture");
  Consumer k(*other);k.useIsolatedRegistryForTesting();registerGroupGProbe(k.registry);
  Operation *otherRoot=nullptr,*otherEntry=nullptr,*otherCopy=nullptr;
  for(auto table:other->getOps<spinel::ir::TableOp>())
    if(text(table,"phase")=="pristine")otherRoot=k.nodes.lookup(table->getAttrOfType<IntegerAttr>("root_id").getInt());
  for(auto n:k.array(k.ref(otherRoot,"statements"),"body"))k.selectedTop.push_back(n);
  for(auto n:k.selectedTop)
    if(text(n,"kind")=="CallNode"&&field(n,"strings","name")=="kprobe"&&k.constant(k.ref(n,"receiver"))=="BPF")otherEntry=n;
  require(otherEntry&&k.dispatchRoot(otherEntry).state==Disposition::Handled,"tp-copy-kind-root");
  auto otherName=k.spelling(k.args(otherEntry).front(),true);
  for(auto n:k.selectedTop)if(text(n,"kind")=="DefNode"&&field(n,"strings","name")==otherName)k.activeDef=n;
  for(auto &[id,n]:k.nodes)if(n->getAttrOfType<IntegerAttr>("file_id").getInt()==0&&text(n,"kind")=="CallNode"&&field(n,"strings","name")=="copy"){otherCopy=n;break;}
  require(otherCopy&&k.evidence[k.id(otherCopy)].size()==1&&!k.evidence[k.id(otherCopy)].front()->getAttr("callee"),"tp-copy-kind-no-callee-evidence");
  k.activeKind="kprobe";k.probing=true;
  auto rejected=checkTracepointRecordCopy(k,otherCopy,layout,member,true);
  require(rejected.state==Disposition::Error&&k.probeIssues.size()==1&&k.probeIssues.back().code=="SB028"&&k.probeIssues.back().message=="the kprobe context has no `copy` — it reads `ctx.arg(n)` with n a declared parameter number (1..6) (P013)","tp-copy-kind-before-callee");
  return 0;
}
