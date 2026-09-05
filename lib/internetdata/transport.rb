# frozen_string_literal: true

require 'uri'

module InternetData
  # The generated wire client, with the three things it gets wrong for this API
  # corrected in one place.
  class Transport < ApiClient
    # The generated Configuration applies a security scheme whatever it holds, so
    # a keyless client would send `Authorization: Bearer ` - an empty credential,
    # which the API answers 401 to rather than treating as no credential at all.
    # That is also exactly what an unset `${{ secrets.X }}` interpolates to.
    class Config < Configuration
      def initialize(api_key: nil, base_url: DEFAULT_BASE_URL, timeout: DEFAULT_TIMEOUT)
        super()
        uri = URI.parse(base_url)
        self.scheme = uri.scheme
        self.host = uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"
        self.base_path = uri.path
        self.access_token = api_key
        self.timeout = timeout
      end

      # ONLY the bearer scheme, never `super`.
      #
      # The generated settings list every scheme the spec declares - including
      # `?apikey=`, which is there for curl users - and Ruby's client applies
      # ALL of them, so `super` put the key in the URL as well as the header,
      # where it lands in every access log between here and the API. The sibling
      # brand's transport has always narrowed it this way; this one did not, and
      # its own test caught it.
      def auth_settings
        return {} if access_token.nil? || access_token.to_s.empty?

        {
          'BearerAuth' => {
            type: 'bearer', in: 'header', key: 'Authorization',
            value: "Bearer #{access_token}"
          }
        }
      end
    end

    def initialize(config)
      super
      @default_headers['User-Agent'] = "internetdata-ruby/#{VERSION}"
    end

    # `follow_location = opts[:follow_location] || true` in the generated client
    # is true for every value it can be given, so the download's 302 would be
    # chased and a multi-gigabyte database read into memory. Nothing this API
    # serves is meant to be followed.
    def build_request(http_method, path, opts = {})
      request = super
      request.options[:followlocation] = false
      request
    end

    # A GET for the presigned link the download endpoint hands out.
    #
    # Built here rather than through {#build_request} so it carries NO
    # credential: the presigned URL authorizes itself, and forwarding the API key
    # would hand it to a host with no business holding it. Redirects ARE followed,
    # unlike every other request this client makes, because this one IS the far
    # side of one; the guard exists to stop the API's own 302 pulling a database
    # into memory, not to stop object storage from moving a bucket.
    #
    # The whole-request timeout is dropped and only the connect phase is bounded.
    # Thirty seconds is a sane ceiling on a catalog read and the wrong one on
    # several gigabytes.
    def storage_request(url)
      options = {
        method: :get,
        headers: { 'User-Agent' => @default_headers['User-Agent'] },
        followlocation: true,
        maxredirs: 5,
        connecttimeout: @config.timeout,
        ssl_verifypeer: @config.verify_ssl,
        ssl_verifyhost: @config.verify_ssl_host ? 2 : 0,
      }
      options[:cainfo] = @config.ssl_ca_cert if @config.ssl_ca_cert
      Typhoeus::Request.new(url, options)
    end
  end
end
