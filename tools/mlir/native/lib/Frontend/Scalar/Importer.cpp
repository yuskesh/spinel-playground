#include "spinel-mlir/Scalar/Importer.h"
#include "spinel-mlir/Core/BlockLoops.h"
#include "spinel-mlir/Core/Intrinsics.h"

#include "FreestandingSubset.h"
#include "ScalarAst.h"

#include "llvm/ADT/StringSet.h"
#include "llvm/ADT/Twine.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <deque>
#include <map>
#include <set>
#include <sstream>

using namespace llvm;
using namespace spinel_mlir::contract;

namespace spinel_mlir::scalar {

class ScalarProgramBuilder {
public:
  static ScalarParameter
  parameter(std::string name, std::string type,
            std::optional<ScalarLentBuffer> lent = std::nullopt) {
    return ScalarParameter(std::move(name), std::move(type), std::move(lent));
  }
  static ScalarMethod method(std::string name, int64_t scope, int64_t defNode,
                             int64_t line,
                             std::vector<ScalarParameter> parameters,
                             std::string returnType, bool scalarAbi,
                             bool checkedReach = false) {
    return ScalarMethod(std::move(name), scope, defNode, line,
                        std::move(parameters), std::move(returnType), scalarAbi,
                        checkedReach);
  }
  static ScalarCallEdge call(std::string caller, std::string callee,
                             int64_t callNode, int64_t line,
                             std::vector<int64_t> argumentNodes) {
    return ScalarCallEdge(std::move(caller), std::move(callee), callNode, line,
                          std::move(argumentNodes));
  }
  static std::unique_ptr<ScalarProgram>
  program(std::string sourceFile, std::vector<std::string> entries,
          std::vector<ScalarMethod> methods,
          std::vector<ScalarCallEdge> calls) {
    return std::unique_ptr<ScalarProgram>(new ScalarProgram(
        std::move(sourceFile), std::move(entries), std::move(methods),
        std::move(calls)));
  }
};

namespace {

/// Decision 0045: a type the inference gave, as a refusal says it. A
/// buffer is never called an array: where no spelling is visible (a
/// helper's parameter or result), the refusal names the element kind.
std::string typeWords(llvm::StringRef ty) {
  if (ty == "int_array") return "an Integer buffer";
  if (ty == "float_array") return "a Float buffer";
  if (ty == "poly_array") return "a buffer of more than one element type";
  return ty.str();
}

struct DefInfo {
  const Node *node;
  const Method *method;
  int64_t line;
  int64_t body;
};

using ast::findField;
using ast::getArray;
using ast::getReference;
using ast::getString;
using ast::quote;

class Selector {
public:
  Selector(const ContractModule &module, ScalarDiagnosticFn diag,
           ScalarImportOptions options)
      : module_(module), diag_(diag), options_(options) {
    for (const Node &node : module.nodes())
      nodes_[node.id] = &node;
    for (const NodeType &type : module.nodeTypes())
      types_[type.id] = &type;
    for (const Method &method : module.methods())
      methods_[method.scope] = &method;
  }

