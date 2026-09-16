require 'rails_helper'

RSpec.describe Knowledge::TextExtractor do
  def fixture(name) = Rails.root.join('spec/fixtures/files', name).to_s

  it 'extracts text from a PDF' do
    text = described_class.new(fixture('sample.pdf'), 'application/pdf').extract
    expect(text).to include('sample') # adjust to match whatever your fixture actually contains
  end

  it 'extracts text from a DOCX' do
    text = described_class.new(fixture('sample.docx'), 'application/vnd.openxmlformats-officedocument.wordprocessingml.document').extract
    expect(text).to be_present
  end

  it 'extracts text from HTML, stripping tags' do
    text = described_class.new(fixture('sample.html'), 'text/html').extract
    expect(text).not_to include('<')
    expect(text).to include('Sample HTML Fixture')
  end

  it 'passes through plain text and markdown unchanged' do
    text = described_class.new(fixture('sample.txt'), 'text/plain').extract
    expect(text).to eq(File.read(fixture('sample.txt')))
  end

  it 'raises for an unsupported content type' do
    expect do
      described_class.new(fixture('sample.txt'), 'application/vnd.ms-excel').extract
    end.to raise_error(Knowledge::TextExtractor::UnsupportedFormatError)
  end
end
