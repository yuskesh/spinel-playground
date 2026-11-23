/* wasm32-wasi (preview 1): the socket options wasi-libc's header leaves out
   and the UNIX-domain family it has no address for. The calls that need
   them fail in the host with ENOTSUP (see ../signal.h here). */
#ifndef SP_WASI_SYS_SOCKET_H
#define SP_WASI_SYS_SOCKET_H
#include <stdint.h>
#include <sys/types.h>
typedef uint32_t socklen_t; typedef unsigned short sa_family_t; struct sockaddr { sa_family_t sa_family; char sa_data[14]; }; struct sockaddr_storage { sa_family_t ss_family; char d[126]; }; struct iovec { void *iov_base; size_t iov_len; }; struct msghdr { void *msg_name; socklen_t msg_namelen; struct iovec *msg_iov; int msg_iovlen; void *msg_control; socklen_t msg_controllen; int msg_flags; };
#ifndef SO_REUSEADDR
#define SO_REUSEADDR 2
#endif
#ifndef SO_ERROR
#define SO_ERROR 4
#endif
#ifndef SO_BROADCAST
#define SO_BROADCAST 6
#endif
#ifndef SO_SNDBUF
#define SO_SNDBUF 7
#endif
#ifndef SO_RCVBUF
#define SO_RCVBUF 8
#endif
#ifndef SO_KEEPALIVE
#define SO_KEEPALIVE 9
#endif
#ifndef SO_LINGER
#define SO_LINGER 13
#endif
#ifndef PF_UNIX
#define PF_UNIX 1
#endif
#ifndef AF_UNIX
#define AF_UNIX PF_UNIX
#endif
int socket(int, int, int);
int bind(int, const struct sockaddr *, socklen_t);
int listen(int, int);
int connect(int, const struct sockaddr *, socklen_t);
int setsockopt(int, int, int, const void *, socklen_t);
int socketpair(int, int, int, int [2]);
/* listen(2)'s backlog hint, which wasi-libc leaves out (sp_net.c's
   Socket.tcp_server_sockets, #8541); the call fails there as the others do */
#ifndef SOMAXCONN
#define SOMAXCONN 128
#endif
#endif
#ifndef AF_INET
#define AF_UNSPEC 0
#define AF_UNIX 1
#define AF_INET 2
#define AF_INET6 10
#define PF_INET AF_INET
#define PF_INET6 AF_INET6
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOL_SOCKET 1
#define SHUT_RD 0
#define SHUT_WR 1
#define SHUT_RDWR 2
#define MSG_PEEK 2
#define MSG_DONTWAIT 0x40
#define MSG_NOSIGNAL 0x4000
int socket(int,int,int); int bind(int,const struct sockaddr*,socklen_t); int listen(int,int);
int accept(int,struct sockaddr*,socklen_t*); int connect(int,const struct sockaddr*,socklen_t);
ssize_t send(int,const void*,size_t,int); ssize_t recv(int,void*,size_t,int);
ssize_t sendto(int,const void*,size_t,int,const struct sockaddr*,socklen_t);
ssize_t recvfrom(int,void*,size_t,int,struct sockaddr*,socklen_t*);
int shutdown(int,int); int getsockopt(int,int,int,void*,socklen_t*); int setsockopt(int,int,int,const void*,socklen_t);
int getsockname(int,struct sockaddr*,socklen_t*); int getpeername(int,struct sockaddr*,socklen_t*);
#endif
#define SO_TYPE 3
#define PF_UNSPEC 0
