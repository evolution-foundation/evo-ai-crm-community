require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Knowledge::UrlCrawlService do
  # ssrf_filter resolves the hostname via Resolv *before* the Net::HTTP call that
  # WebMock intercepts, so stubbing only the HTTP layer leaves these tests dependent
  # on real DNS for 'example.com'. Stub the DNS step too so the suite is hermetic,
  # while still exercising ssrf_filter's real IP-safety check against a genuinely
  # public (if fake-for-this-hostname) resolved address.
  def stub_example_com_dns
    allow(Resolv).to receive(:getaddresses).with('example.com').and_return(['93.184.216.34'])
  end

  it 'fetches a single page when include_subpages is false' do
    stub_example_com_dns
    stub_request(:get, 'https://example.com/docs')
      .to_return(status: 200, body: '<html><body><p>hello</p><a href="/docs/other">other</a></body></html>')

    pages = described_class.new('https://example.com/docs', include_subpages: false).call

    expect(pages.length).to eq(1)
    expect(pages.first[:text]).to include('hello')
  end

  it 'follows same-domain sub-pages up to max_pages' do
    stub_example_com_dns
    stub_request(:get, 'https://example.com/docs')
      .to_return(status: 200, body: '<html><body><a href="https://example.com/docs/a">a</a><a href="https://example.com/docs/b">b</a></body></html>')
    stub_request(:get, 'https://example.com/docs/a').to_return(status: 200, body: '<html><body>page a</body></html>')
    stub_request(:get, 'https://example.com/docs/b').to_return(status: 200, body: '<html><body>page b</body></html>')

    pages = described_class.new('https://example.com/docs', include_subpages: true, max_pages: 2).call

    expect(pages.length).to eq(2)
  end

  it 'refuses to fetch a private/internal address (SSRF guard)' do
    # 169.254.169.254 is a literal IP (a cloud metadata address) — no DNS step
    # involved, so this genuinely exercises ssrf_filter's real IP blacklist with
    # no stubbing of the safety check itself.
    expect do
      described_class.new('http://169.254.169.254/latest/meta-data', include_subpages: false).call
    end.to raise_error(Knowledge::UrlCrawlService::BlockedAddressError)
  end
end
