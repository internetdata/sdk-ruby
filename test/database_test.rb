# frozen_string_literal: true

# The five v2 endpoints. Three of them nest their payload one level down, so an
# unwrap at the wrong depth returns nothing against a healthy API; each test pins
# the depth.

require 'tmpdir'

require_relative 'test_helper'

class DatabaseTest < Minitest::Test
  include TestHelper

  CHECKSUMS = {
    'md5' => 'd41d8cd98f00b204e9800998ecf8427e',
    'sha1' => 'da39a3ee5e6b4b0d3255bfef95601890afd80709',
    'sha256' => 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    'sha512' => 'cf83e1357eefb8bd',
  }.freeze

  def setup
    Typhoeus::Config.block_connection = true
  end

  def teardown
    Typhoeus::Config.block_connection = false
    Typhoeus::Expectation.clear
  end

  # A license is held against the FAMILY, and the ids a download takes hang off
  # `versions`. Reading an id off the family is how list() -> download() breaks.
  def test_list_unwraps_the_families_and_their_versions
    stub_api('/api/v2/database/list', 200, {
               'databases' => [{
                 'base' => 'bogon_ip', 'name' => 'Bogon IP',
                 'summary' => 'Address space that cannot appear on the public internet.',
                 'standing' => 'licensed', 'license_type' => 'standard',
                 'starts' => '2026-01-01T00:00:00Z', 'expires' => nil,
                 'versions' => [{
                   'id' => 'bogon_ip_v1', 'version' => 1, 'summary' => 'v1',
                   'formats' => %w[csvgz mmdb],
                 }],
               }],
             })
    databases = client.database.list

    assert_equal 1, databases.length
    assert_equal 'bogon_ip', databases.first.base
    assert_equal 'licensed', databases.first.standing
    assert_equal 'standard', databases.first.license_type
    assert_nil databases.first.expires
    assert_equal 'bogon_ip_v1', databases.first.versions.first.id
    assert_equal 1, databases.first.versions.first.version
    assert_equal %w[csvgz mmdb], databases.first.versions.first.formats
  end

  def test_metadata_returns_the_document_itself
    stub_api('/api/v2/database/metadata', 200, {
               'id' => 'bogon_ip_v1', 'updated' => '2026-09-04',
               'entries' => 42, 'update_freq' => 'daily',
               'schema' => { 'csvgz' => [{ 'name' => 'ip', 'type' => 'string' }] },
               'sample' => { 'csvgz' => [{ 'ip' => '10.0.0.0/8' }] },
               'size' => { 'csvgz' => 760, 'mmdb' => 3524 },
             })
    metadata = client.database.metadata('bogon_ip_v1')

    assert_equal 'bogon_ip_v1', metadata.id
    assert_equal 42, metadata.entries
    assert_equal 'daily', metadata.update_freq
    assert_equal 'ip', metadata.schema['csvgz'].first.name
    # Per format, and what a transfer is budgeted against before it starts.
    assert_equal({ 'csvgz' => 760, 'mmdb' => 3524 }, metadata.size)
  end

  def test_checksums_returns_the_whole_digest_set_from_one_level_down
    stub_api('/api/v2/database/checksum', 200, {
               'id' => 'bogon_ip_v1', 'format' => 'csvgz', 'checksums' => CHECKSUMS,
             })
    checksums = client.database.checksums('bogon_ip_v1', 'csvgz')

    # Reading a top-level sha256 answers nil against a healthy API, which is
    # exactly what one sibling SDK shipped in its 1.0.x.
    assert_equal CHECKSUMS['sha256'], checksums.sha256
    assert_equal CHECKSUMS['md5'], checksums.md5
    assert_equal CHECKSUMS['sha1'], checksums.sha1
    assert_equal CHECKSUMS['sha512'], checksums.sha512
  end

  def test_downloads_unwraps_the_array_and_passes_a_limit
    calls = stub_api('/api/v2/database/downloads', 200, {
                       'downloads' => [{
                         'dataset_id' => 'bogon_ip_v1', 'format' => 'csvgz',
                         'outcome' => 'ok', 'bytes' => 760, 'http_status' => 302,
                         'apikey_id' => 'mk_1234abcd', 'client_ip' => '203.0.113.7',
                         'user_agent' => 'internetdata-ruby/1.0.0',
                         'created' => '2026-09-04T10:00:00Z',
                       }],
                     })
    downloads = client.database.downloads(limit: 5)

    assert_equal 'ok', downloads.first.outcome
    assert_equal 760, downloads.first.bytes
    assert_includes calls.first.url, 'limit=5'
  end

  def test_download_url_reads_the_location_off_the_302
    location = 'https://s3.example.test/bogon_ip_v1.csv.gz?sig=abc'
    stub_api('/api/v2/database/download', 302, {}, { 'Location' => location })

    assert_equal location, client.database.download_url('bogon_ip_v1', 'csvgz')
  end

  def test_download_url_does_not_follow_the_redirect
    # The redirect points back at this same server, so a follow shows up as a
    # second request. Pointing it at an unresolvable host would not: curl still
    # reports the 302 and its Location after failing to chase it, so the library
    # would look correct while downloading the database against a real bucket.
    origin = Origin.new(body: 'a whole database')
    Typhoeus::Config.block_connection = false

    url = client(base_url: origin.base_url).database.download_url('bogon_ip_v1', 'csvgz')

    assert_equal "#{origin.base_url}/blob", url
    assert_equal ['/api/v2/database/download'], origin.paths
  ensure
    origin&.stop
  end

  # The v1 endpoints take a `?apikey=` query credential and the v2 ones a bearer
  # header. Sending a v2 key the v1 way would put it in every access log between
  # here and the API.
  def test_the_key_travels_as_a_bearer_header_and_never_in_the_query
    calls = stub_api('/api/v2/database/list', 200, { 'databases' => [] })

    client.database.list

    assert_equal "Bearer #{API_KEY}", calls.first.options[:headers]['Authorization']
    refute_includes calls.first.url, 'apikey'
    refute_includes calls.first.url, API_KEY
  end

  def test_a_missing_scope_is_unauthorized
    stub_api('/api/v2/database/list', 401, { 'rc' => 'UNAUTHORIZED' })

    error = assert_raises(InternetData::Error) { client.database.list }
    assert_equal :unauthorized, error.kind
    assert_equal 'UNAUTHORIZED', error.rc
  end

  def test_an_unlicensed_database_is_forbidden_and_carries_its_rc
    stub_api('/api/v2/database/metadata', 403, { 'rc' => 'NOT_LICENSED' })

    error = assert_raises(InternetData::Error) { client.database.metadata('vpn_ip_v1') }
    assert_equal :forbidden, error.kind
    assert_equal 'NOT_LICENSED', error.rc
    refute error.retryable?
  end

  # Today every endpoint is licensed, so a keyless client only ever gets a 401.
  # It still has to BUILD and to send no credential at all: the generated
  # Configuration applies its schemes whatever they hold, so without the
  # `auth_settings` gate this sends `Authorization: Bearer ` and `?apikey=` -
  # which is exactly what an unset `${{ secrets.X }}` interpolates to.
  def test_a_keyless_client_builds_and_presents_no_credential_at_all
    [nil, ''].each do |api_key|
      calls = stub_api('/api/v2/database/list', 200, { 'databases' => [] })

      InternetData::Client.new(api_key: api_key, retries: 0).database.list

      refute calls.first.options[:headers].key?('Authorization'),
             "api_key #{api_key.inspect} still sent an Authorization header"
      refute_includes calls.first.url, 'apikey'
    end
  end

  # The bound must cover the BODY: one that stops at the response head lets a body
  # stalled after its headers run for as long as the server likes.
  def test_a_body_stalled_after_its_headers_is_bounded
    assert_body_bounded(stall: 8)
  end

  # A byte every 20 ms never leaves one read waiting long, so only a bound on the
  # whole attempt ends it.
  def test_a_body_trickled_a_byte_at_a_time_is_bounded
    assert_body_bounded(trickle: 0.02)
  end

  # A transfer takes no per-call timeout and REFUSES one rather than accepting it
  # and quietly ignoring it: a database runs to gigabytes and minutes, so any
  # bound that suits a JSON call would abandon a healthy download, and a caller
  # who passed one would be told nothing. The option is simply not in the
  # signature, so Ruby refuses it for us - this is what stops it being added.
  def test_a_transfer_refuses_a_per_call_timeout
    path = File.join(Dir.tmpdir, 'internetdata-timeout-refusal.mmdb')
    api = client.database

    assert_raises(ArgumentError) { api.download('bogon_ip_v1', 'mmdb', path, timeout: 1) }
    assert_raises(ArgumentError) { api.download_bytes('bogon_ip_v1', 'mmdb', timeout: 1) }

    refute_path_exists path
  end

  # The other half of the rule above: every call that is NOT a transfer takes the
  # option. Without this, the refusal test would pass just as well on a surface
  # that had never been given a per-call timeout at all.
  def test_every_json_call_takes_a_per_call_timeout
    %i[list metadata checksums downloads download_url].each do |name|
      assert_includes client.database.method(name).parameters, %i[key timeout],
                      "#{name} must take a per-call timeout"
    end
  end

  # Refused where it is set, on the client and per call. Accepted, a negative or
  # anything past 2147483 s ran with no bound at all, since libcurl refuses the
  # option and Ethon ignores the refusal, and NaN, Infinity, 2**63 or a string
  # failed every call with an error from Ruby, FFI or Ethon (measured on 2.3.1).
  def test_a_timeout_curl_cannot_hold_is_refused_where_it_is_set
    calls = stub_api('/api/v2/database/list', 200, { 'databases' => [] })
    [-1, -0.5, Float::NAN, Float::INFINITY, 2_147_484, 2**63, Complex(1, 0), '30', :x, true].each do |value|
      assert_raises(ArgumentError, "client #{value.inspect}") { client(timeout: value) }
      assert_raises(ArgumentError, "per call #{value.inspect}") { client.database.list(timeout: value) }
    end
    assert_empty calls, 'no refused timeout reached the network'

    [0, 0.5, 30, InternetData::Transport::LONGEST_TIMEOUT].each do |value|
      assert_equal [], client(timeout: value).database.list, "client #{value}"
      assert_equal [], client.database.list(timeout: value), "per call #{value}"
    end
  end

  def test_the_retry_schedule_and_the_longest_retry_after_honored
    throttle = ->(seconds) { InternetData::Error.new(:rate_limited, 'x', status: 429, retry_after_seconds: seconds) }
    delays = (1..4).map { |attempt| InternetData::Retries.delay_for(throttle.call(nil), attempt) }

    assert_equal [0.25, 0.5, 1.0, 2.0], delays, 'the backoff doubles from 250 ms'
    assert_equal 3.0, InternetData::Retries.delay_for(throttle.call(3.0), 4), 'a Retry-After is waited as given'
    assert_equal 0.0, InternetData::Retries.delay_for(throttle.call(0.0), 2), 'and 0 means now'
    assert_equal 2_147_483.647, InternetData::Retries.delay_for(throttle.call(2_147_483.647), 1), 'up to 2**31 - 1 ms'
    assert_equal 0.25, InternetData::Retries.delay_for(throttle.call(2_147_483.648), 1), 'and past it, the backoff'
  end

  # Honored, 2147484 held the call for 24.8 days, and 9223372036854775807 and
  # 1e400 raised a raw RangeError out of `sleep` (measured on 2.3.1).
  def test_a_retry_after_past_the_bound_is_waited_out_on_the_backoff
    %w[2147484 9223372036854775807 1e400].each do |value|
      Typhoeus.stub("#{BASE_URL}/api/v2/database/list").and_return(
        [json_response(429, { 'rc' => 'RATE_LIMITED' }, 'Retry-After' => value),
         json_response(200, { 'databases' => [] })],
      )
      worker = Thread.new { client(retries: 1).database.list }
      worker.report_on_exception = false

      assert worker.join(5), "Retry-After #{value}: the call waited on the header"
      assert_equal [], worker.value, "Retry-After #{value}: the retry succeeded"
    ensure
      worker&.kill
      Typhoeus::Expectation.clear
    end
  end

  private

  # Each call's per-call bound (0.3 s) fires first, then the same call with no
  # override waits for the client's own (1 s), and the elapsed time says which
  # one fired rather than the stall ending on its own.
  def assert_body_bounded(pace)
    Typhoeus::Config.block_connection = false
    origin = Origin.new(body: '', json_pace: pace)
    slow = InternetData::Client.new(base_url: origin.base_url, api_key: API_KEY, retries: 0, timeout: 1)
    per_call = {
      list: -> { slow.database.list(timeout: 0.3) },
      metadata: -> { slow.database.metadata('bogon_ip_v1', timeout: 0.3) },
      checksums: -> { slow.database.checksums('bogon_ip_v1', 'mmdb', timeout: 0.3) },
      downloads: -> { slow.database.downloads(limit: 5, timeout: 0.3) },
      # Minting a link is an ordinary JSON call, so it takes the bound; the
      # transfer that link is for is the one that must not.
      download_url: -> { slow.database.download_url('bogon_ip_v1', 'mmdb', timeout: 0.3) },
      oauth_exchange: -> { slow.oauth.exchange_device_code('cli', 'mo_dc_x', timeout: 0.3) },
    }
    client_bound = {
      list: -> { slow.database.list },
      metadata: -> { slow.database.metadata('bogon_ip_v1') },
      downloads: -> { slow.database.downloads(limit: 5) },
      oauth_metadata: -> { slow.oauth.metadata },
    }

    per_call.each { |name, call| assert_times_out(name, call, 0.25..0.9) }
    client_bound.each { |name, call| assert_times_out(name, call, 0.9..2.5) }
  ensure
    origin&.stop
  end

  def assert_times_out(name, call, window)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(InternetData::Error, name) { call.call }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal :network, error.kind, "#{name}: #{error.message}"
    assert error.retryable?, "#{name}: a timeout is a transport failure, and worth retrying"
    assert_includes window, elapsed, "#{name} settled after #{elapsed.round(2)}s"
  end
end
