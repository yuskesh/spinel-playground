# tools/npu/tflite.rb -- reads the parts of a TFLite flatbuffer that the NPU
# lane checks: operators, tensors and constant buffers of the first subgraph.
module TFLite
  Tensor = Struct.new(:index, :type, :shape, :buffer, :name)
  Op = Struct.new(:index, :builtin, :custom, :inputs, :outputs)
  UINT8 = 3
  INT8 = 9

  class Model
    attr_reader :tensors, :ops, :inputs, :outputs

    def initialize(bytes)
      @b = bytes.b
      raise ArgumentError, "not a TFLite file" unless @b.bytesize > 8 && @b[4, 4] == "TFL3"
      root = ind(0)
      codes = table_vec(field(root, 1)).map do |c|
        dep = field(c, 0); bc = field(c, 3); cu = field(c, 1)
        [bc ? i32(bc) : (dep ? @b[dep].unpack1("c") : 0), cu ? str(cu) : nil]
      end
      sg = table_vec(field(root, 2)).first
      @buffers = table_vec(field(root, 4))
      @tensors = table_vec(field(sg, 0)).each_with_index.map do |t, i|
        Tensor.new(i, field(t, 1) ? @b.getbyte(field(t, 1)) : 0, field(t, 0) ? ints(field(t, 0)) : [],
                   field(t, 2) ? u32(field(t, 2)) : 0, field(t, 3) ? str(field(t, 3)) : "")
      end
      @inputs = ints(field(sg, 1))
      @outputs = ints(field(sg, 2))
      @ops = table_vec(field(sg, 3)).each_with_index.map do |o, i|
        code = codes[field(o, 0) ? u32(field(o, 0)) : 0]
        Op.new(i, code[0], code[1], ints(field(o, 1)), ints(field(o, 2)))
      end
    end

    def neutron_graphs
      @ops.select { |o| o.custom == "NeutronGraph" }
    end

    def data(tensor)
      f = field(@buffers[tensor.buffer], 0) or return "".b
      p, n = vec(f)
      @b[p, n]
    end

    private

    def u32(o) = @b[o, 4].unpack1("V")
    def i32(o) = @b[o, 4].unpack1("l<")
    def u16(o) = @b[o, 2].unpack1("v")
    def ind(o) = o + u32(o)

    def field(t, n)
      vt = t - i32(t)
      f = 4 + 2 * n
      return nil unless f < u16(vt)
      x = u16(vt + f)
      x.zero? ? nil : t + x
    end

    def vec(o)
      v = ind(o)
      [v + 4, u32(v)]
    end

    def str(o)
      p, n = vec(o)
      @b[p, n]
    end

    def ints(o)
      p, n = vec(o)
      (0...n).map { |i| i32(p + 4 * i) }
    end

    def table_vec(o)
      p, n = vec(o)
      (0...n).map { |i| ind(p + 4 * i) }
    end
  end
end
