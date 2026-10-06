# frozen_string_literal: true

RSpec.describe APICompatibilityLayer::Template do
  it 'preserves JSON types for a whole-value reference' do
    [nil, false, 12, ['item'], { 'key' => 'value' }].each do |value|
      expect(described_class.render('{{values.value}}', { 'values' => { 'value' => value } })).to eq(value)
    end
  end

  it 'allows scalar interpolation but rejects structured interpolation' do
    expect(described_class.render('item-{{values.id}}', { 'values' => { 'id' => 7 } })).to eq('item-7')
    expect do
      described_class.render('item-{{values.id}}', { 'values' => { 'id' => [] } })
    end.to raise_error(APICompatibilityLayer::MappingError)
  end

  it 'selects array values and escaped JSON object keys' do
    expect(described_class.pointer({ 'a/b' => [{ '~' => false }] }, '/a~1b/0/~0')).to be(false)
  end

  %w[/missing /items/01 /items/-1 /items/3].each do |pointer|
    it "rejects unresolved pointer #{pointer}" do
      expect { described_class.pointer({ 'items' => [1] }, pointer) }.to raise_error(APICompatibilityLayer::MappingError)
    end
  end

  it 'does not evaluate Ruby, ERB, shell syntax or recursive request templates' do
    # These strings deliberately contain executable-looking syntax as inert data.
    # rubocop:disable Lint/InterpolationCheck
    payload = '#{Kernel.exit}; <%= Kernel.exit %>; $(exit); {{backend.status}}'
    expect(described_class.render('{{values.input}}', { 'values' => { 'input' => payload } })).to eq(payload)
    expect(described_class.render('<%= Kernel.exit %>', {})).to eq('<%= Kernel.exit %>')
    expect(described_class.render('#{Kernel.exit}', {})).to eq('#{Kernel.exit}')
    # rubocop:enable Lint/InterpolationCheck
  end

  it 'encodes untrusted path values as a segment' do
    output = described_class.render('/items/{{values.id}}', { 'values' => { 'id' => '../a?x=1#z' } }, path: true)
    expect(output).to eq('/items/%2E%2E%2Fa%3Fx%3D1%23z')
  end
end
