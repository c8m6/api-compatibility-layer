# frozen_string_literal: true

require_relative '../lib/api_compatibility_layer'
require 'tempfile'

module SpecHelpers
  def configuration(route = nil)
    {
      'version' => 1,
      'backends' => { 'inventory' => { 'base_url' => 'http://inventory.example.test:9000' } },
      'routes' => [route || { 'method' => 'GET', 'path' => '/legacy/items',
                              'backend' => { 'name' => 'inventory', 'method' => 'GET', 'path' => '/v2/resources' } }]
    }
  end

  def request(method: 'GET', path: '/legacy/items', query: '', headers: {}, body: '')
    APICompatibilityLayer::Engine::Request.new(http_method: method, path: path, query: query, headers: headers,
                                               body: body)
  end

  def engine(data, backend: APICompatibilityLayer::Backend.new)
    APICompatibilityLayer::Engine.new(APICompatibilityLayer::Config.new(data), backend: backend)
  end

  def with_backend(&)
    ready = Queue.new
    server = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1', AccessLog: [],
                                     Logger: WEBrick::Log.new(File::NULL), StartCallback: -> { ready << true })
    servlet = Class.new(WEBrick::HTTPServlet::AbstractServlet) do
      define_method(:service, &)
    end
    server.mount('/', servlet)
    thread = Thread.new { server.start }
    ready.pop
    [server, thread]
  end
end

RSpec.configure do |config|
  config.include SpecHelpers
  config.order = :random
  Kernel.srand config.seed
end
