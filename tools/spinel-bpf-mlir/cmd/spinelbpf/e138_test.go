package main

import "testing"

// E138 の試験 (P027): bcc の tool の root の selftest — 共有の器は e133_test.go。

// E138 の H4 / H5。
func TestBccSelftestTcplife(t *testing.T)   { bccSelftest(t, "bcc/tcplife") }
func TestBccSelftestTcpstates(t *testing.T) { bccSelftest(t, "bcc/tcpstates") }
