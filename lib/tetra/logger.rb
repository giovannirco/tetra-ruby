# frozen_string_literal: true

require 'json'
require 'time'

module Tetra
  # JSON-lines logger with the same keys as the other implementations:
  # {"time":…,"level":"INFO","msg":…, …fields}.
  class Logger
    LEVELS = { 'debug' => 10, 'info' => 20, 'warn' => 30, 'error' => 40 }.freeze

    def initialize(level = 'info', out = $stdout)
      @min = LEVELS.fetch(level)
      @out = out
      @mutex = Mutex.new
    end

    def log(level, msg, **fields)
      return if LEVELS.fetch(level) < @min

      entry = { time: Time.now.utc.iso8601(3), level: level.upcase, msg: msg }
      fields.each { |k, v| entry[k] = v unless v.nil? }
      line = "#{JSON.generate(entry)}\n"
      @mutex.synchronize do
        @out.write(line)
        @out.flush if @out.respond_to?(:flush)
      end
    end

    LEVELS.each_key do |level|
      define_method(level) { |msg, **fields| log(level, msg, **fields) }
    end
  end
end
