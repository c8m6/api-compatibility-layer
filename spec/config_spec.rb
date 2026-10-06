# frozen_string_literal: true

RSpec.describe APICompatibilityLayer::Config do
  it 'loads the documented example and defaults' do
    expect(described_class.load('config/example.yaml').listen).to eq('address' => '0.0.0.0', 'port' => 8080)
    expect(described_class.new(configuration).data).to be_frozen
  end

  invalid = {
    'unknown version' => ->(c) { c['version'] = 2 },
    'float version' => ->(c) { c['version'] = 1.0 },
    'unknown top-level key' => ->(c) { c['script'] = 'exit' },
    'invalid listen' => ->(c) { c['listen'] = { 'port' => 0 } },
    'empty routes' => ->(c) { c['routes'] = [] },
    'wrong routes type' => ->(c) { c['routes'] = {} },
    'unsupported method' => ->(c) { c['routes'][0]['method'] = 'CONNECT' },
    'invalid path' => ->(c) { c['routes'][0]['path'] = 'items' },
    'partial path parameter' => ->(c) { c['routes'][0]['path'] = '/items/:id:suffix' },
    'duplicate parameters' => ->(c) { c['routes'][0]['path'] = '/:id/:id' },
    'missing backend' => ->(c) { c['routes'][0]['backend']['name'] = 'absent' },
    'unknown backend option' => ->(c) { c['routes'][0]['backend']['script'] = 'exit' },
    'dynamic origin' => ->(c) { c['backends']['inventory']['base_url'] = 'http://{{values.host}}' },
    'non-HTTP origin' => ->(c) { c['backends']['inventory']['base_url'] = 'file:///tmp/data' },
    'origin credentials' => lambda { |c|
      c['backends']['inventory']['base_url'] = 'https://user:pass@inventory.example.test'
    },
    'origin path' => ->(c) { c['backends']['inventory']['base_url'] += '/prefix' },
    'absolute backend URL' => ->(c) { c['routes'][0]['backend']['path'] = 'http://other.example.test/' },
    'authority in path' => ->(c) { c['routes'][0]['backend']['path'] = '//other.example.test/' },
    'query in path' => ->(c) { c['routes'][0]['backend']['path'] = '/items?q=1' },
    'unknown template' => ->(c) { c['routes'][0]['backend']['path'] = '/{{values.absent}}' },
    'malformed template' => ->(c) { c['routes'][0]['backend']['path'] = '/{{values.absent' },
    'backend reference before call' => ->(c) { c['routes'][0]['backend']['path'] = '/{{backend.status}}' },
    'Ruby template expression' => ->(c) { c['routes'][0]['backend']['path'] = '/{{Kernel.exit}}' },
    'bad extraction' => ->(c) { c['routes'][0]['extract'] = { 'id' => { 'from' => 'cookie', 'key' => 'id' } } },
    'missing path key' => ->(c) { c['routes'][0]['extract'] = { 'id' => { 'from' => 'path', 'key' => 'id' } } },
    'invalid JSON pointer' => lambda { |c|
      c['routes'][0]['extract'] = { 'id' => { 'from' => 'body', 'pointer' => '/~2' } }
    },
    'framing header' => ->(c) { c['routes'][0]['backend']['headers'] = { 'Content-Length' => '5' } },
    'header injection' => ->(c) { c['routes'][0]['backend']['headers'] = { 'X-Test' => "one\r\nInjected: two" } },
    'duplicate header' => ->(c) { c['routes'][0]['backend']['headers'] = { 'X-Test' => 'one', 'x-test' => 'two' } },
    'invalid status' => ->(c) { c['routes'][0]['response'] = { 'status' => 101 } },
    'body with empty' => ->(c) { c['routes'][0]['response'] = { 'body' => {}, 'empty' => true } },
    'body on 204' => ->(c) { c['routes'][0]['response'] = { 'status' => 204, 'body' => {} } },
    'empty false' => ->(c) { c['routes'][0]['response'] = { 'empty' => false } },
    'static backend reference' => lambda { |c|
      c['routes'][0].delete('backend')
      c['routes'][0]['response'] = { 'body' => '{{backend.body:}}' }
    },
    'no response or backend' => ->(c) { c['routes'][0].delete('backend') },
    'duplicate route' => ->(c) { c['routes'] << c['routes'][0].dup }
  }
  invalid.each do |description, mutation|
    it "rejects #{description} at startup" do
      data = configuration
      mutation.call(data)
      expect { described_class.new(data) }.to raise_error(APICompatibilityLayer::ConfigError)
    end
  end

  ["version: 1\n---\nversion: 1", '', "version: 1\nversion: 2", '--- !ruby/object:Object {}',
   "a: &value {}\nb: *value", 'routes: ['].each do |source|
    it "rejects unsafe or ambiguous YAML #{source.inspect}" do
      Tempfile.create do |file|
        file.write(source)
        file.flush
        expect { described_class.load(file.path) }.to raise_error(APICompatibilityLayer::ConfigError)
      end
    end
  end

  it 'reports the route index for invalid configuration' do
    data = configuration
    data['routes'][0]['method'] = 'bad'
    expect { described_class.new(data) }.to raise_error(APICompatibilityLayer::ConfigError, /routes\[0\].*method/)
  end

  it 'reports a missing configuration file' do
    expect do
      described_class.load('/nonexistent/config.yaml')
    end.to raise_error(APICompatibilityLayer::ConfigError, /cannot load/)
  end
end
