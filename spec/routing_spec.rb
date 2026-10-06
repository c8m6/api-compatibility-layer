# frozen_string_literal: true

RSpec.describe 'Route segment syntax' do
  def static_route(path, method: 'GET')
    { 'method' => method, 'path' => path, 'response' => { 'body' => path } }
  end

  %w[/record:a /record:cname /record:host /record:ptr /items/prefix:id /items/a:b:c].each do |path|
    it "matches #{path} literally without creating parameters" do
      app = engine(configuration(static_route(path)))
      expect(JSON.parse(app.call(request(path: path)).body)).to eq(path)
      expect(app.call(request(path: path.sub(':', '-'))).status).to eq(404)
    end
  end

  it 'keeps different literal colon routes distinct in duplicate detection and matching' do
    paths = %w[/record:a /record:cname /record:host /record:ptr]
    app = engine({ 'version' => 1, 'routes' => paths.map { |path| static_route(path) } })
    paths.each { |path| expect(JSON.parse(app.call(request(path: path)).body)).to eq(path) }
  end

  ['/items/:id', '/record:a/:id', '/items/:id/action:run'].each do |path|
    it "extracts full parameter segments in #{path}" do
      route = static_route(path)
      route['extract'] = { 'id' => { 'from' => 'path', 'key' => 'id' } }
      route['response'] = { 'body' => '{{values.id}}' }
      app = engine(configuration(route))
      expect(JSON.parse(app.call(request(path: path.sub(':id', 'a%3Ab'))).body)).to eq('a:b')
    end
  end

  [['/items/:id', '/items/:other'], ['/record:a/:id', '/record:a/:other'], ['/record:a', '/record:a']].each do |paths|
    it "rejects duplicate patterns #{paths.inspect}" do
      expect do
        engine({ 'version' => 1, 'routes' => paths.map { |path| static_route(path) } })
      end.to raise_error(APICompatibilityLayer::ConfigError, /duplicate/)
    end
  end

  it 'allows the same literal path for different methods' do
    data = { 'version' => 1, 'routes' => [static_route('/record:a'), static_route('/record:a', method: 'POST')] }
    expect { engine(data) }.not_to raise_error
  end

  it 'does not confuse literal names with path parameter extraction keys' do
    route = static_route('/record:a')
    route['extract'] = { 'id' => { 'from' => 'path', 'key' => 'a' } }
    expect { engine(configuration(route)) }.to raise_error(APICompatibilityLayer::ConfigError, /unknown path parameter/)
  end

  %w[/items/: /items/:9id /items/:bad-name /items/:id:suffix /:id/:id /items/:id.json items/:id /items?x=1
     /items#x].each do |path|
    it "rejects invalid or ambiguous path #{path}" do
      expect { engine(configuration(static_route(path))) }.to raise_error(APICompatibilityLayer::ConfigError)
    end
  end
end
