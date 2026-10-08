# frozen_string_literal: true

require 'json'
require 'sinatra/base'
require 'uri'
require_relative 'calc'

module Tetra
  # The routes: the four calculations, the catalogue, probes, metrics,
  # version and the UI. Collaborators (readiness, telemetry, the live
  # broker) are injected, so tests build a fresh app each time.
  class App < Sinatra::Base
    MAX_ECHO = 32
    INTEGER = /\A[+-]?\d+\z/

    configure do
      set :protection, false # security headers come from Tetra::SecurityHeaders
      set :host_authorization, { permitted_hosts: [] } # any Host: Service DNS, IPs, port-forward
      set :show_exceptions, false
      set :raise_errors, false
      set :dump_errors, false
      set :static, false
      set :logging, false
      set :x_cascade, false
      set :default_content_type, 'application/json'
    end

    def initialize(app = nil, deps: {})
      super(app)
      @deps = deps
    end

    def self.truncate(str) = str.length <= MAX_ECHO ? str : "#{str[0, MAX_ECHO]}…"

    # Parse a base-10 int64 with an optional sign.
    def self.parse_term(query, name)
      raw = query[name].to_s
      raise Calc::Error.new("missing query parameter #{name}", 'invalid_input') if raw.empty?
      unless raw.match?(INTEGER)
        raise Calc::Error.new("#{name} must be an integer, got #{JSON.generate(truncate(raw))}", 'invalid_input')
      end

      value = Integer(raw, 10)
      unless Calc::INT64.cover?(value)
        raise Calc::Error.new("#{name} is outside the 64-bit integer range", 'invalid_input')
      end

      value
    end

    attr_reader :deps

    helpers do
      def send_json(status_code, body)
        status status_code
        headers 'content-type' => 'application/json; charset=utf-8', 'cache-control' => 'no-store'
        "#{body.is_a?(String) ? body : JSON.generate(body)}\n"
      end

      def send_error(status_code, message) = send_json(status_code, { error: message })

      def method_not_allowed
        headers 'allow' => 'GET, HEAD'
        send_error(405, 'method not allowed')
      end

      # The raw query, first value winning, as in the other implementations.
      def query
        @query ||= URI.decode_www_form(request.query_string).each_with_object({}) do |(k, v), h|
          h[k] = v unless h.key?(k)
        end
      rescue ArgumentError
        @query = {}
      end

      def api_fallback(path)
        env['tetra.route'] = '/api/'
        Calc.lookup(path.delete_prefix('/api/')) ? method_not_allowed : send_error(404, 'not found')
      end
    end

    get '/api' do
      info = deps.fetch(:info)
      send_json(200, {
                  service: info[:service], implementation: info[:implementation], version: info[:version],
                  operations: Calc::OPERATIONS.map { |op| op.to_h.slice(:name, :symbol, :label).merge(path: "/api/#{op.name}") }
                })
    end

    Calc::OPERATIONS.each do |op|
      get "/api/#{op.name}" do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        event = {
          operation: op.name,
          term_one: App.truncate(query['term_one'].to_s),
          term_two: App.truncate(query['term_two'].to_s),
          result: nil, status: 200, outcome: 'ok',
          request_id: env['tetra.request_id'], time: Time.now.utc.iso8601(3)
        }
        begin
          result = op.apply.call(App.parse_term(query, 'term_one'), App.parse_term(query, 'term_two'))
          event[:result] = result.to_s
          body = send_json(200, %({"result":#{result}}))
        rescue Calc::Error => e
          event.merge!(status: 400, outcome: e.outcome, error: e.message)
          body = send_error(400, e.message)
        end
        event[:duration_ms] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
        deps[:on_event]&.call(event)
        body
      end
    end

    get('/healthz') { send_json(200, { status: 'ok' }) }

    get '/readyz' do
      deps.fetch(:ready).call ? send_json(200, { status: 'ready' }) : send_json(503, { status: 'draining' })
    end

    get('/version') { send_json(200, deps.fetch(:info)) }

    get '/metrics' do
      content_type Telemetry::CONTENT_TYPE
      deps.fetch(:telemetry).scrape
    end

    get '/*' do
      path = request.path_info
      next api_fallback(path) if path.start_with?('/api/')

      file = deps.fetch(:static).lookup(path)
      halt 404 unless file # body from not_found
      content_type file.type
      cache_control(*file.cache_control)
      file.body
    end

    # Sinatra runs this for every 404: an unrouted method (every GET and HEAD
    # matches /*) or a 404 halted by a route.
    not_found do
      path = request.path_info
      next api_fallback(path) if path.start_with?('/api/')

      env['tetra.route'] = '/'
      next method_not_allowed unless request.get? || request.head?

      content_type 'text/plain; charset=utf-8'
      "404 page not found\n"
    end

    error do
      err = env['sinatra.error']
      client_error = err.respond_to?(:http_status) && err.http_status.between?(400, 499)
      next send_error(err.http_status, err.message) if client_error # e.g. a malformed query string

      deps[:logger]&.error('unhandled error', request_id: env['tetra.request_id'],
                                              error: "#{err.class}: #{err.message}")
      send_error(500, 'internal error')
    end
  end
end
