# frozen_string_literal: true

# The five v2 endpoints. Three of them nest their payload one level down, so an
# unwrap at the wrong depth returns nothing against a healthy API; each test pins
# the depth.

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
end
