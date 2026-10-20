ENV['RAILS_ENV'] = 'test'
require_relative '../../../config/environment'
require 'json'
require 'active_support/all'
require_relative '../../../app/services/instagram/amh_visual_engine'

RSpec.describe Instagram::AmhVisualEngine do
  def graph
    stages = described_class::STAGES
    data = { 'scope' => { 'account' => 'qa-account', 'ad' => 'qa-ad', 'media' => 'qa-media' },
             'keyword' => { 'keywords' => ['AMH'], 'mode' => 'word', 'ignoreCase' => true, 'ignoreAccents' => true },
             'material' => { 'material' => 'amh' }, 'reply' => { 'text' => 'Oi! {{link}}' } }
    { 'nodes' => stages.map.with_index { |id, i| { 'id' => id, 'type' => id, 'position' => { 'x' => i * 280, 'y' => 0 }, 'data' => data[id] || {} } },
      'edges' => stages.each_cons(2).map { |a, b| { 'id' => "#{a}-#{b}", 'source' => a, 'target' => b } } }
  end

  it 'uses the persisted graph for a complete, inert, timestamped trace' do
    run = described_class.simulate(graph, fixture: 'eligible')
    expect(run[:trace].map { |t| t[:node] }).to eq(described_class::STAGES)
    expect(run[:trace].map { |t| t[:status] }.uniq).to eq(['passed'])
    expect(run[:outbound_calls]).to eq(0)
    expect(run[:mautic_state]).to eq('not_executed')
    expect(run[:preview]).to include('QA000000')
  end

  { 'negative' => 'rejected', 'scope_mismatch' => 'rejected', 'timeout' => 'uncertain', 'repeated' => 'skipped',
    'expired' => 'blocked', 'conflict' => 'conflict', 'missing_material' => 'failed' }.each do |fixture, outcome|
    it "explains and stops on #{fixture}" do
      run = described_class.simulate(graph, fixture: fixture)
      expect(run[:outcome]).to eq(outcome)
      expect(run[:trace].last[:status]).to eq('not_reached')
      expect(run[:outbound_calls]).to eq(0)
    end
  end

  it 'handles Unicode word boundaries, case, accents, contains, and literal punctuation' do
    rule = graph['nodes'][2]['data']
    expect(described_class.matches?('Quero ámh!', rule)).to be true
    expect(described_class.matches?('xamh', rule)).to be false
    expect(described_class.matches?('áAMH', rule.merge('ignoreAccents' => false))).to be false
    expect(described_class.matches?('amh', rule.merge('ignoreCase' => false))).to be false
    expect(described_class.matches?('xamh', rule.merge('mode' => 'contains'))).to be true
    expect(described_class.matches?('a+b', rule.merge('keywords' => ['a+b']))).to be true
  end

  it 'evaluates custom synthetic input without persisting the raw text' do
    run = described_class.simulate(graph, fixture: 'eligible', text: 'Quero ámh!')
    expect(run[:outcome]).to eq('simulated_accepted')
    expect(run[:input_length]).to eq(10)
    expect(run).not_to have_key(:text)
    expect(described_class.simulate(graph, fixture: 'eligible', text: 'xamh')[:outcome]).to eq('rejected')
    expect { described_class.simulate(graph, fixture: 'eligible', text: 'x' * 201) }.to raise_error(described_class::Invalid)
  end

  it 'rejects disconnected edges, cycles and missing materials before executing' do
    broken = graph
    broken['edges'][0]['target'] = 'result'
    expect { described_class.simulate(broken, fixture: 'eligible') }.to raise_error(described_class::Invalid)
    broken = graph
    broken['nodes'][3]['data']['material'] = 'unapproved'
    expect { described_class.validate!(broken) }.to raise_error(described_class::Invalid)
  end

  it 'rejects malformed nodes, excessive payloads and unknown fixtures' do
    [nil, {}, { 'nodes' => [], 'edges' => [] }, graph.merge('nodes' => [nil] * 6)].each do |invalid|
      expect { described_class.validate!(invalid) }.to raise_error(described_class::Invalid)
    end
    expect { described_class.simulate(graph, fixture: 'real_customer') }.to raise_error(described_class::Invalid)
  end
end
