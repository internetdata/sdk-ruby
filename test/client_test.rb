# frozen_string_literal: true

# What the shared corpus cannot pin for the lookups: the Ruby surface, the retry
# policy's cost in requests, the concurrency a batch genuinely reaches and the
# requests it shares.

require 'yaml'

require_relative 'test_helper'

class ClientTest < Minitest::Test
  include TestHelper

  OK_BODY = TestHelper.answer('1.1.1.1').freeze
  ASN_BODY = {
    'asn' => 9009, 'name' => 'M247 Europe SRL', 'country' => 'RO', 'registry' => 'ripe',
    'allocated' => '2005-06-06', 'domain' => 'm247global.com'
  }.freeze
  DOMAIN_BODY = {
    'domain' => 'example.com', 'is_registered' => true, 'has_a' => true, 'has_aaaa' => true, 'has_mx' => true,
    'has_ns' => true, 'has_cname' => false
  }.freeze

  def teardown
    Typhoeus::Config.block_connection = false
    Typhoeus::Expectation.clear
  end

  def test_the_default_base_url_is_the_api_host_and_database_calls_go_there
    calls = stub_api('/api/v2/database/list', 200, { 'databases' => [] })

    client.database.list

    assert_equal 'https://api.internetdata.io', InternetData::DEFAULT_BASE_URL
    assert_equal ['https://api.internetdata.io/api/v2/database/list'], calls.map(&:url)
  end

  # The issuer is the apex and the API host serves no OAuth route, so the oauth
  # accessor alone derives its host from the base URL.
  def test_oauth_signs_in_at_the_apex_of_the_api_host
    {
      'https://api.internetdata.io' => 'https://internetdata.io',
      'https://api.internetdata.io/' => 'https://internetdata.io',
      'https://api-staging.internetdata.io' => 'https://staging.internetdata.io',
      'https://API-Staging.internetdata.io' => 'https://Staging.internetdata.io',
      'https://internetdata.io' => 'https://internetdata.io',
      'https://staging.internetdata.io' => 'https://staging.internetdata.io',
      'https://apidocs.example.com' => 'https://apidocs.example.com',
      'https://api-.example.com' => 'https://api-.example.com',
      'http://127.0.0.1:8080/base' => 'http://127.0.0.1:8080/base',
    }.each do |base_url, apex|
      url = InternetData::Client.new(base_url: base_url).oauth.authorization_url('cli', 'http://127.0.0.1/cb', 'c')

      assert url.start_with?("#{apex}/oauth/authorize?"), "#{base_url}: #{url}"
    end

    Typhoeus::Config.block_connection = true
    calls = []
    Typhoeus.stub(/./).and_return do |request|
      calls << request.url
      json_response(200, { 'issuer' => 'https://internetdata.io', 'authorization_endpoint' => 'a',
                           'token_endpoint' => 't' })
    end
    InternetData::Client.new.oauth.metadata
    assert_equal ['https://internetdata.io/.well-known/oauth-authorization-server'], calls
  end

  def test_the_bogon_predicate_is_the_same_answer_on_the_module_and_on_a_client
    client = InternetData::Client.new
    %w[10.0.0.1 8.8.8.8 ::1 2606:4700:4700::1111 notanip].each do |ip|
      assert_equal InternetData.bogon?(ip), client.bogon?(ip), ip
    end
  end

  def test_a_bogon_answer_is_wider_than_an_unlimited_answer
    stub_lookups('1.1.1.1' => { body: OK_BODY })
    client = InternetData::Client.new
    served = client.lookup('1.1.1.1')

    refute served.included?('is_vpn')
    assert client.lookup('10.0.0.1').included?('is_vpn'),
           'a bogon answer carries the widest shape whatever the plan'
  end

  def test_a_result_is_frozen_so_a_cached_answer_cannot_be_poisoned
    body = answer('146.70.116.130', 'is_vpn' => true,
                                    'vpn' => { 'provider' => 'mullvad', 'provider_name' => 'Mullvad',
                                               'confidence' => 'high', 'last_seen' => '2026-11-13' })
    stub_lookups('146.70.116.130' => { body: body })
    result = InternetData::Client.new.lookup('146.70.116.130')

    assert result.frozen?
    assert result.raw.frozen?
    assert result.vpn.frozen?
    assert_raises(FrozenError) { result.raw['is_vpn'] = false }
  end

  def test_a_404_is_never_retried
    calls = stub_lookups('1.1.1.1' => { status: 404, body: { 'error' => 'no such route' } })
    client = InternetData::Client.new(retries: 2)

    error = assert_raises(InternetData::Error) { client.lookup('1.1.1.1') }
    assert_equal :bad_request, error.kind
    assert_equal 1, calls.length, 'a client error must cost exactly one request'
  end

  def test_a_429_without_retry_after_is_never_retried
    calls = stub_lookups('1.1.1.1' => {
      status: 429, body: { 'error' => 'overage cap reached; raise or remove it in Billing' }
    })
    client = InternetData::Client.new(retries: 2)

    error = assert_raises(InternetData::Error) { client.lookup('1.1.1.1') }
    assert_equal :quota_exceeded, error.kind
    assert_equal 1, calls.length, 'a spent allowance must not be hammered'
  end

  def test_a_429_carrying_retry_after_is_retried
    calls = []
    Typhoeus.stub(%r{\A#{Regexp.escape(BASE_URL)}/}).and_return(
      [
        lambda { |request|
          calls << request.url
          json_response(429, { 'error' => 'slow down' }, { 'Retry-After' => '0' })
        },
        lambda { |request|
          calls << request.url
          json_response(200, OK_BODY)
        },
      ],
    )
    result = InternetData::Client.new(retries: 2).lookup('1.1.1.1')

    assert_equal '1.1.1.1', result.ip
    assert_equal 2, calls.length
  end

  def test_a_server_error_is_retried_up_to_the_per_call_limit
    calls = stub_lookups('1.1.1.1' => { status: 500, body: { 'error' => 'lookup failed' } })
    client = InternetData::Client.new(retries: 0)

    assert_raises(InternetData::Error) { client.lookup('1.1.1.1') }
    assert_equal 1, calls.length, 'the client default of zero retries applies'

    calls.clear
    assert_raises(InternetData::Error) { client.lookup('1.1.1.1', retries: 2) }
    assert_equal 3, calls.length, 'a per-call retries override must be honored'
  end

  def test_a_transport_failure_is_a_network_error
    Typhoeus.stub(%r{\A#{Regexp.escape(BASE_URL)}/}).and_return(
      Typhoeus::Response.new(code: 0, return_code: :couldnt_connect, body: ''),
    )
    error = assert_raises(InternetData::Error) { InternetData::Client.new(retries: 0).lookup('1.1.1.1') }

    assert_equal :network, error.kind
    assert error.retryable?
  end

  # An AS and a domain are sent as given, path-escaped, and the API reads them;
  # neither answer is cached, since the cache is per address.
  def test_an_asn_and_a_domain_are_sent_as_given_and_never_cached
    calls = stub_lookups(
      'asn/9009' => { body: ASN_BODY }, 'asn/AS9009' => { body: ASN_BODY },
      'domain/example.com' => { body: DOMAIN_BODY }, 'domain/bücher.de' => { body: DOMAIN_BODY },
      'domain/a/b' => { body: DOMAIN_BODY }
    )
    client = InternetData::Client.new(api_key: API_KEY)

    2.times { assert_equal 9009, client.lookup_asn(9009).asn }
    assert_equal 'M247 Europe SRL', client.lookup_asn('AS9009').name
    2.times { assert_equal true, client.lookup_domain('example.com').is_registered }
    client.lookup_domain('bücher.de')
    client.lookup_domain('a/b')

    assert_equal %W[#{BASE_URL}/asn/9009 #{BASE_URL}/asn/9009 #{BASE_URL}/asn/AS9009 #{BASE_URL}/domain/example.com
                    #{BASE_URL}/domain/example.com #{BASE_URL}/domain/b%C3%BCcher.de #{BASE_URL}/domain/a%2Fb],
                 calls
  end

  def test_an_asn_or_a_domain_the_api_cannot_read_is_a_bad_request_asked_once
    calls = stub_lookups({})
    client = InternetData::Client.new(retries: 2)

    { 'an AS' => -> { client.lookup_asn(4_294_967_296) }, 'a domain' => -> { client.lookup_domain('exa mple') } }
      .each do |name, call|
        error = assert_raises(InternetData::Error, name) { call.call }

        assert_equal [:bad_request, 400, 'not a valid IP address, AS number or domain'],
                     [error.kind, error.status, error.message], name
      end
    assert_equal 2, calls.length
  end

  UNREADABLE = {
    'an HTML page' => ['<html>gateway</html>', { 'Content-Type' => 'text/html' }],
    'a cut-off body' => ['{"ip":"1.1.1.1","is_v', {}],
    'an empty body' => ['', {}],
    'an array' => ['[]', {}],
    'an object with no member it requires' => ['{}', {}],
    'members of the wrong type' => ['{"ip":5,"is_bogon":"x","results":[],"errors":"x"}', {}],
    'an answer without its ip' => [JSON.generate(OK_BODY.except('ip')), {}],
  }.freeze

  def test_a_2xx_that_is_not_its_answer_is_a_retried_server_error
    client = InternetData::Client.new(cache: false, retries: 1)
    calls = {
      'lookup' => -> { client.lookup('1.1.1.1') },
      'lookup_asn' => -> { client.lookup_asn(9009) },
      'lookup_domain' => -> { client.lookup_domain('example.com') },
      'my_ip' => -> { client.my_ip },
      'my_entitlement' => -> { client.my_entitlement },
    }
    UNREADABLE.each do |name, (body, headers)|
      calls.each do |call_name, call|
        sent = 0
        Typhoeus.stub(%r{\A#{Regexp.escape(BASE_URL)}/}).and_return do
          sent += 1
          json_response(200, body, headers)
        end
        error = assert_raises(InternetData::Error, "#{call_name}, #{name}") { call.call }

        assert_equal :server_error, error.kind, "#{call_name}, #{name}: #{error.message}"
        assert_equal 200, error.status, "#{call_name}, #{name}"
        assert_equal 2, sent, "#{call_name}, #{name}: retried"
      ensure
        Typhoeus::Expectation.clear
      end
    end
  end

  # A chunk carrying neither map is unreadable as a whole, so it is retried as
  # one.
  def test_a_batch_chunk_that_is_not_its_answer_is_retried
    UNREADABLE.each do |name, (body, headers)|
      sent = 0
      Typhoeus.stub("#{BASE_URL}/batch").and_return do
        sent += 1
        json_response(200, body, headers)
      end
      answers = InternetData::Client.new(cache: false, retries: 1).lookup_batch(%w[1.1.1.1 8.8.8.8])

      answers.each do |ip, answer|
        assert_kind_of InternetData::Error, answer, "#{name}, #{ip}"
        assert_equal :server_error, answer.kind, "#{name}, #{ip}"
        assert_equal 200, answer.status, "#{name}, #{ip}"
      end
      assert_equal 2, sent, "#{name}: the chunk was retried"
    ensure
      Typhoeus::Expectation.clear
    end
  end

  def test_a_batch_entry_that_is_not_an_answer_is_that_addresses_error_alone
    body = {
      'results' => {
        '1.1.1.1' => answer('1.1.1.1'),
        '2.2.2.2' => 'x',
        '3.3.3.3' => 5,
        '4.4.4.4' => { 'ip' => '4.4.4.4' },
      },
      'errors' => { '5.5.5.5' => 7, '6.6.6.6' => { 'status' => 404, 'error' => 'not found' } },
    }
    sent = 0
    Typhoeus.stub("#{BASE_URL}/batch").and_return do
      sent += 1
      json_response(200, body)
    end
    ips = %w[1.1.1.1 2.2.2.2 3.3.3.3 4.4.4.4 5.5.5.5 6.6.6.6 7.7.7.7]
    answers = InternetData::Client.new(cache: false, retries: 1).lookup_batch(ips)

    assert_equal '1.1.1.1', answers['1.1.1.1'].ip
    %w[2.2.2.2 3.3.3.3 4.4.4.4 5.5.5.5 7.7.7.7].each do |ip|
      assert_kind_of InternetData::Error, answers[ip], ip
      assert_equal :server_error, answers[ip].kind, ip
      assert_equal 200, answers[ip].status, ip
    end
    assert_equal :bad_request, answers['6.6.6.6'].kind
    assert_equal 1, sent, 'one unreadable entry does not retry the chunk'
  end

  CLASS_DETAIL = { 'provider' => 'p', 'provider_name' => 'P', 'confidence' => 'high', 'last_seen' => '2026-11-13' }
                 .freeze
  WRONG_TYPED = {
    'a flag of "yes"' => { 'is_tor' => 'yes' },
    'a flag of 1' => { 'is_vpn' => 1 },
    'is_bogon of null' => { 'is_bogon' => nil },
    'a detail of "x"' => { 'vpn' => 'x' },
    'a detail missing a member' => { 'tor' => CLASS_DETAIL.except('confidence') },
    'a numeric string in a detail' => {
      'dcproxy' => { 'provider' => 'p', 'provider_name' => 'P', 'first_seen' => '', 'last_seen' => '',
                     'hits' => '3', 'hits_days_pct' => 1, 'providers_num' => 1 },
    },
    'a null protocol' => {
      'pubproxy' => { 'entry' => true, 'exit' => false, 'protocols' => [nil], 'num_ports' => 1, 'num_proxies' => 1,
                      'last_seen' => '', 'last_usable' => '' },
    },
    'Web IP as an object' => { 'web' => {} },
    'a location without its country' => { 'location' => OK_BODY['location'].except('country') },
    'a latitude of "1"' => { 'location' => OK_BODY['location'].merge('latitude' => '1') },
    'a hosted_domains total of "3"' => { 'hosted_domains' => { 'total' => '3' } },
    'an ip of 5' => { 'ip' => 5 },
  }.freeze

  ASN_WRONG_TYPED = {
    'an asn of "9009"' => { 'asn' => '9009' },
    'a whois column of 1' => { 'whois' => { 'handle' => 1 } },
    'a prefix without its size' => {
      'prefixes' => [{ 'prefix' => '1.0.0.0/24', 'peer_count' => 1, 'rpki_status' => 'valid', 'first_seen' => '',
                       'country' => 'RO', 'other_origins' => [] }],
    },
    'an allocated of null' => { 'allocated' => nil },
  }.freeze

  DOMAIN_WRONG_TYPED = {
    'is_registered of "yes"' => { 'is_registered' => 'yes' },
    'a null A record' => { 'dns' => { 'a' => [nil], 'aaaa' => [], 'mx' => [], 'ns' => [], 'cname' => [] } },
    'a disposable detail missing a member' => {
      'is_disposable' => true, 'disposable' => { 'confidence' => 'high' },
    },
    'has_mx missing' => { 'has_mx' => nil },
  }.freeze

  # A member of the wrong type, a null the spec does not allow or a populated
  # detail missing a member it requires is the server breaking its contract, a
  # retried server error rather than an answer.
  def test_a_member_of_the_wrong_type_is_a_retried_server_error
    client = InternetData::Client.new(cache: false, retries: 1)
    answers = WRONG_TYPED.to_h do |name, member|
      ["lookup, #{name}", [-> { client.lookup('1.1.1.1') }, OK_BODY.merge(member)]]
    end
    answers['my_ip, a flag of "yes"'] = [-> { client.my_ip }, OK_BODY.merge('is_relay' => 'yes')]
    ASN_WRONG_TYPED.each do |name, member|
      answers["lookup_asn, #{name}"] = [-> { client.lookup_asn(9009) }, ASN_BODY.merge(member)]
    end
    DOMAIN_WRONG_TYPED.each do |name, member|
      answers["lookup_domain, #{name}"] = [-> { client.lookup_domain('example.com') }, DOMAIN_BODY.merge(member)]
    end
    usage = ENTITLEMENT_BODY['usage']
    apikey = ENTITLEMENT_BODY['apikey']
    {
      'requests of "1"' => ENTITLEMENT_BODY.merge('usage' => usage.merge('requests' => '1')),
      'a null CIDR' => ENTITLEMENT_BODY.merge('apikey' => apikey.merge('allowed_cidrs' => [nil])),
      'CIDRs of null' => ENTITLEMENT_BODY.merge('apikey' => apikey.merge('allowed_cidrs' => nil)),
      'a tier of 3' => ENTITLEMENT_BODY.merge('plan' => { 'key' => 'max', 'tier' => 3 }),
      'a window_start of "10:00"' => ENTITLEMENT_BODY.merge('usage' => usage.merge('window_start' => '10:00')),
      'a window_start with no zone' => ENTITLEMENT_BODY.merge('usage' => usage.merge('window_start' => '2026-09-04T07:00:00')),
    }.each { |name, body| answers["my_entitlement, #{name}"] = [-> { client.my_entitlement }, body] }
    answers.each do |name, (call, body)|
      sent = 0
      Typhoeus.stub(%r{\A#{Regexp.escape(BASE_URL)}/}).and_return do
        sent += 1
        json_response(200, body)
      end
      error = assert_raises(InternetData::Error, name) { call.call }

      assert_equal :server_error, error.kind, "#{name}: #{error.message}"
      assert_equal 200, error.status, name
      assert_equal 2, sent, "#{name}: retried"
    ensure
      Typhoeus::Expectation.clear
    end
  end

  # An empty detail is present and empty under a false flag, a populated one
  # reads whole, and a null in a member the spec does not require reads as
  # absent.
  def test_an_empty_detail_and_a_null_paid_member_read
    stub_lookups(
      '1.1.1.1' => { body: OK_BODY.merge('is_vpn' => false, 'vpn' => {}, 'web' => [], 'is_cdn' => nil) },
      '2.2.2.2' => { body: answer('2.2.2.2', 'is_tor' => true, 'tor' => CLASS_DETAIL) },
      'domain/example.com' => { body: DOMAIN_BODY.merge('is_disposable' => false, 'disposable' => {}) },
    )
    client = InternetData::Client.new

    one = client.lookup('1.1.1.1')
    assert_equal [{}, [], nil, false], [one.vpn, one.web, one.is_cdn, one.cdn?]
    assert_equal CLASS_DETAIL, client.lookup('2.2.2.2').tor
    assert_equal({}, client.lookup_domain('example.com').disposable)
  end

  def test_a_batch_entry_of_the_wrong_type_is_that_addresses_error_alone
    results = WRONG_TYPED.values.each_with_index.to_h do |member, i|
      ["9.9.9.#{i + 1}", answer("9.9.9.#{i + 1}").merge(member)]
    end
    results['1.1.1.1'] = answer('1.1.1.1', 'pubproxy' => {})
    errors = { '2.2.2.2' => { 'status' => '400', 'error' => 'bad' }, '3.3.3.3' => { 'status' => 400, 'error' => nil } }
    sent = 0
    Typhoeus.stub("#{BASE_URL}/batch").and_return do
      sent += 1
      json_response(200, { 'results' => results, 'errors' => errors })
    end
    answers = InternetData::Client.new(cache: false, retries: 1).lookup_batch(results.keys + errors.keys)

    assert_equal({}, answers['1.1.1.1'].pubproxy)
    (results.keys - ['1.1.1.1'] + errors.keys).each do |ip|
      assert_kind_of InternetData::Error, answers[ip], ip
      assert_equal :server_error, answers[ip].kind, ip
      assert_equal 200, answers[ip].status, ip
    end
    assert_equal 1, sent, 'one unreadable entry does not retry the chunk'
  end

  # The detail models are the spec's `allOf` members, each `{}` under a false
  # flag; a model the spec never writes that way must not read an empty object.
  def test_the_details_that_may_be_empty_are_the_specs
    spec = YAML.safe_load_file(File.expand_path('../spec/openapi.yaml', __dir__))
    details = %w[LookupResponse AsnLookupResponse DomainLookupResponse].flat_map do |name|
      spec.dig('components', 'schemas', name, 'properties').values.filter_map do |property|
        property['allOf']&.first&.fetch('$ref')&.split('/')&.last
      end
    end

    assert_equal details.uniq.sort, InternetData::Transport::DETAILS.sort
  end

  # The lookups build their own requests, so their paths are held to the
  # spec's instead of to a generated class.
  def test_every_lookup_path_is_the_specs
    paths = YAML.safe_load_file(File.expand_path('../spec/openapi.yaml', __dir__)).fetch('paths')
    transport = InternetData::Transport.new
    {
      ['/{ip}', 'get'] => transport.lookup_request('45.83.91.1'),
      ['/myip', 'get'] => transport.myip_request,
      ['/asn/{asn}', 'get'] => transport.asn_request(9009),
      ['/domain/{domain}', 'get'] => transport.domain_request('example.com'),
      ['/api/v1/entitlement', 'get'] => transport.entitlement_request,
      ['/batch', 'post'] => transport.batch_request(['1.1.1.1']),
    }.each do |(template, verb), request|
      assert paths.dig(template, verb), "#{verb} #{template} is not in the spec"
      pattern = Regexp.new("\\A#{Regexp.escape(BASE_URL)}#{template.gsub(/\{\w+\}/, '[^/]+')}\\z")
      assert_match pattern, request.base_url
      assert_equal verb.to_sym, request.options[:method]
    end
  end

  # Seconds as digits, or an HTTP date in any of its three forms, and nothing
  # else.
  def test_a_retry_after_is_digits_or_an_http_date
    at = Time.now.utc + 1
    {
      '0x10' => :quota_exceeded, '1_0' => :quota_exceeded, '1e3' => :quota_exceeded, '1e400' => :quota_exceeded,
      '1.5' => :quota_exceeded, '+1' => :quota_exceeded, '-1' => :quota_exceeded, 'tomorrow' => :quota_exceeded,
      '0' => :rate_limited, '120' => :rate_limited, at.httpdate => :rate_limited,
      at.strftime('%A, %d-%b-%y %H:%M:%S GMT') => :rate_limited,
      at.strftime('%a %b %e %H:%M:%S %Y') => :rate_limited,
    }.each do |value, kind|
      stub_lookups('1.1.1.1' => { status: 429, body: { 'error' => 'slow down' }, headers: { 'Retry-After' => value } })
      error = assert_raises(InternetData::Error, value) { InternetData::Client.new(retries: 0).lookup('1.1.1.1') }

      assert_equal kind, error.kind, "Retry-After #{value.inspect}"
    ensure
      Typhoeus::Expectation.clear
    end
  end

  def test_a_cached_answer_expires_with_its_ttl
    calls = stub_lookups('1.1.1.1' => { body: OK_BODY })
    client = InternetData::Client.new(cache_ttl: 0.05)

    client.lookup('1.1.1.1')
    client.lookup('1.1.1.1')
    assert_equal 1, calls.length

    sleep 0.1
    client.lookup('1.1.1.1')
    assert_equal 2, calls.length
  end

  def test_a_batch_reaches_the_concurrency_it_was_given
    server = TestServer.new(delay: 0.05)
    client = InternetData::Client.new(base_url: server.base_url, concurrency: 2, cache: false)
    # Enough addresses for nine chunks of the batch endpoint's 1000, so a
    # concurrency of eight has something to bound: one request per chunk, and
    # only the chunks overlap.
    addresses = (0...8001).map { |n| "9.#{1 + (n / 65536)}.#{(n / 256) % 256}.#{n % 256}" }

    client.lookup_batch(addresses)
    assert_equal 2, server.peak, 'the client setting bounds a batch that does not override it'

    per_call = TestServer.new(delay: 0.05)
    InternetData::Client.new(base_url: per_call.base_url, concurrency: 2, cache: false)
                        .lookup_batch(addresses, concurrency: 8)
    assert_equal 8, per_call.peak, 'a per-call concurrency must widen the batch, not be swallowed'
  ensure
    server&.stop
    per_call&.stop
  end

  def test_a_batch_honors_a_per_call_retries_override
    attempts = Hash.new(0)
    server = TestServer.new(delay: 0.0) do |path, body|
      attempts[path] += 1
      if attempts[path] < 3
        [500, '{"error":"lookup failed"}']
      else
        [200, TestServer.batch_body(body, is_vpn: true)]
      end
    end
    client = InternetData::Client.new(base_url: server.base_url, retries: 0, cache: false)

    assert_kind_of InternetData::Error, client.lookup_batch(['203.0.114.50'])['203.0.114.50']
    got = client.lookup_batch(['203.0.114.51'], retries: 2)['203.0.114.51']
    assert_equal true, got.is_vpn
  ensure
    server&.stop
  end

  # The per-call bound is set BELOW the client's against a server that stalls
  # past both, so a call that ignored it would wait out the client's bound
  # instead, and the elapsed time says which one fired.
  def test_a_per_call_timeout_below_the_clients_is_the_one_that_fires
    server = TestServer.new(delay: 8)
    client = InternetData::Client.new(base_url: server.base_url, timeout: 4, retries: 0, cache: false)
    calls = {
      lookup: -> { client.lookup('1.1.1.1', timeout: 0.3) },
      lookup_asn: -> { client.lookup_asn(9009, timeout: 0.3) },
      lookup_domain: -> { client.lookup_domain('example.com', timeout: 0.3) },
      my_ip: -> { client.my_ip(timeout: 0.3) },
      my_entitlement: -> { client.my_entitlement(timeout: 0.3) },
      lookup_batch: -> { client.lookup_batch(['1.1.1.1'], timeout: 0.3)['1.1.1.1'] },
    }

    calls.each do |name, call|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = begin
        call.call
      rescue InternetData::Error => e
        e
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_kind_of InternetData::Error, error, name
      assert_equal :network, error.kind, name
      assert error.retryable?, "#{name}: a timeout is a transport failure, and worth retrying"
      assert_operator elapsed, :<, 2, "#{name}: the client's 4s bound fired rather than the per-call one"
    end
  ensure
    server&.stop
  end

  # No cap on what one call accepts: chunking to the endpoint's 1000 is the
  # client's job, so 2,500 addresses are three requests rather than an error.
  def test_a_batch_of_2500_addresses_is_three_requests_and_one_answer_each
    addresses = (0...2500).map { |n| "9.1.#{n / 256}.#{n % 256}" }
    lock = Mutex.new
    sizes = []
    server = TestServer.new(delay: 0) do |_path, body|
      lock.synchronize { sizes << JSON.parse(body)['ips'].length }
      [200, TestServer.batch_body(body)]
    end

    got = InternetData::Client.new(base_url: server.base_url, cache: false).lookup_batch(addresses)

    assert_equal ['/batch'] * 3, server.paths
    assert_equal [500, 1000, 1000], sizes.sort
    assert_equal addresses, got.keys
    addresses.each { |ip| assert_equal ip, got[ip].ip, "#{ip} should be answered for itself" }
  ensure
    server&.stop
  end

  # A hydra that may run nothing never finishes, so a concurrency that is not a
  # whole count from 1 is the caller's mistake to hear about at once.
  def test_a_concurrency_that_is_not_an_integer_from_one_is_refused_where_it_is_set
    calls = stub_lookups('8.8.8.8' => { body: answer('8.8.8.8') })
    client = InternetData::Client.new
    client.lookup('8.8.8.8')
    calls.clear

    [0, -1, 0.5, 1.5, 2.0, Float::NAN, Float::INFINITY, Rational(3, 2), Complex(2, 0), '2', '', nil,
     Object.new].each do |limit|
      assert_raises(ArgumentError, "client concurrency #{limit.inspect}") do
        InternetData::Client.new(concurrency: limit)
      end
      next if limit.nil?

      {
        'a batch' => ['9.9.9.9'],
        'a batch of a bogon' => ['10.0.0.1'],
        'a batch of a cached address' => ['8.8.8.8'],
      }.each do |name, ips|
        error = assert_raises(InternetData::Error, "#{name}, concurrency #{limit.inspect}") do
          client.lookup_batch(ips, concurrency: limit)
        end
        assert_equal :bad_request, error.kind, "#{name}, concurrency #{limit.inspect}"
        refute error.retryable?
      end
    end
    assert_empty calls, 'no refused concurrency reached the network'
  end

  # Checked before the bogon and the cache, or a bad value would be refused only
  # when a request happened to be needed.
  def test_every_lookup_refuses_a_timeout_curl_cannot_hold_before_any_request
    calls = stub_lookups('8.8.8.8' => { body: answer('8.8.8.8') })
    client = InternetData::Client.new
    client.lookup('8.8.8.8')
    calls.clear

    [-1, Float::NAN, 2_147_484, '30'].each do |value|
      {
        'a bogon' => -> { client.lookup('10.0.0.1', timeout: value) },
        'a cached address' => -> { client.lookup('8.8.8.8', timeout: value) },
        'an address to look up' => -> { client.lookup('9.9.9.9', timeout: value) },
        'a batch' => -> { client.lookup_batch(['10.0.0.1', '8.8.8.8', '9.9.9.9'], timeout: value) },
        'a batch answered locally' => -> { client.lookup_batch(['10.0.0.1', '8.8.8.8'], timeout: value) },
        'an AS' => -> { client.lookup_asn(9009, timeout: value) },
        'a domain' => -> { client.lookup_domain('example.com', timeout: value) },
        'my_ip' => -> { client.my_ip(timeout: value) },
        'my_entitlement' => -> { client.my_entitlement(timeout: value) },
      }.each do |name, call|
        assert_raises(ArgumentError, "#{name}, timeout #{value.inspect}") { call.call }
      end
    end
    assert_empty calls, 'no refused timeout reached the network'
  end

  def test_a_retry_count_is_refused_where_it_is_set_on_every_lookup
    calls = stub_lookups('8.8.8.8' => { body: answer('8.8.8.8') })
    client = InternetData::Client.new
    client.lookup('8.8.8.8')
    calls.clear

    [-1, Float::NAN, 1.5, Float::INFINITY, '2', true].each do |value|
      {
        'a bogon' => -> { client.lookup('10.0.0.1', retries: value) },
        'a cached address' => -> { client.lookup('8.8.8.8', retries: value) },
        'an address to look up' => -> { client.lookup('9.9.9.9', retries: value) },
        'a batch' => -> { client.lookup_batch(['10.0.0.1', '8.8.8.8', '9.9.9.9'], retries: value) },
        'a batch answered locally' => -> { client.lookup_batch(['10.0.0.1', '8.8.8.8'], retries: value) },
        'an AS' => -> { client.lookup_asn(9009, retries: value) },
        'a domain' => -> { client.lookup_domain('example.com', retries: value) },
        'my_ip' => -> { client.my_ip(retries: value) },
        'my_entitlement' => -> { client.my_entitlement(retries: value) },
      }.each do |name, call|
        assert_raises(ArgumentError, "#{name}, retries #{value.inspect}") { call.call }
      end
    end
    assert_empty calls, 'no refused count reached the network'
    assert_equal '8.8.8.8', client.lookup('8.8.8.8', retries: nil).ip, 'nil per call is the client default'
  end

  # A chunk's retry waits on the same bound as a single call's.
  def test_a_batch_waits_out_a_retry_after_past_the_bound_on_the_backoff
    ['2147484', '9223372036854775807', '1' + ('0' * 400)].each do |value|
      Typhoeus.stub("#{BASE_URL}/batch").and_return(
        [json_response(429, { 'error' => 'slow down' }, 'Retry-After' => value),
         json_response(200, { 'results' => { '9.9.9.9' => answer('9.9.9.9') }, 'errors' => {} })],
      )
      worker = Thread.new { InternetData::Client.new(retries: 1).lookup_batch(['9.9.9.9']) }
      worker.report_on_exception = false

      assert worker.join(5), "Retry-After #{value}: the batch waited on the header"
      assert_equal '9.9.9.9', worker.value['9.9.9.9'].ip, "Retry-After #{value}: the retry succeeded"
    ensure
      worker&.kill
      Typhoeus::Expectation.clear
    end
  end

  # The bound must cover the BODY: a limit that stops at the response head lets a
  # body stalled after its headers run for as long as the server likes.
  def test_a_lookup_body_stalled_after_its_headers_is_bounded
    assert_body_bounded(stall: 8)
  end

  # A byte every 20 ms never leaves one read waiting long, so only a bound on the
  # whole attempt ends it.
  def test_a_lookup_body_trickled_a_byte_at_a_time_is_bounded
    assert_body_bounded(trickle: 0.02)
  end

  def test_a_keyless_client_presents_no_credential_at_all
    [nil, '', '   ', "\t", " \n"].each do |api_key|
      transport = InternetData::Transport.new(InternetData::Transport::Config.new(api_key: api_key))
      [transport.lookup_request('1.1.1.1'), transport.batch_request(['1.1.1.1'])].each do |request|
        refute request.options[:headers].key?('Authorization'), api_key.inspect
        refute request.options[:headers].key?('X-Api-Key')
        assert_empty request.options[:params]
      end
    end
  end

  def test_an_api_key_is_presented_as_a_bearer_token_on_every_lookup
    transport = InternetData::Transport.new(InternetData::Transport::Config.new(api_key: " secret\n"))
    [
      transport.lookup_request('1.1.1.1'), transport.myip_request, transport.asn_request(9009),
      transport.domain_request('example.com'), transport.entitlement_request, transport.batch_request(['1.1.1.1'])
    ].each do |request|
      assert_equal 'Bearer secret', request.options[:headers]['Authorization'], request.base_url
      refute request.options[:headers].key?('X-Api-Key')
      assert_empty request.options[:params]
      assert_match %r{\Ainternetdata-ruby/}, request.options[:headers]['User-Agent']
      assert_equal false, request.options[:followlocation], 'no request this library builds follows a redirect'
    end
  end

  ENTITLEMENT_BODY = {
    'org_id' => '85bb51e4-2eb6-4a31-8e4d-02ba8b98fe61',
    'apikey' => {
      'id' => '0ab424cc-7619-4dad-b027-afacdc2cedb0',
      'expires' => nil,
      'allowed_cidrs' => [],
    },
    'plan' => { 'key' => 'free', 'tier' => 'free' },
    'usage' => {
      'requests' => 21,
      'quota' => 100,
      'hard_limit' => nil,
      'window_start' => '2026-11-13T00:00:00Z',
      'window_end' => '2026-11-14T00:00:00Z',
    },
  }.freeze

  def test_my_ip_answers_for_the_calling_address
    stub_lookups('myip' => { body: answer('146.70.116.130') })
    result = InternetData::Client.new.my_ip

    assert_equal '146.70.116.130', result.ip
    assert_equal false, result.is_bogon
  end

  def test_my_ip_is_not_cached
    # The cache is keyed by address, and which address this is IS the question.
    calls = stub_lookups('myip' => { body: answer('146.70.116.130') })
    client = InternetData::Client.new
    client.my_ip
    client.my_ip

    assert_equal 2, calls.length
  end

  def test_my_entitlement_reports_the_plan_and_the_usage
    stub_lookups('api/v1/entitlement' => { body: ENTITLEMENT_BODY })
    ent = InternetData::Client.new.my_entitlement

    assert_equal 'free', ent.plan.key
    assert_equal 'free', ent.plan.tier
    assert_equal 21, ent.usage.requests
    assert_equal 100, ent.usage.quota
    # Null means NEVER stop, which is not the same as a limit of zero.
    assert_nil ent.usage.hard_limit
    assert_empty ent.apikey.allowed_cidrs
  end

  # RFC 3339 lets a date-time's T and Z be lowercase.
  def test_my_entitlement_reads_a_lowercase_t_or_z
    usage = ENTITLEMENT_BODY['usage'].merge('window_start' => '2026-09-04t07:00:00Z', 'window_end' => '2026-10-04T07:00:00z')
    apikey = ENTITLEMENT_BODY['apikey'].merge('expires' => '2027-01-01t00:00:00.5z')
    stub_lookups('api/v1/entitlement' => { body: ENTITLEMENT_BODY.merge('usage' => usage, 'apikey' => apikey) })
    ent = InternetData::Client.new.my_entitlement

    assert_equal '2026-09-04T07:00:00Z', ent.usage.window_start.utc.iso8601
    assert_equal '2026-10-04T07:00:00Z', ent.usage.window_end.utc.iso8601
    assert_equal '2027-01-01T00:00:00.500Z', ent.apikey.expires.utc.iso8601(3)
  end

  def test_my_entitlement_is_not_cached
    # The whole point is what has been spent.
    calls = stub_lookups('api/v1/entitlement' => { body: ENTITLEMENT_BODY })
    client = InternetData::Client.new
    client.my_entitlement
    client.my_entitlement

    assert_equal 2, calls.length
  end

  def test_my_entitlement_surfaces_an_unauthorized_key
    stub_lookups('api/v1/entitlement' => { status: 401, body: { 'error' => 'invalid API key' } })
    client = InternetData::Client.new(retries: 0)

    error = assert_raises(InternetData::Error) { client.my_entitlement }
    assert_equal [:unauthorized, 'invalid API key', nil], [error.kind, error.message, error.rc]
  end

  # Twenty threads looking up one address are one request. The server holds
  # each answer, so the calls genuinely overlap.
  def test_concurrent_misses_for_one_address_share_one_request
    server = TestServer.new(delay: 0.2)
    client = InternetData::Client.new(base_url: server.base_url)

    results = Array.new(20) { Thread.new { client.lookup('9.9.9.1') } }.map(&:value)

    assert_equal ['/9.9.9.1'], server.paths, 'twenty concurrent lookups of one address send one request'
    assert_equal 20, results.count { |r| r.ip == '9.9.9.1' }, 'and every caller gets its answer'
  ensure
    server&.stop
  end

  def test_a_batch_and_a_lookup_share_an_address_in_flight_both_ways
    batches = []
    server = TestServer.new(delay: 0.2) do |path, body|
      if path == '/batch'
        batches << JSON.parse(body).fetch('ips').sort
        [200, TestServer.batch_body(body)]
      else
        [200, JSON.generate(answer(path[1..]))]
      end
    end
    client = InternetData::Client.new(base_url: server.base_url)

    single = Thread.new { client.lookup('9.9.9.2') }
    sleep 0.05
    batch = client.lookup_batch(['9.9.9.2', '9.9.9.3'])
    assert_equal ['/9.9.9.2', '/batch'], server.paths.sort, 'the lookup and the batch each sent once'
    assert_equal [['9.9.9.3']], batches, 'the batch left out the address the lookup was fetching'
    assert_same single.value, batch['9.9.9.2'], "and took the lookup's answer for it"

    first = Thread.new { client.lookup_batch(['9.9.9.4', '9.9.9.5']) }
    sleep 0.05
    late = client.lookup('9.9.9.5')
    assert_equal 1, server.paths.count('/batch') - 1, 'a lookup of an address a batch is fetching sends nothing'
    assert_equal 3, server.paths.size
    assert_same first.value['9.9.9.5'], late, "and takes the batch's answer"
  ensure
    server&.stop
  end

  # A failure reaches every waiter and is cached for none; a leader that never
  # finishes leaves its waiters to ask again; and a client without a cache,
  # where every lookup is served, shares nothing.
  def test_a_shared_request_fails_every_waiter_and_a_dead_leader_fails_none
    server = TestServer.new(delay: 0.2) do |path, _body|
      path == '/9.9.9.9' ? [500, JSON.generate({ 'error' => 'boom' })] : [200, JSON.generate(answer(path[1..]))]
    end
    client = InternetData::Client.new(base_url: server.base_url, retries: 0)

    outcomes = Array.new(5) do
      Thread.new do
        client.lookup('9.9.9.9')
        :returned
      rescue InternetData::Error => e
        e
      end
    end.map(&:value)
    assert_equal ['/9.9.9.9'], server.paths, 'five concurrent lookups of a failing address send one request'
    assert_equal 5, outcomes.count { |o| o.is_a?(InternetData::Error) && o.kind == :server_error },
                 'and all five raise its error'
    assert_raises(InternetData::Error) { client.lookup('9.9.9.9') }
    assert_equal 2, server.paths.size, 'the failure was not cached'

    leader = Thread.new { client.lookup('9.9.9.7') }
    sleep 0.05
    waiter = Thread.new { client.lookup('9.9.9.7') }
    sleep 0.05
    leader.kill
    assert waiter.join(5), 'a waiter whose leader died was left waiting'
    assert_equal '9.9.9.7', waiter.value.ip, 'a waiter whose leader died asks again'
    assert_equal 2, server.paths.count('/9.9.9.7')

    uncached = InternetData::Client.new(base_url: server.base_url, cache: false)
    Array.new(5) { Thread.new { uncached.lookup('9.9.9.6') } }.each(&:join)
    assert_equal 5, server.paths.count('/9.9.9.6'), 'a client with no cache shares nothing'
  ensure
    server&.stop
  end

  private

  # Each call's per-call bound (0.3 s) fires first, then a call with no override
  # waits for the client's own (1 s), and the elapsed time says which one fired.
  def assert_body_bounded(pace)
    padded = "#{JSON.generate(answer('1.1.1.1'))}#{' ' * 400}"
    server = TestServer.new(delay: 0) { |_path, _body| [200, padded, {}, pace] }
    client = InternetData::Client.new(base_url: server.base_url, timeout: 1, retries: 0, cache: false)
    per_call = {
      lookup: -> { client.lookup('1.1.1.1', timeout: 0.3) },
      lookup_batch: -> { client.lookup_batch(['1.1.1.1'], timeout: 0.3)['1.1.1.1'] },
      lookup_asn: -> { client.lookup_asn(9009, timeout: 0.3) },
      lookup_domain: -> { client.lookup_domain('example.com', timeout: 0.3) },
      my_ip: -> { client.my_ip(timeout: 0.3) },
    }
    client_bound = {
      lookup: -> { client.lookup('1.1.1.1') },
      my_entitlement: -> { client.my_entitlement },
    }

    per_call.each { |name, call| assert_times_out(name, call, 0.25..0.9) }
    client_bound.each { |name, call| assert_times_out(name, call, 0.9..2.5) }
  ensure
    server&.stop
  end

  def assert_times_out(name, call, window)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = begin
      call.call
    rescue InternetData::Error => e
      e
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_kind_of InternetData::Error, error, name
    assert_equal :network, error.kind, "#{name}: #{error.message}"
    assert error.retryable?, "#{name}: a timeout is a transport failure, and worth retrying"
    assert_includes window, elapsed, "#{name} settled after #{elapsed.round(2)}s"
  end
end
