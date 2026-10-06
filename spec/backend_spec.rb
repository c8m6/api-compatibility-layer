# frozen_string_literal: true

RSpec.describe APICompatibilityLayer::Backend do
  after do
    @server&.shutdown
    @thread&.join
  end

  def start_backend(&)
    @server, @thread = with_backend(&)
    "http://127.0.0.1:#{@server.config[:Port]}"
  end

  it 'translates POST JSON into a backend path, query, headers, JSON body and client response over HTTP' do
    received = Queue.new
    origin = start_backend do |req, res|
      received << { method: req.request_method, path: req.unparsed_uri, query: req.query_string,
                    auth: req['authorization'], client: req['x-client'], type: req['content-type'], body: req.body }
      res.status = 201
      res.body = '{"resource":{"id":17,"name":"Synthetic"}}'
    end
    data = YAML.safe_load_file('config/example.yaml')
    data['backends']['inventory']['base_url'] = origin
    response = engine(data).call(request(method: 'POST', path: '/legacy/items/a%2Fb', query: 'region=north%26east',
                                         headers: { 'Authorization' => 'Bearer synthetic-token' },
                                         body: '{"label":"Synthetic","enabled":false}'))
    expect(response.status).to eq(201)
    expect(JSON.parse(response.body)).to eq('item' => 17, 'label' => 'Synthetic')
    actual = received.pop
    expect(actual).to include(method: 'PUT', path: '/v2/resources/a%2Fb?location=north%26east',
                              query: 'location=north%26east', auth: 'Bearer synthetic-token',
                              client: 'compatibility-example', type: 'application/json')
    expect(JSON.parse(actual[:body])).to eq('name' => 'Synthetic', 'active' => false)
  end

  %w[GET POST PUT PATCH DELETE].each do |method|
    it "sends a backend #{method} request" do
      origin = start_backend do |req, res|
        req.body # Exercise request-body framing even when no body is configured.
        res.body = JSON.generate('method' => req.request_method)
      end
      data = configuration
      data['backends']['inventory']['base_url'] = origin
      data['routes'][0]['backend']['method'] = method
      expect(JSON.parse(engine(data).call(request).body)).to eq('method' => method)
    end
  end

  it 'does not follow backend redirects' do
    count = Queue.new
    origin = start_backend do |_req, res|
      count << true
      res.status = 302
      res['Location'] = 'http://other.example.test/private'
      res.body = '{"redirect":true}'
    end
    data = configuration
    data['backends']['inventory']['base_url'] = origin
    expect(engine(data).call(request).status).to eq(302)
    expect(count.size).to eq(1)
  end

  it 'maps connection failures to 502 without retries' do
    origin = start_backend { |_req, res| res.body = '{}' }
    @server.shutdown
    @thread.join
    data = configuration
    data['backends']['inventory']['base_url'] = origin
    expect(engine(data).call(request).status).to eq(502)
  end

  it 'enforces an overall backend timeout' do
    stub_const('APICompatibilityLayer::Backend::TIMEOUT', 0.05)
    origin = start_backend do |_req, res|
      sleep 0.15
      res.body = '{}'
    end
    data = configuration
    data['backends']['inventory']['base_url'] = origin
    expect(engine(data).call(request).status).to eq(504)
  end

  it 'limits backend response bytes' do
    origin = start_backend { |_req, res| res.body = 'x' * (described_class::MAX_BYTES + 1) }
    data = configuration
    data['backends']['inventory']['base_url'] = origin
    expect(engine(data).call(request).status).to eq(502)
  end

  it 'blocks CRLF header injection from extracted request values' do
    data = configuration
    data['routes'][0]['extract'] = { 'value' => { 'from' => 'query', 'key' => 'value' } }
    data['routes'][0]['backend']['headers'] = { 'X-Test' => '{{values.value}}' }
    expect(engine(data).call(request(query: 'value=a%0D%0AInjected%3Atrue')).status).to eq(422)
  end

  it 'rejects structured request values in query mappings' do
    data = configuration
    data['routes'][0]['extract'] = { 'value' => { 'from' => 'body', 'pointer' => '' } }
    data['routes'][0]['backend']['query'] = { 'q' => '{{values.value}}' }
    expect(engine(data).call(request(body: '{}')).status).to eq(422)
  end
  it 'preserves an explicitly configured lowercase content-type header' do
    origin = start_backend { |req, res| res.body = JSON.generate('type' => req['content-type']) }
    data = configuration
    data['backends']['inventory']['base_url'] = origin
    data['routes'][0]['backend'].merge!('body' => {}, 'headers' => { 'content-type' => 'application/example+json' })
    expect(JSON.parse(engine(data).call(request).body)).to eq('type' => 'application/example+json')
  end
end