  std::unique_ptr<ScalarProgram> run(ArrayRef<std::string> entries) {
    if (entries.empty())
      return reject(0, "empty-entry-selection", "no entry methods were given");
    if (!indexDefinitions())
      return nullptr;

    std::deque<std::string> pending;
    std::set<std::string> registered;
    std::vector<std::string> entryCopy;
    for (const std::string &entry : entries) {
      if (!definitions_.count(entry))
        return reject(0, "unknown-entry-method", quote(entry));
      entryCopy.push_back(entry);
      if (registered.insert(entry).second)
        pending.push_back(entry);
    }

    std::vector<std::string> closure;
    std::vector<ScalarCallEdge> selectedCalls;
    while (!pending.empty()) {
      std::string name = std::move(pending.front());
      pending.pop_front();
      closure.push_back(name);
      const DefInfo &definition = definitions_.at(name);
      std::vector<const Node *> bodyNodes;
      collectSubtree(definition.body, bodyNodes);
      llvm::sort(bodyNodes,
                 [](const Node *a, const Node *b) { return a->id < b->id; });
      for (const Node *node : bodyNodes) {
        if (node->kind != "CallNode")
          continue;
        int64_t receiver = -1;
        std::string callee;
        if (!getReference(*node, "receiver", receiver) ||
            !getString(*node, "name", callee))
          return rejectNode(node->id, "unsupported-node", node->kind);
        if (receiver >= 0)
          continue;
        // Exclude platform externs from the closure: externCall lowers profile-declared calls
        // directly to llvm.call, never emitting synthetic driver stub defs, matching frozen
        // interception.
        if (options_.freestandingTypes && options_.extern_(callee))
          continue;
        // `core_fail` names a status, not a method: nothing is added to the
        // closure and no definition is looked for. A `core_fail` the rules
        // above do not admit falls through to the unresolved-call refusal
        // below rather than being quietly skipped.
        if (isCoreFailCall(*node) || isIntrinsicCall(*node))
          continue;
        // Decision 0026 step 4: on a CORE route the eligibility checker has
        // resolved every call into the closure; the edge names the callee.
        // A call it did not resolve is no edge, whatever its name.
        if (options_.callEdges) {
          auto edge = options_.callEdges->find(node->id);
          if (edge == options_.callEdges->end())
            return rejectNode(node->id, "unresolved-call", quote(callee));
          callee = edge->second;
        }
        auto target = definitions_.find(callee);
        if (target == definitions_.end())
          return rejectNode(node->id, "unresolved-call", quote(callee));
        std::vector<int64_t> args;
        int64_t badArgumentsNode = node->id;
        if (!callArguments(*node, args, badArgumentsNode)) {
          auto bad = nodes_.find(badArgumentsNode);
          StringRef kind = bad == nodes_.end() ? StringRef("CallNode")
                                               : StringRef(bad->second->kind);
          return rejectNode(badArgumentsNode, "unsupported-node", kind);
        }
        const size_t expected = target->second.method->parameters.size();
        if (args.size() != expected) {
          std::ostringstream detail;
          detail << "call to '" << callee << "' with " << args.size()
                 << " arguments, expected " << expected;
          return rejectNode(node->id, "arity-mismatch", detail.str());
        }
        selectedCalls.push_back(ScalarProgramBuilder::call(
            name, callee, node->id, lineOf(node->id), std::move(args)));
        if (registered.insert(callee).second)
          pending.push_back(callee);
      }
    }

    // DECISION 0044: which helper parameters are buffers their callers lend
    // them, derived from the whole closure's calls before any signature is
    // judged.
    if (options_.freestandingTypes && !deriveLentBuffers(selectedCalls))
      return nullptr;

    // Binding discovers the complete FIFO closure first.  Only then may body
    // semantics be inspected: otherwise an early caller-body error can hide a
    // newly reached callee's invalid public signature.
    std::vector<ScalarMethod> selectedMethods;
    for (const std::string &name : closure)
      if (!validateSignature(name, definitions_.at(name), selectedMethods))
        return nullptr;
    for (const std::string &name : closure) {
      // Run stage 1 immediately before inspecting each method body, as frozen want() does. It names
      // allocating syntax before generic importer rejection: n.times { |i| i } reports "times takes
      // a block" rather than unreadable CallNode. Only freestandingTypes uses this ordering; hosted
      // remains unchanged.
      if (options_.freestandingTypes) {
        const DefInfo &d = definitions_.at(name);
        auto lookup = [&](int64_t id) -> const Node * {
          auto found = nodes_.find(id);
          return found == nodes_.end() ? nullptr : found->second;
        };
        auto typeOf = [&](int64_t id) -> std::string {
          auto found = types_.find(id);
          return found == types_.end() ? std::string() : found->second->type;
        };
        std::set<std::string> lentNames;
        for (size_t i = 0; i < d.method->parameters.size(); ++i)
          if (lent_.count({name, i}))
            lentNames.insert(d.method->parameters[i].name);
        if (auto why = fsSubsetCheck(lookup, typeOf, *d.node, name,
                                     options_.root(name), lentNames))
          return rejectNode(d.node->id, "unsupported", *why), nullptr;
      }
      std::vector<const Node *> bodyNodes;
      collectSubtree(definitions_.at(name).body, bodyNodes);
      llvm::sort(bodyNodes,
                 [](const Node *a, const Node *b) { return a->id < b->id; });
// DECISION 0041 stage 1: a literal block on `times`, `upto`, `downto`,
// `each` or `each_with_index` is a loop. Its BlockNode and parameter
// nodes are admitted BY POSITION, as `core_fail`'s operands are, and
// every other block is refused with the reason BlockLoops.cpp gives.
{
  auto lookup = [&](int64_t id) -> const Node * {
    auto found = nodes_.find(id);
    return found == nodes_.end() ? nullptr : found->second;
  };
  for (const Node *node : bodyNodes) {
    core::BlockLoopShape shape = core::classifyBlockLoop(*node, lookup);
    if (shape.refusal)
      return rejectNode(node->id, "unsupported-block", *shape.refusal);
    if (!shape.loop) continue;
    blockLoopCalls_.insert(node->id);
    blockConsumed_.insert(shape.loop->structural.begin(),
                          shape.loop->structural.end());
  }
  if (auto shadow =
          core::findShadowedParameter(*definitions_.at(name).node, lookup))
    return rejectNode(shadow->node, "unsupported-block",
                      "the block's `" + shadow->name +
                          "` has the name of a local of an enclosing "
                          "scope; Ruby would make it a variable of its "
                          "own, and this subset gives a method one "
                          "variable per name. Rename it");
}
      for (const Node *node : bodyNodes) {
        if (!validateNode(*node))
          return nullptr;
        if (node->kind != "CallNode")
          continue;
        int64_t receiver = -1;
        std::string callee;
        if (!getReference(*node, "receiver", receiver) ||
            !getString(*node, "name", callee))
          return rejectNode(node->id, "unsupported-node", node->kind);
        if (!isSupportedCallOperator(*node))
          return rejectNode(node->id, "unsupported-node", node->kind);
        // DECISION 0041: the loop's receiver, limit and body are walked as
        // ordinary nodes; the call itself is the loop, not an operator.
        if (blockLoopCalls_.count(node->id))
          continue;
        // DECISION 0014: `Module.fn(...)` on a declared extern module is a
        // call the generator lowers to `llvm.call`; it is not an operator and
        // it adds nothing to the closure.
        if (receiver >= 0 && options_.application) {
          auto recv = nodes_.find(receiver);
          std::string module;
          if (recv != nodes_.end() && recv->second->kind == "ConstantReadNode" &&
              getString(*recv->second, "name", module) &&
              options_.isAppExternModule(module)) {
            if (!options_.appExtern(module, callee))
              return rejectNode(node->id, "unresolved-call", quote(module + "." + callee));
            continue;
          }
        }
        // DECISION 0041 STAGE 2: `Array.new` and an array's `size`, only
        // where the contract declares a data stack; the checker admitted
        // each against its shape before this ran.
        if (receiver >= 0 && options_.status.scratchBytes != 0) {
          auto recv = nodes_.find(receiver);
          std::string constant;
          if (callee == "new" && recv != nodes_.end() &&
              recv->second->kind == "ConstantReadNode" &&
              getString(*recv->second, "name", constant) && constant == "Array")
            continue;
          if (callee == "size" && recv != nodes_.end() &&
              recv->second->kind == "LocalVariableReadNode")
            continue;
        }
        if (receiver >= 0 && !isSupportedOperator(callee))
          return rejectNode(node->id, "unsupported-node", node->kind);
        if (receiver < 0 && options_.freestandingTypes &&
            options_.extern_(callee))
          continue;
        if (isCoreFailCall(*node) || isIntrinsicCall(*node))
          continue;
      }
    }

    return ScalarProgramBuilder::program(
        module_.sourceFile().str(), std::move(entryCopy),
        std::move(selectedMethods), std::move(selectedCalls));
  }

