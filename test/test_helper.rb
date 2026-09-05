# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'socket'
require 'typhoeus'

require 'internetdata'

module TestHelper
  CORPUS = JSON.parse(File.read(File.expand_path('../testdata/testdata.json', __dir__))).freeze

  BASE_URL = InternetData::DEFAULT_BASE_URL

  API_KEY = 'test-key-6f2a'

  def client(**options)
    InternetData::Client.new(api_key: API_KEY, retries: 0, **options)
  end

  # Answers one endpoint and records every request, so "asked exactly once" is
  # asserted rather than assumed.
  def stub_api(path, status, body, headers = {})
    calls = []
    Typhoeus.stub("#{BASE_URL}#{path}").and_return do |request|
      calls << request
      json_response(status, body, headers)
    end
    calls
  end

  def json_response(status, body, headers = {})
    Typhoeus::Response.new(
      code: status,
      body: body.is_a?(String) ? body : JSON.generate(body),
      headers: { 'Content-Type' => 'application/json' }.merge(headers),
    )
  end

  def corpus_error(name)
    CORPUS['errors'].find { |c| c['name'] == name } || raise("no #{name} fixture in the corpus")
  end
end

# Serves the API's 302 and the object storage it points at, on one origin, and
# records every request so a test can assert what did NOT happen.
#
# A stubbed response tests none of this: Typhoeus answers a stub without ever
# building an easy handle, so the streaming callbacks, the redirect guard and the
# headers the far side saw all go untested.
class Origin
  FILLER = ('x' * (1024 * 1024)).freeze

  def initialize(body:, blob_bytes: nil, blob_status: 200, mint_status: 302, die_after: nil)
    @body = body
    @blob_bytes = blob_bytes
    @blob_status = blob_status
    @mint_status = mint_status
    @die_after = die_after
    @socket = TCPServer.new('127.0.0.1', 0)
    @lock = Mutex.new
    @seen = []
    @acceptor = Thread.new { accept_loop }
  end

  def base_url
    "http://127.0.0.1:#{@socket.addr[1]}"
  end

  def stop
    @socket.close
    @acceptor.kill
  end

  def paths
    @lock.synchronize { @seen.map { |r| r[:path] } }
  end

  def request(path)
    @lock.synchronize { @seen.find { |r| r[:path] == path } } ||
      raise("the origin was never asked for #{path}, it saw #{paths.inspect}")
  end

  private

  def accept_loop
    loop do
      connection = @socket.accept
      Thread.new(connection) { |c| serve(c) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def serve(connection)
    record = read_request(connection)
    return if record.nil?

    @lock.synchronize { @seen << record }
    record[:path] == '/blob' ? serve_blob(connection, record) : mint(connection)
  ensure
    begin
      connection.close
    rescue IOError
      nil
    end
  end

  # Absolute, as the real 302 to object storage is: a presigned URL is on another
  # host entirely, so nothing here may lean on a relative one.
  def mint(connection)
    return head(connection, 302, 0, 'Location' => "#{base_url}/blob") if @mint_status == 302

    body = JSON.generate({ 'rc' => 'NOT_LICENSED' })
    head(connection, @mint_status, body.bytesize, 'Content-Type' => 'application/json')
    connection.write(body)
  end

  # Promises `declared` bytes and stops after `@die_after` of them, so a transfer
  # can be made to die with the destination already part written. A client that
  # hangs up mid-body is the point of several of these tests, so a broken pipe is
  # an outcome rather than an error, and what got out before it is what the test
  # reads back.
  def serve_blob(connection, record)
    declared = @blob_bytes || @body.bytesize
    stop_at = @die_after || declared
    head(connection, @blob_status, declared)
    sent = 0
    begin
      if @blob_bytes.nil?
        sent = connection.write(@body)
      else
        while sent < stop_at
          size = [FILLER.bytesize, stop_at - sent].min
          connection.write(size == FILLER.bytesize ? FILLER : FILLER[0, size])
          sent += size
        end
      end
    rescue Errno::EPIPE, Errno::ECONNRESET
      nil
    end
    record[:sent] = sent
  end

  def head(connection, status, declared, headers = {})
    extra = headers.map { |name, value| "#{name}: #{value}\r\n" }.join
    connection.print(
      "HTTP/1.1 #{status} X\r\n#{extra}Content-Length: #{declared}\r\nConnection: close\r\n\r\n",
    )
  end

  def read_request(connection)
    request_line = connection.gets
    return nil if request_line.nil?

    headers = {}
    loop do
      line = connection.gets
      break if line.nil? || line.strip.empty?

      name, _, value = line.partition(':')
      headers[name.strip.downcase] = value.strip
    end
    target = request_line.split(' ')[1]
    { target: target, path: target.split('?').first, headers: headers, sent: 0 }
  end
end
