# frozen_string_literal: true

# Synthetic HTTP backend and DNS server, reachable only on this process's loopback.
class SharedEndpointFixture
  attr_reader :dns_port, :http_port

  def initialize
    @aliases = {}
    @mutex = Mutex.new
    @tcp = TCPServer.new('127.0.0.1', 0)
    @dns_port = @tcp.local_address.ip_port
    @udp = UDPSocket.new
    @udp.bind('127.0.0.1', @dns_port)
    @threads = [Thread.new { serve_udp }, Thread.new { serve_tcp }]
    start_http
  end

  def stop
    @http&.shutdown
    @threads.each { |thread| thread.kill.join }
    @tcp.close
    @udp.close
  end

  private

  def start_http
    ready = Queue.new
    @http = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1', AccessLog: [],
                                    Logger: WEBrick::Log.new(File::NULL), StartCallback: -> { ready << true })
    @http.mount_proc('/entries') do |request, response|
      data = JSON.parse(request.body)
      @mutex.synchronize { @aliases[data.fetch('name')] = data.fetch('target') }
      response.status = 201
      response.body = JSON.generate(data)
    end
    @threads << Thread.new { @http.start }
    ready.pop
    @http_port = @http.config[:Port]
  end

  def serve_udp
    loop do
      bytes, sender = @udp.recvfrom(65_535)
      @udp.send(answer(bytes), 0, sender[3], sender[1])
    end
  end

  def serve_tcp
    loop do
      client = @tcp.accept
      begin
        length = client.read(2).unpack1('n')
        bytes = answer(client.read(length))
        client.write([bytes.bytesize].pack('n') + bytes)
      ensure
        client.close
      end
    end
  end

  def answer(bytes)
    request = Resolv::DNS::Message.decode(bytes)
    response = Resolv::DNS::Message.new(request.id)
    response.qr = 1
    response.aa = 1
    request.question.each do |name, type|
      response.add_question(name, type)
      add_answer(response, name, type)
    end
    response.encode
  end

  def add_answer(response, name, type)
    target = @mutex.synchronize { @aliases[name.to_s] }
    if target
      response.add_answer(name, 60, Resolv::DNS::Resource::IN::CNAME.new(Resolv::DNS::Name.create(target)))
      name = target
    end
    return unless type == Resolv::DNS::Resource::IN::A && name.to_s == 'ingress.example.test'

    response.add_answer(name, 60, Resolv::DNS::Resource::IN::A.new('192.0.2.10'))
  end
end