  // Admit only a, b = rhs1, rhs2. Splats (nonempty rights), nesting, arity mismatch and nonlocal
  // targets remain unsupported-node.
  bool validateMultiWrite(const Node &node) {
    std::vector<int64_t> lefts, rights;
    int64_t valueId = -1;
    if (!getArray(node, "lefts", lefts) || !getArray(node, "rights", rights) ||
        !getReference(node, "value", valueId) || valueId < 0)
      return failNode(node.id, "unsupported-node", node.kind);
    if (!rights.empty() || lefts.size() < 2)
      return failNode(node.id, "unsupported-node", node.kind);
    for (int64_t id : lefts) {
      auto it = nodes_.find(id);
      if (it == nodes_.end() || it->second->kind != "LocalVariableTargetNode")
        return failNode(node.id, "unsupported-node", node.kind);
    }
    auto value = nodes_.find(valueId);
    if (value == nodes_.end() || value->second->kind != "ArrayNode")
      return failNode(node.id, "unsupported-node", node.kind);
    std::vector<int64_t> elements;
    if (!getArray(*value->second, "elements", elements) ||
        elements.size() != lefts.size())
      return failNode(node.id, "unsupported-node", node.kind);
    multiWriteConsumed_.insert(lefts.begin(), lefts.end());
    multiWriteConsumed_.insert(valueId);
    return true;
  }

private:
  std::unique_ptr<ScalarProgram> reject(int64_t line, StringRef category,
                                        StringRef detail) {
    diag_((Twine("scalar:") + Twine(line) + ": " + category + ": " + detail)
              .str());
    return nullptr;
  }

  bool fail(int64_t line, StringRef category, StringRef detail) {
    reject(line, category, detail);
    return false;
  }

  std::unique_ptr<ScalarProgram> rejectNode(int64_t id, StringRef category,
                                            StringRef detail) {
    return reject(lineOf(id), category, detail);
  }

  bool failNode(int64_t id, StringRef category, StringRef detail) {
    return fail(lineOf(id), category, detail);
  }

  int64_t lineOf(int64_t id) const {
    auto it = types_.find(id);
    return it == types_.end() ? 0 : it->second->line;
  }

  bool indexDefinitions() {
    auto root = nodes_.find(module_.root());
    if (root == nodes_.end())
      return fail(0, "unsupported-node", "ProgramNode");
    int64_t statementsId = -1;
    if (!getReference(*root->second, "statements", statementsId))
      return failNode(root->second->id, "unsupported-node", root->second->kind);
    auto statements = nodes_.find(statementsId);
    if (statements == nodes_.end())
      return failNode(statementsId, "unsupported-node", "StatementsNode");
    std::vector<int64_t> body;
    if (!getArray(*statements->second, "body", body))
      return failNode(statementsId, "unsupported-node", statements->second->kind);

    // A def the analysis left out because nothing names it
    // (contract::AnalysisRewrite::PrunedMethod) is no method of the analysed
    // program: it has no scope to bind, and no call can reach it by name.
    std::set<int64_t> pruned;
    for (const auto &rw : module_.analysisRewrites())
      if (rw.rewrite == AnalysisRewrite::Kind::PrunedMethod)
        pruned.insert(rw.id);

    for (int64_t id : body) {
      auto found = nodes_.find(id);
      if (found == nodes_.end() || found->second->kind != "DefNode")
        continue;
      if (pruned.count(id))
        continue;
      const Node &node = *found->second;
      int64_t receiver = 0;
      std::string name;
      if (!getReference(node, "receiver", receiver) ||
          !getString(node, "name", name))
        return failNode(id, "unsupported-node", node.kind);
      if (receiver != -1)
        continue;
      if (definitions_.count(name))
        return failNode(id, "duplicate-method", quote(name));
      int64_t parametersId = -1, bodyId = -1;
      if (!getReference(node, "parameters", parametersId) ||
          !getReference(node, "body", bodyId))
        return failNode(id, "unsupported-node", node.kind);
      // The method's own scope is read off a node that LIVES IN IT.  prism
      // builds no ParametersNode for a zero-argument `def` (both `def five`
      // and `def five()` come out as `R <def> parameters -1`), so the
      // parameters node cannot be the only anchor: the E160 binding rule names
      // the DefNode's parameter node OR its **body** node.  Falling back to the
      // body keeps zero-argument methods -- legitimate members of the subset,
      // which the frozen generator accepts -- bound to their real scope.
      // An empty body (-1 as well) has no node in the method's scope at all,
      // so there is nothing to read and the def stays a loud unsupported-node
      // rather than a guess.
      const int64_t scopeAnchor = parametersId >= 0 ? parametersId : bodyId;
      auto type = types_.find(scopeAnchor);
      if (type == types_.end())
        return failNode(id, "unsupported-node", node.kind);
      auto method = methods_.find(type->second->scope);
      if (method == methods_.end())
        return failNode(id, "unsupported-node", node.kind);
      definitions_.emplace(name, DefInfo{&node, method->second, lineOf(id), bodyId});
    }
    return true;
  }

  /// The SHAPE of the parameter list, which the `methods` face cannot answer.
  ///
  /// That face reports a flat `name:type` list and an arity, so `def k(n, m =
  /// 3)` arrives here indistinguishable from `def k(n, m)` — E018's
  /// reject/r10_optparam.rb, which the frozen generator refuses and which the
  /// selector accepted until this check existed.  The difference is not
  /// cosmetic: an optional parameter means the method has TWO arities and a
  /// default-value expression that runs in the callee, and `sp_k(i64, i64)`
  /// can express neither — a caller that omitted `m` would read whatever the
  /// second register happened to hold.
  ///
  /// The rule is total rather than a list of prism's parameter kinds: on a
  /// ParametersNode, `requireds` is the ONLY field that may be non-empty.
  /// Enumerating `optionals`/`keywords`/`posts`/`rest`/`block`/`keyword_rest`
  /// would silently admit whatever prism adds next; refusing everything else
  /// admits it only after someone decides it belongs (frozen: FuncGen's own
  /// parameter walk, which enumerates — this is the same rule, closed the
  /// other way round).
  bool validateParameterShape(StringRef name, const DefInfo &definition) {
    int64_t parametersId = -1;
    if (!getReference(*definition.node, "parameters", parametersId))
      return failNode(definition.node->id, "unsupported-node",
                      definition.node->kind);
    if (parametersId < 0)
      return true; // `def five` / `def five()`: no ParametersNode at all.
    auto found = nodes_.find(parametersId);
    if (found == nodes_.end())
      return failNode(parametersId, "unsupported-node", "ParametersNode");
    const Node &parameters = *found->second;

    size_t requireds = 0;
    for (const AstField &field : parameters.fields) {
      if (field.kind == AstField::Kind::Array) {
        const std::vector<int64_t> &items =
            std::get<std::vector<int64_t>>(field.value);
        if (field.key == "requireds") {
          requireds = items.size();
          for (int64_t item : items) {
            auto parameter = nodes_.find(item);
            if (parameter == nodes_.end() ||
                parameter->second->kind != "RequiredParameterNode")
              return fail(definition.line, "unsupported-node",
                          (Twine("'") + name + "': parameter kind " +
                           (parameter == nodes_.end()
                                ? Twine("<unknown node ") + Twine(item) + ">"
                                : Twine(parameter->second->kind)) +
                           " is not in the subset").str());
          }
          continue;
        }
        if (!items.empty())
          return fail(definition.line, "unsupported-node",
                      (Twine("'") + name +
                       "': only required positional parameters are supported "
                       "(found '" + field.key + "')").str());
        continue;
      }
      if (field.kind == AstField::Kind::Reference &&
          std::get<int64_t>(field.value) >= 0)
        return fail(definition.line, "unsupported-node",
                    (Twine("'") + name + "': '" + field.key +
                     "' parameters are not in the subset").str());
    }

    // The two faces have to agree about how many parameters there are.  They
    // are produced by one tool from one parse, so a disagreement is a broken
    // face rather than a rejected program — but it is still not something to
    // guess past, because the arity is what the emitted signature is made of.
    if (requireds != definition.method->parameters.size())
      return fail(definition.line, "unsupported-node",
                  (Twine("'") + name + "': the ast face has " +
                   Twine(requireds) + " required parameter(s) but the methods "
                   "face declares " +
                   Twine(definition.method->parameters.size())).str());
    return true;
  }

