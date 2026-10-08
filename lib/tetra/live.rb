# frozen_string_literal: true

require 'json'

module Tetra
  # Fans calculation events out to browsers over Server-Sent Events.
  #
  # A stream does not hold a Puma thread: the endpoint hijacks the socket
  # (Rack response hijack) and hands it to the broker, which writes with
  # write_nonblock. A subscriber whose socket buffer is full loses that
  # event, counted in +dropped+; one that cannot take a whole frame is
  # disconnected (the browser reconnects), so frames are never interleaved.
  class Broker
    attr_reader :max_streams

    def initialize(max_streams, heartbeat: 15)
      @max_streams = max_streams
      @heartbeat = heartbeat
      @subs = []
      @mutex = Mutex.new
      @dropped = 0
      @closed = false
      @ticker = nil
    end

    def subscribers = @mutex.synchronize { @subs.size }
    def dropped = @mutex.synchronize { @dropped }
    def accepting? = @mutex.synchronize { !@closed && @subs.size < @max_streams }

    # Takes over a hijacked socket; the status line and headers are already written.
    def attach(io)
      @mutex.synchronize do
        return io.close if @closed

        @subs << io
        start_ticker
      end
      deliver(io, "retry: 3000\n\n")
    end

    def publish(value)
      broadcast("event: calc\ndata: #{JSON.generate(value)}\n\n")
    end

    # Ends every stream and refuses new ones.
    def close
      subs = @mutex.synchronize do
        @closed = true
        @ticker&.kill
        @subs.dup.tap { @subs.clear }
      end
      subs.each { |io| safely_close(io) }
    end

    private

    def broadcast(frame)
      @mutex.synchronize { @subs.dup }.each { |io| deliver(io, frame) }
    end

    def deliver(io, frame)
      written = io.write_nonblock(frame, exception: false)
      if written == :wait_writable
        @mutex.synchronize { @dropped += 1 }
      elsif written < frame.bytesize
        drop(io) # a partial frame would corrupt the stream
      end
    rescue IOError, SystemCallError
      drop(io)
    end

    def drop(io)
      @mutex.synchronize { @subs.delete(io) }
      safely_close(io)
    end

    def safely_close(io)
      io.close unless io.closed?
    rescue IOError, SystemCallError
      nil
    end

    # Keep-alives also detect closed connections: the write fails and the
    # subscriber is removed. Must be called with @mutex held.
    def start_ticker
      return if @ticker&.alive?

      @ticker = Thread.new do
        loop do
          sleep @heartbeat
          broadcast(": keep-alive\n\n")
        end
      end
    end
  end
end
