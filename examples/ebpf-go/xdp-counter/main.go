//go:build linux

// xdp-counter — **外部 .bpf.o を持たない単一 Go バイナリ** (E153 / P013 Task 6)。
//
// ELF は go:embed で中に入っている。実行時に MLIR も clang も cgo も要らない。
//
//	xdp-counter -iface eth0 [-duration 5s]
//
// 権限: XDP の attach は **root 不要、CAP_BPF + CAP_NET_ADMIN で足りる**
// (results/E153/kernel_env.md の実測)。
package main

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
	"github.com/cilium/ebpf/ringbuf"
	"github.com/cilium/ebpf/rlimit"
)

func main() {
	iface := flag.String("iface", "", "the network interface to attach to")
	duration := flag.Duration("duration", 0, "run for this long, then stop (0 = until Ctrl-C)")
	parseOnly := flag.Bool("parse-only", false, "check only that the embedded ELF parses, without touching the kernel")
	flag.Parse()

	if *parseOnly {
		spec, err := LoadCollectionSpec()
		if err != nil {
			log.Fatalf("cannot parse the embedded ELF: %v", err)
		}
		fmt.Printf("parse-ok programs=%d maps=%d elf=%d bytes\n",
			len(spec.Programs), len(spec.Maps), len(ObjectELF()))
		return
	}
	if *iface == "" {
		log.Fatal("-iface is required (for a check that does not touch the kernel, -parse-only)")
	}

	if err := rlimit.RemoveMemlock(); err != nil {
		log.Fatalf("RemoveMemlock: %v", err)
	}

	var objs Objects
	if err := LoadObjects(&objs, nil); err != nil {
		// **verifier の拒否を素の -EACCES で終わらせない** (P013 Task 6 checkbox)。
		log.Fatal(explainLoadError(err))
	}
	defer func() {
		if err := objs.Close(); err != nil {
			log.Printf("close: %v", err)
		}
	}()

	dev, err := netInterface(*iface)
	if err != nil {
		log.Fatal(err)
	}
	xdp, err := link.AttachXDP(link.XDPOptions{
		Program: objs.CountPackets, Interface: dev,
	})
	if err != nil {
		log.Fatalf("cannot attach XDP to %s: %v", *iface, err)
	}
	defer xdp.Close()

	rd, err := ringbuf.NewReader(objs.Events)
	if err != nil {
		log.Fatalf("cannot open the ring buffer: %v", err)
	}
	defer rd.Close()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	deadline := time.Now().Add(*duration)

	go func() {
		for {
			rec, err := rd.Read()
			if errors.Is(err, ringbuf.ErrClosed) {
				return
			}
			if err != nil {
				log.Printf("ring buffer: %v", err)
				continue
			}
			var t Tick
			if err := t.Decode(rec.RawSample); err != nil {
				log.Printf("decode: %v", err)
				continue
			}
			fmt.Printf("tick count=%d\n", t.Count)
		}
	}()

	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			printCounter(objs.Counts)
			return
		case <-ticker.C:
			printCounter(objs.Counts)
			if *duration > 0 && time.Now().After(deadline) {
				return
			}
		}
	}
}

func printCounter(m *ebpf.Map) {
	var v uint64
	if err := m.Lookup(uint32(0), &v); err != nil {
		log.Printf("cannot read the counter: %v", err)
		return
	}
	fmt.Printf("counter=%d\n", v)
}

// explainLoadError は verifier の拒否を **どの program のどこか**が分かる形にする。
// cilium/ebpf は *ebpf.VerifierError に kernel の log をそのまま入れている。
func explainLoadError(err error) string {
	var ve *ebpf.VerifierError
	if !errors.As(err, &ve) {
		return fmt.Sprintf("cannot load the embedded ELF: %v", err)
	}
	return fmt.Sprintf(`the kernel verifier rejected it.

  program : %s (core.programs in the schema, section "xdp")
  subject : the %d-byte ELF embedded in this binary
  canon   : schema.json — it decides the program and map declarations

what the kernel says:
%+v

how to read it: the instruction numbers match the output of "spbpf-opt --convert-spbpf-to-llvm".
The .mlir it comes from is xdp_counter.mlir, which comes from bpfgen/main.go.`,
		"count_packets", len(ObjectELF()), ve)
}

// netInterface は ifindex を **sysfs から**読む。
//
// `net.InterfaceByName` を使うと `net` 経由で `runtime/cgo` が依存に入り、
// 「Go 経路に cgo を要求しない」(P013 Global Constraints) が破れる — 実測で踏んだ。
// ifindex は /sys/class/net/<name>/ifindex に十進で書いてあるので、それで足りる。
func netInterface(name string) (int, error) {
	b, err := os.ReadFile("/sys/class/net/" + name + "/ifindex")
	if err != nil {
		return 0, fmt.Errorf("interface %q not found: %w", name, err)
	}
	idx, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		return 0, fmt.Errorf("cannot read the ifindex of interface %q: %w", name, err)
	}
	return idx, nil
}
