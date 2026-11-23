#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/GroupGUprobe.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include <cstdlib>
using namespace mlir;using namespace spinel::consumer;
static void need(bool yes,const char *message){if(!yes){llvm::errs()<<"FAIL "<<message<<"\n";std::exit(1);}}
int main(int argc,char **argv){
 need(argc==3,"facts and local source arguments");MLIRContext ctx;ctx.loadDialect<spinel::ir::SpinelFactsDialect,ebpf::EBPFDialect,arith::ArithDialect>();
 auto localize=[&](ModuleOp module){module->removeAttr("spinel_facts.typing_probe");for(auto source:module.getOps<spinel::ir::SourceOp>())if(source->getAttrOfType<IntegerAttr>("file_id").getInt()==0)source->setAttr("path",StringAttr::get(&ctx,argv[2]));};
 auto input=parseSourceFile<ModuleOp>(argv[1],&ctx);need(bool(input),"parse facts");localize(*input);Consumer c(*input);Registry registry;registerConsumerGroups(registry);c.useIsolatedRegistryForTesting(std::move(registry));Operation *root=nullptr;
 for(auto table:input->getOps<spinel::ir::TableOp>())if(text(table,"phase")=="pristine")root=c.nodes.lookup(table->getAttrOfType<IntegerAttr>("root_id").getInt());need(root&&succeeded(c.select(root)),"selection");
 for(auto n:c.selectedTop)need(c.dispatchDeclaration(n).state!=Disposition::Error,"declarations");
 Operation *entry=nullptr,*def=nullptr,*call=nullptr;for(auto n:c.selectedTop){if(text(n,"kind")=="CallNode"&&field(n,"strings","name")=="uprobe")entry=n;if(text(n,"kind")=="DefNode"&&field(n,"strings","name")=="on_put")def=n;}
 for(auto &row:c.nodes)if(row.second->getAttrOfType<IntegerAttr>("file_id").getInt()==0&&field(row.second,"strings","name")=="buf_arg")call=row.second;
 need(entry&&def&&call,"source nodes");auto program=c.dispatchRoot(entry);need(program.state==Disposition::Handled,"buffer declaration");
 auto argument=c.args(entry)[1];auto saved=argument->getAttr("strings");NamedAttrList strings(cast<DictionaryAttr>(saved));
 std::string invalidPath=std::string(argv[2]);invalidPath=invalidPath.substr(0,invalidPath.find_last_of('/'))+"/target//pfix";strings.set("content",StringAttr::get(&ctx,invalidPath));strings.set("unescaped",StringAttr::get(&ctx,invalidPath));argument->setAttr("strings",DictionaryAttr::get(&ctx,strings));c.probing=true;
 auto refused=c.dispatchRoot(entry);need(refused.state==Disposition::Error&&StringRef(c.probeIssues.back().message).contains("clean absolute path"),"repeated slash absolute target refuses before callee");argument->setAttr("strings",saved);c.probing=false;c.blocking=false;
c.activeDef=def;c.activeKind="uprobe";Block block;c.builder.setInsertionPointToStart(&block);c.contextValue=block.addArgument(ebpf::ContextType::get(&ctx,"uprobe"),c.builder.getUnknownLoc());c.probing=true;
 auto checked=checkedUserBuffer(c,call);need(succeeded(checked)&&(*checked)->n==1&&(*checked)->def==def&&block.empty(),"Probe checked metadata no IR");
 need(failed(emitUserBuffer(c,**checked,outputLoc(call)))&&block.empty()&&!c.blocking,"Probe emit refused without IR/blocking");c.probing=false;
 auto emitted=emitUserBuffer(c,**checked,outputLoc(call));need(succeeded(emitted)&&isa<ebpf::UserBufType>((*emitted).getType())&&block.getOperations().size()==1,"checked user buffer emit");
 auto savedContext=c.contextValue;c.contextValue=block.addArgument(ebpf::ContextType::get(&ctx,"kprobe"),c.builder.getUnknownLoc());
 need(failed(emitUserBuffer(c,**checked,outputLoc(call)))&&block.getOperations().size()==1,"wrong context type refuses");c.contextValue=savedContext;c.blocking=false;
 auto invalid=**checked;invalid.n=2;c.probing=false;need(failed(emitUserBuffer(c,invalid,outputLoc(call)))&&block.getOperations().size()==1,"wrong parameter metadata refuses");c.activeDef=nullptr;need(failed(emitUserBuffer(c,**checked,outputLoc(call)))&&block.getOperations().size()==1,"wrong root refuses");
 c.probing=true;c.registry.uprobe->emitUserBuffer={};need(failed(checkedUserBuffer(c,call))&&block.getOperations().size()==1,"partial hooks named refusal");
 auto full=parseSourceFile<ModuleOp>(argv[1],&ctx);need(bool(full),"parse full facts");localize(*full);Consumer complete(*full);Registry fresh;registerConsumerGroups(fresh);complete.useIsolatedRegistryForTesting(std::move(fresh));auto artifacts=complete.run();need(succeeded(artifacts),"full output_buf");unsigned reads=0;full->walk([&](ebpf::UserReadOp read){++reads;need(read->getParentOp()->getName().getStringRef()=="ebpf.ringbuf.if_reserved","direct present read");need(read->getBlock()==&read->getParentOp()->getRegion(0).front(),"present region");need(read.getLen().getDefiningOp()->getBlock()!=read->getBlock(),"length before reservation");need(read.getPtr().getDefiningOp()->getBlock()!=read->getBlock(),"buffer before reservation");auto loc=dyn_cast<FileLineColLoc>(read.getLoc());need(loc&&loc.getLine()==11&&loc.getColumn()==7,"real Ruby output location");bool record=false,count=false,status=false,submitted=false;for(auto &op:*read->getBlock()){if(op.getName().getStringRef()=="ebpf.ringbuf.store_record")record=true;if(&op==read.getOperation())need(record,"record before read");if(op.getName().getStringRef()=="ebpf.ringbuf.store_field"){if(op.getOperand(1)==read.getResult(1)){need(!status,"count before status");count=true;}if(op.getOperand(1)==read.getResult(0)){need(count,"count stored");status=true;}}if(op.getName().getStringRef()=="ebpf.ringbuf.submit"){need(status,"status before submit");submitted=true;}}need(submitted,"submit");});need(reads==1,"exactly one user.read");
 llvm::outs()<<"PASS user buffer Probe/root/hooks and reservation ordering\n";
}
