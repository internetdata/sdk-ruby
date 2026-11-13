# frozen_string_literal: true

# Asserts the shared conformance corpus that every InternetData SDK asserts.
#
# The corpus is generated into testdata/ and is identical across languages, so a
# behavior that drifts here fails here rather than surfacing as two client
# libraries quietly disagreeing about the same refusal.

require_relative 'test_helper'

class ConformanceTest < Minitest::Test
  include TestHelper

  def setup
    # Anything not stubbed raises instead of reaching the network, so a test
    # that claims no request was made cannot pass by accident.
    Typhoeus::Config.block_connection = true
  end

  def teardown
    Typhoeus::Config.block_connection = false
    Typhoeus::Expectation.clear
  end

  def test_bogon_matches_the_canonical_ranges
    CORPUS['isBogon'].each do |c|
      assert_equal c['expect'], InternetData.bogon?(c['ip']), "#{c['ip']} (#{c['why']})"
    end
  end

  # A server listening on :: sees every IPv4 visitor as ::ffff:a.b.c.d. Read
  # whole that is inside ::ffff:0:0/96, so an SDK that did not unmap answered
  # each one locally as a bogon and never asked.
  def test_an_ipv4_mapped_address_is_the_ipv4_address_it_carries
    CORPUS['ipv4Mapped'].each do |c|
      ip = c['ip']
      carries = c['carries']
      assert_equal c['expect'], InternetData.bogon?(ip), "#{ip}: bogon? (#{c['why']})"

      Typhoeus::Expectation.clear
      routes = { carries => { body: answer(carries) } }
      calls = stub_lookups(routes)
      client = InternetData::Client.new
      result = client.lookup(ip)
      assert_equal carries, result.ip, "#{ip}: the answer names #{carries}"
      if c['expect']
        assert result.bogon?, "#{ip}: answered as a bogon"
        assert_empty calls, "#{ip}: with no request"
        next
      end
      assert_equal ["#{BASE_URL}/#{carries}"], calls, "#{ip}: sent as #{carries}"
      client.lookup(carries)
      assert_equal 1, calls.length, "#{ip}: a lookup of #{carries} is then a cache hit"

      # The mapped form alone: asked beside its plain form, a batch that sent
      # the address as given would still have been answered for the plain one.
      Typhoeus::Expectation.clear
      sent = []
      Typhoeus.stub("#{BASE_URL}/batch").and_return do |request|
        sent.concat(JSON.parse(request.options[:body].to_s).fetch('ips', []))
        batch_response(routes, request.options[:body])
      end
      answers = InternetData::Client.new(retries: 0).lookup_batch([ip])
      assert_equal [ip], answers.keys, "#{ip}: a batch keys the answer as asked"
      answer = answers[ip]
      assert_equal carries, (answer.respond_to?(:ip) ? answer.ip : nil), "#{ip}: and answers it as #{carries}"
      assert_equal [carries], sent, "#{ip}: the batch sent #{carries} alone"
    end
  end

  # The shape the API answers a bogon on a paid plan, whatever this client's
  # plan, with the address filled in.
  def test_a_bogon_is_answered_locally_in_the_widest_shape
    calls = stub_lookups({})
    shape = CORPUS['bogonResponse']
    %w[10.0.0.1 ::1].each do |ip|
      result = InternetData::Client.new.lookup(ip)

      assert_equal({ 'ip' => ip }.merge(shape['answer']), result.raw, ip)
      assert result.bogon?, ip
      shape['flagsFalse'].each do |flag|
        assert_equal false, result.public_send(flag), "#{flag} must be present and false"
        assert result.included?(flag), "#{flag} must be present"
      end
      (shape['emptyObjects'] + shape['emptyLists']).each do |detail|
        assert_empty result.public_send(detail), "#{detail} must be present and empty"
        assert result.included?(detail), "#{detail} must be present"
      end
      %w[location asn company abuse whois rwhois].each do |object|
        assert_equal shape[object], result.public_send(object), object
      end
      assert_equal shape['hostname'], result.hostname
      assert_equal shape['hostedDomains'], result.hosted_domains
    end
    assert_empty calls, 'a bogon must not reach the network'
  end

  # Absent is "not in your plan" and must never read as false or 0, and that
  # holds inside a shared object too: Unlimited's location has no city.
  def test_lookup_preserves_absent_versus_false_across_every_plan_shape
    CORPUS['lookup'].each do |c|
      result = corpus_lookup(c)
      expect = c['expect']

      expect['present'].each do |field, value|
        assert_equal value, result.public_send(field), "#{c['name']}: #{field} should be #{value.inspect}"
        assert result.included?(field), "#{c['name']}: #{field} should be included"
        next unless [true, false].include?(value)

        assert_equal value, result.public_send(predicate_for(field)), "#{c['name']}: #{field} predicate"
      end
      expect['objects'].each do |field|
        value = result.public_send(field)
        assert value.is_a?(Hash) || value.is_a?(Array), "#{c['name']}: #{field} should be present"
      end
      expect['empty'].each do |field|
        assert_empty result.public_send(field), "#{c['name']}: #{field} must be present and empty"
        assert result.included?(field), "#{c['name']}: #{field} must be included"
      end
      expect['absent'].each do |field|
        assert_nil result.public_send(field), "#{c['name']}: #{field} must be ABSENT, not false"
        refute result.included?(field), "#{c['name']}: #{field} must not be reported as included"
        next unless result.respond_to?(predicate_for(field))

        # A predicate coalesces absent to false rather than passing nil on, so
        # `if result.vpn?` is never a three-way question.
        assert_equal false, result.public_send(predicate_for(field)),
                     "#{c['name']}: #{predicate_for(field)} must answer false, never nil"
      end
      (expect['absentIn'] || {}).each do |object, members|
        members.each do |member|
          refute result.public_send(object).key?(member), "#{c['name']}: #{object}.#{member} must be ABSENT"
        end
      end

      Typhoeus::Expectation.clear
    end
  end

  # A lookup refusal's message is its `error`, a database refusal's its `rc`,
  # and each is classified by its status alone: the corpus holds both, and each
  # is run against a lookup and a database call.
  def test_errors_are_classified_by_range_and_by_retry_after
    CORPUS['errors'].each do |c|
      error_calls.each do |name, (path, call)|
        stub_api(path, c['status'], c['body'], c['headers'])
        # No retries, so a retryable error still surfaces rather than looping.
        error = assert_raises(InternetData::Error, "#{name}, #{c['name']}") { call.call(client) }

        assert_equal c['expect']['kind'], error.kind.to_s, "#{name}, #{c['name']}"
        assert_equal c['expect']['retryable'], error.retryable?, "#{name}, #{c['name']}: retryable"
        assert_equal c['status'], error.status, "#{name}, #{c['name']}: status"
        assert_equal c['body']['rc'], error.rc, "#{name}, #{c['name']}: rc"
        if c['expect']['message']
          assert_equal c['expect']['message'], error.message, "#{name}, #{c['name']}: message"
        end
        if c['expect']['retryAfterSeconds']
          assert_equal c['expect']['retryAfterSeconds'], error.retry_after_seconds, "#{name}, #{c['name']}"
        end
      ensure
        Typhoeus::Expectation.clear
      end
    end
  end

  # A 404 is a CLIENT error. Three of four VPNDetection SDKs let one fall through
  # to the retryable server_error default and asked twice more for a database ID
  # that will never exist, so the count is pinned rather than the classification
  # alone.
  def test_a_client_error_is_asked_for_exactly_once_and_a_server_error_is_not
    CORPUS['errors'].each do |c|
      error_calls.each do |name, (path, call)|
        calls = stub_api(path, c['status'], c['body'], c['headers'])
        retrying = InternetData::Client.new(api_key: API_KEY, retries: 2)

        assert_raises(InternetData::Error, "#{name}, #{c['name']}") { call.call(retrying) }
        want = c['expect']['retryable'] ? 3 : 1
        assert_equal want, calls.length, "#{name}, #{c['name']}: attempts"
      ensure
        Typhoeus::Expectation.clear
      end
    end
  end

  def test_batch_dedupes_short_circuits_bogons_and_keys_by_address
    c = corpus_batch('dedup-bogon-and-order-free-keying')
    routes = { '1.1.1.1' => { body: answer('1.1.1.1') }, '8.8.8.8' => { body: answer('8.8.8.8') } }
    sent = []
    Typhoeus.stub("#{BASE_URL}/batch").and_return do |request|
      sent << JSON.parse(request.options[:body].to_s).fetch('ips')
      batch_response(routes, request.options[:body])
    end
    got = InternetData::Client.new.lookup_batch(c['input'])

    assert_equal c['expect']['keys'], got.keys
    assert_equal c['expect']['httpRequests'], sent.length
    assert_equal [c['expect']['keys'] - c['expect']['bogonKeys']], sent, 'each address sent once'
    c['expect']['bogonKeys'].each do |ip|
      assert got[ip].bogon?, "#{ip} should be a local answer"
    end
  end

  def test_one_bad_address_does_not_lose_the_rest_of_the_batch
    c = corpus_batch('partial-failure-does-not-fail-the-batch')
    stub_lookups('1.1.1.1' => { body: answer('1.1.1.1', 'is_tor' => false) })
    got = InternetData::Client.new(retries: 0).lookup_batch(c['input'])

    assert_equal c['expect']['keys'], got.keys
    c['expect']['errorKeys'].each do |ip|
      assert_kind_of InternetData::Error, got[ip], "#{ip} should carry its error"
      assert_equal c['expect']['errorKinds'][ip].to_sym, got[ip].kind, ip
    end
    assert_equal false, got['1.1.1.1'].is_tor, 'the good address still answered'
  end

  def test_a_cache_hit_issues_no_second_request
    c = corpus_batch('cache-hit-issues-no-second-request')
    calls = stub_lookups('1.1.1.1' => { body: answer('1.1.1.1') })
    client = InternetData::Client.new

    c['repeat'].times { client.lookup_batch(c['input']) }

    assert_equal c['expect']['httpRequests'], calls.length
  end

  def test_a_large_batch_is_sent_in_chunks_of_a_thousand
    c = corpus_batch('chunks-of-one-thousand')
    calls = stub_lookups(c['input'].to_h { |ip| [ip, { body: answer(ip) }] })
    got = InternetData::Client.new(cache: false).lookup_batch(c['input'])

    assert_equal c['expect']['keyCount'], got.size
    assert_equal c['expect']['httpRequests'], calls.length
    c['input'].each do |ip|
      assert_equal ip, got[ip].ip, "#{ip} should be answered for itself"
    end
  end

  # No cap on what one call takes: the chunking is the client's job.
  def test_an_uncapped_batch_is_chunked_rather_than_refused
    c = corpus_batch('uncapped-input-is-chunked')
    calls = stub_lookups(c['input'].to_h { |ip| [ip, { body: answer(ip) }] })
    got = InternetData::Client.new(cache: false).lookup_batch(c['input'])

    assert_equal c['expect']['httpRequests'], calls.length
    assert_equal c['expect']['keyCount'], got.size
    c['input'].each do |ip|
      assert_equal ip, got[ip].ip, "#{ip} should be answered for itself"
    end
  end

  # A per-entry failure carries no headers, so its 429 can only be a spent
  # allowance, and a 500 is the server's; neither is retried per entry, because
  # retries belong to the call and the call succeeded.
  def test_an_entry_error_is_classified_by_its_status
    c = corpus_batch('an-entry-error-is-classified-by-its-status')
    calls = stub_lookups(
      '1.1.1.1' => { body: answer('1.1.1.1') },
      '8.8.8.8' => { status: 429, body: { 'error' => 'overage cap reached; raise or remove it in Billing' } },
      '9.9.9.9' => { status: 500, body: { 'error' => 'lookup failed' } },
    )
    got = InternetData::Client.new(retries: 3).lookup_batch(c['input'])

    assert_equal c['expect']['keys'], got.keys
    c['expect']['errorKinds'].each do |ip, kind|
      assert_kind_of InternetData::Error, got[ip], "#{ip} should carry its error"
      assert_equal kind.to_sym, got[ip].kind, ip
    end
    assert_equal c['expect']['httpRequests'], calls.length
  end

  def test_two_clients_never_share_a_cached_answer
    calls = stub_lookups('1.1.1.1' => { body: answer('1.1.1.1') })
    InternetData::Client.new(api_key: 'key-a').lookup('1.1.1.1')
    InternetData::Client.new(api_key: 'key-b').lookup('1.1.1.1')

    # Two keys can be on different plans and so entitled to different fields; a
    # shared cache would serve one of them the other's shape.
    assert_equal 2, calls.length
  end

  def test_caching_can_be_turned_off
    calls = stub_lookups('1.1.1.1' => { body: answer('1.1.1.1') })
    client = InternetData::Client.new(cache: false)
    client.lookup('1.1.1.1')
    client.lookup('1.1.1.1')

    assert_equal 2, calls.length
  end

  # A database commissioned for a single customer is ABSENT from a listing for
  # anyone else, rather than present with a standing of `unlicensed`. The server
  # decides that per key, so the catalog differs between two keys and there is no
  # second source to reconstruct it from. The corpus names the rules; this maps
  # each one to the test that answers it, so a rule added there fails here until
  # it is answered.
  VISIBILITY_RULES = {
    'listing-is-returned-as-served' => :test_the_listing_is_returned_as_served,
    'no-catalog-is-compiled-into-the-client' => :test_no_catalog_is_compiled_into_the_client,
    'a-listing-is-never-reused-across-clients' => :test_a_listing_is_never_reused_across_clients,
  }.freeze

  def test_every_visibility_rule_in_the_corpus_is_answered_here
    assert_equal CORPUS['visibility']['clientRules'].sort, VISIBILITY_RULES.keys.sort
    VISIBILITY_RULES.each_value { |name| assert_respond_to self, name }
  end

  def test_the_listing_is_returned_as_served
    published = CORPUS['standings'].map { |standing| family("db_#{standing}", standing) }
    stub_api('/api/v2/database/list', 200, { 'databases' => published })

    got = client.database.list

    assert_equal published.map { |d| d['base'] }, got.map(&:base)
    assert_equal CORPUS['standings'], got.map(&:standing)
  end

  # Nothing to fall back on means nothing to leak: a client holding a catalog of
  # its own would have something to answer with here.
  def test_no_catalog_is_compiled_into_the_client
    stub_api('/api/v2/database/list', 200, { 'databases' => [] })

    assert_empty client.database.list
  end

  # A catalog is per key, so nothing about it may be remembered across clients.
  # A cache that outlived one of them would show one org another org's catalog,
  # which is the whole of the visibility contract undone.
  def test_a_listing_is_never_reused_across_clients
    calls = stub_api('/api/v2/database/list', 200, { 'databases' => [family('db', 'licensed')] })

    InternetData::Client.new(api_key: 'key-a', retries: 0).database.list
    InternetData::Client.new(api_key: 'key-b', retries: 0).database.list

    assert_equal 2, calls.length
    assert_equal ['Bearer key-a', 'Bearer key-b'],
                 calls.map { |request| request.options[:headers]['Authorization'] }
  end

  def test_every_documented_standing_and_license_type_decodes
    CORPUS['standings'].each do |standing|
      CORPUS['license_type'].each do |license_type|
        decoded = InternetData::Database.build_from_hash(family('x', standing, license_type))
        assert_equal standing, decoded.standing
        assert_equal license_type, decoded.license_type
      end
    end
    # Null when there is no license, which is most of a published catalog.
    assert_nil InternetData::Database.build_from_hash(family('x', 'unlicensed', nil)).license_type
  end

  def test_every_documented_format_is_accepted_and_nothing_else_is
    CORPUS['formats'].each do |format|
      stub_api('/api/v2/database/checksum', 200,
               { 'id' => 'bogon_ip_v1', 'format' => format, 'checksums' => digests })
      assert_equal digests['sha256'], client.database.checksums('bogon_ip_v1', format).sha256

      Typhoeus::Expectation.clear
    end
    assert_raises(ArgumentError) { client.database.checksums('bogon_ip_v1', 'parquet') }
  end

  private

  # One corpus case's call, answered with its body.
  def corpus_lookup(c)
    path, call = {
      'lookup' => ["/#{c['target']}", ->(client) { client.lookup(c['target']) }],
      'lookupAsn' => ["/asn/#{c['target']}", ->(client) { client.lookup_asn(c['target']) }],
      'lookupDomain' => ["/domain/#{c['target']}", ->(client) { client.lookup_domain(c['target']) }],
    }.fetch(c['call'])
    stub_api(path, c['status'], c['body'])
    call.call(InternetData::Client.new)
  end

  def predicate_for(field)
    "#{field.delete_prefix('is_')}?"
  end

  # A lookup and a database call, each with the path it asks.
  def error_calls
    {
      'lookup' => ['/1.1.1.1', ->(client) { client.lookup('1.1.1.1') }],
      'database' => ['/api/v2/database/metadata', ->(client) { client.database.metadata('bogon_ip_v1') }],
    }
  end

  def family(base, standing, license_type = 'standard')
    {
      'base' => base, 'name' => base.upcase, 'summary' => 'a line',
      'standing' => standing, 'open' => false, 'license_type' => license_type,
      'starts' => nil, 'expires' => nil,
      'versions' => [{
        'id' => "#{base}_v1", 'version' => 1, 'summary' => 'a line',
        'formats' => CORPUS['formats'],
      }],
    }
  end

  def digests
    {
      'md5' => 'd41d8cd98f00b204e9800998ecf8427e',
      'sha1' => 'da39a3ee5e6b4b0d3255bfef95601890afd80709',
      'sha256' => 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'sha512' => 'cf83e1357eefb8bd',
    }
  end
end
