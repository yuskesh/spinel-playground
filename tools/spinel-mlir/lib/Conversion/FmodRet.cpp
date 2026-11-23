#include "spinel/Conversion/FmodRet.h"
#include "spinel/Conversion/Consumer.h"
#include "spinel/Analysis/KernelTypes.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
namespace spinel::consumer {
namespace {
using DRoot=Dispatch<ProgramDecl>;
using DStmt=Dispatch<StatementResult>;
using DExpr=Dispatch<Expr>;
struct IntType {unsigned bits;bool sign;};
std::optional<IntType> intType(StringRef s) {
  if(s.size()<2||(s[0]!='i'&&s[0]!='u'))return {};
  unsigned n;if(s.drop_front().getAsInteger(10,n)||(n!=8&&n!=16&&n!=32&&n!=64))return {};
  return IntType{n,s[0]=='i'};
}
void writeInt(llvm::json::OStream &o,IntType t) {
  o.object([&]{o.attribute("kind","int");o.attribute("bits",t.bits);o.attribute("signed",t.sign);o.attribute("endianness","little");o.attribute("alignment",t.bits/8);});
}
struct FmodProgram:Payload {
  std::string target,param;
  int64_t nargs=-1;
  std::map<int64_t,std::string> args;
  Operation *def=nullptr;
};
struct Read:Payload {IntType type;int64_t index;};
struct Fmod {
  std::shared_ptr<const FmodProgram> current;
  Operation *running=nullptr,*last=nullptr;
  Expr lastValue;
  std::optional<int64_t> guardValue;
  bool guarded=false;
  Value fired;
  bool isReturn(Consumer &c,Operation *n) {
    return text(n,"kind")=="CallNode"&&field(n,"strings","name")=="fmod_return"&&c.constant(c.ref(n,"receiver"))=="BPF";
  }
  LogicalResult issue(Consumer &c,Operation *n,StringRef code,StringRef label,const std::string &m,bool path=true) {
    return c.diagnostic(n,code,label,m,path);
  }
  DRoot root(Consumer &c,Operation *n) {
    const std::string shape="`BPF.fmod_ret :name, \"kernel_function\", nargs: N, args: {0 => :i32}`";
    auto bad=[&](const std::string &m,StringRef code="SB008",StringRef label="ProgramShape") {
      (void)issue(c,n,code,label,m,false);return DRoot::error();
    };
    auto as=c.args(n);
    if(as.size()!=3||text(as[0],"kind")!="SymbolNode"||text(as[1],"kind")!="StringNode"||c.spelling(as[1],false).empty()||text(as[2],"kind")!="KeywordHashNode")return bad("a fmod_ret program is declared as "+shape+" — a Symbol, a non-empty String literal and `nargs:` (E144)");
    auto d=std::make_shared<FmodProgram>();d->target=c.spelling(as[1],false).str();Operation *hv=nullptr;
    for(auto e:c.array(as[2],"elements")) {
      auto k=c.ref(e,"key"),v=c.ref(e,"value");
      if(text(e,"kind")!="AssocNode"||text(k,"kind")!="SymbolNode"||!v)return bad("the options of "+shape+" are `nargs:` and `args:` (E144)");
      auto key=c.spelling(k,true);
      if(key=="nargs") {
        if(text(v,"kind")!="IntegerNode")return bad("`nargs:` of "+shape+" is the target function's argument count, an Integer literal 0..12, given once (E144)");
        auto count=c.integer(v);if(failed(count))return DRoot::error();
        if(*count<0||*count>12||d->nargs>=0)return bad("`nargs:` of "+shape+" is the target function's argument count, an Integer literal 0..12, given once (E144)");
        d->nargs=*count;
      } else if(key=="args") {
        if(hv)return bad("`args:` of "+shape+" is given once (E144)");hv=v;
      } else return bad("the options of "+shape+" are `nargs:` and `args:` — the return type is i32 (E144)");
    }
    if(d->nargs<0)return bad(shape+" needs `nargs:` — the target function's argument count (E144)");
    auto badArg=[&](const std::string &m){return bad(m,"SB033","KernelTypeShape");};
    if(hv) {
      auto elements=c.array(hv,"elements");
      if(text(hv,"kind")!="HashNode"||elements.empty())return badArg("`args:` of "+shape+" is a non-empty Hash literal of argument index => integer type (E144)");
      for(auto e:elements) {
        auto k=c.ref(e,"key"),v=c.ref(e,"value");
        if(text(e,"kind")!="AssocNode"||text(k,"kind")!="IntegerNode"||!v)return badArg("each fmod_ret argument is `i => :i32` with i an Integer literal (E144)");
        auto i=c.integer(k);if(failed(i))return DRoot::error();
        if(*i<0||*i>=d->nargs||d->args.count(*i))return badArg("a fmod_ret argument index is 0..nargs−1 ("+std::to_string(d->nargs-1)+") and appears once (E144)");
        if(text(v,"kind")!="SymbolNode")return badArg("argument "+std::to_string(*i)+": a fmod_ret argument is an integer type Symbol (:i8 … :u64) — bpf-mlir's fmod_ret reads integer arguments only (IntArgs — E400) (E144)");
        auto type=c.spelling(v,true).str();if(!intType(type))return badArg("argument "+std::to_string(*i)+": an integer argument's type is one of :i8 … :i64 / :u8 … :u64 (E144)");d->args[*i]=type;
      }
    }
    CalleePolicy policy;policy.expected="BPF.fmod_ret";if(failed(c.known(n,policy)))return DRoot::error();
    auto name=c.spelling(as[0],true);
    for(auto def:c.selectedTop)if(text(def,"kind")=="DefNode"&&field(def,"strings","name")==name)d->def=def;
    if(!d->def){(void)c.error(n,"root target must be a declared method");return DRoot::error();}
    auto params=c.array(c.ref(d->def,"parameters"),"requireds");
    if(params.size()!=1){(void)c.error(d->def,"root requires one context parameter");return DRoot::error();}
    d->param=field(params[0],"strings","name").str();current=d;
    Operation *wrong=nullptr;std::string cn;
    llvm::DenseSet<Operation*> seen;
    std::function<void(Operation*)> scan=[&](Operation *x) {
      if(!x||!seen.insert(x).second)return;
      auto constant=c.constant(x);
      if(StringRef(constant).starts_with("BPF::")&&constant!="BPF::FMOD_CALL") {
        auto tail=StringRef(constant).drop_front(5);
        if((tail.starts_with("XDP_")||tail.starts_with("TC_")||tail.starts_with("CG_")||tail.starts_with("SF_")||tail.starts_with("NF_")||tail.starts_with("FLOW_")||tail.starts_with("SK_"))&&(!wrong||c.id(x)<c.id(wrong))){wrong=x;cn=constant;}
      }
      if(auto refs=x->getAttrOfType<DictionaryAttr>("refs"))for(auto item:refs)scan(c.nodes.lookup(cast<IntegerAttr>(item.getValue()).getInt()));
      if(auto arrays=x->getAttrOfType<DictionaryAttr>("arrays"))for(auto item:arrays)for(auto id:cast<ArrayAttr>(item.getValue()))scan(c.nodes.lookup(cast<IntegerAttr>(id).getInt()));
    };scan(d->def);
    if(wrong) {
      auto v=StringRef(cn);std::string label=v.starts_with("BPF::XDP_")?"an XDP":v.starts_with("BPF::TC_")?"a sched_cls (tcx)":v.starts_with("BPF::CG_")?"a cgroup_skb":v.starts_with("BPF::SF_")?"a socket_filter":v.starts_with("BPF::NF_")?"a netfilter":v.starts_with("BPF::SK_")?"an sk_lookup":"a flow_dissector";
      auto saved=c.programName;c.programName=name.str();
      (void)issue(c,wrong,"SB028","TracingKind",cn+" is "+label+" verdict — a fmod_ret program returns BPF::FMOD_CALL or BPF.fmod_return(e) (e provably non-zero) (P026)");c.programName=saved;return DRoot::error();
    }
    ProgramDecl p;p.kind="fmod_ret";p.attachTarget=d->target;p.analysisContext="obj_BPF::FmodRetCtx";p.payload=d;
    p.finalizeBody=[this](Consumer &c){return finish(c);};return DRoot::handled(std::move(p));
  }
  LogicalResult range(Consumer &c,const Expr &e,Operation *n) {
    if(e->range.isBool)return issue(c,n,"SB001","UnsupportedConstruct","`BPF.fmod_return(e)` takes an Integer, not a bool (E144)");
    auto check=range::checkIntegerUse(e->range,{c.id(n),0});
    if(!check)return c.rangeFailure(check.takeError(),n);
    if(*check)return c.issue(**check);
    auto iv=e->range.interval.finite();if(!iv)return c.rangeFailure(iv.takeError(),n);
    auto zero=math::Integer::from(0);
    if(iv->lo<=zero&&zero<=iv->hi)return issue(c,n,"SB014","SemanticGap","the value of `BPF.fmod_return(e)` may be 0 (its range is "+iv->str()+") — 0 means \"call the original function\", so a replaced return value must be provably non-zero; return BPF::FMOD_CALL for that path instead (E144)");
    if(iv->lo<math::Integer::from(INT32_MIN)||math::Integer::from(INT32_MAX)<iv->hi)return issue(c,n,"SB014","SemanticGap","the value of `BPF.fmod_return(e)` may not fit the i32 return value (its range is "+iv->str()+") — narrow it first (E144)");
    return success();
  }
  FailureOr<Expr> value(Consumer &c,Operation *call,bool guard) {
    CalleePolicy policy;policy.expected="BPF.fmod_return";if(failed(c.known(call,policy)))return failure();
    auto as=c.args(call);if(as.size()!=1){(void)issue(c,call,"SB011","ShadowedName","`BPF.fmod_return` resolves to \"BPF.fmod_return\" (with "+std::to_string(as.size())+" arguments), not the library's BPF.fmod_return(e)");return failure();}
    auto n=as[0];
    if((guard||guarded)&&text(n,"kind")!="IntegerNode") {
      (void)issue(c,n,"SB006","NonConstant",guard?"a guard `return BPF.fmod_return(e) if cond` takes an integer literal e — the terminal arith.select of bpf-mlir's ebpf.return chooses between program-level values (E144)":"with a guard `return … if cond`, the last `BPF.fmod_return(e)` takes an integer literal — the terminal arith.select of bpf-mlir's ebpf.return chooses between program-level values (E144)");return failure();
    }
    auto e=c.scalar(n);if(failed(e)||failed(range(c,*e,n)))return failure();return *e;
  }
  DExpr expression(Consumer &c,Operation *n) {
    if(!current||current->def!=c.activeDef||text(n,"kind")!="CallNode")return DExpr::declined();
    auto recv=c.ref(n,"receiver");
    if(text(recv,"kind")!="LocalVariableReadNode"||field(recv,"strings","name")!=current->param)return DExpr::declined();
    if(field(n,"strings","name")!="arg")return DExpr::declined();
    auto as=c.args(n);if(as.size()!=1||text(as[0],"kind")!="IntegerNode")return (void)c.error(n,"fmod_ret ctx.arg requires one literal index"),DExpr::error();
    auto i=c.integer(as[0]);if(failed(i))return DExpr::error();
    auto found=current->args.find(*i);if(found==current->args.end())return (void)issue(c,as[0],"SB033","KernelTypeShape","argument "+std::to_string(*i)+" is not declared in `BPF.fmod_ret … args:` (E144)"),DExpr::error();
    auto type=*intType(found->second);CalleePolicy policy;policy.expected="FmodRetCtx#arg";if(failed(c.known(n,policy)))return DExpr::error();
    auto rv=tracing::integerRange(type.bits,type.sign,tracing::IntegerSource::Argument);if(!rv)return (void)c.rangeFailure(rv.takeError(),n),DExpr::error();
    auto payload=std::make_shared<Read>();payload->type=type;payload->index=*i;
    auto e=std::make_shared<ScalarExpr>();e->node=n;e->kind="fmod.arg";e->range=*rv;e->payload=payload;return DExpr::handled(e);
  }
  DStmt statement(Consumer &c,ArrayRef<Operation*> list,size_t index,unsigned depth) {
    if(c.activeKind!="fmod_ret"||!current||current->def!=c.activeDef)return DStmt::declined();
    if(running!=c.activeDef){running=c.activeDef;last=nullptr;lastValue={};guardValue.reset();guarded=false;fired={};}
    auto n=list[index];auto kind=text(n,"kind");
    auto body=c.array(c.ref(c.activeDef,"body"),"body");
    if(body.empty())return DStmt::declined();
    last=body.back();
    if((kind=="IfNode"||kind=="UnlessNode")&&!depth&&!c.ref(n,"subsequent")&&!c.ref(n,"else_clause")) {
      auto arm=c.array(c.ref(n,"statements"),"body");
      if(arm.size()!=1||text(arm[0],"kind")!="ReturnNode")return DStmt::declined();
      auto args=c.args(arm[0]);if(args.size()!=1)return (void)c.error(arm[0],"guard requires one named return"),DStmt::error();
      std::optional<int64_t> gv;
      if(isReturn(c,args[0])) {auto e=value(c,args[0],true);if(failed(e))return DStmt::error();auto v=c.integer((*e)->node);if(failed(v))return DStmt::error();gv=*v;}
      else if(c.constant(args[0])!="BPF::FMOD_CALL")return (void)c.error(arm[0],"guard requires a fmod_ret named return"),DStmt::error();
      if(guarded&&guardValue!=gv)return (void)c.error(arm[0],"guard verdict differs from prior early return"),DStmt::error();
      guarded=true;guardValue=gv;
      auto cond=c.scalar(c.ref(n,"predicate"));if(failed(cond)||!(*cond)->range.isBool)return DStmt::error();
      auto cv=c.emitScalar(*cond);if(!cv)return DStmt::error();
      if(kind=="UnlessNode")cv=arith::XOrIOp::create(c.builder,outputLoc((*cond)->node),cv,arith::ConstantIntOp::create(c.builder,outputLoc((*cond)->node),1,1));
      auto locals=c.locals;auto borrows=c.borrows;auto bindings=c.bindings;
      auto yes=std::make_unique<Block>(),no=std::make_unique<Block>();Value other;
      {
        OpBuilder::InsertionGuard insertion(c.builder);
        c.builder.setInsertionPointToStart(yes.get());auto y=arith::ConstantIntOp::create(c.builder,outputLoc(n),1,1);
        ebpf::IfYieldOp::create(c.builder,outputLoc(n),ValueRange{y});
        c.builder.setInsertionPointToStart(no.get());if(failed(c.refineLocals(*cond,kind=="UnlessNode")))return DStmt::error();
        auto rest=list.drop_front(index+1);if(!rest.empty()&&rest.back()==last)rest=rest.drop_back();
        auto saved=fired;fired={};if(failed(c.scalarStatements(rest,depth)))return DStmt::error();
        other=fired?fired:arith::ConstantIntOp::create(c.builder,outputLoc(n),0,1).getResult();fired=saved;
        ebpf::IfYieldOp::create(c.builder,outputLoc(n),ValueRange{other});
      }
      c.locals=locals;c.borrows=borrows;c.bindings=bindings;
      auto op=ebpf::IfOp::create(c.builder,outputLoc(n),TypeRange{c.builder.getI1Type()},cv);op->getRegion(0).push_back(yes.release());op->getRegion(1).push_back(no.release());fired=op->getResult(0);
      Operation *tail=last;
      if(text(tail,"kind")=="ReturnNode"){auto a=c.args(tail);tail=a.size()==1?a[0]:nullptr;}
      if(list.back()==last&&isReturn(c,tail)){auto e=value(c,tail,false);if(failed(e))return DStmt::error();lastValue=*e;}
      return DStmt::handled({list.size()-index});
    }
    if(!depth&&n==last) {
      Operation *v=n;if(kind=="ReturnNode"){auto a=c.args(n);v=a.size()==1?a[0]:nullptr;}
      if(isReturn(c,v)){auto e=value(c,v,false);if(failed(e))return DStmt::error();lastValue=*e;return DStmt::handled({1});}
      if(c.constant(v)=="BPF::FMOD_CALL") {if(failed(c.known(v)))return DStmt::error();return DStmt::handled({1});}
      (void)issue(c,n,"SB008","ProgramShape","the program must end with a named return value — BPF::FMOD_CALL (call the original function) or BPF.fmod_return(e) (e provably non-zero) — not an implicit last expression, got "+kind.str());return DStmt::error();
    }
    return DStmt::declined();
  }
  LogicalResult finish(Consumer &c) {
    auto body=c.array(c.ref(c.activeDef,"body"),"body");
    if(body.empty())return issue(c,c.activeDef,"SB008","ProgramShape","the program `"+c.programName+"` must end with a named return value — BPF::FMOD_CALL (call the original function) or BPF.fmod_return(e) (e provably non-zero) — not an implicit last expression");
    auto loc=outputLoc(body.back());
    return emitFmodTerminal(c,loc,lastValue,fired,guarded,guardValue);
  }
};
Dispatch<ExportFields> exportProgram(Consumer &c,size_t i,bool schema) {
  if(!schema)return Dispatch<ExportFields>::declined();
  auto p=c.programs[i];auto d=std::static_pointer_cast<const FmodProgram>(p.payload);
  ExportFields f;f.emplace_back("name",p.name);f.emplace_back("kind",p.kind);f.emplace_back("attach_target",p.attachTarget);f.emplace_back("nargs",d->nargs);
  f.emplace_back("ret",ExportValue::write([](auto &o){writeInt(o,{32,true});}));
  std::vector<std::string> maps;for(auto m:p.maps)maps.push_back(c.maps[m].name);
  f.emplace_back("maps",ExportValue::write([maps](auto &o){o.array([&]{for(auto &m:maps)o.value(m);});}));
  if(!d->args.empty())f.emplace_back("args",ExportValue::write([d](auto &o){o.array([&]{for(int64_t n=0;n<d->nargs;++n){auto at=d->args.find(n);if(at==d->args.end())o.value(nullptr);else writeInt(o,*intType(at->second));}});}));
  f.emplace_back("note","Ruby def "+p.name);return Dispatch<ExportFields>::handled(std::move(f));
}
}
LogicalResult emitFmodTerminal(Consumer &c,Location loc,const Expr &lastValue,
                              Value fired,bool guarded,std::optional<int64_t> guardValue) {
  if(guarded&&!fired)return c.error(c.activeDef,"fmod guard has no checked condition");
  if(lastValue||guardValue) {
    Value v;
    if(lastValue){v=c.emitScalar(lastValue);if(!v)return failure();v=arith::TruncIOp::create(c.builder,loc,c.builder.getI32Type(),v);}
    else v=arith::ConstantIntOp::create(c.builder,loc,0,32);
    if(guarded){auto g=arith::ConstantIntOp::create(c.builder,loc,guardValue.value_or(0),32);v=arith::SelectOp::create(c.builder,loc,fired,g,v);}
    OperationState state(loc,"ebpf.return");state.addOperands(v);c.builder.create(state);
  } else if(guarded)ebpf::VerdictIfOp::create(c.builder,loc,fired,"done","done");
  else ebpf::VerdictOp::create(c.builder,loc,"done");
  return success();
}
void registerFmodRet(Registry &r) {
  auto state=std::make_shared<Fmod>();
  r.addRoot("fmod_ret",[state](Consumer &c,Operation *n){return state->root(c,n);});
  r.addExpression("CallNode",[state](Consumer &c,Operation *n){return state->expression(c,n);});
  for(auto k:{"IfNode","UnlessNode","ReturnNode","CallNode","ConstantPathNode","IntegerNode"})r.addStatement(k,[state](Consumer &c,ArrayRef<Operation*> a,size_t i,unsigned d){return state->statement(c,a,i,d);});
  r.addEmitter("fmod.arg",[](Consumer &c,const Expr &e){auto p=std::static_pointer_cast<const Read>(e->payload);auto loc=outputLoc(e->node);OperationState s(loc,"ebpf.ctx.arg");s.addOperands(c.contextValue);s.addTypes(c.builder.getIntegerType(p->type.bits));s.addAttribute("index",c.builder.getI64IntegerAttr(p->index));Value v=c.builder.create(s)->getResult(0);if(p->type.bits<64)v=p->type.sign?arith::ExtSIOp::create(c.builder,loc,c.builder.getI64Type(),v).getResult():arith::ExtUIOp::create(c.builder,loc,c.builder.getI64Type(),v).getResult();return Dispatch<Value>::handled(v);});
  r.addProgramExporter("fmod_ret",exportProgram);
}
}
