#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/PacketLoop.h"
#include "spinel/Conversion/GroupBEffects.h"
#include "spinel/Conversion/GroupEEffects.h"
#include "spinel/Conversion/LoopFacts.h"
#include "spinel/Conversion/Subprograms.h"
#include "spinel/Analysis/BoundedLoopRange.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "llvm/ADT/DenseSet.h"
#include <set>
#include <tuple>
namespace spinel::consumer {
namespace {
using range::Environment;
struct LoopModel;
struct Statement {
  Operation *node=nullptr,*branch=nullptr;
  std::string kind,name;
  Expr value;
  std::shared_ptr<LoopModel> loop;
  std::vector<Statement> yes,no;
  std::optional<PacketLoopWindow> window;
  std::optional<groupb::MapEffect> mapEffect;
  size_t map=0;
  Locals after;
};
struct Body : CheckedBody {
  std::vector<Statement> statements;
  Locals after;
  bool escaped=false;
};
struct LoopModel {
  loops::Syntax syntax;
  loop::Bounds bounds;
  Expr bound;
  std::vector<std::string> carried;
  std::shared_ptr<const Body> body;
  Locals post;
};
struct Engine;
struct GroupState {
  Engine *engine=nullptr;
  std::map<Operation *,std::set<std::string>> blockLocals;
};
Environment ranges(const Locals &locals) {
  Environment out;
  for(const auto &[name,value]:locals)out[name]=value.expr->range;
  return out;
}
void setRanges(Locals &locals,const Environment &env) {
  for(auto &[name,value]:locals) {
    auto found=env.find(name);
    if(found==env.end())continue;
    value.expr=std::make_shared<ScalarExpr>(*value.expr);
    value.expr->range=range::asLocal(found->second);
  }
}
struct Engine {
  Consumer &c;
  GroupState &state;
  BodyTransfer previous;
  std::vector<loops::Syntax> lexical;
  std::vector<unsigned> counts;
  std::vector<std::vector<std::string>> carriedFrames;
  std::vector<Environment> breaks,nexts;
  std::vector<Locals> breakOrigins,nextOrigins;
  Engine(Consumer &consumer,GroupState &s):c(consumer),state(s),
      previous(std::move(consumer.bodyTransfer)) {
    state.engine=this;
  }
  ~Engine(){c.bodyTransfer=std::move(previous);state.engine=nullptr;}
  LogicalResult issue(Operation *node,const std::string &message) {
    return c.diagnostic(node,"SB030","LoopShape",message,true);
  }
  LogicalResult rangeIssue(const range::RangeIssue &i) {
    if(i.code=="SB030")return issue(c.nodes.lookup(i.node),i.message);
    return c.issue(i);
  }
  template<class F> void walk(Operation *node,F fn) {
    llvm::DenseSet<int64_t> seen;
    auto visit=[&](auto &&self,Operation *n)->void {
      if(!n || !seen.insert(c.id(n)).second)return;
      fn(n);
      for(auto ref:n->getAttrOfType<DictionaryAttr>("refs"))
        self(self,c.nodes.lookup(cast<IntegerAttr>(ref.getValue()).getInt()));
      for(auto array:n->getAttrOfType<DictionaryAttr>("arrays"))
        for(auto value:cast<ArrayAttr>(array.getValue()))
          self(self,c.nodes.lookup(cast<IntegerAttr>(value).getInt()));
    };
    visit(visit,node);
  }
  std::map<std::string,Operation *> writes(Operation *body) {
    std::map<std::string,Operation *> out;
    walk(body,[&](Operation *node){
      auto kind=text(node,"kind");
      if(kind=="LocalVariableWriteNode" || kind=="LocalVariableOperatorWriteNode" ||
         kind=="LocalVariableOrWriteNode" || kind=="LocalVariableAndWriteNode")
        out.try_emplace(field(node,"strings","name").str(),node);
    });
    return out;
  }
  FailureOr<Expr> boundRead(Operation *node) {
    auto name=field(node,"strings","name");
    for(auto it=lexical.rbegin();it!=lexical.rend();++it) {
      if(!it->localNames.count(name.str()))continue;
      if(failed(loops::knownBoundRead(c,node,*it)))return failure();
      auto value=c.locals.find(name.str());
      if(value==c.locals.end())
        return (void)c.error(node,"E012 block local has no range binding"),failure();
      auto expr=std::make_shared<ScalarExpr>(*value->second.expr);
      expr->node=node;expr->kind="local";expr->name=name.str();
      expr->range=range::asLocal(expr->range);
      return expr;
    }
    return failure();
  }
  LogicalResult allowed(const loops::Syntax &shape) {
    if(!shape.sourceName.empty() && (c.locals.count(shape.sourceName) ||
       c.borrows.count(shape.sourceName)))
      return issue(shape.block,"the block parameter "+quote(shape.sourceName)+
        " shadows a local of the same name — rename it (P015)");
    bool ok=true;
    walk(shape.body,[&](Operation *n){
      if(!ok)return;
      auto kind=text(n,"kind");auto name=field(n,"strings","name").str();
      if(failed(checkSubprogramLoopCall(c,n))) { ok=false;return; }
      // Packet owns context/kind and its direct-body restriction. Check these
      // candidates before speculative range transfer can suppress the issue.
      if(kind=="CallNode" && (name=="adjust_head" || name=="adjust_tail")) {
        if(failed(c.scalar(n))) { ok=false;return; }
      }
      if(kind=="LocalVariableReadNode" && c.bindings.count("gkernel.ptr:"+name)) {
        (void)issue(n,"the kernel pointer "+quote(name)+" is not read inside a loop body (bpf-mlir's ebpf.loop body has no CO-RE read) — read the members before the loop (P021)");
        ok=false;return;
      }
      if(kind=="CallNode" && (name=="output" || name=="output_str" || name=="output_comm" || name=="output_argv" || name=="output_buf") &&
         llvm::any_of(c.rings,[&](const auto &r){return r.constant==c.constant(c.ref(n,"receiver"));})) {
        (void)issue(n,"a ring buffer "+quote(name)+" is not accepted inside a loop (bpf-mlir's ebpf.loop body has no ring buffer op) — count in the loop and output after it (P015)");
        ok=false;return;
      }
      if(kind=="LocalVariableReadNode" && (c.borrows.count(name)||c.bindings.count("packet:"+name))) {
        (void)issue(n,quote(name)+" is bound outside the loop — a lookup result or a packet window does not cross into a loop body (bpf-mlir's ebpf.loop carries only integers); do the lookup / check inside the body (P015)");
        ok=false;
      } else if(!shape.sourceName.empty() && name==shape.sourceName &&
                kind.starts_with("LocalVariable") && kind.ends_with("WriteNode")) {
        (void)issue(n,"the loop index "+quote(name)+" is not assigned inside the body (Ruby rebinds it every iteration; the unrolled copies fix it) — use another local (P015)");
        ok=false;
      }
    });
    return success(ok);
  }
  static std::string quote(const std::string &s){return "\x60"+s+"\x60";}
  FailureOr<Locals> join(const Locals &a,const Locals &b) {
    auto merged=range::joinEnvironment(ranges(a),ranges(b));
    if(!merged)return (void)c.rangeFailure(merged.takeError(),c.activeDef),failure();
    Locals out;
    for(const auto &[name,value]:*merged) {
      auto expr=std::make_shared<ScalarExpr>(*a.at(name).expr);
      expr->range=range::asLocal(value);
      auto &other=b.at(name).expr->reads;
      expr->reads.insert(expr->reads.end(),other.begin(),other.end());
      out[name]={expr,{}};
    }
    return out;
  }
  LogicalResult refine(const Expr &expr,bool positive) {
    return c.refineLocals(expr,positive);
  }
  LogicalResult knownReads(Operation *node) {
    bool valid=true;
    llvm::DenseSet<int64_t> seen;
    auto visit=[&](auto &&self,Operation *read)->void {
      if(!read||!valid||!seen.insert(c.id(read)).second)return;
      if(text(read,"kind")=="BlockNode")return;
      if(text(read,"kind")=="LocalVariableReadNode") {
        auto name=field(read,"strings","name").str();
        for(auto it=lexical.rbegin();it!=lexical.rend();++it) {
          if(!it->localNames.count(name))continue;
          if(failed(loops::knownBoundRead(c,read,*it)))valid=false;
          break;
        }
      }
      for(auto attr:read->getAttrOfType<DictionaryAttr>("refs"))
        self(self,c.nodes.lookup(cast<IntegerAttr>(attr.getValue()).getInt()));
      for(auto attr:read->getAttrOfType<DictionaryAttr>("arrays"))
        for(auto value:cast<ArrayAttr>(attr.getValue()))
          self(self,c.nodes.lookup(cast<IntegerAttr>(value).getInt()));
    };
    visit(visit,node);
    return success(valid);
  }
  FailureOr<std::shared_ptr<Body>> sequence(Operation *statements,bool arm=false,StringRef armKind="") {
    auto body=std::make_shared<Body>();
    auto list=c.array(statements,"body");
    for(size_t i=0;i<list.size();++i) {
      auto node=list[i];auto kind=text(node,"kind");
      if(kind.starts_with("LocalVariable") && kind.ends_with("WriteNode")) {
        auto name=field(node,"strings","name");
        bool bound=false;
        for(auto it=lexical.rbegin();it!=lexical.rend();++it)
          if(it->localNames.count(name.str())) {
            if(failed(loops::knownBoundLocal(c,node,*it)))return failure();
            bound=true;break;
          }
        if(!bound && failed(c.known(node)))return failure();
      }
      Statement statement;statement.node=node;
      statement.name=field(node,"strings","name").str();
      auto rhsNode=c.ref(node,"value");
      auto rhsName=field(rhsNode,"strings","name");
      if(!loops::isIterator(c,node) && failed(knownReads(node)))return failure();
      Dispatch<PacketLoopWindow> packet;
      if(c.registry.packetLoop)
        packet=c.registry.packetLoop->check(c,list,i,counts.size());
      if(packet.state==Disposition::Error)return failure();
      if(packet.state==Disposition::Handled) {
        statement.kind="packet";statement.window=*packet.value;
        auto pre=c.locals;
        FailureOr<std::shared_ptr<Body>> yes=failure();
        {
          ScopeGuard restore(c);
          auto scope=c.registry.packetLoop->enterCheck(c,*statement.window);
          if(!scope)return (void)c.rangeFailure(scope.takeError(),node),failure();
          if(!*scope)return (void)c.error(node,"E027 packet scope returned null"),failure();
          yes=sequence(c.ref(statement.window->branch,"statements"),true,"window");
          if(failed(yes))return failure();
          statement.yes=(*yes)->statements;
          statement.after=c.locals;
        }
        auto sub=c.ref(statement.window->branch,"subsequent");
        if(sub&&text(sub,"kind")!="ElseNode")
          return (void)c.diagnostic(sub,"SB005","RefCheckShape","`elsif` is not accepted after `if "+statement.window->name+"` (P004 §1)",true),failure();
        c.locals=pre;
        auto no=sequence(c.ref(sub,"statements"),true,"window");
        if(failed(no))return failure();
        statement.no=(*no)->statements;
        auto joined=join(statement.after,c.locals);
        if(failed(joined))return failure();
        c.locals=*joined;statement.after=c.locals;
        i+=statement.window->consumed-1;
      } else if(kind=="LocalVariableWriteNode"&&rhsName=="lookup") {
        statement.kind="present";
        auto receiver=c.constant(c.ref(rhsNode,"receiver"));
        auto found=llvm::find_if(c.maps,[&](auto &m){return m.name==receiver;});
        if(found==c.maps.end())return (void)c.error(rhsNode,"map receiver is not declared"),failure();
        statement.map=found-c.maps.begin();
        if(failed(c.knownMap(rhsNode,statement.map)))return failure();
        if(i+1>=list.size())return (void)c.error(node,"lookup requires its immediate present check"),failure();
        auto branch=list[++i];statement.branch=branch;auto predicate=c.ref(branch,"predicate");
        if(text(branch,"kind")!="IfNode"||text(predicate,"kind")!="LocalVariableReadNode"||
           field(predicate,"strings","name")!=statement.name)
          return (void)c.diagnostic(node,"SB005","RefCheckShape","`"+statement.name+" = "+found->name+".lookup(…)` must be followed immediately by `if "+statement.name+"` (the present / absent check)",true),failure();
        auto sub=c.ref(branch,"subsequent");
        if(text(sub,"kind")=="IfNode")
          return (void)c.diagnostic(sub,"SB005","RefCheckShape","`elsif` is not accepted after `if "+statement.name+"` (P001 §3.4)",true),failure();
        auto key=c.checkedMapKey(statement.map,c.args(rhsNode),rhsNode);
        if(failed(key))return failure();
        statement.value=*key;
        auto oldBorrows=c.borrows;auto pre=c.locals;
        std::optional<int64_t> literal=(*key)->kind=="literal" ? std::optional<int64_t>((*key)->literal) : std::nullopt;
        c.borrows[statement.name]={statement.map,literal,{}};
        auto yes=sequence(c.ref(branch,"statements"),true,armKind=="window"?"window":"present");
        if(failed(yes))return failure();
        statement.yes=(*yes)->statements;auto thenLocals=c.locals;
        c.locals=pre;c.borrows=oldBorrows;
        auto no=sequence(c.ref(sub,"statements"),true,armKind=="window"?"window":"present");
        if(failed(no))return failure();
        statement.no=(*no)->statements;c.borrows=oldBorrows;
        auto merged=join(thenLocals,c.locals);
        if(failed(merged))return failure();
        c.locals=*merged;statement.after=c.locals;
      } else if(loops::isIterator(c,node)) {
        auto model=analyze(node);
        if(failed(model))return failure();
        statement.kind="loop";statement.loop=*model;
      } else if(kind=="LocalVariableWriteNode" ||
                kind=="LocalVariableOperatorWriteNode") {
        statement.kind="assign";
        auto status=kind=="LocalVariableWriteNode"
            ? checkStatusWrite(c,node) : Dispatch<Expr>::declined();
        if(status.state==Disposition::Error)return failure();
        FailureOr<Expr> rhs=status.state==Disposition::Handled
            ? FailureOr<Expr>(*status.value) : c.scalar(c.ref(node,"value"));
        if(failed(rhs))return failure();
        if(kind=="LocalVariableOperatorWriteNode") {
          auto local=c.locals.find(statement.name);
          if(local==c.locals.end())
            return (void)c.error(node,"operator assignment needs a scalar local"),failure();
          auto left=std::make_shared<ScalarExpr>(*local->second.expr);
          left->kind="local";left->name=statement.name;left->node=node;
          left->range=range::asLocal(left->range);
          auto expr=std::make_shared<ScalarExpr>();
          expr->node=node;expr->kind="binary";
          expr->op=field(node,"strings","binary_operator").str();
          expr->args={left,*rhs};expr->reads=left->reads;
          expr->reads.insert(expr->reads.end(),(*rhs)->reads.begin(),(*rhs)->reads.end());
          rhs=c.outcome(expr,range::transferBinary(expr->op,left->range,(*rhs)->range,
                                                  {c.id(node),c.id((*rhs)->node)}));
          if(failed(rhs))return failure();
        }
        if(!(*rhs)->range.isBool &&
           failed(c.checked(range::checkIntegerUse((*rhs)->range,{c.id((*rhs)->node)}),
                            (*rhs)->node)))return failure();
        statement.value=*rhs;
        if(statement.name!="_")c.locals[statement.name]={*rhs,{}};
      } else if(kind=="IfNode" || kind=="UnlessNode") {
        statement.kind="if";
        auto predicate=c.scalar(c.ref(node,"predicate"));
        if(failed(predicate))return failure();
        if(!(*predicate)->range.isBool)
          return (void)c.error(node,"E012 loop condition must be bool"),failure();
        if(kind=="UnlessNode") {
          auto neg=std::make_shared<ScalarExpr>();
          neg->node=(*predicate)->node;neg->kind="not";neg->args={*predicate};
          neg->range.isBool=true;predicate=neg;
        }
        statement.value=*predicate;
        auto pre=c.locals;
        if(failed(refine(*predicate,true)))return failure();
        auto yes=sequence(c.ref(node,"statements"),true,armKind=="window"?"window":"if");
        if(failed(yes))return failure();
        auto thenLocals=c.locals;c.locals=pre;
        if(failed(refine(*predicate,false)))return failure();
        auto alternate=c.ref(node,kind=="UnlessNode"?"else_clause":"subsequent");
        if(text(alternate,"kind")=="IfNode")
          return (void)c.error(alternate,"E012 loop elsif not yet supported"),failure();
        auto no=sequence(c.ref(alternate,"statements"),true,armKind=="window"?"window":"if");
        if(failed(no))return failure();
        auto elseLocals=c.locals;
        statement.yes=std::move((*yes)->statements);
        statement.no=std::move((*no)->statements);
        if((*yes)->escaped && (*no)->escaped)c.locals=pre;
        else if((*yes)->escaped)c.locals=elseLocals;
        else if((*no)->escaped)c.locals=thenLocals;
        else {
          auto result=join(thenLocals,elseLocals);
          if(failed(result))return failure();
          c.locals=std::move(*result);
        }
        statement.after=c.locals;
      } else if(kind=="BreakNode" || kind=="NextNode") {
        statement.kind=kind=="BreakNode"?"break":"next";
        auto kw=statement.kind;
        if(c.ref(node,"arguments"))
          return (void)issue(node,quote(kw)+" with a value is not accepted — the value of a loop is not used on the eBPF side; write a bare "+quote(kw)+" and keep the value in a local (P015)"),failure();
        if(armKind=="window")
          return (void)issue(node,quote(kw)+" inside a packet window's `if w` arm is not accepted (bpf-mlir leaves a loop only from an if / present arm) — set a local in the arm and "+quote(kw+" if")+" after it (P015)"),failure();
        if(!arm)
          return (void)issue(node,"an unconditional "+quote(kw)+" directly in the loop body makes the rest of the body dead code — write "+quote(kw+" if cond")+" (P015)"),failure();
        if(i+1!=list.size())
          return (void)issue(node,quote(kw)+" must be the last statement of its arm — the statements after it are dead code (P015)"),failure();
        (kind=="BreakNode"?breaks:nexts).push_back(ranges(c.locals));
        (kind=="BreakNode"?breakOrigins:nextOrigins).push_back(c.locals);
        body->escaped=true;
      } else if(kind=="CallNode") {
        auto receiver=c.constant(c.ref(node,"receiver"));
        auto mapDecl=llvm::find_if(c.maps,[&](const auto &m){return m.name==receiver;});
        auto op=field(node,"strings","name");
        if(mapDecl!=c.maps.end() &&
           (mapDecl->kind=="hash" || mapDecl->kind=="lru_hash" || mapDecl->kind=="percpu_hash") &&
           (op=="update" || op=="insert" || op=="replace" || op=="delete" || op=="add_or_init"))
          return (void)c.diagnostic(node,"SB026","StatusIgnored",discardedHashStatus(*mapDecl,op),true),failure();
        auto map=groupb::checkMapEffect(c,node);
        if(map.state==Disposition::Error)return failure();
        if(map.state==Disposition::Handled) {
          statement.kind="map";statement.mapEffect=*map.value;
        } else {
          auto counter=checkCounterAdd(c,node);
          if(counter.state==Disposition::Error)return failure();
          if(counter.state!=Disposition::Handled)
            return (void)c.error(node,"E027 unsupported loop call"),failure();
          statement.kind="counter";statement.value=*counter.value;
        }
      } else return (void)c.error(node,"E012 unsupported loop body statement "+kind.str()),failure();
      body->statements.push_back(std::move(statement));
    }
    body->after=c.locals;return body;
  }
  FailureOr<std::shared_ptr<LoopModel>> analyze(Operation *node) {
    auto shape=loops::inspect(c,node,counts.size(),
        [&](const loops::Syntax &s){return allowed(s);});
    if(failed(shape))return failure();
    auto count=c.scalar(shape->count);
    if(failed(count))return failure();
    unsigned product=1;for(auto n:counts)product*=n;
    auto bound=loop::resolveBounds((*count)->range,shape->inclusive,
                                  counts.size(),product,{c.id(node),c.id(shape->count)});
    if(!bound)return (void)c.rangeFailure(bound.takeError(),node),failure();
    if(bound->issue)return (void)rangeIssue(*bound->issue),failure();
    bool outerProbe=c.probing;
    auto model=std::make_shared<LoopModel>();
    model->syntax=*shape;model->bounds=*bound->bounds;
    if(model->bounds.runtime)model->bound=*count;
    auto pre=c.locals;
    auto written=writes(shape->body);
    for(auto &[name,where]:written)if(pre.count(name)) {
      if(pre.at(name).expr->range.isBool)
        return (void)issue(where,quote(name)+" is a bool assigned inside the loop — a value carried across iterations must be an Integer (use 0 / 1) (P015)"),failure();
      model->carried.push_back(name);
    }
    lexical.push_back(*shape);counts.push_back(model->bounds.count);
    // Mirror the finite solver's entry/exit choices with owned expression
    // origins. A numeric range alone cannot carry Map/Parameter/CallResult.
    Locals originEntry=pre;
    std::vector<Locals> originEntries,originExits;
    bool finalTransfer=false;
    auto keepOriginKeys=[&](const Locals &locals) {
      Locals kept=pre;
      for(auto &[name,local]:kept) {
        auto found=locals.find(name);
        if(found!=locals.end())local=found->second;
        local.expr=std::make_shared<ScalarExpr>(*local.expr);
        std::set<std::tuple<ReadOrigin::Domain,size_t,std::optional<int64_t>,std::string,int64_t>> seen;
        std::vector<ReadOrigin> reads;
        for(const auto &read:local.expr->reads)
          if(seen.emplace(read.domain,read.map,read.key,read.ref,read.token).second)
            reads.push_back(read);
        local.expr->reads=std::move(reads);
        local.value={};
      }
      return kept;
    };
    auto oldTransfer=std::move(c.bodyTransfer);
    c.bodyTransfer=[&](Consumer &,const BodyRequest &request)->llvm::Expected<BodyResult>{
      if(finalTransfer) {
        c.locals=originEntries.empty()?pre:originEntries.front();
        for(size_t i=1;i<originEntries.size();++i) {
          auto merged=join(c.locals,originEntries[i]);
          if(failed(merged))return llvm::createStringError("E051 loop origin entry join failed");
          c.locals=*merged;
        }
      } else {
        c.locals=originEntry;
        originEntries.push_back(originEntry);
        if(model->bounds.runtime)originExits.push_back(originEntry);
      }
      setRanges(c.locals,request.entry);
      for(auto &[name,local]:c.locals)local.value={};
      if(!shape->sourceName.empty()) {
        auto iv=std::make_shared<ScalarExpr>();
        iv->node=shape->parameter;iv->kind="local";iv->name=shape->sourceName;
        iv->range={math::MathInterval(request.iv),false,false,range::Form::Local};
        c.locals[shape->sourceName]={iv,{}};
        c.bindings[shape->sourceName]={shape->parameter,shape->analyzedParameter,{}};
      }
      auto savedBreaks=std::move(breaks),savedNexts=std::move(nexts);
      auto savedBreakOrigins=std::move(breakOrigins),savedNextOrigins=std::move(nextOrigins);
      breaks.clear();nexts.clear();
      breakOrigins.clear();nextOrigins.clear();
      auto body=sequence(request.statements);
      BodyResult result;
      result.normal=ranges(c.locals);
      result.breaks=std::move(breaks);result.nexts=std::move(nexts);
      breaks=std::move(savedBreaks);nexts=std::move(savedNexts);
      if(!finalTransfer) {
        originExits.insert(originExits.end(),breakOrigins.begin(),breakOrigins.end());
        auto end=c.locals;
        for(const auto &next:nextOrigins) {
          auto merged=join(end,next);
          if(failed(merged))return llvm::createStringError("E051 loop next origin join failed");
          end=*merged;
        }
        originEntry=keepOriginKeys(end);
      }
      breakOrigins=std::move(savedBreakOrigins);nextOrigins=std::move(savedNextOrigins);
      if(request.mode==CheckMode::Probe) {
        // Speculative semantic issues are internal and discarded by the finite
        // solver. A failing assignment preserves its previous local, as Go.
        result.issues=std::move(c.probeIssues);c.probeIssues.clear();
      } else if(failed(body)) {
        return llvm::createStringError("E012 checked body rejected");
      } else result.checked=*body;
      return result;
    };
    std::shared_ptr<const Body> checkedBody;
    auto result=loop::analyzeFinite(model->bounds,ranges(pre),
      [&](const Environment &entry,const math::Interval &iv,loop::Mode mode)
          ->llvm::Expected<loop::Step>{
        finalTransfer=mode==loop::Mode::Check;
        auto transfer=c.transferBody({shape->body,entry,iv,
          outerProbe || mode==loop::Mode::Probe?CheckMode::Probe:CheckMode::Check});
        if(!transfer)return transfer.takeError();
        if(mode==loop::Mode::Check && !outerProbe)
          checkedBody=std::static_pointer_cast<const Body>(transfer->checked);
        return loop::Step{transfer->normal,transfer->breaks,transfer->nexts,
                          transfer->issues};
      });
    c.bodyTransfer=std::move(oldTransfer);
    counts.pop_back();lexical.pop_back();
    if(!result) {
      auto error=result.takeError();
      if(c.blocking)llvm::consumeError(std::move(error));
      else (void)c.rangeFailure(std::move(error),node);
      return failure();
    }
    model->body=checkedBody;
    originExits.push_back(originEntry);
    auto originPost=originExits.front();
    for(size_t i=1;i<originExits.size();++i) {
      auto merged=join(originPost,originExits[i]);
      if(failed(merged))return failure();
      originPost=*merged;
    }
    model->post=keepOriginKeys(originPost);setRanges(model->post,result->post);
    for(auto &[name,local]:model->post)local.value={};
    c.locals=model->post;
    for(auto &[name,where]:written)
      if(!outerProbe && !pre.count(name) && name!=shape->sourceName)
        state.blockLocals[c.activeDef].insert(name);
    return model;
  }
  LogicalResult emit(const LoopModel &model);
  LogicalResult emitBody(const std::vector<Statement> &body);
};
LogicalResult Engine::emitBody(const std::vector<Statement> &body) {
  for(const auto &s:body) {
    if(s.kind=="assign") {
      auto value=c.emitScalar(s.value);if(!value)return failure();
      if(s.name!="_")c.locals[s.name]={s.value,value};
    } else if(s.kind=="map") {
      if(failed(groupb::emitMapEffect(c,*s.mapEffect)))return failure();
    } else if(s.kind=="counter") {
      if(failed(emitCounterAdd(c,s.value)))return failure();
    } else if(s.kind=="packet") {
      if(failed(c.registry.packetLoop->emit(c,*s.window,
           [&]{return emitBody(s.yes);},[&]{return emitBody(s.no);})))return failure();
    } else if(s.kind=="loop") {
      if(failed(emit(*s.loop)))return failure();
    } else if(s.kind=="break" || s.kind=="next") {
      SmallVector<Value> values;
      for(auto &name:carriedFrames.back())values.push_back(c.locals.at(name).value);
      if(s.kind=="break")ebpf::BreakOp::create(c.builder,outputLoc(s.node),values);
      else ebpf::ContinueOp::create(c.builder,outputLoc(s.node),values);
    } else if(s.kind=="if" || s.kind=="present") {
      Value predicate;
      if(s.kind=="present") {
        auto key=c.emitMapKey(s.value,s.map);if(!key)return failure();
        auto &m=c.maps[s.map];m.used=true;c.usedMap=true;
        predicate=ebpf::MapLookupOp::create(c.builder,outputLoc(s.node),
          ebpf::MaybeRefType::get(c.ctx,m.valueType?m.valueType:c.builder.getIntegerType(m.bits)),m.value,key);
      } else predicate=c.emitScalar(s.value);
      if(!predicate)return failure();
      auto pre=c.locals;
      auto yes=std::make_unique<Block>(),no=std::make_unique<Block>();
      Locals a,b;
      bool escA=!s.yes.empty() && (s.yes.back().kind=="break" || s.yes.back().kind=="next");
      bool escB=!s.no.empty() && (s.no.back().kind=="break" || s.no.back().kind=="next");
      {
        OpBuilder::InsertionGuard guard(c.builder);
        c.builder.setInsertionPointToStart(yes.get());
        auto oldBorrows=c.borrows;
        if(s.kind=="present") {
          auto &m=c.maps[s.map];
          auto ref=yes->addArgument(ebpf::BorrowedType::get(c.ctx,m.valueType?m.valueType:c.builder.getIntegerType(m.bits)),c.builder.getUnknownLoc());
          std::optional<int64_t> key=s.value->kind=="literal"?std::optional<int64_t>(s.value->literal):std::nullopt;
          c.borrows[s.name]={s.map,key,ref};
        }
        if(failed(emitBody(s.yes)))return failure();
        a=c.locals;c.locals=pre;c.borrows=oldBorrows;
        c.builder.setInsertionPointToStart(no.get());
        if(failed(emitBody(s.no)))return failure();
        b=c.locals;c.locals=pre;
      }
      std::vector<std::string> names;SmallVector<Type> types;
      if(!(escA && escB)) {
        auto &left=escA?b:a;auto &right=escB?a:b;
        for(auto &[name,local]:left) {
          if(!right.count(name))continue;
          if(pre.count(name) && local.value==pre.at(name).value &&
             right.at(name).value==pre.at(name).value)continue;
          names.push_back(name);types.push_back(local.value.getType());
        }
      }
      Operation *op;
      if(s.kind=="present")
        op=ebpf::RefCheckOp::create(c.builder,outputLoc(s.node),types,predicate);
      else op=ebpf::IfOp::create(c.builder,outputLoc(s.node),types,predicate);
      op->getRegion(0).push_back(yes.release());
      op->getRegion(1).push_back(no.release());
      {
        OpBuilder::InsertionGuard guard(c.builder);
        for(unsigned arm=0;arm<2;++arm) {
          if(arm?escB:escA)continue;
          SmallVector<Value> values;
          auto &env=arm?b:a;
          for(auto &name:names)values.push_back(env.at(name).value);
          c.builder.setInsertionPointToEnd(&op->getRegion(arm).front());
          if(s.kind=="present")ebpf::YieldOp::create(c.builder,outputLoc(s.branch),values);
          else ebpf::IfYieldOp::create(c.builder,outputLoc(s.node),values);
        }
      }
      for(size_t i=0;i<names.size();++i)
        c.locals[names[i]]={s.after.at(names[i]).expr,op->getResult(i)};
    }
  }
  return success();
}
LogicalResult Engine::emit(const LoopModel &model) {
  auto pre=c.locals;
  auto loc=outputLoc(model.syntax.call);
  Value bound;
  if(model.bound) {
    bound=c.emitScalar(model.bound);
    if(model.bounds.inclusive)
      bound=arith::AddIOp::create(c.builder,loc,bound,
        arith::ConstantIntOp::create(c.builder,loc,1,64));
    if(model.bounds.clamp) {
      auto zero=arith::ConstantIntOp::create(c.builder,loc,0,64);
      auto pred=arith::CmpIOp::create(c.builder,loc,arith::CmpIPredicate::slt,bound,zero);
      auto op=ebpf::IfOp::create(c.builder,loc,TypeRange{c.builder.getI64Type()},pred);
      for(unsigned arm=0;arm<2;++arm) {
        auto block=new Block;op->getRegion(arm).push_back(block);
        OpBuilder::InsertionGuard guard(c.builder);c.builder.setInsertionPointToStart(block);
        ebpf::IfYieldOp::create(c.builder,loc,ValueRange{arm?bound:Value(zero)});
      }
      bound=op->getResult(0);
    }
    bound=arith::TruncIOp::create(c.builder,loc,c.builder.getI32Type(),bound);
  }
  SmallVector<Value> inits;SmallVector<Type> types;
  for(auto &name:model.carried) {
    inits.push_back(pre.at(name).value);types.push_back(c.builder.getI64Type());
  }
  unsigned emittedCount=model.bounds.count;
#ifdef SPINEL_E012_TEST_COUNT
  if(emittedCount==4)emittedCount=3;
#endif
  auto op=ebpf::LoopOp::create(c.builder,loc,types,uint64_t(emittedCount),
                              true,false,bound,inits);
  auto block=new Block;op.getBody().push_back(block);
  auto iv=block->addArgument(c.builder.getI32Type(),c.builder.getUnknownLoc());
  for(auto &name:model.carried) {
    auto value=block->addArgument(c.builder.getI64Type(),c.builder.getUnknownLoc());
    c.locals[name]={pre.at(name).expr,value};
  }
  {
    OpBuilder::InsertionGuard guard(c.builder);c.builder.setInsertionPointToStart(block);
    if(!model.syntax.sourceName.empty()) {
      auto expr=std::make_shared<ScalarExpr>();
      expr->node=model.syntax.parameter;expr->kind="local";expr->name=model.syntax.sourceName;
      expr->range={math::MathInterval(math::Interval::point(math::Integer::from(0))),
                   false,false,range::Form::Local};
      auto value=arith::ExtUIOp::create(c.builder,loc,c.builder.getI64Type(),iv);
      c.locals[model.syntax.sourceName]={expr,value};
    }
    carriedFrames.push_back(model.carried);
    auto result=emitBody(model.body->statements);
    carriedFrames.pop_back();if(failed(result))return failure();
    SmallVector<Value> yields;
    for(auto &name:model.carried)yields.push_back(c.locals.at(name).value);
    ebpf::LoopYieldOp::create(c.builder,loc,yields,Value());
  }
  c.locals=pre;
  for(size_t i=0;i<model.carried.size();++i) {
    auto &name=model.carried[i];
    c.locals[name]={model.post.at(name).expr,op->getResult(i)};
  }
  return success();
}
} // namespace
void registerGroupB(Registry &registry) {
  registry.addStatement("WhileNode",[](Consumer &c,ArrayRef<Operation *> list,
                                       size_t index,unsigned){
    (void)c.diagnostic(list[index],"SB001","UnsupportedConstruct",
        "WhileNode has no static bound — write `N.times do |i| … end`, `k.times`, `(0...k).each` or `(0..m).each` with a bound ≤ 64 (P015)",true);
    return Dispatch<StatementResult>::error();
  });
  auto state=std::make_shared<GroupState>();
  registry.addExpression("LocalVariableReadNode",[state](Consumer &c,Operation *node){
    if(!state->engine)return Dispatch<Expr>::declined();
    auto name=field(node,"strings","name");
    auto &stack=state->engine->lexical;
    if(llvm::none_of(stack,[&](auto &s){return s.localNames.count(name.str());}))
      return Dispatch<Expr>::declined();
    if(c.borrows.count(name.str()) || c.bindings.count("packet:"+name.str())) {
      for(auto it=stack.rbegin();it!=stack.rend();++it)
        if(it->localNames.count(name.str())) {
          if(failed(loops::knownBoundRead(c,node,*it)))return Dispatch<Expr>::error();
          break;
        }
      return Dispatch<Expr>::declined();
    }
    auto value=state->engine->boundRead(node);
    return failed(value)?Dispatch<Expr>::error():Dispatch<Expr>::handled(*value);
  });
  registry.addExpression("CallNode",[state](Consumer &c,Operation *node){
    if(loops::isIterator(c,node)) {
      (void)c.diagnostic(node,"SB030","LoopShape",
        "the value of "+Engine::quote(field(node,"strings","name").str())+
        " (its receiver, or a break value) is not used on the eBPF side — write the loop as a statement and keep results in locals (P015)",true);
      return Dispatch<Expr>::error();
    }
    auto name=field(node,"strings","name").str();
    if(!c.ref(node,"receiver") && state->blockLocals[c.activeDef].count(name)) {
      (void)c.diagnostic(node,"SB030","LoopShape",Engine::quote(name)+
        " was first assigned inside a loop block — Ruby does not keep it after the loop (it reads a method call); assign it before the loop (P015)",true);
      return Dispatch<Expr>::error();
    }
    return Dispatch<Expr>::declined();
  });
  registry.addStatement("CallNode",[state](Consumer &c,ArrayRef<Operation *> list,
                                           size_t index,unsigned){
    auto node=list[index];
    if(!loops::isIterator(c,node))return Dispatch<StatementResult>::declined();
    Engine engine(c,*state);
    auto callerLocals=c.locals;
    auto model=engine.analyze(node);
    if(failed(model))return Dispatch<StatementResult>::error();
    // Analysis changes only range models; SSA inputs still come from the
    // caller's original locals. The transferBody scope restores all SSA.
    // Recover loop-carried SSA from the caller; analyze's post preserved Value.
    c.locals=std::move(callerLocals);
    if(failed(engine.emit(**model)))return Dispatch<StatementResult>::error();
    return Dispatch<StatementResult>::handled({1});
  });
}
} // namespace spinel::consumer