  /// DECISION 0044: what the calls lend one helper parameter.
  struct LentAcc {
    /// element -> the first call that lends it (caller, line)
    std::map<std::string, std::pair<std::string, int64_t>> elems;
    /// Every mode that reaches the parameter, through any chain of calls
    /// (review finding 1): `in`, `out` or `inout`, each with the first chain
    /// that brings it, for the refusals.
    std::map<std::string, std::string> modes;
    ScalarLentBuffer result(bool checked) const {
      ScalarLentBuffer out;
      out.elem = elems.empty() ? std::string() : elems.begin()->first;
      out.dir = modes.count("in") ? "in" : modes.count("out") ? "out" : "inout";
      out.checked = checked;
      if (auto in = modes.find("in"); in != modes.end()) out.inFrom = in->second;
      if (auto o = modes.find("out"); o != modes.end()) out.outFrom = o->second;
      return out;
    }
  };
  /// One buffer a function holds: its element, and every mode that reaches
  /// it, each with the chain that brings it.
  struct HeldBuffer {
    std::string elem;
    std::map<std::string, std::string> modes;
  };

  /// The index of `param` among `method`'s parameters, or -1.
  int paramIndex(const std::string &method, const std::string &param) const {
    auto d = definitions_.find(method);
    if (d == definitions_.end()) return -1;
    const auto &ps = d->second.method->parameters;
    for (size_t i = 0; i < ps.size(); ++i)
      if (ps[i].name == param) return static_cast<int>(i);
    return -1;
  }

  /// The buffer `method` holds in its parameter `index`: a declared buffer of
  /// an entry, or one its callers lend it (as derived so far).
  std::optional<HeldBuffer> heldBuffer(const std::string &method, size_t index) const {
    if (const ScalarRootDesc *root = options_.root(method)) {
      if (index < root->params.size() &&
          root->params[index].kind == ScalarParamDesc::Kind::Buffer)
        return HeldBuffer{root->params[index].elem,
                          {{root->params[index].dir,
                            (Twine("`") + paramName(method, index) + "`, an `:" +
                             root->params[index].dir + "` buffer of '" + method + "'")
                                .str()}}};
      return std::nullopt;
    }
    auto found = lent_.find({method, index});
    if (found == lent_.end() || found->second.elems.empty()) return std::nullopt;
    return HeldBuffer{found->second.elems.begin()->first, found->second.modes};
  }

  std::string paramName(const std::string &method, size_t i) const {
    auto d = definitions_.find(method);
    return d != definitions_.end() && i < d->second.method->parameters.size()
               ? d->second.method->parameters[i].name
               : std::string("?");
  }

  /// DECISION 0044, U1 (review finding 2): the methods some entry declared
  /// with checked bounds reaches through any chain of calls, through entry
  /// callees too. A helper skips its range check only when no checked entry
  /// reaches it.
  void computeCheckedReach(const std::vector<ScalarCallEdge> &calls) {
    std::map<std::string, std::vector<std::string>> out;
    std::set<std::string> methods;
    for (const ScalarCallEdge &c : calls) {
      out[c.caller().str()].push_back(c.callee().str());
      methods.insert(c.caller().str());
      methods.insert(c.callee().str());
    }
    for (const auto &[name, info] : definitions_) (void)info, methods.insert(name);
    std::vector<std::string> work;
    for (const std::string &m : methods)
      if (const ScalarRootDesc *r = options_.root(m); r && r->boundsChecked &&
                                                      checkedReach_.insert(m).second)
        work.push_back(m);
    while (!work.empty()) {
      std::string m = work.back();
      work.pop_back();
      for (const std::string &c : out[m])
        if (checkedReach_.insert(c).second) work.push_back(c);
    }
  }

  /// The buffer a call argument names, when it is a parameter of the caller
  /// that holds one, read by name.
  std::optional<HeldBuffer> argumentBuffer(const std::string &caller, int64_t argId,
                                           std::string *bufName = nullptr) const {
    auto a = nodes_.find(argId);
    std::string n;
    if (a == nodes_.end() || a->second->kind != "LocalVariableReadNode" ||
        !getString(*a->second, "name", n))
      return std::nullopt;
    const int j = paramIndex(caller, n);
    if (j < 0) return std::nullopt;
    if (bufName) *bufName = n;
    return heldBuffer(caller, static_cast<size_t>(j));
  }

