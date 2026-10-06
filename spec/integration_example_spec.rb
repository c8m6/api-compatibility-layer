# frozen_string_literal: true

RSpec.describe 'Complete synthetic compatibility example' do
  before do
    @received = Queue.new
    received = @received
    records = [
      { 'name' => 'lb.example.test', 'type' => 'CNAME', 'value' => 'other.example.test' },
      { 'name' => 'other.example.test', 'type' => 'A', 'value' => '192.0.2.20' },
      { 'name' => 'lb.example.test', 'type' => 'A', 'value' => '192.0.2.10' },
      { 'name' => 'alias.example.test', 'type' => 'CNAME', 'value' => 'target.example.test' }
    ]
    @server, @thread = with_backend do |req, res|
      received << { method: req.request_method, path: req.path, body: req.body, authorization: req['authorization'] }
      if req.request_method == 'POST'
        records << JSON.parse(req.body)
        res.status = 201
        res.body = JSON.generate(records.last)
      else
        res.body = JSON.generate(records)
      end
    end
    data = YAML.safe_load_file('config/integration-example.yaml')
    data['backends']['inventory']['base_url'] = "http://127.0.0.1:#{@server.config[:Port]}"
    @app = engine(data)
  end

  after do
    @server&.shutdown
    @thread&.join
  end

  def call(path, query: '', method: 'GET', body: '')
    @app.call(request(path: path, query: query, method: method, body: body,
                      headers: { 'Authorization' => 'Bearer synthetic-client-only' }))
  end

  it 'selects known zones from literal data and returns [] for an unknown domain without backend calls' do
    %w[example.test lab.example.test].each do |domain|
      response = call('/zone_auth', query: "fqdn=#{domain}")
      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)).to eq([{ 'name' => domain }])
    end
    expect(JSON.parse(call('/zone_auth', query: 'fqdn=missing.example.test').body)).to eq([])
    expect(@received).to be_empty
  end

  it 'returns [] for a host lookup without calling a backend' do
    response = call('/record:host', query: 'name=lb.example.test')
    expect(response.status).to eq(200)
    expect(JSON.parse(response.body)).to eq([])
    expect(@received).to be_empty
  end

  it 'selects an A value using both fields and does not implicitly forward Authorization' do
    response = call('/record:a', query: 'name=lb.example.test')
    expect(response.status).to eq(200)
    expect(JSON.parse(response.body)).to eq([{ 'ipv4addr' => '192.0.2.10' }])
    expect(@received.pop).to include(method: 'GET', path: '/v1/entries', authorization: nil)
  end

  it 'selects a CNAME value using both fields' do
    response = call('/record:cname', query: 'name=alias.example.test')
    expect(response.status).to eq(200)
    expect(JSON.parse(response.body)).to eq([{ 'canonical' => 'target.example.test' }])
  end

  %w[/record:a /record:cname].each do |path|
    it "returns [] for a missing value at #{path}" do
      response = call(path, query: 'name=missing.example.test')
      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)).to eq([])
    end
  end

  it 'returns the same static test IP regardless of network input without a backend call' do
    %w[192.0.2.0 198.51.100.0 arbitrary-data].each do |network|
      response = call('/ipv4address', query: "network=#{network}&status=UNUSED")
      expect(JSON.parse(response.body)).to eq([{ 'ip_address' => '192.0.2.10' }])
    end
    expect(@received).to be_empty
  end

  it 'creates an A entry with a deterministic ID using the existing request mapping and looks it up' do
    response = call('/record:a', method: 'POST', body: '{"name":"new.example.test","ipv4addr":"192.0.2.10"}')
    expect(response.status).to eq(201)
    expect(response.body).to eq('')
    outgoing = @received.pop
    expect(outgoing).to include(method: 'POST', path: '/v1/entries', authorization: nil)
    expect(JSON.parse(outgoing[:body])).to eq('id' => 'A:new.example.test', 'name' => 'new.example.test',
                                              'type' => 'A', 'value' => '192.0.2.10')
    expect(JSON.parse(call('/record:a', query: 'name=new.example.test').body)).to eq([{ 'ipv4addr' => '192.0.2.10' }])
  end

  it 'acknowledges PTR creation with a static 204 and no backend call' do
    response = call('/record:ptr', method: 'POST', body: '{"ipv4addr":"192.0.2.10","ptrdname":"lb.example.test"}')
    expect(response.status).to eq(204)
    expect(response.body).to eq('')
    expect(@received).to be_empty
  end

  it 'creates a CNAME entry with a deterministic ID using the existing mapping and looks it up' do
    response = call('/record:cname', method: 'POST',
                                     body: '{"name":"new-alias.example.test","canonical":"target.example.test"}')
    expect(response.status).to eq(201)
    outgoing = @received.pop
    expect(outgoing).to include(method: 'POST', path: '/v1/entries', authorization: nil)
    expect(JSON.parse(outgoing[:body])).to eq('id' => 'CNAME:new-alias.example.test',
                                              'name' => 'new-alias.example.test',
                                              'type' => 'CNAME', 'value' => 'target.example.test')
    expect(JSON.parse(call('/record:cname', query: 'name=new-alias.example.test').body))
      .to eq([{ 'canonical' => 'target.example.test' }])
  end
end
