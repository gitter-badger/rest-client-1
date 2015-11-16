require 'tempfile'
require 'securerandom'
require 'stringio'

require 'mime/types'

module RestClient
  module Payload
    extend self

    def generate(params)
      if params.is_a?(String)
        Base.new(params)
      elsif params.is_a?(Hash)
        if params.delete(:multipart) == true || has_file?(params)
          Multipart.new(params)
        else
          UrlEncoded.new(params)
        end
      elsif params.respond_to?(:read)
        Streamed.new(params)
      else
        nil
      end
    end

    def has_file?(params)
      params.any? do |_, v|
        case v
        when Hash
          has_file?(v)
        when Array
          has_file_array?(v)
        else
          v.respond_to?(:path) && v.respond_to?(:read)
        end
      end
    end

    def has_file_array?(params)
      params.any? do |v|
        case v
        when Hash
          has_file?(v)
        when Array
          has_file_array?(v)
        else
          v.respond_to?(:path) && v.respond_to?(:read)
        end
      end
    end

    class Base
      def initialize(params)
        build_stream(params)
      end

      def build_stream(params)
        @stream = StringIO.new(params)
        @stream.seek(0)
      end

      def read(*args)
        @stream.read(*args)
      end

      def to_s
        result = read
        @stream.seek(0)
        result
      end

      # Flatten parameters by converting hashes of hashes to flat hashes
      # {keys1 => {keys2 => value}} will be transformed into [keys1[key2], value]
      def flatten_params(params, parent_key = nil)
        result = []
        params.each do |key, value|
          calculated_key = parent_key ? "#{parent_key}[#{handle_key(key)}]" : handle_key(key)
          if value.is_a? Hash
            result += flatten_params(value, calculated_key)
          elsif value.is_a? Array
            result += flatten_params_array(value, calculated_key)
          else
            result << [calculated_key, value]
          end
        end
        result
      end

      def flatten_params_array value, calculated_key
        result = []
        value.each do |elem|
          if elem.is_a? Hash
            result += flatten_params(elem, calculated_key)
          elsif elem.is_a? Array
            result += flatten_params_array(elem, calculated_key)
          else
            result << ["#{calculated_key}[]", elem]
          end
        end
        result
      end

      def headers
        {'Content-Length' => size.to_s}
      end

      def size
        @stream.size
      end

      alias :length :size

      def close
        @stream.close unless @stream.closed?
      end

      def inspect
        # TODO: make this not pretend to be a string (ugh)
        to_s.inspect
      end

      def short_inspect
        (size > 500 ? "#{size} byte(s) length" : inspect)
      end

    end

    class Streamed < Base
      def build_stream(params = nil)
        @stream = params
      end

      def size
        if @stream.respond_to?(:size)
          @stream.size
        elsif @stream.is_a?(IO)
          @stream.stat.size
        end
      end

      alias :length :size
    end

    class UrlEncoded < Base
      def build_stream(params = nil)
        @stream = StringIO.new(Utils.encode_query_string(params))
        @stream.seek(0)
      end

      def headers
        super.merge({'Content-Type' => 'application/x-www-form-urlencoded'})
      end
    end

    class Multipart < Base
      EOL = "\r\n"

      def build_stream(params)
        b = '--' + boundary

        @stream = Tempfile.new("RESTClient.Stream.#{rand(1000)}")
        @stream.binmode
        @stream.write(b + EOL)

        if params.is_a? Hash
          x = flatten_params(params)
        else
          x = params
        end

        last_index = x.length - 1
        x.each_with_index do |a, index|
          k, v = * a
          if v.respond_to?(:read) && v.respond_to?(:path)
            create_file_field(@stream, k, v)
          else
            create_regular_field(@stream, k, v)
          end
          @stream.write(EOL + b)
          @stream.write(EOL) unless last_index == index
        end
        @stream.write('--')
        @stream.write(EOL)
        @stream.seek(0)
      end

      def create_regular_field(s, k, v)
        s.write("Content-Disposition: form-data; name=\"#{k}\"")
        s.write(EOL)
        s.write(EOL)
        s.write(v)
      end

      def create_file_field(s, k, v)
        begin
          s.write("Content-Disposition: form-data;")
          s.write(" name=\"#{k}\";") unless (k.nil? || k=='')
          s.write(" filename=\"#{v.respond_to?(:original_filename) ? v.original_filename : File.basename(v.path)}\"#{EOL}")
          s.write("Content-Type: #{v.respond_to?(:content_type) ? v.content_type : mime_for(v.path)}#{EOL}")
          s.write(EOL)
          while (data = v.read(8124))
            s.write(data)
          end
        ensure
          v.close if v.respond_to?(:close)
        end
      end

      def mime_for(path)
        mime = MIME::Types.type_for path
        mime.empty? ? 'text/plain' : mime[0].content_type
      end

      def boundary
        return @boundary if @boundary

        # Use the same algorithm used by WebKit: generate 16 random
        # alphanumeric characters, replacing `+` `/` with `A` `B` (included in
        # the list twice) to round out the set of 64.
        s = SecureRandom.base64(12)
        s.tr!('+/', 'AB')

        @boundary = '----RubyFormBoundary' + s
      end

      # for Multipart do not escape the keys
      def handle_key key
        key
      end

      def headers
        super.merge({'Content-Type' => %Q{multipart/form-data; boundary=#{boundary}}})
      end

      def close
        @stream.close!
      end
    end
  end
end
