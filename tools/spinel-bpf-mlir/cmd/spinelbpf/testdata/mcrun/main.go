// mcrun は E022 の H4 の runner (試験だけ — 利用者の API ではない): ELF を cilium で load し、全ての CPU で同時に XDP の test run を
// repeat 回ずつ回して、record の map Cs[0] の n (atomic_add) と m (load / add / store) を出す (bpf-mlir E251 の fieldatomic の形)。
//
//	mcrun <ELF> <repeat>
//	mcrun percpu <ELF> <repeat>   (E039 — thread を CPU に固定し getcpu で確かめ、P[0] の CPU ごとの n / m と H[3] の CPU ごとの値を出す)
//	mcrun hash <ELF> <repeat>   (E035 — Stat[0..4] と hash の Counts / Small の値の和を出す)
//	mcrun ring <ELF> <repeat>   (E028 の H5 — ring buffer Events を reader の goroutine が並んで読み、受け取った数・Drops[0]・送った数を出す)
package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/ringbuf"
	"golang.org/x/sys/unix"
)

func main() {
	if os.Args[1] == "percpu" {
		percpuMain(os.Args[2], os.Args[3])
		return
	}
	if os.Args[1] == "hash" {
		hashMain(os.Args[2], os.Args[3])
		return
	}
	if os.Args[1] == "ring" {
		ringMain(os.Args[2], os.Args[3])
		return
	}
	spec, err := ebpf.LoadCollectionSpec(os.Args[1])
	if err != nil {
		panic(err)
	}
	repeat, _ := strconv.Atoi(os.Args[2])
	coll, err := ebpf.NewCollection(spec)
	if err != nil {
		panic(err)
	}
	defer coll.Close()
	prog := coll.Programs["prog"]
	ncpu := runtime.NumCPU()
	var wg sync.WaitGroup
	for cpu := 0; cpu < ncpu; cpu++ {
		wg.Add(1)
		go func(cpu int) {
			defer wg.Done()
			runtime.LockOSThread()
			var set unix.CPUSet
			set.Set(cpu)
			if err := unix.SchedSetaffinity(0, &set); err != nil {
				panic(err)
			}
			data := make([]byte, 64)
			for i := 0; i < repeat; i++ { // repeat 1 の run を回数分 (cilium の repeat > 1 の EINTR のやり直しが数を増やす — go-bpf-mlir E116)
				if _, err := prog.Run(&ebpf.RunOptions{Data: data, Repeat: 1}); err != nil {
					panic(err)
				}
			}
		}(cpu)
	}
	wg.Wait()
	v := make([]byte, 16)
	if err := coll.Maps["Cs"].Lookup(uint32(0), &v); err != nil {
		panic(err)
	}
	n, m := binary.LittleEndian.Uint64(v[0:]), binary.LittleEndian.Uint64(v[8:])
	fmt.Printf("cpus=%d repeat=%d want=%d n=%d m=%d lost=%d (%.2f%%)\n", ncpu, repeat, uint64(ncpu)*uint64(repeat), n, m, n-m, 100*float64(n-m)/float64(n))
}

// runAll は prog を全ての CPU で同時に repeat 回ずつ (CPU ごとに goroutine を固定)。
func runAll(prog *ebpf.Program, repeat int) int {
	ncpu := runtime.NumCPU()
	var wg sync.WaitGroup
	for cpu := 0; cpu < ncpu; cpu++ {
		wg.Add(1)
		go func(cpu int) {
			defer wg.Done()
			runtime.LockOSThread()
			var set unix.CPUSet
			set.Set(cpu)
			if err := unix.SchedSetaffinity(0, &set); err != nil {
				panic(err)
			}
			data := make([]byte, 64)
			for i := 0; i < repeat; i++ { // repeat 1 の run を回数分 (cilium の repeat > 1 の EINTR のやり直しが数を増やす — go-bpf-mlir E116)
				if _, err := prog.Run(&ebpf.RunOptions{Data: data, Repeat: 1}); err != nil {
					panic(err)
				}
			}
		}(cpu)
	}
	wg.Wait()
	return ncpu
}

func ringMain(elf, rep string) {
	spec, err := ebpf.LoadCollectionSpec(elf)
	if err != nil {
		panic(err)
	}
	repeat, _ := strconv.Atoi(rep)
	coll, err := ebpf.NewCollection(spec)
	if err != nil {
		panic(err)
	}
	defer coll.Close()
	rd, err := ringbuf.NewReader(coll.Maps["Events"])
	if err != nil {
		panic(err)
	}
	defer rd.Close()
	var received uint64
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() { // 走らせている間も読む (reader が遅ければ落ちる — 落ちた数は Drops に)
		defer close(done)
		var rec ringbuf.Record
		for {
			select {
			case <-stop:
				return
			default:
			}
			rd.SetDeadline(time.Now().Add(20 * time.Millisecond))
			if err := rd.ReadInto(&rec); err != nil {
				if errors.Is(err, os.ErrDeadlineExceeded) {
					continue
				}
				panic(err)
			}
			received++
		}
	}()
	ncpu := runAll(coll.Programs["prog"], repeat)
	close(stop)
	<-done
	var rec ringbuf.Record
	for { // 残りを読む (期限切れで空)
		rd.SetDeadline(time.Now().Add(50 * time.Millisecond))
		if err := rd.ReadInto(&rec); err != nil {
			if errors.Is(err, os.ErrDeadlineExceeded) {
				break
			}
			panic(err)
		}
		received++
	}
	var dropped uint64
	if err := coll.Maps["Drops"].Lookup(uint32(0), &dropped); err != nil {
		panic(err)
	}
	sent := uint64(ncpu) * uint64(repeat)
	fmt.Printf("cpus=%d repeat=%d sent=%d received=%d dropped=%d sum_ok=%v\n", ncpu, repeat, sent, received, dropped, received+dropped == sent)
}

