#include "spinel/Conversion/Consumer.h"
namespace spinel::consumer {
// Negative declaration only: analyze.go:874-904. Registering the constructor
// also makes select() visit it; a rejection hidden in run's fallback cannot.
// E020 owns valid DevMap declarations and their lowering.
void registerDeclarationRejections(Registry &registry) {
  registry.addDeclaration({"BPF::DevMap", "new"},
      [](Consumer &c, Operation *node) {
        auto call = c.ref(node, "value");
        auto as = c.args(call);
        auto name = field(node, "strings", "name");
        if (as.size() != 3 || text(as[0], "kind") != "StringNode" ||
            c.spelling(as[0], false) != name ||
            text(as[1], "kind") != "SymbolNode" ||
            text(as[2], "kind") != "IntegerNode" ||
            c.spelling(as[1], true) == "u32")
          return Dispatch<bool>::declined();
        (void)c.diagnostic(as[1], "SB013", "MapDeclShape",
                          "the value type of a devmap is :u32 (an ifindex), "
                          "got :" + c.spelling(as[1], true).str() + " (E124)");
        return Dispatch<bool>::error();
      });
}
} // namespace spinel::consumer
