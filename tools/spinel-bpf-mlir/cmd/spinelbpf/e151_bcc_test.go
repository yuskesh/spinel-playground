package main

import "testing"

// TestBccSelftestExecsnoop は E151 の H7 (P028 — execsnoop の selftest と実用の形)。
func TestBccSelftestExecsnoop(t *testing.T) { bccSelftest(t, "bcc/execsnoop") }
