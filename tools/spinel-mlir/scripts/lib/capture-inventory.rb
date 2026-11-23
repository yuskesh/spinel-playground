require 'json'
require 'digest'

# Canonical capture inventory; subset projections use this same writer.
module CaptureInventory
  module_function
  def write(out)
    inventory=Dir[out+'/**/*'].select{|p|File.file?(p)}.sort.to_h{|p|[p.delete_prefix(out+'/'),Digest::SHA256.file(p).hexdigest]}
    File.write(out+'/sha256.json',JSON.pretty_generate(inventory)+"\n")
  end
end
