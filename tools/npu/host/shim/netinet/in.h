#pragma once
#include <stdint.h>
#include <sys/socket.h>
#define IPPROTO_TCP 6
#define IPPROTO_UDP 17
#define IPPROTO_IP 0
#define IPPROTO_IPV6 41
#define INADDR_ANY 0u
#define INADDR_LOOPBACK 0x7f000001u
typedef uint16_t in_port_t; typedef uint32_t in_addr_t;
struct in_addr { in_addr_t s_addr; };
struct sockaddr_in { sa_family_t sin_family; in_port_t sin_port; struct in_addr sin_addr; char sin_zero[8]; };
struct in6_addr { uint8_t s6_addr[16]; };
struct sockaddr_in6 { sa_family_t sin6_family; in_port_t sin6_port; uint32_t sin6_flowinfo; struct in6_addr sin6_addr; uint32_t sin6_scope_id; };
uint16_t htons(uint16_t); uint16_t ntohs(uint16_t); uint32_t htonl(uint32_t); uint32_t ntohl(uint32_t);