// sumHash は hash の map の u64 の値の和 (無い map は 0)。
func sumHash(m *ebpf.Map) uint64 {
	if m == nil {
		return 0
	}
	var k uint32
	var v, sum uint64
	it := m.Iterate()
	for it.Next(&k, &v) {
		sum += v
	}
	if err := it.Err(); err != nil {
		panic(err)
	}
	return sum
}

func hashMain(elf, rep string) {
	spec, err := ebpf.LoadCollectionSpec(elf)
	if err != nil {
		panic(err)
	}
	repeat, _ := strconv.Atoi(rep)
	coll, err := ebpf.NewCollection(spec)
	if err != nil {
		panic(err)
	}
	defer coll.Close()
	ncpu := runAll(coll.Programs["prog"], repeat)
	var st [5]uint64
	for i := range st {
		if err := coll.Maps["Stat"].Lookup(uint32(i), &st[i]); err != nil {
			panic(err)
		}
	}
	fmt.Printf("cpus=%d repeat=%d nominal=%d stat=%d,%d,%d,%d,%d counts=%d small=%d\n", ncpu, repeat, uint64(ncpu)*uint64(repeat), st[0], st[1], st[2], st[3], st[4], sumHash(coll.Maps["Counts"]), sumHash(coll.Maps["Small"]))
}

// getcpu は今の thread の CPU (getcpu の syscall — x/sys に関数が無い)。
func getcpu() int {
	var cpu uint32
	if _, _, e := unix.RawSyscall(unix.SYS_GETCPU, uintptr(unsafe.Pointer(&cpu)), 0, 0); e != 0 {
		panic(e)
	}
	return int(cpu)
}

// percpuMain は全ての CPU に 1 つずつ固定した thread で repeat 1 の run を repeat 回 (固定を run の前後に getcpu で確かめる — go-bpf-mlir P010 のレビューの P2)、
// 終わりに P[0] (record の n / m — per-CPU なら CPU ごと、共有なら 1 つ) と H[3] (在れば) の CPU ごとの値を出す。
func percpuMain(elf, rep string) {
	spec, err := ebpf.LoadCollectionSpec(elf)
	if err != nil {
		panic(err)
	}
	repeat, _ := strconv.Atoi(rep)
	coll, err := ebpf.NewCollection(spec)
	if err != nil {
		panic(err)
	}
	defer coll.Close()
	prog := coll.Programs["prog"]
	ncpu := runtime.NumCPU()
	var wg sync.WaitGroup
	moved := make([]bool, ncpu)
	for cpu := 0; cpu < ncpu; cpu++ {
		wg.Add(1)
		go func(cpu int) {
			defer wg.Done()
			runtime.LockOSThread()
			var set unix.CPUSet
			set.Set(cpu)
			if err := unix.SchedSetaffinity(0, &set); err != nil {
				panic(err)
			}
			data := make([]byte, 64)
			for i := 0; i < repeat; i++ {
				if getcpu() != cpu {
					moved[cpu] = true
				}
				if _, err := prog.Run(&ebpf.RunOptions{Data: data, Repeat: 1}); err != nil {
					panic(err)
				}
			}
			if getcpu() != cpu {
				moved[cpu] = true
			}
		}(cpu)
	}
	wg.Wait()
	for cpu, m := range moved {
		if m {
			fmt.Printf("thread for CPU %d ran elsewhere — pinning failed\n", cpu)
			os.Exit(3)
		}
	}
	p := coll.Maps["P"]
	type sv struct{ N, M uint64 }
	var ns, ms []string
	var sumN, sumM uint64
	if p.Type() == ebpf.PerCPUArray {
		var vs []sv
		if err := p.Lookup(uint32(0), &vs); err != nil {
			panic(err)
		}
		for _, v := range vs {
			ns, ms = append(ns, strconv.FormatUint(v.N, 10)), append(ms, strconv.FormatUint(v.M, 10))
			sumN, sumM = sumN+v.N, sumM+v.M
		}
	} else {
		var v sv
		if err := p.Lookup(uint32(0), &v); err != nil {
			panic(err)
		}
		ns, ms, sumN, sumM = []string{strconv.FormatUint(v.N, 10)}, []string{strconv.FormatUint(v.M, 10)}, v.N, v.M
	}
	hs, sumH := "-", uint64(0)
	if h, ok := coll.Maps["H"]; ok {
		var vs []uint64
		if err := h.Lookup(uint32(3), &vs); err != nil {
			panic(err)
		}
		var ss []string
		for _, v := range vs {
			ss = append(ss, strconv.FormatUint(v, 10))
			sumH += v
		}
		hs = strings.Join(ss, ",")
	}
	fmt.Printf("cpus=%d repeat=%d nominal=%d n=%s sum_n=%d m=%s sum_m=%d h=%s sum_h=%d\n", ncpu, repeat, uint64(ncpu)*uint64(repeat), strings.Join(ns, ","), sumN, strings.Join(ms, ","), sumM, hs, sumH)
}
