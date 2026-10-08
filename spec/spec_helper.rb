# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  enable_coverage :branch
  add_filter '/spec/'
  minimum_coverage line: 90
end

require 'json'
require 'rack/test'
require 'socket'
require 'stringio'
require_relative '../lib/tetra'
require_relative '../lib/tetra/server'

module Helpers
  def build_service(env = {})
    @logs = StringIO.new
    Tetra.build(Tetra::Config.load(env), logger: Tetra::Logger.new('info', @logs), env:)
  end

  def log_entries = @logs.string.lines.map { |l| JSON.parse(l) }

  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1]
  ensure
    server&.close
  end

  # Reads from a raw socket until +needle+ appears.
  def read_until(sock, needle, timeout: 3)
    buf = +''
    deadline = Time.now + timeout
    until buf.include?(needle)
      raise "timed out waiting for #{needle.inspect}; got #{buf.inspect}" if Time.now > deadline

      buf << sock.readpartial(4096) if sock.wait_readable(0.1)
    end
    buf
  end

  def wait_for(timeout: 3)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now > deadline
    expect(yield).to be(true)
  end
end

RSpec.configure do |config|
  config.include Helpers
  config.disable_monkey_patching!
  config.order = :random
end
