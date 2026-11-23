#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
using namespace mlir;
using namespace spinel::consumer;
namespace spinel::consumer {void registerGroupG(Registry &);}
int main(int argc,char **argv) {
  if(argc<2||argc>5)return 2;
  std::string kind=argc>=3?argv[2]:"fexit";
  std::string target=argc>=4?argv[3]:(kind=="fexit"?"bpf_fentry_test1":"bpf_fentry_test6");
  MLIRContext ctx;ctx.loadDialect<spinel::ir::SpinelFactsDialect,ebpf::EBPFDialect,arith::ArithDialect>();
  auto input=parseSourceFile<ModuleOp>(argv[1],&ctx);if(!input)return 2;
  Consumer c(*input);c.useIsolatedRegistryForTesting();registerGroupG(c.registry);
  if(argc==5) {
    StringRef mode=argv[4];Operation *declaration=nullptr;
    for(auto &item:c.nodes) {
      auto n=item.second,call=c.ref(n,"value");
      if(text(n,"kind")=="ConstantWriteNode"&&c.constant(c.ref(call,"receiver"))=="BPF::SockMap")declaration=n;
    }
    if(!declaration)return 2;
    auto call=c.ref(declaration,"value");auto &e=c.evidence[c.id(call)];
    if(e.size()!=1)return 2;
    if(mode=="duplicate-evidence")e.push_back(e.front());
    else if(mode=="indirect")e.front()->setAttr("dispatch",StringAttr::get(&ctx,"dynamic"));
    else if(mode=="wrong-receiver") {
      auto recv=c.ref(call,"receiver");NamedAttrList attrs(recv->getAttrOfType<DictionaryAttr>("strings"));
      attrs.set("name",StringAttr::get(&ctx,"NotSockMap"));recv->setAttr("strings",attrs.getDictionary(&ctx));
    } else if(mode=="missing-exporter") {
      auto &exporters=c.registry.mapExporters;
      exporters.erase(std::remove_if(exporters.begin(),exporters.end(),[](const auto &x){return x.first=="sockmap";}),exporters.end());
    } else return 2;
    if(succeeded(c.run())||!c.blocking||c.printedRejections==0) {
      llvm::errs()<<"FAIL SockMap control "<<mode<<" must reject with SB diagnostic\n";return 1;
    }
    llvm::outs()<<"SockMap "<<mode<<" rejection GREEN\n";
    return mode=="missing-exporter"?1:0;
  }
  Operation *root=nullptr;
  for(auto t:input->getOps<spinel::ir::TableOp>())if(text(t,"phase")=="pristine")root=c.nodes.lookup(t->getAttrOfType<IntegerAttr>("root_id").getInt());
  if(!root||failed(c.select(root))){llvm::errs()<<"FAIL fexit registered in select\n";return 1;}
  for(auto n:c.selectedTop)if(c.dispatchDeclaration(n).state==Disposition::Error){llvm::errs()<<"FAIL kernel declarations\n";return 1;}
  Operation *entry=nullptr;for(auto n:c.selectedTop)if(field(n,"strings","name")==kind)entry=n;
  auto result=c.dispatchRoot(entry);
  if(result.state!=Disposition::Handled||!result.value||result.value->kind!=kind||result.value->attachTarget!=target||!result.value->finalizeBody||!result.value->payload){llvm::errs()<<"FAIL kernel root metadata\n";return 1;}
  llvm::outs()<<kind<<" root metadata GREEN\n";
}
