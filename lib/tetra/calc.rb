# frozen_string_literal: true

module Tetra
  # The arithmetic operations exposed by the API.
  #
  # Ruby integers never overflow, so every result is range-checked against
  # int64 to keep the API identical to the other implementations. To add an
  # operation, append it to OPERATIONS: the routes, the catalogue and the UI
  # all read this list.
  module Calc
    MAX_INT64 = (2**63) - 1
    MIN_INT64 = -(2**63)
    INT64 = (MIN_INT64..MAX_INT64)

    # An error the API answers with 400; +outcome+ labels it in metrics.
    class Error < StandardError
      attr_reader :outcome

      def initialize(message, outcome)
        super(message)
        @outcome = outcome
      end
    end

    Operation = Struct.new(:name, :symbol, :label, :apply, keyword_init: true)

    def self.checked(result)
      raise Error.new('result overflows a 64-bit integer', 'overflow') unless INT64.cover?(result)

      result
    end

    # Ruby's Integer#/ floors (-7 / 2 == -4). The contract truncates toward
    # zero (-7 / 2 == -3), as Go, C and Java do, so divide exactly and truncate.
    def self.truncated_division(a, b)
      raise Error.new('division by zero', 'division_by_zero') if b.zero?

      checked(Rational(a, b).truncate)
    end

    OPERATIONS = [
      Operation.new(name: 'sum', symbol: '+', label: 'Addition', apply: ->(a, b) { checked(a + b) }),
      Operation.new(name: 'sub', symbol: '−', label: 'Subtraction', apply: ->(a, b) { checked(a - b) }),
      Operation.new(name: 'mul', symbol: '×', label: 'Multiplication', apply: ->(a, b) { checked(a * b) }),
      Operation.new(name: 'div', symbol: '÷', label: 'Division', apply: ->(a, b) { truncated_division(a, b) })
    ].map(&:freeze).freeze

    def self.lookup(name)
      OPERATIONS.find { |op| op.name == name }
    end
  end
end
