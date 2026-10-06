# frozen_string_literal: true

RSpec.describe APICompatibilityLayer::Selection do
  def select(source, where: { '/name' => 'example.test' }, project: '{{item:/value}}', values: {})
    selection = { 'from' => source, 'where' => where, 'project' => project }
    described_class.validate(selection, names: values.keys, backend: false)
    described_class.render(selection, { 'values' => values })
  end

  it 'combines conditions with AND and projects only the first matching element' do
    rows = [{ 'name' => 'other.test', 'type' => 'A', 'value' => 1 },
            { 'name' => 'example.test', 'type' => 'CNAME', 'value' => 2 },
            { 'name' => 'example.test', 'type' => 'A', 'value' => 3 },
            { 'name' => 'example.test', 'type' => 'A', 'value' => 4 }]
    expect(select(rows, where: { '/name' => '{{values.name}}', '/type' => 'A' },
                        values: { 'name' => 'example.test' })).to eq([3])
  end

  it 'returns exactly [] without evaluating project when no element matches' do
    expect(select([], project: '{{item:/missing}}')).to eq([])
    expect(select([{ 'name' => 'other.test' }], project: '{{item:/missing}}')).to eq([])
  end

  it 'skips elements missing a filter pointer, including missing versus explicit null' do
    expect(select([{}, { 'value' => nil }], where: { '/value' => nil },
                                            project: '{{item:}}')).to eq([{ 'value' => nil }])
  end

  it 'does not convert strings, numbers or booleans during comparison' do
    expect(select([{ 'value' => 1 }], where: { '/value' => '1' })).to eq([])
    expect(select([{ 'value' => false }], where: { '/value' => 0 })).to eq([])
    expect(select([{ 'value' => 'false' }], where: { '/value' => false })).to eq([])
    expect(select([{ 'value' => 1 }], where: { '/value' => 1.0 })).to eq([1])
  end

  it 'supports deep JSON equality for a complete extracted value reference' do
    value = { 'list' => [1, false, nil] }
    expect(select([{ 'value' => value }], where: { '/value' => '{{values.expected}}' },
                                          values: { 'expected' => value })).to eq([value])
  end

  it 'supports root pointers and scalar, null, false and array elements' do
    [nil, false, 7, 'item', [1, 2]].each do |value|
      expect(select([value], where: { '' => '{{values.expected}}' }, project: '{{item:}}',
                             values: { 'expected' => value })).to eq([value])
    end
  end

  it 'supports escaped keys and nested array pointers in filters and projections' do
    rows = [{ 'a/b' => [{ '~' => true }], 'value' => ['result'] }]
    expect(select(rows, where: { '/a~1b/0/~0' => true }, project: '{{item:/value/0}}')).to eq(['result'])
  end

  it 'does not fall back to later matches if the first projection fails' do
    rows = [{ 'name' => 'example.test' }, { 'name' => 'example.test', 'value' => 'later' }]
    expect { select(rows) }.to raise_error(APICompatibilityLayer::MappingError)
  end

  it 'does not recursively evaluate source or request values, including code-looking strings' do
    # rubocop:disable-next Lint/InterpolationCheck
    payload = '#{Kernel.exit}; <%= Kernel.exit %>; $(exit); {{item:/missing}}'
    result = select([{ 'name' => payload, 'value' => '{{values.missing}}' }],
                    where: { '/name' => '{{values.input}}' },
                    project: { 'selected' => '{{item:/value}}', 'request' => '{{values.input}}' },
                    values: { 'input' => payload })
    expect(result).to eq([{ 'selected' => '{{values.missing}}', 'request' => payload }])
  end

  describe 'response errors' do
    let(:backend) { instance_double(APICompatibilityLayer::Backend) }
    let(:data) { configuration }

    before do
      data['routes'][0]['response'] = {
        'select' => { 'from' => '{{backend.body:/rows}}', 'where' => { '/name' => 'example.test' },
                      'project' => '{{item:/value}}' }
      }
    end

    def respond(body, status: 200)
      allow(backend).to receive(:call).and_return(APICompatibilityLayer::Backend::Result.new(status: status,
                                                                                             body: body))
      engine(data, backend: backend).call(request)
    end

    ['{}', '{"rows":{}}', '{"rows":null}', '{"rows":1}', '{"rows":"[]"}', 'invalid',
     '{"rows":[{"name":"example.test"}]}'].each do |body|
      it "returns 502 for invalid source or projection #{body.inspect}" do
        response = respond(body)
        expect(response.status).to eq(502)
        expect(JSON.parse(response.body)).to eq('error' => 'response_mapping_failed')
      end
    end

    it 'selects from a nested backend array and leaves backend error status intact' do
      response = respond('{"rows":[{"name":"example.test","value":false}]}', status: 503)
      expect(response.status).to eq(503)
      expect(JSON.parse(response.body)).to eq([false])
    end

    it 'retains the output size limit after projection' do
      data['routes'][0]['response']['select']['project'] = '{{item:/value}}{{item:/value}}'
      body = JSON.generate('rows' => [{ 'name' => 'example.test',
                                        'value' => 'x' * (APICompatibilityLayer::Backend::MAX_BYTES / 2) }])
      expect(respond(body).status).to eq(502)
    end
  end
end
