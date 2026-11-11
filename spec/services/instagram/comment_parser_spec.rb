# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Instagram::CommentParser do
  let(:value) do
    {
      'from' => { 'id' => '1134687895664215', 'username' => 'graca8918' },
      'media' => { 'id' => '18063450365360157', 'media_product_type' => 'FEED' },
      'id' => '18091065803441878',
      'text' => 'Qual o valor'
    }
  end

  subject(:parser) { described_class.new(value) }

  it 'reads the comment fields' do
    expect(parser.comment_id).to eq('18091065803441878')
    expect(parser.text).to eq('Qual o valor')
    expect(parser.from_id).to eq('1134687895664215')
    expect(parser.username).to eq('graca8918')
    expect(parser.media_id).to eq('18063450365360157')
    expect(parser.media_product_type).to eq('FEED')
    expect(parser.parent_id).to be_nil
    expect(parser).to be_valid
  end

  it 'exposes parent_id for replies to a comment' do
    expect(described_class.new(value.merge('parent_id' => '999')).parent_id).to eq('999')
  end

  it 'is invalid without comment id or author' do
    expect(described_class.new(value.except('id'))).not_to be_valid
    expect(described_class.new(value.except('from'))).not_to be_valid
    expect(described_class.new(nil)).not_to be_valid
  end
end
