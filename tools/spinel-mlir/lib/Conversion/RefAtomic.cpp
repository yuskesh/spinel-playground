#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/Subprograms.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"

namespace spinel::consumer {
namespace {
Dispatch<StatementResult> refAtomic(Consumer &c, ArrayRef<Operation *> list,
                                    size_t index, unsigned) {
  auto node = list[index];
  auto receiver = c.ref(node,"receiver");
  if (field(node,"strings","name") != "atomic_add" ||
      text(receiver,"kind") != "LocalVariableReadNode") return Dispatch<StatementResult>::declined();
  auto local = field(receiver,"strings","name").str();
  auto borrowed = c.borrows.find(local);
  if (borrowed == c.borrows.end()) return Dispatch<StatementResult>::declined();
  // Nested dispatch restores the borrows map. Keep an owned descriptor.
  const Borrow borrow = borrowed->second;
  size_t map = borrow.map;
  if (map >= c.maps.size()) return (void)c.error(node,"scalar borrowed atomic map is invalid"), Dispatch<StatementResult>::error();
  const auto &declaration = c.maps[map];
  if (!declaration.valueRecord.empty()) return Dispatch<StatementResult>::declined();
  if (declaration.kind == "lpm_trie")
    return (void)c.diagnostic(node,"SB002","UnsupportedCall","`" + local +
        ".atomic_add` is not accepted on lpm_trie " + declaration.name +
        " — an lpm_trie is read-only on the eBPF side (read the value with `" + local +
        ".load`; user space writes it with `obj.lpm_put`) (E121)",true), Dispatch<StatementResult>::error();
  CalleePolicy policy{"MapRef#atomic_add"};
  policy.requireCallee = false;
  if (failed(c.known(node,policy))) return Dispatch<StatementResult>::error();
  auto callee = text(c.evidence[c.id(node)].front(),"callee");
  if (callee != policy.expected)
    return (void)c.diagnostic(node,"SB011","ShadowedName","`atomic_add` resolves to " +
        callee.str() + ", not BPF::MapRef#atomic_add",true), Dispatch<StatementResult>::error();
  auto args = c.args(node);
  if (args.size() != 1)
    return (void)c.diagnostic(node,"SB002","UnsupportedCall","`" + local +
        ".atomic_add` takes one delta (`" + local + ".atomic_add(d)`) (P008 §2)",true), Dispatch<StatementResult>::error();
  auto reads = c.origins(args[0]);
  if (llvm::any_of(reads,[&](const ReadOrigin &read) {
        return read.domain == ReadOrigin::Domain::Map && read.ref == local;
      }))
    return (void)c.diagnostic(node,"SB019","SharedReadModifyWrite","`" + local +
        ".atomic_add` adds a value read from the same entry — use a delta that does not read `" + local +
        "` (P008 §2)",true), Dispatch<StatementResult>::error();
  auto value = c.scalar(args[0]);
  if (failed(value) || failed(c.checked(range::checkStoreValue((*value)->range,
      c.rangeMap(map),{c.id(args[0])},"delta"),args[0]))) return Dispatch<StatementResult>::error();
  if (failed(noteSubprogramWrite(c,node,
      {map,borrow.key,local,ReadOrigin::Domain::Map},reads))) return Dispatch<StatementResult>::error();
  if (!c.probing) {
    auto delta = c.scalarStore(*value,map);
    if (!delta || !borrow.value)
      return (void)c.error(node,"scalar borrowed atomic value is missing"), Dispatch<StatementResult>::error();
    ebpf::RefAtomicAddOp::create(c.builder,outputLoc(node),borrow.value,delta);
  }
  return Dispatch<StatementResult>::handled({1});
}
} // namespace
void registerRefAtomic(Registry &registry) { registry.addStatement("CallNode",refAtomic); }
} // namespace spinel::consumer
