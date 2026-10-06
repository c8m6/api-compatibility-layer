# frozen_string_literal: true

require 'bundler/setup'
require 'json'
require 'net/http'
require 'tempfile'
require 'timeout'
require 'webrick'
require 'yaml'

raise 'image must run as non-root' if Process.uid.zero?

# Entirely synthetic backend, reachable only within this test container.
ready = Queue.new
backend = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1', AccessLog: [],
                                  Logger: WEBrick::Log.new(File::NULL), StartCallback: -> { ready << true })
servlet = Class.new(WEBrick::HTTPServlet::AbstractServlet) do
  def service(request, response)
    response.status = 201
    response.body = JSON.generate('method' => request.request_method, 'body' => JSON.parse(request.body),
                                  'authorization' => request['authorization'])
  end
end
backend.mount('/', servlet)
thread = Thread.new { backend.start }
ready.pop

config = {
  'version' => 1, 'listen' => { 'address' => '127.0.0.1', 'port' => 18_080 },
  'backends' => { 'inventory' => { 'base_url' => "http://127.0.0.1:#{backend.config[:Port]}" } },
  'routes' => %w[GET POST PUT PATCH DELETE].map do |method|
    { 'method' => method, 'path' => '/ready', 'response' => { 'body' => { 'ok' => true } } }
  end + [{ 'method' => 'DELETE', 'path' => '/empty', 'response' => { 'status' => 204, 'empty' => true } },
         { 'method' => 'POST', 'path' => '/items',
           'extract' => { 'body' => { 'from' => 'body', 'pointer' => '' },
                          'token' => { 'from' => 'header', 'key' => 'Authorization' } },
           'backend' => { 'name' => 'inventory', 'method' => 'PATCH', 'path' => '/resources',
                          'headers' => { 'Authorization' => '{{values.token}}' }, 'body' => '{{values.body}}' } }]
}

def http_request(method, path, body = nil)
  http = Net::HTTP.new('127.0.0.1', 18_080, nil)
  http.open_timeout = 1
  http.read_timeout = 2
  request = Net::HTTPGenericRequest.new(method, !body.nil? || method != 'GET', true, path,
                                        'Content-Type' => 'application/json', 'Authorization' => 'Bearer synthetic')
  request.body = body
  http.request(request)
end

Tempfile.create(['acl-smoke', '.yaml']) do |file|
  file.write(YAML.dump(config))
  file.flush
  %w[TERM INT].each do |signal|
    pid = Process.spawn({ 'ACL_CONFIG' => file.path }, 'ruby', 'bin/acl')
    begin
      Timeout.timeout(10) do
        loop do
          break if http_request('GET', '/ready').code == '200'
        rescue Errno::ECONNREFUSED, EOFError
          sleep 0.05
        end
      end
      %w[GET POST PUT PATCH DELETE].each do |method|
        response = http_request(method, '/ready')
        raise "#{method} failed" unless response.code == '200' && JSON.parse(response.body) == { 'ok' => true }
      end
      response = http_request('POST', '/items', '{"enabled":false}')
      expected = { 'method' => 'PATCH', 'body' => { 'enabled' => false }, 'authorization' => 'Bearer synthetic' }
      raise 'HTTP translation failed' unless response.code == '201' && JSON.parse(response.body) == expected
      raise 'invalid JSON not rejected' unless http_request('POST', '/items', '{').code == '400'

      empty = http_request('DELETE', '/empty')
      raise 'empty response failed' unless empty.code == '204' && empty.body.nil?
      raise 'oversized request not rejected' unless http_request('POST', '/items', 'x' * 1_048_577).code == '413'
      raise 'unknown route not rejected' unless http_request('GET', '/missing').code == '404'

      Process.kill(signal, pid)
      _, status = Timeout.timeout(10) { Process.wait2(pid) }
      raise "unclean SIG#{signal} shutdown" unless status.success?
    ensure
      begin
        Process.kill('KILL', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        # Already reaped after a clean shutdown.
      end
    end
  end
end
backend.shutdown
thread.join
puts 'Image smoke test passed: non-root, five methods, HTTP translation, errors, SIGTERM and SIGINT.'
