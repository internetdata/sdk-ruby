# frozen_string_literal: true

require_relative 'test_helper'
require 'internetdata/middleware'

# The middleware half of the shared conformance corpus, plus the Ruby-specific
# parts of it.
#
# The corpus needs no translation here at all: this SDK's Result is backed by
# the raw wire hash, so `{ 'location' => { 'country' => ... } }` is both what
# the corpus holds and what a caller writes. Symbol keys work too.
class MiddlewareTest < Minitest::Test
  include TestHelper

  MIDDLEWARE = TestHelper::CORPUS['middleware']
  UNLIMITED = TestHelper::CORPUS['lookup'].find { |c| c['name'] == 'unlimited-answer' }.fetch('body')
  PAID = TestHelper::CORPUS['lookup'].find { |c| c['name'] == 'paid-full-shape' }.fetch('body')
  PUBLIC_IP = PAID.fetch('ip')

  # The least a framework can offer, so the core is exercised without one.
  Req = Struct.new(:headers, :ip) do
    def initialize(headers = {}, ip = PUBLIC_IP)
      super(headers.transform_keys { |k| k.to_s.downcase }, ip)
    end
  end

  SELECTORS = InternetData::Middleware::Selectors.new do |request|
    InternetData::Middleware::RequestView.new(
      header: ->(name) { request.headers[name.downcase] },
      framework_ip: -> { request.ip }
    )
  end

  def setup
    Typhoeus::Expectation.clear
  end

  def teardown
    Typhoeus::Expectation.clear
  end

  def core(**options)
    InternetData::Middleware::Core.new(SELECTORS.default, **options)
  end

  def serving(body, status: 200, headers: {})
    ip = body['ip'] || PUBLIC_IP
    calls = stub_lookups(ip => { status: status, body: body, headers: headers })
    [InternetData::Client.new(cache: false, retries: 0), calls]
  end

  def test_corpus_conditions
    MIDDLEWARE['conditions'].each do |c|
      why = "#{c['name']}: #{c['why']}"
      result = if c['bogon']
                 InternetData::Bogon.result(c['bogon'])
               else
                 client, = serving(c['body'])
                 client.lookup(c['body']['ip'])
               end

      assert_equal c['expect']['blocked'],
                   InternetData::Middleware::Condition.matches?(c['condition'], result), why
      assert_equal c['expect']['missing'].sort,
                   InternetData::Middleware::Condition.missing_members(c['condition'], result).sort,
                   why
      Typhoeus::Expectation.clear
    end
  end

  def test_corpus_refuses_a_condition_that_constrains_nothing
    MIDDLEWARE['invalidConditions'].each do |c|
      error = assert_raises(ArgumentError, "#{c['name']}: #{c['why']}") do
        core(block_condition: c['condition'])
      end
      assert_match(/constrains nothing/, error.message)
    end
  end

  def test_enriches_without_blocking_when_no_condition_is_configured
    client, = serving(UNLIMITED)
    lookup = core(client: client).evaluate(Req.new)

    refute lookup.blocked?
    assert_equal 'AT', lookup.result.location['country']
    assert_equal 9009, lookup.result.asn['asn']
    assert_equal PUBLIC_IP, lookup.ip
  end

  def test_a_country_condition_blocks_without_a_key_and_another_country_passes
    client, = serving(UNLIMITED)
    blocking = core(client: client, block_condition: { location: { country: %w[DE AT] } })
    passing = core(client: client, block_condition: { location: { country: 'DE' } })

    assert blocking.evaluate(Req.new).blocked?
    refute passing.evaluate(Req.new).blocked?
  end

  def test_skip_claims_the_request_and_costs_no_lookup
    client, calls = serving(PAID)
    assert_nil core(client: client, skip: ->(_r) { true }).evaluate(Req.new)
    assert_empty calls
  end

  def test_fails_open_on_a_lookup_error_and_closed_only_when_asked
    client, = serving({ 'ip' => PUBLIC_IP, 'error' => 'boom' }, status: 500)
    opened = core(client: client, block_condition: { 'location' => { 'country' => 'AT' } })
    lookup = opened.evaluate(Req.new)

    refute lookup.blocked?
    assert_kind_of InternetData::Error, lookup.error
    assert_nil lookup.result

    closed = core(client: client, block_condition: { 'location' => { 'country' => 'AT' } }, fail_closed: true)
    assert closed.evaluate(Req.new).blocked?
  end

  def test_a_rate_limit_still_fails_open
    client, = serving({ 'ip' => PUBLIC_IP, 'error' => 'rate limit exceeded' },
                      status: 429, headers: { 'Retry-After' => '30' })
    lookup = core(client: client, block_condition: { location: { country: 'AT' } }).evaluate(Req.new)

    refute lookup.blocked?
    assert_equal :rate_limited, lookup.error.kind
  end

  def test_a_private_client_address_warns_once_and_never_reaches_the_network
    client, calls = serving(PAID)
    warnings = []
    subject = core(client: client, block_condition: { 'location' => { 'country' => 'AT' } },
                   on_warn: ->(m) { warnings << m })

    2.times do
      lookup = subject.evaluate(Req.new({}, '10.0.0.7'))
      refute lookup.blocked?
      assert lookup.result.bogon?
    end

    assert_empty calls
    assert_equal 1, warnings.length, 'a per-request warning is an outage of its own'
    assert_match(/not a public address/, warnings.first)
  end

  def test_a_missing_member_warns_once_or_raises_on_request
    client, = serving(UNLIMITED)
    warnings = []
    warned = core(client: client, block_condition: { 'is_hosting' => true }, on_warn: ->(m) { warnings << m })
    2.times { warned.evaluate(Req.new) }

    assert_equal 1, warnings.length
    assert_match(/is_hosting/, warnings.first)

    strict = core(client: client, block_condition: { 'is_hosting' => true }, on_missing_field: :raise)
    error = assert_raises(ArgumentError) { strict.evaluate(Req.new) }
    assert_match(/does not include/, error.message)
  end

  # location is on every plan and its city is not, so a city condition on
  # Unlimited can never fire: it is reported by its path, not passed over
  # because location itself was served.
  def test_a_paid_member_inside_an_object_every_plan_gets_is_warned_about_by_its_path
    client, = serving(UNLIMITED)
    warnings = []
    lookup = core(client: client, block_condition: { location: { city: 'Vienna' } },
                  on_warn: ->(m) { warnings << m }).evaluate(Req.new)

    refute lookup.blocked?
    assert_equal 1, warnings.length
    assert_match(/location\.city/, warnings.first)
  end

  def test_symbol_keys_work_as_well_as_strings
    client, = serving(PAID)
    lookup = core(client: client, block_condition: { asn: { type: 'HOSTING' }, location: { country: 'at' } })
             .evaluate(Req.new)

    # A Ruby caller writes symbols; the corpus and the wire use strings. Both
    # have to reach the same answer or one of the two is a trap.
    assert lookup.blocked?
  end

  def test_selectors_read_what_they_say_they_read
    request = Req.new({ 'X-Forwarded-For' => '203.0.113.9, 70.41.3.18, 150.172.238.178' },
                      '10.0.0.1')

    assert_equal '10.0.0.1', SELECTORS.default.call(request)
    assert_equal '203.0.113.9', SELECTORS.xff.call(request)
    assert_equal '150.172.238.178', SELECTORS.xff(1).call(request)
    assert_equal '70.41.3.18', SELECTORS.xff(2).call(request)
    assert_equal '10.0.0.1', SELECTORS.header('CF-Connecting-IP').call(request)

    cloudflared = Req.new({ 'CF-Connecting-IP' => '198.51.100.4' }, '10.0.0.1')
    assert_equal '198.51.100.4', SELECTORS.header('CF-Connecting-IP').call(cloudflared)
    assert_equal '10.0.0.1', SELECTORS.xff.call(Req.new({}, '10.0.0.1'))
  end

  def test_an_unresolvable_address_warns_and_does_not_block
    warnings = []
    subject = InternetData::Middleware::Core.new(
      ->(_r) { nil },
      block_condition: { 'location' => { 'country' => 'AT' } },
      on_warn: ->(m) { warnings << m }
    )
    lookup = subject.evaluate(Req.new)

    refute lookup.blocked?
    assert_kind_of InternetData::Error, lookup.error
    assert_match(/could not resolve a client address/, warnings.first)
  end

  # The client refuses what is not an address before sending it, so a header
  # that carried something else is a failed lookup like any other: let through.
  def test_a_selector_answering_something_that_is_not_an_address_fails_open
    client, calls = serving(PAID)
    lookup = core(client: client, ip_selector: ->(_r) { 'example.com' },
                  block_condition: { location: { country: 'AT' } }).evaluate(Req.new)

    refute lookup.blocked?
    assert_equal :bad_request, lookup.error.kind
    assert_empty calls
  end

  # Every other test hands the core a client, so a key or a bound the core
  # dropped on its way to the client it builds would pass them all.
  def test_a_core_built_from_a_key_sends_it_once_bounded_at_its_own_timeout
    sent = []
    Typhoeus.stub(%r{\A#{Regexp.escape(BASE_URL)}/}).and_return do |request|
      sent << request
      json_response(503, { 'error' => 'unavailable' })
    end
    lookup = core(api_key: API_KEY, block_condition: { location: { country: 'AT' } }).evaluate(Req.new)

    refute lookup.blocked?
    assert_equal :server_error, lookup.error.kind
    assert_equal 1, sent.length, 'a request path retries nothing by default'
    assert_equal "Bearer #{API_KEY}", sent.first.options[:headers]['Authorization']
    assert_equal 2.5, sent.first.options[:timeout]
  end
end

# A regression test for a collision the Rails gem creates, not a hypothetical:
# `defined?(Rails)` inside `module InternetData` resolves to
# `InternetData::Rails` before the top-level one, so the moment the
# internetdata-rails gem defines that namespace, building any client would raise
# NoMethodError on a module that has no `.logger`.
class RailsConstantCollisionTest < Minitest::Test
  def test_a_nested_rails_namespace_does_not_break_the_client
    InternetData.const_set(:Rails, Module.new) unless InternetData.const_defined?(:Rails, false)
    InternetData::Client.new(cache: false)
  ensure
    InternetData.send(:remove_const, :Rails) if InternetData.const_defined?(:Rails, false)
  end
end
