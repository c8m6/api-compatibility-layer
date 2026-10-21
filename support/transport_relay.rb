# frozen_string_literal: true

require 'socket'
require 'timeout'

# Optional container companion; the HTTP application never loads this file.
class TransportRelay
  TIMEOUT = 5
  MAX_CLIENTS = 32
  MAX_PACKET = 65_535

  def initialize(environment = ENV)
    @host = environment.fetch('ACL_RELAY_UPSTREAM_HOST')
    unless @host.match?(/\A[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?\z/)
      raise ArgumentError, 'ACL_RELAY_UPSTREAM_HOST must be an IPv4 address or hostname'
    end

    @port = port(environment.fetch('ACL_RELAY_LISTEN_PORT', '53'))
    @upstream_port = port(environment.fetch('ACL_RELAY_UPSTREAM_PORT', '53'))
    @slots = SizedQueue.new(MAX_CLIENTS)
    MAX_CLIENTS.times { @slots << true }
    @workers = []
    @mutex = Mutex.new
    @stopping = false
  end

  def privileged_port?
    @port < 1024
  end

  def run
    @tcp = TCPServer.new('0.0.0.0', @port)
    @udp = UDPSocket.new
    @udp.bind('0.0.0.0', @port)
    %w[INT TERM].each { |signal| Signal.trap(signal) { @stopping = true } }
    until @stopping
      IO.select([@tcp, @udp], nil, nil, 0.25)&.first&.each do |listener|
        listener == @tcp ? accept_tcp : accept_udp
      end
    end
  ensure
    @tcp&.close
    @udp&.close
    @mutex.synchronize { @workers.dup }.each { |thread| thread.kill.join }
  end

  private

  def port(value)
    Integer(value, 10).tap do |number|
      raise ArgumentError, 'relay ports must be between 1 and 65535' unless (1..65_535).cover?(number)
    end
  end

  def accept_tcp
    client = @tcp.accept_nonblock(exception: false)
    return if client == :wait_readable

    client.close unless worker { relay_tcp(client) }
  end

  def accept_udp
    packet = @udp.recvfrom_nonblock(MAX_PACKET, exception: false)
    return if packet == :wait_readable

    payload, sender = packet
    worker { relay_udp(payload, sender) }
  end

  def worker(&)
    @slots.pop(true)
    @mutex.synchronize do
      @workers << Thread.new do
        Timeout.timeout(TIMEOUT, &)
      rescue IOError, SystemCallError, SocketError, Timeout::Error
        # Drop a failed exchange without logging client traffic.
      ensure
        @slots << true
        @mutex.synchronize { @workers.delete(Thread.current) }
      end
    end
    true
  rescue ThreadError
    false
  end

  def relay_udp(payload, sender)
    upstream = UDPSocket.new
    upstream.connect(@host, @upstream_port)
    upstream.send(payload, 0)
    @udp.send(upstream.recv(MAX_PACKET), 0, sender[3], sender[1])
  ensure
    upstream&.close
  end

  def relay_tcp(client)
    upstream = Socket.tcp(@host, @upstream_port, connect_timeout: TIMEOUT)
    upload = Thread.new do
      IO.copy_stream(client, upstream)
      upstream.close_write
    rescue IOError, SystemCallError
      # The peer may already have closed its side of the connection.
    end
    IO.copy_stream(upstream, client)
  ensure
    upload&.kill&.join
    upstream&.close
    client.close
  end
end
