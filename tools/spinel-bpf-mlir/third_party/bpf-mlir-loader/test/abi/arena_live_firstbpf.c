/*
 * E063 preroot (G5a): stop the real arena_live + real libbml at the first bpf(2).
 *
 * Linked with -Wl,--wrap=syscall next to the same objects as build/tools/arena_live
 * (arena_live.c, arena_live_wrap.c, libbml.a, libbpf.a, ...). libbpf issues every BPF
 * command through syscall(__NR_bpf, cmd, attr, size); the first such call is recorded as
 * "first-bpf cmd=<n>" on stderr and the process exits 42 without calling bpf(). Every
 * other syscall() passes through unchanged. Everything before that point (argument and
 * file reads, the ELF, the SHA, the map declarations, the precheck parse) is the real code.
 * Nothing here talks to the kernel's BPF subsystem; non-root hosts reject bpf() anyway
 * (kernel.unprivileged_bpf_disabled=2), so reaching the wrap is the observation.
 */
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>

#define FIRSTBPF_EXIT 42

long __real_syscall(long number, ...);

long __wrap_syscall(long number, ...)
{
	va_list ap;
	long a[6];
	va_start(ap, number);
	for (int i = 0; i < 6; i++)
		a[i] = va_arg(ap, long);
	va_end(ap);
	if (number == __NR_bpf) {
		dprintf(2, "first-bpf cmd=%ld\n", a[0]);
		_exit(FIRSTBPF_EXIT);
	}
	return __real_syscall(number, a[0], a[1], a[2], a[3], a[4], a[5]);
}
