# frozen_string_literal: true

module Tetra
  # Runtime settings from the environment. Every setting has a default.
  class Config
    LEVELS = %w[debug info warn error].freeze

    attr_reader :port, :log_level, :drain_delay, :shutdown_timeout, :max_live_streams

    def initialize(port: 8000, log_level: 'info', drain_delay: 5, shutdown_timeout: 10, max_live_streams: 100)
      @port = port
      @log_level = log_level
      @drain_delay = drain_delay
      @shutdown_timeout = shutdown_timeout
      @max_live_streams = max_live_streams
    end

    def self.load(env = ENV)
      level = env['LOG_LEVEL'].to_s.empty? ? 'info' : env['LOG_LEVEL'].downcase
      unless LEVELS.include?(level)
        raise ArgumentError, "LOG_LEVEL: #{env['LOG_LEVEL'].inspect} is not one of #{LEVELS.join(', ')}"
      end

      new(
        port: int(env, 'PORT', 8000, 1, 65_535),
        log_level: level,
        drain_delay: int(env, 'DRAIN_DELAY_SECONDS', 5, 0, 300),
        shutdown_timeout: int(env, 'SHUTDOWN_TIMEOUT_SECONDS', 10, 1, 300),
        max_live_streams: int(env, 'MAX_LIVE_STREAMS', 100, 0, 10_000)
      )
    end

    def self.int(env, name, default, min, max)
      raw = env[name].to_s
      return default if raw.empty?

      value = raw.match?(/\A-?\d+\z/) ? Integer(raw, 10) : nil
      return value if value&.between?(min, max)

      raise ArgumentError, "#{name}: #{raw.inspect} must be an integer between #{min} and #{max}"
    end
    private_class_method :int

    def to_h
      { port:, log_level:, drain_delay:, shutdown_timeout:, max_live_streams: }
    end
  end
end
