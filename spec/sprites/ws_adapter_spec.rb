# frozen_string_literal: true

require "spec_helper"
require "socket"

RSpec.describe Sprites::WebSocketConnection do
  def connect_pair(valid_accept: true, extra_headers: {})
    client_socket, server_socket = Socket.pair(:UNIX, :STREAM, 0)
    connection = described_class.new("ws://example.test/v1/sprites/demo/exec", timeout: 1)
    allow(connection).to receive(:create_socket).and_return(client_socket)
    server_thread = Thread.new do
      request = read_headers(server_socket)
      key = request[/^Sec-WebSocket-Key:\s*(.+)\r$/i, 1]
      accept = Base64.strict_encode64(
        Digest::SHA1.digest("#{key}#{described_class::WEBSOCKET_GUID}")
      )
      accept = "invalid" unless valid_accept
      headers = {
        "Upgrade" => "websocket",
        "Connection" => "keep-alive, Upgrade",
        "Sec-WebSocket-Accept" => accept
      }.merge(extra_headers)
      response = +"HTTP/1.1 101 Switching Protocols\r\n"
      headers.each { |name, value| response << "#{name}: #{value}\r\n" }
      response << "\r\n"
      server_socket.write(response)
    end
    connection.connect!
    server_thread.join
    [connection, server_socket]
  rescue StandardError
    server_thread&.join
    client_socket&.close unless client_socket&.closed?
    server_socket&.close unless server_socket&.closed?
    raise
  end

  def read_headers(socket)
    buffer = +""
    buffer << socket.readpartial(1024) until buffer.include?("\r\n\r\n")
    buffer
  end

  def server_frame(opcode, payload = "", fin: true, masked: false, declared_length: nil)
    payload = payload.b
    first = (fin ? 0x80 : 0) | opcode
    length = declared_length || payload.bytesize
    mask_bit = masked ? 0x80 : 0
    header = +[first].pack("C")
    if length < 126
      header << [mask_bit | length].pack("C")
    elsif length < 65_536
      header << [mask_bit | 126, length].pack("Cn")
    else
      header << [mask_bit | 127, length].pack("CQ>")
    end
    return header if declared_length

    if masked
      key = "mask"
      encoded = payload.bytes.each_with_index.map { |byte, index| byte ^ key.getbyte(index & 3) }.pack("C*")
      header << key << encoded
    else
      header << payload
    end
    header
  end

  def read_client_frame(socket)
    first, second = socket.read(2).unpack("CC")
    length = second & 0x7F
    length = socket.read(2).unpack1("n") if length == 126
    length = socket.read(8).unpack1("Q>") if length == 127
    key = socket.read(4)
    payload = socket.read(length)
    decoded = payload.bytes.each_with_index.map { |byte, index| byte ^ key.getbyte(index & 3) }.pack("C*")
    [first & 0x0F, decoded]
  end

  it "validates the RFC 6455 handshake and parses capabilities case-insensitively" do
    connection, server = connect_pair(
      extra_headers: { "X-Sprite-Capabilities" => "signal, resize" }
    )

    expect(connection.capabilities).to eq("signal" => true, "resize" => true)
    expect(connection.response_headers["upgrade"]).to eq("websocket")
  ensure
    connection&.close
    server&.close
  end

  it "rejects an invalid Sec-WebSocket-Accept instead of accepting any 101 response" do
    expect { connect_pair(valid_accept: false) }
      .to raise_error(Sprites::Error, /invalid Sec-WebSocket-Accept/)
  end

  it "sends a masked close frame before closing the socket" do
    connection, server = connect_pair

    connection.close
    opcode, payload = read_client_frame(server)

    expect(opcode).to eq(0x08)
    expect(payload.unpack1("n")).to eq(1000)
    expect(connection).to be_closed
  ensure
    connection&.close
    server&.close
  end

  it "assembles fragmented messages and answers ping without recursion" do
    connection, server = connect_pair
    server.write(server_frame(0x01, "hel", fin: false))
    server.write(server_frame(0x09, "ping"))
    server.write(server_frame(0x00, "lo"))

    expect(connection.read_message).to eq([:text, "hello"])
    expect(read_client_frame(server)).to eq([0x0A, "ping"])
  ensure
    connection&.close
    server&.close
  end

  it "rejects masked server frames and oversized declared payloads before allocation" do
    connection, server = connect_pair
    server.write(server_frame(0x02, "bad", masked: true))
    expect { connection.read_message }.to raise_error(Sprites::Error, /must not be masked/)
    connection.close
    server.close

    connection, server = connect_pair
    server.write(
      server_frame(
        0x02,
        declared_length: described_class::MAX_FRAME_PAYLOAD_BYTES + 1
      )
    )
    expect { connection.read_message }.to raise_error(Sprites::Error, /exceeds/)
  ensure
    connection&.close
    server&.close
  end
end
