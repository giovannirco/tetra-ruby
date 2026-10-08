# frozen_string_literal: true

require 'puma'
require 'puma/server'
require_relative '../tetra'

module Tetra
  # Runs the service on Puma and owns the shutdown sequence: fail
  # readiness, keep serving for the drain delay, end the live streams, then
  # let Puma finish in-flight requests (cut after the shutdown timeout).
  #
  # Puma is embedded rather than launched, because the launcher's own
  # SIGTERM handling would close the listener before the drain delay.
  class Server
    THREADS = 16

    attr_reader :service

    def initialize(env: ENV, out: $stdout)
      @config = Config.load(env)
      @logger = Logger.new(@config.log_level, out)
      @service = Tetra.build(@config, logger: @logger, env:)
      @puma = Puma::Server.new(@service.rack_app, nil,
                               min_threads: 0, max_threads: THREADS,
                               log_writer: Puma::LogWriter.null,
                               first_data_timeout: 10, persistent_timeout: 60,
                               force_shutdown_after: @config.shutdown_timeout)
      @puma.add_tcp_listener('0.0.0.0', @config.port)
      @thread = @puma.run
      @stop_mutex = Mutex.new
      @logger.info('listening', addr: ":#{@config.port}", version: @service.info[:version])
    end

    def port = @puma.connected_ports.first

    # Runs the shutdown sequence once; later calls wait for the first.
    def stop
      @stop_mutex.synchronize do
        @stopping ||= Thread.new do
          @logger.info('shutting down', drain_delay: "#{@config.drain_delay}s")
          @service.drain
          sleep @config.drain_delay
          @service.close_streams
          @puma.stop(true)
          @logger.info('stopped')
        end
      end.join
    end

    # Blocks until Puma has stopped.
    def wait = @thread.join
  end
end
