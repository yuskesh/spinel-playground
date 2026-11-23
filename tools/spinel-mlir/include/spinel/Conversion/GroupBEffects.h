#pragma once
#include "spinel/Conversion/Consumer.h"
namespace spinel::consumer::groupb {
struct MapEffect { Operation *node=nullptr; size_t map=0; Expr key,value; bool update=false; };
Dispatch<MapEffect> checkMapEffect(Consumer &,Operation *);
LogicalResult emitMapEffect(Consumer &,const MapEffect &);
}
