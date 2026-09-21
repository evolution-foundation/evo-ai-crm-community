# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MessageFinder do
  let(:inbox) { Inbox.create!(name: 'Finder Inbox', channel: Channel::Api.create!) }
  let(:contact) { Contact.create!(name: 'Finder', email: "finder-#{SecureRandom.hex(4)}@example.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:burst_at) { Time.zone.at(1_760_000_000) }

  let!(:messages) do
    Array.new(45) do |i|
      Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming,
                      content: "burst #{i}", created_at: burst_at)
    end
  end

  def find(params)
    described_class.new(conversation, params).perform
  end

  # Bounded on purpose: a cursor that stops advancing (a non-strict comparison,
  # say) repeats the same page forever, and an unbounded loop answers that with a
  # hang instead of a failure.
  def walk(direction, first_page, cursor_of)
    pages = [first_page]
    messages.size.times do
      page = find(direction => cursor_of.call(pages.last).id)
      return pages if page.empty?

      pages << page
    end
    raise "cursor did not exhaust after #{messages.size} pages - it is not advancing"
  end

  def oldest_message
    page = find({})
    messages.size.times do
      older = find(before: page.first.id)
      return page.first if older.empty?

      page = older
    end
    raise 'before cursor did not exhaust - it is not advancing'
  end

  it 'walks backwards through messages sharing one timestamp without gaps or duplicates' do
    pages = walk(:before, find({}), ->(page) { page.first })

    ids = pages.flatten.map(&:id)
    expect(pages.map(&:size)).to eq([20, 20, 5])
    expect(ids).to match_array(messages.map(&:id))
    expect(ids.uniq.size).to eq(45)
  end

  it 'reaches every later message of the burst from the oldest cursor' do
    pages = walk(:after, [oldest_message], ->(page) { page.last })

    ids = pages.flatten.map(&:id)
    expect(ids).to match_array(messages.map(&:id))
    expect(ids.uniq.size).to eq(45)
  end

  it 'breaks the timestamp tie the same way on every call' do
    newest = find({})

    expect(find({}).map(&:id)).to eq(newest.map(&:id))
    expect(newest.map(&:id)).to eq(newest.map(&:id).sort)
  end

  describe 'page' do
    it 'skips the newer pages' do
      page_one = find(page: '1')
      page_two = find(page: '2')
      page_three = find(page: '3')

      expect(page_one.map(&:id)).to eq(find({}).map(&:id))
      expect(page_two.map(&:id)).to eq(find(before: page_one.first.id).map(&:id))
      expect(page_three.size).to eq(5)
      expect((page_one + page_two + page_three).map(&:id)).to match_array(messages.map(&:id))
    end

    it 'rejects page combined with a cursor' do
      expect { find(page: '2', before: messages.last.id) }.to raise_error(described_class::InvalidParams, /cursor/)
    end

    it 'rejects a page that is not a positive integer' do
      %w[0 -1 abc].each do |value|
        expect { find(page: value) }.to raise_error(described_class::InvalidParams, /positive integer/)
      end
    end

    it 'rejects a page whose offset would overflow the bigint OFFSET' do
      expect { find(page: (described_class::MAX_PAGE + 1).to_s) }
        .to raise_error(described_class::InvalidParams, /at most/)
    end
  end
end
