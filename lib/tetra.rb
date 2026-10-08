# frozen_string_literal: true

require 'rack'
require_relative 'tetra/app'
require_relative 'tetra/calc'
require_relative 'tetra/config'
require_relative 'tetra/live'
require_relative 'tetra/logger'
require_relative 'tetra/middleware'
require_relative 'tetra/static_files'
require_relative 'tetra/telemetry'
require_relative 'tetra/version'

# Tetra: a four-operation arithmetic API with live request telemetry.
module Tetra
  WEB_ROOT = File.expand_path('../web', __dir__)

  # The assembled service: a Rack app plus the hooks the server needs.
  Service = Struct.new(:rack_app, :info, :broker, :draining, keyword_init: true) do
    # Fail readiness; called when shutdown starts.
    def drain = draining.make_true
    def ready? = !draining.true?
    # End the live streams so the server can stop.
    def close_streams = broker.close
  end

  # A flag the readiness probe and the shutdown path share across threads.
  class Flag
    def initialize
      @mutex = Mutex.new
      @value = false
    end

    def make_true = @mutex.synchronize { @value = true }
    def true? = @mutex.synchronize { @value }
  end

  # Request path: request ID → security headers → telemetry → routes.
  def self.build(config, logger: Logger.new(config.log_level), env: ENV)
    info = version_info(env)
    broker = Broker.new(config.max_live_streams)
    telemetry = Telemetry.new(info, broker, logger)
    draining = Flag.new
    on_event = lambda do |event|
      telemetry.calc_outcome(event[:operation], event[:outcome])
      broker.publish(event)
    end
    app = App.new(deps: {
                    info:, telemetry:, logger:, on_event:,
                    ready: -> { !draining.true? },
                    static: StaticFiles.new(WEB_ROOT)
                  })
    events = EventsEndpoint.new(broker)

    rack_app = Rack::Builder.new do
      use RequestId
      use SecurityHeaders
      use Telemetry::Middleware, telemetry
      map('/events') { run events }
      run app
    end.to_app

    Service.new(rack_app:, info:, broker:, draining:)
  end
end
