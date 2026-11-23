# tools/metal -- Ruby compute kernels on Apple GPUs

`spinel-metal` compiles a compute kernel written in a small Ruby subset to Metal
Shading Language, and the Ruby program that drives it to a native binary. It
runs on macOS with a Metal device. Ported from spinel-ebpf
`23fa4b06`; see [provenance](../../docs/provenance.md).

```sh
cd tools/metal/examples
../spinel-metal compile saxpy.rb -o build/       # build/saxpy.metal, build/saxpy_host.rb
../spinel-metal host host_saxpy.rb -o build/     # build/host_saxpy
./build/host_saxpy build 4096
```

It needs `vendor/spinel` built (`docs/building.md`). A kernel is a method named
`kernel__<name>`, with its buffers declared by `gpu_buffer`:

```ruby
gpu_buffer :x,   :float, 0
gpu_buffer :y,   :float, 1
gpu_buffer :out, :float, 2

def kernel__saxpy
  i = gpu_global_id
  gpu_store(:out, i, 2.5 * gpu_load(:x, i) + gpu_load(:y, i))
end
```

The generator is the `gpu-metal` target of the compiler in `tools/ebpf`
(`src/codegen_c/spinel_ebpf_cc.c`), and `spinel-metal` calls it. They share the
in-process code generator, which is why that target stays there.

## Checks

`tests/run_gpu_codegen.sh` checks the generated MSL as text and needs no GPU.

`tests/run_gpu_bridge.sh` and `tests/run_gpu_metal_exec.sh` run the kernels on a
Metal device and compare them with a CPU computation of the same formula. They
are oracles, listed in `tests/ORACLES.tsv`, and run only with `ALLOW_ORACLE=1`.
