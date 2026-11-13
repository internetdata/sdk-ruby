# frozen_string_literal: true

require 'cgi'
require 'json'
require 'uri'

module InternetData
  # The generated wire client, with the three things it gets wrong for this API
  # corrected in one place.
  class Transport < ApiClient
    # The spec's path templates for the lookups, which the client builds itself:
    # no generated class holds them, since a batch queues its requests on a hydra
    # and the generated methods run each request as they build it. The suite
    # holds each one to spec/openapi.yaml.
    LOOKUP_PATH = '/{ip}'
    MYIP_PATH = '/myip'
    ASN_PATH = '/asn/{asn}'
    DOMAIN_PATH = '/domain/{domain}'
    ENTITLEMENT_PATH = '/api/v1/entitlement'
    BATCH_PATH = '/batch'
    # The lookups' operations spell their bearer scheme `bearerAuth` and the
    # database's `BearerAuth`. Config answers the one bearer this client sends
    # under the database's spelling, so a lookup names that.
    LOOKUP_AUTH = %w[BearerAuth].freeze

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

    # `api_key` without the blanks around it, nil for blanks alone. A control
    # character is refused where it is set, and the key is left out of the
    # message: a CR or LF failed every call with Ethon's raw InvalidValue, whose
    # message quoted the key, and a tab, NUL or DEL went out inside it (2.8.5).
    def self.checked_key(api_key)
      return nil if api_key.nil?

      key = api_key.to_s.strip
      raise ArgumentError, 'api_key must not contain a control character' if key.match?(/[[:cntrl:]]/)

      key.empty? ? nil : key
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
        self.access_token = Transport.checked_key(api_key)
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

    def initialize(config = Config.new)
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

    # A request built with `oauth: true` goes to the authorization server, the
    # rest to the API.
    def build_request_url(path, opts = {})
      opts[:oauth] ? "#{oauth_base_url}#{path}" : super
    end

    # Where the authorization server answers: the apex the API host is named
    # under, since the issuer is the apex and the API host serves no OAuth
    # route. `api.` is dropped and `api-<env>.` becomes `<env>.`, so
    # `https://api.internetdata.io` signs in at `https://internetdata.io`; any
    # other base URL is used as given.
    def oauth_base_url
      @config.base_url.sub(%r{\A(https?://)api(?:-([^./:]+))?\.}i) do
        env = Regexp.last_match(2)
        "#{Regexp.last_match(1)}#{env ? "#{env}." : ''}"
      end
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

      Transport.check_type!(JSON.parse(response.body.to_s), return_type.to_s, 'the answer') if return_type
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
      request = build_request(http_method, path, header_params: headers, auth_names: [], timeout: timeout,
                                                 oauth: true)
      request.options[:body] = URI.encode_www_form(form) unless form.nil?
      request.options[:body] = JSON.generate(json) unless json.nil?
      request
    end

    def lookup_request(ip, timeout: nil)
      lookup_get(LOOKUP_PATH.sub('{ip}', CGI.escape(ip.to_s)), timeout)
    end

    def myip_request(timeout: nil)
      lookup_get(MYIP_PATH, timeout)
    end

    def asn_request(asn, timeout: nil)
      lookup_get(ASN_PATH.sub('{asn}', CGI.escape(asn.to_s)), timeout)
    end

    def domain_request(domain, timeout: nil)
      lookup_get(DOMAIN_PATH.sub('{domain}', CGI.escape(domain.to_s)), timeout)
    end

    def entitlement_request(timeout: nil)
      lookup_get(ENTITLEMENT_PATH, timeout)
    end

    # The one request with a body: the batch.
    def batch_request(ips, timeout: nil)
      build_request(
        :POST, BATCH_PATH,
        header_params: { 'Accept' => 'application/json', 'Content-Type' => 'application/json' },
        body: { ips: ips },
        auth_names: LOOKUP_AUTH,
        timeout: timeout,
      )
    end

    def self.entitlement_result(response)
      body = answer(response)
      begin
        check_type!(body, 'Entitlement', 'the answer')
        Entitlement.build_from_hash(body)
      rescue StandardError => e
        raise Error.new(:server_error, "could not read the answer as Entitlement: #{e.message}",
                        status: response.code)
      end
    end

    def self.lookup_result(response)
      Result.new(checked_answer(response, 'LookupResponse'))
    end

    def self.asn_result(response)
      AsnResult.new(checked_answer(response, 'AsnLookupResponse'))
    end

    def self.domain_result(response)
      DomainResult.new(checked_answer(response, 'DomainLookupResponse'))
    end

    # Whether a parsed value is the generated `type`: a batch entry that is not
    # is that address's error alone.
    def self.conforms?(value, type)
      check_type!(value, type, 'the entry')
    rescue TypeError
      false
    end

    # The two maps of a batch answer, each present even when empty. An answer
    # carrying neither is unreadable as a whole, and is retried as one.
    def self.batch_body(response)
      body = answer(response)
      unless body['results'].is_a?(Hash) || body['errors'].is_a?(Hash)
        raise Error.new(:server_error, 'the batch answer carried neither results nor errors',
                        status: response.code)
      end

      {
        'results' => body['results'].is_a?(Hash) ? body['results'] : {},
        'errors' => body['errors'].is_a?(Hash) ? body['errors'] : {},
      }
    end

    # The JSON object a 2xx lookup answer carries; anything else raises the
    # error its status or its unreadable body maps to.
    def self.answer(response)
      raise Error.from_transport(response) if transport_failure?(response)
      raise Error.from_status(response.code, response.headers, response.body) unless response.success?

      parse_object(response)
    end

    # The answer, once every member it carries has the spec's type.
    def self.checked_answer(response, type)
      body = answer(response)
      begin
        check_type!(body, type, 'the answer')
      rescue TypeError => e
        raise Error.new(:server_error, "could not read the answer as #{type}: #{e.message}",
                        status: response.code)
      end
      body
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

    private_class_method :transport_failure?, :parse_object, :oauth_refusal, :answer, :checked_answer

    # The members the spec requires of each answer a lookup, a batch, the
    # entitlement or a database call reads. One that is not nullable must be
    # there and not null: the generated reader skips the writer of a list or map
    # member that is not one, so `"versions": null` came back as a family with no
    # versions (2.8.1, measured 2026-10-19). A member the spec does not require is
    # one a plan may leave out, every member of a detail object among them, which
    # is `{}` under a false flag. test/database_test.rb holds this to
    # spec/openapi.yaml.
    REQUIRED = {
      'LookupResponse' => %i[ip is_bogon is_tor is_relay is_anycast is_carrier is_satellite is_ssh is_smtp
                             is_web is_dns_resolver is_bittorrent tor relay location asn company hostname abuse],
      'ClassDetail' => [],
      'ProxyDetail' => [],
      'PubproxyDetail' => [],
      'CarrierDetail' => [],
      'SatelliteDetail' => [],
      'SshDetail' => [],
      'SmtpDetail' => [],
      'WebDetail' => %i[port tls_ok session_ok status_code server location title cert_subject_cn
                        cert_subject_o cert_issuer_dn cert_browser_trusted tls_version first_seen last_seen],
      'DnsResolverDetail' => [],
      'BitTorrentDetail' => [],
      'Location' => %i[continent continent_name country country_name timezone currency_code currency_name
                       currency_symbol flag_emoji flag_unicode],
      'Asn' => %i[asn name domain type prefix],
      'Company' => %i[name domain],
      'AbuseContact' => %i[email],
      'Whois' => %i[id name org country status source domain abuse_email asn],
      'Rwhois' => %i[id name country source domain abuse_email],
      'HostedDomains' => %i[total],
      'AsnLookupResponse' => %i[asn name country registry allocated domain],
      'AsnPrefix' => %i[prefix peer_count rpki_status first_seen country size other_origins],
      'DomainLookupResponse' => %i[domain is_registered has_a has_aaaa has_mx has_ns has_cname],
      'DomainDns' => %i[a aaaa mx ns cname],
      'DnsAddressRecord' => %i[ip last_seen],
      'DnsMxRecord' => %i[priority host last_seen],
      'DnsNsRecord' => %i[host last_seen],
      'DnsCnameRecord' => %i[target last_seen],
      'DomainIpRanges' => %i[domain redirects_to total ipv4 ranges],
      'DomainIpRange' => %i[range name country],
      'DisposableDetail' => [],
      'BatchLookupError' => %i[status error],
      'Entitlement' => %i[org_id apikey plan usage],
      'EntitlementApikey' => %i[id expires allowed_cidrs],
      'EntitlementPlan' => %i[key tier],
      'EntitlementUsage' => %i[requests quota hard_limit window_start window_end],
      'DatabaseList' => %i[databases],
      'Database' => %i[base name summary standing open license_type starts expires renews_at notice_due_at versions],
      'DatabaseVersion' => %i[id version summary formats],
      'DatabaseMetadata' => %i[id updated entries schema size],
      'DatabaseMetadataColumn' => %i[name type],
      'DatabaseChecksumsResponse' => %i[id format checksums],
      'DbChecksums' => %i[md5 sha1 sha256 sha512],
      'DownloadList' => %i[downloads],
      'Download' => %i[dataset_id format outcome sample open bytes http_status apikey_id client_ip user_agent created],
    }.freeze

    # RFC 3339's full-date, the spec's `date`, and its date-time, the spec's
    # `date-time`, its `T` and `Z` in either case, as RFC 3339 allows: through
    # 2.8.4 a lowercase one failed the call. Anything else reached the
    # generated reader's Date.parse or Time.parse, which read "monday" as this
    # week's, "10:00" as today in the process's zone and 30 February as 2 March
    # (2.8.2, measured 2026-10-20).
    RFC3339_DATE = /\A(\d{4})-(\d{2})-(\d{2})\z/
    RFC3339_DATE_TIME = /\A(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:[Zz]|[+-](\d{2}):(\d{2}))\z/

    # A date in the form its type names, on a day and at a time that exist: an
    # hour of 24 rolls over the way a missing day does.
    def self.date?(value, type)
      m = (type == 'Date' ? RFC3339_DATE : RFC3339_DATE_TIME).match(value)
      return false unless m && Date.valid_date?(m[1].to_i, m[2].to_i, m[3].to_i)

      type == 'Date' || (m[4].to_i < 24 && m[5].to_i < 60 && m[6].to_i < 60 && m[7].to_i < 24 && m[8].to_i < 60)
    end

    # True when the parsed `value` has the generated `type`, a model's members
    # recursively; raises TypeError naming where it does not. No list entry or
    # map value the spec describes may be null: through 2.8.1 one came back as
    # nil, or as 0 in `size`.
    def self.check_type!(value, type, where)
      raise TypeError, "#{where} is null" if value.nil?

      typed =
        case type
        when 'String' then value.is_a?(String)
        when 'Date', 'Time' then value.is_a?(String) && date?(value, type)
        when 'Integer' then value.is_a?(Integer)
        when 'Float' then value.is_a?(Numeric)
        when 'Boolean' then [true, false].include?(value)
        # The spec's `type: object`, a sample row: through 2.8.5 a row of 1, "x"
        # or [] came back as the answer.
        when 'Object' then value.is_a?(Hash)
        when /\AArray<(?<inner>.+)>\z/
          inner = Regexp.last_match(:inner)
          value.is_a?(Array) && value.each_with_index.all? { |v, i| check_type!(v, inner, "#{where}[#{i}]") }
        when /\AHash<String, ?(?<inner>.+)>\z/
          inner = Regexp.last_match(:inner)
          value.is_a?(Hash) && value.all? { |k, v| check_type!(v, inner, "#{where}.#{k}") }
        else
          model = InternetData.const_get(type)
          if model.respond_to?(:openapi_types)
            value.is_a?(Hash) && model.openapi_types.all? { |attr, member| check_member!(model, attr, member, value, where) }
          else
            value.is_a?(String) # an enum
          end
        end
      return true if typed

      raise TypeError, "#{where} is not a #{type}"
    end

    # A member absent or null reads as absent, unless the spec requires it and
    # does not make it nullable.
    def self.check_member!(model, attr, member, value, where)
      key = model.attribute_map[attr].to_s
      return check_type!(value[key], member.to_s, "#{where}.#{key}") unless value[key].nil?
      return true unless REQUIRED.fetch(model.name.split('::').last).include?(attr)
      return true if model.openapi_nullable.include?(attr)

      raise TypeError, "#{where}.#{key} is #{value.key?(key) ? 'null' : 'missing'}"
    end

    private_class_method :check_member!

    private

    def lookup_get(path, timeout)
      build_request(:GET, path, header_params: { 'Accept' => 'application/json' }, auth_names: LOOKUP_AUTH,
                                timeout: timeout)
    end
  end
end
