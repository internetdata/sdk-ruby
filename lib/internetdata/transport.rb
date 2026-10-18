# frozen_string_literal: true

require 'json'
require 'uri'

module InternetData
  # The generated wire client, with the three things it gets wrong for this API
  # corrected in one place.
  class Transport < ApiClient
    # The longest `timeout` curl holds, in seconds: 2**31 - 1 ms, about 24.8 days.
    # libcurl refuses a longer one, and any negative, and Ethon ignores the
    # refusal, so the call would run with no bound at all.
    LONGEST_TIMEOUT = 2_147_483.647

    # `timeout`, once it is a bound curl can hold: seconds, 0 for none. Refused
    # where it is set, because nothing downstream refuses it: a negative ran with
    # no bound, and NaN, Infinity, a number past curl's ceiling or a string failed
    # every call with an error from Ruby, FFI or Ethon that names none of this.
    # NaN fails both comparisons, and an infinity one of them.
    def self.checked_timeout(timeout)
      return timeout if timeout.is_a?(Numeric) && timeout.real? && timeout >= 0 && timeout <= LONGEST_TIMEOUT

      raise ArgumentError,
            "timeout must be a number of seconds from 0 (no bound) to #{LONGEST_TIMEOUT}, not #{timeout.inspect}"
    end

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
        self.timeout = timeout.nil? ? nil : Transport.checked_timeout(timeout)
      end

      # ONLY the bearer scheme, never `super`.
      #
      # The generated settings list every scheme the spec declares - including
      # `?apikey=`, which is there for curl users - and Ruby's client applies
      # ALL of them, so `super` put the key in the URL as well as the header,
      # where it lands in every access log between here and the API. The sibling
      # brand's transport has always narrowed it this way; this one did not, and
      # its own test caught it.
      #
      # A key of blanks alone is no key: unstripped, `'   '` or a tab went out
      # as `Authorization: Bearer` and the blank (2.6.0, measured 2026-10-09).
      def auth_settings
        token = access_token.to_s.strip
        return {} if token.empty?

        {
          'BearerAuth' => {
            type: 'bearer', in: 'header', key: 'Authorization',
            value: "Bearer #{token}"
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
    #
    # `opts[:timeout]` is a per-call override of the configured bound, which the
    # generated client would otherwise apply to every request it builds. It
    # reaches here as an ordinary generated `opts` entry, so one seam bounds
    # every call whether the request was built by hand or by the generator.
    def build_request(http_method, path, opts = {})
      request = super
      request.options[:followlocation] = false
      request.options[:timeout] = Transport.checked_timeout(opts[:timeout]) unless opts[:timeout].nil?
      request
    end

    # A 2xx the generated client cannot read as the answer it promises is the
    # server's fault, and a retryable :server_error, as it is on the OAuth calls:
    # a proxy's HTML page, a cut-off or empty body, or an object missing a member
    # the spec requires. The generated reader raised a RuntimeError, a
    # JSON::ParserError or an ArgumentError for those, none of them retried, and
    # handed an empty or non-object body back as nil, as if it were the answer.
    #
    # Every member present is checked against the type the spec gives it before
    # the answer is handed back: the generated reader converts with `to_i` and
    # `to_s`, so `"version":"x"` came back as version 0 and `"version":"3"` as 3,
    # as if either were the answer (2.6.3, measured 2026-10-16).
    def deserialize(response, return_type)
      data = super
      raise Error.new(:server_error, "the API answered with no #{return_type}", status: response.code) if data.nil?

      check_type!(JSON.parse(response.body, symbolize_names: true), return_type.to_s, 'the answer') if return_type
      data
    rescue Error
      raise
    rescue StandardError => e
      raise Error.new(:server_error, "could not read the answer as #{return_type}: #{e.message}",
                      status: response.code)
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

    # A request to the authorization server, which carries NO credential whatever
    # this client was built with: these endpoints have no use for the API key, and
    # on the token endpoint an `Authorization` header reads as client
    # authentication, which a public client does not have.
    #
    # The form is encoded here rather than by curl, so a `+` in a value leaves as
    # `%2B` and never arrives as a space.
    def oauth_request(http_method, path, form: nil, json: nil, timeout: nil)
      headers = { 'Accept' => 'application/json' }
      headers['Content-Type'] = 'application/x-www-form-urlencoded' unless form.nil?
      headers['Content-Type'] = 'application/json' unless json.nil?
      request = build_request(http_method, path, header_params: headers, auth_names: [], timeout: timeout)
      request.options[:body] = URI.encode_www_form(form) unless form.nil?
      request.options[:body] = JSON.generate(json) unless json.nil?
      request
    end

    # The JSON object a 2xx OAuth answer carries. A refusal the authorization
    # server words as an RFC 6749 error raises that; anything else that is not a
    # 2xx raises the ordinary error its status maps to.
    def self.oauth_object(response)
      oauth_success!(response)
      parse_object(response)
    end

    def self.oauth_success!(response)
      raise Error.from_transport(response) if transport_failure?(response)
      return if response.success?

      raise oauth_refusal(response) || Error.from_status(response.code, response.headers, response.body)
    end

    # Only a 4xx whose body is a JSON object with a STRING `error` is the
    # authorization server's own refusal. A 5xx is an outage whatever its body
    # says, and a gateway's page names no OAuth code at all.
    def self.oauth_refusal(response)
      return nil unless (400..499).cover?(response.code)

      body = JSON.parse(response.body.to_s)
      return nil unless body.is_a?(Hash) && body['error'].is_a?(String)

      description = body['error_description'].is_a?(String) ? body['error_description'] : nil
      OauthRequestError.for_code(body['error'], description, status: response.code, headers: response.headers)
    rescue JSON::ParserError
      nil
    end

    def self.transport_failure?(response)
      response.timed_out? || response.code.to_i.zero?
    end

    def self.parse_object(response)
      body = JSON.parse(response.body.to_s)
      return body if body.is_a?(Hash)

      raise Error.new(:server_error, 'the API answered with something other than an object',
                      status: response.code)
    rescue JSON::ParserError => e
      raise Error.new(:server_error, "could not parse the response body: #{e.message}",
                      status: response.code)
    end

    private_class_method :transport_failure?, :parse_object, :oauth_refusal

    private

    # True when `value` has the generated `type`, a model's members recursively;
    # raises TypeError naming where it does not. A null is left to the models'
    # own required-member checks.
    def check_type!(value, type, where)
      return true if value.nil?

      typed =
        case type
        when 'String', 'Date', 'Time' then value.is_a?(String)
        when 'Integer' then value.is_a?(Integer)
        when 'Float' then value.is_a?(Numeric)
        when 'Boolean' then [true, false].include?(value)
        when 'Object' then true
        when /\AArray<(?<inner>.+)>\z/
          inner = Regexp.last_match(:inner)
          value.is_a?(Array) && value.each_with_index.all? { |v, i| check_type!(v, inner, "#{where}[#{i}]") }
        when /\AHash<String, ?(?<inner>.+)>\z/
          inner = Regexp.last_match(:inner)
          value.is_a?(Hash) && value.all? { |k, v| check_type!(v, inner, "#{where}.#{k}") }
        else
          model = InternetData.const_get(type)
          if model.respond_to?(:openapi_types)
            value.is_a?(Hash) && model.openapi_types.all? do |attr, member|
              key = model.attribute_map[attr]
              check_type!(value[key], member.to_s, "#{where}.#{key}")
            end
          else
            value.is_a?(String) # an enum
          end
        end
      return true if typed

      raise TypeError, "#{where} is not a #{type}"
    end
  end
end
