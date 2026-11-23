// Consumer-only malformed metadata controls, not new Go-oracle inputs.
#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/GroupGUprobe.h"
#include "mlir/Parser/Parser.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include <cstdio>
#include <cstdlib>
#include <unistd.h>
using namespace mlir;
using namespace spinel::consumer;
static void require(bool ok,const char *name){if(!ok){llvm::outs()<<"FAIL "<<name<<"\n";std::exit(1);}}
int main(int argc,char **argv) {
  require(argc==2,"fixture");MLIRContext context;
  context.loadDialect<spinel::ir::SpinelFactsDialect,ebpf::EBPFDialect,arith::ArithDialect>();
  for(int mode=0;mode<8;++mode) {
    auto module=parseSourceFile<ModuleOp>(argv[1],&context);require(bool(module),"fixed parse");OpBuilder b(&context);
    int64_t callId=-1;unsigned phases=0;
    for(auto table:module->getOps<spinel::ir::TableOp>()) {
      llvm::DenseMap<int64_t,Operation*> nodes;Operation *call=nullptr,*record=nullptr;
      for(auto n:table.getBody().front().getOps<spinel::ir::NodeOp>()) {
        nodes[n->getAttrOfType<IntegerAttr>("id").getInt()]=n;
        if(text(n,"kind")=="CallNode"&&field(n,"strings","name")=="output_argv")call=n;
        if(text(n,"kind")=="CallNode"&&field(n,"strings","name")=="record")record=n;
      }
      require(call&&record,"output and declaration");callId=call->getAttrOfType<IntegerAttr>("id").getInt();
      auto ref=[&](Operation *n,StringRef key){auto a=n->getAttrOfType<DictionaryAttr>("refs").getAs<IntegerAttr>(key);return a?nodes.lookup(a.getInt()):nullptr;};
      auto args=[&](Operation *n){return ref(n,"arguments")->getAttrOfType<DictionaryAttr>("arrays").getAs<ArrayAttr>("arguments");};
      auto setArgs=[&](Operation *n,ArrayRef<Attribute> values){auto list=ref(n,"arguments");NamedAttrList a(list->getAttrOfType<DictionaryAttr>("arrays"));a.set("arguments",b.getArrayAttr(values));list->setAttr("arrays",a.getDictionary(&context));};
      auto values=args(call);SmallVector<Attribute> changed(values.begin(),values.end());
      auto make=nodes.lookup(cast<IntegerAttr>(values[0]).getInt());auto made=args(make);auto status=nodes.lookup(cast<IntegerAttr>(made.getValue().back()).getInt());
      if(mode==0) {changed.pop_back();setArgs(call,changed);} // callee+arity, earlier callee only
      if(mode==1) {
        auto options=nodes.lookup(cast<IntegerAttr>(args(record).getValue().back()).getInt());auto elements=options->getAttrOfType<DictionaryAttr>("arrays").getAs<ArrayAttr>("elements");bool found=false;
        for(auto e:elements){auto assoc=nodes.lookup(cast<IntegerAttr>(e).getInt());auto key=ref(assoc,"key");if(field(key,"strings","value")!="status")continue;auto type=ref(assoc,"value");NamedAttrList a(type->getAttrOfType<DictionaryAttr>("strings"));a.set("value",b.getStringAttr("u64"));type->setAttr("strings",a.getDictionary(&context));found=true;}
        require(found,"status field mutation");
      }
      if(mode==2)for(auto key:{"literal_decimal","backend_decimal","literal_text"})status->setAttr(key,b.getStringAttr("1"));
      if(mode==3){changed[0]=status->getAttr("id");setArgs(call,changed);}
      ++phases;
    }
    require(phases==2,"paired phase changes");
    if(mode==0||mode==4)for(auto e:module->getOps<spinel::ir::EvidenceOp>())if(e->getAttrOfType<IntegerAttr>("node_id").getInt()==callId)e->setAttr("callee",b.getStringAttr("RingBuf#output_str"));
    Consumer c(*module);unsigned fallback=0;
    if(mode==5)c.registry.uprobe->emitUserStringArray={};
    if(mode==6||mode==7) {
      auto check=c.registry.uprobe->checkedUserStringArray;
      c.registry.uprobe->checkedUserStringArray=[check,mode](Consumer &c,Operation *n)->FailureOr<std::shared_ptr<const UserStringArg>> {
        auto p=check(c,n);if(failed(p))return failure();auto q=std::make_shared<UserStringArg>(**p);
        if(mode==6)q->valueKind=UserStringValueKind::String;else q->source=UserStringSource::Uprobe;
        return std::shared_ptr<const UserStringArg>(q);
      };
      auto string=c.registry.uprobe->emitUserString;
      c.registry.uprobe->emitUserString=[&fallback,string](Consumer &c,const UserStringArg &a,Location l){++fallback;return string(c,a,l);};
    }
    FILE *log=std::tmpfile();require(log!=nullptr,"diagnostic capture");llvm::errs().flush();int saved=dup(2);require(saved>=0&&dup2(fileno(log),2)>=0,"stderr redirect");
    auto result=c.run();llvm::errs().flush();dup2(saved,2);close(saved);std::rewind(log);std::string error;char buffer[512];size_t count;while((count=std::fread(buffer,1,sizeof(buffer),log)))error.append(buffer,count);std::fclose(log);
    require(failed(result)&&c.printedRejections==1,"one earlier named rejection");
    require(error.find(mode>=5?"rejected SB001":mode==0||mode==4?"rejected SB011":"rejected SB024")!=std::string::npos,"expected stage code");
    if(mode==0)require(error.find("five arguments")==std::string::npos,"callee wins over adjacent arity violation");
    if(mode==1)require(error.find("status member of output_argv")!=std::string::npos,"status type stage");
    if(mode==2)require(error.find("give the literal 0")!=std::string::npos,"literal zero stage");
    if(mode==3)require(error.find("RecordShape")!=std::string::npos,"record make stage");
    if(mode>=5)require(fallback==0&&(error.find("argv")!=std::string::npos||(mode==7&&error.find("matching checked source")!=std::string::npos)),"bad array hook metadata never falls back to scalar");
    llvm::outs()<<"argv-check-stage "<<mode<<" named rejection\n";
  }
}
