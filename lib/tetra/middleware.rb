# frozen_string_literal: true

require 'securerandom'

module Tetra
  # Keeps a well-formed incoming X-Request-Id (set by a gateway, say) or
  # makes one, stores it in env['tetra.request_id'] and echoes it back.
  class RequestId
    VALID = /\A[A-Za-z0-9._-]{1,64}\z/

    def initialize(app) = @app = app

    def self.for(incoming) = incoming.to_s.match?(VALID) ? incoming : SecureRandom.hex(16)

    def call(env)
      id = env['tetra.request_id'] = RequestId.for(env['HTTP_X_REQUEST_ID'])
      status, headers, body = @app.call(env)
      headers['x-request-id'] = id
      [status, headers, body]
    end
  end

  # Same-origin-only Content-Security-Policy plus the usual hardening headers.
  class SecurityHeaders
    HEADERS = {
      'content-security-policy' => "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; " \
                                   "connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
      'x-content-type-options' => 'nosniff',
      'referrer-policy' => 'no-referrer',
      'x-frame-options' => 'DENY'
    }.freeze

    def initialize(app) = @app = app

    def call(env)
      status, headers, body = @app.call(env)
      HEADERS.each { |k, v| headers[k] = v }
      [status, headers, body]
    end
  end

  # GET /events: hands the socket to the broker through a Rack response
  # hijack, so the stream holds no server thread.
  class EventsEndpoint
    def initialize(broker) = @broker = broker

    def call(env)
      env['tetra.route'] = '/events'
      method = env['REQUEST_METHOD']
      unless %w[GET HEAD].include?(method)
        return [405, { 'content-type' => 'application/json; charset=utf-8', 'allow' => 'GET, HEAD' },
                [%({"error":"method not allowed"}\n)]]
      end
      unless @broker.accepting?
        return [503, { 'content-type' => 'application/json; charset=utf-8' }, [%({"error":"too many live streams"}\n)]]
      end

      headers = {
        'content-type' => 'text/event-stream',
        'cache-control' => 'no-store',
        'x-accel-buffering' => 'no',
        'rack.hijack' => ->(io) { @broker.attach(io) }
      }
      [200, headers, []]
    end
  end
end
