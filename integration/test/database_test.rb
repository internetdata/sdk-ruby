# frozen_string_literal: true

# The published gem against the staging API, end to end: list a real catalog,
# read a real metadata document, and move real bytes whose digest the API
# published separately.

require 'digest'
require 'tmpdir'

require_relative '../lib/staging'

class DatabaseTest < Minitest::Test
  FORMATS = %w[csvgz mmdb].freeze
  STANDINGS = %w[licensed expired unlicensed].freeze
  LICENSE_TYPE = %w[evaluation internal redistribute].freeze
  DIGESTS = %w[md5 sha1 sha256 sha512].freeze

  def setup
    skip(Staging.skip_reason) if Staging.skip_reason
  end

  def test_the_catalog_reads_as_the_published_schema_describes_it
    databases = catalog

    refute_empty databases, 'staging published no databases at all'
    databases.each do |database|
      assert_includes STANDINGS, database.standing, "#{database.base}: standing"
      unless database.license_type.nil?
        assert_includes LICENSE_TYPE, database.license_type, "#{database.base}: license_type"
      end
      refute_empty database.versions, "#{database.base}: a family with no versions"
      database.versions.each do |version|
        assert_match(/\A[a-z0-9_]+\z/, version.id, "#{database.base}: version id")
        refute_empty version.formats, "#{version.id}: built in no format at all"
        (version.formats - FORMATS).each { |f| flunk("#{version.id}: undocumented format #{f}") }
      end
    end
  end

  # A license with no term is a live one; a license carrying `expires` in the
  # past would be reported as `expired`, so a CI credential that quietly lapses
  # shows up here rather than as a confusing refusal months later.
  def test_this_org_holds_at_least_one_live_license
    licensed = Staging.licensed(catalog)

    refute_empty licensed, 'the CI credential licenses nothing, so nothing can be downloaded'
    licensed.each do |database|
      refute_nil database.license_type, "#{database.base}: a live license with no license_type term"
    end
  end

  def test_metadata_publishes_a_size_for_every_format_the_version_is_built_in
    each_licensed_version do |version|
      metadata = client.database.metadata(version.id)

      assert_equal version.id, metadata.id
      assert_operator metadata.entries, :>=, 0, "#{version.id}: entries"
      assert_match(/\A\d{4}-\d{2}-\d{2}\z/, metadata.updated.to_s, "#{version.id}: updated")
      version.formats.each do |format|
        size = metadata.size[format]
        refute_nil size, "#{version.id}: built in #{format} but publishes no size for it"
        assert_operator size, :>, 0, "#{version.id}.#{format}: size"
      end
      assert_equal version.formats.sort, metadata.size.keys.sort, "#{version.id}: formats vs sizes"
    end
  end

  def test_a_download_matches_the_size_and_the_digest_the_api_published
    Dir.mktmpdir('internetdata-integration-') do |dir|
      each_licensed_version do |version|
        metadata = client.database.metadata(version.id)
        version.formats.each do |format|
          size = metadata.size[format]
          # Budgeted BEFORE the transfer, not after: the point is that a
          # mistaken id never gets to move gigabytes through CI.
          assert_operator size, :<=, Staging::SIZE_CEILING,
                          "#{version.id}.#{format} is #{size} bytes, over the CI budget"

          path = File.join(dir, "#{version.id}.#{format}")
          written = client.database.download(version.id, format, path)
          published = client.database.checksums(version.id, format)

          assert_equal size, written, "#{version.id}.#{format}: bytes written"
          assert_equal size, File.size(path), "#{version.id}.#{format}: bytes on disk"
          DIGESTS.each do |name|
            assert_match(/\A[0-9a-f]+\z/, published.public_send(name), "#{version.id}: #{name}")
          end
          assert_equal published.sha256, Digest::SHA256.file(path).hexdigest,
                       "#{version.id}.#{format}: sha256 disagrees with the published digest"
          assert_equal File.binread(path), client.database.download_bytes(version.id, format),
                       "#{version.id}.#{format}: download_bytes disagrees with the streamed copy"
        end
      end
    end
  end

  # The 302 is answered rather than chased, so the link can be handed to anything
  # that speaks HTTP. Fetching it here with no credential at all is what proves
  # that: it authorizes itself, and it carries none of ours.
  def test_the_download_url_is_a_credential_free_link_on_object_storage
    version = first_licensed_version
    format = version.formats.first
    size = client.database.metadata(version.id).size[format]
    assert_operator size, :<=, Staging::SIZE_CEILING, "#{version.id}.#{format} is over the CI budget"

    url = client.database.download_url(version.id, format)

    assert_match(%r{\Ahttps://}, url)
    refute_includes url, Staging.key, 'the API key was handed to object storage'
    refute_equal URI.parse(Staging::BASE_URL).host, URI.parse(url).host,
                 'the link points back at the API rather than at object storage'

    bare = Typhoeus.get(url)
    assert_equal 200, bare.code, 'the link did not authorize its own transfer'
    assert_equal size, bare.body.bytesize
  end

  # Every fetch above ran through the recorder, so this is the whole run rather
  # than one request: the key goes to the API and nowhere else.
  def test_the_key_reached_the_api_and_never_object_storage
    version = first_licensed_version
    Dir.mktmpdir('internetdata-integration-') do |dir|
      client.database.download(version.id, version.formats.first, File.join(dir, 'blob'))
    end

    api_origin = Staging::BASE_URL
    assert(Staging.facts.any? { |fact| fact.origin == api_origin && fact.carried_key },
           'the key never reached the API, so every assertion above ran unauthenticated')
    Staging.facts.reject { |fact| fact.origin == api_origin }.each do |fact|
      refute fact.carried_key, "the key was sent to #{fact.origin}#{fact.path}"
    end
  end

  def test_an_unlicensed_database_is_refused_without_a_retry
    unlicensed = Staging.unlicensed(catalog)
    skip 'staging published nothing this org does not license' if unlicensed.empty?

    version = unlicensed.first.versions.last
    # Retries would only slow a refusal down: it is a client error either way,
    # and this asserts the library agrees.
    error = assert_raises(InternetData::Error) do
      client(retries: 3).database.metadata(version.id)
    end

    assert_equal :forbidden, error.kind, "#{version.id}: kind"
    refute error.retryable?, "#{version.id}: a refusal is not worth retrying"
    assert_equal 403, error.status
    assert_includes %w[NOT_LICENSED LICENSE_EXPIRED], error.rc, "#{version.id}: rc"
  end

  def test_the_download_history_lists_what_this_run_did
    version = first_licensed_version
    Dir.mktmpdir('internetdata-integration-') do |dir|
      client.database.download(version.id, version.formats.first, File.join(dir, 'blob'))
    end

    attempts = client.database.downloads(limit: 10)

    refute_empty attempts
    assert_operator attempts.length, :<=, 10, 'the limit was not passed through'
    assert(attempts.any? { |a| a.dataset_id == version.id }, "no attempt at #{version.id} was recorded")
    attempts.each do |attempt|
      assert_includes %w[ok unauthorized denied expired unknown unavailable], attempt.outcome
    end
  end

  private

  def client(**options)
    Staging.client(**options)
  end

  # One listing for the whole run. It is also the fixture every other test reads,
  # so a catalog that fails to decode fails once and loudly.
  def catalog
    self.class.catalog ||= client.database.list
  end

  def each_licensed_version
    Staging.licensed(catalog).each { |database| database.versions.each { |v| yield v } }
  end

  def first_licensed_version
    Staging.licensed(catalog).first&.versions&.last ||
      flunk('the CI credential licenses nothing to download')
  end

  class << self
    attr_accessor :catalog
  end
end
