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

  # A served answer for `ip`: the corpus's Unlimited one, every member the spec
  # requires and none it leaves to a plan, with `members` laid over it.
  def self.answer(ip, members = {})
    CORPUS['lookup'].find { |c| c['name'] == 'unlimited-answer' }.fetch('body').merge('ip' => ip).merge(members)
  end

  def answer(ip, members = {})
    TestHelper.answer(ip, members)
  end

  # Answers lookups from a table and records every request, so "never touched
  # the network" is asserted rather than assumed. Any address the table does not
  # know gets the 400 the real API answers.
  def stub_lookups(routes)
    calls = []
    Typhoeus.stub(%r{\A#{Regexp.escape(BASE_URL)}/}).and_return do |request|
      calls << request.url
      if request.url == "#{BASE_URL}/batch"
        batch_response(routes, request.options[:body])
      else
        route = routes[address_of(request)]
        if route.nil?
          json_response(400, { 'error' => 'not a valid IP address, AS number or domain' })
        else
          json_response(route[:status] || 200, route[:body], route[:headers] || {})
        end
      end
    end
    calls
  end

  # A POST /batch is answered the way the API answers one: every address the
  # table knows is a result if its route is a 200 and an entry error otherwise,
  # and an unknown address is the 400 the API gives a string that is not one.
  # One call however many addresses, which is what the request counts measure.
  def batch_response(routes, body)
    results = {}
    errors = {}
    JSON.parse(body.to_s).fetch('ips', []).each do |ip|
      route = routes[ip]
      if route.nil?
        errors[ip] = { 'status' => 400, 'error' => 'not a valid IP address, AS number or domain' }
      elsif (route[:status] || 200) == 200
        results[ip] = route[:body]
      else
        errors[ip] = { 'status' => route[:status], 'error' => route[:body]['error'] }
      end
    end
    json_response(200, { 'results' => results, 'errors' => errors })
  end

  def address_of(request)
    CGI.unescape(URI.parse(request.url).path.delete_prefix('/'))
  end

  def corpus_batch(name)
    TestHelper::CORPUS['batch'].find { |c| c['name'] == name }
  end
end

# A real HTTP server on a real socket, which is the only way to observe how many
# requests a hydra genuinely has in flight at once. A stubbed response is
# answered before the next one is even queued, so it would measure a peak of one
# whatever the concurrency was set to.
class TestServer
  attr_reader :peak, :paths

  def initialize(delay: 0.05, &handler)
    @socket = TCPServer.new('127.0.0.1', 0)
    @delay = delay
    @handler = handler || lambda do |path, body|
      if path == '/batch'
        [200, TestServer.batch_body(body)]
      else
        [200, JSON.generate(TestHelper.answer(path[1..], 'is_vpn' => false))]
      end
    end
    @lock = Mutex.new
    @in_flight = 0
    @peak = 0
    @paths = []
    @acceptor = Thread.new { accept_loop }
  end

  def base_url
    "http://127.0.0.1:#{@socket.addr[1]}"
  end

  def stop
    @socket.close
    @acceptor.kill
  end

  # The answer a batch gets from a server that has nothing to say about any
  # address: every address in the body, answered with `is_vpn`. A POST /batch
  # carries its addresses in the body rather than the path, so this is where
  # they are read.
  def self.batch_body(body, is_vpn: false)
    ips = JSON.parse(body.to_s).fetch('ips', [])
    JSON.generate({
      'results' => ips.to_h { |ip| [ip, TestHelper.answer(ip, 'is_vpn' => is_vpn)] },
      'errors' => {},
    })
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
    request = read_request(connection)
    return if request.nil?

    path, request_body = request
    status, body, headers, pace = in_flight(path) { @handler.call(path, request_body) }
    extra = (headers || {}).map { |name, value| "#{name}: #{value}\r\n" }.join
    connection.print(
      "HTTP/1.1 #{status} OK\r\nContent-Type: application/json\r\n#{extra}" \
      "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n",
    )
    write_body(connection, body, pace)
  ensure
    begin
      connection.close
    rescue IOError
      nil
    end
  end

  # Counts this request as in flight while it is being ANSWERED, ending before
  # the first response byte goes out. Held any longer the count RACES the hydra:
  # curl finishes on the last body byte and the next chunk leaves at once, so a
  # request whose thread had not yet booked itself out is seen alongside the new
  # one and `peak` reads one too high.
  def in_flight(path)
    enter(path)
    sleep(@delay)
    yield
  ensure
    leave
  end

  # The headers are already out, so a stall here is one no bound that stops at
  # the headers can see. `stall:` sends half the body and then waits; `trickle:`
  # sends a byte per gap, so no single read ever waits long.
  def write_body(connection, body, pace)
    case pace
    in nil
      connection.print(body)
    in { stall: seconds }
      connection.print(body.byteslice(0, body.bytesize / 2))
      connection.flush
      sleep(seconds)
      connection.print(body.byteslice(body.bytesize / 2, body.bytesize))
    in { trickle: gap }
      body.each_char do |char|
        connection.print(char)
        connection.flush
        sleep(gap)
      end
    end
  rescue Errno::EPIPE, Errno::ECONNRESET
    nil
  end

  def read_request(connection)
    request_line = connection.gets
    return nil if request_line.nil?

    length = 0
    loop do
      header = connection.gets
      break if header.nil? || header.strip.empty?

      name, value = header.split(':', 2)
      length = value.to_i if name.casecmp?('content-length')
    end
    # A POST carries its body after the blank line, sized by Content-Length.
    body = length.positive? ? connection.read(length) : ''
    [request_line.split(' ')[1], body]
  end

  def enter(path)
    @lock.synchronize do
      @paths << path
      @in_flight += 1
      @peak = [@peak, @in_flight].max
    end
  end

  def leave
    @lock.synchronize { @in_flight -= 1 }
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

  def initialize(body:, blob_bytes: nil, blob_status: 200, mint_status: 302, die_after: nil, blob_failures: 0,
                 json_pace: nil)
    @body = body
    @blob_failures = blob_failures
    @json_pace = json_pace
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

    failing = @lock.synchronize do
      @seen << record
      record[:path] == '/blob' && @seen.count { |r| r[:path] == '/blob' } <= @blob_failures
    end
    return head(connection, 503, 0) if failing
    return paced(connection) unless @json_pace.nil? || record[:path] == '/blob'

    record[:path] == '/blob' ? serve_blob(connection, record) : mint(connection)
  ensure
    begin
      connection.close
    rescue IOError
      nil
    end
  end

  # A JSON answer whose headers go out at once and whose body does not, so a bound
  # that stops at the headers never sees the stall. `stall:` sends half the body
  # and waits; `trickle:` sends a byte per gap, so no single read waits long.
  def paced(connection)
    body = "#{JSON.generate({ 'databases' => [] })}#{' ' * 400}"
    head(connection, 200, body.bytesize, 'Content-Type' => 'application/json')
    case @json_pace
    in { stall: seconds }
      connection.write(body.byteslice(0, body.bytesize / 2))
      sleep(seconds)
      connection.write(body.byteslice(body.bytesize / 2, body.bytesize))
    in { trickle: gap }
      body.each_char do |char|
        connection.write(char)
        sleep(gap)
      end
    end
  rescue Errno::EPIPE, Errno::ECONNRESET
    nil
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
