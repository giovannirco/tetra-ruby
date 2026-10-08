# frozen_string_literal: true

RSpec.describe Tetra::Calc do
  max = Tetra::Calc::MAX_INT64
  min = Tetra::Calc::MIN_INT64
  apply = ->(name, a, b) { described_class.lookup(name).apply.call(a, b) }

  [
    ['sum', 4, 1, 5], ['sum', -4, -6, -10], ['sum', max - 1, 1, max],
    ['sub', 4, 1, 3], ['sub', 1, 4, -3], ['sub', min + 1, 1, min],
    ['mul', 6, 7, 42], ['mul', max, 0, 0], ['mul', -3, 5, -15], ['mul', min, 1, min],
    ['div', 8, 2, 4], ['div', 7, 2, 3], ['div', -7, 2, -3], ['div', 7, -2, -3], ['div', -7, -2, 3]
  ].each do |name, a, b, want|
    it("#{name}(#{a}, #{b}) = #{want}") { expect(apply.call(name, a, b)).to eq(want) }
  end

  [
    ['sum', max, 1, 'overflow'], ['sum', min, -1, 'overflow'],
    ['sub', max, -1, 'overflow'], ['sub', min, 1, 'overflow'],
    ['mul', max, 2, 'overflow'], ['mul', min, -1, 'overflow'], ['mul', 2**32, 2**32, 'overflow'],
    ['div', 1, 0, 'division_by_zero'], ['div', 0, 0, 'division_by_zero'], ['div', min, -1, 'overflow']
  ].each do |name, a, b, outcome|
    it "#{name}(#{a}, #{b}) fails with #{outcome}" do
      expect { apply.call(name, a, b) }.to raise_error(Tetra::Calc::Error) { |e| expect(e.outcome).to eq(outcome) }
    end
  end

  it 'lists the four operations in order, frozen' do
    expect(described_class::OPERATIONS.map(&:name)).to eq(%w[sum sub mul div])
    expect(described_class::OPERATIONS).to all(satisfy { |op| op.symbol && op.label && op.frozen? })
    expect(described_class::OPERATIONS).to be_frozen
    expect(described_class.lookup('pow')).to be_nil
  end
end
