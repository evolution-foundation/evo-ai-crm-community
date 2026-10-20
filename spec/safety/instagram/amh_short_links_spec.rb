ENV['RAILS_ENV'] = 'test'
require_relative '../../../config/environment'
require 'webmock/rspec'

RSpec.describe 'AMH short links' do
  it 'loads the complete Rails autoload tree without middleware namespace errors' do
    expect { Rails.autoloaders.main.eager_load }.not_to raise_error
  end

  let(:graph) { JSON.parse(File.read(Rails.root.join('spec/fixtures/amh_visual_graph.json'))) }
  let(:proof) do
    p = Instagram::AmhVisualProof.create!(name: 'QA links', draft: graph, create_key: SecureRandom.uuid)
    p.publish_version!(p.lock_version, 'qa')
    p.reload
  end
  let(:version) { proof.versions.last }
  let(:event) { graph['nodes'][1]['data'].slice('account', 'ad', 'media').merge('app' => 'qa-app', 'comment' => SecureRandom.uuid, 'text' => 'Quero ámh!') }
  let(:model) { Instagram::AmhShortLink }
  let(:client) { ActionDispatch::Integration::Session.new(Rails.application) }
  let(:secret) { 'qa-only-link-secret-' + 'x' * 40 }

  around do |example|
    raise 'Isolated DB required' unless ActiveRecord::Base.connection_db_config.database == 'instagram_amh_safety_test'
    WebMock.disable_net_connect!
    saved_env = ENV.to_h.slice('INSTAGRAM_AMH_LINK_QA_ENABLED', 'INSTAGRAM_AMH_LINK_SERVICE_SECRET')
    ENV['INSTAGRAM_AMH_LINK_QA_ENABLED'] = 'true'
    ENV['INSTAGRAM_AMH_LINK_SERVICE_SECRET'] = secret
    @old_velma = $velma
    @redis_namespace = "qa-links:#{SecureRandom.hex(8)}"
    $velma = ConnectionPool.new(size: 2, timeout: 1) do
      Redis::Namespace.new(@redis_namespace, redis: Redis.new(url: 'redis://127.0.0.1:6379/15'))
    end
    if example.metadata[:concurrency]
      example.run
    else
      ActiveRecord::Base.transaction { example.run; raise ActiveRecord::Rollback }
    end
  ensure
    if example.metadata[:concurrency]
      Instagram::AmhShortLink.delete_all
      Instagram::AmhVisualProof.delete_all
    end
    if @old_velma
      $velma.with { |redis| redis.keys('*').each { |key| redis.del(key) } }
      $velma.shutdown(&:close)
    end
    $velma = @old_velma
    %w[INSTAGRAM_AMH_LINK_QA_ENABLED INSTAGRAM_AMH_LINK_SERVICE_SECRET].each { |k| ENV[k] = saved_env[k] }
    Current.reset
    WebMock.allow_net_connect!
  end

  def issue(ev = event, v = version)
    model.issue_qa!(proof: proof, version_id: v['id'], event: ev)
  end

  def resolve_request(code, nonce: SecureRandom.hex(16), timestamp: Time.current.to_i.to_s, signed: true, query: '')
    body = JSON.generate(code: code, rate_key: 'a' * 64)
    signature = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{nonce}.#{body}")
    client.post('/internal/instagram-amh/resolve' + query, params: body, headers: {
                  'CONTENT_TYPE' => 'application/json', 'X-Amh-Timestamp' => timestamp, 'X-Amh-Nonce' => nonce,
                  'X-Amh-Signature' => signed ? signature : '0' * 64
                })
  end

  it 'issues 8 random characters, freezes the graph, recovers retries and resolves without changing a record' do
    result = issue
    code = result[:url].split('/').last
    expect(result[:url].length).to eq(39)
    expect(code).to match(model::CODE)
    expect(issue[:url]).to eq(result[:url])
    row = model.find(result[:id])
    expect(row.encrypted_payload).not_to include(code, event['comment'], 'qa-app')
    before = row.attributes
    2.times do
      resolved = model.resolve(code)
      expect(resolved[:material]).to eq('amh')
      expect(resolved[:destination]).to eq('/lp/amh-na-pratica-ginecologica')
      expect(resolved.keys).not_to include(:event, :email, :instagram_id)
    end
    expect(row.reload.attributes).to eq(before)
    proof.update!(draft: graph.deep_dup.tap { |g| g['nodes'][3]['data']['material'] = 'amh-consultorio' })
    expect(model.resolve(code)[:material]).to eq('amh')
    expect(proof.reload.ledger).to eq([])
  end

  it 'rejects ad/media contradictions, wrong accounts/keywords and unapproved materials' do
    expect { issue(event.merge('ad' => 'wrong')) }.to raise_error(model::Unavailable)
    expect { issue(event.merge('media' => 'wrong')) }.to raise_error(model::Conflict)
    expect { issue(event.merge('account' => 'wrong')) }.to raise_error(model::Unavailable)
    expect { issue(event.merge('text' => 'xamh')) }.to raise_error(model::Unavailable)
    expect { issue(event.merge('email' => 'never@example.invalid')) }.to raise_error(model::Unavailable)
    expect { issue(event.merge('ad' => nil)) }.not_to raise_error
    expect { issue(event.merge('ad' => nil, 'media' => nil)) }.to raise_error(model::Unavailable)
  end

  it 'never renews expired/revoked tokens or reuses a tombstone on a random collision' do
    first = issue
    row = model.find(first[:id])
    code = first[:url].split('/').last
    row.update!(expires_at: 1.minute.ago)
    expect { model.resolve(code) }.to raise_error(model::Unavailable)
    expect { issue }.to raise_error(model::Unavailable)
    model.compact_expired!
    expect(row.reload.encrypted_payload).to be_nil
    expect(row.code_hash).to eq(Digest::SHA256.hexdigest(code))
    allow(SecureRandom).to receive(:urlsafe_base64).and_return(code, 'ZZZZZZZZ')
    other = issue(event.merge('comment' => 'another-comment'))
    expect(other[:url]).to end_with('/ZZZZZZZZ')
    model.find(other[:id]).revoke!
    expect { model.resolve('ZZZZZZZZ') }.to raise_error(model::Unavailable)
    expect(model.count).to eq(2)
  end

  it 'refuses to reinterpret the same comment under another published version' do
    issue
    proof.publish_version!(proof.lock_version, 'qa')
    expect { issue(event, proof.reload.versions.last) }.to raise_error(model::Conflict)
    expect(model.count).to eq(1)
  end

  it 'routes the second material and rejects ambiguous shared-media mappings' do
    graph['nodes'][3]['data']['material'] = 'amh-consultorio'
    result = issue
    expect(model.resolve(result[:url].split('/').last)[:destination]).to eq('/lp/amh-no-consultorio')
    other = Instagram::AmhVisualProof.create!(name: 'Conflicting QA', draft: graph, create_key: SecureRandom.uuid)
    other.publish_version!(other.lock_version, 'qa')
    expect { issue(event.merge('comment' => 'different')) }.to raise_error(model::Conflict)
    expect { issue(event.merge('comment' => 'different', 'ad' => nil)) }.to raise_error(model::Conflict)
  end

  it 'recovers an already issued snapshot even if a later QA mapping becomes ambiguous' do
    first = issue
    other = Instagram::AmhVisualProof.create!(name: 'Later QA', draft: graph, create_key: SecureRandom.uuid)
    other.publish_version!(other.lock_version, 'qa')
    expect(issue[:url]).to eq(first[:url])
    expect { issue(event.merge('comment' => 'new-comment')) }.to raise_error(model::Conflict)
  end

  it 'rejects competing older selectable versions even when the latest mapping differs' do
    p = proof
    other = Instagram::AmhVisualProof.create!(name: 'Older eligible QA', draft: graph, create_key: SecureRandom.uuid)
    other.publish_version!(other.lock_version, 'qa')
    changed = graph.deep_dup
    changed['nodes'][1]['data']['ad'] = 'different-ad'
    changed['nodes'][1]['data']['media'] = 'different-media'
    other.update!(draft: changed)
    other.publish_version!(other.lock_version, 'qa')
    expect { issue }.to raise_error(model::Conflict)
  end

  it 'reloads stale rows at revocation boundaries and fails closed on unreadable encrypted payloads' do
    issued = issue
    stale = model.find(issued[:id])
    model.find(issued[:id]).revoke!
    expect { stale.recover_qa!(version['id']) }.to raise_error(model::Unavailable)
    second = issue(event.merge('comment' => 'qa-second'))
    model.find(second[:id]).update!(encrypted_payload: 'corrupt-qa-payload')
    expect { issue(event.merge('comment' => 'qa-second')) }.to raise_error(model::Conflict)
    expect(model.count).to eq(2)
  end

  it 'uses only signed body values despite conflicting query parameters and reports pool timeouts as 503' do
    issued = issue
    resolve_request(issued[:url].split('/').last, query: '?code=BAD00000&rate_key=wrong')
    expect(client.response.status).to eq(200)
    expect(JSON.parse(client.response.body)['attribution_id']).to eq(issued[:id])
    allow($velma).to receive(:with).and_raise(ConnectionPool::TimeoutError)
    resolve_request(issued[:url].split('/').last)
    expect(client.response.status).to eq(503)
    RSpec::Mocks.space.proxy_for($velma).reset
  end

  it 'rejects oversized bodies at Rack before JSON parameter parsing' do
    client.post('/internal/instagram-amh/resolve', params: '', headers: { 'CONTENT_TYPE' => 'application/json' })
    expect(client.response.status).to eq(401)
    client.post('/internal/instagram-amh/resolve', params: 'x' * 1025, headers: { 'CONTENT_TYPE' => 'application/json' })
    expect(client.response.status).to eq(413)
    input = Class.new do
      attr_reader :read_size
      def read(size)
        @read_size = size
        'x' * size
      end
    end.new
    middleware = Middleware::AmhLinkBodyLimit.new(->(_env) { raise 'must not reach Rails' })
    status, = middleware.call('PATH_INFO' => '/internal/instagram-amh/resolve', 'REQUEST_METHOD' => 'POST', 'rack.input' => input)
    expect(status).to eq(413)
    expect(input.read_size).to eq(1025)
  end

  it 'holds the same transaction lock used by publications and competing issuance', :concurrency do
    observed = Queue.new
    Instagram::AmhVisualProof.with_mapping_lock do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.transaction do
            observed << connection.select_value('SELECT pg_try_advisory_xact_lock(419202619)')
          end
        end
      end.join
      expect(observed.pop).to be false
    end
  end

  it 'requires a fresh signed request, rejects replay and rate limits using shared Redis' do
    code = issue[:url].split('/').last
    nonce = SecureRandom.hex(16)
    resolve_request(code, nonce: nonce)
    expect(client.response.status).to eq(200)
    expect(client.response.headers['Cache-Control']).to include('no-store')
    resolve_request(code, nonce: nonce)
    expect(client.response.status).to eq(401)
    resolve_request(code, signed: false)
    expect(client.response.status).to eq(401)
    resolve_request(code, timestamp: 2.minutes.ago.to_i.to_s)
    expect(client.response.status).to eq(401)
    29.times { resolve_request(code) }
    expect(client.response.status).to eq(200)
    resolve_request(code)
    expect(client.response.status).to eq(429)
  end

  it 'returns the same generic response for missing, expired and revoked codes' do
    code = issue[:url].split('/').last
    model.first.revoke!
    [code, 'BAD00000', '../oops'].each do |value|
      resolve_request(value)
      expect(client.response.status).to eq(404)
      expect(JSON.parse(client.response.body)).to eq('error' => 'Link indisponível')
    end
    ENV['INSTAGRAM_AMH_LINK_QA_ENABLED'] = 'false'
    resolve_request(code)
    expect(client.response.status).to eq(404)
  end

  it 'gates QA issuance and revocation behind journeys.update' do
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) { Current.user = User.new(id: SecureRandom.uuid); Current.evo_permission_cache = {} }
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(false)
    client.post('/api/v1/instagram_amh_links', params: { proof_id: proof.id, version_id: version['id'], event: event }, as: :json)
    expect(client.response.status).to eq(403)
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(true)
    client.post('/api/v1/instagram_amh_links', params: { proof_id: proof.id, version_id: version['id'], event: event }, as: :json)
    expect(client.response.status).to eq(201), client.response.body
    id = JSON.parse(client.response.body).fetch('data').fetch('id')
    client.delete("/api/v1/instagram_amh_links/#{id}")
    expect(client.response.status).to eq(204)
    expect(model.find(id).revoked_at).to be_present
  end

  it 'deduplicates actual concurrent inserts by the unique event index', :concurrency do
    p = proof
    v = version
    ev = event
    barrier = Queue.new
    threads = 3.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop
          model.issue_qa!(proof: p, version_id: v['id'], event: ev)
        end
      end
    end
    3.times { barrier << true }
    results = threads.map(&:value)
    expect(results.map { |r| r[:url] }.uniq.size).to eq(1)
    expect(model.count).to eq(1)
  end
end
