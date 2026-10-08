# frozen_string_literal: true

RSpec.describe Tetra::Broker do
  def pair
    UNIXSocket.pair.tap { |pair| @sockets.concat(pair) }
  end

  before { @sockets = [] }
  after { @sockets.each { |s| s.close unless s.closed? } }

  it 'writes the retry hint, published events and heartbeats' do
    broker = described_class.new(10, heartbeat: 0.02)
    server, client = pair
    broker.attach(server)
    expect(read_until(client, "retry: 3000\n\n")).to start_with('retry')
    expect(broker.subscribers).to eq(1)

    broker.publish(operation: 'sum')
    read_until(client, %(event: calc\ndata: {"operation":"sum"}\n\n))
    read_until(client, ": keep-alive\n\n")
    broker.close
  end

  it 'forgets a subscriber whose peer went away' do
    broker = described_class.new(10)
    server, client = pair
    broker.attach(server)
    client.close
    broker.publish(n: 1)
    expect(broker.subscribers).to eq(0)
    expect(server).to be_closed
  end

  it 'drops events for a full buffer and disconnects on a partial frame' do
    broker = described_class.new(10)
    full = Object.new
    def full.write_nonblock(*, **) = :wait_writable
    def full.closed? = false
    partial = Object.new
    def partial.write_nonblock(frame, **) = frame.bytesize - 1
    def partial.closed? = @closed || false
    def partial.close = @closed = true

    broker.instance_variable_get(:@subs).push(full, partial)
    broker.publish(n: 1)
    expect(broker.dropped).to eq(1)
    expect(broker.subscribers).to eq(1) # the partial writer was disconnected
    expect(partial).to be_closed
  end

  it 'enforces the stream limit and refuses streams after close' do
    broker = described_class.new(1)
    expect(broker.accepting?).to be(true)
    server, = pair
    broker.attach(server)
    expect(broker.accepting?).to be(false)

    broker.close
    expect(server).to be_closed
    expect(broker.subscribers).to eq(0)
    late, = pair
    broker.attach(late)
    expect(late).to be_closed
  end
end
