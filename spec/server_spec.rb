# frozen_string_literal: true

require 'net/http'

RSpec.describe Tetra::Server do
  let(:out) { StringIO.new }

  it 'serves on Puma, streams live events through a hijacked socket, then drains and stops' do
    port = free_port
    server = described_class.new(env: { 'PORT' => port.to_s, 'DRAIN_DELAY_SECONDS' => '0' }, out:)
    expect(server.port).to eq(port)

    res = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/api/sum?term_one=2&term_two=3"))
    expect(JSON.parse(res.body)).to eq('result' => 5)

    stream = TCPSocket.new('127.0.0.1', port)
    stream.write("GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n")
    head = read_until(stream, "retry: 3000\n\n")
    expect(head).to include('HTTP/1.1 200', 'content-type: text/event-stream', 'x-request-id:')
    wait_for { server.service.broker.subscribers == 1 }

    Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/api/mul?term_one=6&term_two=7"))
    event = JSON.parse(read_until(stream, "\n\n").split('data: ').last)
    expect(event).to include('operation' => 'mul', 'result' => '42', 'outcome' => 'ok', 'status' => 200)

    [Thread.new { server.stop }, Thread.new { server.stop }].each(&:join) # idempotent
    server.wait
    expect { loop { stream.readpartial(10) } }.to raise_error(EOFError) # the stream was ended
    expect { TCPSocket.new('127.0.0.1', port) }.to raise_error(SystemCallError)
    msgs = out.string.lines.map { |l| JSON.parse(l)['msg'] }
    expect(msgs).to include('listening', 'shutting down', 'stopped')
  ensure
    stream&.close
  end

  it 'fails on a port in use and on bad config' do
    port = free_port
    first = described_class.new(env: { 'PORT' => port.to_s, 'DRAIN_DELAY_SECONDS' => '0' }, out:)
    expect { described_class.new(env: { 'PORT' => port.to_s }, out:) }.to raise_error(Errno::EADDRINUSE)
    first.stop
    expect { described_class.new(env: { 'PORT' => 'nope' }, out:) }.to raise_error(ArgumentError, /PORT/)
  end
end

RSpec.describe Tetra::Config do
  it 'has defaults' do
    expect(described_class.load({}).to_h).to eq(port: 8000, log_level: 'info', drain_delay: 5, shutdown_timeout: 10,
                                                max_live_streams: 100)
  end

  it 'reads overrides' do
    env = { 'PORT' => '9000', 'LOG_LEVEL' => 'DEBUG', 'DRAIN_DELAY_SECONDS' => '0',
            'SHUTDOWN_TIMEOUT_SECONDS' => '30', 'MAX_LIVE_STREAMS' => '5' }
    expect(described_class.load(env).to_h).to eq(port: 9000, log_level: 'debug', drain_delay: 0, shutdown_timeout: 30,
                                                 max_live_streams: 5)
  end

  [{ 'PORT' => 'eighty' }, { 'PORT' => '70000' }, { 'LOG_LEVEL' => 'loud' }, { 'DRAIN_DELAY_SECONDS' => '-1' },
   { 'SHUTDOWN_TIMEOUT_SECONDS' => '0' }, { 'MAX_LIVE_STREAMS' => '1.5' }].each do |env|
    it("rejects #{env}") { expect { described_class.load(env) }.to raise_error(ArgumentError) }
  end
end

RSpec.describe Tetra::Logger do
  it 'filters by level and drops nil fields' do
    out = StringIO.new
    log = described_class.new('warn', out)
    log.debug('hidden')
    log.info('hidden')
    log.warn('shown', a: 1, skip: nil)
    log.error('also shown')
    entries = out.string.lines.map { |l| JSON.parse(l) }
    expect(entries.size).to eq(2)
    expect(entries.first).to include('level' => 'WARN', 'msg' => 'shown', 'a' => 1)
    expect(entries.first).not_to have_key('skip')
  end
end
