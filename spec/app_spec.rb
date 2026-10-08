# frozen_string_literal: true

RSpec.describe 'the assembled service' do
  include Rack::Test::Methods

  let(:service) { build_service('VERSION' => 'v9.9.9', 'COMMIT' => 'abc1234') }
  let(:app) { service.rack_app }

  it 'serves probes, version, metrics, security headers and the request log' do
    get '/api/sub?term_one=4&term_two=1'
    expect(last_response.headers['x-request-id']).to match(/\A\h{32}\z/)
    expect(last_response.headers['content-security-policy']).to include("script-src 'self'")
    expect(last_response.headers['x-frame-options']).to eq('DENY')

    get '/healthz'
    expect(JSON.parse(last_response.body)).to eq('status' => 'ok')
    get '/readyz'
    expect(JSON.parse(last_response.body)).to eq('status' => 'ready')
    get '/version'
    expect(JSON.parse(last_response.body)).to include('implementation' => 'ruby', 'version' => 'v9.9.9',
                                                      'commit' => 'abc1234')

    get '/nowhere-at-all'
    put '/healthz'
    expect(last_response.status).to eq(405)
    get '/metrics'
    expect(last_response.headers['content-type']).to start_with('text/plain')
    [
      'tetra_http_requests_total{method="GET",route="/api/sub",status="200"} 1.0',
      'tetra_http_requests_total{method="GET",route="/",status="404"} 1.0',
      'tetra_http_requests_total{method="PUT",route="/",status="405"} 1.0',
      'tetra_http_request_duration_seconds_count{method="GET",route="/api/sub"} 1.0',
      'tetra_calc_operations_total{operation="sub",outcome="ok"} 1.0',
      'tetra_build_info{implementation="ruby",version="v9.9.9",commit="abc1234",runtime="ruby',
      'tetra_live_subscribers 0.0',
      'tetra_http_requests_in_flight 1.0',
      'process_start_time_seconds'
    ].each { |want| expect(last_response.body).to include(want) }

    entry = log_entries.find { |e| e['route'] == '/api/sub' }
    expect(entry).to include('msg' => 'request', 'level' => 'INFO', 'status' => 200, 'method' => 'GET')
    expect(entry['request_id']).to match(/\A\h{32}\z/)
    expect(entry['bytes']).to be > 0
    expect(log_entries.any? { |e| e['route'] == '/healthz' && e['status'] == 200 }).to be(false)
  end

  it 'keeps a valid incoming request id and replaces anything else' do
    header 'X-Request-Id', 'trace-42'
    get '/healthz'
    expect(last_response.headers['x-request-id']).to eq('trace-42')
    expect(Tetra::RequestId.for('gw-1234.abc_DEF')).to eq('gw-1234.abc_DEF')
    [nil, '', 'bad id', 'a' * 65].each { |bad| expect(Tetra::RequestId.for(bad)).to match(/\A\h{32}\z/) }
  end

  it 'serves the UI with cache headers and rejects other methods' do
    get '/'
    expect(last_response.status).to eq(200)
    expect(last_response.headers['cache-control']).to eq('no-cache')
    expect(last_response.body).to include('<canvas id="scene"')

    get '/vendor/three/build/three.module.min.js'
    expect(last_response.headers['cache-control']).to eq('public, max-age=86400')
    expect(last_response.headers['content-type']).to start_with('text/javascript')

    get '/nope.js'
    expect(last_response.status).to eq(404)
    get '/../Gemfile'
    expect(last_response.status).to eq(404)
    post '/'
    expect(last_response.status).to eq(405)
  end

  it 'turns readiness off once draining' do
    service.drain
    get '/readyz'
    expect(last_response.status).to eq(503)
    expect(JSON.parse(last_response.body)).to eq('status' => 'draining')
    expect(service.ready?).to be(false)
  end

  it 'answers the live stream endpoint without a socket: limits and methods' do
    post '/events'
    expect(last_response.status).to eq(405)
    full = build_service('MAX_LIVE_STREAMS' => '0')
    status, _headers, body = full.rack_app.call(Rack::MockRequest.env_for('/events'))
    expect(status).to eq(503)
    expect(body.join).to include('too many live streams')
  end

  it 'maps unexpected errors to a 500 and logs them' do
    logs = StringIO.new
    broken = Tetra::App.new(deps: { info: nil, logger: Tetra::Logger.new('info', logs) })
    status, _headers, body = Rack::MockRequest.new(broken).get('/api').then { |r| [r.status, r.headers, r.body] }
    expect(status).to eq(500)
    expect(JSON.parse(body)).to eq('error' => 'internal error')
    expect(logs.string).to include('unhandled error')
  end
end
