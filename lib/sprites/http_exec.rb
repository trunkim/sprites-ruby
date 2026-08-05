# frozen_string_literal: true

require "net/http"

module Sprites
  # 不依赖 WebSocket 的非 TTY exec。
  #
  # 服务端 wire format 是无长度前缀的 type byte + payload，依赖 HTTP transport
  # 交付的 chunk 边界。因此这里必须在 Net::HTTP#request block 内直接消费
  # read_body chunk，不能经过 IO.pipe 或按字节流重新分块。协议本身仍无法检测
  # 所有中间层合并 chunk 的情况，大输出应优先使用 WebSocket Cmd。
  module HTTPExec
    DEFAULT_EXEC_MAX_BUFFER = 10 * 1024 * 1024
    ERROR_BODY_LIMIT = 1024 * 1024

    def exec_file_http(sprite_name, file, args = [], input: nil, environment: nil,
                       working_dir: nil, timeout: nil,
                       max_buffer: DEFAULT_EXEC_MAX_BUFFER, encoding: Encoding::UTF_8)
      file = file.to_s
      raise ArgumentError, "file is required" if file.empty?

      args = Array(args).map(&:to_s)
      max_buffer = Integer(max_buffer)
      raise ArgumentError, "max_buffer must be >= 0" if max_buffer.negative?

      timeout = Float(timeout) unless timeout.nil?
      if timeout && (!timeout.finite? || timeout.negative?)
        raise ArgumentError, "timeout must be a non-negative finite number"
      end

      params = [["cmd", file]]
      args.each { |arg| params << ["cmd", arg] }
      params << ["path", file]
      params << ["dir", working_dir.to_s] if working_dir
      environment&.each { |key, value| params << ["env", "#{key}=#{value}"] }
      params << ["stdin", "true"] unless input.nil?

      uri = Routes.uri(base_url, Routes.exec(sprite_name), params: params)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/octet-stream"
      request.body = input.to_s.b unless input.nil?

      request_stream(
        uri,
        request,
        read_timeout: timeout,
        open_timeout: timeout,
        write_timeout: timeout
      ) do |response|
        parse_http_exec_response(response, max_buffer:, encoding:)
      end
    end

    private

    def parse_http_exec_response(response, max_buffer:, encoding:)
      unless response.code.to_i.between?(200, 299)
        body = read_bounded_error_body(response)
        api_error = APIError.parse(response, body)
        raise api_error if api_error

        raise Error, "HTTP exec failed (status #{response.code}): #{body}"
      end

      stdout = +"".b
      stderr = +"".b
      exit_code = nil

      response.read_body do |chunk|
        next if chunk.nil? || chunk.empty?

        frame_type = chunk.getbyte(0)
        payload = chunk.byteslice(1..) || +"".b
        case frame_type
        when STREAM_STDOUT
          append_exec_output!(stdout, payload, "stdout", max_buffer)
        when STREAM_STDERR
          append_exec_output!(stderr, payload, "stderr", max_buffer)
        when STREAM_EXIT
          unless payload.bytesize == 1
            raise Error,
                  "invalid HTTP exec exit frame length #{payload.bytesize}; " \
                  "the protocol requires preserved HTTP chunk boundaries"
          end
          exit_code = payload.getbyte(0)
        else
          raise Error,
                format(
                  "unsupported HTTP exec frame type 0x%02x; " \
                  "the protocol requires preserved HTTP chunk boundaries",
                  frame_type
                )
        end
      end

      raise Error, "HTTP exec response did not include an exit frame" if exit_code.nil?

      result = ExecResult.new(
        stdout: encode_exec_output(stdout, encoding),
        stderr: encode_exec_output(stderr, encoding),
        exit_code:
      )
      raise ExecError, result unless exit_code.zero?

      result
    end

    def append_exec_output!(buffer, payload, stream_name, max_buffer)
      if buffer.bytesize + payload.bytesize > max_buffer
        raise Error, "#{stream_name} max_buffer exceeded"
      end

      buffer << payload
    end

    def encode_exec_output(buffer, encoding)
      return buffer if encoding.nil? || encoding == :binary || encoding.to_s == "binary"

      buffer.force_encoding(Encoding.find(encoding))
    end

    def read_bounded_error_body(response)
      body = +"".b
      response.read_body do |chunk|
        remaining = ERROR_BODY_LIMIT - body.bytesize
        body << chunk.byteslice(0, remaining) if remaining.positive?
      end
      body
    end
  end

  class Sprite
    def exec_file_http(file, args = [], **options)
      client.exec_file_http(name, file, args, **options)
    end
  end
end
