#include "spinel/Conversion/ConsumerExtensions.h"
namespace spinel::consumer {
#define SPINEL_CONSUMER_GROUP(name) void name(Registry &);
#include "spinel/Conversion/ConsumerGroups.def"
#undef SPINEL_CONSUMER_GROUP
void registerConsumerGroups(Registry &registry) {
#define SPINEL_CONSUMER_GROUP(name) name(registry);
#include "spinel/Conversion/ConsumerGroups.def"
#undef SPINEL_CONSUMER_GROUP
}
} // namespace spinel::consumer