  /// DECISION 0044 (D1, L1, B1 with U1): derive each helper parameter that
  /// its callers lend a buffer, from every call in the closure, to a fixed
  /// point -- a helper lends on what it was lent, and may call itself. Then
  /// refuse, by name, what the derivation cannot admit.
  bool deriveLentBuffers(const std::vector<ScalarCallEdge> &calls) {
    computeCheckedReach(calls);
    bool changed = true;
    while (changed) {
      changed = false;
      for (const ScalarCallEdge &call : calls) {
        const std::string caller = call.caller().str(), callee = call.callee().str();
        // An entry's own declaration decides each of its positions.
        if (options_.root(callee)) continue;
        for (size_t i = 0; i < call.argumentNodes().size(); ++i) {
          std::optional<HeldBuffer> held = argumentBuffer(caller, call.argumentNodes()[i]);
          if (!held) continue;
          LentAcc &acc = lent_[{callee, i}];
          if (acc.elems.emplace(held->elem, std::make_pair(caller, call.line())).second)
            changed = true;
          for (const auto &[mode, chain] : held->modes)
            if (acc.modes
                    .emplace(mode, (Twine(chain) + ", lent by the call at line " +
                                    Twine(call.line()) + " in '" + caller + "'")
                                       .str())
                    .second)
              changed = true;
        }
      }
    }
    for (const auto &[key, acc] : lent_) {
      if (acc.elems.size() < 2) continue;
      auto first = acc.elems.begin(), second = std::next(first);
      return fail(second->second.second, "lent-buffer",
                  (Twine("'") + key.first + "' parameter " + Twine(key.second) + " '" +
                   paramName(key.first, key.second) + "' is lent an :" + first->first +
                   " buffer by the call at line " + Twine(first->second.second) +
                   " in '" + first->second.first + "' and an :" + second->first +
                   " buffer by the call at line " + Twine(second->second.second) +
                   " in '" + second->second.first +
                   "'; a lent buffer has one element type (decision 0044)")
                      .str());
    }
    for (const ScalarCallEdge &call : calls) {
      const std::string caller = call.caller().str(), callee = call.callee().str();
      const ScalarRootDesc *root = options_.root(callee);
      for (size_t i = 0; i < call.argumentNodes().size(); ++i) {
        std::string bufName;
        std::optional<HeldBuffer> held =
            argumentBuffer(caller, call.argumentNodes()[i], &bufName);
        const std::string head = (Twine("argument ") + Twine(i) + " of '" + callee +
                                  "' at line " + Twine(call.line()) + " in '" +
                                  caller + "'").str();
        if (!root) {
          auto lent = lent_.find({callee, i});
          if (lent != lent_.end() && !held)
            return fail(call.line(), "lent-buffer",
                        head + " is not a buffer this function holds, named "
                               "directly, and another call lends a buffer "
                               "there; a lent parameter takes a buffer at "
                               "every call (decision 0044)");
          continue;
        }
        const bool declaredBuffer =
            i < root->params.size() &&
            root->params[i].kind == ScalarParamDesc::Kind::Buffer;
        if (!declaredBuffer) {
          if (held)
            return fail(call.line(), "lent-buffer",
                        head + " is the buffer `" + bufName + "`, and '" + callee +
                            "' declares a number there (decision 0044)");
          continue;
        }
        const ScalarParamDesc &want = root->params[i];
        if (!held)
          return fail(call.line(), "lent-buffer",
                      head + " must be a buffer this function holds, named "
                             "directly: '" + callee + "' declares [:" + want.elem +
                             "_buf, :" + want.dir + "] there (decision 0044)");
        if (held->elem != want.elem)
          return fail(call.line(), "lent-buffer",
                      head + " is the buffer `" + bufName + "`, an :" + held->elem +
                          " buffer, and '" + callee + "' declares [:" + want.elem +
                          "_buf, :" + want.dir + "] there; a lent buffer has "
                          "one element type (decision 0044)");
        // Review finding 1: the callee writes unless it declares `:in`, and
        // reads unless it declares `:out`; every mode that reaches here must
        // allow what it does.
        if (auto in = held->modes.find("in"); in != held->modes.end() && want.dir != "in")
          return fail(call.line(), "lent-buffer",
                      head + " is the buffer `" + bufName + "`, which is "
                             "read-only (:in) here (" + in->second + "), and '" +
                             callee + "' declares [:" + want.elem + "_buf, :" +
                             want.dir + "] there; a lent buffer keeps its mode "
                             "(decision 0044)");
        if (auto o = held->modes.find("out"); o != held->modes.end() && want.dir != "out")
          return fail(call.line(), "lent-buffer",
                      head + " is the buffer `" + bufName + "`, which is "
                             "write-only (:out) here (" + o->second + "), and '" +
                             callee + "' declares [:" + want.elem + "_buf, :" +
                             want.dir + "] there; a lent buffer keeps its mode "
                             "(decision 0044)");
      }
    }
    return true;
  }

