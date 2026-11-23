#pragma once
#include <netinet/in.h>
#define INET_ADDRSTRLEN 16
#define INET6_ADDRSTRLEN 46
const char *inet_ntop(int,const void*,char*,socklen_t); int inet_pton(int,const char*,void*);
in_addr_t inet_addr(const char*);
