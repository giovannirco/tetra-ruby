# frozen_string_literal: true

require 'etc'
require 'prometheus/client'
require 'prometheus/client/formats/text'

module Tetra
  # RED metrics for every request, calculation outcomes, and one structured
  # log line per request. Names and labels match the other Tetra
  # implementations, so one dashboard and one rule file cover all of them.
  class Telemetry
    STREAM_ROUTE = '/events'
    QUIET_ROUTES = %w[/healthz /readyz /metrics].freeze
    BUCKETS = [0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1].freeze
    CONTENT_TYPE = Prometheus::Client::Formats::Text::CONTENT_TYPE

    attr_reader :registry

    def initialize(info, live, logger)
      @live = live
      @logger = logger
      @registry = Prometheus::Client::Registry.new
      @requests = @registry.counter(:tetra_http_requests_total,
                                    docstring: 'HTTP requests by method, route and status code.',
                                    labels: %i[method route status])
      @duration = @registry.histogram(:tetra_http_request_duration_seconds,
                                      docstring: 'HTTP request latency by method and route.',
                                      labels: %i[method route], buckets: BUCKETS)
      @in_flight = @registry.gauge(:tetra_http_requests_in_flight,
                                   docstring: 'HTTP requests currently being served.')
      @calc_ops = @registry.counter(:tetra_calc_operations_total,
                                    docstring: 'Calculations by operation and outcome ' \
                                               '(ok, invalid_input, division_by_zero, overflow).',
                                    labels: %i[operation outcome])
      @registry.gauge(:tetra_build_info, docstring: 'Always 1; labels identify the running build.',
                                         labels: %i[implementation version commit runtime])
               .set(1, labels: info.slice(:implementation, :version, :commit, :runtime))
      @subscribers = @registry.gauge(:tetra_live_subscribers, docstring: 'Open Server-Sent Events streams.')
      @dropped = @registry.counter(:tetra_live_events_dropped_total,
                                   docstring: 'Live events dropped because a subscriber was too slow.')
      @rss = @registry.gauge(:process_resident_memory_bytes, docstring: 'Resident memory size in bytes.')
      @registry.gauge(:process_start_time_seconds, docstring: 'Start time of the process since the epoch.')
               .set(Time.now.to_f)
      @dropped_reported = 0
    end

    def calc_outcome(operation, outcome)
      @calc_ops.increment(labels: { operation:, outcome: })
    end

    # The exposition text; values read at scrape time are refreshed first.
    def scrape
      @subscribers.set(@live.subscribers)
      dropped = @live.dropped
      @dropped.increment(by: dropped - @dropped_reported) if dropped > @dropped_reported
      @dropped_reported = dropped
      rss = resident_memory
      @rss.set(rss) if rss
      Prometheus::Client::Formats::Text.marshal(@registry)
    end

    # Measures and logs one request through +app+.
    def around(app, env)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @in_flight.increment
      status, headers, body = app.call(env)
      [status, headers, body]
    ensure
      @in_flight.decrement
      record(env, status || 500, headers || {}, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
    end

    # Rack middleware: `use Telemetry::Middleware, telemetry`.
    class Middleware
      def initialize(app, telemetry)
        @app = app
        @telemetry = telemetry
      end

      def call(env) = @telemetry.around(@app, env)
    end

    # The route label: the matched template, so its values stay bounded.
    def self.route_of(env)
      return env['tetra.route'] if env['tetra.route']

      pattern = env['sinatra.route']&.split(' ', 2)&.last
      return 'unmatched' unless pattern

      pattern == '/*' ? '/' : pattern
    end

    private

    def record(env, status, headers, seconds)
      route = Telemetry.route_of(env)
      method = env['REQUEST_METHOD']
      @requests.increment(labels: { method:, route:, status: status.to_s })
      @duration.observe(seconds, labels: { method:, route: }) unless route == STREAM_ROUTE

      level = QUIET_ROUTES.include?(route) && status < 400 ? 'debug' : 'info'
      length = headers['content-length']
      @logger.log(level, 'request',
                  method:, path: env['PATH_INFO'], route:, status:,
                  bytes: length&.to_i, duration_ms: (seconds * 1e6).round / 1e3,
                  request_id: env['tetra.request_id'],
                  remote_addr: env['REMOTE_ADDR'], user_agent: env['HTTP_USER_AGENT'].to_s)
    end

    def resident_memory
      File.read('/proc/self/statm').split[1].to_i * Etc.sysconf(Etc::SC_PAGESIZE)
    rescue SystemCallError
      nil # not Linux: no /proc
    end
  end
end
