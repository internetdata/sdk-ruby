# frozen_string_literal: true

require 'typhoeus'

module InternetData
  DEFAULT_BASE_URL = 'https://internetdata.io'
  DEFAULT_RETRIES = 2
  DEFAULT_TIMEOUT = 30

  # A client for the InternetData API.
  #
  # Every call needs an API key carrying the `db.download` scope. Access is
  # granted by contract, one database family at a time, so there is no
  # unauthenticated tier to fall back to.
  class Client
    # The licensed database downloads, and everything about them.
    attr_reader :database

    # @param api_key [String] a key carrying the `db.download` scope.
    # @param retries [Integer] extra attempts for a transient failure.
    # @param timeout [Numeric] seconds allowed for one API call. It also bounds the
    #   CONNECT phase of a transfer, which is otherwise unlimited.
    # @param transport [Transport, nil] override the HTTP layer, mostly for tests.
    def initialize(api_key:, base_url: DEFAULT_BASE_URL, retries: DEFAULT_RETRIES,
                   timeout: DEFAULT_TIMEOUT, transport: nil)
      if transport.nil? && api_key.to_s.strip.empty?
        raise ArgumentError, 'an API key carrying the db.download scope is required'
      end

      @transport = transport || Transport.new(
        Transport::Config.new(api_key: api_key, base_url: base_url, timeout: timeout),
      )
      @database = DatabaseApi.new(@transport, retries: retries)
    end
  end
end