  bool validateSignature(StringRef name, const DefInfo &definition,
                         std::vector<ScalarMethod> &out) {
    // Shape before types: the `methods` face's parameter list only MEANS
    // "the parameters" once every one of them is a required positional.
    if (!validateParameterShape(name, definition))
      return false;
    // freestandingTypes admits nonintegers using both inferred float/int_array/float_array and root
    // declarations. Neither alone suffices: an array parameter not declared as a boundary buffer is
    // a helper argument and historically remained refused.
    const ScalarRootDesc *root =
        options_.freestandingTypes ? options_.root(name) : nullptr;
    auto typedOk = [&](size_t index, StringRef ty) {
      if (!options_.status.entry.empty() && ty == "buffer") {
        // Accepted at a position the checker DERIVED a borrow for, and nowhere
        // else. For the entry that is the contract's own declaration; for a
        // helper it is what the calls that reach it pass. The position is
        // checked here as well rather than trusted across two pieces of code.
        if (index >= definition.method->parameters.size()) return false;
        if (name == options_.status.entry &&
            options_.status.buffer(definition.method->parameters[index].name))
          return true;
        return options_.borrow(name, index) != nullptr;
      }
      if (!options_.freestandingTypes)
        return ty == "int";
      if (ty == "int" || ty == "float")
        return true;
      if (ty != "int_array" && ty != "float_array")
        return false;
      // Arrays are accepted only in declared buffer positions, or, under decision 0044, where every
      // helper call lends a buffer.
      if (!root && lent_.count({name.str(), index}))
        return true;
      return root && index < root->params.size() &&
             root->params[index].kind == ScalarParamDesc::Kind::Buffer;
    };
    // The checker's derivation, when the contract supplied entry facts: the
    // producer has no signature to offer for a source nothing calls.
    auto signature = options_.derivedSignatures.find(name.str());
    const bool haveDerived =
        signature != options_.derivedSignatures.end() &&
        signature->second.first.size() == definition.method->parameters.size();
    std::vector<ScalarParameter> parameters;
    for (size_t index = 0; index < definition.method->parameters.size(); ++index) {
      const Parameter &parameter = definition.method->parameters[index];
      const std::string declared =
          haveDerived ? signature->second.first[index] : parameter.type;
      if (!typedOk(index, declared)) {
        std::ostringstream detail;
        detail << "'" << name.str() << "' parameter " << index << " '"
               << parameter.name << "' is " << typeWords(declared);
        const bool boxed = declared == "poly" || declared == "unknown";
        return fail(definition.line,
                    boxed ? "boxed-signature" : "non-integer-parameter",
                    detail.str());
      }
      std::optional<ScalarLentBuffer> lent;
      if (!root)
        if (auto found = lent_.find({name.str(), index}); found != lent_.end())
          lent = found->second.result(checkedReach_.count(name.str()) != 0);
      parameters.push_back(
          ScalarProgramBuilder::parameter(parameter.name, declared, std::move(lent)));
    }
    const std::string returnType =
        haveDerived ? signature->second.second : definition.method->returnType;
    // DECISION 0008 TASK 3: an INTERNAL helper may answer a boolean, which a
    // branch in this closure consumes. It never reaches the boundary -- the
    // entry's result is the contract's, and the eligibility checker refuses a
    // bool there by name.
    const bool internalBool = !options_.status.entry.empty() &&
                              name != options_.status.entry &&
                              returnType == "bool";
    const bool retOk = internalBool ||
                       (options_.freestandingTypes
                            ? (returnType == "int" || returnType == "float")
                            : returnType == "int");
    if (!retOk)
      return fail(definition.line, "non-integer-return",
                  (Twine("'") + name + "' returns " + typeWords(returnType)).str());
    // abi_scalar is the producer verdict for the hosted canonical value ABI (all mrb_int).
    // Freestanding declarations own f64/buffer boundaries, so freestandingTypes ignores it. With
    // supplied facts, an uncalled source has no inferred scalar signature; derivation already
    // establishes integer parameters/results. Treating an unknown "no" as refusal would reject
    // every caller-free contract.
    if (!options_.freestandingTypes && !haveDerived && !definition.method->scalarAbi)
      return fail(definition.line, "abi-mismatch",
                  (Twine("'") + name +
                   "' has an integer signature but abi_scalar is no").str());
    out.push_back(ScalarProgramBuilder::method(
        name.str(), definition.method->scope, definition.node->id,
        definition.line, std::move(parameters), returnType,
        definition.method->scalarAbi, checkedReach_.count(name.str()) != 0));
    return true;
  }

  void collectSubtree(int64_t id, std::vector<const Node *> &out) const {
    std::set<int64_t> seen;
    std::vector<int64_t> work{id};
    while (!work.empty()) {
      int64_t current = work.back();
      work.pop_back();
      if (current < 0 || !seen.insert(current).second)
        continue;
      auto found = nodes_.find(current);
      if (found == nodes_.end())
        continue;
      out.push_back(found->second);
      for (const AstField &field : found->second->fields) {
        if (field.kind == AstField::Kind::Reference) {
          int64_t child = std::get<int64_t>(field.value);
          if (child >= 0)
            work.push_back(child);
        } else if (field.kind == AstField::Kind::Array) {
          for (int64_t child : std::get<std::vector<int64_t>>(field.value))
            work.push_back(child);
        }
      }
    }
  }

  /// Decision 0022: a word intrinsic (spinel-mlir/Core/Intrinsics.h) is not a
  /// call into the closure either. It is recognised on the CORE routes -- a
  /// status entry, and since decision 0042 stage 4 `--core` (which sets
  /// `bitOperators`) and freestanding -- with no receiver, when the source
  /// defines no method of that name: the checkers refuse the other shapes by
  /// name, and a call this predicate declines falls through to the
  /// unresolved-call refusal. The hosted lanes keep the names ordinary.
  bool isIntrinsicCall(const Node &n) {
    if (options_.status.entry.empty() && !options_.freestandingTypes &&
        !options_.bitOperators)
      return false;
    if (n.kind != "CallNode") return false;
    int64_t receiver = -1;
    std::string name;
    if (!getReference(n, "receiver", receiver) || receiver >= 0) return false;
    if (!getString(n, "name", name) || !spinel_mlir::core::coreIntrinsic(name)) return false;
    return !definitions_.count(name);
  }

  /// Decision 0007 task 2: `core_fail(:<category>)` names one of the
  /// boundary's own failure statuses and returns it.
  ///
  /// It is NOT a call into the closure: there is no definition to find, and
  /// inventing one would put a function in the object the source never wrote.
  /// A top-level `def core_fail` is a conflict rather than a shadow -- the
  /// eligibility checker refuses it by name, and this predicate declines so
  /// that nothing here compiles a call to either of the two.
  bool isCoreFailCall(const Node &n) {
    if (options_.status.entry.empty()) return false;
    if (n.kind != "CallNode") return false;
    if (definitions_.count("core_fail")) return false;
    int64_t receiver = -1, block = -1, argumentsId = -1;
    std::string name;
    if (!getReference(n, "receiver", receiver) || receiver >= 0) return false;
    if (!getString(n, "name", name) || name != "core_fail") return false;
    if (!isSupportedCallOperator(n)) return false;
    if (!getReference(n, "block", block) || block >= 0) return false;
    if (!getReference(n, "arguments", argumentsId) || argumentsId < 0) return false;
    auto args = nodes_.find(argumentsId);
    if (args == nodes_.end() || args->second->kind != "ArgumentsNode") return false;
    std::vector<int64_t> values;
    if (!getArray(*args->second, "arguments", values) || values.size() != 1)
      return false;
    auto sym = nodes_.find(values[0]);
    if (sym == nodes_.end() || sym->second->kind != "SymbolNode") return false;
    std::string category;
    if (!getString(*sym->second, "value", category)) return false;
    // One spelling. Decision 0007's application-requested failure is
    // `core_fail(:capacity)`; the other internal categories belong to failures
    // the compiler establishes, and are not an application's to request.
    if (category != "capacity")
      return false;
    coreFailConsumed_.insert(n.id);
    coreFailConsumed_.insert(argumentsId);
    coreFailConsumed_.insert(values[0]);
    return true;
  }

