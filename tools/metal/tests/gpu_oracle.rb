# frozen_string_literal: true
#
# E456 (P013): the differential oracle for the gpu-metal harness — CRuby
# executes THE SAME .rb the codegen compiled, with the three gpu builtins
# shimmed onto arrays and a gid loop. spinel's classic differential form
# (CRuby semantics vs our lowering), for zero new codegen.
#
#   ruby gpu_oracle.rb <example.rb> <kernel_method> <N> [--perturb]
#
# Inputs mirror gpu_metal_runner.swift exactly (buffer 0 = x, 1 = y, 2 = out;
# values exact in float32). Computation runs in Ruby doubles; the comparator
# absorbs the double-vs-float32 per-op rounding with a 1e-5 relative tolerance.
#
# --perturb is the harness's negative control (E415 discipline): it corrupts one
# output element by +1.0 after the compute, and the comparator MUST fail on it —
# a run where the perturbed compare passes means the gate is vacuous.

abort "usage: ruby gpu_oracle.rb <example.rb> <kernel_method> <N> [--perturb]" unless ARGV.length >= 3
example, kern, n = ARGV[0], ARGV[1], Integer(ARGV[2])
perturb = ARGV.include?("--perturb")

$gpu_bufs = {
  0 => Array.new(n) { |i| (i % 1000) * 0.25 + 0.5 },
  1 => Array.new(n) { |i| ((i * 7) % 997) * 0.125 },
  2 => Array.new(n, 0.0),
}
$gpu_gid = 0
$gpu_slot_by_name = {}

# E459: the example may declare named buffers; the shim resolves a name to its
# declared slot, and keeps accepting integer slots for anonymous-mode units.
def gpu_buffer(name, _type, slot)
  $gpu_slot_by_name[name] = slot
  nil
end

def gpu_resolve(slot_or_name) = slot_or_name.is_a?(Symbol) ? $gpu_slot_by_name.fetch(slot_or_name) : slot_or_name

def gpu_global_id = $gpu_gid
def gpu_load(slot, i) = $gpu_bufs.fetch(gpu_resolve(slot))[i]
def gpu_store(slot, i, v)
  $gpu_bufs.fetch(gpu_resolve(slot))[i] = v
  nil
end

load File.expand_path(example)
abort "oracle: no method #{kern} in #{example}" unless Object.private_method_defined?(kern) || Object.method_defined?(kern)

n.times do |g|
  $gpu_gid = g
  send(kern)
end

$gpu_bufs[2][n / 2] += 1.0 if perturb   # negative control: one corrupted element

$gpu_bufs[2].each_with_index { |v, i| puts "#{i} #{v}" }
