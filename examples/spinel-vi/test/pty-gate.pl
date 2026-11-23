#!/usr/bin/env perl
# macOS has Perl and script(1) in its base system.  This helper gives each
# real-terminal probe its own session/process group so a stuck tb_poll_event
# cannot escape the gate's deadline.
use strict;
use warnings;
use POSIX qw(setsid);

my ($typescript, $binary, $out, $case, $mode, $delay) = @ARGV;
die "usage: pty-gate.pl TYPESCRIPT BINARY OUT CASE MODE DELAY\n"
    unless defined $delay;
my $deadline = $ENV{SPINEL_VI_E097_PTY_DEADLINE} // 8;
die "E097 pty watchdog: deadline must be a positive integer\n"
    unless $deadline =~ /\A[1-9][0-9]*\z/;

my $pid = fork();
die "E097 pty watchdog: fork failed: $!\n" unless defined $pid;
if ($pid == 0) {
    setsid() == -1 and die "E097 pty watchdog: setsid failed: $!\n";
    exec "/bin/sh", "-c", q{
        ( sleep "$5"
          case "$3" in
            basic) printf "x" ;;
            input) printf "x\022\343\201\202" ;;
            resize) : ;;
            *) echo "unknown E097 PTY case: $3" >&2; exit 64 ;;
          esac
        ) | script -q "$0" /bin/sh -c '
          before=$(stty -g)
          if [ "$1" = "-" ]; then
            TERM=xterm-256color SPINEL_VI_BACKEND=termbox2 "$0"
          else
            TERM=xterm-256color SPINEL_VI_BACKEND=termbox2 "$0" "$1"
          fi
          app_rc=$?
          after=$(stty -g)
          test "$before" = "$after" && echo TERM_RESTORED
          exit "$app_rc"
        ' "$1" "$4" > "$2"
    }, $typescript, $binary, $out, $case, $mode, $delay;
    die "E097 pty watchdog: exec failed: $!\n";
}

my $status;
my $completed = eval {
    local $SIG{ALRM} = sub { die "deadline\n" };
    alarm $deadline;
    waitpid($pid, 0);
    $status = $?;
    alarm 0;
    1;
};
if (!$completed) {
    alarm 0;
    kill "TERM", -$pid;
    select undef, undef, undef, 0.20;
    kill "KILL", -$pid;
    waitpid($pid, 0);
    print STDERR "E097 pty watchdog: deadline exceeded; process group reaped\n";
    exit 124;
}
exit(($status & 127) ? 128 + ($status & 127) : ($status >> 8));
