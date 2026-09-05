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

  def test_errors_are_classified_by_range_and_by_retry_after
    CORPUS['errors'].each do |c|
      stub_api('/api/v2/database/metadata', c['status'], c['body'], c['headers'])

      error = assert_raises(InternetData::Error, c['name']) { client.database.metadata('bogon_ip_v1') }
      assert_equal c['expect']['kind'], error.kind.to_s, c['name']
      assert_equal c['expect']['retryable'], error.retryable?, "#{c['name']}: retryable"
      assert_equal c['status'], error.status, "#{c['name']}: status"
      assert_equal c['body']['rc'], error.rc, "#{c['name']}: rc"
      assert_equal c['expect']['message'], error.message, "#{c['name']}: message"
      if c['expect']['retryAfterSeconds']
        assert_equal c['expect']['retryAfterSeconds'], error.retry_after_seconds, c['name']
      end

      Typhoeus::Expectation.clear
    end
  end

  # A 404 is a CLIENT error. Three of four VPNDetection SDKs let one fall through
  # to the retryable server_error default and asked twice more for a database id
  # that will never exist, so the count is pinned rather than the classification
  # alone.
  def test_a_client_error_is_asked_for_exactly_once_and_a_server_error_is_not
    CORPUS['errors'].each do |c|
      calls = stub_api('/api/v2/database/metadata', c['status'], c['body'], c['headers'])
      retrying = InternetData::Client.new(api_key: API_KEY, retries: 2)

      assert_raises(InternetData::Error, c['name']) { retrying.database.metadata('bogon_ip_v1') }
      want = c['expect']['retryable'] ? 3 : 1
      assert_equal want, calls.length, "#{c['name']}: attempts"

      Typhoeus::Expectation.clear
    end
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

  def family(base, standing, license_type = 'standard')
    {
      'base' => base, 'name' => base.upcase, 'summary' => 'a line',
      'standing' => standing, 'license_type' => license_type,
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
