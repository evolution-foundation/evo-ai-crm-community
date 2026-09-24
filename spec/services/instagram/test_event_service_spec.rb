# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Instagram::TestEventService do
  let(:test_messaging) do
    { 'sender' => { 'id' => '12334' }, 'recipient' => { 'id' => '23245' },
      'message' => { 'mid' => 'random_mid', 'text' => 'random_text' } }
  end
  # Real comment notification: a `changes` value with no sender/recipient at all.
  let(:comment_value) do
    { 'from' => { 'id' => '17841400000000000', 'username' => 'cliente' }, 'id' => '18000000000000000',
      'media' => { 'id' => '18100000000000000', 'media_product_type' => 'FEED' }, 'text' => 'Que top hein 🔥🔥' }
  end

  describe '.messaging_from' do
    it 'returns the value of the first change when it is an object' do
      expect(described_class.messaging_from([{ 'field' => 'messages', 'value' => test_messaging }])).to eq(test_messaging)
      expect(described_class.messaging_from([{ field: 'messages', value: test_messaging }])).to eq(test_messaging)
    end

    it 'is nil for every shape that cannot carry one, and never raises' do
      [nil, [], {}, { 'field' => 'messages', 'value' => test_messaging }, 'oops', %w[a b],
       [{ 'field' => 'comments' }], [{ 'value' => 'text' }], [{ 'value' => nil }], [nil]].each do |changes|
        expect(described_class.messaging_from(changes)).to be_nil
      end
    end
  end

  describe '.test_event?' do
    it "is true only for Meta's fixed sender/recipient pair" do
      expect(described_class.test_event?(test_messaging)).to be(true)
      expect(described_class.test_event?(test_messaging.with_indifferent_access)).to be(true)
      expect(described_class.test_event?(test_messaging.merge('recipient' => { 'id' => '99' }))).to be(false)
    end

    it 'is false for a payload with no sender/recipient, and never raises' do
      expect(described_class.test_event?(comment_value)).to be(false)
      expect(described_class.test_event?({})).to be(false)
      expect(described_class.test_event?(nil)).to be(false)
      expect(described_class.test_event?('oops')).to be(false)
    end

    it 'is false when sender/recipient is present but not a hash' do
      expect(described_class.test_event?('sender' => 'abc', 'recipient' => { 'id' => '23245' })).to be(false)
      expect(described_class.test_event?('sender' => { 'id' => '12334' }, 'recipient' => ['23245'])).to be(false)
      expect(described_class.test_event?('sender' => nil, 'recipient' => nil)).to be(false)
    end
  end

  describe '#perform' do
    it 'returns false for a comment payload instead of raising on the missing sender' do
      expect(described_class.new(comment_value.with_indifferent_access).perform).to be(false)
    end

    it 'still recognises the test event and goes on to create the test text' do
      service = described_class.new(test_messaging.with_indifferent_access)
      allow(service).to receive(:create_test_text).and_return(:created)

      expect(service.perform).to eq(:created)
    end
  end
end
