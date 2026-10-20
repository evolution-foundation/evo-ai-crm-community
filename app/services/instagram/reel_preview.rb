# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'cgi'

class Instagram::ReelPreview
  MAX_BODY_BYTES = 1.megabyte
  MAX_REDIRECTS = 2
  USER_AGENT = 'Mozilla/5.0 (compatible; EvoCRM/1.0; +https://evolution-api.com)'

  def initialize(raw_url)
    @raw_url = raw_url.to_s
  end

  def call
    canonical_url = normalize(@raw_url)
    return { original_url: @raw_url } if canonical_url.blank?

    metadata = {
      original_url: @raw_url,
      canonical_url: canonical_url,
      shortcode: shortcode(canonical_url)
    }

    metadata.merge(fetch_open_graph(URI.parse(canonical_url))).compact
  rescue URI::InvalidURIError
    { original_url: @raw_url }
  end

  private

  def normalize(value)
    uri = URI.parse(value)
    return unless instagram_uri?(uri)

    uri.scheme = 'https'
    uri.path = uri.path.sub(%r{\A/reels/}, '/reel/')
    uri.query = nil
    uri.fragment = nil
    uri.to_s
  end

  def shortcode(url)
    url[%r{instagram\.com/reel/([^/?#]+)}, 1]
  end

  def instagram_uri?(uri)
    return false unless uri.is_a?(URI::HTTP)

    host = uri.host.to_s.downcase
    host == 'instagram.com' || host.end_with?('.instagram.com')
  end

  def fetch_open_graph(uri, redirects_left = MAX_REDIRECTS)
    response = request(uri)

    if response.is_a?(Net::HTTPRedirection) && redirects_left.positive?
      redirected_uri = URI.join(uri.to_s, response['location'].to_s)
      return {} unless instagram_uri?(redirected_uri)

      return fetch_open_graph(redirected_uri, redirects_left - 1)
    end

    return {} unless response.is_a?(Net::HTTPSuccess)
    return {} unless response['content-type'].to_s.downcase.include?('text/html')

    document = Nokogiri::HTML(response.body.to_s.byteslice(0, MAX_BODY_BYTES))
    {
      preview_image_url: safe_http_url(meta_content(document, 'og:image')),
      title: meta_content(document, 'og:title'),
      description: meta_content(document, 'og:description')
    }.compact
  rescue StandardError => e
    Rails.logger.info("Instagram Reel preview unavailable: #{e.class}")
    {}
  end

  def request(uri)
    request = Net::HTTP::Get.new(uri)
    request['User-Agent'] = USER_AGENT
    request['Accept'] = 'text/html,application/xhtml+xml'

    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == 'https',
      open_timeout: 2,
      read_timeout: 3
    ) { |http| http.request(request) }
  end

  def meta_content(document, property)
    document.at_css("meta[property='#{property}'], meta[name='#{property}']")&.[]('content')&.strip.presence
  end

  def safe_http_url(value)
    return if value.blank?

    uri = URI.parse(CGI.unescapeHTML(value))
    uri.to_s if uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end
end
