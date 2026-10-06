# frozen_string_literal: true

RSpec.describe 'Selection configuration' do
  let(:data) { configuration }
  let(:selection) do
    { 'from' => '{{backend.body:}}', 'where' => { '/name' => '{{values.name}}' },
      'project' => { 'value' => '{{item:/value}}' } }
  end

  before do
    data['routes'][0]['extract'] = { 'name' => { 'from' => 'query', 'key' => 'name' } }
    data['routes'][0]['response'] = { 'select' => selection }
  end

  invalid = {
    'missing source' => ->(s) { s.delete('from') },
    'missing projection' => ->(s) { s.delete('project') },
    'unknown option' => ->(s) { s['sort'] = '/name' },
    'non-string option' => ->(s) { s[1] = true },
    'object source' => ->(s) { s['from'] = {} },
    'scalar source' => ->(s) { s['from'] = 1 },
    'request source' => ->(s) { s['from'] = '{{values.name}}' },
    'status source' => ->(s) { s['from'] = '{{backend.status}}' },
    'embedded source reference' => ->(s) { s['from'] = 'prefix{{backend.body:}}' },
    'multiple source references' => ->(s) { s['from'] = '{{backend.body:}}{{backend.body:}}' },
    'invalid source pointer' => ->(s) { s['from'] = '{{backend.body:/~2}}' },
    'empty conditions' => ->(s) { s['where'] = {} },
    'non-mapping conditions' => ->(s) { s['where'] = [] },
    'relative filter pointer' => ->(s) { s['where'] = { 'name' => 'example.test' } },
    'non-string filter pointer' => ->(s) { s['where'] = { 1 => true } },
    'invalid filter escape' => ->(s) { s['where'] = { '/~2' => 'value' } },
    'array comparison literal' => ->(s) { s['where'] = { '/name' => [] } },
    'object comparison literal' => ->(s) { s['where'] = { '/name' => {} } },
    'non-finite comparison' => ->(s) { s['where'] = { '/name' => Float::INFINITY } },
    'embedded comparison template' => ->(s) { s['where'] = { '/name' => 'prefix-{{values.name}}' } },
    'unknown comparison variable' => ->(s) { s['where'] = { '/name' => '{{values.missing}}' } },
    'item reference in comparison' => ->(s) { s['where'] = { '/name' => '{{item:/name}}' } },
    'backend reference in comparison' => ->(s) { s['where'] = { '/name' => '{{backend.status}}' } },
    'Ruby expression' => ->(s) { s['where'] = { '/name' => '{{Kernel.exit}}' } },
    'unknown projection variable' => ->(s) { s['project'] = '{{values.missing}}' },
    'invalid projection pointer' => ->(s) { s['project'] = '{{item:/~2}}' },
    'malformed projection template' => ->(s) { s['project'] = '{{item:/name' },
    'non-JSON literal source' => ->(s) { s['from'] = [Float::NAN] },
    'non-JSON projection' => ->(s) { s['project'] = Float::INFINITY }
  }
  invalid.each do |description, mutation|
    it "rejects #{description} at startup" do
      mutation.call(selection)
      expect do
        APICompatibilityLayer::Config.new(data)
      end.to raise_error(APICompatibilityLayer::ConfigError, /routes\[0\]/)
    end
  end

  [nil, [], 'select'].each do |value|
    it "rejects a select block of #{value.inspect}" do
      data['routes'][0]['response']['select'] = value
      expect { APICompatibilityLayer::Config.new(data) }.to raise_error(APICompatibilityLayer::ConfigError)
    end
  end

  %w[body empty].each do |key|
    it "rejects select with response.#{key}" do
      data['routes'][0]['response'][key] = key == 'body' ? nil : true
      expect { APICompatibilityLayer::Config.new(data) }.to raise_error(APICompatibilityLayer::ConfigError, /exclusive/)
    end
  end

  it 'rejects backend references without a backend' do
    data['routes'][0].delete('backend')
    expect { APICompatibilityLayer::Config.new(data) }.to raise_error(APICompatibilityLayer::ConfigError)
  end

  it 'rejects a select response with a bodyless HTTP status' do
    data['routes'][0]['response']['status'] = 204
    expect { APICompatibilityLayer::Config.new(data) }.to raise_error(APICompatibilityLayer::ConfigError)
  end

  it 'rejects item references in an ordinary response body' do
    data['routes'][0]['response'] = { 'body' => '{{item:/value}}' }
    expect { APICompatibilityLayer::Config.new(data) }.to raise_error(APICompatibilityLayer::ConfigError)
  end

  it 'rejects item references in the backend request' do
    data['routes'][0]['backend']['body'] = '{{item:/value}}'
    expect { APICompatibilityLayer::Config.new(data) }.to raise_error(APICompatibilityLayer::ConfigError)
  end

  it 'accepts a static source with template-looking strings as literal data' do
    data['routes'][0].delete('backend')
    selection['from'] = [{ 'name' => '{{not.an.expression}}', 'value' => '{{item:/missing}}' }]
    expect { APICompatibilityLayer::Config.new(data) }.not_to raise_error
  end
end
