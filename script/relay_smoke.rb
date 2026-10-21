# frozen_string_literal: true

require 'bundler/setup'
require 'json'
require 'net/http'
require 'resolv'
require 'socket'
require 'tempfile'
require 'timeout'
require 'webrick'
require 'yaml'

require_relative 'relay_fixture'

class RelaySmoke
  def initialize
    @fixture = SharedEndpointFixture.new
    @port = TCPServer.open('127.0.0.1', 0) { |socket| socket.local_address.ip_port }
    @relay_port = Integer(ENV.fetch('ACL_RELAY_SMOKE_PORT', '1053'))
  end

  def run
    Tempfile.create(['relay-smoke', '.yaml']) do |file|
      file.write(YAML.dump(configuration))
      file.flush
      %w[TERM INT].each { |signal| verify_process(file.path, signal) }
    end
    puts 'Relay smoke passed: shared HTTP/DNS address, CNAME write/read, UDP/TCP, concurrent clients, TERM/INT.'
  ensure
    @fixture.stop
  end

  private

  def configuration
    {
      'version' => 1, 'listen' => { 'address' => '127.0.0.1', 'port' => @port },
      'backends' => { 'inventory' => { 'base_url' => "http://127.0.0.1:#{@fixture.http_port}" } },
      'routes' => [{ 'method' => 'GET', 'path' => '/ready', 'response' => { 'body' => { 'ok' => true } } },
                   { 'method' => 'POST', 'path' => '/aliases',
                     'extract' => { 'entry' => { 'from' => 'body', 'pointer' => '' } },
                     'backend' => { 'name' => 'inventory', 'method' => 'POST', 'path' => '/entries',
                                    'body' => '{{values.entry}}' } }]
    }
  end

  def environment(path)
    { 'ACL_CONFIG' => path, 'ACL_RELAY_UPSTREAM_HOST' => '127.0.0.1',
      'ACL_RELAY_UPSTREAM_PORT' => @fixture.dns_port.to_s, 'ACL_RELAY_LISTEN_PORT' => @relay_port.to_s }
  end

  def verify_process(path, signal)
    pid = Process.spawn(environment(path), 'ruby', 'bin/acl-with-relay', out: File::NULL, err: File::NULL)
    wait_ready
    children = File.read("/proc/#{pid}/task/#{pid}/children").split.map(&:to_i)
    verify_capabilities(children) if ENV['ACL_RELAY_SMOKE_CAPABILITIES'] == '1'
    verify_exchange
    verify_concurrent_queries
    Process.kill(signal, pid)
    _, status = Timeout.timeout(10) { Process.wait2(pid) }
    raise "unclean SIG#{signal} shutdown" unless status.success?
    raise 'companion left a child process running' if children.any? { |child| alive?(child) }
  ensure
    cleanup(pid)
  end

  def cleanup(pid)
    Process.kill('TERM', pid)
    Timeout.timeout(10) { Process.wait(pid) }
  rescue Timeout::Error
    Process.kill('KILL', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # Already reaped after clean shutdown.
  end

  def verify_capabilities(children)
    statuses = children.map { |pid| File.read("/proc/#{pid}/status") }
    capabilities = statuses.map { |status| status[/^CapEff:\s*(\h+)/, 1].to_i(16) }
    raise 'only the relay may hold NET_BIND_SERVICE' unless capabilities.sort == [0, 0x400]

    http = statuses.find { |status| status[/^CapEff:\s*(\h+)/, 1].to_i(16).zero? }
    raise 'HTTP may not gain privileges' unless http[/^NoNewPrivs:\s*(\d+)/, 1] == '1'
    raise 'a child changed user' unless statuses.all? { |status| status[/^Uid:\s*(\d+)/, 1].to_i == Process.uid }
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_ready
    Timeout.timeout(10) do
      loop do
        return if http('GET', '/ready').code == '200' && udp_query('ingress.example.test').answer.any?
      rescue IOError, SystemCallError, Timeout::Error
        sleep 0.05
      end
    end
  end

  def http(method, path, body = nil)
    client = Net::HTTP.new('127.0.0.1', @port, nil)
    client.open_timeout = 1
    client.read_timeout = 2
    request = Net::HTTPGenericRequest.new(method, !body.nil?, true, path, 'Content-Type' => 'application/json')
    request.body = JSON.generate(body) if body
    client.request(request)
  end

  def verify_exchange
    response = http('POST', '/aliases', { 'name' => 'alias.example.test', 'target' => 'ingress.example.test' })
    raise 'HTTP backend write failed' unless response.code == '201'

    dns = Resolv::DNS.new(nameserver_port: [['127.0.0.1', @relay_port]], timeouts: 2)
    raise 'CNAME address resolution failed' unless dns.getaddress('alias.example.test').to_s == '192.0.2.10'

    cname = dns.getresource('alias.example.test', Resolv::DNS::Resource::IN::CNAME)
    raise 'CNAME record lost' unless cname.name.to_s == 'ingress.example.test'

    verify_tcp
  ensure
    dns&.close
  end

  def query(name, id)
    Resolv::DNS::Message.new(id).tap { |message| message.add_question(name, Resolv::DNS::Resource::IN::A) }
  end

  def udp_query(name, id = 1234)
    socket = UDPSocket.new
    socket.connect('127.0.0.1', @relay_port)
    socket.send(query(name, id).encode, 0)
    Timeout.timeout(2) { Resolv::DNS::Message.decode(socket.recv(65_535)) }
  ensure
    socket&.close
  end

  def verify_tcp
    socket = TCPSocket.new('127.0.0.1', @relay_port)
    payload = query('alias.example.test', 4321).encode
    socket.write([payload.bytesize].pack('n'))
    socket.write(payload[0, 3])
    socket.write(payload[3..])
    socket.close_write
    response = Timeout.timeout(2) { Resolv::DNS::Message.decode(socket.read(socket.read(2).unpack1('n'))) }
    raise 'TCP DNS response corrupted' unless response.id == 4321 && response.answer.size == 2
  ensure
    socket&.close
  end

  def verify_concurrent_queries
    threads = 12.times.map do |id|
      Thread.new do
        response = udp_query('alias.example.test', id)
        raise 'UDP responses crossed between clients' unless response.id == id && response.answer.size == 2
      end
    end
    threads.each(&:value)
  end
end

RelaySmoke.new.run
