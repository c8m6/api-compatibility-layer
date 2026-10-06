# frozen_string_literal: true

RSpec.describe APICompatibilityLayer::Engine do
  let(:backend) { instance_double(APICompatibilityLayer::Backend) }
  let(:data) { configuration }
  let(:route) { data['routes'][0] }
  let(:result) { APICompatibilityLayer::Backend::Result.new(status: 201, body: '{"data":{"id":7,"active":false}}') }

  before { allow(backend).to receive(:call).and_return(result) }

  def run_request(**)
    engine(data, backend: backend).call(request(**))
  end

  it 'forwards backend status and JSON by default' do
    response = run_request
    expect(response.status).to eq(201)
    expect(JSON.parse(response.body)).to eq('data' => { 'id' => 7, 'active' => false })
  end

  %w[GET POST PUT PATCH DELETE].each do |method|
    it "matches #{method}" do
      route['method'] = method
      expect(run_request(method: method).status).to eq(201)
    end
  end

  it 'matches the method, path and trailing slash exactly' do
    expect(run_request(method: 'POST').status).to eq(404)
    expect(run_request(path: '/legacy/items/').status).to eq(404)
    expect(run_request(path: '/absent').status).to eq(404)
    expect(backend).not_to have_received(:call)
  end

  it 'uses the first matching route' do
    data['routes'].unshift('method' => 'GET', 'path' => '/legacy/:id', 'response' => { 'body' => 'first' })
    expect(JSON.parse(run_request.body)).to eq('first')
    expect(backend).not_to have_received(:call)
  end

  it 'extracts path, query, header and JSON values including false and null' do
    route['path'] = '/legacy/items/:id'
    route['extract'] = {
      'id' => { 'from' => 'path', 'key' => 'id' },
      'search' => { 'from' => 'query', 'key' => 'q' },
      'token' => { 'from' => 'header', 'key' => 'AUTHORIZATION' },
      'active' => { 'from' => 'body', 'pointer' => '/active' },
      'optional' => { 'from' => 'body', 'pointer' => '/optional' }
    }
    run_request(path: '/legacy/items/a%20b', query: 'q=first&q=last+value',
                headers: { 'Authorization' => 'Bearer synthetic' }, body: '{"active":false,"optional":null}')
    values = { 'id' => 'a b', 'search' => 'last value', 'token' => 'Bearer synthetic',
               'active' => false, 'optional' => nil }
    expect(backend).to have_received(:call).with(anything, anything, hash_including('values' => values))
  end

  it 'ignores incoming authorization unless mapped' do
    expect(run_request(headers: { 'Authorization' => 'arbitrary synthetic value' }).status).to eq(201)
  end

  it 'transforms backend JSON selections and status' do
    route['response'] = { 'status' => 200, 'body' => { 'identifier' => '{{backend.body:/data/id}}',
                                                       'enabled' => '{{backend.body:/data/active}}' } }
    response = run_request
    expect(response.status).to eq(200)
    expect(JSON.parse(response.body)).to eq('identifier' => 7, 'enabled' => false)
  end

  it 'returns a static response without a backend' do
    route.delete('backend')
    route['response'] = { 'status' => 202, 'body' => { 'ok' => true } }
    expect(run_request.status).to eq(202)
    expect(backend).not_to have_received(:call)
  end

  it 'can return JSON null' do
    route['response'] = { 'body' => nil }
    expect(run_request.body).to eq('null')
  end

  it 'returns an empty response without content type' do
    route['response'] = { 'status' => 204, 'empty' => true }
    response = run_request
    expect(response.status).to eq(204)
    expect(response.body).to eq('')
    expect(response.headers).to eq({})
  end

  it 'does not parse an ignored backend body' do
    allow(backend).to receive(:call).and_return(APICompatibilityLayer::Backend::Result.new(status: 200,
                                                                                           body: 'not JSON'))
    route['response'] = { 'body' => 'static' }
    expect(run_request.body).to eq('"static"')
  end

  [204, 205, 304].each do |status|
    it "suppresses a body for backend status #{status}" do
      allow(backend).to receive(:call).and_return(APICompatibilityLayer::Backend::Result.new(status: status, body: ''))
      expect(run_request.body).to eq('')
    end
  end

  it 'preserves backend HTTP errors for declarative transformation' do
    allow(backend).to receive(:call).and_return(APICompatibilityLayer::Backend::Result.new(status: 503,
                                                                                           body: '{"busy":true}'))
    expect(run_request.status).to eq(503)
  end

  { APICompatibilityLayer::BackendError => 502, APICompatibilityLayer::BackendTimeout => 504 }.each do |error, status|
    it "handles #{error}" do
      allow(backend).to receive(:call).and_raise(error)
      expect(run_request.status).to eq(status)
    end
  end

  it 'rejects invalid JSON before calling a backend' do
    expect(run_request(body: '{').status).to eq(400)
    expect(backend).not_to have_received(:call)
  end

  it 'rejects oversized input' do
    expect(run_request(body: 'x' * (APICompatibilityLayer::Backend::MAX_BYTES + 1)).status).to eq(413)
    expect(backend).not_to have_received(:call)
  end

  it 'reports missing required extractions' do
    route['extract'] = { 'id' => { 'from' => 'query', 'key' => 'id' } }
    expect(run_request.status).to eq(422)
    expect(backend).not_to have_received(:call)
  end

  it 'reports unresolved backend pointers' do
    route['response'] = { 'body' => '{{backend.body:/missing}}' }
    expect(run_request.status).to eq(502)
  end

  it 'reports non-JSON backend responses without leaking their content' do
    allow(backend).to receive(:call).and_return(APICompatibilityLayer::Backend::Result.new(status: 200,
                                                                                           body: 'private detail'))
    expect(run_request.status).to eq(502)
    expect(run_request.body).not_to include('private detail')
  end
end
