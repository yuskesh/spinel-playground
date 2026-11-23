# tools/npu/tflite_write.rb -- writes the int8 TFLite model an `npu_def`
# declares. It covers only what the declaration can say. NXP's converter turns
# the result into a NeutronGraph, and spinel-npu checks that graph.
module TFLiteWrite
  class Error < StandardError; end

  # A flatbuffer laid out front to back: a parent comes before its children, so
  # every offset points forward, as the format requires.
  module FB
    Table = Struct.new(:fields)
    Vector = Struct.new(:kind, :items)
    Text = Struct.new(:text)
    ALIGN = { i64: 8, bytes: 16 }.freeze

    module_function

    def pad(out, align, ahead = 0)
      out << "\0" until ((out.bytesize + ahead) % align).zero?
    end

    def patch(out, at, target)
      out[at, 4] = [target - at].pack("V")
    end

    def write_table(out, table, at, queue)
      pad(out, 4)
      vtable = out.bytesize
      ids = table.fields.keys.sort
      count = (ids.max || -1) + 1
      out << [4 + 2 * count, 4 + 4 * ids.size].pack("vv")
      (0...count).each { |id| out << [ids.index(id) ? 4 + 4 * ids.index(id) : 0].pack("v") }
      pad(out, 4)
      start = out.bytesize
      patch(out, at, start)
      out << [start - vtable].pack("l<")
      ids.each do |id|
        kind, value = table.fields[id]
        case kind
        when :byte then out << [value, 0, 0, 0].pack("C4")
        when :int then out << [value].pack("l<")
        when :uint then out << [value].pack("V")
        when :ref
          queue << [value, out.bytesize]
          out << "\0\0\0\0"
        end
      end
    end

    def write_vector(out, vector, at, queue)
      pad(out, ALIGN.fetch(vector.kind, 4), 4)
      patch(out, at, out.bytesize)
      if vector.kind == :bytes
        out << [vector.items.bytesize].pack("V") << vector.items.b
        return
      end
      out << [vector.items.size].pack("V")
      vector.items.each do |x|
        case vector.kind
        when :int then out << [x].pack("l<")
        when :i64 then out << [x].pack("q<")
        when :float then out << [x].pack("e")
        when :ref
          queue << [x, out.bytesize]
          out << "\0\0\0\0"
        end
      end
    end

    def write(root, file_id)
      out = "\0\0\0\0#{file_id}".b
      queue = [[root, 0]]
      until queue.empty?
        object, at = queue.shift
        case object
        when Table then write_table(out, object, at, queue)
        when Vector then write_vector(out, object, at, queue)
        when Text
          pad(out, 4)
          patch(out, at, out.bytesize)
          out << [object.text.bytesize].pack("V") << object.text.b << "\0"
        end
      end
      out
    end
  end

  INT8 = 9
  INT32 = 2
  VALID = 1
  ACTIVATION = { none: 0, relu: 1, relu6: 3 }.freeze
  BUILTIN = { avg_pool: 1, conv2d: 3, fully_connected: 9, max_pool: 17, reshape: 22 }.freeze
  OPTIONS = { conv2d: 1, avg_pool: 5, max_pool: 5, fully_connected: 8, reshape: 17 }.freeze

  OPERATORS = %i[conv2d max_pool avg_pool flatten fully_connected].freeze

  # What the block of `npu_def` runs against: the operators and nothing of the
  # model behind them, so a name that is not an operator stops the build.
  class Operators
    def initialize(model)
      @model = model
    end

    OPERATORS.each do |op|
      define_method(op) { |*args, **opts| @model.public_send(op, *args, **opts) }
    end

    def method_missing(name, *)
      raise Error, "`#{name}` is not an operator npu_def generates (#{OPERATORS.join(", ")})"
    end

    def respond_to_missing?(*) = false
  end

  class Model
    attr_reader :shape

    def declare(&block)
      Operators.new(self).instance_eval(&block)
    end

    def initialize(input, quant)
      unless input.is_a?(Array) && input[0] == :i8 && input.size == 5 && input[1] == 1 && input[2..].all? { |d| positive?(d) }
        raise Error, "input: is [:i8, 1, height, width, channels]; got #{input.inspect}"
      end
      @tensors = []
      @buffers = [FB::Table.new({})]
      @ops = []
      @codes = []
      @shape = input[1..]
      @quant = check_quant("input", quant)
      @last = @input = tensor(@shape, INT8, @quant, nil, "input")
    end

    def conv2d(filters, kernel:, weights:, weight_scale:, bias:, quant:, activation: :none, stride: 1)
      need_image("conv2d")
      [filters, kernel, stride].each { |v| raise Error, "conv2d: #{v.inspect} is not a positive integer" unless positive?(v) }
      _, h, w, c = @shape
      out = [1, valid_size(h, kernel, stride, "conv2d"), valid_size(w, kernel, stride, "conv2d"), filters]
      wt = weight_tensor("conv2d", weights, [filters, kernel, kernel, c], weight_scale)
      bt = bias_tensor("conv2d", bias, filters, weight_scale)
      emit(:conv2d, [@last, wt, bt], out, check_quant("conv2d", quant),
           { 0 => [:byte, VALID], 1 => [:int, stride], 2 => [:int, stride], 3 => [:byte, activation_of("conv2d", activation)] })
    end

    def max_pool(size, stride: size) = pool(:max_pool, size, stride)
    def avg_pool(size, stride: size) = pool(:avg_pool, size, stride)

    def flatten
      raise Error, "flatten: the input is already flat" unless @shape.size == 4
      out = [1, @shape.inject(:*)]
      shape_buffer = tensor([2], INT32, nil, out.pack("l<*"), "flatten_shape")
      emit(:reshape, [@last, shape_buffer], out, @quant, { 0 => [:ref, FB::Vector.new(:int, out)] })
    end

    def fully_connected(units, weights:, weight_scale:, bias:, quant:, activation: :none)
      raise Error, "fully_connected: the input is not flat; call flatten first" unless @shape.size == 2
      raise Error, "fully_connected: #{units.inspect} is not a positive integer" unless positive?(units)
      wt = weight_tensor("fully_connected", weights, [units, @shape[1]], weight_scale)
      bt = bias_tensor("fully_connected", bias, units, weight_scale)
      emit(:fully_connected, [@last, wt, bt], [1, units], check_quant("fully_connected", quant),
           { 0 => [:byte, activation_of("fully_connected", activation)] })
    end

    def to_tflite
      raise Error, "the block declares no operator" if @ops.empty?
      # Every operator says version 1. The pinned converter accepts that; other
      # TFLite readers may want the version of their own registry.
      codes = @codes.map do |k|
        FB::Table.new({ 0 => [:byte, [BUILTIN[k], 127].min], 2 => [:int, 1], 3 => [:int, BUILTIN[k]] })
      end
      graph = FB::Table.new({ 0 => refs(@tensors), 1 => ints([@input]), 2 => ints([@last]), 3 => refs(@ops), 4 => text("main") })
      FB.write(FB::Table.new({ 0 => [:uint, 3], 1 => refs(codes), 2 => refs([graph]), 3 => text("spinel-npu"), 4 => refs(@buffers) }), "TFL3")
    end

    private

    def positive?(v) = v.is_a?(Integer) && v > 0

    # The file holds float32, so a scale must survive that: finite and above 0.
    def scale?(v)
      return false unless v.is_a?(Numeric) && v.finite?
      stored = [v].pack("e").unpack1("e")
      stored.finite? && stored > 0
    end
    def refs(items) = [:ref, FB::Vector.new(:ref, items)]
    def ints(items) = [:ref, FB::Vector.new(:int, items)]
    def text(s) = [:ref, FB::Text.new(s)]

    def need_image(op)
      raise Error, "#{op}: the input is flat, and #{op} needs [1, height, width, channels]" unless @shape.size == 4
    end

    def valid_size(dim, kernel, stride, op)
      raise Error, "#{op}: kernel #{kernel} is larger than the input #{@shape.inspect}" if kernel > dim
      (dim - kernel) / stride + 1
    end

    def check_quant(op, q)
      unless q.is_a?(Array) && q.size == 2 && scale?(q[0]) && q[1].is_a?(Integer) && q[1].between?(-128, 127)
        raise Error, "#{op}: quant: is [scale > 0, zero point in int8]; got #{q.inspect}"
      end
      [q[0].to_f, q[1]]
    end

    def activation_of(op, name)
      ACTIVATION.fetch(name) { raise Error, "#{op}: activation: is one of #{ACTIVATION.keys.join(", ")}; got #{name.inspect}" }
    end

    def tensor(shape, type, quant, data, name)
      index = 0
      if data
        @buffers << FB::Table.new({ 0 => [:ref, FB::Vector.new(:bytes, data)] })
        index = @buffers.size - 1
      end
      fields = { 0 => ints(shape), 1 => [:byte, type], 2 => [:uint, index], 3 => text(name) }
      if quant
        fields[4] = [:ref, FB::Table.new({ 2 => [:ref, FB::Vector.new(:float, [quant[0]])],
                                           3 => [:ref, FB::Vector.new(:i64, [quant[1]])] })]
      end
      @tensors << FB::Table.new(fields)
      @tensors.size - 1
    end

    def weight_tensor(op, weights, shape, scale)
      raise Error, "#{op}: weight_scale: must be finite and above 0 in float32; got #{scale.inspect}" unless scale?(scale)
      raise Error, "#{op}: weights: must be an array" unless weights.is_a?(Array)
      flat = weights.flatten
      want = shape.inject(:*)
      raise Error, "#{op}: #{flat.size} weights, and shape #{shape.inspect} needs #{want}" unless flat.size == want
      unless flat.all? { |w| w.is_a?(Integer) && w.between?(-127, 127) }
        raise Error, "#{op}: weights are integers from -127 to 127"
      end
      tensor(shape, INT8, [scale.to_f, 0], flat.pack("c*"), "#{op}_#{@ops.size}_weights")
    end

    def bias_tensor(op, bias, units, weight_scale)
      unless bias.is_a?(Array) && bias.size == units && bias.all? { |b| b.is_a?(Integer) && b.between?(-(2**31), 2**31 - 1) }
        raise Error, "#{op}: bias: is #{units} int32 values; got #{bias.inspect}"
      end
      unless scale?(@quant[0] * weight_scale)
        raise Error, "#{op}: the bias scale, input scale #{@quant[0]} times weight_scale #{weight_scale}, does not fit float32"
      end
      tensor([units], INT32, [@quant[0] * weight_scale, 0], bias.pack("l<*"), "#{op}_#{@ops.size}_bias")
    end

    def pool(kind, size, stride)
      need_image(kind)
      [size, stride].each { |v| raise Error, "#{kind}: #{v.inspect} is not a positive integer" unless positive?(v) }
      _, h, w, c = @shape
      out = [1, valid_size(h, size, stride, kind), valid_size(w, size, stride, kind), c]
      emit(kind, [@last], out, @quant,
           { 0 => [:byte, VALID], 1 => [:int, stride], 2 => [:int, stride], 3 => [:int, size], 4 => [:int, size] })
    end

    def emit(kind, inputs, shape, quant, options)
      output = tensor(shape, INT8, quant, nil, "#{kind}_#{@ops.size}_out")
      @codes << kind unless @codes.include?(kind)
      @ops << FB::Table.new({ 0 => [:uint, @codes.index(kind)], 1 => ints(inputs), 2 => ints([output]),
                              3 => [:byte, OPTIONS[kind]], 4 => [:ref, FB::Table.new(options)] })
      @last = output
      @shape = shape
      @quant = quant
    end
  end
end