  bool validateNode(const Node &node) {
    StringSet<> supported;
    for (StringRef kind : supportedNodeKinds(options_))
      supported.insert(kind);
    // Admit MultiWriteNode lefts (LocalVariableTargetNode) and value (Prism ArrayNode for
    // right-hand sides) by position only. Adding those kinds globally would also admit xs = [1, 2,
    // 3] and break r2_array refusal.
    if (multiWriteConsumed_.count(node.id))
      return true;
    if (coreFailConsumed_.count(node.id) || isCoreFailCall(node))
      return true;
    // DECISION 0041: a loop's call, block and parameter nodes.
    if (blockLoopCalls_.count(node.id) || blockConsumed_.count(node.id))
      return true;
    if (!supported.contains(node.kind))
      return failNode(node.id, "unsupported-node", node.kind);
    if (node.kind == "MultiWriteNode" && !validateMultiWrite(node))
      return false;
    if (node.kind == "LocalVariableReadNode" ||
        node.kind == "LocalVariableWriteNode" || node.kind == "IntegerNode" ||
        node.kind == "CallNode" || node.kind == "AndNode" ||
        node.kind == "OrNode" || node.kind == "ParenthesesNode") {
      // The checker's derivation, when the contract supplied entry facts.
      auto derived = options_.derivedTypes.find(node.id);
      if (derived != options_.derivedTypes.end())
        return derived->second == "unknown" || derived->second == "void"
                   ? failNode(node.id, "type-evidence", derived->second)
                   : true;
      auto type = types_.find(node.id);
      if (type != types_.end() &&
          (type->second->type == "unknown" || type->second->type == "void"))
        return failNode(node.id, "untyped-node", node.kind);
    }
    return true;
  }

  /// F-36: a CallNode carries the operator it was WRITTEN with, and the node
  /// kind alone does not distinguish `a.+(1)` from `a&.+(1)`.  Safe navigation
  /// is a conditional call -- `nil` short-circuits the whole expression -- so
  /// importing it as a plain arithmetic call would silently drop the nil arm
  /// and change the meaning of the program.  The frozen generator refuses it
  /// (`spinel-mlirgen.py`, MlirGen.call: `node.get("call_operator", ".") ==
  /// "&."` -> `Unsupported("safe navigation '&.'")`), so the selector must
  /// refuse it too rather than let it reach MlirGen as an ordinary call.
  ///
  /// The criterion is copied from there, including its default: an ABSENT
  /// field reads as `.`.  The pinned producer always wrote the field (exactly
  /// `.` or `&.`, issue #793).  Upstream (f5e8252ff) writes no operator and
  /// marks a safe navigation with the integer `safe_nav` instead, so that is
  /// read too: with no `call_operator`, an absent `safe_nav` (or 0) is `.`
  /// and `safe_nav` 1 is `&.`, refused exactly as the spelling was -- an
  /// absent operator must not become permission for the conditional call.
  /// A field that is PRESENT with any other spelling or value is
  /// outside the producer's closed set: it is refused loudly here rather than
  /// guessed at, the same way a malformed `arguments` or `parameters` field
  /// is.  That is stricter than the frozen generator, but only for faces the
  /// producer cannot emit -- the same asymmetry the hand-edited untyped-node
  /// and abi-mismatch fixtures already record.
  bool isSupportedCallOperator(const Node &node) const {
    if (findField(node, "safe_nav")) {
      int64_t v = 0;
      if (!ast::getInteger(node, "safe_nav", v) || v != 0)
        return false;
    }
    std::string callOperator;
    if (!getString(node, "call_operator", callOperator))
      return findField(node, "call_operator") == nullptr;
    return callOperator == ".";
  }

  bool isSupportedOperator(StringRef name) const {
    // Only freestandingTypes extends buffer indexing here. []/[]= are receiver-bearing CallNodes;
    // excluding them from this set would produce unsupported-node.
    if ((options_.freestandingTypes || !options_.status.entry.empty()) &&
        (name == "[]" || name == "[]="))
      return true;
    // Frozen hosted Python admits ! and +@; MlirGen already implemented +@ but this table
    // previously blocked it. mix uses !(m > 2) && n < 0. Historical decision 0007 task 2 admitted
    // shifts, bitwise operators and abs in the checked boundary because it can report domain
    // failures; other lanes then lacked that channel. Decision 0042 stage 3 adds ** there.
    if (!options_.status.entry.empty() &&
        (name == "<<" || name == ">>" || name == "&" || name == "|" ||
         name == "^" || name == "~" || name == "abs" || name == "**"))
      return true;
    // Decision 0042: on freestanding and on the native `--core` route, the
    // four exact bitwise operators (stage 1), which cannot fail, the shifts
    // (stage 2), and `abs` and `**` (stage 3), whose failures each of those
    // modes delivers its own way. The hosted lanes are unchanged.
    if ((options_.freestandingTypes || options_.bitOperators) &&
        (name == "&" || name == "|" || name == "^" || name == "~" ||
         name == "<<" || name == ">>" || name == "abs" || name == "**"))
      return true;
    return name == "+" || name == "-" || name == "*" || name == "/" ||
           name == "%" || name == "==" || name == "!=" || name == "<" ||
           name == "<=" || name == ">" || name == ">=" || name == "-@" ||
           name == "+@" || name == "!";
  }

  bool callArguments(const Node &call, std::vector<int64_t> &args,
                     int64_t &badNode) const {
    int64_t argumentsId = -1;
    if (!getReference(call, "arguments", argumentsId))
      return false;
    if (argumentsId < 0)
      return true;
    badNode = argumentsId;
    auto found = nodes_.find(argumentsId);
    return found != nodes_.end() && getArray(*found->second, "arguments", args);
  }

