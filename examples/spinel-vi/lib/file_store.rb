# spinel-tier: full
# V3/V4 file boundary. C owns lstat, UTF-8/LF validation, and the durable
# replacement sequence; Ruby only supplies already materialized editor bytes.
module SpinelVi
  module FileStore
    def self.load(path)
      text = ViTerm.sp_vi_file_load_bytes(path)
      if ViTerm.sp_vi_file_last_status != 0
        raise RuntimeError, ViTerm.sp_vi_file_error
      end
      if ViTerm.sp_vi_file_validate_text(text, text.bytesize) != 0
        raise RuntimeError, ViTerm.sp_vi_file_error
      end
      # The :binstr return is a binary String (sp_str_as_binary); the C side has
      # just validated it as UTF-8, so it is text from here on.
      text.force_encoding("UTF-8")
    end

    def self.save(path, text)
      return -1 if ViTerm.sp_vi_file_validate_text(text, text.bytesize) != 0
      ViTerm.sp_vi_file_save(path, text, text.bytesize)
    end

    def self.error
      ViTerm.sp_vi_file_error
    end
  end
end
