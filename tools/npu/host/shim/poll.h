#pragma once
#define POLLIN 1
#define POLLOUT 4
#define POLLERR 8
#define POLLHUP 16
#define POLLNVAL 32
#define POLLPRI 2
typedef unsigned nfds_t;
struct pollfd { int fd; short events; short revents; };
int poll(struct pollfd *, nfds_t, int);