  ScalarImportOptions options_;
  std::set<int64_t> multiWriteConsumed_;
  /// The nodes `core_fail(:<category>)` accounts for: the call itself, its
  /// ArgumentsNode and the SymbolNode. Admitted BY POSITION, like the
  /// MultiWriteNode operands above -- putting SymbolNode in the closed set
  /// would admit `:anything` everywhere, and there is no symbol in this subset.
  std::set<int64_t> coreFailConsumed_;
  /// DECISION 0041: the CallNodes that are loops with a literal block, and
  /// the nodes those loops account for by position.
  std::set<int64_t> blockLoopCalls_;
  std::set<int64_t> blockConsumed_;
  /// DECISION 0044: (helper, parameter index) -> what its calls lend it.
  std::map<std::pair<std::string, size_t>, LentAcc> lent_;
  /// DECISION 0044, U1: the methods a checked entry reaches.
  std::set<std::string> checkedReach_;
  const ContractModule &module_;
  ScalarDiagnosticFn diag_;
  std::map<int64_t, const Node *> nodes_;
  std::map<int64_t, const NodeType *> types_;
  std::map<int64_t, const Method *> methods_;
  std::map<std::string, DefInfo> definitions_;
};

} // namespace

// ElseNode is the `else` arm of an `if` (E018 subset).  cp1's only conditional
// fixture was fib's MODIFIER if, which prism spells without one, so its absence
// here was invisible until the logic fixture landed.
//
// **This is the closed set** — "list what is allowed, refuse the rest".  E166
// CP4's core sweep reads it through the public accessor so that the freestanding
// tier check and the importer cannot disagree about what the subset is.
llvm::ArrayRef<llvm::StringRef> supportedNodeKinds(ScalarImportOptions options) {
  // Decision 0007 task 2 admits a literal scalar constant. Only for the status
  // ABI: the other lanes have no way to resolve one, and a `ConstantReadNode`
  // there is still a runtime lookup.
  // The default seventeen, plus `ConstantReadNode` and nothing else. Written
  // out rather than appended to `kKinds`, because that array is a prefix
  // arrangement whose lengths are asserted, and because the two sets are
  // allowed to diverge: `FloatNode` is the freestanding lane's and stays there.
  static const llvm::StringRef kStatusKinds[] = {
      "StatementsNode", "ArgumentsNode", "IfNode", "ElseNode", "ReturnNode",
      "CallNode", "IntegerNode", "LocalVariableReadNode",
      "LocalVariableWriteNode", "WhileNode", "AndNode", "OrNode",
      "ParenthesesNode", "MultiWriteNode", "LocalVariableOperatorWriteNode",
      "UnlessNode", "UntilNode", "ConstantReadNode",
      // DECISION 0008 TASK 4: `break` and `next`, without values, leaving or
      // restarting the nearest loop. Only on this lane: the other lanes have
      // no loop-control lowering and a `break` there is still an unsupported
      // node.
      "BreakNode", "NextNode",
      // DECISION 0008 TASK 4: `buf[i] op= v`, evaluated once and stored only
      // if every check passes.
      "IndexOperatorWriteNode",
      // DECISION 0008 TASK 4: the two boolean literals, which `&&` and `||`
      // need and which an internal boolean helper answers with.
      "TrueNode", "FalseNode"};
  static_assert(sizeof(kStatusKinds) / sizeof(llvm::StringRef) == 23, "");
  // DECISION 0014 §7: an application entry admits a string literal, as
  // constant bytes in the one position the checker allowed it. The status set
  // plus that one kind; nothing else widens.
  static const llvm::StringRef kApplicationKinds[] = {
      "StatementsNode", "ArgumentsNode", "IfNode", "ElseNode", "ReturnNode",
      "CallNode", "IntegerNode", "LocalVariableReadNode",
      "LocalVariableWriteNode", "WhileNode", "AndNode", "OrNode",
      "ParenthesesNode", "MultiWriteNode", "LocalVariableOperatorWriteNode",
      "UnlessNode", "UntilNode", "ConstantReadNode",
      "BreakNode", "NextNode", "IndexOperatorWriteNode", "TrueNode", "FalseNode",
      "StringNode",
      // DECISION 0014 D5: a single-level `Mod::NAME`, the board package's
      // notation for its constants. The eligibility checker decides which
      // paths resolve; a deeper one is refused there by name.
      "ConstantPathNode"};
  static_assert(sizeof(kApplicationKinds) / sizeof(llvm::StringRef) == 25, "");
  if (options.application) return kApplicationKinds;
  if (!options.status.entry.empty()) return kStatusKinds;
  static const llvm::StringRef kKinds[] = {
      "StatementsNode", "ArgumentsNode", "IfNode", "ElseNode", "ReturnNode",
      "CallNode", "IntegerNode", "LocalVariableReadNode",
      "LocalVariableWriteNode", "WhileNode", "AndNode", "OrNode",
      "ParenthesesNode",
      // These two kinds were first freestanding-only and later entered the default set, matching
      // frozen hosted Python. gcd/bench_gcd/bench_tak previously failed solely on this kind.
      // ArrayNode/LocalVariableTargetNode remain positionally admitted only; r2_array is the
      // control.
      "MultiWriteNode", "LocalVariableOperatorWriteNode",
      // unless/until swap if/while arms and use the same walker.
      "UnlessNode", "UntilNode",
      // FloatNode is freestandingTypes-only, the sole remaining flag difference; add nothing after
      // it.
      "FloatNode"};
  static_assert(sizeof(kKinds) / sizeof(llvm::StringRef) == 18, "");
  // Represent the default set as the first seventeen entries; freestandingTypes appends FloatNode.
  if (options.freestandingTypes)
    return llvm::ArrayRef<llvm::StringRef>(kKinds, 18);
  return llvm::ArrayRef<llvm::StringRef>(kKinds, 17);
}

std::unique_ptr<ScalarProgram>
selectScalarProgram(const ContractModule &module,
                    ArrayRef<std::string> entryNames,
                    ScalarDiagnosticFn diag, ScalarImportOptions options) {
  return Selector(module, diag, options).run(entryNames);
}

void printSelection(const ScalarProgram &program, raw_ostream &os) {
  os << "source " << program.sourceFile() << "\n";
  for (const std::string &entry : program.entries())
    os << "entry " << entry << "\n";
  for (const ScalarMethod &method : program.methods()) {
    os << "method " << method.name() << " scope=" << method.scope()
       << " def_node=" << method.defNode() << " line=" << method.line() << "\n";
    for (auto indexed : enumerate(method.parameters()))
      os << "  param " << indexed.index() << " " << indexed.value().name()
         << " " << indexed.value().type() << "\n";
    os << "  return " << method.returnType() << "\n";
    os << "  abi " << (method.scalarAbi() ? "scalar" : "boxed") << "\n";
  }
  for (const ScalarCallEdge &call : program.calls()) {
    os << "call " << call.caller() << " -> " << call.callee()
       << " node=" << call.callNode() << " line=" << call.line() << " args=";
    if (call.argumentNodes().empty())
      os << "-";
    else
      for (auto indexed : enumerate(call.argumentNodes())) {
        if (indexed.index())
          os << ",";
        os << indexed.value();
      }
    os << "\n";
  }
}

} // namespace spinel_mlir::scalar
