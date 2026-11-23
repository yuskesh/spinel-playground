#include "spinel/Conversion/Consumer.h"
#include "spinel/Import/Import.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "llvm/Support/raw_ostream.h"
#include <unistd.h>
#include <cstdlib>
using namespace mlir;
using namespace spinel;
using namespace spinel::consumer;
static void require(bool ok, StringRef name) {
  if(!ok){llvm::errs()<<"FAIL "<<name<<"\n";std::exit(1);}
}
static std::string capture(llvm::function_ref<void()> action) {
  int fds[2];require(pipe(fds)==0,"capture-pipe");
  int old=dup(2);require(old>=0&&dup2(fds[1],2)>=0,"capture-dup");close(fds[1]);
  action();llvm::errs().flush();require(dup2(old,2)>=0,"capture-restore");close(old);
  std::string result;char buffer[4096];ssize_t n;
  while((n=read(fds[0],buffer,sizeof(buffer)))>0)result.append(buffer,n);
  close(fds[0]);return result;
}
static OwningOpRef<ModuleOp> parse(MLIRContext &context,const char *path) {
  auto m=parseSourceFile<ModuleOp>(path,&context);require(bool(m),"parse");return m;
}
static std::vector<Operation*> calls(Consumer &c) {
  std::vector<Operation*> result;
  for(auto &[id,n]:c.nodes)
    if(text(n,"kind")=="CallNode" && field(n,"strings","name")=="ktime_ns" &&
       c.constant(c.ref(n,"receiver"))=="BPF" && n->getAttrOfType<IntegerAttr>("file_id").getInt()==0)
      result.push_back(n);
  llvm::sort(result,[&](auto *a,auto *b){return c.id(a)<c.id(b);});return result;
}
static bool sameLoc(Location a,Location b) {
  auto x=dyn_cast<FileLineColLoc>(a),y=dyn_cast<FileLineColLoc>(b);
  return x&&y&&x.getFilename()==y.getFilename()&&x.getLine()==y.getLine()&&x.getColumn()==y.getColumn();
}
static void check(MLIRContext &context,const char *facts,const char *oracle,unsigned count) {
  auto input=parse(context,facts);require(succeeded(verifyImport(*input)),"verify-facts");
  Consumer c(*input);c.useIsolatedRegistryForTesting(c.registry);
  auto nodes=calls(c);require(nodes.size()==count,"ktime-input-count");
  auto reference=parse(context,oracle);std::vector<ebpf::KtimeOp> wanted;
  reference->walk([&](ebpf::KtimeOp op){wanted.push_back(op);});
  require(wanted.size()==count,"ktime-oracle-count");
  auto output=ModuleOp::create(UnknownLoc::get(&context));c.builder.setInsertionPointToEnd(output.getBody());
  for(unsigned i=0;i<count;++i) {
    auto node=nodes[i];auto result=c.dispatchExpression("CallNode",node);
    require(result.state==Disposition::Handled,"ktime-handler");auto e=*result.value;
    auto iv=e->range.interval.finite();require(bool(iv),"ktime-range-finite");
    require(iv->lo.str()=="0"&&iv->hi.str()=="18446744073709551615"&&e->range.wide&&!e->range.isBool&&
            e->range.form==range::Form::Ktime&&e->reads.empty(),"ktime-range");
    auto ops=output.getBody()->getOperations().size();c.probing=true;
    auto speculative=c.dispatchExpression("CallNode",node);
    require(speculative.state==Disposition::Handled&&!c.emitScalar(*speculative.value)&&
            output.getBody()->getOperations().size()==ops&&!c.blocking&&c.probeIssues.empty(),"ktime-probe");
    c.probing=false;auto v=c.emitScalar(e);require(bool(v),"ktime-emit");
    auto op=v.getDefiningOp();require(op&&isa<ebpf::KtimeOp>(op)&&op->getNumOperands()==0&&
                                    op->getNumResults()==1&&v.getType().isInteger(64),"ktime-oracle-shape");
    require(sameLoc(op->getLoc(),wanted[i].getLoc()),"ktime-oracle-loc");
    auto u64=range::checkStoreValue(e->range,{"T",64,false,1},{c.id(node)},"value");
    require(bool(u64)&&!bool(*u64),"ktime-direct-u64");
    auto i64=range::checkStoreValue(e->range,{"T",64,true,1},{c.id(node)},"value");
    auto u32=range::checkStoreValue(e->range,{"T",32,false,1},{c.id(node)},"value");
    auto integer=range::checkIntegerUse(e->range,{c.id(node)});
    require(bool(i64)&&bool(*i64)&&(*i64)->code=="SB014"&&bool(u32)&&bool(*u32)&&
            (*u32)->code=="SB014"&&bool(integer)&&bool(*integer)&&(*integer)->code=="SB014","ktime-wide-refusal");
    auto one=range::literal(math::Integer::from(1),{c.id(node)});require(bool(one),"literal");
    auto add=range::transferBinary("+",e->range,one->value,{c.id(node)});
    auto mask=range::literal(math::Integer::from(65535),{c.id(node)});require(bool(mask),"mask");
    auto narrowed=range::transferBinary("&",e->range,mask->value,{c.id(node)});
    require(bool(add)&&bool(add->issue)&&add->issue->code=="SB014"&&bool(narrowed)&&!narrowed->issue&&
            !narrowed->value.wide,"ktime-arithmetic-narrow");
  }
  // A distinct BPF call stays outside this helper; do not consume another group.
  Operation *other=nullptr;
  for(auto &[id,n]:c.nodes)
    if(text(n,"kind")=="CallNode"&&field(n,"strings","name")=="xdp"&&
       c.constant(c.ref(n,"receiver"))=="BPF") {other=n;break;}
  require(other!=nullptr,"non-target-fixture");
  auto before=output.getBody()->getOperations().size();
  auto declined=c.dispatchExpression("CallNode",other);
  require(declined.state==Disposition::Declined&&!c.blocking&&
          output.getBody()->getOperations().size()==before,"ktime-declined");
  output.erase();

  // Mutate only copies of evidence/input. The saved fixtures remain untouched.
  for(unsigned mode=0;mode<5;++mode) {
    auto copy=parse(context,facts);Consumer bad(*copy);bad.useIsolatedRegistryForTesting(bad.registry);
    auto n=calls(bad).front();auto id=bad.id(n);auto ev=bad.evidence[id].front();
    if(mode==0)ev->setAttr("callee",StringAttr::get(&context,"Other.ktime_ns"));
    if(mode==1) {
      Operation *arguments=nullptr;
      for(auto &[key,candidate]:bad.nodes)
        if(text(candidate,"kind")=="ArgumentsNode"&&!bad.array(candidate,"arguments").empty()) {
          arguments=candidate;break;
        }
      require(arguments!=nullptr,"arity-fixture");
      auto argument=bad.array(arguments,"arguments").front();
      auto argsId=bad.id(arguments);
      for(auto target:{arguments,bad.analyzed.lookup(argsId)}) {
        NamedAttrList arrays(target->getAttrOfType<DictionaryAttr>("arrays"));
        arrays.set("arguments",bad.builder.getArrayAttr({bad.builder.getI64IntegerAttr(bad.id(argument))}));
        target->setAttr("arrays",arrays.getDictionary(&context));
      }
      for(auto target:{n,bad.analyzed.lookup(id)}) {
        NamedAttrList refs(target->getAttrOfType<DictionaryAttr>("refs"));
        refs.set("arguments",bad.builder.getI64IntegerAttr(argsId));
        target->setAttr("refs",refs.getDictionary(&context));
      }
    }
    if(mode==2)bad.evidence[id].clear();
    if(mode==3)bad.evidence[id].push_back(ev);
    if(mode==4)ev->setAttr("dispatch",StringAttr::get(&context,"indirect"));

    Dispatch<Expr> result;
    auto err=capture([&]{result=bad.dispatchExpression("CallNode",n);});

    require(result.state==Disposition::Error&&!err.empty()&&bad.printedRejections==1,"ktime-evidence-refusal");
    if(mode<=1) {
      std::string message=mode==0
        ? "`BPF.ktime_ns` resolves to \"Other.ktime_ns\" (with 0 arguments), not the library's BPF.ktime_ns"
        : "`BPF.ktime_ns` resolves to \"BPF.ktime_ns\" (with 1 arguments), not the library's BPF.ktime_ns";
      require(err==bad.renderDiagnostic(n,"rejected","SB011","ShadowedName",message)+"\n",
              "ktime-callee-arity-full-diagnostic");
    }

  }
}
int main(int argc,char **argv) {
  require(argc==3,"usage");MLIRContext context;
  context.loadDialect<ir::SpinelFactsDialect,ebpf::EBPFDialect,arith::ArithDialect>();
  check(context,argv[1],SPINEL_E033_REC_ORACLE,3);
  check(context,argv[2],SPINEL_E033_MC_ORACLE,1);
  llvm::outs()<<"PASS ktime helper: four oracle operations/locations, Probe, wide range, evidence\n";
}
