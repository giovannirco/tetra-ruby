# frozen_string_literal: true

RSpec.describe 'the /api routes' do
  include Rack::Test::Methods

  let(:service) { build_service }
  let(:app) { service.rack_app }

  [
    ['/api/sum?term_one=4&term_two=1', 200, '{"result":5}'],
    ['/api/sub?term_one=4&term_two=1', 200, '{"result":3}'],
    ['/api/mul?term_one=4&term_two=1', 200, '{"result":4}'],
    ['/api/div?term_one=4&term_two=1', 200, '{"result":4}'],
    ['/api/div?term_one=7&term_two=2', 200, '{"result":3}'],
    ['/api/div?term_one=-7&term_two=2', 200, '{"result":-3}'],
    ['/api/sum?term_one=-4&term_two=%2B10', 200, '{"result":6}'],
    ['/api/sum?term_one=9223372036854775807&term_two=0', 200, '{"result":9223372036854775807}'],
    ['/api/sum?term_one=1&term_one=2&term_two=0', 200, '{"result":1}'],
    ['/api/div?term_one=1&term_two=0', 400, '{"error":"division by zero"}'],
    ['/api/mul?term_one=9223372036854775807&term_two=2', 400, '{"error":"result overflows a 64-bit integer"}'],
    ['/api/sum?term_two=1', 400, '{"error":"missing query parameter term_one"}'],
    ['/api/sum?term_one=1', 400, '{"error":"missing query parameter term_two"}'],
    ['/api/sum?term_one=abc&term_two=1', 400, '{"error":"term_one must be an integer, got \"abc\""}'],
    ['/api/sum?term_one=1.5&term_two=1', 400, '{"error":"term_one must be an integer, got \"1.5\""}'],
    ['/api/sum?term_one=1&term_two=99999999999999999999', 400,
     '{"error":"term_two is outside the 64-bit integer range"}']
  ].each do |path, status, body|
    it "GET #{path} → #{status} #{body}" do
      get path
      expect(last_response.status).to eq(status)
      expect(last_response.body.strip).to eq(body)
      expect(last_response.headers['content-type']).to start_with('application/json')
      expect(last_response.headers['cache-control']).to eq('no-store')
    end
  end

  it 'cuts long input in the error message' do
    get "/api/sum?term_one=#{'x' * 40}&term_two=1"
    expect(JSON.parse(last_response.body)['error']).to eq(%(term_one must be an integer, got "#{'x' * 32}…"))
  end

  it 'survives a malformed query string' do
    status, = app.call(Rack::MockRequest.env_for('/api/sum').merge('QUERY_STRING' => 'term_one=%zz&term_two=1'))
    expect(status).to eq(400)
  end

  it 'lists the operations' do
    get '/api'
    body = JSON.parse(last_response.body)
    expect(body['implementation']).to eq('ruby')
    expect(body['operations'].last).to eq('name' => 'div', 'symbol' => '÷', 'label' => 'Division', 'path' => '/api/div')
  end

  it 'answers 405 for a known operation with the wrong method and 404 otherwise' do
    post '/api/sum?term_one=1&term_two=1'
    expect(last_response.status).to eq(405)
    expect(last_response.headers['allow']).to eq('GET, HEAD')
    expect(JSON.parse(last_response.body)).to eq('error' => 'method not allowed')

    get '/api/pow?term_one=2&term_two=8'
    expect(last_response.status).to eq(404)
    expect(JSON.parse(last_response.body)).to eq('error' => 'not found')

    delete '/api/pow'
    expect(last_response.status).to eq(404)

    head '/api/sum?term_one=1&term_two=1'
    expect(last_response.status).to eq(200)
  end
end
