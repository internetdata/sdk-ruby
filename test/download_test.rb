# frozen_string_literal: true

# The database transfer, exercised against a real HTTP origin rather than a stub.
# These methods exist to answer what curl does with a 302 and with a body too
# large to hold, and a stub exercises neither.

require 'digest'
require 'fileutils'
require 'tmpdir'

require_relative 'test_helper'

class DownloadTest < Minitest::Test
  include TestHelper

  BLOB = 'a whole database, gzipped in real life'
  MIB = 1024 * 1024

  def setup
    @dir = Dir.mktmpdir('internetdata-download-')
  end

  def teardown
    @origin&.stop
    FileUtils.remove_entry(@dir)
  end

  def test_download_follows_the_redirect_and_writes_the_file
    downloader = origin_client
    path = File.join(@dir, 'bogon_ip_v1.csv.gz')

    written = downloader.database.download('bogon_ip_v1', 'csvgz', path)

    assert_equal BLOB.bytesize, written
    assert_equal BLOB, File.binread(path)
    refute_path_exists "#{path}.part", 'the .part file outlived a successful transfer'
    assert_equal ['/api/v2/database/download', '/blob'], @origin.paths
  end

  def test_download_bytes_agrees_with_the_streamed_copy
    downloader = origin_client
    path = File.join(@dir, 'bogon_ip_v1.csv.gz')
    downloader.database.download('bogon_ip_v1', 'csvgz', path)

    bytes = downloader.database.download_bytes('bogon_ip_v1', 'csvgz')

    assert_equal Encoding::BINARY, bytes.encoding
    assert_equal File.binread(path), bytes
    assert_equal Digest::SHA256.hexdigest(File.binread(path)), Digest::SHA256.hexdigest(bytes)
  end

  # The key authorizes the API call that mints the link. The link is presigned
  # and authorizes itself, so forwarding the key on would hand a credential to a
  # host that has no business seeing it.
  def test_the_api_key_reaches_the_api_and_never_object_storage
    downloader = origin_client

    downloader.database.download_bytes('bogon_ip_v1', 'csvgz')

    minted = @origin.request('/api/v2/database/download')
    assert_equal "Bearer #{API_KEY}", minted[:headers]['authorization']

    fetched = @origin.request('/blob')
    refute_includes fetched[:target], API_KEY, 'the key was put in the object storage URL'
    fetched[:headers].each do |name, value|
      refute_includes value, API_KEY, "the key was sent to object storage as #{name}"
    end
  end

  # The assertion that matters most: a body far larger than any sane buffer has
  # to move through the process without ever being resident. Published databases
  # reach 5.34 GiB.
  #
  # Half the payload, not the eighth a compiled SDK can hold to. Streaming in
  # Ruby is not free of garbage: curl hands each 16 KB chunk over as a fresh
  # String, and absorbing that allocation rate grows the GC arena sub-linearly,
  # so a tighter ceiling fails for reasons that have nothing to do with
  # buffering.
  def test_a_large_body_is_streamed_not_buffered
    skip 'peak RSS is only readable through /proc' if peak_rss.nil?

    size = 512 * MIB
    downloader = origin_client(blob_bytes: size)
    before = peak_rss
    written = downloader.database.download('bogon_ip_v1', 'csvgz', File.join(@dir, 'big'))
    grew = peak_rss - before

    assert_equal size, written
    # Peak resident, not the live heap: an implementation that buffers frees the
    # buffer at the end of the call but cannot hide having held it.
    assert_operator grew, :<=, size / 2,
                    "peak RSS grew #{grew / MIB} MiB for a #{size / MIB} MiB body, so it was held"
  end

  # Nothing bounds the size of an object storage error page, so a refusal is
  # classified on the status with the body left unread. The origin promises a
  # page far larger than any socket buffer; the client hanging up before it
  # arrives is what shows the page was never taken.
  def test_object_storage_refusing_the_link_is_typed_with_its_page_left_unread
    page = 64 * MIB
    downloader = origin_client(blob_status: 403, blob_bytes: page)

    error = assert_raises(InternetData::Error) { downloader.database.download_bytes('bogon_ip_v1', 'csvgz') }

    assert_equal :forbidden, error.kind
    assert_equal 403, error.status
    refute error.retryable?
    assert_includes error.message, 'object storage refused the download link'
    assert_operator @origin.request('/blob')[:sent], :<, page,
                    'the whole refusal page was read before it was classified'
  end

  # A truncated file that looks complete is worse than no file: the next run
  # reads it as a whole database. The bytes land beside the destination and the
  # name only appears on success.
  def test_a_transfer_that_dies_part_way_leaves_nothing_at_the_destination
    downloader = origin_client(blob_bytes: 4 * MIB, die_after: MIB)
    path = File.join(@dir, 'bogon_ip_v1.csv.gz')

    error = assert_raises(InternetData::Error) { downloader.database.download('bogon_ip_v1', 'csvgz', path) }

    assert_equal :network, error.kind
    refute_path_exists path, 'a short file was left where a whole database should be'
    refute_path_exists "#{path}.part", 'the partial file survived a failed transfer'
  end

  def test_a_truncated_transfer_fails_for_download_bytes_too
    downloader = origin_client(blob_bytes: 4 * MIB, die_after: MIB)

    error = assert_raises(InternetData::Error) { downloader.database.download_bytes('bogon_ip_v1', 'csvgz') }

    assert_equal :network, error.kind
  end

  # The half of the .part guard a cleanup step cannot fake: a destination opened
  # directly is truncated before the first byte arrives, so yesterday's good copy
  # is gone whether or not the refresh then succeeds.
  def test_a_failed_refresh_leaves_the_previous_copy_intact
    downloader = origin_client(blob_bytes: 4 * MIB, die_after: MIB)
    path = File.join(@dir, 'bogon_ip_v1.csv.gz')
    File.binwrite(path, 'yesterday')

    assert_raises(InternetData::Error) { downloader.database.download('bogon_ip_v1', 'csvgz', path) }

    assert_path_exists path, 'the failed refresh took yesterdays copy with it'
    assert_equal 'yesterday', File.binread(path)
  end

  # An unlicensed database is refused by the API, before any link is minted. It
  # is a client error, so the retry schedule must not touch it.
  def test_an_unlicensed_database_is_forbidden_and_asked_for_exactly_once
    downloader = origin_client(mint_status: 403, retries: 3)
    path = File.join(@dir, 'bogon_ip_v1.csv.gz')

    error = assert_raises(InternetData::Error) { downloader.database.download('bogon_ip_v1', 'csvgz', path) }

    assert_equal :forbidden, error.kind
    assert_equal 403, error.status
    refute error.retryable?
    assert_equal 'NOT_LICENSED', error.rc
    assert_equal ['/api/v2/database/download'], @origin.paths
    refute_path_exists "#{path}.part", 'a refusal left a partial file behind'
  end

  def test_download_bytes_refuses_an_unlicensed_database_the_same_way
    downloader = origin_client(mint_status: 403, retries: 3)

    error = assert_raises(InternetData::Error) { downloader.database.download_bytes('bogon_ip_v1', 'csvgz') }

    assert_equal :forbidden, error.kind
    assert_equal 'NOT_LICENSED', error.rc
    assert_equal ['/api/v2/database/download'], @origin.paths
  end

  private

  def origin_client(retries: 0, **options)
    @origin = Origin.new(body: BLOB, **options)
    Typhoeus::Config.block_connection = false
    InternetData::Client.new(base_url: @origin.base_url, api_key: API_KEY, retries: retries)
  end

  # VmHWM is the highest resident set the process has ever reached, so a buffer
  # that was allocated and freed still shows. Linux only, which is where CI runs.
  def peak_rss
    File.read('/proc/self/status')[/^VmHWM:\s+(\d+) kB/, 1].to_i * 1024
  rescue Errno::ENOENT
    nil
  end
end
