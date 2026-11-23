#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "mlir/IR/OperationSupport.h"
#include "spinel/Conversion/Consumer.h"
#include "llvm/Support/JSON.h"
using namespace mlir;using namespace spinel::consumer;
int main(int argc,char **argv) {
  bool strip=argc==3&&StringRef(argv[2])=="--strip-typing-probe";bool variant=argc==4&&StringRef(argv[2])=="--probe-variant";if(argc!=6&&!strip&&!variant)return 2;
  MLIRContext ctx;ctx.loadDialect<spinel::ir::SpinelFactsDialect,ebpf::EBPFDialect,arith::ArithDialect>();
  auto input=parseSourceFile<ModuleOp>(argv[1],&ctx);if(!input)return 2;
  auto publishFixture=[&]() {
    std::string printed;llvm::raw_string_ostream stream(printed);
    input->getOperation()->print(stream,OpPrintingFlags().enableDebugInfo());stream<<"\n";
    auto roundtrip=parseSourceString<ModuleOp>(printed,&ctx);
    if(!roundtrip||!OperationEquivalence::isEquivalentTo(input->getOperation(),roundtrip->getOperation(),OperationEquivalence::Flags::None)) {
      llvm::errs()<<"FAIL modified facts roundtrip including locations\n";return 1;
    }
    llvm::outs()<<printed;return 0;
  };
  if(strip) {input->getOperation()->removeAttr("spinel_facts.typing_probe");return publishFixture();}
  if(variant) {
    auto attr=input->getOperation()->getAttrOfType<DictionaryAttr>("spinel_facts.typing_probe");if(!attr)return 2;
    NamedAttrList attrs(attr);StringRef mode(argv[3]);std::string library;
    for(auto source:input->getOps<spinel::ir::SourceOp>())if(source->getAttrOfType<IntegerAttr>("file_id").getInt()!=0){library=text(source,"path").str();break;}
    for(auto arm:{"before_json","after_json"}) {
      auto json=llvm::json::parse(attr.getAs<StringAttr>(arm).getValue());if(!json)return 2;
      auto *obj=json->getAsObject();auto *types=obj?obj->getArray("types"):nullptr;if(!types||types->empty())return 2;
      if(mode=="unknown-file"||mode=="library-only") {
        if(mode=="library-only"&&library.empty())return 2;
        for(auto &row:*types)(*row.getAsObject())["file"]=mode=="unknown-file"?std::string("/not/in/SourceOps.rb"):library;
      } else if(mode=="zero-records")(*obj)["types"]=llvm::json::Array{};
      else if(mode=="missing-diagnostics")obj->erase("diagnostics");
      else if(mode=="bad-codegen")(*obj)["codegen"]=42;
      else if(mode=="bad-type")(*types->front().getAsObject())["type"]=42;
      else if(mode=="bad-optional")(*types->front().getAsObject())["singleton"]="false";
      else return 2;
      std::string encoded;llvm::raw_string_ostream stream(encoded);stream<<*json;
      attrs.set(arm,StringAttr::get(&ctx,encoded));
    }
    input->getOperation()->setAttr("spinel_facts.typing_probe",DictionaryAttr::get(&ctx,attrs));return publishFixture();
  }

  Consumer c(*input);Registry fresh;registerConsumerGroups(fresh);c.useIsolatedRegistryForTesting(std::move(fresh));
  Operation *root=nullptr;
  for(auto t:input->getOps<spinel::ir::TableOp>())if(text(t,"phase")=="pristine")root=c.nodes.lookup(t->getAttrOfType<IntegerAttr>("root_id").getInt());
  if(!root||failed(c.select(root))){llvm::errs()<<"FAIL kernel-path selection\n";return 1;}
  for(auto n:c.selectedTop)if(c.dispatchDeclaration(n).state==Disposition::Error){llvm::errs()<<"FAIL kernel-path declarations\n";return 1;}
  Operation *entry=nullptr,*def=nullptr,*expression=nullptr;
  for(auto n:c.selectedTop)if(text(n,"kind")=="CallNode"&&field(n,"strings","name")=="fentry")entry=n;
  auto p=c.dispatchRoot(entry);if(p.state!=Disposition::Handled){llvm::errs()<<"FAIL kernel root\n";return 1;}
  auto args=c.args(entry);for(auto n:c.selectedTop)if(text(n,"kind")=="DefNode"&&field(n,"strings","name")==c.spelling(args[0],true))def=n;
  for(auto &item:c.nodes)if(text(item.second,"kind")=="CallNode"&&field(item.second,"strings","name")==argv[2]&&item.second->getAttrOfType<IntegerAttr>("file_id").getInt()==0){expression=item.second;break;}
  if(!def||!expression)return 2;
  Block block;c.builder.setInsertionPointToStart(&block);auto base=block.addArgument(ebpf::KPtrType::get(&ctx,argv[3]),c.builder.getUnknownLoc());c.activeDef=def;c.activeKind="fentry";
  c.bindings[std::string("gkernel.ptr:")+argv[4]]={expression,nullptr,base};
  c.probing=true;auto checked=c.dispatchExpression("CallNode",expression);c.probing=false;
  if(checked.state!=Disposition::Handled||!checked.value||!block.empty()){llvm::errs()<<"FAIL kernel-path check-only\n";return 1;}
  auto value=c.emitScalar(*checked.value);if(!value){llvm::errs()<<"FAIL kernel-path emit\n";return 1;}
  bool found=false;for(auto &op:block)if(op.getName().getStringRef()==argv[5])found=true;
  if(!found){llvm::errs()<<"FAIL kernel-path emitted operation\n";return 1;}
  llvm::outs()<<"PASS kernel declaration / Probe no IR / checked emit\n";
}
