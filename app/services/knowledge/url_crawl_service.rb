require 'net/http'
require 'nokogiri'
require 'ssrf_filter'

# Fetches a URL (and optionally same-domain sub-pages linked from it) and
# returns the extracted text of each page. This is a plain HTTP crawler, not
# a headless browser — it does not execute JavaScript.
#
# Guards against SSRF (Server-Side Request Forgery): `url` is user-supplied,
# so a request for e.g. a cloud metadata endpoint (http://169.254.169.254/...)
# or another private/internal address must be blocked before any request is
# made. This is delegated to the `ssrf_filter` gem, whose `SsrfFilter.get`
# resolves the hostname, rejects private/link-local/reserved IP ranges, and
# only then performs the HTTP request against the verified-safe address —
# there is no separate "safe?" check method, the guard and the fetch are one
# call (see SsrfFilter::PrivateIPAddress, ::UnresolvedHostname,
# ::InvalidUriScheme raised by SsrfFilter.get itself).
class Knowledge::UrlCrawlService
  class BlockedAddressError < StandardError; end

  # Hard ceiling regardless of what the caller requests — never crawl more
  # than this many pages for a single call, to bound the outbound request
  # volume against an arbitrary user-supplied domain.
  MAX_ALLOWED_PAGES = 50

  def initialize(start_url, include_subpages: false, max_pages: 1)
    @start_url = start_url
    @include_subpages = include_subpages
    @max_pages = [max_pages, MAX_ALLOWED_PAGES].min
  end

  def call
    visited = []
    queue = [@start_url]
    pages = []

    while queue.any? && pages.length < @max_pages
      url = queue.shift
      next if visited.include?(url)

      visited << url
      html = fetch(url)
      next if html.nil?

      doc = Nokogiri::HTML(html)
      pages << { url: url, text: doc.text.squish }

      next unless @include_subpages

      doc.css('a[href]').each do |link|
        absolute = absolute_same_domain_url(url, link['href'])
        queue << absolute if absolute && !visited.include?(absolute)
      end
    end

    pages
  end

  private

  def fetch(url)
    response = SsrfFilter.get(url)
    return nil unless response.is_a?(Net::HTTPSuccess)

    response.body
  rescue SsrfFilter::Error => e
    raise BlockedAddressError, "Blocked address for #{url}: #{e.message}"
  rescue URI::InvalidURIError
    nil
  end

  def absolute_same_domain_url(base_url, href)
    base_uri = URI.parse(base_url)
    target_uri = URI.join(base_url, href)
    return nil unless target_uri.host == base_uri.host
    return nil unless target_uri.is_a?(URI::HTTP)

    target_uri.to_s
  rescue URI::InvalidURIError, URI::BadURIError
    nil
  end
end
