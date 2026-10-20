# frozen_string_literal: true

require 'stringio'

# Bound reads before Rails parses/logs request parameters, including chunked bodies.
class AmhLinkBodyLimit
  PATHS = %w[/internal/instagram-amh/resolve /internal/instagram-amh/associate].freeze
  LIMIT = 1024

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless PATHS.include?(env['PATH_INFO']) && env['REQUEST_METHOD'] == 'POST'
    return too_large if env['CONTENT_LENGTH'].to_i > LIMIT

    body = env.fetch('rack.input').read(LIMIT + 1) || ''
    return too_large if body.bytesize > LIMIT

    env['rack.input'] = StringIO.new(body)
    @app.call(env)
  end

  private

  def too_large
    [413, { 'Content-Type' => 'application/json', 'Cache-Control' => 'private, no-store',
            'X-Robots-Tag' => 'noindex, nofollow', 'Referrer-Policy' => 'no-referrer' }, ['{}']]
  end
end
