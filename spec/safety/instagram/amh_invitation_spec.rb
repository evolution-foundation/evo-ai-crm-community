ENV['RAILS_ENV'] = 'test'
require_relative '../../../config/environment'
require 'webmock/rspec'
require 'httparty'

RSpec.describe Instagram::AmhInvitation do
  let(:inbox) { Struct.new(:channel).new(Struct.new(:access_token).new('inert-qa')) }
  let(:contract) { { 'identity' => { 'igsid' => '90002' } } }
  let(:text) { 'Oi, {{primeiro_nome}}! Você pediu o material sobre AMH. Posso enviar o acesso por aqui?' }

  it 'normalizes first names, preserving accents' do
    %w[JONAS joNas jonas].each { |name| expect(described_class.first_name(name)).to eq('Jonas') }
    expect(described_class.first_name('  jonas silva  ')).to eq('Jonas')
    expect(described_class.first_name("JOÃO\tSILVA")).to eq('João')
    [nil, '', '@jonas', '1234', '😀'].each { |name| expect(described_class.first_name(name)).to eq('') }
  end

  it 'uses the observed display name without a network request' do
    expect(described_class.render(text: text, contract: contract.merge('display_name' => 'joNas silva'), inbox: inbox)).to start_with('Oi, Jonas!')
  end

  it 'reads only the name with an authorization header' do
    request = stub_request(:get, 'https://graph.instagram.com/v23.0/90002?fields=name')
      .with(headers: { 'Authorization' => 'Bearer inert-qa' })
      .to_return(status: 200, body: '{"name":"JONAS SILVA"}', headers: { 'Content-Type' => 'application/json' })
    expect(described_class.render(text: text, contract: contract, inbox: inbox)).to start_with('Oi, Jonas!')
    expect(request).to have_been_requested.once
  end

  it 'falls back naturally on unavailable profiles and never uses the handle' do
    stub_request(:get, /graph.instagram.com/).to_timeout
    expect(described_class.render(text: text, contract: contract.merge('username' => 'jonas123'), inbox: inbox)).to start_with('Oi! Você')
  end

  it 'preserves legacy invitations without fetching a profile' do
    expect(described_class.render(text: 'Posso enviar?', contract: contract, inbox: inbox)).to eq('Posso enviar?')
  end
end
